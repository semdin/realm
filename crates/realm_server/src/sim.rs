//! The authoritative simulation of one map: players moved by their inputs,
//! creatures thinking and fighting, projectiles, deaths and respawns, and one
//! snapshot per client every other tick. Runs on its own thread at 30 Hz; the
//! network tasks talk to it only through channels.
//!
//! Cost control, in order of how much it saves:
//! - creatures in cells with no player within two cells do not run at all;
//! - awake creatures think (pick targets) at 30, 10 or 2 Hz by distance to the
//!   nearest player, and only move every tick;
//! - snapshots carry what changed since the client's acknowledged baseline,
//!   nearest and longest-waiting first, within a byte budget per snapshot.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::hash::{BuildHasherDefault, Hasher};
use std::time::Instant;

use bevy_ecs::prelude::*;
use bytes::Bytes;
use realm_proto::control::{self, ClientMsg, ServerMsg};
use realm_proto::ticket::Ticket;
use realm_proto::{EntitySet, EntityState, InputBatch, InputFrame, JoinReply, Snapshot};
use realm_rules::{CharacterSheet, Place};
use realm_sim::Vec3;
use realm_sim::movement::{self, Body, MoveParams};
use realm_sim::nav::{NavQuery, NavScratch};
use realm_sim::staircase::Staircases;
use realm_sim::world::World as Terrain;

use crate::game::Game;

mod afflict;
mod brain;
mod combat;
mod duel;
mod dungeon;
mod ga;
mod maintenance;
mod quests;
mod rewards;
mod social;
mod status;
mod travel;
use crate::store::StoreJob;
use combat::{Bolt, Caster};
use realm_proto::control::CombatEvent;

pub type ConnId = u64;

/// Network -> simulation.
pub enum NetEvent {
    Join {
        conn: ConnId,
        ticket: Ticket,
        outbox: tokio::sync::mpsc::Sender<Bytes>,
        control: tokio::sync::mpsc::Sender<Bytes>,
        reply: tokio::sync::oneshot::Sender<JoinReply>,
    },
    /// A message on the control channel.
    Control {
        conn: ConnId,
        msg: ClientMsg,
    },
    /// The store thread answered a load.
    Loaded {
        conn: ConnId,
        result: Result<Option<Box<CharacterSheet>>, String>,
    },
    /// The store thread finished a save (`ok`: it landed).
    Saved {
        character: u64,
        revision: u64,
        ok: bool,
    },
    Input {
        conn: ConnId,
        batch: InputBatch,
    },
    Leave {
        conn: ConnId,
    },
    /// The coordinator sent something.
    Coord(realm_proto::coord::CoordMsg),
    /// The link to the coordinator came up, or went down.
    CoordUp,
    CoordDown,
}

/// Every player is saved once in this many ticks (30 s), spread over them.
const AUTOSAVE_TICKS: u32 = 30 * 30;
/// A changed sheet is saved this long after its last change (5 s).
const SAVE_DEBOUNCE_TICKS: u32 = 5 * 30;
/// Gear changes, selling, refining wait this long after combat (5 s).
const COMBAT_LOCK_TICKS: u32 = 5 * 30;
/// Reliable messages a client may have waiting; past that it is closed.
pub const CONTROL_QUEUE: usize = 256;

const CELL: f32 = 32.0;
const GRID_HALF: f32 = 1120.0;
const GRID_DIM: usize = (2.0 * GRID_HALF / CELL) as usize;
const INTEREST_RADIUS: f32 = 70.0;
/// An entity already on a client stays until it is this far, so one walking
/// along the edge does not flicker in and out.
const INTEREST_KEEP: f32 = 80.0;
const WAKE_CELLS: i32 = 2;
/// Snapshots go to each client every this many ticks (15 Hz), clients split
/// across the ticks so the work is spread evenly.
pub const SNAPSHOT_EVERY: u32 = 2;
/// Estimated bytes of entity data per snapshot: 8 KB/s at 15 Hz is about 546
/// bytes, minus the header and the owner's body.
const ENTITY_BUDGET: usize = 470;
const HISTORY: usize = 32;
const STATE_IDLE: u8 = 0;
const STATE_MOVING: u8 = 1;
const STATE_ATTACKING: u8 = 2;
const STATE_DEAD: u8 = 3;
/// A dead creature stays visible this long, then leaves until it respawns.
const CORPSE_TICKS: u32 = 60;
const CHEST: f32 = 1.15;
/// Most steps a player may run in one tick (catching up after a stall).
const MAX_BURST: u32 = 4;
/// Steps a player may have in hand: the ticks it sent nothing for, up to
/// half a second. A client that stalled sends its catch-up steps in a burst
/// (FixedStep runs up to 8 in one frame); with this much in hand the server
/// drains them at MAX_BURST a tick instead of keeping them queued for good.
const STEP_CREDIT: u32 = 15;
/// A missing input is given up for lost after this many ticks.
const LOST_AFTER_TICKS: u32 = 6;
/// How far an input's own tick may lie from the server's (two seconds).
const INPUT_TICK_WINDOW: u32 = 60;
/// Inputs a client may run ahead of the server before it is resynchronised.
const RESYNC_AHEAD: u32 = 60;
/// Creatures re-find the ground under them every this many ticks.
const GROUND_EVERY: u32 = 3;
/// Within this distance a creature walks straight at its goal.
const DIRECT_CHASE: f32 = 6.0;
/// A goal that moved this far from where a path was planned for gets a new
/// path at once instead of at the next scheduled re-plan.
const REPLAN_DRIFT: f32 = 8.0;
/// Polygons one path search may visit (a creature's chase stays local).
const PATH_NODE_BUDGET: usize = 3000;

#[derive(Component)]
struct NetId(u32);

/// Entity ids are small sequential integers: a multiply is all the hashing
/// they need (the default SipHash is several times slower).
#[derive(Default)]
struct IdHasher(u64);

impl Hasher for IdHasher {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write(&mut self, bytes: &[u8]) {
        for b in bytes {
            self.0 = (self.0 ^ u64::from(*b)).wrapping_mul(0x0100_0000_01b3);
        }
    }
    fn write_u32(&mut self, n: u32) {
        self.0 = u64::from(n).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    }
}

type IdMap<V> = HashMap<u32, V, BuildHasherDefault<IdHasher>>;

#[derive(Component)]
struct Player {
    body: Body,
    /// Received inputs waiting for their tick, by sequence number.
    pending: BTreeMap<u32, InputFrame>,
    last_seq: u32,
    last_frame: InputFrame,
    hp: f32,
    max_hp: f32,
    dead_until: u32,
    home: Vec3,
    /// Last place the body stood on ground.
    last_ground: Vec3,
    /// Steps this player may still run (one more per tick, up to
    /// STEP_CREDIT).
    allowance: u32,
    /// Ticks the next input has been missing while later ones wait.
    gap_ticks: u32,
    /// The tick label of the newest input run (holds start from the next).
    last_input_tick: u32,
    /// Deaths and respawns so far (wrapping), for the owner's snapshots.
    life: u8,
    /// The next tick this player may chat.
    chat_ready: u32,
    /// What the players near it were last told about it (PlayerInfo).
    info_key: u64,
    /// Its party as the coordinator last said.
    party: realm_proto::coord::PartyView,
    /// A dead player may rise from this tick (`dead_until` is when it goes
    /// to town by itself).
    respawn_ready: u32,
    /// The character record. Position and hp live in `body` / `hp` while
    /// playing and are written back by `Sim::sheet_of`.
    sheet: CharacterSheet,
    /// Tick of the first unsaved change, if any.
    dirty_since: Option<u32>,
    /// Mana, casting, cooldowns, the ward, derived gear stats.
    caster: Caster,
    /// Last tick this player attacked or was hit (gear changes wait for
    /// peace).
    last_combat: u32,
    /// What creatures left on it: holds, web, venom, despair.
    afflictions: afflict::Afflictions,
    /// The holds as its owner's prediction must apply them.
    restraint: realm_sim::movement::Restraint,
    /// Last tick it lost health (the broom waits for peace).
    last_hurt: u32,
    /// A trip to another map waiting for its seat.
    trip: Option<travel::PendingTrip>,
}

impl Mob {
    fn thrown_ready(&self, ability: u16) -> u32 {
        self.thrown
            .iter()
            .find(|(a, _)| *a == ability)
            .map_or(0, |(_, t)| *t)
    }

    fn set_thrown_ready(&mut self, ability: u16, tick: u32) {
        match self.thrown.iter_mut().find(|(a, _)| *a == ability) {
            Some(slot) => slot.1 = tick,
            None => self.thrown.push((ability, tick)),
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum MobMode {
    Idle,
    Wander(Vec3),
    Chase(Entity),
    Return,
    Dead,
}

#[derive(Component)]
struct Mob {
    pack: usize,
    species: u16,
    home: Vec3,
    pos: Vec3,
    yaw: u16,
    hp: f32,
    max_hp: f32,
    /// Its level, attack power (an elite's raised), reach and pace.
    level: u32,
    attack_power: f32,
    attack_range: f32,
    move_speed: f32,
    elite: bool,
    /// A pack's boss: patterns, its own leash, no ring.
    boss: bool,
    /// A commander whose mate fell.
    enraged: bool,
    /// The boss pattern it throws next.
    pattern_next: u32,
    /// The experience its kill gives.
    exp_reward: u32,
    /// Players who hit it lately (the kill's credit).
    credit: Vec<rewards::Credit>,
    mode: MobMode,
    /// Ticks until the next attack may start (runs slower while slowed).
    attack_cd: f32,
    /// The attack under way, from its windup to the end of its recovery.
    attack: Option<brain::Attack>,
    /// Plain attacks begun this life (every Nth is an ability).
    attacks_made: u32,
    /// Thrown abilities and the tick each is ready again.
    thrown: Vec<(u16, u32)>,
    /// Last tick a player's blow landed (the leash stretches after it).
    hit_at: u32,
    /// Since when its target has been out of reach (0 = reachable).
    unreachable_since: u32,
    /// Next look around for a player (aggressive packs).
    next_scan: u32,
    next_think: u32,
    died_at: u32,
    rng: u32,
    state: u8,
    /// Corners still to walk to the current goal, nearest first.
    path: Vec<Vec3>,
    /// The goal the path was planned for, and when to plan again.
    path_goal: Vec3,
    replan_at: u32,
    /// Holds, slows, burns and throws on the body.
    status: status::Status,
    /// Loot chance multiplier (a dungeon run's creatures).
    drop_scale: f32,
    /// Its windups' length multiplier (a dungeon difficulty's telegraph).
    windup_scale: f32,
    /// A part of a multi-part boss: the body (parts neither think nor move).
    part_of: Option<Entity>,
    /// A multi-part boss: its parts and their bone keys.
    parts: Vec<(Entity, String)>,
    /// A boss's fight phase (patterns with a higher min_phase wait).
    phase: u8,
}

/// What one client has been sent.
struct View {
    /// Entity sets of recent snapshots, by tick: the delta baselines.
    history: VecDeque<(u32, EntitySet)>,
    acked: u32,
    priority: IdMap<f32>,
}

struct Client {
    entity: Entity,
    net_id: u32,
    character: u64,
    account: u64,
    outbox: tokio::sync::mpsc::Sender<Bytes>,
    control: tokio::sync::mpsc::Sender<Bytes>,
    view: View,
    phase: u32,
    bytes: u64,
    /// Combat events waiting for this client's next snapshot.
    events: Vec<CombatEvent>,
}

/// One replicated entity this tick.
#[derive(Clone, Copy)]
struct Row {
    id: u32,
    entity: Entity,
    state: EntityState,
    is_player: bool,
}

#[derive(Default)]
pub struct Stats {
    pub ticks: Vec<f32>,
    pub sections: [f64; 5],
    pub bytes_out: u64,
    pub snapshots: u64,
    pub awake_mobs: usize,
    pub thinking_mobs: usize,
    pub casts: u64,
    /// Refused attacks: unknown target, not a living creature, out of range.
    pub refused: [u64; 3],
    pub paths: u64,
    /// Players found below the map's height band this window (fell out).
    pub fallen: u64,
    /// Furthest any living player got from where it spawned, metres.
    pub roamed: f32,
    /// Where the first player that fell this window last stood.
    pub fell_at: Option<Vec3>,
    pub path_ms: f64,
    pub ground_ms: f64,
    pub hits: u64,
    pub kills: u64,
    pub player_deaths: u64,
    /// Crowd control this window: holds and throws a spell put on a
    /// creature, enchantment procs, burn and bleed ticks.
    pub holds: u64,
    pub procs: u64,
    pub dot_ticks: u64,
    /// Creature abilities wound up, and holds they put on players.
    pub telegraphs: u64,
    pub player_holds: u64,
}

struct PendingJoin {
    ticket: Ticket,
    outbox: tokio::sync::mpsc::Sender<Bytes>,
    control: tokio::sync::mpsc::Sender<Bytes>,
    reply: tokio::sync::oneshot::Sender<JoinReply>,
    /// Where it lands, when it travelled here.
    arrival: Option<realm_rules::travel::Arrival>,
    /// Waiting for the store (not the coordinator).
    loading: bool,
}

pub const SECTION_NAMES: [&str; 5] = ["players", "creatures", "projectiles", "grid", "snapshots"];

pub struct Sim {
    pub tick: u32,
    world: World,
    terrain: Terrain,
    game: Game,
    content_hash: [u8; 32],
    clients: HashMap<ConnId, Client>,
    ids: HashMap<u32, Entity>,
    next_id: u32,
    bolts: Vec<Bolt>,
    /// Creature bolts in flight.
    mob_bolts: Vec<brain::MobBolt>,
    /// Each pack's anchor, members and respawn clock.
    packs: Vec<brain::PackState>,
    /// Per pack, its awake members this tick (the ring and spacing).
    pack_views: Vec<Vec<brain::MateView>>,
    touched_packs: Vec<usize>,
    /// Fighting creatures with an aura, this tick.
    auras: Vec<Entity>,
    /// Players with venom running.
    poisoned: Vec<Entity>,
    /// Creatures with a burn, a bleed or a throw running.
    ticking: Vec<Entity>,
    /// This tick's combat events, where they happened.
    events: Vec<(Vec3, CombatEvent)>,
    /// Events only their player hears (a refused cast).
    private_events: Vec<(Entity, CombatEvent)>,
    rows: Vec<Row>,
    /// Row indices per cell.
    cells: Vec<Vec<u32>>,
    /// Player positions per cell (for creature targeting).
    player_cells: Vec<Vec<(Entity, Vec3)>>,
    /// Every living player's position this tick.
    player_pos: HashMap<Entity, Vec3>,
    awake: Vec<bool>,
    nav: NavQuery,
    nav_scratch: NavScratch,
    stairs: Staircases,
    /// Development: players spawn next to one of these packs (indices).
    dev_spawn_packs: Vec<usize>,
    /// State of the server's dice (refining, enchanting).
    dice_state: u32,
    /// Joins waiting for their character to load.
    pending: HashMap<ConnId, PendingJoin>,
    /// The newest sheet of each character whose save has not finished: a
    /// join reads it instead of the store's older copy.
    unsaved: HashMap<u64, CharacterSheet>,
    store: crossbeam_channel::Sender<StoreJob>,
    /// The realm's maintenance as the coordinator told it.
    maintenance: maintenance::Maintenance,
    /// Game admins and the weather.
    pub admins: ga::Admins,
    /// To the coordinator (None: running alone), and whether it is linked.
    coord_tx: Option<tokio::sync::mpsc::UnboundedSender<realm_proto::coord::MapMsg>>,
    coord_up: bool,
    /// Duel challenges and duels on this map.
    duels: duel::DuelBook,
    /// Characters leaving this server: saved, waiting to be released.
    departing: HashMap<u64, travel::Departing>,
    /// Maps the coordinator says are open.
    open_maps: Vec<String>,
    waylinks: Vec<travel::Waylink>,
    next_waylink: u32,
    /// A dungeon map: its copies' gates and runs.
    instanced: bool,
    gates: realm_sim::gates::Gates,
    runs: Vec<Option<dungeon::Run>>,
    free_packs: Vec<usize>,
    runs_told: Vec<realm_proto::coord::RunSummary>,
    /// An outer map: every dungeon map's live copies, ready checks, launches.
    dungeon_runs: Vec<realm_proto::coord::RunSummary>,
    /// This week's dungeon boards (from the coordinator).
    boards: Vec<realm_proto::coord::Board>,
    ready_checks: Vec<dungeon::Check>,
    launches: Vec<dungeon::Launch>,
    next_check: u32,
    next_hazard: u32,
    /// Development: a run's creatures' health and damage x this.
    pub dev_dungeon_scale: f32,
    /// Development: every run's curses (instead of the week's).
    pub dev_dungeon_affixes: Option<Vec<String>>,
    /// Development: a run starts at this step (those before it done, their
    /// gates open, nothing of theirs spawned).
    pub dev_dungeon_start: Option<String>,
    /// Development: the Web Mother's cocoon wraps a player even alone (it
    /// needs two otherwise).
    pub dev_cocoon_solo: bool,
    pub stats: Stats,
    params: MoveParams,
}

fn cell_of(p: Vec3) -> Option<usize> {
    let cx = ((p.x + GRID_HALF) / CELL) as i32;
    let cz = ((p.z + GRID_HALF) / CELL) as i32;
    if cx < 0 || cz < 0 || cx >= GRID_DIM as i32 || cz >= GRID_DIM as i32 {
        return None;
    }
    Some(cz as usize * GRID_DIM + cx as usize)
}

fn cell_coords(p: Vec3) -> (i32, i32) {
    (
        ((p.x + GRID_HALF) / CELL) as i32,
        ((p.z + GRID_HALF) / CELL) as i32,
    )
}

fn cells_around(p: Vec3, radius_cells: i32) -> impl Iterator<Item = usize> {
    let (cx, cz) = cell_coords(p);
    (-radius_cells..=radius_cells).flat_map(move |dz| {
        (-radius_cells..=radius_cells).filter_map(move |dx| {
            let (x, z) = (cx + dx, cz + dz);
            (x >= 0 && z >= 0 && x < GRID_DIM as i32 && z < GRID_DIM as i32)
                .then(|| z as usize * GRID_DIM + x as usize)
        })
    })
}

/// The rules' dice over the server's xorshift.
struct ServerDice(u32);

impl realm_rules::Dice for ServerDice {
    fn unit(&mut self) -> f32 {
        unit(&mut self.0)
    }
}

/// Seconds since the Unix epoch (reward days, weekly resets).
fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn xorshift(state: &mut u32) -> u32 {
    let mut x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    x
}

fn unit(state: &mut u32) -> f32 {
    (xorshift(state) >> 8) as f32 / (1 << 24) as f32
}

fn yaw_of(dir: Vec3) -> u16 {
    // Yaw 0 looks along -Z (the movement rules' convention).
    let angle = libm::atan2f(-dir.x, -dir.z);
    let turn = if angle < 0.0 {
        angle + core::f32::consts::TAU
    } else {
        angle
    };
    (libm::roundf(turn * (65_536.0 / core::f32::consts::TAU)) as u32 & 0xFFFF) as u16
}

fn hp_byte(hp: f32, max: f32) -> u8 {
    if hp <= 0.0 {
        0
    } else {
        (libm::ceilf(hp / max * 255.0) as u32).clamp(1, 255) as u8
    }
}

/// Server-side distances only decide who sees and targets what; nothing a
/// client re-simulates depends on them, so they use the hardware square root
/// (the movement rules use the bit-exact one).
fn planar_distance(a: Vec3, b: Vec3) -> f32 {
    planar_distance_sq(a, b).sqrt()
}

fn planar_distance_sq(a: Vec3, b: Vec3) -> f32 {
    let (dx, dz) = (a.x - b.x, a.z - b.z);
    dx * dx + dz * dz
}

impl Sim {
    pub fn new(
        game: Game,
        terrain: Terrain,
        nav: NavQuery,
        stairs: Staircases,
        content_hash: [u8; 32],
        dev_spawn_near: Option<&str>,
        store: crossbeam_channel::Sender<StoreJob>,
    ) -> Result<Self, String> {
        let dev_spawn_packs: Vec<usize> = match dev_spawn_near {
            None => Vec::new(),
            Some(species) => {
                let packs: Vec<usize> = (0..game.packs.len())
                    .filter(|&i| {
                        // A species, a boss key (grak), a Dark Shard body
                        // (stone_dark) or training_dummy; empty: any
                        // creature pack.
                        let p = &game.packs[i];
                        let creatures = p.kind == crate::game::PackKind::Creatures;
                        let stone = matches!(
                            p.kind,
                            crate::game::PackKind::Stone(_) | crate::game::PackKind::Dummy
                        );
                        (creatures && species.is_empty())
                            || ((creatures || stone) && game.species[p.species].id == species)
                            || p.boss_setup.as_ref().is_some_and(|b| b.key == species)
                    })
                    .collect();
                if packs.is_empty() {
                    return Err(format!("no {species} packs on this map"));
                }
                packs
            }
        };
        let mut sim = Self {
            tick: 1,
            world: World::new(),
            terrain,
            game,
            content_hash,
            clients: HashMap::new(),
            ids: HashMap::new(),
            next_id: 1,
            bolts: Vec::new(),
            mob_bolts: Vec::new(),
            packs: Vec::new(),
            pack_views: Vec::new(),
            touched_packs: Vec::new(),
            auras: Vec::new(),
            poisoned: Vec::new(),
            ticking: Vec::new(),
            events: Vec::new(),
            private_events: Vec::new(),
            rows: Vec::new(),
            cells: vec![Vec::new(); GRID_DIM * GRID_DIM],
            player_cells: vec![Vec::new(); GRID_DIM * GRID_DIM],
            player_pos: HashMap::new(),
            awake: vec![false; GRID_DIM * GRID_DIM],
            nav,
            nav_scratch: NavScratch::default(),
            stairs,
            dev_spawn_packs,
            dice_state: getrandom::u32().unwrap_or(0x2545_F491) | 1,
            pending: HashMap::new(),
            unsaved: HashMap::new(),
            maintenance: maintenance::Maintenance::default(),
            admins: ga::Admins::default(),
            coord_tx: None,
            coord_up: false,
            duels: duel::DuelBook::default(),
            departing: HashMap::new(),
            open_maps: Vec::new(),
            waylinks: Vec::new(),
            next_waylink: 0,
            instanced: false,
            gates: realm_sim::gates::Gates::default(),
            runs: Vec::new(),
            free_packs: Vec::new(),
            runs_told: Vec::new(),
            dungeon_runs: Vec::new(),
            boards: Vec::new(),
            ready_checks: Vec::new(),
            launches: Vec::new(),
            next_check: 0,
            next_hazard: 0,
            dev_dungeon_scale: 1.0,
            dev_dungeon_affixes: None,
            dev_dungeon_start: None,
            dev_cocoon_solo: false,
            store,
            stats: Stats::default(),
            params: MoveParams::default(),
        };
        sim.spawn_creatures();
        Ok(sim)
    }

    /// Makes this a dungeon map: copies side by side, these gates.
    pub fn set_copies(&mut self, gates: realm_sim::gates::Gates) {
        self.instanced = true;
        self.gates = gates;
        self.runs = (0..realm_rules::dungeons::COPIES).map(|_| None).collect();
    }

    /// Links this server to the coordinator (the link task reports through
    /// NetEvent::CoordUp / CoordDown).
    pub fn set_coord(
        &mut self,
        tx: tokio::sync::mpsc::UnboundedSender<realm_proto::coord::MapMsg>,
    ) {
        self.coord_tx = Some(tx);
    }

    /// Development: the map's world bosses are not standing at boot but
    /// rise `seconds` after it (announced as the old game did, a minute
    /// before), so their notices can be watched.
    pub fn dev_boss_respawn(&mut self, seconds: u32) {
        let tick = self.tick;
        for pack in 0..self.packs.len() {
            if !self.game.packs[pack].world_boss {
                continue;
            }
            let members = std::mem::take(&mut self.packs[pack].members);
            for e in members {
                self.despawn(e);
            }
            self.packs[pack].alive = 0;
            self.packs[pack].announced = false;
            self.packs[pack].respawn_at = Some(tick + seconds * realm_sim::SIM_HZ);
        }
    }

    pub fn creature_count(&self) -> usize {
        self.ids.len() - self.clients.len()
    }

    pub fn player_count(&self) -> usize {
        self.clients.len()
    }

    fn new_id(&mut self, entity: Entity) -> u32 {
        let id = self.next_id;
        self.next_id += 1;
        self.ids.insert(id, entity);
        id
    }

    fn ground(&self, x: f32, z: f32) -> f32 {
        self.terrain.ground_height(x, z).unwrap_or(0.0)
    }

    /// Every pack of the map, standing on its first anchor.
    fn spawn_creatures(&mut self) {
        let mut rng = 0x9E37_79B9_u32;
        for index in 0..self.game.packs.len() {
            let pack = &self.game.packs[index];
            let (count, species) = (pack.count, pack.species);
            let summons = matches!(pack.kind, crate::game::PackKind::Summons(_));
            let mut members = Vec::new();
            for _ in 0..if summons { 0 } else { count.max(1) } {
                let mob = Mob {
                    pack: index,
                    species: species as u16,
                    home: Vec3::ZERO,
                    pos: Vec3::ZERO,
                    yaw: (xorshift(&mut rng) & 0xFFFF) as u16,
                    hp: 1.0,
                    max_hp: 1.0,
                    level: 1,
                    attack_power: 0.0,
                    attack_range: 0.0,
                    move_speed: 0.0,
                    elite: false,
                    boss: false,
                    enraged: false,
                    pattern_next: 0,
                    exp_reward: 0,
                    credit: Vec::new(),
                    mode: MobMode::Idle,
                    attack_cd: 0.0,
                    attack: None,
                    attacks_made: 0,
                    thrown: Vec::new(),
                    hit_at: 0,
                    unreachable_since: 0,
                    next_scan: 0,
                    next_think: 0,
                    died_at: 0,
                    rng: xorshift(&mut rng) | 1,
                    state: STATE_IDLE,
                    path: Vec::new(),
                    path_goal: Vec3::ZERO,
                    replan_at: 0,
                    status: status::Status::default(),
                    drop_scale: 1.0,
                    windup_scale: 1.0,
                    part_of: None,
                    parts: Vec::new(),
                    phase: 1,
                };
                let entity = self.world.spawn(mob).id();
                let id = self.new_id(entity);
                self.world.entity_mut(entity).insert(NetId(id));
                members.push(entity);
            }
            self.packs.push(brain::PackState {
                anchor: Vec3::ZERO,
                members,
                alive: 0,
                respawn_at: None,
                waves_done: 0,
                announced: false,
            });
            self.pack_views.push(Vec::new());
        }
        for index in 0..self.packs.len() {
            if !matches!(
                self.game.packs[index].kind,
                crate::game::PackKind::Summons(_)
            ) {
                self.place_pack(index, true);
            }
        }
    }

    /// Runs one 30 Hz step.
    pub fn step(&mut self, events: impl Iterator<Item = NetEvent>) {
        let started = Instant::now();
        for event in events {
            self.handle(event);
        }
        self.maintenance_tick();
        // Maintenance: idle does nothing; frozen keeps only what lets the
        // players leave and see the world stand still.
        if self.maintenance.idle {
            self.tick += 1;
            return;
        }
        if self.maintenance.frozen {
            self.sweep_departing();
            self.rebuild_grid();
            self.dispatch_events();
            self.snapshots();
            self.tick += 1;
            return;
        }
        let mut mark = Instant::now();
        let mut lap = |section: usize, stats: &mut Stats| {
            let now = Instant::now();
            stats.sections[section] += (now - mark).as_secs_f64() * 1000.0;
            mark = now;
        };
        self.players();
        self.advance_casts();
        lap(0, &mut self.stats);
        self.creatures();
        lap(1, &mut self.stats);
        self.advance_bolts();
        self.advance_mob_bolts();
        self.advance_status();
        self.advance_afflictions();
        self.sweep_chests();
        self.quest_visits();
        self.party_vitals();
        self.tick_duels();
        self.advance_waylinks();
        self.expire_trips();
        self.sweep_departing();
        self.tick_runs();
        self.follow_parts();
        self.tick_hazards();
        self.tick_checks();
        self.regenerate();
        lap(2, &mut self.stats);
        self.rebuild_grid();
        lap(3, &mut self.stats);
        self.dispatch_events();
        self.snapshots();
        lap(4, &mut self.stats);
        self.autosave();
        self.stats
            .ticks
            .push(started.elapsed().as_secs_f32() * 1000.0);
        self.tick += 1;
    }

    fn handle(&mut self, event: NetEvent) {
        match event {
            NetEvent::Join {
                conn,
                ticket,
                outbox,
                control,
                reply,
            } => {
                let join = PendingJoin {
                    ticket,
                    outbox,
                    control,
                    reply,
                    arrival: None,
                    loading: false,
                };
                self.join(conn, join);
            }
            NetEvent::Loaded { conn, result } => {
                let Some(join) = self.pending.remove(&conn) else {
                    return;
                };
                match result {
                    Ok(sheet) => self.admit(conn, join, sheet.map(|s| *s)),
                    Err(e) => {
                        eprintln!("[store] load for connection {conn} failed: {e}");
                        let _ = join.reply.send(JoinReply::Refused(
                            "character could not be loaded".to_owned(),
                        ));
                    }
                }
            }
            NetEvent::Saved {
                character,
                revision,
                ok,
            } => self.save_answered(character, revision, ok),
            NetEvent::Control { conn, msg } => self.control(conn, msg),
            NetEvent::Input { conn, batch } => {
                let Some(client) = self.clients.get_mut(&conn) else {
                    return;
                };
                if batch.ack_snapshot > client.view.acked && batch.ack_snapshot < self.tick {
                    client.view.acked = batch.ack_snapshot;
                }
                let Some(mut player) = self.world.get_mut::<Player>(client.entity) else {
                    return;
                };
                // A frozen world takes no move; nothing is kept to replay.
                if self.maintenance.frozen {
                    player.pending.clear();
                    player.last_seq = player.last_seq.max(batch.newest_seq);
                    return;
                }
                let first = batch.newest_seq.wrapping_sub(batch.inputs.len() as u32 - 1);
                // A client more than two seconds ahead of what the server ran
                // (it stalled, or the server did) is resynchronised: its
                // backlog is dropped, never replayed, so moves cannot be banked.
                if batch.newest_seq > player.last_seq + RESYNC_AHEAD {
                    player.pending.clear();
                    player.last_seq = first.wrapping_sub(1);
                }
                for (i, frame) in batch.inputs.iter().enumerate() {
                    let seq = first.wrapping_add(i as u32);
                    if seq > player.last_seq {
                        player.pending.insert(seq, *frame);
                    }
                }
            }
            NetEvent::Leave { conn } => {
                self.pending.remove(&conn);
                if self.clients.contains_key(&conn) {
                    self.leave_world(conn, None);
                } else {
                    self.departed_conn_closed(conn);
                }
            }
            NetEvent::Coord(msg) => self.coord_event(msg),
            NetEvent::CoordUp => self.coord_link_up(),
            NetEvent::CoordDown => self.coord_link_down(),
        }
    }

    /// A login this server may admit (the coordinator's `sheet`, if it sent
    /// one): the same character playing here hands over its live sheet, a
    /// save on its way serves before the store, else the store loads it.
    fn join_here(&mut self, conn: ConnId, mut join: PendingJoin, sheet: Option<CharacterSheet>) {
        let character = join.ticket.character;
        // A departure from here already released is over: its old
        // connection (if still open) ends, the newest login plays.
        self.departing.remove(&character);
        // The same character already playing: the newest login takes over
        // with the sheet as it is in the world right now (the old
        // connection closes when its channels are dropped).
        let playing = self
            .clients
            .iter()
            .find(|(_, c)| c.character == character)
            .map(|(&old, _)| old);
        if let Some(old) = playing {
            let live = self.remove_player(old);
            return self.admit(conn, join, sheet.or(live));
        }
        if sheet.is_some() {
            return self.admit(conn, join, sheet);
        }
        if let Some(sheet) = self.unsaved.get(&character).cloned() {
            return self.admit(conn, join, Some(sheet));
        }
        // An older login of the same character still loading loses to this
        // one (two loads would admit the character twice).
        let older: Vec<ConnId> = self
            .pending
            .iter()
            .filter(|(c, j)| **c != conn && j.loading && j.ticket.character == character)
            .map(|(c, _)| *c)
            .collect();
        for c in older {
            if let Some(old) = self.pending.remove(&c) {
                let _ = old
                    .reply
                    .send(JoinReply::Refused("logged in elsewhere".to_owned()));
            }
        }
        join.loading = true;
        self.pending.insert(conn, join);
        let _ = self.store.send(StoreJob::Load { conn, character });
    }

    /// Puts a joining player in the world with its sheet (a new character
    /// when it has none yet) and sends it the join reply and its sheet.
    fn admit(&mut self, conn: ConnId, join: PendingJoin, sheet: Option<CharacterSheet>) {
        let character = join.ticket.character;
        let mut sheet = sheet.unwrap_or_else(|| {
            let house = self
                .game
                .houses
                .get(character as usize % self.game.houses.len().max(1))
                .cloned()
                .unwrap_or_default();
            self.game.rules.new_character(
                character,
                &format!("Wanderer {}", character % 10_000),
                &house,
            )
        });
        sheet.normalize();
        let home = self.spawn_point_for(character);
        let saved_here = sheet
            .place
            .as_ref()
            .filter(|p| p.map == self.game.map)
            .map(|p| self.settle(Vec3::new(p.pos[0], p.pos[1], p.pos[2])));
        let arrival = join.arrival.clone();
        // A dungeon map: the copy of the character's run (none: it leaves).
        let copy = if self.instanced {
            self.copy_for_join(
                character,
                arrival.as_ref().map_or(0, |a| a.copy),
                sheet
                    .place
                    .as_ref()
                    .filter(|p| p.map == self.game.map)
                    .map(|p| p.pos[0]),
            )
        } else {
            Some(0)
        };
        let eject = copy.is_none() && self.coord_tx.is_some();
        // Without a run (or a coordinator to leave through) it stands in
        // copy 1.
        let copy = copy.unwrap_or(u8::from(self.instanced));
        let landed = arrival.as_ref().map(|a| self.land_in(copy, &a.landing));
        let saved_here =
            saved_here.filter(|p| !self.instanced || realm_rules::dungeons::copy_at(p.x) == copy);
        let home = if self.instanced {
            self.settle(home + dungeon::offset_of(copy))
        } else {
            home
        };
        let derived = self.game.rules.derived(&sheet);
        let max_hp = derived.max_hp.max(1) as f32;
        let caster = Caster::new(sheet.mana as f32, derived);
        // A character saved dead comes back whole at the map's spawn.
        let (start, hp) = if sheet.hp == 0 {
            (home, max_hp)
        } else {
            (
                landed.or(saved_here).unwrap_or(home),
                (sheet.hp as f32).min(max_hp),
            )
        };
        let player = Player {
            body: Body::at(start),
            pending: BTreeMap::new(),
            last_seq: 0,
            last_frame: InputFrame::default(),
            hp,
            max_hp,
            dead_until: 0,
            home,
            last_ground: start,
            allowance: 0,
            gap_ticks: 0,
            last_input_tick: self.tick,
            life: 0,
            chat_ready: 0,
            info_key: 0,
            party: realm_proto::coord::PartyView::default(),
            respawn_ready: 0,
            sheet,
            dirty_since: None,
            caster,
            last_combat: 0,
            afflictions: afflict::Afflictions::default(),
            restraint: realm_sim::movement::Restraint::default(),
            last_hurt: 0,
            trip: None,
        };
        let entity = self.world.spawn(player).id();
        let id = self.new_id(entity);
        self.world.entity_mut(entity).insert(NetId(id));
        let phase = (conn as u32) % SNAPSHOT_EVERY;
        let view = View {
            history: VecDeque::new(),
            acked: 0,
            priority: IdMap::default(),
        };
        self.clients.insert(
            conn,
            Client {
                entity,
                net_id: id,
                character,
                account: join.ticket.account,
                outbox: join.outbox,
                control: join.control,
                view,
                phase,
                bytes: 0,
                events: Vec::new(),
            },
        );
        self.announce(entity);
        let _ = join.reply.send(JoinReply::Accepted {
            entity: id,
            tick: self.tick,
            content_hash: self.content_hash,
            copy,
        });
        self.send_sheet(conn);
        self.tell_maintenance(conn);
        self.tell_weather(conn);
        if let Some(arrival) = &arrival {
            self.arrived(conn, entity, arrival);
        }
        if self.instanced {
            if eject {
                self.eject_from_dungeon(conn, entity);
            } else {
                self.copy_joined(conn, copy);
            }
        }
    }

    /// Takes a player out of the world and saves its sheet; returns the
    /// sheet. Dropping the client's channels closes its connection if it is
    /// still open (a newer login took over).
    fn remove_player(&mut self, conn: ConnId) -> Option<CharacterSheet> {
        self.take_out(conn, None).map(|(_, sheet)| sheet)
    }

    /// Takes a player out of the world and saves its sheet (with `place`
    /// instead of where it stands, for a traveller); returns its client and
    /// sheet.
    fn take_out(
        &mut self,
        conn: ConnId,
        place: Option<realm_rules::Place>,
    ) -> Option<(Client, CharacterSheet)> {
        let client = self.clients.remove(&conn)?;
        let mut sheet = self.sheet_of(client.entity)?;
        if place.is_some() {
            sheet.place = place;
        }
        self.ids.remove(&client.net_id);
        self.world.despawn(client.entity);
        self.save(sheet.clone());
        Some((client, sheet))
    }

    /// The player's sheet with its live position and hp written back.
    fn sheet_of(&self, entity: Entity) -> Option<CharacterSheet> {
        let player = self.world.get::<Player>(entity)?;
        let mut sheet = player.sheet.clone();
        let pos = if player.dead_until != 0 {
            player.home
        } else {
            player.body.pos
        };
        sheet.place = Some(Place {
            map: self.game.map.clone(),
            pos: [pos.x, pos.y, pos.z],
            yaw: player.last_frame.movement.yaw_radians(),
        });
        sheet.hp = libm::ceilf(player.hp.max(0.0)) as u32;
        sheet.mana = libm::ceilf(player.caster.mana.max(0.0)) as u32;
        Some(sheet)
    }

    fn save(&mut self, sheet: CharacterSheet) {
        self.unsaved.insert(sheet.id, sheet.clone());
        let _ = self.store.send(StoreJob::Save(Box::new(sheet)));
    }

    fn send_control(&mut self, conn: ConnId, msg: &ServerMsg) {
        let Some(client) = self.clients.get(&conn) else {
            return;
        };
        // A client that lets this many reliable messages pile up is gone or
        // hostile; it is dropped rather than buffered without end.
        if client
            .control
            .try_send(Bytes::from(control::encode_server(msg)))
            .is_err()
        {
            eprintln!("[net] connection {conn}: control queue full, closing");
            self.leave_world(conn, None);
        }
    }

    fn send_sheet(&mut self, conn: ConnId) {
        let Some(entity) = self.clients.get(&conn).map(|c| c.entity) else {
            return;
        };
        if let Some(sheet) = self.sheet_of(entity) {
            self.send_control(conn, &ServerMsg::Sheet(Box::new(sheet)));
        }
        self.refresh_info(entity);
    }

    fn control(&mut self, conn: ConnId, msg: ClientMsg) {
        let Some(entity) = self.clients.get(&conn).map(|c| c.entity) else {
            return;
        };
        // From the save barrier on, nothing a player asks is done (the
        // saved sheet is the final one).
        if self.maintenance.frozen {
            return;
        }
        match msg {
            ClientMsg::Look(raw) => {
                let look = self.game.rules.looks.clean(&raw);
                let tick = self.tick;
                let Some(mut player) = self.world.get_mut::<Player>(entity) else {
                    return;
                };
                if player.sheet.look == look {
                    return;
                }
                player.sheet.look = look;
                player.sheet.revision += 1;
                player.dirty_since.get_or_insert(tick);
                self.send_sheet(conn);
            }
            ClientMsg::Item {
                op_id,
                revision,
                op,
            } => self.item_op(conn, entity, op_id, revision, &op),
            ClientMsg::LearnSkill(spell) => self.learn_skill(conn, entity, spell),
            ClientMsg::OpenChest(id) => self.open_chest(conn, entity, id),
            ClientMsg::TakeLoot { chest, slot } => self.take_loot(conn, entity, chest, slot),
            ClientMsg::Respawn { here } => self.request_respawn(entity, here),
            ClientMsg::SpendAttribute(stat) => self.spend_attribute(conn, entity, stat),
            ClientMsg::Talk(name) => self.talk(entity, &name),
            ClientMsg::ClaimQuest(id) => self.claim_quest(conn, entity, id),
            ClientMsg::Chat(text) => self.chat(conn, entity, &text),
            ClientMsg::Door(id) => self.request_door(conn, entity, &id),
            ClientMsg::Travel { from, to } => self.request_node_trip(conn, entity, &from, &to),
            ClientMsg::Ride(on) => self.request_ride(conn, entity, on),
            ClientMsg::WaylinkPlace(dest) => self.place_waylink(conn, entity, &dest),
            ClientMsg::WaylinkHold { id, hold } => self.hold_waylink(conn, entity, id, hold),
            ClientMsg::DungeonInfo(portal) => self.dungeon_info(conn, entity, &portal),
            ClientMsg::DungeonStart { portal, difficulty } => {
                self.dungeon_start(conn, entity, &portal, difficulty);
            }
            ClientMsg::DungeonReady { id, yes } => self.dungeon_ready(entity, id, yes),
            ClientMsg::DungeonGuide => self.dungeon_guide(conn, entity),
            ClientMsg::Inspect(id) => {
                let player = self.ids.get(&id).and_then(|e| self.player_info(*e));
                let Some(info) = player.or_else(|| self.creature_info(id)) else {
                    return;
                };
                self.send_control(conn, &info);
            }
        }
    }

    /// Spends a skill point: learns `spell` or raises it one level.
    fn learn_skill(&mut self, conn: ConnId, entity: Entity, spell: String) {
        let tick = self.tick;
        let combat = &self.game.rules.combat;
        let Some(player) = self.world.get::<Player>(entity) else {
            return;
        };
        let level = combat.skill_level(&player.sheet, &spell);
        let reason = if !combat.skill_upgradeable(&spell) {
            "not_a_skill"
        } else if level >= combat.skills.max_level {
            "max_level"
        } else if combat.skill_points(&player.sheet) == 0 {
            "no_points"
        } else if player.dead_until != 0 {
            "dead"
        } else {
            "learned"
        };
        let ok = reason == "learned";
        if ok && let Some(mut player) = self.world.get_mut::<Player>(entity) {
            let skills = &mut player.sheet.skills;
            match skills.iter_mut().find(|(s, _)| *s == spell) {
                Some(entry) => entry.1 += 1,
                None => skills.push((spell.clone(), 1)),
            }
            player.sheet.revision += 1;
            player.dirty_since.get_or_insert(tick);
        }
        self.send_control(
            conn,
            &ServerMsg::SkillResult {
                spell,
                ok,
                reason: reason.to_owned(),
            },
        );
        if ok {
            self.send_sheet(conn);
        }
    }

    /// One item request: gates from the server's own state, the rules do
    /// the rest; the answer and (on success) the new sheet go back.
    fn item_op(
        &mut self,
        conn: ConnId,
        entity: Entity,
        op_id: u32,
        revision: u64,
        op: &realm_rules::ItemOp,
    ) {
        let tick = self.tick;
        let Some(mut sheet) = self.sheet_of(entity) else {
            return;
        };
        let reply = if sheet.revision != revision {
            Err("stale")
        } else {
            let Some(player) = self.world.get::<Player>(entity) else {
                return;
            };
            let pos = player.body.pos;
            let ctx = realm_rules::ItemContext {
                dead: player.dead_until != 0,
                in_combat: player.last_combat != 0 && tick < player.last_combat + COMBAT_LOCK_TICKS,
                // A spell being drawn (wound up, not yet over): no gear
                // change mid-cast, as in the old game; potions still go.
                casting: player
                    .caster
                    .cast
                    .as_ref()
                    .is_some_and(|c| tick < c.end_tick),
                mounted: player.body.mounted,
                at_shop: self.game.rules.at_hearth(&self.game.map, pos.x, pos.z),
                at_dungeon_gate: self.near_dungeon_gate(pos),
            };
            let mut dice = ServerDice(xorshift(&mut self.dice_state) | 1);
            let result = self
                .game
                .rules
                .apply_item_op(&mut sheet, op, ctx, &mut dice);
            self.dice_state = dice.0;
            result
        };
        let (ok, reason, amount) = match reply {
            Ok(done) => (true, done.reason, done.amount),
            Err(reason) => (false, reason, 0),
        };
        // Quest events: what the operation did, and to which slot.
        let quest = match (ok, reason, op) {
            (
                true,
                "equipped",
                realm_rules::ItemOp::Move {
                    to: realm_rules::Cell::Worn(slot),
                    ..
                },
            ) => Some(("equip", slot.name().to_owned())),
            (true, "refined", _) => Some(("refine", String::new())),
            (true, "enchanted", _) => Some(("enchant", String::new())),
            _ => None,
        };
        if ok {
            let derived = self.game.rules.derived(&sheet);
            let max_hp = derived.max_hp.max(1) as f32;
            if let Some(mut player) = self.world.get_mut::<Player>(entity) {
                // A potion changed hp or mana; gear may have changed the
                // maximums and every stat the casts and hits read.
                player.max_hp = max_hp;
                player.hp = (sheet.hp as f32).min(max_hp);
                player.caster.max_mana = derived.max_mana as f32;
                player.caster.mana = (sheet.mana as f32).min(player.caster.max_mana);
                player.caster.derived = derived;
                sheet.place = None;
                player.sheet = sheet;
                player.dirty_since.get_or_insert(tick);
            }
        }
        self.send_control(
            conn,
            &ServerMsg::ItemResult {
                op_id,
                ok,
                reason: reason.to_owned(),
                amount,
            },
        );
        if let Some((kind, target)) = quest {
            self.quest_event(entity, kind, &target, false);
        }
        if ok || reason == "stale" {
            self.send_sheet(conn);
        }
    }

    /// Saves a changed sheet once it has been quiet for a while, and every
    /// player every 30 s, spread so only a few save on any one tick.
    fn autosave(&mut self) {
        let tick = self.tick;
        let due: Vec<Entity> = self
            .clients
            .values()
            .filter(|c| {
                let regular = (c.character as u32)
                    .wrapping_add(tick)
                    .is_multiple_of(AUTOSAVE_TICKS);
                let changed = self
                    .world
                    .get::<Player>(c.entity)
                    .and_then(|p| p.dirty_since)
                    .is_some_and(|since| tick >= since + SAVE_DEBOUNCE_TICKS);
                regular || changed
            })
            .map(|c| c.entity)
            .collect();
        for entity in due {
            if let Some(mut player) = self.world.get_mut::<Player>(entity) {
                player.dirty_since = None;
            }
            if let Some(sheet) = self.sheet_of(entity) {
                self.save(sheet);
            }
        }
    }

    /// Saves every player now (the server is stopping).
    pub fn save_all(&mut self) {
        let entities: Vec<Entity> = self.clients.values().map(|c| c.entity).collect();
        for entity in entities {
            if let Some(sheet) = self.sheet_of(entity) {
                self.save(sheet);
            }
        }
    }

    /// Where a joining player appears. A map spawn point is authored with
    /// its height: the ground is looked for just under it, so indoors the body
    /// lands on the floor, not on the roof above it. Next to a creature pack
    /// (outdoors) the highest surface is the ground.
    fn spawn_point_for(&self, character: u64) -> Vec3 {
        if !self.dev_spawn_packs.is_empty() {
            let pick = (character as usize).wrapping_mul(7919) % self.dev_spawn_packs.len();
            let pack = &self.game.packs[self.dev_spawn_packs[pick]];
            let (x, z) = (pack.center.0 + 14.0, pack.center.1);
            return Vec3::new(x, self.ground(x, z) + 0.05, z);
        }
        let spawn = self.game.spawn_point;
        let floor = self
            .terrain
            .ray_down(spawn + Vec3::new(0.0, 1.5, 0.0), 6.0)
            .map_or(spawn.y, |hit| hit.point.y);
        Vec3::new(spawn.x, floor + 0.05, spawn.z)
    }

    /// Moves every player by its next input and starts its actions.
    fn players(&mut self) {
        let tick = self.tick;
        // Moving staircases take their pose for this tick before anyone moves.
        self.stairs.apply(&mut self.terrain, tick);
        let has_stairs = !self.stairs.flights.is_empty();
        let mut stairs_at = tick;
        // A dungeon's gates, the same way (a dungeon has no staircases).
        let has_gates = !self.gates.is_empty();
        if has_gates {
            self.gates.apply(&mut self.terrain, tick);
        }
        let mut gates_at = tick;
        let mut casts: Vec<(Entity, InputFrame)> = Vec::new();
        let mut risen: Vec<Entity> = Vec::new();
        let mut query = self.world.query::<(Entity, &mut Player)>();
        for (entity, mut player) in query.iter_mut(&mut self.world) {
            if player.dead_until != 0 {
                // The dead still consume their inputs (without effect), so the
                // client's sequence and acknowledgements keep moving.
                if let Some((&newest, _)) = player.pending.iter().next_back() {
                    player.last_seq = newest;
                }
                player.pending.clear();
                if tick >= player.dead_until {
                    risen.push(entity);
                }
                continue;
            }
            // Each received input runs exactly once, in sequence, on the world
            // as it was on the tick the client ran it, so when an input
            // arrives never changes what it does. Nothing is invented for an
            // input that has not arrived: the body waits for it. A client gets
            // one step per tick on average and a short burst after a stall,
            // so it cannot speed itself up.
            player.allowance = (player.allowance + 1).min(STEP_CREDIT);
            let mut burst = MAX_BURST;
            while player.allowance > 0 && burst > 0 {
                let next = player.last_seq + 1;
                let Some(frame) = player.pending.remove(&next) else {
                    // A gap that stays open while later inputs arrive means those
                    // inputs were lost for good (every packet repeating them was
                    // dropped): skip them.
                    match player.pending.keys().next() {
                        Some(&first) if player.gap_ticks >= LOST_AFTER_TICKS => {
                            player.last_seq = first - 1;
                            player.gap_ticks = 0;
                            continue;
                        }
                        Some(_) => player.gap_ticks += 1,
                        None => {}
                    }
                    break;
                };
                player.gap_ticks = 0;
                player.allowance -= 1;
                burst -= 1;
                player.last_seq = next;
                player.last_frame = frame;
                let input_tick = frame.tick.clamp(
                    tick.saturating_sub(INPUT_TICK_WINDOW),
                    tick + INPUT_TICK_WINDOW,
                );
                player.last_input_tick = input_tick;
                if has_stairs && input_tick != stairs_at {
                    self.stairs.apply(&mut self.terrain, input_tick);
                    stairs_at = input_tick;
                }
                if has_gates && input_tick != gates_at {
                    self.gates.apply(&mut self.terrain, input_tick);
                    gates_at = input_tick;
                }
                let mut body = player.body;
                self.stairs.carry(&mut body, input_tick);
                let params = player.restraint.params(&self.params, input_tick);
                movement::step(&mut body, frame.movement, &params, &self.terrain);
                player.body = body;
                if body.pos.y < self.game.y_min {
                    if self.stats.fallen == 0 {
                        self.stats.fell_at = Some(player.last_ground);
                    }
                    self.stats.fallen += 1;
                } else if body.on_floor {
                    player.last_ground = body.pos;
                }
                self.stats.roamed = self
                    .stats
                    .roamed
                    .max(planar_distance(body.pos, player.home));
                if frame.action != 0 {
                    casts.push((entity, frame));
                }
            }
        }
        if stairs_at != tick {
            self.stairs.apply(&mut self.terrain, tick);
        }
        if has_gates && gates_at != tick {
            self.gates.apply(&mut self.terrain, tick);
        }
        for (caster, frame) in casts {
            self.request_cast(caster, frame);
        }
        // No choice made in time: to town.
        for player in risen {
            self.respawn(player, false);
        }
    }

    /// Collects every visible entity's replicated state into rows and files
    /// them by cell.
    fn rebuild_grid(&mut self) {
        self.rows.clear();
        for cell in &mut self.cells {
            cell.clear();
        }
        let tick = self.tick;
        let mut players = self.world.query::<(Entity, &NetId, &Player)>();
        for (entity, id, p) in players.iter(&self.world) {
            let state = EntityState {
                pos: realm_proto::on_grid(p.body.pos),
                yaw: p.last_frame.movement.yaw,
                state: if p.dead_until != 0 {
                    STATE_DEAD
                } else if p.body.vel.length_squared() > 0.25 {
                    STATE_MOVING
                } else {
                    STATE_IDLE
                } | if p.body.mounted {
                    realm_proto::STATE_MOUNTED
                } else {
                    0
                },
                kind: 0,
                hp: hp_byte(p.hp, p.max_hp),
                status: p.afflictions.bits(tick),
            };
            self.rows.push(Row {
                id: id.0,
                entity,
                state,
                is_player: true,
            });
        }
        let mut chests = self.world.query::<(Entity, &NetId, &rewards::Chest)>();
        for (entity, id, c) in chests.iter(&self.world) {
            self.rows.push(Row {
                id: id.0,
                entity,
                state: EntityState {
                    pos: realm_proto::on_grid(c.pos),
                    yaw: 0,
                    state: STATE_IDLE,
                    kind: if c.rare {
                        realm_proto::KIND_CHEST_RARE
                    } else {
                        realm_proto::KIND_CHEST
                    },
                    hp: 255,
                    status: 0,
                },
                is_player: false,
            });
        }
        let mut mobs = self.world.query::<(Entity, &NetId, &Mob)>();
        for (entity, id, m) in mobs.iter(&self.world) {
            if m.mode == MobMode::Dead && tick > m.died_at + CORPSE_TICKS {
                continue;
            }
            let state = EntityState {
                pos: realm_proto::on_grid(m.pos),
                yaw: m.yaw,
                state: m.state,
                kind: (m.species + 1)
                    | if m.elite { realm_proto::KIND_ELITE } else { 0 }
                    | if m.enraged {
                        realm_proto::KIND_ENRAGED
                    } else {
                        0
                    }
                    | if m.boss { realm_proto::KIND_BOSS } else { 0 },
                hp: hp_byte(m.hp, m.max_hp),
                status: if m.mode == MobMode::Dead {
                    0
                } else {
                    m.status.bits(tick)
                },
            };
            self.rows.push(Row {
                id: id.0,
                entity,
                state,
                is_player: false,
            });
        }
        for (index, row) in self.rows.iter().enumerate() {
            if let Some(cell) = cell_of(row.state.pos) {
                self.cells[cell].push(index as u32);
            }
        }
    }

    fn snapshots(&mut self) {
        let tick = self.tick;
        let interest_cells = (INTEREST_KEEP / CELL).ceil() as i32;
        let mut sent = 0_u64;
        let mut count = 0_u64;
        for client in self.clients.values_mut() {
            if tick % SNAPSHOT_EVERY != client.phase {
                continue;
            }
            // Combat events since the last snapshot go first, on the
            // reliable channel (a full queue drops the client like any other
            // reliable message would).
            if !client.events.is_empty() {
                let batch = std::mem::take(&mut client.events);
                let _ = client.control.try_send(Bytes::from(control::encode_server(
                    &ServerMsg::Combat(batch),
                )));
            }
            let Some(player) = self.world.get::<Player>(client.entity) else {
                continue;
            };
            let center = player.body.pos;
            let view = &mut client.view;
            let baseline = view
                .history
                .iter()
                .find(|(t, _)| *t == view.acked)
                .map(|(t, set)| (*t, set.as_slice()));
            let base: &[(u32, EntityState)] = baseline.map_or(&[], |(_, set)| set);
            let known = |id: u32| {
                base.binary_search_by_key(&id, |e| e.0)
                    .ok()
                    .map(|i| base[i].1)
            };

            // Candidates: in range (or already known and not yet too far).
            // Known ones enter `next` at their baseline state; the ones chosen
            // below are updated to their current state.
            let mut next: EntitySet = Vec::with_capacity(base.len() + 16);
            let mut changed: Vec<(f32, u32, EntityState, Option<usize>)> = Vec::new();
            for cell in cells_around(center, interest_cells) {
                for &index in &self.cells[cell] {
                    let row = &self.rows[index as usize];
                    if row.entity == client.entity {
                        continue;
                    }
                    let d2 = planar_distance_sq(row.state.pos, center);
                    if d2 > INTEREST_KEEP * INTEREST_KEEP {
                        continue;
                    }
                    let old = known(row.id);
                    if old.is_none() && d2 > INTEREST_RADIUS * INTEREST_RADIUS {
                        continue;
                    }
                    let d = d2.sqrt();
                    match old {
                        Some(old) if old == row.state => next.push((row.id, old)),
                        Some(old) => {
                            next.push((row.id, old));
                            let acc = view.priority.entry(row.id).or_insert(0.0);
                            *acc += if d < 20.0 {
                                1.0
                            } else if d < 40.0 {
                                0.5
                            } else {
                                0.25
                            };
                            changed.push((*acc, row.id, row.state, Some(next.len() - 1)));
                        }
                        None => {
                            let near = if row.is_player { 2.0 } else { 1.0 };
                            changed.push((100.0 + near - d * 0.01, row.id, row.state, None));
                        }
                    }
                }
            }
            changed.sort_unstable_by(|a, b| b.0.total_cmp(&a.0));
            let mut budget = ENTITY_BUDGET;
            for (_, id, state, slot) in changed {
                let cost = if slot.is_some() { 6 } else { 14 };
                if cost > budget {
                    continue;
                }
                budget -= cost;
                match slot {
                    Some(i) => next[i].1 = state,
                    None => next.push((id, state)),
                }
                view.priority.insert(id, 0.0);
            }
            next.sort_unstable_by_key(|e| e.0);
            if view.priority.len() > next.len() * 2 {
                view.priority
                    .retain(|id, _| next.binary_search_by_key(id, |e| e.0).is_ok());
            }

            let snapshot = Snapshot {
                tick,
                baseline_tick: baseline.map_or(0, |(t, _)| t),
                last_input_seq: player.last_seq,
                own: player.body,
                own_hp: hp_byte(player.hp, player.max_hp),
                own_vitals: [
                    libm::ceilf(player.hp.max(0.0)) as u32,
                    player.max_hp as u32,
                    libm::ceilf(player.caster.mana.max(0.0)) as u32,
                    player.caster.max_mana as u32,
                ],
                own_restraint: player.restraint,
                own_status: player.afflictions.bits(tick),
                own_life: player.life,
                entities: next,
            };
            let bytes = realm_proto::encode_snapshot(&snapshot, baseline.map(|(_, s)| s));
            if bytes.len() > realm_proto::MAX_DATAGRAM {
                // Over the datagram limit (a crowd appeared at once): skip
                // this one; the next starts from the same baseline with the
                // priorities that grew meanwhile.
                continue;
            }
            sent += bytes.len() as u64;
            count += 1;
            client.bytes += bytes.len() as u64;
            let _ = client.outbox.try_send(Bytes::from(bytes));
            view.history.push_back((tick, snapshot.entities));
            while view.history.len() > HISTORY {
                view.history.pop_front();
            }
        }
        self.stats.bytes_out += sent;
        self.stats.snapshots += count;
    }
}
