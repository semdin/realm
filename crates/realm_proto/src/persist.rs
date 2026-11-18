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

use std::collections::HashSet;

use realm_rules::CharacterSheet;
use serde::{Deserialize, Serialize};

use crate::coord::Board;
use realm_rules::names::name_key;

#[cfg(feature = "client")]
pub mod client;

/// Characters the login service makes are numbered from here. They are only
/// ever born in `CreateCharacter`: a save or a join for one with no stored
/// row (it was deleted) brings nothing back. Development characters, which
/// have no account, live below and are made by their first save.
pub const FIRST_PLAYER_CHARACTER: u64 = 10_000_000;

/// What a weekly board shows in place of a deleted character's name.
pub const DELETED_NAME: &str = "—";

/// Blanks the names whose `name_key` is in `keys` on `board`; true when one
/// was there. The run itself stays.
pub fn forget_board_names(board: &mut Board, keys: &HashSet<String>) -> bool {
    let mut changed = false;
    for (name, _) in board.runs.iter_mut().flat_map(|r| r.party.iter_mut()) {
        if keys.contains(&name_key(name)) {
            DELETED_NAME.clone_into(name);
            changed = true;
        }
    }
    changed
}

/// An account as the login service checks a password against it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountRow {
    pub id: u64,
    pub username: String,
    /// The argon2id PHC string.
    pub hash: String,
    /// The version of the terms it last accepted (None: never).
    pub terms_version: Option<String>,
    /// The hash of its one-time recovery code (None: it has none yet).
    pub recovery_hash: Option<String>,
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

/// What stands against an account: `kind` "ban" or "mute", `until` the Unix
/// second it ends (0: permanent).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SanctionRow {
    pub account: u64,
    pub kind: String,
    pub until: u64,
    pub reason: String,
    pub by: String,
    pub at: u64,
}

/// `account` does not want to hear from `blocked` (known as `name`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct BlockRow {
    pub account: u64,
    pub blocked: u64,
    pub name: String,
}

/// A player's report. `context` is a JSON array of the chat around it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReportRow {
    pub id: u64,
    pub at: u64,
    pub reporter_account: u64,
    pub reporter_character: u64,
    pub reporter_name: String,
    pub target_account: u64,
    pub target_character: u64,
    pub target_name: String,
    pub category: String,
    pub text: String,
    pub map: String,
    pub context: String,
    pub status: String,
}

/// A player's character and its account.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CharacterRef {
    pub character: u64,
    pub account: u64,
    pub name: String,
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
    /// A new account (`hash` already argon2id), its recovery code's hash and
    /// the terms version it accepted, age confirmed -> `Registered`;
    /// Err("taken") when the name is someone's, whatever the case.
    Register {
        req: u64,
        username: String,
        hash: String,
        recovery_hash: String,
        terms_version: String,
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
    /// The old list of game admins by name (lowercase) -> `Gas`. GA rights
    /// now come from REALM_GA_ACCOUNTS; nothing asks for this any more.
    LoadGas { req: u64 },
    /// Changes that old list -> `Done`. Unused, like `LoadGas`.
    SetGa { req: u64, name: String, on: bool },
    /// The service's numbers -> `Stats`.
    Stats { req: u64 },
    /// Live sanctions and every block -> `Moderation`.
    LoadModeration { req: u64 },
    /// Keep a sanction (one per account and kind) -> `Done`.
    SetSanction { req: u64, row: SanctionRow },
    /// Lift a sanction -> `Done`.
    ClearSanction {
        req: u64,
        account: u64,
        kind: String,
    },
    /// Keep or drop a block -> `Done`.
    SetBlock { req: u64, row: BlockRow, on: bool },
    /// Keep a report -> `Done`.
    AddReport { req: u64, row: ReportRow },
    /// The newest reports -> `Reports`.
    LoadReports {
        req: u64,
        limit: u32,
        open_only: bool,
    },
    /// Set a report's status -> `Done`.
    CloseReport { req: u64, id: u64, status: String },
    /// One line of the audit trail (`detail`: a JSON object) -> `Done`.
    Audit {
        req: u64,
        character: Option<u64>,
        kind: String,
        detail: String,
    },
    /// The player's character called `name`, whatever the case -> `Character`.
    FindCharacter { req: u64, name: String },
    /// `account` accepted the terms `version` and confirmed its age -> `Done`.
    AcceptTerms {
        req: u64,
        account: u64,
        version: String,
    },
    /// A new password hash -> `Done`; Err("no account").
    SetPassword {
        req: u64,
        account: u64,
        hash: String,
    },
    /// A new recovery code's hash -> `Done`; Err("no account").
    SetRecovery {
        req: u64,
        account: u64,
        recovery_hash: String,
    },
    /// A recovery code was used: the new password and the code that replaces
    /// it, only while `used` is still the stored code -> `Done`; Err("stale")
    /// when it is not (each code works once).
    Recover {
        req: u64,
        account: u64,
        used: String,
        hash: String,
        recovery_hash: String,
    },
    /// Deletes `account`'s `character` in one transaction, its name off the
    /// weekly boards -> `Done`; Err("no character") when it has none such.
    DeleteCharacter {
        req: u64,
        account: u64,
        character: u64,
    },
    /// Deletes `account` and all its characters the same way -> `Done`;
    /// Err("no account").
    DeleteAccount { req: u64, account: u64 },
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
    Moderation {
        req: u64,
        result: Result<(Vec<SanctionRow>, Vec<BlockRow>), String>,
    },
    Reports {
        req: u64,
        result: Result<Vec<ReportRow>, String>,
    },
    Character {
        req: u64,
        result: Result<Option<CharacterRef>, String>,
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
            | Self::LoadModeration { req }
            | Self::SetSanction { req, .. }
            | Self::ClearSanction { req, .. }
            | Self::SetBlock { req, .. }
            | Self::AddReport { req, .. }
            | Self::LoadReports { req, .. }
            | Self::CloseReport { req, .. }
            | Self::Audit { req, .. }
            | Self::FindCharacter { req, .. }
            | Self::Stats { req }
            | Self::AcceptTerms { req, .. }
            | Self::SetPassword { req, .. }
            | Self::SetRecovery { req, .. }
            | Self::Recover { req, .. }
            | Self::DeleteCharacter { req, .. }
            | Self::DeleteAccount { req, .. } => *req,
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
            Self::Moderation { result, .. } => of(result),
            Self::Reports { result, .. } => of(result),
            Self::Character { result, .. } => of(result),
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
            | Self::Moderation { req, .. }
            | Self::Reports { req, .. }
            | Self::Character { req, .. }
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
