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
