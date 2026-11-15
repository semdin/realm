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
//! servers keep them in. Sessions and the failed-login waits are in memory
//! either way. The old game's rules, from its service contract:
//! account names 3-24 of [A-Za-z0-9_-], passwords of 8 or more with letters
//! and digits, argon2id; a session lasts 24 h, five at most per account
//! (the oldest goes); two characters per account; character names as
//! realm_rules::names, unique whatever the case; ten failed logins in five
//! minutes from one address or for one account wait.
//!
//! Where a character's map is (and whether the realm takes logins) comes
//! from the coordinator's admin surface (GET /admin/maps, with
//! REALM_SERVICE_TOKEN). Phase 7 puts the surface behind TLS; the requests
//! stay these:
//!
//!   POST /api/register          {username, password} -> {success, account_id}
//!   POST /api/login             {username, password} -> {success, account_id, username, token, expires_in_seconds}
//!   POST /api/logout            (Bearer)
//!   POST /api/characters/list   (Bearer) -> {characters: [{id, name, house, level, map, look}]}
//!   POST /api/characters/create (Bearer) {name, house, look} -> {character: {id, name, house}}
//!   POST /api/play              (Bearer) {character_id} -> {map, address, ticket (hex), expires_in_seconds}
//!   GET  /api/health
//!   GET  /api/status            -> {state: ONLINE|MAINTENANCE, maintenance, message} (the launcher)

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use argon2::Argon2;
use argon2::password_hash::phc::PasswordHash;
use argon2::password_hash::{PasswordHasher, PasswordVerifier};
use realm_http::{Request, read_request, respond};
use realm_proto::SigningKey;
use realm_proto::persist::client::PersistClient;
use realm_proto::persist::{PersistMsg, PersistReply};
use realm_proto::ticket::Ticket;
use realm_rules::names::{name_key, name_problem};
use realm_rules::{CharacterSheet, Rules};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, Semaphore};

type AnyResult<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

const SESSION_TTL: Duration = Duration::from_secs(24 * 3600);
const MAX_SESSIONS: usize = 5;
const MAX_CHARACTERS: usize = 2;
const TICKET_SECONDS: u64 = 60;
const FAIL_WINDOW: Duration = Duration::from_secs(5 * 60);
const FAIL_LIMIT: usize = 10;
const MAX_CONNECTIONS: usize = 32;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);
/// New characters are numbered from here (development characters below).
const FIRST_CHARACTER: u64 = 10_000_000;

#[derive(Clone, Serialize, Deserialize)]
struct Account {
    id: u64,
    name: String,
    hash: String,
    /// Its characters: (id, name).
    characters: Vec<(u64, String)>,
}

#[derive(Default, Serialize, Deserialize)]
struct Ledger {
    next_account: u64,
    next_character: u64,
    accounts: Vec<Account>,
}

struct Session {
    account: u64,
    expires: Instant,
    made: Instant,
}

struct State {
    /// The persistence service (None: the ledger and character files).
    persist: Option<Arc<PersistClient>>,
    ledger: Ledger,
    ledger_file: PathBuf,
    characters: PathBuf,
    sessions: HashMap<String, Session>,
    failures: HashMap<String, Vec<Instant>>,
    rules: Arc<Rules>,
    houses: Vec<String>,
    key: SigningKey,
    coord_admin: String,
    service_token: String,
    start_map: String,
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn token() -> Result<String, getrandom::Error> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes)?;
    Ok(hex(&bytes))
}

fn write_atomic(path: &Path, text: &str) -> std::io::Result<()> {
    let temp = path.with_extension("json.tmp");
    std::fs::write(&temp, text)?;
    std::fs::rename(&temp, path)
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

fn error(status: u16, message: &str) -> (u16, Value) {
    (status, json!({"success": false, "error": message}))
}

impl State {
    fn save(&self) {
        match serde_json::to_string_pretty(&self.ledger) {
            Ok(text) => {
                if let Err(e) = write_atomic(&self.ledger_file, &text) {
                    eprintln!(
                        "[login] cannot keep the accounts in {}: {e}",
                        self.ledger_file.display()
                    );
                }
            }
            Err(e) => eprintln!("[login] accounts: {e}"),
        }
    }

    fn account_of(&mut self, token: &str) -> Option<u64> {
        let now = Instant::now();
        self.sessions.retain(|_, s| s.expires > now);
        self.sessions.get(token).map(|s| s.account)
    }

    /// Failed logins from `ip` or for `name` inside the window.
    fn throttled(&mut self, ip: IpAddr, name: &str) -> bool {
        let now = Instant::now();
        let keys = [
            format!("ip:{ip}"),
            format!("account:{}", name.to_lowercase()),
        ];
        keys.iter().any(|k| {
            let list = self.failures.entry(k.clone()).or_default();
            list.retain(|t| now.duration_since(*t) < FAIL_WINDOW);
            list.len() >= FAIL_LIMIT
        })
    }

    fn failed(&mut self, ip: IpAddr, name: &str) {
        let now = Instant::now();
        for k in [
            format!("ip:{ip}"),
            format!("account:{}", name.to_lowercase()),
        ] {
            self.failures.entry(k).or_default().push(now);
        }
    }

    fn sheet_path(&self, id: u64) -> PathBuf {
        self.characters.join(format!("{id}.json"))
    }

    fn load_sheet(&self, id: u64) -> Option<CharacterSheet> {
        let text = std::fs::read_to_string(self.sheet_path(id)).ok()?;
        serde_json::from_str(&text).ok()
    }

    fn name_taken(&self, name: &str) -> bool {
        let key = name_key(name);
        self.ledger
            .accounts
            .iter()
            .flat_map(|a| a.characters.iter())
            .any(|(_, n)| name_key(n) == key)
    }
}

fn unavailable(what: &str, e: &str) -> (u16, Value) {
    eprintln!("[login] {what}: {e}");
    error(503, "Service unavailable.")
}

/// `--persist`: the account goes to the persistence service.
async fn register_persist(client: &PersistClient, body: &Value) -> (u16, Value) {
    let name = body["username"].as_str().unwrap_or("").trim().to_owned();
    let password = body["password"].as_str().unwrap_or("").to_owned();
    if let Some(p) = account_problem(&name).or_else(|| password_problem(&password)) {
        return error(400, p);
    }
    let hashed = tokio::task::spawn_blocking(move || {
        Argon2::default()
            .hash_password(password.as_bytes())
            .map(|h| h.to_string())
    })
    .await;
    let hash = match hashed {
        Ok(Ok(h)) => h,
        Ok(Err(e)) => return unavailable("hashing", &e.to_string()),
        Err(e) => return unavailable("hashing", &e.to_string()),
    };
    let username = name.clone();
    match client
        .call(|req| PersistMsg::Register {
            req,
            username,
            hash,
        })
        .await
    {
        Ok(PersistReply::Registered { result: Ok(id), .. }) => {
            println!("[login] account {id} registered");
            (200, json!({"success": true, "account_id": id}))
        }
        Ok(PersistReply::Registered { result: Err(e), .. }) if e == "taken" => {
            error(409, "That account name is taken.")
        }
        Ok(other) => unavailable("register", &format!("{other:?}")),
        Err(e) => unavailable("register", &e),
    }
}

fn register(state: &mut State, body: &Value) -> (u16, Value) {
    let name = body["username"].as_str().unwrap_or("").trim();
    let password = body["password"].as_str().unwrap_or("");
    if let Some(p) = account_problem(name).or_else(|| password_problem(password)) {
        return error(400, p);
    }
    if state
        .ledger
        .accounts
        .iter()
        .any(|a| a.name.eq_ignore_ascii_case(name))
    {
        return error(409, "That account name is taken.");
    }
    let hash = match Argon2::default().hash_password(password.as_bytes()) {
        Ok(h) => h.to_string(),
        Err(e) => {
            eprintln!("[login] hashing: {e}");
            return error(503, "Service unavailable.");
        }
    };
    state.ledger.next_account = state.ledger.next_account.max(1);
    let id = state.ledger.next_account;
    state.ledger.next_account += 1;
    state.ledger.accounts.push(Account {
        id,
        name: name.to_owned(),
        hash,
        characters: Vec::new(),
    });
    state.save();
    println!("[login] account {id} registered");
    (200, json!({"success": true, "account_id": id}))
}

async fn login(state: &Mutex<State>, ip: IpAddr, body: &Value) -> (u16, Value) {
    let name = body["username"].as_str().unwrap_or("").trim().to_owned();
    let password = body["password"].as_str().unwrap_or("").to_owned();
    let (found, persist) = {
        let mut s = state.lock().await;
        if s.throttled(ip, &name) {
            return error(429, "Too many failed logins. Try again in a few minutes.");
        }
        let found = s
            .ledger
            .accounts
            .iter()
            .find(|a| a.name.eq_ignore_ascii_case(&name))
            .map(|a| (a.id, a.name.clone(), a.hash.clone()));
        (found, s.persist.clone())
    };
    let found = match &persist {
        None => found,
        Some(client) => {
            let username = name.clone();
            match client
                .call(|req| PersistMsg::FindAccount { req, username })
                .await
            {
                Ok(PersistReply::Account {
                    result: Ok(row), ..
                }) => row.map(|a| (a.id, a.username, a.hash)),
                Ok(other) => return unavailable("login", &format!("{other:?}")),
                Err(e) => return unavailable("login", &e),
            }
        }
    };
    // Hashing takes a while: never under the lock.
    let verified = match &found {
        Some((_, _, hash)) => {
            let (hash, password) = (hash.clone(), password.clone());
            tokio::task::spawn_blocking(move || {
                PasswordHash::new(&hash).is_ok_and(|h| {
                    Argon2::default()
                        .verify_password(password.as_bytes(), &h)
                        .is_ok()
                })
            })
            .await
            .unwrap_or(false)
        }
        None => false,
    };
    let mut s = state.lock().await;
    let Some((account, username, _)) = found.filter(|_| verified) else {
        s.failed(ip, &name);
        return error(401, "Invalid username or password.");
    };
    let Ok(t) = token() else {
        return error(503, "Service unavailable.");
    };
    if let Some(client) = &persist {
        match client
            .call(|req| PersistMsg::TouchAccount { req, account })
            .await
        {
            Ok(PersistReply::Done { result: Ok(()), .. }) => {}
            Ok(other) => eprintln!("[login] last login of {account}: {other:?}"),
            Err(e) => eprintln!("[login] last login of {account}: {e}"),
        }
    }
    let now = Instant::now();
    s.sessions.retain(|_, x| x.expires > now);
    let mut mine: Vec<(String, Instant)> = s
        .sessions
        .iter()
        .filter(|(_, x)| x.account == account)
        .map(|(k, x)| (k.clone(), x.made))
        .collect();
    mine.sort_by_key(|(_, made)| *made);
    while mine.len() >= MAX_SESSIONS {
        let (oldest, _) = mine.remove(0);
        s.sessions.remove(&oldest);
    }
    s.sessions.insert(
        t.clone(),
        Session {
            account,
            expires: now + SESSION_TTL,
            made: now,
        },
    );
    (
        200,
        json!({
            "success": true,
            "account_id": account,
            "username": username,
            "token": t,
            "expires_in_seconds": SESSION_TTL.as_secs(),
        }),
    )
}

/// `--persist`: the roster from the persistence service.
async fn list_persist(client: &PersistClient, start_map: &str, account: u64) -> (u16, Value) {
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
fn new_character_parts(houses: &[String], body: &Value) -> Result<NewCharacter, (u16, Value)> {
    let name = body["name"].as_str().unwrap_or("").trim().to_owned();
    let house = body["house"].as_str().unwrap_or("").to_owned();
    if let Some(p) = name_problem(&name) {
        return Err(error(400, p));
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
async fn create_persist(state: &Mutex<State>, account: u64, body: &Value) -> (u16, Value) {
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
) -> Result<Option<Option<String>>, (u16, Value)> {
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

fn list(state: &State, account: u64) -> (u16, Value) {
    let Some(a) = state.ledger.accounts.iter().find(|a| a.id == account) else {
        return error(401, "Not logged in.");
    };
    let characters: Vec<Value> = a
        .characters
        .iter()
        .filter_map(|(id, _)| state.load_sheet(*id))
        .map(|sheet| {
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

fn create(state: &mut State, account: u64, body: &Value) -> (u16, Value) {
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

async fn play(state: &Mutex<State>, account: u64, body: &Value) -> (u16, Value) {
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
    let (start, admin, service_token) = {
        let s = state.lock().await;
        (
            s.start_map.clone(),
            s.coord_admin.clone(),
            s.service_token.clone(),
        )
    };
    let map = map.unwrap_or_else(|| start.clone());
    let maps = match realm_http::call(
        &admin,
        "GET",
        "/admin/maps",
        &[("x-service-token", &service_token)],
        &json!({}),
    )
    .await
    {
        Ok((200, v)) => v,
        _ => return error(503, "The realm is not reachable right now."),
    };
    if maps["accepting"] != true {
        return (503, json!({"success": false, "error": "maintenance"}));
    }
    let address_of = |name: &str| {
        maps["maps"].as_array().and_then(|list| {
            list.iter()
                .find(|m| m["map"] == name)
                .and_then(|m| m["address"].as_str().map(str::to_owned))
        })
    };
    // A map that is not open (a dungeon whose server is down) sends the
    // character to the start map.
    let (map, address) = match address_of(&map) {
        Some(a) => (map, a),
        None => match address_of(&start) {
            Some(a) => (start, a),
            None => return error(503, "The realm is not reachable right now."),
        },
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let s = state.lock().await;
    let Ok(ticket) = Ticket::new(account, character, now + TICKET_SECONDS) else {
        return error(503, "Service unavailable.");
    };
    let signed = ticket.sign(&s.key);
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

/// GET /api/status: what the launcher shows before play (its contract from
/// the old service: `state` ONLINE or MAINTENANCE, `maintenance`, `message`).
/// The realm is open while the coordinator takes logins; a coordinator in a
/// maintenance cycle, or one that cannot be reached, is "maintenance" to a
/// player - either way the realm is closed for now.
async fn realm_status(state: &Mutex<State>) -> (u16, Value) {
    let (admin, token) = {
        let s = state.lock().await;
        (s.coord_admin.clone(), s.service_token.clone())
    };
    let open = matches!(
        realm_http::call(&admin, "GET", "/admin/maps", &[("x-service-token", &token)], &json!({})).await,
        Ok((200, v)) if v["accepting"] == true
    );
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    (
        200,
        json!({
            "state": if open { "ONLINE" } else { "MAINTENANCE" },
            "maintenance": !open,
            "message": if open { "Diyar açık." } else { "Diyar şu an bakımda." },
            "time": now,
        }),
    )
}

async fn route(state: &Mutex<State>, ip: IpAddr, req: Request) -> (u16, Value) {
    let path = req.path.as_str();
    match (req.method.as_str(), path) {
        ("GET", "/api/health") => (200, json!({"status": "ok", "service": "realm_login"})),
        ("GET", "/api/status") => realm_status(state).await,
        ("POST", "/api/register") => {
            let persist = state.lock().await.persist.clone();
            match persist {
                Some(client) => register_persist(&client, &req.body).await,
                None => register(&mut *state.lock().await, &req.body),
            }
        }
        ("POST", "/api/login") => login(state, ip, &req.body).await,
        (
            "POST",
            "/api/logout" | "/api/characters/list" | "/api/characters/create" | "/api/play",
        ) => {
            let account = state.lock().await.account_of(req.bearer());
            let Some(account) = account else {
                return error(401, "Not logged in.");
            };
            match path {
                "/api/logout" => {
                    state.lock().await.sessions.remove(req.bearer());
                    (200, json!({"success": true}))
                }
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
                        create_persist(state, account, &req.body).await
                    } else {
                        create(&mut *state.lock().await, account, &req.body)
                    }
                }
                _ => play(state, account, &req.body).await,
            }
        }
        _ => error(404, "Not found."),
    }
}

async fn connection(mut stream: TcpStream, from: SocketAddr, state: Arc<Mutex<State>>) {
    let req = match tokio::time::timeout(REQUEST_TIMEOUT, read_request(&mut stream)).await {
        Ok(Ok(r)) => r,
        Ok(Err((code, why))) => {
            respond(&mut stream, code, &json!({"success": false, "error": why})).await;
            return;
        }
        Err(_) => return,
    };
    let ip = client_ip(from.ip(), req.header("x-forwarded-for"));
    let (code, body) = route(&state, ip, req).await;
    respond(&mut stream, code, &body).await;
}

/// The player's address for the failed-login waits. Behind the TLS proxy
/// (Caddy, on this host) every request comes from loopback, so there the
/// last X-Forwarded-For entry - the one the proxy itself added - is the
/// player; Caddy drops what a player sent in that header. From anywhere
/// else the header is the caller's own word and is ignored.
fn client_ip(peer: IpAddr, forwarded: &str) -> IpAddr {
    if !peer.is_loopback() {
        return peer;
    }
    forwarded
        .rsplit(',')
        .next()
        .and_then(|last| last.trim().parse().ok())
        .unwrap_or(peer)
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
    let kept = match &o.persist {
        Some(addr) => format!("accounts in the persistence service at {addr}"),
        None => format!("{} account(s)", ledger.accounts.len()),
    };
    println!(
        "[login] {kept}, houses {:?}, listening on {}",
        houses, o.bind
    );
    let state = Arc::new(Mutex::new(State {
        persist,
        ledger,
        ledger_file,
        characters: o.characters.clone(),
        sessions: HashMap::new(),
        failures: HashMap::new(),
        rules: Arc::new(rules),
        houses,
        key: SigningKey::from_bytes(&secret),
        coord_admin: o.coord_admin.clone(),
        service_token,
        start_map: o.start_map.clone(),
    }));
    let listener = TcpListener::bind(o.bind).await?;
    let slots = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    loop {
        let (stream, from) = listener.accept().await?;
        let Ok(permit) = slots.clone().try_acquire_owned() else {
            continue;
        };
        let state = state.clone();
        tokio::spawn(async move {
            connection(stream, from, state).await;
            drop(permit);
        });
    }
}
