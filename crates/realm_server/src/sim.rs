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
use realm_proto::ticket::Ticket;
use realm_proto::{EntitySet, EntityState, InputBatch, InputFrame, JoinReply, Snapshot};
use realm_sim::movement::{self, Body, MoveParams};
use realm_sim::world::World as Terrain;
use realm_sim::{SIM_DT, Vec3};

use crate::game::Game;

pub type ConnId = u64;

/// Network -> simulation.
pub enum NetEvent {
    Join {
        conn: ConnId,
        ticket: Ticket,
        outbox: tokio::sync::mpsc::Sender<Bytes>,
        reply: tokio::sync::oneshot::Sender<JoinReply>,
    },
    Input {
        conn: ConnId,
        batch: InputBatch,
    },
    Leave {
        conn: ConnId,
    },
}

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
/// Inputs a client may run ahead of the server before it is resynchronised.
const RESYNC_AHEAD: u32 = 60;

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
    outbox: tokio::sync::mpsc::Sender<Bytes>,
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
    pub hits: u64,
    pub kills: u64,
    pub player_deaths: u64,
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
    dev_spawn_near_packs: bool,
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
        content_hash: [u8; 32],
        dev_spawn_near_packs: bool,
    ) -> Self {
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
            dev_spawn_near_packs,
            stats: Stats::default(),
            params: MoveParams::default(),
        };
        sim.spawn_creatures();
        sim
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
                reply,
            } => {
                let home = self.spawn_point_for(ticket.character);
                let player = Player {
                    body: Body::at(home),
                    pending: BTreeMap::new(),
                    last_seq: 0,
                    last_frame: InputFrame::default(),
                    cooldown: 0,
                    hp: self.game.player_max_hp,
                    max_hp: self.game.player_max_hp,
                    dead_until: 0,
                    home,
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
                        outbox,
                        view,
                        phase,
                        bytes: 0,
                    },
                );
                let _ = reply.send(JoinReply::Accepted {
                    entity: id,
                    tick: self.tick,
                    content_hash: self.content_hash,
                });
            }
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
                if let Some(client) = self.clients.remove(&conn) {
                    self.ids.remove(&client.net_id);
                    self.world.despawn(client.entity);
                }
            }
        }
    }

    fn spawn_point_for(&self, character: u64) -> Vec3 {
        let (x, z) = if self.dev_spawn_near_packs && !self.game.packs.is_empty() {
            let pack =
                &self.game.packs[(character as usize).wrapping_mul(7919) % self.game.packs.len()];
            (pack.center.0 + 14.0, pack.center.1)
        } else {
            (self.game.spawn_point.x, self.game.spawn_point.z)
        };
        Vec3::new(x, self.ground(x, z) + 0.05, z)
    }

    /// Moves every player by its next input and starts its actions.
    fn players(&mut self) {
        let tick = self.tick;
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
            // Jitter buffer: run the next input in sequence; when it has not
            // arrived, repeat the last movement without its action. A client
            // that ran ahead (buffer too deep) catches up two inputs a tick.
            let runs = if player.pending.len() > 4 { 2 } else { 1 };
            for _ in 0..runs {
                let next = player.last_seq + 1;
                let frame = if let Some(frame) = player.pending.remove(&next) {
                    player.last_seq = next;
                    player.last_frame = frame;
                    frame
                } else {
                    // Inputs lost for good (everything older than what is
                    // pending) are skipped rather than waited for.
                    if let Some((&first, _)) = player.pending.iter().next()
                        && first > next + 3
                    {
                        player.last_seq = first - 1;
                    }
                    InputFrame {
                        action: 0,
                        target: 0,
                        ..player.last_frame
                    }
                };
                let mut body = player.body;
                movement::step(&mut body, frame.movement, &self.params, &self.terrain);
                player.body = body;
                player.cooldown = player.cooldown.saturating_sub(1);
                if frame.action == 1 && player.cooldown == 0 {
                    casts.push((entity, frame.target));
                }
            }
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
        let game = &self.game;
        let terrain = &self.terrain;
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
                    let step = (speed * SIM_DT).min(dist - stop);
                    let dir = to / dist;
                    mob.pos += dir * step;
                    mob.pos.y = terrain
                        .ground_height(mob.pos.x, mob.pos.z)
                        .unwrap_or(mob.pos.y);
                    mob.yaw = yaw_of(dir);
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
