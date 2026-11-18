//! realm_login (--characters <dir> [--accounts <file.json>] | --persist <addr>)
//!             [--bind 127.0.0.1:7950] [--keys keys] [--content content/data]
//!             [--coord-admin 127.0.0.1:8082] [--start-map grounds]
//!
//! The login service: accounts, their characters, and the ticket a client
//! joins its map with. It holds keys/ticket.key (map servers only hold the
//! public half). With `--persist` the accounts and characters are kept by
//! the persistence service (realm_persist, PostgreSQL; keys/coord.key), the
//! map servers loading them from there too; without it (development, CI)
//! in a JSON ledger and as new character files in the folder the map
//! servers keep them in (store.rs). Sessions and the throttles are in memory
//! either way (guard.rs). The rules: account names 3-24 of [A-Za-z0-9_-],
//! passwords of 8 or more with letters and digits, argon2id; a session lasts
//! 24 h, five at most per account (the oldest goes); two characters per
//! account; character names as realm_rules::names, unique whatever the case.
//!
//! Where a character's map is (and whether the realm takes logins) comes
//! from the coordinator's admin surface (GET /admin/maps, with
//! REALM_SERVICE_TOKEN); the same surface takes characters out of the world
//! before they are deleted.
//!
//! Refusals carry the player's sentence in `error` and, where the game acts
//! on one, a `code` (update_required, terms_required, consent_required,
//! terms_outdated, busy, rate_limited, maintenance, realm_unreachable).
//! A client may send `protocol_version` with login, register and play: one
//! that does not match is told update_required (426) before it goes further.
//!
//!   POST /api/register          {username, password, terms_version, terms_accepted, age_confirmed}
//!                               -> {success, account_id, recovery_code}
//!   POST /api/login             {username, password} -> {success, account_id, username, token,
//!                               expires_in_seconds, terms_required, terms_version, has_recovery_code}
//!   POST /api/logout            (Bearer)
//!   POST /api/account/recover   {username, recovery_code, new_password} -> {success, recovery_code}
//!   POST /api/account/info      (Bearer) -> {username, has_recovery_code, terms_required, terms_version}
//!   POST /api/account/accept-terms (Bearer) {terms_version, terms_accepted, age_confirmed}
//!   POST /api/account/password  (Bearer) {current_password, new_password, keep_character?} -> {success, token, ..}
//!   POST /api/account/recovery-code (Bearer) {password} -> {success, recovery_code}
//!   POST /api/account/delete    (Bearer) {password, confirm_username}
//!   POST /api/characters/list   (Bearer) -> {characters: [{id, name, house, level, map, look}]}
//!   POST /api/characters/create (Bearer) {name, house, look} -> {character: {id, name, house}}
//!   POST /api/characters/delete (Bearer) {character_id, confirm_name}
//!   POST /api/play              (Bearer) {character_id} -> {map, address, ticket (hex), expires_in_seconds}
//!   GET  /api/health
//!   GET  /api/status            -> {state: ONLINE|MAINTENANCE, realm: open|maintenance|unreachable,
//!                                   maintenance, message, protocol_version} (the launcher, the game)
//!   GET  /api/legal...          the Terms and the Privacy Policy (legal.rs)
//!
//! Until an account has accepted the current terms its session can only
//! accept them, change or recover its password, delete itself or log out.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use argon2::Argon2;
use argon2::password_hash::phc::PasswordHash;
use argon2::password_hash::{PasswordHasher, PasswordVerifier};
use realm_http::{Request, read_request, respond_raw, same};
use realm_proto::SigningKey;
use realm_proto::persist::client::PersistClient;
use realm_proto::persist::{PersistMsg, PersistReply};
use realm_proto::ticket::Ticket;
use realm_rules::names::{name_key, name_problem};
use realm_rules::{CharacterSheet, Rules};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, Semaphore};

mod guard;
mod legal;
mod store;

use guard::{Caller, Guard, HashGate, Secret, SignupRefused};
use store::{Failure, Found, Ledger, write_atomic};

type AnyResult<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;
type Reply = (u16, Value);

const SESSION_TTL: Duration = Duration::from_secs(24 * 3600);
const MAX_SESSIONS: usize = 5;
const MAX_CHARACTERS: usize = 2;
const TICKET_SECONDS: u64 = 60;
const MAX_CONNECTIONS: usize = 32;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);
/// New characters are numbered from here (development characters below).
const FIRST_CHARACTER: u64 = realm_proto::persist::FIRST_PLAYER_CHARACTER;
/// /api/status may be this old (every waiting client polls it).
const STATUS_TTL: Duration = Duration::from_secs(3);
/// A character being deleted stays barred from the world this long: past any
/// ticket already handed out.
const DELETE_BAR_SECONDS: u64 = 120;
/// How long the coordinator gets to take characters out of the world.
const RELEASE_TIMEOUT: Duration = Duration::from_secs(9);
/// Recovery codes: 30 symbols of 5 bits, in groups of five.
const CODE_SYMBOLS: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

const BAD_LOGIN: &str = "Invalid username or password.";
const BAD_RECOVERY: &str = "Invalid username or recovery code.";
const BAD_PASSWORD: &str = "Your current password is not correct.";
const TOO_MANY_LOGINS: &str = "Too many failed logins. Try again in a few minutes.";
const TOO_MANY_TRIES: &str = "Too many attempts. Try again in a few minutes.";

struct Session {
    account: u64,
    username: String,
    terms_ok: bool,
    expires: Instant,
    made: Instant,
}

/// The session a request came with.
struct Me {
    account: u64,
    username: String,
    terms_ok: bool,
}

struct State {
    /// The persistence service (None: the ledger and character files).
    persist: Option<Arc<PersistClient>>,
    ledger: Ledger,
    ledger_file: PathBuf,
    characters: PathBuf,
    sessions: HashMap<String, Session>,
    guard: Guard,
    rules: Arc<Rules>,
    houses: Vec<String>,
    key: SigningKey,
    coord_admin: String,
    service_token: String,
    start_map: String,
    /// The last /api/status answer and when it was made.
    status: Option<(Instant, Value)>,
}

pub struct App {
    state: Mutex<State>,
    gate: HashGate,
    /// Verified when a name has no account, so an unknown name takes as long
    /// as a wrong password.
    dummy_hash: String,
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn token() -> Result<String, getrandom::Error> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes)?;
    Ok(hex(&bytes))
}

/// A fresh one-time code: 150 random bits, easy to copy by hand.
fn new_recovery_code() -> Result<String, getrandom::Error> {
    let mut bytes = [0_u8; 30];
    getrandom::fill(&mut bytes)?;
    let mut out = String::with_capacity(35);
    for (i, b) in bytes.iter().enumerate() {
        if i > 0 && i % 5 == 0 {
            out.push('-');
        }
        out.push(char::from(CODE_SYMBOLS[usize::from(b & 31)]));
    }
    Ok(out)
}

/// What is stored for a code. The code is long and random, so a plain hash
/// is enough (and costs an attacker's flood nothing here); look-alike
/// letters and the dashes do not matter when it is typed back.
fn recovery_hash(code: &str) -> String {
    let clean: String = code
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .map(|c| match c.to_ascii_uppercase() {
            'O' => '0',
            'I' | 'L' => '1',
            other => other,
        })
        .collect();
    let mut hasher = Sha256::new();
    hasher.update(b"realm-recovery-v1:");
    hasher.update(clean.as_bytes());
    format!("sha256:{}", hex(hasher.finalize().as_slice()))
}

/// A new account's name may not pass for staff, or be a listed word.
fn reserved_account(name: &str) -> Option<&'static str> {
    realm_filter::shared()
        .name_refused(name)
        .then_some("That account name is not available.")
}

fn account_problem(name: &str) -> Option<&'static str> {
    let ok = (3..=24).contains(&name.len())
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
    (!ok).then_some("Account names are 3-24 letters, digits, _ or -.")
}

fn password_problem(password: &str) -> Option<&'static str> {
    let ok = password.chars().count() >= 8
        && password.chars().any(|c| c.is_alphabetic())
        && password.chars().any(|c| c.is_ascii_digit())
        && password.len() <= 256;
    (!ok).then_some("Passwords need 8 or more characters with letters and digits.")
}

fn error(status: u16, message: &str) -> Reply {
    (status, json!({"success": false, "error": message}))
}

fn coded(status: u16, code: &str, message: &str) -> Reply {
    (
        status,
        json!({"success": false, "error": message, "code": code}),
    )
}

fn unavailable(what: &str, e: &str) -> Reply {
    eprintln!("[login] {what}: {e}");
    error(503, "Service unavailable.")
}

fn store_down(what: &str, failure: &Failure) -> Reply {
    unavailable(what, &format!("{failure:?}"))
}

fn busy() -> Reply {
    coded(
        503,
        "busy",
        "The login service is busy. Try again in a moment.",
    )
}

fn rate_limited(message: &str) -> Reply {
    coded(429, "rate_limited", message)
}

fn text<'a>(body: &'a Value, key: &str) -> &'a str {
    body[key].as_str().unwrap_or("")
}

/// A client built for another protocol is stopped here, before it logs in
/// or asks for a ticket. One that does not say (an older game) goes on, and
/// the map refuses it as before.
fn outdated(body: &Value) -> Option<Reply> {
    let theirs = body["protocol_version"].as_u64()?;
    let ours = realm_proto::PROTOCOL_VERSION;
    (theirs != u64::from(ours)).then(|| {
        (
            426,
            json!({
                "success": false,
                "code": "update_required",
                "error": "Your game is out of date. Close it and open the launcher to update.",
                "protocol_version": ours,
            }),
        )
    })
}

/// The consent a registration or the terms screen must carry.
fn consent_problem(body: &Value) -> Option<Reply> {
    if text(body, "terms_version") != legal::VERSION {
        return Some(coded(
            400,
            "terms_outdated",
            "The Terms have changed. Please review them again.",
        ));
    }
    if body["terms_accepted"] != true {
        return Some(coded(
            400,
            "consent_required",
            "Accept the Terms of Service and Privacy Policy to continue.",
        ));
    }
    if body["age_confirmed"] != true {
        return Some(coded(
            400,
            "consent_required",
            "You must confirm that you are 16 or older.",
        ));
    }
    None
}

fn hash_password(password: &str) -> Result<String, String> {
    Argon2::default()
        .hash_password(password.as_bytes())
        .map(|h| h.to_string())
        .map_err(|e| e.to_string())
}

fn verify_password(hash: &str, password: &str) -> bool {
    PasswordHash::new(hash).is_ok_and(|h| {
        Argon2::default()
            .verify_password(password.as_bytes(), &h)
            .is_ok()
    })
}

impl State {
    fn session_of(&mut self, token: &str) -> Option<Me> {
        let now = Instant::now();
        self.sessions.retain(|_, s| s.expires > now);
        self.sessions.get(token).map(|s| Me {
            account: s.account,
            username: s.username.clone(),
            terms_ok: s.terms_ok,
        })
    }

    /// A new session; the account's oldest goes past MAX_SESSIONS.
    fn open_session(&mut self, account: u64, username: &str, terms_ok: bool, t: String) {
        let now = Instant::now();
        self.sessions.retain(|_, x| x.expires > now);
        let mut mine: Vec<(String, Instant)> = self
            .sessions
            .iter()
            .filter(|(_, x)| x.account == account)
            .map(|(k, x)| (k.clone(), x.made))
            .collect();
        mine.sort_by_key(|(_, made)| *made);
        while mine.len() >= MAX_SESSIONS {
            let (oldest, _) = mine.remove(0);
            self.sessions.remove(&oldest);
        }
        self.sessions.insert(
            t,
            Session {
                account,
                username: username.to_owned(),
                terms_ok,
                expires: now + SESSION_TTL,
                made: now,
            },
        );
    }

    fn revoke_sessions(&mut self, account: u64) {
        self.sessions.retain(|_, s| s.account != account);
    }
}

impl App {
    async fn hashed(&self, password: String) -> Result<String, Reply> {
        match self.gate.run(move || hash_password(&password)).await {
            Ok(Ok(hash)) => Ok(hash),
            Ok(Err(e)) => Err(unavailable("hashing", &e)),
            Err(guard::Busy) => Err(busy()),
        }
    }

    async fn verified(&self, hash: String, password: String) -> Result<bool, Reply> {
        self.gate
            .run(move || verify_password(&hash, &password))
            .await
            .map_err(|guard::Busy| busy())
    }

    async fn admin(&self, path: &str, body: &Value, method: &str) -> Option<(u16, Value)> {
        let (admin, token) = {
            let s = self.state.lock().await;
            (s.coord_admin.clone(), s.service_token.clone())
        };
        let headers = [("x-service-token", token.as_str())];
        let call = realm_http::call(&admin, method, path, &headers, body);
        tokio::time::timeout(RELEASE_TIMEOUT, call).await.ok()?.ok()
    }

    /// Has the coordinator take `characters` out of the world (saved and
    /// released as any logout: parties, duels and dungeon runs close as they
    /// do then) and keep them out for `bar_seconds`, and take `names` off the
    /// boards it holds. True once they are all out.
    async fn release_characters(
        &self,
        characters: &[u64],
        names: &[String],
        bar_seconds: u64,
    ) -> bool {
        let body = json!({"characters": characters, "names": names, "bar_seconds": bar_seconds});
        match self.admin("/admin/characters/release", &body, "POST").await {
            Some((200, v)) if v["ok"] == true => true,
            other => {
                eprintln!("[login] releasing characters {characters:?}: {other:?}");
                false
            }
        }
    }

    /// Everything of `account` still in the world leaves it, except
    /// `keep` (the character this very client is playing). Not waited for.
    async fn kick_account(self: &Arc<Self>, account: u64, keep: u64) {
        let Ok(roster) = self.roster(account).await else {
            return;
        };
        let ids: Vec<u64> = roster
            .into_iter()
            .map(|(id, _)| id)
            .filter(|id| *id != keep)
            .collect();
        if ids.is_empty() {
            return;
        }
        let app = self.clone();
        tokio::spawn(async move {
            app.release_characters(&ids, &[], 0).await;
        });
    }

    /// The password of the logged-in account, checked with its own limit.
    async fn reauthenticate(&self, me: &Me, password: &str) -> Result<Found, Reply> {
        if self.state.lock().await.guard.reauth_blocked(me.account) {
            return Err(rate_limited(TOO_MANY_TRIES));
        }
        let found = match self.find_account(&me.username).await {
            Ok(Some(found)) if found.id == me.account => found,
            Ok(_) => return Err(error(401, "Not logged in.")),
            Err(e) => return Err(store_down("account", &e)),
        };
        let right = self
            .verified(found.hash.clone(), password.to_owned())
            .await?;
        let mut s = self.state.lock().await;
        if right {
            s.guard.reauth_passed(me.account);
            Ok(found)
        } else {
            s.guard.reauth_failed(me.account);
            Err(coded(403, "wrong_password", BAD_PASSWORD))
        }
    }
}

async fn register(app: &App, who: Caller, body: &Value) -> Reply {
    if let Some(refused) = outdated(body) {
        return refused;
    }
    {
        let mut s = app.state.lock().await;
        if !s.guard.request_allowed(who) || !s.guard.signup_try(who) {
            return rate_limited(TOO_MANY_TRIES);
        }
    }
    let name = text(body, "username").trim().to_owned();
    let password = text(body, "password").to_owned();
    if let Some(p) = account_problem(&name)
        .or_else(|| reserved_account(&name))
        .or_else(|| password_problem(&password))
    {
        return error(400, p);
    }
    if let Some(refused) = consent_problem(body) {
        return refused;
    }
    // The name first: a taken name costs no hashing.
    match app.find_account(&name).await {
        Ok(None) => {}
        Ok(Some(_)) => return error(409, "That account name is taken."),
        Err(e) => return store_down("register", &e),
    }
    let reserved = app.state.lock().await.guard.signup_reserve(who);
    match reserved {
        Ok(()) => {}
        Err(SignupRefused::Address) => {
            return rate_limited("Too many new accounts from your network. Try again later.");
        }
        Err(SignupRefused::Realm) => {
            return coded(
                503,
                "signups_paused",
                "New accounts are paused for now. Try again later.",
            );
        }
    }
    let made = make_account(app, &name, password).await;
    if made.0 != 200 {
        app.state.lock().await.guard.signup_refund(who);
    }
    made
}

async fn make_account(app: &App, name: &str, password: String) -> Reply {
    let hash = match app.hashed(password).await {
        Ok(hash) => hash,
        Err(refused) => return refused,
    };
    let Ok(code) = new_recovery_code() else {
        return error(503, "Service unavailable.");
    };
    match app
        .create_account(name, hash, recovery_hash(&code), legal::VERSION)
        .await
    {
        Ok(id) => {
            println!("[login] account {id} registered");
            (
                200,
                json!({
                    "success": true,
                    "account_id": id,
                    "recovery_code": code,
                    "terms_version": legal::VERSION,
                }),
            )
        }
        Err(Failure::Refused(e)) if e == "taken" => error(409, "That account name is taken."),
        Err(e) => store_down("register", &e),
    }
}

async fn login(app: &App, who: Caller, body: &Value) -> Reply {
    if let Some(refused) = outdated(body) {
        return refused;
    }
    let name = text(body, "username").trim().to_owned();
    let password = text(body, "password");
    // Too long to be anyone's: it simply will not match.
    let password = if password.len() > 256 { "" } else { password }.to_owned();
    {
        let mut s = app.state.lock().await;
        if !s.guard.request_allowed(who) || s.guard.blocked(Secret::Login, who, &name) {
            return rate_limited(TOO_MANY_LOGINS);
        }
    }
    let found = if account_problem(&name).is_some() {
        None
    } else {
        match app.find_account(&name).await {
            Ok(found) => found,
            Err(e) => return store_down("login", &e),
        }
    };
    let hash = found
        .as_ref()
        .map_or_else(|| app.dummy_hash.clone(), |f| f.hash.clone());
    let right = match app.verified(hash, password).await {
        Ok(right) => right,
        Err(refused) => return refused,
    };
    let Some(found) = found.filter(|_| right) else {
        app.state
            .lock()
            .await
            .guard
            .failed(Secret::Login, who, &name);
        return error(401, BAD_LOGIN);
    };
    if let Some(refused) = banned(app, found.id).await {
        return refused;
    }
    let Ok(t) = token() else {
        return error(503, "Service unavailable.");
    };
    app.touch_account(found.id).await;
    let terms_ok = found.terms_version.as_deref() == Some(legal::VERSION);
    {
        let mut s = app.state.lock().await;
        s.guard.passed(Secret::Login, who, &name);
        s.open_session(found.id, &found.username, terms_ok, t.clone());
    }
    println!("[login] account {} logged in", found.id);
    (
        200,
        json!({
            "success": true,
            "account_id": found.id,
            "username": found.username,
            "token": t,
            "expires_in_seconds": SESSION_TTL.as_secs(),
            "terms_required": !terms_ok,
            "terms_version": legal::VERSION,
            "has_recovery_code": found.recovery_hash.is_some(),
        }),
    )
}

/// A forgotten password: the one-time code buys a new one and is replaced.
/// Every failure reads the same, whether or not the account exists.
async fn recover(app: &Arc<App>, who: Caller, body: &Value) -> Reply {
    let name = text(body, "username").trim().to_owned();
    let password = text(body, "new_password").to_owned();
    {
        let mut s = app.state.lock().await;
        if !s.guard.request_allowed(who) || s.guard.blocked(Secret::Recovery, who, &name) {
            return rate_limited(TOO_MANY_TRIES);
        }
    }
    if let Some(p) = password_problem(&password) {
        return error(400, p);
    }
    let given = recovery_hash(text(body, "recovery_code"));
    let found = if account_problem(&name).is_some() {
        None
    } else {
        match app.find_account(&name).await {
            Ok(found) => found,
            Err(e) => return store_down("recover", &e),
        }
    };
    let stored = found
        .as_ref()
        .and_then(|f| f.recovery_hash.clone())
        .unwrap_or_default();
    let right = same(stored.as_bytes(), given.as_bytes());
    let Some(found) = found.filter(|_| right) else {
        app.state
            .lock()
            .await
            .guard
            .failed(Secret::Recovery, who, &name);
        return error(401, BAD_RECOVERY);
    };
    let hash = match app.hashed(password).await {
        Ok(hash) => hash,
        Err(refused) => return refused,
    };
    let Ok(code) = new_recovery_code() else {
        return error(503, "Service unavailable.");
    };
    match app
        .recover(found.id, stored, hash, recovery_hash(&code))
        .await
    {
        Ok(()) => {}
        Err(Failure::Refused(_)) => return error(401, BAD_RECOVERY),
        Err(e) => return store_down("recover", &e),
    }
    {
        let mut s = app.state.lock().await;
        s.guard.passed(Secret::Recovery, who, &name);
        s.guard.passed(Secret::Login, who, &name);
        s.revoke_sessions(found.id);
    }
    app.kick_account(found.id, 0).await;
    println!("[login] account {} recovered", found.id);
    (200, json!({"success": true, "recovery_code": code}))
}

async fn accept_terms(app: &App, me: &Me, body: &Value) -> Reply {
    if let Some(refused) = consent_problem(body) {
        return refused;
    }
    if let Err(e) = app.accept_terms(me.account, legal::VERSION).await {
        return store_down("terms", &e);
    }
    let mut s = app.state.lock().await;
    for session in s.sessions.values_mut() {
        if session.account == me.account {
            session.terms_ok = true;
        }
    }
    (
        200,
        json!({"success": true, "terms_version": legal::VERSION}),
    )
}

/// A new password: every session of the account ends, this client gets a
/// fresh one, and whatever else of the account is in the world is taken out.
async fn change_password(app: &Arc<App>, me: &Me, body: &Value) -> Reply {
    let new = text(body, "new_password").to_owned();
    if let Some(p) = password_problem(&new) {
        return error(400, p);
    }
    if let Err(refused) = app.reauthenticate(me, text(body, "current_password")).await {
        return refused;
    }
    let hash = match app.hashed(new).await {
        Ok(hash) => hash,
        Err(refused) => return refused,
    };
    let Ok(t) = token() else {
        return error(503, "Service unavailable.");
    };
    if let Err(e) = app.set_password(me.account, hash).await {
        return store_down("password", &e);
    }
    {
        let mut s = app.state.lock().await;
        s.revoke_sessions(me.account);
        s.open_session(me.account, &me.username, me.terms_ok, t.clone());
    }
    app.kick_account(me.account, body["keep_character"].as_u64().unwrap_or(0))
        .await;
    println!("[login] account {} changed its password", me.account);
    (
        200,
        json!({"success": true, "token": t, "expires_in_seconds": SESSION_TTL.as_secs()}),
    )
}

async fn new_recovery(app: &App, me: &Me, body: &Value) -> Reply {
    if let Err(refused) = app.reauthenticate(me, text(body, "password")).await {
        return refused;
    }
    let Ok(code) = new_recovery_code() else {
        return error(503, "Service unavailable.");
    };
    if let Err(e) = app.set_recovery(me.account, recovery_hash(&code)).await {
        return store_down("recovery code", &e);
    }
    println!("[login] account {} made a new recovery code", me.account);
    (200, json!({"success": true, "recovery_code": code}))
}

async fn account_info(app: &App, me: &Me) -> Reply {
    match app.find_account(&me.username).await {
        Ok(Some(found)) if found.id == me.account => (
            200,
            json!({
                "success": true,
                "username": found.username,
                "has_recovery_code": found.recovery_hash.is_some(),
                "terms_required": !me.terms_ok,
                "terms_version": legal::VERSION,
            }),
        ),
        Ok(_) => error(401, "Not logged in."),
        Err(e) => store_down("account", &e),
    }
}

const STILL_PLAYING: &str = "That character could not leave the world yet. Try again in a moment.";

async fn delete_character(app: &App, me: &Me, body: &Value) -> Reply {
    let character = body["character_id"].as_u64().unwrap_or(0);
    let roster = match app.roster(me.account).await {
        Ok(roster) => roster,
        Err(e) => return store_down("delete character", &e),
    };
    let Some((_, name)) = roster.into_iter().find(|(id, _)| *id == character) else {
        return error(404, "No such character.");
    };
    if name_key(text(body, "confirm_name")) != name_key(&name) {
        return coded(
            400,
            "confirm_mismatch",
            "The name you typed does not match.",
        );
    }
    if !app
        .release_characters(
            &[character],
            std::slice::from_ref(&name),
            DELETE_BAR_SECONDS,
        )
        .await
    {
        return coded(503, "still_playing", STILL_PLAYING);
    }
    match app.delete_character(me.account, character).await {
        Ok(()) => {
            println!(
                "[login] account {} deleted character {character}",
                me.account
            );
            (200, json!({"success": true}))
        }
        Err(Failure::Refused(_)) => error(404, "No such character."),
        Err(e) => store_down("delete character", &e),
    }
}

async fn delete_account(app: &App, me: &Me, body: &Value) -> Reply {
    if !text(body, "confirm_username")
        .trim()
        .eq_ignore_ascii_case(&me.username)
    {
        return coded(
            400,
            "confirm_mismatch",
            "The account name you typed does not match.",
        );
    }
    if let Err(refused) = app.reauthenticate(me, text(body, "password")).await {
        return refused;
    }
    let roster = match app.roster(me.account).await {
        Ok(roster) => roster,
        Err(e) => return store_down("delete account", &e),
    };
    let (ids, names): (Vec<u64>, Vec<String>) = roster.into_iter().unzip();
    if !ids.is_empty()
        && !app
            .release_characters(&ids, &names, DELETE_BAR_SECONDS)
            .await
    {
        return coded(503, "still_playing", STILL_PLAYING);
    }
    if let Err(e) = app.delete_account(me.account).await {
        return store_down("delete account", &e);
    }
    app.state.lock().await.revoke_sessions(me.account);
    println!("[login] account {} deleted", me.account);
    (200, json!({"success": true}))
}

/// `--persist`: the roster from the persistence service.
async fn list_persist(client: &PersistClient, start_map: &str, account: u64) -> Reply {
    let roster = match client
        .call(|req| PersistMsg::Characters { req, account })
        .await
    {
        Ok(PersistReply::Characters { result: Ok(r), .. }) => r,
        Ok(other) => return unavailable("characters", &format!("{other:?}")),
        Err(e) => return unavailable("characters", &e),
    };
    let characters: Vec<Value> = roster
        .into_iter()
        .map(|c| {
            let look: Vec<Value> = c.look.iter().map(|(k, v)| json!([k, v])).collect();
            json!({
                "id": c.id,
                "name": c.name,
                "house": c.house,
                "level": c.level,
                "map": c.map.unwrap_or_else(|| start_map.to_owned()),
                "look": look,
            })
        })
        .collect();
    (200, json!({"success": true, "characters": characters}))
}

/// A new character's name, house and look as asked for.
type NewCharacter = (String, String, Vec<(String, f32)>);

/// The name, house and look of a new character from a create request, or
/// why it is refused.
fn new_character_parts(houses: &[String], body: &Value) -> Result<NewCharacter, Reply> {
    let name = text(body, "name").trim().to_owned();
    let house = text(body, "house").to_owned();
    if let Some(p) = name_problem(&name) {
        return Err(error(400, p));
    }
    if realm_filter::shared().name_refused(&name) {
        return Err(error(400, "That name is not available."));
    }
    if !houses.contains(&house) {
        return Err(error(400, "Unknown house."));
    }
    let raw: Vec<(String, f32)> = body["look"]
        .as_array()
        .map(|pairs| {
            pairs
                .iter()
                .filter_map(|p| Some((p[0].as_str()?.to_owned(), p[1].as_f64()? as f32)))
                .collect()
        })
        .unwrap_or_default();
    Ok((name, house, raw))
}

/// `--persist`: the persistence service makes the character in one
/// transaction (the count, the name, the id).
async fn create_persist(state: &Mutex<State>, account: u64, body: &Value) -> Reply {
    let (client, sheet) = {
        let s = state.lock().await;
        let Some(client) = s.persist.clone() else {
            return error(503, "Service unavailable.");
        };
        let (name, house, raw) = match new_character_parts(&s.houses, body) {
            Ok(parts) => parts,
            Err(refused) => return refused,
        };
        let mut sheet = s.rules.new_character(0, &name, &house);
        sheet.look = s.rules.looks.clean(&raw);
        (client, sheet)
    };
    let (name, house) = (sheet.name.clone(), sheet.house.clone());
    let max = MAX_CHARACTERS as u8;
    match client
        .call(|req| PersistMsg::CreateCharacter {
            req,
            account,
            sheet: Box::new(sheet),
            max,
        })
        .await
    {
        Ok(PersistReply::Created { result: Ok(id), .. }) => {
            println!("[login] account {account} made character {id}");
            (
                200,
                json!({"success": true, "character": {"id": id, "name": name, "house": house}}),
            )
        }
        Ok(PersistReply::Created { result: Err(e), .. }) => match e.as_str() {
            "full" => error(400, "Maximum 2 characters per account."),
            "taken" => error(409, "Character name already taken."),
            "no account" => error(401, "Not logged in."),
            _ => unavailable("create", &e),
        },
        Ok(other) => unavailable("create", &format!("{other:?}")),
        Err(e) => unavailable("create", &e),
    }
}

/// `--persist`: whether `account` owns `character`, and the map it is on.
async fn owned_map_persist(
    client: &PersistClient,
    account: u64,
    character: u64,
) -> Result<Option<Option<String>>, Reply> {
    match client
        .call(|req| PersistMsg::Owner { req, character })
        .await
    {
        Ok(PersistReply::Owner {
            result: Ok(Some(owner)),
            ..
        }) if owner == account => {}
        Ok(PersistReply::Owner { result: Ok(_), .. }) => return Ok(None),
        Ok(other) => return Err(unavailable("play", &format!("{other:?}"))),
        Err(e) => return Err(unavailable("play", &e)),
    }
    match client.call(|req| PersistMsg::Load { req, character }).await {
        Ok(PersistReply::Loaded {
            result: Ok(sheet), ..
        }) => Ok(Some(sheet.and_then(|s| s.place.map(|p| p.map)))),
        Ok(other) => Err(unavailable("play", &format!("{other:?}"))),
        Err(e) => Err(unavailable("play", &e)),
    }
}

fn list(state: &State, account: u64) -> Reply {
    let Some(a) = state.ledger.accounts.iter().find(|a| a.id == account) else {
        return error(401, "Not logged in.");
    };
    let characters: Vec<Value> = a
        .characters
        .iter()
        .filter_map(|(id, _)| state.load_sheet(*id))
        .map(|sheet: CharacterSheet| {
            let map = sheet
                .place
                .as_ref()
                .map_or_else(|| state.start_map.clone(), |p| p.map.clone());
            let look: Vec<Value> = sheet.look.iter().map(|(k, v)| json!([k, v])).collect();
            json!({
                "id": sheet.id,
                "name": sheet.name,
                "house": sheet.house,
                "level": sheet.level,
                "map": map,
                "look": look,
            })
        })
        .collect();
    (200, json!({"success": true, "characters": characters}))
}

fn create(state: &mut State, account: u64, body: &Value) -> Reply {
    let (name, house, raw) = match new_character_parts(&state.houses, body) {
        Ok(parts) => parts,
        Err(refused) => return refused,
    };
    let Some(index) = state.ledger.accounts.iter().position(|a| a.id == account) else {
        return error(401, "Not logged in.");
    };
    if state.ledger.accounts[index].characters.len() >= MAX_CHARACTERS {
        return error(400, "Maximum 2 characters per account.");
    }
    if state.name_taken(&name) {
        return error(409, "Character name already taken.");
    }
    state.ledger.next_character = state.ledger.next_character.max(FIRST_CHARACTER);
    let mut id = state.ledger.next_character;
    // Never over a character file that is already there.
    while state.sheet_path(id).exists() {
        id += 1;
    }
    state.ledger.next_character = id + 1;
    let mut sheet = state.rules.new_character(id, &name, &house);
    sheet.look = state.rules.looks.clean(&raw);
    let text = match serde_json::to_string_pretty(&sheet) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("[login] character {id}: {e}");
            return error(503, "Service unavailable.");
        }
    };
    if let Err(e) = write_atomic(&state.sheet_path(id), &text) {
        eprintln!("[login] character {id}: {e}");
        return error(503, "Service unavailable.");
    }
    state.ledger.accounts[index]
        .characters
        .push((id, name.clone()));
    state.save();
    println!("[login] account {account} made character {id}");
    (
        200,
        json!({"success": true, "character": {"id": id, "name": name, "house": house}}),
    )
}

/// The refusal for a banned account. A coordinator that cannot be asked
/// refuses nobody here: `/api/play` needs it anyway.
async fn banned(app: &App, account: u64) -> Option<Reply> {
    let asked = json!({"account": account});
    let (_, v) = app.admin("/admin/access", &asked, "POST").await?;
    (v["banned"] == true).then(|| ban_reply(&v))
}

fn ban_reply(v: &Value) -> Reply {
    (
        403,
        json!({
            "success": false,
            "error": "banned",
            "code": "banned",
            "reason": v["reason"],
            "until": v["until"],
        }),
    )
}

async fn play(app: &App, account: u64, body: &Value) -> Reply {
    if let Some(refused) = outdated(body) {
        return refused;
    }
    let state = &app.state;
    let character = body["character_id"].as_u64().unwrap_or(0);
    let persist = state.lock().await.persist.clone();
    let stored = match &persist {
        Some(client) => match owned_map_persist(client, account, character).await {
            Ok(owned) => owned,
            Err(refused) => return refused,
        },
        None => {
            let s = state.lock().await;
            let owns = s
                .ledger
                .accounts
                .iter()
                .any(|a| a.id == account && a.characters.iter().any(|(c, _)| *c == character));
            owns.then(|| {
                s.load_sheet(character)
                    .and_then(|sheet| sheet.place.map(|p| p.map))
            })
        }
    };
    let Some(map) = stored else {
        return error(404, "No such character.");
    };
    let start = state.lock().await.start_map.clone();
    let map = map.unwrap_or_else(|| start.clone());
    // The coordinator decides: bans, maintenance, the realm's and the map's
    // room, the line. A map that is not open sends the character to the start.
    let asked = json!({"account": account, "character": character, "map": map, "start": start});
    let unreachable = || {
        coded(
            503,
            "realm_unreachable",
            "The realm is not reachable right now.",
        )
    };
    let Some((200, answer)) = app.admin("/admin/admit", &asked, "POST").await else {
        return unreachable();
    };
    if answer["ok"] != true {
        return match answer["error"].as_str().unwrap_or("") {
            "maintenance" => coded(503, "maintenance", "maintenance"),
            "banned" => ban_reply(&answer),
            "realm_full" => (
                503,
                json!({
                    "success": false,
                    "error": "realm_full",
                    "code": "realm_full",
                    "scope": answer["scope"],
                    "position": answer["position"],
                    "queue": answer["queue"],
                    "retry_s": answer["retry_s"],
                }),
            ),
            _ => unreachable(),
        };
    }
    let (Some(map), Some(address)) = (answer["map"].as_str(), answer["address"].as_str()) else {
        return unreachable();
    };
    let (map, address) = (map.to_owned(), address.to_owned());
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let s = state.lock().await;
    let Ok(ticket) = Ticket::new(account, character, now + TICKET_SECONDS) else {
        return error(503, "Service unavailable.");
    };
    let signed = ticket.sign(&s.key);
    println!(
        "[login] account {account} character {character}: ticket for {map} at {address} ({TICKET_SECONDS} s)"
    );
    (
        200,
        json!({
            "success": true,
            "map": map,
            "address": address,
            "ticket": hex(&signed),
            "expires_in_seconds": TICKET_SECONDS,
        }),
    )
}

/// GET /api/status: what the launcher and the login card show. `state` and
/// `maintenance` stay the launcher's contract (either way the realm is
/// closed for now); `realm` tells a maintenance from a realm that cannot be
/// reached. Answers are shared for a few seconds, however many clients ask.
/// GET /api/health/realm, for an uptime monitor: 200 while players can get in
/// or the realm is down on purpose, 503 when something is wrong. (/api/health
/// only says this service is up: the deployment waits on that one.)
async fn realm_health(app: &App) -> Reply {
    let (_, status) = realm_status(app).await;
    let realm = status["realm"].as_str().unwrap_or("unreachable");
    let code = if matches!(realm, "open" | "full" | "maintenance") {
        200
    } else {
        503
    };
    (
        code,
        json!({
            "status": if code == 200 { "ok" } else { "problem" },
            "service": "realm",
            "realm": realm,
            "players": status["players"],
            "queue": status["queue"],
            "alerts": status["alerts"],
            "time": status["time"],
        }),
    )
}

async fn realm_status(app: &App) -> Reply {
    {
        let s = app.state.lock().await;
        if let Some((at, value)) = &s.status
            && at.elapsed() < STATUS_TTL
        {
            return (200, value.clone());
        }
    }
    let health = match app.admin("/admin/health", &json!({}), "GET").await {
        Some((200, v)) => v,
        _ => Value::Null,
    };
    let start = app.state.lock().await.start_map.clone();
    let start_up = health["maps_up"]
        .as_array()
        .is_some_and(|m| m.iter().any(|x| x == start.as_str()));
    let some_down = health["maps_down"]
        .as_array()
        .is_some_and(|m| !m.is_empty());
    let full = health["queue"].as_u64().unwrap_or(0) > 0
        || health["players"].as_u64().unwrap_or(0)
            >= health["realm_cap"].as_u64().unwrap_or(u64::MAX);
    let realm = if health.is_null() {
        "unreachable"
    } else if health["accepting"] != true {
        "maintenance"
    } else if !start_up || some_down || health["persist_ok"] != true {
        "degraded"
    } else if full {
        "full"
    } else {
        "open"
    };
    let open = matches!(realm, "open" | "full" | "degraded");
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let value = json!({
        "state": match realm {
            "degraded" => "DEGRADED",
            _ if open => "ONLINE",
            _ => "MAINTENANCE",
        },
        "realm": realm,
        "maintenance": !open,
        "reason": health["reason"],
        "players": health["players"],
        "capacity": health["realm_cap"],
        "queue": health["queue"],
        "alerts": health["alerts"].as_array().map_or(0, Vec::len),
        "message": if open { "Diyar açık." } else { "Diyar şu an bakımda." },
        // The launcher holds a release whose protocol range misses this.
        "protocol_version": realm_proto::PROTOCOL_VERSION.to_string(),
        "terms_version": legal::VERSION,
        "time": now,
    });
    app.state.lock().await.status = Some((Instant::now(), value.clone()));
    (200, value)
}

async fn route(app: &Arc<App>, who: Caller, req: Request) -> Reply {
    let path = req.path.as_str();
    match (req.method.as_str(), path) {
        ("GET", "/api/health") => (200, json!({"status": "ok", "service": "realm_login"})),
        ("GET", "/api/health/realm") => realm_health(app).await,
        ("GET", "/api/status") => realm_status(app).await,
        ("POST", "/api/register") => register(app, who, &req.body).await,
        ("POST", "/api/login") => login(app, who, &req.body).await,
        ("POST", "/api/account/recover") => recover(app, who, &req.body).await,
        (
            "POST",
            "/api/logout"
            | "/api/characters/list"
            | "/api/characters/create"
            | "/api/characters/delete"
            | "/api/play"
            | "/api/account/info"
            | "/api/account/accept-terms"
            | "/api/account/password"
            | "/api/account/recovery-code"
            | "/api/account/delete",
        ) => {
            let me = app.state.lock().await.session_of(req.bearer());
            let Some(me) = me else {
                return error(401, "Not logged in.");
            };
            let account = me.account;
            let body = &req.body;
            let state = &app.state;
            if !me.terms_ok
                && matches!(
                    path,
                    "/api/characters/list" | "/api/characters/create" | "/api/play"
                )
            {
                return coded(
                    403,
                    "terms_required",
                    "Accept the Terms of Service and Privacy Policy to continue.",
                );
            }
            match path {
                "/api/logout" => {
                    state.lock().await.sessions.remove(req.bearer());
                    (200, json!({"success": true}))
                }
                "/api/account/info" => account_info(app, &me).await,
                "/api/account/accept-terms" => accept_terms(app, &me, body).await,
                "/api/account/password" => change_password(app, &me, body).await,
                "/api/account/recovery-code" => new_recovery(app, &me, body).await,
                "/api/account/delete" => delete_account(app, &me, body).await,
                "/api/characters/delete" => delete_character(app, &me, body).await,
                "/api/characters/list" => {
                    let (persist, start_map) = {
                        let s = state.lock().await;
                        (s.persist.clone(), s.start_map.clone())
                    };
                    match persist {
                        Some(client) => list_persist(&client, &start_map, account).await,
                        None => list(&*state.lock().await, account),
                    }
                }
                "/api/characters/create" => {
                    if state.lock().await.persist.is_some() {
                        create_persist(state, account, body).await
                    } else {
                        create(&mut *state.lock().await, account, body)
                    }
                }
                _ => play(app, account, body).await,
            }
        }
        _ => error(404, "Not found."),
    }
}

async fn connection(mut stream: TcpStream, from: SocketAddr, app: Arc<App>) {
    let json_headers = [("Cache-Control", "no-store")];
    let req = match tokio::time::timeout(REQUEST_TIMEOUT, read_request(&mut stream)).await {
        Ok(Ok(r)) => r,
        Ok(Err((code, why))) => {
            let body = json!({"success": false, "error": why}).to_string();
            respond_raw(
                &mut stream,
                code,
                "application/json",
                &json_headers,
                body.as_bytes(),
            )
            .await;
            return;
        }
        Err(_) => return,
    };
    if req.method == "GET"
        && let Some(page) = legal::page(&req.path)
    {
        respond_raw(
            &mut stream,
            200,
            page.content_type,
            &[
                ("Cache-Control", "public, max-age=300"),
                ("X-Content-Type-Options", "nosniff"),
                ("Referrer-Policy", "no-referrer"),
                (
                    "Content-Security-Policy",
                    "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
                ),
            ],
            &page.body,
        )
        .await;
        return;
    }
    let who = Caller::new(from.ip(), req.header("x-forwarded-for"));
    let (code, body) = route(&app, who, req).await;
    respond_raw(
        &mut stream,
        code,
        "application/json",
        &json_headers,
        body.to_string().as_bytes(),
    )
    .await;
}

struct Options {
    bind: SocketAddr,
    keys: PathBuf,
    content: PathBuf,
    characters: PathBuf,
    accounts: Option<PathBuf>,
    /// The persistence service's address (None: the ledger and files).
    persist: Option<String>,
    coord_admin: String,
    start_map: String,
}

fn options() -> AnyResult<Options> {
    let mut o = Options {
        bind: "127.0.0.1:7950".parse()?,
        keys: PathBuf::from("keys"),
        content: PathBuf::from("content/data"),
        characters: PathBuf::new(),
        accounts: None,
        persist: None,
        coord_admin: "127.0.0.1:8082".to_owned(),
        start_map: "grounds".to_owned(),
    };
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        let value = it.next().ok_or_else(|| format!("{arg} needs a value"))?;
        match arg.as_str() {
            "--bind" => o.bind = value.parse()?,
            "--keys" => o.keys = PathBuf::from(value),
            "--content" => o.content = PathBuf::from(value),
            "--characters" => o.characters = PathBuf::from(value),
            "--accounts" => o.accounts = Some(PathBuf::from(value)),
            "--persist" => o.persist = Some(value.clone()),
            "--coord-admin" => o.coord_admin.clone_from(value),
            "--start-map" => o.start_map.clone_from(value),
            other => return Err(format!("unknown option {other}").into()),
        }
    }
    if o.persist.is_some() && (!o.characters.as_os_str().is_empty() || o.accounts.is_some()) {
        return Err(
            "--persist keeps accounts and characters: no --characters or --accounts".into(),
        );
    }
    if o.persist.is_none() && o.characters.as_os_str().is_empty() {
        return Err("--characters <dir> (or --persist <addr>) is required".into());
    }
    Ok(o)
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> AnyResult<()> {
    let o = options()?;
    let secret: [u8; 32] = std::fs::read(o.keys.join("ticket.key"))?
        .try_into()
        .map_err(|_| "ticket.key must be 32 bytes")?;
    let content = realm_data::Content::load(&o.content)?;
    let rules = Rules::from_content(&content)?;
    let houses: Vec<String> = content
        .file("houses.json")
        .and_then(|h| h.as_object())
        .map(|h| h.keys().filter(|k| !k.starts_with('_')).cloned().collect())
        .unwrap_or_default();
    let (persist, ledger, ledger_file) = if let Some(addr) = &o.persist {
        let service: [u8; 32] = std::fs::read(o.keys.join("coord.key"))?
            .try_into()
            .map_err(|_| "coord.key must be 32 bytes")?;
        (
            Some(PersistClient::start(addr.clone(), service)),
            Ledger::default(),
            PathBuf::new(),
        )
    } else {
        std::fs::create_dir_all(&o.characters)?;
        let ledger_file = o
            .accounts
            .clone()
            .unwrap_or_else(|| o.characters.join("accounts.json"));
        let ledger: Ledger = std::fs::read_to_string(&ledger_file)
            .ok()
            .map(|t| serde_json::from_str(&t))
            .transpose()?
            .unwrap_or_default();
        (None, ledger, ledger_file)
    };
    let service_token = std::env::var("REALM_SERVICE_TOKEN")
        .unwrap_or_default()
        .trim()
        .to_owned();
    if service_token.is_empty() {
        println!(
            "[login] REALM_SERVICE_TOKEN is empty: the realm's maps cannot be asked, nobody can play"
        );
    }
    let signups = std::env::var("REALM_SIGNUPS_PER_HOUR")
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(guard::SIGNUPS_GLOBAL_PER_HOUR);
    let kept = match &o.persist {
        Some(addr) => format!("accounts in the persistence service at {addr}"),
        None => format!("{} account(s)", ledger.accounts.len()),
    };
    println!(
        "[login] {kept}, houses {:?}, terms {}, at most {signups} new accounts an hour, listening on {}",
        houses,
        legal::VERSION,
        o.bind
    );
    let dummy_hash =
        tokio::task::spawn_blocking(|| hash_password("no account has this password")).await??;
    let app = Arc::new(App {
        state: Mutex::new(State {
            persist,
            ledger,
            ledger_file,
            characters: o.characters.clone(),
            sessions: HashMap::new(),
            guard: Guard::new(signups),
            rules: Arc::new(rules),
            houses,
            key: SigningKey::from_bytes(&secret),
            coord_admin: o.coord_admin.clone(),
            service_token,
            start_map: o.start_map.clone(),
            status: None,
        }),
        gate: HashGate::new(),
        dummy_hash,
    });
    let listener = TcpListener::bind(o.bind).await?;
    let slots = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    loop {
        let (stream, from) = listener.accept().await?;
        let Ok(permit) = slots.clone().try_acquire_owned() else {
            continue;
        };
        let app = app.clone();
        tokio::spawn(async move {
            connection(stream, from, app).await;
            drop(permit);
        });
    }
}
