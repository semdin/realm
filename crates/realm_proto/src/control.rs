//! The control channel: the join stream kept open after [`crate::JoinReply`]
//! for reliable, ordered messages both ways. Each message is a frame, a
//! little-endian `u32` length then that many bytes; the first frame each way
//! is the hello / join reply, every later one a [`ServerMsg`] or
//! [`ClientMsg`] in postcard.
//!
//! This module does no I/O: [`frame`] wraps bytes to write, [`FrameReader`]
//! takes whatever arrived and hands back whole frames.

use realm_rules::{CharacterSheet, Item, ItemOp};

/// Something that happened in combat, for the clients that can see it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum CombatEvent {
    /// A cast began: the caster turns to `aim` and the spell leaves the wand
    /// on `release_tick`.
    CastStarted {
        caster: u32,
        spell: u8,
        target: u32,
        aim: [f32; 3],
        release_tick: u32,
    },
    /// The spell left the wand (a bolt starts flying from `from`).
    CastReleased {
        caster: u32,
        spell: u8,
        from: [f32; 3],
        dir: [f32; 3],
    },
    /// An area spell burst at `at`.
    Burst {
        caster: u32,
        spell: u8,
        at: [f32; 3],
    },
    /// A hit landed: `amount` damage (0 for a blocked or reflected one),
    /// `flags` (HIT_* bits), the victim's health after it (0..255).
    Hit {
        target: u32,
        attacker: u32,
        spell: u8,
        amount: u32,
        flags: u8,
        hp: u8,
    },
    /// The player's own request was refused (cooldown, no mana, ...).
    CastRefused { spell: u8, reason: String },
    /// A creature winds up a telegraphed ability (realm_rules creature
    /// ability `ability`): its shape lands on `center`, facing `yaw`
    /// (radians, the creature's facing), on `release_tick`; the creature
    /// recovers until `recovery_tick`.
    Telegraph {
        caster: u32,
        ability: u16,
        center: [f32; 3],
        yaw: f32,
        release_tick: u32,
        recovery_tick: u32,
    },
    /// A telegraph was broken off before it landed (the creature was held,
    /// thrown, or gave up).
    TelegraphCancelled { caster: u32 },
}

/// Hit flags: what the hit was, and what a control enchantment added to it.
pub const HIT_CRIT: u8 = 1;
pub const HIT_FINISHER: u8 = 2;
pub const HIT_PIERCE: u8 = 4;
pub const HIT_STUN: u8 = 8;
pub const HIT_SLOW: u8 = 16;
pub const HIT_BURN: u8 = 32;
/// A creature walking home shrugged the blow off.
pub const HIT_EVADE: u8 = 64;
use serde::{Deserialize, Serialize};

/// Largest frame either side accepts; a peer sending more is closed.
pub const MAX_FRAME: usize = 256 * 1024;

/// Server -> client.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum ServerMsg {
    /// The player's whole character sheet: sent after joining and whenever
    /// it changes.
    Sheet(Box<CharacterSheet>),
    /// The answer to an item request. `reason` is a word the client turns
    /// into a message ("equipped", "no_gold", "stale", ...); `amount` is the
    /// oril earned or spent, the points restored or the new tier.
    ItemResult {
        op_id: u32,
        ok: bool,
        reason: String,
        amount: i64,
    },
    /// What happened in combat near the player since the last batch.
    Combat(Vec<CombatEvent>),
    /// The answer to a skill request ("learned", "no_points", ...).
    SkillResult {
        spell: String,
        ok: bool,
        reason: String,
    },
    /// What a creature is (answer to `Inspect`): `name` is a boss's,
    /// a Dark Shard's or a dummy's own name (empty: the species' name).
    CreatureInfo {
        entity: u32,
        /// A boss's boss_overrides key (its body, scale and name), else empty.
        boss_key: String,
        name: String,
        level: u32,
        elite: bool,
        boss: bool,
    },
    /// What a kill paid this player: experience, oril (the killer's), items
    /// taken from a chest, and the levels it gained.
    Reward {
        exp: u64,
        oril: u64,
        items: Vec<(String, u32)>,
        levels: u16,
    },
    /// A chest's cells (answer to `OpenChest`, and after every take): an
    /// emptied cell stays as None.
    Chest {
        chest: u32,
        slots: Vec<Option<Item>>,
    },
    /// The answer to `TakeLoot` ("taken", "bag_full", "out_of_range",
    /// "gone", "dead").
    LootResult {
        chest: u32,
        ok: bool,
        reason: String,
    },
    /// The player died: it may rise from `ready_tick`, and goes to town by
    /// itself at `auto_tick` (server ticks); `killer` is the entity.
    Death {
        ready_tick: u32,
        auto_tick: u32,
        killer: u32,
    },
    /// The answer to `SpendAttribute` ("spent", "no_points", "max",
    /// "unknown").
    AttributeResult {
        stat: String,
        ok: bool,
        reason: String,
    },
    /// Something the map announces: `kind` ("boss_soon", "boss_spawned",
    /// "boss_slain", "stone_wave", "stone_shattered") about `subject` (a
    /// name; the client translates both). `actor` is the character whose
    /// blow felled it (empty when none did); `value` and `of` are the
    /// numbers in the line: seconds to go (boss_soon), the boss's level
    /// (boss_spawned), the wave and how many there are (stone_wave).
    Notice {
        kind: String,
        subject: String,
        actor: String,
        value: u32,
        of: u32,
    },
}

/// Client -> server.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum ClientMsg {
    /// A new appearance (looks.json keys -> value); the server cleans it.
    Look(Vec<(String, f32)>),
    /// An item operation, made against the sheet at `revision` (a request
    /// made against an older sheet is refused as "stale"; the client has the
    /// new sheet by then).
    Item {
        op_id: u32,
        revision: u64,
        op: ItemOp,
    },
    /// Spend a skill point on `spell` (learn it, or raise it one level).
    LearnSkill(String),
    /// What is this creature (entity id)?
    Inspect(u32),
    /// Show a chest's cells (within reach).
    OpenChest(u32),
    /// Take one cell of a chest, or everything that fits (None).
    TakeLoot { chest: u32, slot: Option<u8> },
    /// Rise after death: where the body fell (`here`) or in town.
    Respawn { here: bool },
    /// Spend an attribute point (vit, int, str, dex).
    SpendAttribute(String),
}

#[derive(Debug, PartialEq, Eq)]
pub enum FrameError {
    TooLarge(usize),
    Malformed,
}

impl core::fmt::Display for FrameError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::TooLarge(n) => write!(f, "frame of {n} bytes is over the limit"),
            Self::Malformed => f.write_str("malformed control message"),
        }
    }
}

impl std::error::Error for FrameError {}

/// `payload` with its length prefix.
#[must_use]
pub fn frame(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + payload.len());
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(payload);
    out
}

#[must_use]
pub fn encode_server(msg: &ServerMsg) -> Vec<u8> {
    frame(&postcard::to_stdvec(msg).unwrap_or_default())
}

#[must_use]
pub fn encode_client(msg: &ClientMsg) -> Vec<u8> {
    frame(&postcard::to_stdvec(msg).unwrap_or_default())
}

pub fn decode_server(payload: &[u8]) -> Result<ServerMsg, FrameError> {
    postcard::from_bytes(payload).map_err(|_| FrameError::Malformed)
}

pub fn decode_client(payload: &[u8]) -> Result<ClientMsg, FrameError> {
    postcard::from_bytes(payload).map_err(|_| FrameError::Malformed)
}

/// Collects stream bytes and yields complete frames.
#[derive(Default)]
pub struct FrameReader {
    buffer: Vec<u8>,
}

impl FrameReader {
    pub fn push(&mut self, bytes: &[u8]) {
        self.buffer.extend_from_slice(bytes);
    }

    /// The next whole frame's payload, if one has arrived.
    pub fn next_frame(&mut self) -> Result<Option<Vec<u8>>, FrameError> {
        let Some(head) = self.buffer.get(..4) else {
            return Ok(None);
        };
        let len = u32::from_le_bytes([head[0], head[1], head[2], head[3]]) as usize;
        if len > MAX_FRAME {
            return Err(FrameError::TooLarge(len));
        }
        if self.buffer.len() < 4 + len {
            return Ok(None);
        }
        let payload = self.buffer[4..4 + len].to_vec();
        self.buffer.drain(..4 + len);
        Ok(Some(payload))
    }
}
