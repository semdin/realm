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
use realm_sim::movement::{self, Body, MoveParams};
use realm_sim::nav::{NavQuery, NavScratch};
use realm_sim::staircase::Staircases;
use realm_sim::world::World as Terrain;
use realm_sim::{SIM_DT, Vec3};

use crate::game::Game;
use crate::store::StoreJob;

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
        result: Result<Option<CharacterSheet>, String>,
    },
    /// The store thread finished a save.
    Saved {
        character: u64,
        revision: u64,
    },
    Input {
        conn: ConnId,
        batch: InputBatch,
    },
    Leave {
        conn: ConnId,
    },
}

/// Every player is saved once in this many ticks (30 s), spread over them.
const AUTOSAVE_TICKS: u32 = 30 * 30;
/// A changed sheet is saved this long after its last change (5 s).
const SAVE_DEBOUNCE_TICKS: u32 = 5 * 30;
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
const PROJECTILE_HIT_RADIUS: f32 = 0.7;
const CHEST: f32 = 1.15;
/// Most steps a player may run in one tick (catching up after a stall).
const MAX_BURST: u32 = 4;
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
    cooldown: u16,
    hp: f32,
    max_hp: f32,
    dead_until: u32,
    home: Vec3,
    /// Last place the body stood on ground.
    last_ground: Vec3,
    /// Steps this player may still run (one more per tick, capped).
    allowance: u32,
    /// Ticks the next input has been missing while later ones wait.
    gap_ticks: u32,
    /// The character record. Position and hp live in `body` / `hp` while
    /// playing and are written back by `Sim::sheet_of`.
    sheet: CharacterSheet,
    /// Tick of the first unsaved change, if any.
    dirty_since: Option<u32>,
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
    mode: MobMode,
    attack_cd: u16,
    next_think: u32,
    respawn_at: u32,
    died_at: u32,
    rng: u32,
    state: u8,
    /// Corners still to walk to the current goal, nearest first.
    path: Vec<Vec3>,
    /// The goal the path was planned for, and when to plan again.
    path_goal: Vec3,
    replan_at: u32,
}

struct Projectile {
    owner: Entity,
    target: Entity,
    pos: Vec3,
    damage: f32,
    left: f32,
    speed: f32,
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
    outbox: tokio::sync::mpsc::Sender<Bytes>,
    control: tokio::sync::mpsc::Sender<Bytes>,
    view: View,
    phase: u32,
    bytes: u64,
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
}

struct PendingJoin {
    ticket: Ticket,
    outbox: tokio::sync::mpsc::Sender<Bytes>,
    control: tokio::sync::mpsc::Sender<Bytes>,
    reply: tokio::sync::oneshot::Sender<JoinReply>,
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
    projectiles: Vec<Projectile>,
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
    /// Joins waiting for their character to load.
    pending: HashMap<ConnId, PendingJoin>,
    /// The newest sheet of each character whose save has not finished: a
    /// join reads it instead of the store's older copy.
    unsaved: HashMap<u64, CharacterSheet>,
    store: crossbeam_channel::Sender<StoreJob>,
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
                        species.is_empty() || game.species[game.packs[i].species].id == species
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
            projectiles: Vec::new(),
            rows: Vec::new(),
            cells: vec![Vec::new(); GRID_DIM * GRID_DIM],
            player_cells: vec![Vec::new(); GRID_DIM * GRID_DIM],
            player_pos: HashMap::new(),
            awake: vec![false; GRID_DIM * GRID_DIM],
            nav,
            nav_scratch: NavScratch::default(),
            stairs,
            dev_spawn_packs,
            pending: HashMap::new(),
            unsaved: HashMap::new(),
            store,
            stats: Stats::default(),
            params: MoveParams::default(),
        };
        sim.spawn_creatures();
        Ok(sim)
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

    fn spawn_creatures(&mut self) {
        let mut rng = 0x9E37_79B9_u32;
        for index in 0..self.game.packs.len() {
            let pack = &self.game.packs[index];
            let (count, center, half_extent, species) =
                (pack.count, pack.center, pack.half_extent, pack.species);
            let max_hp = self.game.mob_max_hp(pack);
            for _ in 0..count {
                let x = center.0 + (unit(&mut rng) * 2.0 - 1.0) * half_extent.0.max(1.0);
                let z = center.1 + (unit(&mut rng) * 2.0 - 1.0) * half_extent.1.max(1.0);
                let home = Vec3::new(x, self.terrain.ground_height(x, z).unwrap_or(0.0), z);
                let mob = Mob {
                    pack: index,
                    species: species as u16,
                    home,
                    pos: home,
                    yaw: (xorshift(&mut rng) & 0xFFFF) as u16,
                    hp: max_hp,
                    max_hp,
                    mode: MobMode::Idle,
                    attack_cd: 0,
                    next_think: 0,
                    respawn_at: 0,
                    died_at: 0,
                    rng: xorshift(&mut rng) | 1,
                    state: STATE_IDLE,
                    path: Vec::new(),
                    path_goal: home,
                    replan_at: 0,
                };
                let entity = self.world.spawn(mob).id();
                let id = self.new_id(entity);
                self.world.entity_mut(entity).insert(NetId(id));
            }
        }
    }

    /// Runs one 30 Hz step.
    pub fn step(&mut self, events: impl Iterator<Item = NetEvent>) {
        let started = Instant::now();
        for event in events {
            self.handle(event);
        }
        let mut mark = Instant::now();
        let mut lap = |section: usize, stats: &mut Stats| {
            let now = Instant::now();
            stats.sections[section] += (now - mark).as_secs_f64() * 1000.0;
            mark = now;
        };
        self.players();
        lap(0, &mut self.stats);
        self.creatures();
        lap(1, &mut self.stats);
        self.projectiles();
        lap(2, &mut self.stats);
        self.rebuild_grid();
        lap(3, &mut self.stats);
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
                let character = ticket.character;
                let join = PendingJoin {
                    ticket,
                    outbox,
                    control,
                    reply,
                };
                // The same character already playing: the newest login takes
                // over with the sheet as it is in the world right now (the
                // old connection closes when its channels are dropped).
                let playing = self
                    .clients
                    .iter()
                    .find(|(_, c)| c.character == character)
                    .map(|(&old, _)| old);
                if let Some(old) = playing {
                    let sheet = self.remove_player(old);
                    self.admit(conn, join, sheet);
                } else if let Some(sheet) = self.unsaved.get(&character).cloned() {
                    self.admit(conn, join, Some(sheet));
                } else {
                    self.pending.insert(conn, join);
                    let _ = self.store.send(StoreJob::Load { conn, character });
                }
            }
            NetEvent::Loaded { conn, result } => {
                let Some(join) = self.pending.remove(&conn) else {
                    return;
                };
                match result {
                    Ok(sheet) => self.admit(conn, join, sheet),
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
            } => {
                if self
                    .unsaved
                    .get(&character)
                    .is_some_and(|s| s.revision <= revision)
                {
                    self.unsaved.remove(&character);
                }
            }
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
                self.remove_player(conn);
            }
        }
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
            .map(|p| Vec3::new(p.pos[0], p.pos[1], p.pos[2]));
        let max_hp = sheet.base_max_hp.max(1) as f32;
        // A character saved dead comes back whole at the map's spawn.
        let (start, hp) = if sheet.hp == 0 {
            (home, max_hp)
        } else {
            (saved_here.unwrap_or(home), (sheet.hp as f32).min(max_hp))
        };
        let player = Player {
            body: Body::at(start),
            pending: BTreeMap::new(),
            last_seq: 0,
            last_frame: InputFrame::default(),
            cooldown: 0,
            hp,
            max_hp,
            dead_until: 0,
            home,
            last_ground: start,
            allowance: 0,
            gap_ticks: 0,
            sheet,
            dirty_since: None,
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
                outbox: join.outbox,
                control: join.control,
                view,
                phase,
                bytes: 0,
            },
        );
        let _ = join.reply.send(JoinReply::Accepted {
            entity: id,
            tick: self.tick,
            content_hash: self.content_hash,
        });
        self.send_sheet(conn);
    }

    /// Takes a player out of the world and saves its sheet; returns the
    /// sheet. Dropping the client's channels closes its connection if it is
    /// still open (a newer login took over).
    fn remove_player(&mut self, conn: ConnId) -> Option<CharacterSheet> {
        let client = self.clients.remove(&conn)?;
        let sheet = self.sheet_of(client.entity);
        self.ids.remove(&client.net_id);
        self.world.despawn(client.entity);
        if let Some(sheet) = &sheet {
            self.save(sheet.clone());
        }
        sheet
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
            self.remove_player(conn);
        }
    }

    fn send_sheet(&mut self, conn: ConnId) {
        let Some(entity) = self.clients.get(&conn).map(|c| c.entity) else {
            return;
        };
        if let Some(sheet) = self.sheet_of(entity) {
            self.send_control(conn, &ServerMsg::Sheet(sheet));
        }
    }

    fn control(&mut self, conn: ConnId, msg: ClientMsg) {
        let Some(entity) = self.clients.get(&conn).map(|c| c.entity) else {
            return;
        };
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
        let mut casts: Vec<(Entity, u32)> = Vec::new();
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
                    player.dead_until = 0;
                    player.hp = player.max_hp;
                    let home = player.home;
                    player.body = Body::at(home);
                }
                continue;
            }
            // Each received input runs exactly once, in sequence, on the world
            // as it was on the tick the client ran it, so when an input
            // arrives never changes what it does. Nothing is invented for an
            // input that has not arrived: the body waits for it. A client gets
            // one step per tick on average and a short burst after a stall,
            // so it cannot speed itself up.
            player.allowance = (player.allowance + 1).min(MAX_BURST);
            while player.allowance > 0 {
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
                player.last_seq = next;
                player.last_frame = frame;
                let input_tick = frame.tick.clamp(
                    tick.saturating_sub(INPUT_TICK_WINDOW),
                    tick + INPUT_TICK_WINDOW,
                );
                if has_stairs && input_tick != stairs_at {
                    self.stairs.apply(&mut self.terrain, input_tick);
                    stairs_at = input_tick;
                }
                let mut body = player.body;
                self.stairs.carry(&mut body, input_tick);
                movement::step(&mut body, frame.movement, &self.params, &self.terrain);
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
                player.cooldown = player.cooldown.saturating_sub(1);
                if frame.action == 1 && player.cooldown == 0 {
                    casts.push((entity, frame.target));
                }
            }
        }
        if stairs_at != tick {
            self.stairs.apply(&mut self.terrain, tick);
        }
        for (caster, target_id) in casts {
            self.start_basic_attack(caster, target_id);
        }
    }

    fn start_basic_attack(&mut self, caster: Entity, target_id: u32) {
        let Some(&target) = self.ids.get(&target_id) else {
            self.stats.refused[0] += 1;
            return;
        };
        let Some(origin) = self.world.get::<Player>(caster).map(|p| p.body.pos) else {
            return;
        };
        let Some(target_pos) = self
            .world
            .get::<Mob>(target)
            .filter(|m| m.mode != MobMode::Dead)
            .map(|m| m.pos)
        else {
            self.stats.refused[1] += 1;
            return;
        };
        if planar_distance(origin, target_pos) > self.game.basic.range {
            self.stats.refused[2] += 1;
            return;
        }
        if let Some(mut player) = self.world.get_mut::<Player>(caster) {
            player.cooldown = self.game.basic.cooldown_ticks;
        }
        self.stats.casts += 1;
        self.projectiles.push(Projectile {
            owner: caster,
            target,
            pos: origin + Vec3::new(0.0, 1.25, 0.0),
            damage: self.game.basic.damage,
            left: self.game.basic.range * 1.5,
            speed: self.game.basic.speed,
        });
    }

    /// Homing bolts: fly toward the target's chest, hit within a radius.
    fn projectiles(&mut self) {
        let mut hits: Vec<(Entity, Entity, f32)> = Vec::new();
        let world = &self.world;
        self.projectiles.retain_mut(|p| {
            let Some(mob) = world
                .get::<Mob>(p.target)
                .filter(|m| m.mode != MobMode::Dead)
            else {
                return false;
            };
            let aim = mob.pos + Vec3::new(0.0, CHEST, 0.0);
            let to = aim - p.pos;
            let dist = to.length();
            let step = p.speed * SIM_DT;
            if dist <= step + PROJECTILE_HIT_RADIUS {
                hits.push((p.owner, p.target, p.damage));
                return false;
            }
            p.pos += to * (step / dist);
            p.left -= step;
            p.left > 0.0
        });
        self.stats.hits += hits.len() as u64;
        for (owner, target, damage) in hits {
            let tick = self.tick;
            let Some(mut mob) = self.world.get_mut::<Mob>(target) else {
                continue;
            };
            mob.hp -= damage;
            if mob.hp <= 0.0 {
                mob.hp = 0.0;
                mob.mode = MobMode::Dead;
                mob.state = STATE_DEAD;
                mob.died_at = tick;
                self.stats.kills += 1;
                let (lo, hi) = self.game.mob_respawn_ticks;
                let span = hi.saturating_sub(lo).max(1);
                mob.respawn_at = tick + lo + xorshift(&mut mob.rng) % span;
            } else if !matches!(mob.mode, MobMode::Chase(_)) {
                mob.mode = MobMode::Chase(owner);
                mob.next_think = tick;
            }
        }
    }

    /// Creature brains. Sleeping cells are skipped entirely.
    fn creatures(&mut self) {
        let tick = self.tick;
        // Which cells are awake, and where the players are.
        self.awake.iter_mut().for_each(|a| *a = false);
        for cell in &mut self.player_cells {
            cell.clear();
        }
        self.player_pos.clear();
        let mut players = self.world.query::<(Entity, &Player)>();
        for (entity, player) in players.iter(&self.world) {
            if player.dead_until != 0 {
                continue;
            }
            let pos = player.body.pos;
            self.player_pos.insert(entity, pos);
            if let Some(cell) = cell_of(pos) {
                self.player_cells[cell].push((entity, pos));
            }
            for cell in cells_around(pos, WAKE_CELLS) {
                self.awake[cell] = true;
            }
        }

        let mut strikes: Vec<(Entity, f32)> = Vec::new();
        let mut awake = 0;
        let mut thinking = 0;
        let mut paths = 0_u64;
        let mut path_ms = 0.0_f64;
        let mut ground_ms = 0.0_f64;
        let game = &self.game;
        let terrain = &self.terrain;
        let nav = &self.nav;
        let mut scratch = std::mem::take(&mut self.nav_scratch);
        let player_cells = &self.player_cells;
        let player_pos = &self.player_pos;
        let awake_cells = &self.awake;
        let mut query = self.world.query::<&mut Mob>();
        for mut mob in query.iter_mut(&mut self.world) {
            if mob.mode == MobMode::Dead {
                if tick >= mob.respawn_at {
                    let home = mob.home;
                    mob.pos = home;
                    mob.hp = mob.max_hp;
                    mob.mode = MobMode::Idle;
                    mob.state = STATE_IDLE;
                    mob.path.clear();
                }
                continue;
            }
            let Some(cell) = cell_of(mob.pos) else {
                continue;
            };
            if !awake_cells[cell] {
                continue;
            }
            awake += 1;
            let pack = &game.packs[mob.pack];
            let species = &game.species[pack.species];

            // Nearest living player in the 3x3 cells around.
            let mut nearest: Option<(Entity, Vec3, f32)> = None;
            for c in cells_around(mob.pos, 1) {
                for &(entity, pos) in &player_cells[c] {
                    let d = planar_distance(pos, mob.pos);
                    if nearest.is_none_or(|n| d < n.2) {
                        nearest = Some((entity, pos, d));
                    }
                }
            }
            let nearest_d = nearest.map_or(f32::MAX, |n| n.2);
            mob.attack_cd = mob.attack_cd.saturating_sub(1);

            if tick >= mob.next_think {
                thinking += 1;
                let period = if nearest_d < 30.0 {
                    1
                } else if nearest_d < 64.0 {
                    3
                } else {
                    15
                };
                mob.next_think = tick + period;
                let leashed = planar_distance(mob.pos, mob.home) > pack.leash;
                mob.mode = match mob.mode {
                    MobMode::Chase(_) if leashed => MobMode::Return,
                    MobMode::Chase(target) => {
                        // Keep chasing while the target is alive and near.
                        let alive_near = player_pos
                            .get(&target)
                            .is_some_and(|p| planar_distance(*p, mob.pos) < pack.leash);
                        if alive_near {
                            MobMode::Chase(target)
                        } else {
                            MobMode::Return
                        }
                    }
                    MobMode::Return if planar_distance(mob.pos, mob.home) < 1.0 => MobMode::Idle,
                    MobMode::Return => MobMode::Return,
                    MobMode::Idle | MobMode::Wander(_) => match nearest {
                        Some((entity, _, d)) if d <= game.aggro_radius(pack) => {
                            MobMode::Chase(entity)
                        }
                        _ => {
                            if matches!(mob.mode, MobMode::Idle) && xorshift(&mut mob.rng) % 100 < 4
                            {
                                let a = unit(&mut mob.rng) * core::f32::consts::TAU;
                                let r = 2.0 + unit(&mut mob.rng) * 5.0;
                                MobMode::Wander(
                                    mob.home + Vec3::new(libm::cosf(a) * r, 0.0, libm::sinf(a) * r),
                                )
                            } else {
                                mob.mode
                            }
                        }
                    },
                    MobMode::Dead => MobMode::Dead,
                };
            }

            // Move every tick toward the current goal.
            let (goal, speed, attack) = match mob.mode {
                MobMode::Chase(target) => match player_pos.get(&target).copied() {
                    Some(p) => (Some(p), species.move_speed, Some(target)),
                    None => (None, 0.0, None),
                },
                MobMode::Wander(to) => (Some(to), species.move_speed * 0.35, None),
                MobMode::Return => {
                    mob.hp = mob.max_hp;
                    (Some(mob.home), species.move_speed * 1.5, None)
                }
                _ => (None, 0.0, None),
            };
            mob.state = STATE_IDLE;
            if let Some(goal) = goal {
                let to = Vec3::new(goal.x - mob.pos.x, 0.0, goal.z - mob.pos.z);
                let dist = to.length();
                let stop = if attack.is_some() {
                    species.attack_range * 0.8
                } else {
                    0.3
                };
                if dist > stop {
                    // Walk the navigation mesh. Close in (a melee chase) the
                    // creature goes straight at its goal. Further out it plans
                    // a path when it has none, once a second, or when the goal
                    // has moved far from what it planned for; in between, the
                    // path's last corner follows the goal.
                    if dist < DIRECT_CHASE {
                        mob.path.clear();
                        mob.path.push(goal);
                    } else {
                        let goal_moved =
                            planar_distance_sq(goal, mob.path_goal) > REPLAN_DRIFT * REPLAN_DRIFT;
                        if mob.path.is_empty() || goal_moved || tick >= mob.replan_at {
                            let t0 = Instant::now();
                            let planned = nav.path(mob.pos, goal, PATH_NODE_BUDGET, &mut scratch);
                            path_ms += t0.elapsed().as_secs_f64() * 1000.0;
                            mob.path = match planned {
                                Some(mut corners) => {
                                    corners.reverse();
                                    corners
                                }
                                None => vec![goal],
                            };
                            mob.path_goal = goal;
                            mob.replan_at = tick + 30 + (mob.rng % 10);
                            paths += 1;
                        } else if let Some(end) = mob.path.first_mut() {
                            *end = goal;
                        }
                    }
                    let mut budget = speed * SIM_DT;
                    while budget > 0.0 {
                        let Some(&corner) = mob.path.last() else {
                            break;
                        };
                        let leg = Vec3::new(corner.x - mob.pos.x, 0.0, corner.z - mob.pos.z);
                        let leg_len = leg.length();
                        let last_leg = mob.path.len() == 1;
                        let keep = if last_leg { stop.min(leg_len) } else { 0.0 };
                        if leg_len - keep <= budget {
                            mob.pos.x += leg.x / leg_len.max(1e-4) * (leg_len - keep);
                            mob.pos.z += leg.z / leg_len.max(1e-4) * (leg_len - keep);
                            budget -= leg_len - keep;
                            if leg_len > 1e-3 {
                                mob.yaw = yaw_of(leg / leg_len);
                            }
                            mob.path.pop();
                            if last_leg {
                                break;
                            }
                        } else {
                            mob.pos.x += leg.x / leg_len * budget;
                            mob.pos.z += leg.z / leg_len * budget;
                            mob.yaw = yaw_of(leg / leg_len);
                            budget = 0.0;
                        }
                    }
                    // Height follows the ground every third tick, creatures
                    // spread over the three (a few centimetres of lag at a
                    // run; clients smooth it anyway).
                    if (tick + mob.rng).is_multiple_of(GROUND_EVERY) {
                        let t_ground = Instant::now();
                        if let Some(ground) =
                            terrain.ray_down(mob.pos + Vec3::new(0.0, 1.5, 0.0), 4.0)
                        {
                            mob.pos.y = ground.point.y;
                        }
                        ground_ms += t_ground.elapsed().as_secs_f64() * 1000.0;
                    }
                    mob.state = STATE_MOVING;
                } else if matches!(mob.mode, MobMode::Wander(_)) {
                    mob.mode = MobMode::Idle;
                }
                if let Some(target) = attack
                    && dist <= species.attack_range
                {
                    mob.yaw = yaw_of(to / dist.max(0.001));
                    if mob.attack_cd == 0 {
                        mob.attack_cd = species.attack_cooldown_ticks;
                        strikes.push((target, game.mob_attack(pack)));
                    }
                    mob.state = STATE_ATTACKING;
                }
            }
        }
        self.stats.awake_mobs = awake;
        self.stats.thinking_mobs += thinking;
        self.stats.paths += paths;
        self.stats.path_ms += path_ms;
        self.stats.ground_ms += ground_ms;
        self.nav_scratch = scratch;

        let respawn = self.game.respawn_ticks;
        for (target, damage) in strikes {
            if let Some(mut player) = self.world.get_mut::<Player>(target)
                && player.dead_until == 0
            {
                player.hp -= damage;
                if player.hp <= 0.0 {
                    player.hp = 0.0;
                    player.dead_until = tick + u32::from(respawn);
                    self.stats.player_deaths += 1;
                }
            }
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
                },
                kind: 0,
                hp: hp_byte(p.hp, p.max_hp),
            };
            self.rows.push(Row {
                id: id.0,
                entity,
                state,
                is_player: true,
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
                kind: m.species + 1,
                hp: hp_byte(m.hp, m.max_hp),
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
