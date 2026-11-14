//! Map servers and the coordinator. A map server holds one map; the
//! coordinator knows who is online where, keeps the parties and carries what
//! crosses maps (shouts, party lines, invitations, party views). They speak
//! over one TCP stream each way, framed like the control stream (a u32
//! length, then postcard), after a hello that proves the map server holds the shared
//! coordinator key.

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
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum MapMsg {
    /// First frame: the shared key and the map this server holds.
    Hello {
        key: [u8; 32],
        map: String,
    },
    /// A character came onto this map (or this server reconnected).
    Online {
        character: u64,
        name: String,
        house: String,
        level: u16,
    },
    Offline {
        character: u64,
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
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum CoordMsg {
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
    Invite { to: u64, from: String },
    /// `to`'s party as it now stands (empty: not in one).
    Party { to: u64, view: PartyView },
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
