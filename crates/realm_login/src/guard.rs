//! What keeps a flood or a password guesser away from the accounts and from
//! the realm's CPU: sliding-window counters by address and by account, kept
//! in memory only (nothing here outlives 24 h or a restart), and a small gate
//! every Argon2 hash has to pass.
//!
//! The account limits are built so that knowing a player's name is not enough
//! to lock that player out: failures count per (account, address), so someone
//! else's guesses use up their own allowance. Guessing from many addresses
//! lowers everyone's allowance for that account but never to zero, so the
//! real owner always keeps a few tries.
//!
//! The caller's address is the last X-Forwarded-For entry when the request
//! came from the proxy on this host (loopback); Caddy replaces whatever a
//! player sent in that header. Anything else is the peer address. A request
//! made directly on the host with no such header is a local tool and is not
//! limited.

use std::collections::{HashMap, VecDeque};
use std::net::IpAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use tokio::sync::Semaphore;

const MINUTE: Duration = Duration::from_secs(60);
const HOUR: Duration = Duration::from_secs(3600);
const DAY: Duration = Duration::from_secs(24 * 3600);

/// Login, registration and recovery requests from one address.
const REQUESTS_PER_MINUTE: usize = 60;

const LOGIN_WINDOW: Duration = Duration::from_secs(5 * 60);
/// Failed logins for one account from one address.
const LOGIN_PAIR: usize = 8;
/// Failed logins from one address, whatever the accounts (shared addresses
/// are common here, so this is well above one person's mistakes).
const LOGIN_ADDRESS: usize = 40;
/// Failures for one account from all addresses that count as an attack on it.
const ATTACK_WINDOW: Duration = Duration::from_secs(15 * 60);
const ATTACK_FAILURES: usize = 50;
/// What (account, address) may still fail during an attack.
const PAIR_UNDER_ATTACK: usize = 2;

const RECOVER_PAIR: usize = 5;
const RECOVER_ADDRESS: usize = 20;
const RECOVER_ATTACK: usize = 30;

/// Registration tries from one address (a taken name counts).
const SIGNUP_TRIES_PER_HOUR: usize = 30;
/// Accounts actually made from one address.
const SIGNUPS_PER_HOUR: usize = 5;
const SIGNUPS_PER_DAY: usize = 20;
/// Accounts made realm-wide, unless REALM_SIGNUPS_PER_HOUR says otherwise
/// (0 closes registration during an attack).
pub const SIGNUPS_GLOBAL_PER_HOUR: usize = 120;

/// Wrong passwords on a logged-in session's own account.
const REAUTH_WINDOW: Duration = Duration::from_secs(15 * 60);
const REAUTH_FAILURES: usize = 5;

/// One key never remembers more than this many hits.
const MAX_HITS_PER_KEY: usize = 256;
/// Keys kept at most; past this new ones go uncounted (the hash gate still
/// bounds the work), so memory stays bounded under a spoofed-looking flood.
const MAX_KEYS: usize = 100_000;
const SWEEP_EVERY: Duration = Duration::from_secs(60);

/// Argon2 hashes running at once, and how many may wait for a turn. Past
/// that a request is told the service is busy instead of queueing.
const HASH_SLOTS: usize = 2;
const HASH_WAITING: usize = 12;
const HASH_WAIT: Duration = Duration::from_secs(3);

/// Who is asking.
#[derive(Clone, Copy, Debug)]
pub struct Caller {
    pub ip: IpAddr,
    /// False: a tool on this host, talking to the service directly.
    pub limited: bool,
}

impl Caller {
    pub fn new(peer: IpAddr, forwarded: &str) -> Self {
        if !peer.is_loopback() {
            return Self {
                ip: peer,
                limited: true,
            };
        }
        let last = forwarded.rsplit(',').next().unwrap_or("").trim();
        if last.is_empty() {
            return Self {
                ip: peer,
                limited: false,
            };
        }
        Self {
            ip: last.parse().unwrap_or(peer),
            limited: true,
        }
    }

    /// The address as limits count it: IPv6 by its /64, which is what one
    /// household or server holds.
    fn key(&self) -> String {
        match self.ip.to_canonical() {
            IpAddr::V4(ip) => ip.to_string(),
            IpAddr::V6(ip) => {
                let s = ip.segments();
                format!("{:x}:{:x}:{:x}:{:x}::/64", s[0], s[1], s[2], s[3])
            }
        }
    }
}

/// Why an account was not made.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SignupRefused {
    /// Too many from this address.
    Address,
    /// The realm-wide limit (or registration is closed).
    Realm,
}

/// What a password-like secret is being tried for.
#[derive(Clone, Copy)]
pub enum Secret {
    Login,
    Recovery,
}

impl Secret {
    fn limits(self) -> (&'static str, Duration, usize, usize, usize) {
        match self {
            Self::Login => (
                "login",
                LOGIN_WINDOW,
                LOGIN_PAIR,
                LOGIN_ADDRESS,
                ATTACK_FAILURES,
            ),
            Self::Recovery => (
                "recover",
                HOUR,
                RECOVER_PAIR,
                RECOVER_ADDRESS,
                RECOVER_ATTACK,
            ),
        }
    }
}

struct Hits {
    span: Duration,
    at: VecDeque<Instant>,
}

pub struct Guard {
    hits: HashMap<String, Hits>,
    swept: Instant,
    signups_per_hour: usize,
}

/// An account name as a counter key: names that could not exist share one
/// key, so junk cannot grow the table.
fn name_key(name: &str) -> String {
    let name = name.trim();
    let plausible = (1..=24).contains(&name.len())
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
    if plausible {
        name.to_ascii_lowercase()
    } else {
        "?".to_owned()
    }
}

impl Guard {
    pub fn new(signups_per_hour: usize) -> Self {
        Self {
            hits: HashMap::new(),
            swept: Instant::now(),
            signups_per_hour,
        }
    }

    fn recent(&mut self, key: &str, span: Duration) -> usize {
        let now = Instant::now();
        let Some(hits) = self.hits.get_mut(key) else {
            return 0;
        };
        while hits
            .at
            .front()
            .is_some_and(|t| now.duration_since(*t) >= span)
        {
            hits.at.pop_front();
        }
        hits.at.len()
    }

    fn add(&mut self, key: String, span: Duration) {
        self.sweep();
        if !self.hits.contains_key(&key) && self.hits.len() >= MAX_KEYS {
            return;
        }
        let hits = self.hits.entry(key).or_insert_with(|| Hits {
            span,
            at: VecDeque::new(),
        });
        hits.span = hits.span.max(span);
        if hits.at.len() >= MAX_HITS_PER_KEY {
            hits.at.pop_front();
        }
        hits.at.push_back(Instant::now());
    }

    fn sweep(&mut self) {
        let now = Instant::now();
        if now.duration_since(self.swept) < SWEEP_EVERY {
            return;
        }
        self.swept = now;
        self.hits
            .retain(|_, h| h.at.back().is_some_and(|t| now.duration_since(*t) < h.span));
    }

    /// One more login, registration or recovery request from `who`: false
    /// when it has sent too many this minute.
    pub fn request_allowed(&mut self, who: Caller) -> bool {
        if !who.limited {
            return true;
        }
        let key = format!("req:{}", who.key());
        if self.recent(&key, MINUTE) >= REQUESTS_PER_MINUTE {
            return false;
        }
        self.add(key, MINUTE);
        true
    }

    /// Whether `who` must wait before trying a secret for `name`.
    pub fn blocked(&mut self, kind: Secret, who: Caller, name: &str) -> bool {
        if !who.limited {
            return false;
        }
        let (tag, window, pair, address, attack) = kind.limits();
        let (ip, account) = (who.key(), name_key(name));
        if self.recent(&format!("{tag}-ip:{ip}"), window) >= address {
            return true;
        }
        let under_attack = self.recent(&format!("{tag}-all:{account}"), ATTACK_WINDOW) >= attack;
        let allowed = if under_attack {
            PAIR_UNDER_ATTACK
        } else {
            pair
        };
        self.recent(&format!("{tag}-pair:{account}|{ip}"), window) >= allowed
    }

    pub fn failed(&mut self, kind: Secret, who: Caller, name: &str) {
        if !who.limited {
            return;
        }
        let (tag, window, ..) = kind.limits();
        let (ip, account) = (who.key(), name_key(name));
        self.add(format!("{tag}-ip:{ip}"), window);
        self.add(format!("{tag}-all:{account}"), ATTACK_WINDOW);
        self.add(format!("{tag}-pair:{account}|{ip}"), window);
    }

    /// The right secret: this address starts afresh for this account.
    pub fn passed(&mut self, kind: Secret, who: Caller, name: &str) {
        if !who.limited {
            return;
        }
        let (tag, ..) = kind.limits();
        self.hits
            .remove(&format!("{tag}-pair:{}|{}", name_key(name), who.key()));
    }

    /// A registration try from `who`, before anything is looked up.
    pub fn signup_try(&mut self, who: Caller) -> bool {
        if !who.limited {
            return true;
        }
        let key = format!("signup-try:{}", who.key());
        if self.recent(&key, HOUR) >= SIGNUP_TRIES_PER_HOUR {
            return false;
        }
        self.add(key, HOUR);
        true
    }

    /// Holds a place for one new account, before its password is hashed;
    /// `signup_refund` gives it back if none is made.
    pub fn signup_reserve(&mut self, who: Caller) -> Result<(), SignupRefused> {
        if !who.limited {
            return Ok(());
        }
        if self.signups_per_hour == 0 || self.recent("signup-realm", HOUR) >= self.signups_per_hour
        {
            return Err(SignupRefused::Realm);
        }
        let (hour, day) = (
            format!("signup-h:{}", who.key()),
            format!("signup-d:{}", who.key()),
        );
        if self.recent(&hour, HOUR) >= SIGNUPS_PER_HOUR || self.recent(&day, DAY) >= SIGNUPS_PER_DAY
        {
            return Err(SignupRefused::Address);
        }
        self.add("signup-realm".to_owned(), HOUR);
        self.add(hour, HOUR);
        self.add(day, DAY);
        Ok(())
    }

    pub fn signup_refund(&mut self, who: Caller) {
        if !who.limited {
            return;
        }
        for key in [
            "signup-realm".to_owned(),
            format!("signup-h:{}", who.key()),
            format!("signup-d:{}", who.key()),
        ] {
            if let Some(hits) = self.hits.get_mut(&key) {
                hits.at.pop_back();
            }
        }
    }

    /// Too many wrong passwords on this logged-in account's own actions.
    pub fn reauth_blocked(&mut self, account: u64) -> bool {
        self.recent(&format!("reauth:{account}"), REAUTH_WINDOW) >= REAUTH_FAILURES
    }

    pub fn reauth_failed(&mut self, account: u64) {
        self.add(format!("reauth:{account}"), REAUTH_WINDOW);
    }

    pub fn reauth_passed(&mut self, account: u64) {
        self.hits.remove(&format!("reauth:{account}"));
    }
}

/// The gate in front of Argon2: a few hashes at a time on the blocking pool,
/// a short bounded wait, and "busy" after that. A flood costs at most
/// HASH_SLOTS threads of CPU however many requests arrive.
pub struct HashGate {
    slots: Semaphore,
    waiting: AtomicUsize,
}

/// The gate is full.
#[derive(Debug)]
pub struct Busy;

impl HashGate {
    pub fn new() -> Self {
        Self {
            slots: Semaphore::new(HASH_SLOTS),
            waiting: AtomicUsize::new(0),
        }
    }

    pub async fn run<T: Send + 'static>(
        &self,
        work: impl FnOnce() -> T + Send + 'static,
    ) -> Result<T, Busy> {
        if self.waiting.fetch_add(1, Ordering::SeqCst) >= HASH_WAITING + HASH_SLOTS {
            self.waiting.fetch_sub(1, Ordering::SeqCst);
            return Err(Busy);
        }
        let permit = tokio::time::timeout(HASH_WAIT, self.slots.acquire()).await;
        let result = match permit {
            Ok(Ok(_held)) => tokio::task::spawn_blocking(work).await.map_err(|_| Busy),
            _ => Err(Busy),
        };
        self.waiting.fetch_sub(1, Ordering::SeqCst);
        result
    }
}
