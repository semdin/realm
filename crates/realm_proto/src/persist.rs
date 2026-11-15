//! Map servers, the login service and the coordinator and the persistence
//! service (`realm_persist`): one TCP stream each, framed like the control
//! stream (a u32 length, then postcard), after a hello that proves the
//! caller holds the shared service key (keys/coord.key). Requests are
//! answered in order on the stream they came on, each with its `req`; a
//! caller may have several in flight.
//!
//! A reply's `Err` is a refusal the caller acts on ("taken", "full") or
//! the store's own failure (anything else: the caller answers "try later").
//! New variants go at the end: postcard numbers them in order.

use realm_rules::CharacterSheet;
use serde::{Deserialize, Serialize};

use crate::coord::Board;

#[cfg(feature = "client")]
pub mod client;

/// An account as the login service checks a password against it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountRow {
    pub id: u64,
    pub username: String,
    /// The argon2id PHC string.
    pub hash: String,
}

/// A character as an account's roster shows it (read from its sheet).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CharacterSummary {
    pub id: u64,
    pub name: String,
    pub house: String,
    pub level: u16,
    /// None: never placed (the start map).
    pub map: Option<String>,
    pub look: Vec<(String, f32)>,
}

/// The persistence service's numbers (`PersistMsg::Stats`), for the
/// coordinator's metrics. Counts run since the service started; the save
/// latencies are the commits of the last minute.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct PersistStats {
    pub uptime_s: u64,
    /// Callers linked right now (each map server, the login service, the
    /// coordinator's two links: its changes and these numbers).
    pub callers: u32,
    pub loads: u64,
    /// Saves committed.
    pub saves: u64,
    /// Saves refused because the stored revision was newer.
    pub stale: u64,
    /// Requests the store failed (not refusals such as stale or taken).
    pub failures: u64,
    /// Saves committed in the last minute and their latency there.
    pub saves_last_minute: u32,
    pub save_p50_ms: f32,
    pub save_p99_ms: f32,
    pub save_max_ms: f32,
    /// `pg_database_size` of the realm's database.
    pub database_bytes: u64,
    pub characters: u64,
    pub accounts: u64,
    /// Why the database figures above are missing (empty: they are not).
    pub database_error: String,
}

/// Caller -> persistence service.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum PersistMsg {
    /// First frame: the shared service key.
    Hello { key: [u8; 32] },
    /// The stored sheet of `character` (None: never saved).
    Load { req: u64, character: u64 },
    /// Store `sheet` unless the stored copy is newer (a higher revision).
    Save {
        req: u64,
        sheet: Box<CharacterSheet>,
    },
    /// A new account (`hash` already argon2id) -> `Registered`; Err("taken")
    /// when the name is someone's, whatever the case.
    Register {
        req: u64,
        username: String,
        hash: String,
    },
    /// The account named `username`, whatever the case -> `Account`.
    FindAccount { req: u64, username: String },
    /// A login happened -> `Done`.
    TouchAccount { req: u64, account: u64 },
    /// An account's characters, oldest first -> `Characters`.
    Characters { req: u64, account: u64 },
    /// A new character for `account` -> `Created` with its id: one
    /// transaction that locks the account, refuses Err("full") at `max`
    /// characters and Err("taken") for a name a player's character has
    /// (whatever the case), and stores `sheet` under a fresh id.
    CreateCharacter {
        req: u64,
        account: u64,
        sheet: Box<CharacterSheet>,
        max: u8,
    },
    /// Whose `character` is -> `Owner` (None: nobody's, or none at all).
    Owner { req: u64, character: u64 },
    /// The weekly dungeon boards -> `Boards`.
    LoadBoards { req: u64 },
    /// Keep `board` (one per dungeon and difficulty) -> `Done`.
    SaveBoard { req: u64, board: Board },
    /// The game admins' names (lowercase) -> `Gas`.
    LoadGas { req: u64 },
    /// Make `name` a game admin or take it back -> `Done`.
    SetGa { req: u64, name: String, on: bool },
    /// The service's numbers -> `Stats`.
    Stats { req: u64 },
}

/// Persistence service -> caller.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum PersistReply {
    Loaded {
        req: u64,
        /// Err: the store could not answer (the caller refuses the join).
        result: Result<Option<Box<CharacterSheet>>, String>,
    },
    /// `ok`: the sheet is stored (committed). Not ok: `error` says why
    /// ("stale": the stored revision is newer; else the store failed).
    Saved {
        req: u64,
        character: u64,
        revision: u64,
        ok: bool,
        error: String,
    },
    Registered {
        req: u64,
        result: Result<u64, String>,
    },
    Account {
        req: u64,
        result: Result<Option<AccountRow>, String>,
    },
    /// The answer to a request that only has to land.
    Done {
        req: u64,
        result: Result<(), String>,
    },
    Characters {
        req: u64,
        result: Result<Vec<CharacterSummary>, String>,
    },
    Created {
        req: u64,
        result: Result<u64, String>,
    },
    Owner {
        req: u64,
        result: Result<Option<u64>, String>,
    },
    Boards {
        req: u64,
        result: Result<Vec<Board>, String>,
    },
    Gas {
        req: u64,
        result: Result<Vec<String>, String>,
    },
    Stats {
        req: u64,
        result: Result<PersistStats, String>,
    },
}

impl PersistMsg {
    pub fn req(&self) -> u64 {
        match self {
            Self::Hello { .. } => 0,
            Self::Load { req, .. }
            | Self::Save { req, .. }
            | Self::Register { req, .. }
            | Self::FindAccount { req, .. }
            | Self::TouchAccount { req, .. }
            | Self::Characters { req, .. }
            | Self::CreateCharacter { req, .. }
            | Self::Owner { req, .. }
            | Self::LoadBoards { req }
            | Self::SaveBoard { req, .. }
            | Self::LoadGas { req }
            | Self::SetGa { req, .. }
            | Self::Stats { req } => *req,
        }
    }
}

impl PersistReply {
    /// Why the request did not land (a refusal or the store's failure).
    pub fn error(&self) -> Option<&str> {
        fn of<T>(r: &Result<T, String>) -> Option<&str> {
            r.as_ref().err().map(String::as_str)
        }
        match self {
            Self::Saved {
                ok: false, error, ..
            } => Some(error),
            Self::Saved { .. } => None,
            Self::Loaded { result, .. } => of(result),
            Self::Registered { result, .. } | Self::Created { result, .. } => of(result),
            Self::Account { result, .. } => of(result),
            Self::Done { result, .. } => of(result),
            Self::Characters { result, .. } => of(result),
            Self::Owner { result, .. } => of(result),
            Self::Boards { result, .. } => of(result),
            Self::Gas { result, .. } => of(result),
            Self::Stats { result, .. } => of(result),
        }
    }

    pub fn req(&self) -> u64 {
        match self {
            Self::Loaded { req, .. }
            | Self::Saved { req, .. }
            | Self::Registered { req, .. }
            | Self::Account { req, .. }
            | Self::Done { req, .. }
            | Self::Characters { req, .. }
            | Self::Created { req, .. }
            | Self::Owner { req, .. }
            | Self::Boards { req, .. }
            | Self::Gas { req, .. }
            | Self::Stats { req, .. } => *req,
        }
    }
}

pub fn encode_msg(msg: &PersistMsg) -> Vec<u8> {
    crate::control::frame(&postcard::to_stdvec(msg).unwrap_or_default())
}

pub fn encode_reply(msg: &PersistReply) -> Vec<u8> {
    crate::control::frame(&postcard::to_stdvec(msg).unwrap_or_default())
}

pub fn decode_msg(payload: &[u8]) -> Result<PersistMsg, crate::control::FrameError> {
    postcard::from_bytes(payload).map_err(|_| crate::control::FrameError::Malformed)
}

pub fn decode_reply(payload: &[u8]) -> Result<PersistReply, crate::control::FrameError> {
    postcard::from_bytes(payload).map_err(|_| crate::control::FrameError::Malformed)
}
