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
/// A ward sent the bolt back at its caster (the hit is on the caster).
pub const HIT_REFLECTED: u8 = 128;
use serde::{Deserialize, Serialize};

/// Largest frame either side accepts; a peer sending more is closed.
pub const MAX_FRAME: usize = 256 * 1024;
/// Largest frame a client may send: nothing it says needs more.
pub const MAX_CLIENT_FRAME: usize = 16 * 1024;

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
        /// A boss's parts (heads, vines: entities), with the part names
        /// (the bone keys, L / M / R / T).
        parts: Vec<(u32, String)>,
        /// A part: the boss it belongs to (0: none).
        part_of: u32,
    },
    /// What a kill or a quest paid this player: experience, oril, items
    /// (from a chest or a quest), the levels it gained, house reputation.
    Reward {
        exp: u64,
        oril: u64,
        items: Vec<(String, u32)>,
        levels: u16,
        rep: u32,
    },
    /// A chat line (coord CHANNEL_*): `from` is the speaker's name (empty
    /// for a system line), `speaker` its entity when it stands on this map
    /// (a speech bubble), else 0.
    Chat {
        channel: u8,
        from: String,
        text: String,
        speaker: u32,
    },
    /// `from` invites the player into its party (`/accept`, `/decline`).
    PartyInvite { from: String },
    /// The player's party as it now stands (party 0: none).
    Party(crate::coord::PartyView),
    /// `from` challenges the player (`group`: party against party, `size`
    /// players on that side); answer with `/daccept` or `/ddecline`.
    DuelInvite { from: String, group: bool, size: u8 },
    /// The player's duel as it stands, or how it ended (`duel` 0).
    Duel(DuelView),
    /// A travel request was refused, or a broom request answered. `what`:
    /// door, hearthway, cabinet, passage, waylink, ride; `reason` a word
    /// (out_of_range, in_combat, level_too_low, mounted, no_item,
    /// map_full, map_unavailable, ... ; "mounted"/"dismounted" when a ride
    /// request worked).
    TravelResult {
        what: String,
        ok: bool,
        reason: String,
    },
    /// The player is leaving for `map` (`label`: where to; `kind`: door,
    /// hearthway, ...). A trip on this map follows at once; to another map
    /// `Travel` follows.
    Departing {
        map: String,
        label: String,
        kind: String,
    },
    /// Join `map` at `address` with `ticket` (this connection ends).
    Travel {
        map: String,
        address: String,
        ticket: Vec<u8>,
    },
    /// The player was set down here by a trip of `kind`.
    Arrived { kind: String },
    /// A Waylink of the player's party.
    Waylink(WaylinkView),
    /// The dungeon gate, a ready check, a run.
    Dungeon(Box<DungeonMsg>),
    /// Gate `id` of the player's dungeon copy opens (or closes) from server
    /// tick `tick` (scheduled ahead, for the prediction).
    Gate { id: String, tick: u32, open: bool },
    /// The answer to `ClaimQuest` ("claimed", "not_ready", "bag_full").
    QuestResult {
        quest: String,
        ok: bool,
        reason: String,
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
    /// Who a player is (answer to `Inspect` on a player's entity).
    PlayerInfo {
        entity: u32,
        character: u64,
        name: String,
        house: String,
        level: u16,
        /// A game admin (the client shows the emblem).
        ga: bool,
        /// How the player looks (realm_rules looks), what it wears (slot
        /// index, item id, tier), its house rank and the titles it earned
        /// (dungeon first clears). Sent again to the players near it
        /// whenever any of this changes.
        look: Vec<(String, f32)>,
        gear: Vec<(u8, String, u8)>,
        rank: u8,
        titles: Vec<String>,
    },
    /// What lasts on the player now and the server tick each ends (sent
    /// whenever it changes): stun, knock, web (slowed), despair (no natural
    /// regeneration), venom, freeze, burn, bleed, weak, ward. The bar of
    /// effects counts them down.
    Effects(Vec<(String, u32)>),
    /// The realm's weather (on joining and whenever it changes); the
    /// client shows it outdoors.
    Weather { rain: bool },
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
        /// The map it happened on; set for the realm's notices (a world
        /// boss, a Legendary gold, update_soon has none), which every map
        /// hears: the client puts those in the chat as "[World]" lines.
        place: String,
    },
    /// The realm's maintenance: `state` (ONLINE when a countdown was called
    /// off, ANNOUNCING with `seconds` to go, DRAINING, SAVING: the world
    /// stands still and nothing more is done, DISCONNECTING: the connection
    /// closes next, FAILED: held, still connected), and why.
    Maintenance {
        state: String,
        reason: String,
        seconds: u32,
    },
    /// Staff or the realm acted on this account. `kind`: kick and ban (the
    /// connection closes next), mute, unmute. `until`: the Unix second it
    /// ends (0: permanent, or it has no end).
    Sanction {
        kind: String,
        reason: String,
        until: u64,
    },
    /// The names this account has blocked (on joining, and when it changes).
    Blocks(Vec<String>),
    /// The answer to a report or a block. `what`: report, block, unblock;
    /// `reason`: sent, done, too_soon, daily_limit, duplicate, not_found,
    /// self, full, unavailable.
    SocialResult {
        what: String,
        ok: bool,
        reason: String,
        name: String,
    },
}

/// A duel as one duelist sees it. Running: `duel`, `group`, `phase` (0
/// countdown, 1 fight), `fight_tick` / `end_tick` (server ticks), the arena
/// (`center`, `radius`), `allies` and `foes` (entity, name), who is `out`.
/// Ended (`duel` 0): `result` ("won", "lost", "draw"), `reason` ("defeat",
/// "fled", "left", "died", "yield", "timeout"), `last` (the last one out),
/// `by` (who beat them). Declined: `declined_by`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct DuelView {
    pub duel: u32,
    pub group: bool,
    pub phase: u8,
    pub fight_tick: u32,
    pub end_tick: u32,
    pub center: [f32; 3],
    pub radius: f32,
    pub allies: Vec<(u32, String)>,
    pub foes: Vec<(u32, String)>,
    pub out: Vec<u32>,
    pub result: String,
    pub reason: String,
    pub last: String,
    pub by: String,
    pub declined_by: String,
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
    /// What is this creature or player (entity id)?
    Inspect(u32),
    /// Show a chest's cells (within reach).
    OpenChest(u32),
    /// Take one cell of a chest, or everything that fits (None).
    TakeLoot { chest: u32, slot: Option<u8> },
    /// Rise after death: where the body fell (`here`) or in town.
    Respawn { here: bool },
    /// Spend an attribute point (vit, int, str, dex).
    SpendAttribute(String),
    /// The player talked to this NPC (npcs.json `name`).
    Talk(String),
    /// Claim a quest that is ready.
    ClaimQuest(String),
    /// A chat line or a /command, as typed.
    Chat(String),
    /// Go through the door (maps.json portal id) the player stands in.
    Door(String),
    /// Travel from the node the player stands at (`from`): a hearth to the
    /// hearth `to`, a cabinet or passage to its twin (`to` unused).
    Travel { from: String, to: String },
    /// Mount the broom (true) or get off it (false).
    Ride(bool),
    /// Set a Waylink boot down for `dest` (a travel node).
    WaylinkPlace(String),
    /// Hold on to (or let go of) the Waylink `id`.
    WaylinkHold { id: u32, hold: bool },
    /// What the dungeon behind the gate `portal` asks of the party.
    DungeonInfo(String),
    /// The party leader starts the dungeon behind `portal` at `difficulty`
    /// (index into realm_rules::dungeons::DIFFICULTIES).
    DungeonStart { portal: String, difficulty: u8 },
    /// A member answers the ready check `id`.
    DungeonReady { id: u32, yes: bool },
    /// The dungeon guide: the player's records and this week's boards.
    DungeonGuide,
    /// Report a player. `category`: harassment, hate, spam, cheating, name,
    /// other; `text` is optional.
    Report {
        character: u64,
        name: String,
        category: String,
        text: String,
    },
    /// Stop (or go back to) hearing from this player's account.
    Block { name: String, on: bool },
}

/// A party member as the dungeon gate sees it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct GateMember {
    pub character: u64,
    pub name: String,
    pub level: u16,
    /// What keeps it from going ("" when nothing): not_gathered, dead,
    /// mounted, in_duel, in_combat, in_run, ...
    pub status: String,
    /// Per difficulty: unlocked, rewarded runs left today (-1 unlimited),
    /// best full clear in ms (0 none).
    pub unlocked: Vec<bool>,
    pub rights: Vec<i32>,
    pub best_ms: Vec<u32>,
}

/// A ready check as its members see it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ReadyView {
    pub id: u32,
    pub dungeon: String,
    pub difficulty: u8,
    pub leader: String,
    /// (name, level, ready)
    pub members: Vec<(String, u16, bool)>,
    /// Server tick it runs out.
    pub ends_tick: u32,
}

/// How a run ended.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct RunResult {
    /// realm_rules::dungeons::RANK_* (0: cleared without a medal, -1: not
    /// cleared).
    pub rank: i8,
    pub time_ms: u32,
    /// Share of the creatures cleared, 0..=1000.
    pub clear: u16,
    pub deaths: u16,
    pub timeout: bool,
}

/// A curse's mark on a run's floor. `kind`: burst (a ring at a corpse that
/// goes off at `release_tick`), storm (a ring under a player, the same),
/// sticky (a slowing patch until `until_tick`), pool (venom or web, until
/// `until_tick`). Server ticks; `hp_share`: the share of maximum health it
/// takes (per second for a venom pool).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct HazardView {
    pub id: u32,
    pub kind: String,
    pub center: [f32; 3],
    pub radius: f32,
    pub start_tick: u32,
    pub release_tick: u32,
    pub until_tick: u32,
    pub hp_share: f32,
    /// A band instead of a ring (half extents x, z around `center`; 0: a
    /// ring). The Sealed Wing's breath.
    pub half: [f32; 2],
}

/// The sleep chime by a sleeping guardian: where it stands and who rings
/// it (server ticks; 0 when nobody does). `ready_tick`: it can ring again.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ChimeView {
    pub at: [f32; 3],
    pub radius: f32,
    pub ringer: u32,
    pub start_tick: u32,
    pub end_tick: u32,
    pub ready_tick: u32,
}

/// A dungeon run as the players in it see it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct RunView {
    pub dungeon: String,
    pub difficulty: u8,
    pub ref_level: u16,
    /// 0 gathering, 1 counting down, 2 running, 3 over.
    pub phase: u8,
    /// Server ticks: when the countdown ends (phase 1) / the clock started.
    pub countdown_end: u32,
    pub start_tick: u32,
    /// The clock's own penalty (deaths), seconds.
    pub penalty_s: f32,
    pub par_s: f32,
    pub limit_s: f32,
    pub step: String,
    pub message: String,
    pub forces: u32,
    pub forces_total: u32,
    pub deaths: u16,
    /// -1: no lives rule.
    pub lives_left: i32,
    pub broken: bool,
    /// (name, down)
    pub bosses: Vec<(String, bool)>,
    /// Creatures still standing when only `cleared:all` remains.
    pub left: u32,
    pub complete: bool,
    pub result: Option<RunResult>,
    /// The run's curses (dungeons.json affixes ids).
    pub affixes: Vec<String>,
    /// Curse marks on the floor now (a player arriving late sees them).
    pub hazards: Vec<HazardView>,
    /// The sleep chime, in a run that has one.
    pub chime: Option<ChimeView>,
}

/// The dungeon gate, the ready check and a run.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum DungeonMsg {
    /// The answer to `DungeonInfo`. `active`: the asker's own run still
    /// open (copy, its view as a summary).
    Info {
        dungeon: String,
        portal: String,
        leader: String,
        members: Vec<GateMember>,
        active: Option<crate::coord::RunSummary>,
        check: Option<ReadyView>,
        /// This week's curses in order: a difficulty takes the first N.
        affixes: Vec<String>,
    },
    Ready(ReadyView),
    Cancelled {
        reason: String,
        who: String,
    },
    /// The start was refused: reason (not_leader, party_size, level_too_low,
    /// level_spread, difficulty_locked, no_key, map_full, ...), who, value.
    Refused {
        reason: String,
        who: String,
        value: i32,
    },
    /// The party is on its way into `map`.
    Launch {
        map: String,
    },
    /// The run as it stands.
    State(RunView),
    /// A curse mark appears on the floor.
    Hazard(HazardView),
    /// The dungeon guide's page. `records`: (dungeon, difficulty, best rank
    /// cleared or -1, best ms or 0, rewarded runs left today or -1);
    /// `boards`: this week's fastest; `titles`: the player's.
    Guide {
        week: u32,
        affixes: Vec<String>,
        records: Vec<(String, u8, i8, u32, i32)>,
        boards: Vec<crate::coord::Board>,
        titles: Vec<String>,
    },
    /// What the run paid this player. `helper`: no daily right left.
    Rewards {
        helper: bool,
        rank: i8,
        exp: u64,
        oril: u64,
        items: Vec<(String, u32, u8)>,
        unlocked: Vec<u8>,
        title: String,
    },
}

/// A Waylink boot as its party sees it. `phase` 0 set down (counting down
/// to `fires_tick`, a server tick), 1 fired, 2 gone (fizzled, or it left
/// the viewer's party). `holders` are entities.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct WaylinkView {
    pub id: u32,
    pub phase: u8,
    pub pos: [f32; 3],
    pub dest: String,
    pub label: String,
    pub owner: u32,
    pub owner_name: String,
    pub fires_tick: u32,
    pub holders: Vec<u32>,
    pub radius: f32,
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
    /// Largest frame taken (None: [`MAX_FRAME`]).
    limit: Option<usize>,
}

impl FrameReader {
    /// A reader that refuses frames over `limit` bytes.
    #[must_use]
    pub fn with_limit(limit: usize) -> Self {
        Self {
            buffer: Vec::new(),
            limit: Some(limit),
        }
    }

    pub fn push(&mut self, bytes: &[u8]) {
        self.buffer.extend_from_slice(bytes);
    }

    /// The next whole frame's payload, if one has arrived.
    pub fn next_frame(&mut self) -> Result<Option<Vec<u8>>, FrameError> {
        let Some(head) = self.buffer.get(..4) else {
            return Ok(None);
        };
        let len = u32::from_le_bytes([head[0], head[1], head[2], head[3]]) as usize;
        if len > self.limit.unwrap_or(MAX_FRAME) {
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
