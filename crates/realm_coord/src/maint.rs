//! The realm's maintenance and the admin surface that drives it.
//!
//! State machine (the old game's names, part of the contract: the
//! deployment controller and the launcher poll GET /admin/status):
//!
//!   ONLINE -> ANNOUNCING -> DRAINING -> SAVING -> DISCONNECTING -> MAINTENANCE
//!                 |            |
//!                 +-- ABORTED -+ -> ONLINE        (only before SAVING starts)
//!                              SAVING / DISCONNECTING -> FAILED (a barrier
//!                              did not confirm); abort from FAILED -> ONLINE
//!
//! From ANNOUNCING on no login is admitted (travellers still arrive until
//! SAVING). SAVING freezes every map and saves every player there; the
//! cycle goes on only when each map confirmed each save. DISCONNECTING
//! takes everyone out as a logout and goes on when no seat is left. In
//! MAINTENANCE the maps are idle and this surface keeps answering.
//!
//! The surface is a small HTTP/1.1 server bound to a loopback address only,
//! one request per connection, size-capped and timed out, and it does not
//! start at all without REALM_SERVICE_TOKEN (the `x-service-token` header
//! must match): an unauthenticated maintenance surface must not exist.
//!
//! Endpoints (token required unless said otherwise):
//!
//!   GET  /admin/status (/admin/state)   the cycle's state and history
//!   GET  /admin/maps                    open maps and their addresses (login)
//!   GET  /admin/metrics                 the realm's numbers as JSON: state,
//!                                       release, uptime, players, seats in
//!                                       transit, parties, every map (linked
//!                                       or not, age of its last numbers,
//!                                       the numbers, 5 min of players and
//!                                       tick p99) and the persistence
//!                                       service (metrics.rs)
//!   GET  /admin/metrics.prom            the same numbers as Prometheus text
//!   GET  /panel                         the operator panel, WITHOUT a token:
//!                                       a static page holding no data that
//!                                       reads the token from `#token=...`
//!                                       and polls /admin/metrics with it
//!   POST /admin/maintenance/begin|abort, /admin/save, /admin/disconnect-all,
//!        /admin/ga, /admin/announce     the cycle, barriers, GAs, notices

use std::collections::{HashSet, VecDeque};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use realm_http::{Request, read_request, respond, respond_raw, same};
use realm_proto::PROTOCOL_VERSION;
use realm_proto::coord::CoordMsg;
use serde_json::{Value, json};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, Semaphore, oneshot};

use crate::{Book, Seat, metrics};

const DEFAULT_COUNTDOWN_S: f64 = 300.0;
/// Announcements come this often, and this often in the last seconds.
const URGENT_ANNOUNCE: Duration = Duration::from_secs(3);
const URGENT_REMAINING_S: u64 = 15;
/// A barrier (every map saved, every map emptied) is waited for this long.
const BARRIER_TIMEOUT: Duration = Duration::from_secs(15);
const HISTORY_LIMIT: usize = 24;
const REASON_MAX: usize = 200;
const MAX_CONNECTIONS: usize = 8;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);
/// A request waiting on a barrier gives up after this long.
const DEFERRED_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum State {
    #[default]
    Online,
    Announcing,
    Draining,
    Saving,
    Disconnecting,
    Maintenance,
    Aborted,
    Failed,
}

impl State {
    pub fn name(self) -> &'static str {
        match self {
            State::Online => "ONLINE",
            State::Announcing => "ANNOUNCING",
            State::Draining => "DRAINING",
            State::Saving => "SAVING",
            State::Disconnecting => "DISCONNECTING",
            State::Maintenance => "MAINTENANCE",
            State::Aborted => "ABORTED",
            State::Failed => "FAILED",
        }
    }

    /// From SAVING on the maps stand still.
    pub fn frozen(self) -> bool {
        matches!(
            self,
            State::Saving | State::Disconnecting | State::Maintenance | State::Failed
        )
    }
}

/// Timings (flags of realm_coord).
#[derive(Clone, Debug)]
pub struct Settings {
    /// DRAINING lasts this long.
    pub drain: Duration,
    /// SAVING stands at least this long (a poller has to be able to see it).
    pub save_min: Duration,
    /// ANNOUNCING repeats itself this often.
    pub announce: Duration,
    /// The release this coordinator runs (REALM_RELEASE), for the status.
    pub release: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            drain: Duration::from_secs(10),
            save_min: Duration::from_millis(1000),
            announce: Duration::from_secs(10),
            release: String::new(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Save,
    Empty,
}

/// Every map's answer to one `SaveAll` or `DisconnectAll`.
struct Barrier {
    id: u64,
    kind: Kind,
    /// Links still to answer.
    waiting: HashSet<u64>,
    saved: u32,
    failed: u32,
    removed: u32,
    deadline: Instant,
    /// Requests of the admin surface waiting for the result.
    answers: Vec<oneshot::Sender<Value>>,
    /// The cycle's own barrier (SAVING, DISCONNECTING), or one asked alone.
    cycle: bool,
}

impl Barrier {
    fn done(&self) -> bool {
        self.waiting.is_empty()
    }

    fn result(&self) -> Value {
        match self.kind {
            Kind::Save => json!({
                "ok": self.failed == 0,
                "saved": self.saved,
                "failed": self.failed,
            }),
            Kind::Empty => json!({"ok": true, "disconnected": self.removed}),
        }
    }
}

#[derive(Default)]
pub struct Maint {
    pub state: State,
    reason: String,
    /// Unix ms the countdown ends at (0: none).
    deadline_ms: u64,
    deadline: Option<Instant>,
    history: VecDeque<(String, u64)>,
    last_announce: Option<Instant>,
    phase_until: Option<Instant>,
    saving_since: Option<Instant>,
    disconnect_since: Option<Instant>,
    /// The cycle's save barrier answered: (landed, failed).
    saved: Option<(u32, u32)>,
    /// The cycle's empty-out answered.
    emptied: bool,
    barriers: Vec<Barrier>,
    next_barrier: u64,
    boot: Option<Instant>,
    pub settings: Settings,
}

impl Maint {
    pub fn new(settings: Settings) -> Self {
        Self {
            settings,
            ..Self::default()
        }
    }

    /// Why the current cycle runs (empty while ONLINE).
    pub fn reason(&self) -> &str {
        &self.reason
    }

    /// Since the coordinator's clock started.
    pub fn uptime(&self) -> Duration {
        self.boot.map_or(Duration::ZERO, |b| b.elapsed())
    }
}

fn unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// Nothing that looks like a service token reaches a log line, even when
/// an operator pastes one into a reason.
fn redact(text: &str) -> String {
    text.split(' ')
        .map(|w| {
            let secret = w.len() >= 24
                && w.chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
            if secret { "***" } else { w }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

impl Book {
    fn set_state(&mut self, state: State) {
        self.maint.state = state;
        self.maint
            .history
            .push_back((state.name().to_owned(), unix_ms()));
        while self.maint.history.len() > HISTORY_LIMIT {
            self.maint.history.pop_front();
        }
        println!(
            "[maintenance] STATE {} (players={}, maps={})",
            state.name(),
            self.online.len(),
            self.links.len()
        );
    }

    fn remaining_s(&self) -> u64 {
        self.maint.deadline.map_or(0, |d| {
            d.saturating_duration_since(Instant::now())
                .as_secs_f64()
                .ceil() as u64
        })
    }

    /// Every map (and through it every player) hears the state.
    fn broadcast_state(&mut self, seconds: u64) {
        let msg = CoordMsg::Maintenance {
            state: self.maint.state.name().to_owned(),
            reason: self.maint.reason.clone(),
            seconds: seconds as u32,
        };
        for l in self.links.values() {
            let _ = l.tx.send(msg.clone());
        }
    }

    /// A map that links mid-cycle hears where the cycle stands.
    pub fn tell_maintenance(&self, link: u64) {
        if self.maint.state == State::Online {
            return;
        }
        self.to_link(
            link,
            CoordMsg::Maintenance {
                state: self.maint.state.name().to_owned(),
                reason: self.maint.reason.clone(),
                seconds: self.remaining_s() as u32,
            },
        );
    }

    /// May a claim come in now? Logins only while ONLINE; travellers until
    /// the world freezes.
    pub fn claim_allowed(&self, character: u64) -> bool {
        match self.maint.state {
            State::Online => true,
            State::Announcing | State::Draining => {
                matches!(self.seats.get(&character), Some(Seat::Transit { .. }))
            }
            _ => false,
        }
    }

    /// May a trip be reserved now?
    pub fn travel_allowed(&self) -> bool {
        !self.maint.state.frozen()
    }

    fn begin(&mut self, reason: String, countdown_s: f64) -> Value {
        if self.maint.state != State::Online {
            let state = self.maint.state.name();
            return json!({
                "ok": false,
                "error": "already_in_maintenance",
                "state": state,
                "message": format!("a maintenance cycle is already running (state {state})"),
            });
        }
        self.maint.reason = reason;
        self.maint.deadline = Some(Instant::now() + Duration::from_secs_f64(countdown_s));
        self.maint.deadline_ms = unix_ms() + (countdown_s * 1000.0) as u64;
        self.set_state(State::Announcing);
        self.announce();
        println!(
            "[maintenance] begins: '{}' countdown={}s players={}",
            redact(&self.maint.reason),
            countdown_s as u64,
            self.online.len()
        );
        json!({
            "ok": true,
            "state": self.maint.state.name(),
            "reason": self.maint.reason,
            "deadline_ms": self.maint.deadline_ms,
            "players": self.online.len(),
            "countdown_seconds": countdown_s,
        })
    }

    fn announce(&mut self) {
        self.maint.last_announce = Some(Instant::now());
        let left = self.remaining_s();
        self.broadcast_state(left);
    }

    fn abort(&mut self) -> Value {
        let previous = self.maint.state.name();
        match self.maint.state {
            State::Announcing | State::Draining | State::Failed => {
                if self.maint.state != State::Failed {
                    // ABORTED is the way out of the cycle: the realm lands
                    // back in ONLINE at once.
                    self.set_state(State::Aborted);
                }
                // A FAILED hold froze a realm whose barrier did not
                // confirm: the players are still there and the maps keep
                // trying their saves; an abort returns it to play.
                self.maint.barriers.retain(|b| !b.cycle);
                self.maint.deadline = None;
                self.maint.deadline_ms = 0;
                self.maint.reason.clear();
                self.set_state(State::Online);
                self.broadcast_state(0);
                println!("[maintenance] aborted from {previous}; the realm is ONLINE");
                json!({
                    "ok": true,
                    "state": "ONLINE",
                    "previous_state": previous,
                    "players": self.online.len(),
                })
            }
            State::Online => json!({
                "ok": false,
                "error": "not_in_maintenance",
                "state": previous,
                "message": "no maintenance cycle is running",
            }),
            // SAVING and after is past the point of no return: a save
            // followed by more play is not a final save.
            _ => json!({
                "ok": false,
                "error": "too_late",
                "state": previous,
                "message": format!(
                    "maintenance has passed the save barrier (state {previous}); abort is refused"
                ),
            }),
        }
    }

    fn start_barrier(&mut self, kind: Kind, cycle: bool, answer: Option<oneshot::Sender<Value>>) {
        self.maint.next_barrier += 1;
        let id = self.maint.next_barrier;
        let waiting: HashSet<u64> = self.links.keys().copied().collect();
        for l in &waiting {
            self.to_link(
                *l,
                match kind {
                    Kind::Save => CoordMsg::SaveAll { barrier: id },
                    Kind::Empty => CoordMsg::DisconnectAll { barrier: id },
                },
            );
        }
        self.maint.barriers.push(Barrier {
            id,
            kind,
            waiting,
            saved: 0,
            failed: 0,
            removed: 0,
            deadline: Instant::now() + BARRIER_TIMEOUT,
            answers: answer.into_iter().collect(),
            cycle,
        });
    }

    /// A map answered a barrier.
    pub fn barrier_answer(&mut self, link: u64, id: u64, saved: u32, failed: u32, removed: u32) {
        if let Some(b) = self.maint.barriers.iter_mut().find(|b| b.id == id)
            && b.waiting.remove(&link)
        {
            b.saved += saved;
            b.failed += failed;
            b.removed += removed;
        }
    }

    /// A map went away: it answers nothing more. Its players' last saves
    /// are unconfirmed, so a save barrier counts it failed.
    pub fn barrier_link_gone(&mut self, link: u64) {
        for b in &mut self.maint.barriers {
            if b.waiting.remove(&link) && b.kind == Kind::Save {
                b.failed += 1;
            }
        }
    }

    fn fail(&mut self, why: String) {
        self.set_state(State::Failed);
        self.maint.deadline = None;
        self.maint.deadline_ms = 0;
        self.broadcast_state(0);
        eprintln!("[maintenance] FAILED: {why}");
        println!(
            "[maintenance] FAILED is a safe hold: players stay connected, logins stay refused, no release may proceed"
        );
    }

    /// Runs the cycle (every 100 ms, on wall time).
    pub fn maint_tick(&mut self) {
        let now = Instant::now();
        // Barriers answered or timed out.
        let mut finished = Vec::new();
        let mut k = 0;
        while k < self.maint.barriers.len() {
            let b = &mut self.maint.barriers[k];
            if !b.done() && now >= b.deadline {
                if b.kind == Kind::Save {
                    b.failed += b.waiting.len() as u32;
                }
                b.waiting.clear();
            }
            if b.done() {
                finished.push(self.maint.barriers.remove(k));
            } else {
                k += 1;
            }
        }
        let mut cycle_done: Option<Barrier> = None;
        for mut b in finished {
            let result = b.result();
            for a in b.answers.drain(..) {
                let _ = a.send(result.clone());
            }
            if b.cycle {
                cycle_done = Some(b);
            }
        }
        match self.maint.state {
            State::Announcing => {
                if self.remaining_s() == 0 {
                    self.set_state(State::Draining);
                    self.maint.phase_until = Some(now + self.maint.settings.drain);
                    self.broadcast_state(0);
                    return;
                }
                let interval = if self.remaining_s() <= URGENT_REMAINING_S {
                    URGENT_ANNOUNCE.min(self.maint.settings.announce)
                } else {
                    self.maint.settings.announce
                };
                if self
                    .maint
                    .last_announce
                    .is_none_or(|at| now.duration_since(at) >= interval)
                {
                    self.announce();
                }
            }
            State::Draining => {
                if self.maint.phase_until.is_some_and(|t| now >= t) {
                    self.set_state(State::Saving);
                    self.maint.saving_since = Some(now);
                    // The maps freeze first, then save: nothing changes
                    // after the final save.
                    self.broadcast_state(0);
                    self.start_barrier(Kind::Save, true, None);
                }
            }
            State::Saving => {
                if let Some(b) = cycle_done {
                    self.maint.saved = Some((b.saved, b.failed));
                }
                let Some((saved, failed)) = self.maint.saved else {
                    return;
                };
                if self
                    .maint
                    .saving_since
                    .is_some_and(|t| now.duration_since(t) < self.maint.settings.save_min)
                {
                    return;
                }
                self.maint.saved = None;
                if failed > 0 {
                    self.fail(format!(
                        "the save barrier did not confirm {failed} save(s) ({saved} landed)"
                    ));
                    return;
                }
                println!("[maintenance] save barrier: {saved} save(s) landed");
                self.set_state(State::Disconnecting);
                self.maint.disconnect_since = Some(now);
                self.broadcast_state(0);
                self.start_barrier(Kind::Empty, true, None);
            }
            State::Disconnecting => {
                if cycle_done.is_some() {
                    self.maint.emptied = true;
                }
                if !self.maint.emptied {
                    return;
                }
                let seated = self
                    .seats
                    .values()
                    .filter(|s| matches!(s, Seat::On { .. }))
                    .count();
                if seated > 0 {
                    if self
                        .maint
                        .disconnect_since
                        .is_some_and(|t| now.duration_since(t) > BARRIER_TIMEOUT * 2)
                    {
                        self.maint.emptied = false;
                        self.fail(format!("{seated} seat(s) survived the disconnect barrier"));
                    }
                    return;
                }
                self.maint.emptied = false;
                self.set_state(State::Maintenance);
                self.maint.deadline = None;
                self.maint.deadline_ms = 0;
                self.broadcast_state(0);
                println!("[maintenance] MAINTENANCE: zero players, maps idle, status live");
            }
            _ => {}
        }
    }

    /// The maps open now and where clients reach them (the login service
    /// sends a player to its map with this).
    fn maps_view(&self) -> Value {
        let mut maps: Vec<Value> = self
            .links
            .iter()
            .map(|(id, l)| {
                let players = self
                    .seats
                    .values()
                    .filter(|s| matches!(s, Seat::On { link, .. } if link == id))
                    .count();
                json!({"map": l.map, "address": l.address, "capacity": l.capacity, "players": players})
            })
            .collect();
        maps.sort_by(|a, b| a["map"].as_str().cmp(&b["map"].as_str()));
        json!({"ok": true, "accepting": self.maint.state == State::Online, "maps": maps})
    }

    fn status(&self) -> Value {
        let mut maps: Vec<&str> = self.links.values().map(|l| l.map.as_str()).collect();
        maps.sort_unstable();
        let history: Vec<Value> = self
            .maint
            .history
            .iter()
            .map(|(s, at)| json!({"state": s, "at_ms": at}))
            .collect();
        let mut out = json!({
            "ok": true,
            "state": self.maint.state.name(),
            "reason": self.maint.reason,
            "deadline_ms": self.maint.deadline_ms,
            "players": self.online.len(),
            "maps": maps,
            "uptime_ms": self.maint.boot.map_or(0, |b| b.elapsed().as_millis() as u64),
            "protocol": PROTOCOL_VERSION,
            "frozen": self.maint.state.frozen(),
            "simulation_paused": self.maint.state == State::Maintenance,
            "history": history,
        });
        if !self.maint.settings.release.is_empty() {
            out["release"] = json!(self.maint.settings.release);
        }
        out
    }
}

/// Waits for a barrier's result.
async fn deferred(rx: oneshot::Receiver<Value>) -> (u16, Value) {
    match tokio::time::timeout(DEFERRED_TIMEOUT, rx).await {
        Ok(Ok(v)) => (200, v),
        _ => (504, json!({"ok": false, "error": "timeout"})),
    }
}

async fn route(req: Request, book: &Arc<Mutex<Book>>) -> (u16, Value) {
    let conflict = |v: Value| {
        let code = if v["ok"].as_bool() == Some(true) {
            200
        } else {
            409
        };
        (code, v)
    };
    match (req.method.as_str(), req.path.as_str()) {
        ("GET", "/admin/status" | "/admin/state") => (200, book.lock().await.status()),
        ("GET", "/admin/maps") => (200, book.lock().await.maps_view()),
        ("GET", "/admin/metrics") => (200, book.lock().await.metrics_view()),
        ("POST", "/admin/maintenance/begin") => {
            let mut reason: String = req.body["reason"]
                .as_str()
                .unwrap_or("")
                .trim()
                .chars()
                .take(REASON_MAX)
                .collect();
            if reason.is_empty() {
                reason = "scheduled maintenance".to_owned();
            }
            let countdown = req.body["countdown_seconds"]
                .as_f64()
                .unwrap_or(DEFAULT_COUNTDOWN_S)
                .clamp(0.0, 86_400.0);
            conflict(book.lock().await.begin(reason, countdown))
        }
        ("POST", "/admin/maintenance/abort") => conflict(book.lock().await.abort()),
        // `/admin/admin/save` was a typo in the old spec that shipped once;
        // the deployment controller may still call it.
        ("POST", "/admin/save" | "/admin/admin/save") => {
            let (tx, rx) = oneshot::channel();
            book.lock().await.start_barrier(Kind::Save, false, Some(tx));
            deferred(rx).await
        }
        ("POST", "/admin/disconnect-all") => {
            let (tx, rx) = oneshot::channel();
            book.lock()
                .await
                .start_barrier(Kind::Empty, false, Some(tx));
            deferred(rx).await
        }
        ("POST", "/admin/ga") => book.lock().await.admin_ga(&req.body),
        ("POST", "/admin/announce") => {
            if req.body["kind"].as_str() != Some("update_soon") {
                return (400, json!({"ok": false, "error": "unknown kind"}));
            }
            let b = book.lock().await;
            if b.maint.state != State::Online {
                return (
                    409,
                    json!({"ok": false, "error": "not_online", "state": b.maint.state.name()}),
                );
            }
            let minutes = req.body["minutes"].as_u64().unwrap_or(3).clamp(1, 60) as u32;
            for l in b.links.values() {
                let _ =
                    l.tx.send(CoordMsg::Notice(realm_proto::control::ServerMsg::Notice {
                        kind: "update_soon".to_owned(),
                        subject: String::new(),
                        actor: String::new(),
                        value: minutes,
                        of: 0,
                        place: String::new(),
                    }));
            }
            (200, json!({"ok": true, "minutes": minutes}))
        }
        _ => (404, json!({"ok": false, "error": "not_found"})),
    }
}

async fn connection(mut stream: TcpStream, token: Arc<String>, book: Arc<Mutex<Book>>) {
    let req = match tokio::time::timeout(REQUEST_TIMEOUT, read_request(&mut stream)).await {
        Ok(Ok(r)) => r,
        Ok(Err((code, why))) => {
            respond(&mut stream, code, &json!({"ok": false, "error": why})).await;
            return;
        }
        Err(_) => return,
    };
    if req.method == "GET" && req.path == "/panel" {
        // The page holds no data: it reads the token from its own address
        // and asks /admin/metrics with it. Nothing it loads comes from
        // anywhere else, and it is never cached.
        respond_raw(
            &mut stream,
            200,
            "text/html; charset=utf-8",
            &[
                ("Cache-Control", "no-store"),
                ("X-Content-Type-Options", "nosniff"),
                ("Referrer-Policy", "no-referrer"),
                (
                    "Content-Security-Policy",
                    "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
                ),
            ],
            metrics::PANEL_HTML.as_bytes(),
        )
        .await;
        return;
    }
    let given = req.header("x-service-token");
    if given.is_empty() || !same(given.as_bytes(), token.as_bytes()) {
        respond(
            &mut stream,
            403,
            &json!({"ok": false, "error": "forbidden"}),
        )
        .await;
        return;
    }
    if req.method == "GET" && req.path == "/admin/metrics.prom" {
        let view = book.lock().await.metrics_view();
        respond_raw(
            &mut stream,
            200,
            "text/plain; version=0.0.4; charset=utf-8",
            &[("Cache-Control", "no-store")],
            metrics::prometheus(&view).as_bytes(),
        )
        .await;
        return;
    }
    let (code, body) = route(req, &book).await;
    respond(&mut stream, code, &body).await;
}

/// Serves the admin surface on `bind` (a loopback address) with `token`.
pub async fn serve(bind: SocketAddr, token: String, book: Arc<Mutex<Book>>) {
    if token.is_empty() {
        // Loud and final: without a token anything on the host could drain
        // the realm. The coordinator itself keeps running.
        println!(
            "[admin] REFUSING TO START: REALM_SERVICE_TOKEN is empty - the admin surface stays closed"
        );
        return;
    }
    if !bind.ip().is_loopback() {
        println!("[admin] REFUSING TO START: {bind} is not a loopback address");
        return;
    }
    let listener = match TcpListener::bind(bind).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("[admin] cannot bind {bind}: {e} - maintenance surface unavailable");
            return;
        }
    };
    println!("[admin] maintenance surface on {bind} (service token required)");
    let token = Arc::new(token);
    let slots = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    loop {
        let Ok((stream, _)) = listener.accept().await else {
            continue;
        };
        let Ok(permit) = slots.clone().try_acquire_owned() else {
            // Too many at once: this one is closed unanswered.
            continue;
        };
        let (token, book) = (token.clone(), book.clone());
        tokio::spawn(async move {
            connection(stream, token, book).await;
            drop(permit);
        });
    }
}

/// The cycle's clock.
pub fn start_clock(book: Arc<Mutex<Book>>) {
    tokio::spawn(async move {
        book.lock().await.maint.boot = Some(Instant::now());
        let mut every = tokio::time::interval(Duration::from_millis(100));
        loop {
            every.tick().await;
            book.lock().await.maint_tick();
        }
    });
}
