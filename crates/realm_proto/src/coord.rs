//! Map servers and the coordinator. A map server holds one map; the
//! coordinator knows who is online where, keeps the parties and carries what
//! crosses maps (shouts, party lines, invitations, party views). They speak
//! over one TCP stream each way, framed like the control stream (a u32
//! length, then postcard), after a hello that proves the map server holds the shared
//! coordinator key.
//!
//! The coordinator also owns where every character is, so one character is
//! never in two worlds. A map server asks before it admits anyone
//! (`Claim`); the coordinator answers `Admit` (with the sheet when it holds
//! the newest one) or `Refuse`. A character on another map is first taken
//! out there (`Evict`). A map that lets a character go saves it, waits for
//! the save to land, and only then hands the sheet over (`Release`): to the
//! next claimant, or, when the character travels, held for the destination
//! map, with a fresh ticket for the client to join there (`Travel`). A
//! traveller first gets a seat on the destination (`Reserve`), so a full or
//! closed map is refused while the traveller still stands where it was.

use realm_rules::CharacterSheet;
use realm_rules::travel::Arrival;
use serde::{Deserialize, Serialize};

/// Chat channels (`ServerMsg::Chat`).
pub const CHANNEL_LOCAL: u8 = 0;
pub const CHANNEL_SHOUT: u8 = 1;
pub const CHANNEL_PARTY: u8 = 2;
pub const CHANNEL_SYSTEM: u8 = 3;

/// A chat line keeps at most this many characters.
pub const CHAT_MAX: usize = 200;
/// A party holds at most this many players.
pub const PARTY_MAX: usize = 5;

/// A chat line as it may be shown: control characters, line and paragraph
/// separators and bidirectional overrides become spaces, the ends are
/// trimmed, and it is cut to CHAT_MAX characters.
#[must_use]
pub fn clean_chat(raw: &str) -> String {
    let cleaned: String = raw
        .chars()
        .map(|c| {
            let bidi = matches!(c, '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}');
            if c.is_control() || c == '\u{2028}' || c == '\u{2029}' || bidi {
                ' '
            } else {
                c
            }
        })
        .collect();
    cleaned.trim().chars().take(CHAT_MAX).collect()
}

/// One member as the party frames show it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PartyMember {
    pub character: u64,
    pub name: String,
    pub house: String,
    pub level: u16,
    pub hp: u32,
    pub max_hp: u32,
    pub mana: u32,
    pub max_mana: u32,
    pub map: String,
    pub dead: bool,
}

/// A party as its members see it; `party` 0 = not in one.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PartyView {
    pub party: u64,
    pub leader: u64,
    pub members: Vec<PartyMember>,
}

/// A party request from a player.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum PartyCmd {
    Invite(String),
    Accept,
    Decline,
    Leave,
    Kick(String),
    Promote(String),
}

/// What opens a dungeon copy: the run's spec, fixed at the gate.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct RunSpec {
    pub dungeon: String,
    pub difficulty: u8,
    pub ref_level: u16,
    /// (character, name, level, rewarded, first run of the day)
    pub roster: Vec<(u64, String, u16, bool, bool)>,
    /// The week's curses this difficulty takes.
    #[serde(default)]
    pub affixes: Vec<String>,
}

/// A live copy as the gates see it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct RunSummary {
    pub map: String,
    pub copy: u8,
    pub dungeon: String,
    pub difficulty: u8,
    pub roster: Vec<u64>,
    pub complete: bool,
    pub forces: u32,
    pub forces_total: u32,
    /// Seconds until it closes (empty) or times out; -1 none.
    pub left_s: i32,
    /// Players inside.
    pub inside: u8,
}

/// One run on a weekly board: time, medal rank, deaths, the party
/// (name, level).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct BoardRun {
    pub ms: u32,
    pub rank: i8,
    pub deaths: u16,
    pub party: Vec<(String, u16)>,
}

/// A dungeon's fastest full clears at one difficulty this week (10 at most,
/// fastest first).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Board {
    pub dungeon: String,
    pub difficulty: u8,
    pub week: u32,
    pub runs: Vec<BoardRun>,
}

/// A map server's numbers over its last status window (5 s), sent with
/// every status line for the coordinator's metrics and operator panel.
/// The tick timings and bytes are the window's; the save counts are
/// cumulative since the map server started.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct MapStats {
    pub map: String,
    /// The window's length in milliseconds.
    pub window_ms: u32,
    pub players: u32,
    pub creatures: u32,
    /// Every replicated entity (players and creatures).
    pub entities: u32,
    pub tick_p50_ms: f32,
    pub tick_p99_ms: f32,
    pub tick_max_ms: f32,
    /// Ticks that overran their 33 ms slot this window.
    pub late_ticks: u32,
    /// Saves handed to the store and not yet answered.
    pub saves_in_flight: u32,
    /// Saves answered, and of those the ones that did not land.
    pub saves_done: u64,
    pub saves_failed: u64,
    /// Snapshot bytes sent to clients, per second over the window.
    pub bytes_out_per_s: u64,
    /// Resident memory of the process (0 where it is not known: off Linux).
    pub rss_bytes: u64,
}

/// Map server -> coordinator.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum MapMsg {
    /// First frame: the shared key, the map this server holds, the address
    /// clients reach it at and how many players it holds at most.
    Hello {
        key: [u8; 32],
        map: String,
        address: String,
        capacity: u16,
    },
    /// May `character` travel to `map`? Holds a seat there for a while.
    Reserve {
        character: u64,
        map: String,
    },
    /// Connection `conn` brings a ticket for `character`: may it play here?
    Claim {
        conn: u64,
        character: u64,
    },
    /// `character` left this map and its save has landed: here is the
    /// sheet. `arrival`: it travels there (it holds a seat).
    Release {
        character: u64,
        account: u64,
        sheet: Box<CharacterSheet>,
        arrival: Option<Arrival>,
    },
    /// An `Evict` named a character this map does not hold.
    Gone {
        character: u64,
    },
    /// A gate asks for a copy of the dungeon on `map`.
    OpenCopy {
        req: u64,
        map: String,
        spec: Box<RunSpec>,
    },
    /// A dungeon map's answer (copy 0: none free).
    CopyOpened {
        req: u64,
        copy: u8,
    },
    /// A dungeon map's live copies (sent whenever they change).
    Runs(Vec<RunSummary>),
    /// A full clear for the weekly board (`party`: character, name, level).
    RunRecord {
        dungeon: String,
        difficulty: u8,
        week: u32,
        run: BoardRun,
        characters: Vec<u64>,
    },
    /// A character came onto this map (or this server reconnected).
    Online {
        character: u64,
        name: String,
        house: String,
        level: u16,
    },
    /// What a party member's frame shows (sent while it is in a party).
    Vitals {
        character: u64,
        level: u16,
        hp: u32,
        max_hp: u32,
        mana: u32,
        max_mana: u32,
        dead: bool,
    },
    /// A shout (to the whole realm).
    Shout {
        from: u64,
        text: String,
    },
    /// A line to the speaker's party.
    PartyChat {
        from: u64,
        text: String,
    },
    Party {
        from: u64,
        cmd: PartyCmd,
    },
    /// The answer to `SaveAll`: every player here (and every one leaving)
    /// was saved, `failed` of them without the store confirming.
    Saved {
        barrier: u64,
        saved: u32,
        failed: u32,
    },
    /// The answer to `DisconnectAll`: nobody is left here and every
    /// leaver's seat was released (`removed` players were taken out).
    Emptied {
        barrier: u64,
        removed: u32,
    },
    /// A GA (`by`, checked here) makes `name` a GA or takes it back.
    Ga {
        by: u64,
        name: String,
        on: bool,
    },
    /// A GA (`by`, checked here) starts or stops the rain.
    Weather {
        by: u64,
        rain: bool,
    },
    /// A notice for the whole realm (a world boss, a Legendary gold).
    Announce(crate::control::ServerMsg),
    /// The map's numbers, every 5 s while linked (the coordinator's
    /// metrics). Appended last: postcard numbers variants in order.
    Stats(MapStats),
}

/// Coordinator -> map server.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum CoordMsg {
    /// Connection `conn` may bring `character` in: with `sheet` when the
    /// coordinator holds the newest one (else the map loads it), and where
    /// it lands when it travelled here.
    Admit {
        conn: u64,
        character: u64,
        sheet: Option<Box<CharacterSheet>>,
        arrival: Option<Arrival>,
    },
    Refuse {
        conn: u64,
        reason: String,
    },
    /// The answer to `Reserve` (reason: map_unavailable, map_full).
    Reserved {
        character: u64,
        ok: bool,
        reason: String,
    },
    /// Another login wants `character`: take it out of the world and
    /// release it.
    Evict {
        character: u64,
    },
    /// `character`, released to travel, joins `map` at `address` with
    /// `ticket`; tell its client.
    Travel {
        character: u64,
        map: String,
        address: String,
        ticket: Vec<u8>,
    },
    /// The maps open right now (sent whenever one comes or goes).
    Maps(Vec<String>),
    /// To a dungeon map: open a copy for this run.
    OpenCopy {
        req: u64,
        spec: Box<RunSpec>,
    },
    /// To the gate that asked: the copy (0: none free).
    CopyOpened {
        req: u64,
        copy: u8,
    },
    /// Every dungeon map's live copies.
    Runs(Vec<RunSummary>),
    /// This week's boards (sent whenever one changes, and on linking).
    Boards(Vec<Board>),
    /// A run took first place on its board: its party earns the record
    /// title (wherever they are) and the realm hears of it.
    RecordSet {
        dungeon: String,
        difficulty: u8,
        ms: u32,
        names: Vec<String>,
        characters: Vec<u64>,
    },
    /// A line for one character on this map.
    Line {
        to: u64,
        channel: u8,
        from: String,
        text: String,
    },
    /// A line for every player on this map (a shout).
    Broadcast {
        channel: u8,
        from: String,
        text: String,
    },
    /// `to` is invited into `from`'s party.
    Invite {
        to: u64,
        from: String,
    },
    /// `to`'s party as it now stands (empty: not in one).
    Party {
        to: u64,
        view: PartyView,
    },
    /// The realm's maintenance state (the old game's names: ONLINE,
    /// ANNOUNCING, DRAINING, SAVING, DISCONNECTING, MAINTENANCE, FAILED),
    /// why, and the seconds left of a countdown. Every player hears it.
    /// From SAVING on the world stands still; in MAINTENANCE it is idle.
    Maintenance {
        state: String,
        reason: String,
        seconds: u32,
    },
    /// Save every player now (and those leaving); answer `Saved`.
    SaveAll {
        barrier: u64,
    },
    /// Tell every player the realm is going down, take them all out (saved
    /// and released as any logout) and answer `Emptied`.
    DisconnectAll {
        barrier: u64,
    },
    /// A notice for every player on the map (ServerMsg::Notice): the
    /// realm's (a world boss anywhere, a Legendary gold, update_soon).
    Notice(crate::control::ServerMsg),
    /// The realm's game admins, by character name (lowercase); sent on
    /// linking and whenever it changes.
    Gas(Vec<String>),
    /// The realm's weather; sent on linking and whenever it changes.
    Weather {
        rain: bool,
    },
}

pub fn encode_map(msg: &MapMsg) -> Vec<u8> {
    crate::control::frame(&postcard::to_stdvec(msg).unwrap_or_default())
}

pub fn encode_coord(msg: &CoordMsg) -> Vec<u8> {
    crate::control::frame(&postcard::to_stdvec(msg).unwrap_or_default())
}

pub fn decode_map(payload: &[u8]) -> Result<MapMsg, crate::control::FrameError> {
    postcard::from_bytes(payload).map_err(|_| crate::control::FrameError::Malformed)
}

pub fn decode_coord(payload: &[u8]) -> Result<CoordMsg, crate::control::FrameError> {
    postcard::from_bytes(payload).map_err(|_| crate::control::FrameError::Malformed)
}
