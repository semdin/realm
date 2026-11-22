//! Creature brains, the old game's `mob_base.gd` on the server's clock.
//!
//! - Aggressive packs look for the nearest player they can see within their
//!   aggro radius; reactive ones only answer a blow. A creature always turns
//!   on whoever hit it last, and its pack mates within the assist radius
//!   join in.
//! - The leash runs from the pack's anchor and stretches while the creature
//!   is being hit. A melee creature whose target stays out of reach gives
//!   up. Giving up walks it home: it heals on the way, and a blow from
//!   outside its home ground is shrugged off.
//! - An attack winds up, lands on its release tick and recovers. Every Nth
//!   plain attack is one of the species' telegraphed abilities; a target out
//!   of reach can draw a thrown one. Casters throw bolts from up to 15 m.
//! - Melee pack mates take at most `attack_slots` places at a target; the
//!   rest wait on a ring around it. Mates keep apart while they walk.
//! - A pack comes back whole, on a fresh anchor in its area, some time after
//!   its last member fell.

use crate::game::PackKind;
use realm_proto::control::CombatEvent;
use realm_rules::creatures::{
    AGGRO_SCAN_MS, AbilityDef, BOLT_REACH, BOSS_TARGET_LOCK_MS, ENRAGE_ATTACK, ENRAGE_COOLDOWN,
    ENRAGE_SPEED, HOME_RADIUS, LEAD_REACH, LEASH_HOT_MS, LEASH_HOT_SCALE, MELEE_LUNGE, MELEE_SLACK,
    RETURN_REGEN_SHARE, RING_PACE, Riders, Shape, Trigger, UNREACHABLE_MS, WINDUP_STEP,
};
use realm_sim::nav::{NavQuery, NavScratch, OBSTACLE_CLEARANCE};
use realm_sim::world::World as Terrain;
use realm_sim::{SIM_DT, SIM_HZ, Vec3};
use std::collections::HashMap;
use std::time::Instant;

use super::{
    DIRECT_CHASE, Entity, GROUND_EVERY, Mob, MobMode, NetId, PATH_NODE_BUDGET, Player,
    REPLAN_DRIFT, STATE_ATTACKING, STATE_DEAD, STATE_IDLE, STATE_MOVING, Sim, cell_of,
    cells_around, planar_distance, planar_distance_sq, unit, xorshift, yaw_of,
};

/// Packs are checked for their respawn this often.
const RESPAWN_CHECK_TICKS: u32 = 15;
/// A world boss is announced this long before it comes back (60 s).
const WORLD_BOSS_WARNING: u32 = 60 * SIM_HZ;
/// Another pack's anchor this close rejects a respawn spot.
const ANCHOR_SPACING: f32 = 6.2;
/// A creature leaves a protected zone it walked into this often.
const SAFE_CHECK_TICKS: u32 = 8;
/// A body this close to its place on the ring holds there.
const RING_HOLD: f32 = 0.6;
/// A pack mate this far ahead of a walking creature is gone round.
const AHEAD_DOT: f32 = 0.35;
const GO_ROUND: f32 = 1.5;
/// Bolts and abilities leave and are aimed at chest height.
const CHEST: f32 = 1.0;
const WAND: f32 = 1.2;
/// A creature bolt meets a player this close to its path.
const BOLT_RADIUS: f32 = 0.7;
/// Idle creatures rest this long (ms, from..to), then stroll this far from
/// home (m) at this share of their speed, giving up after a while.
const WANDER_REST_MS: (u32, u32) = (2000, 5000);
const WANDER_RANGE: (f32, f32) = (2.5, 6.0);
const WANDER_PACE: f32 = 0.3;
const WANDER_GIVE_UP_MS: u32 = 7000;
/// A caster between its bolts steps to a new spot round its target: this far
/// round (radians, either way), at its pace times STRAFE_PACE, at most once
/// in STRAFE_MS (from, to) after it last set off.
const STRAFE_TURN: (f32, f32) = (0.45, 1.1);
const STRAFE_PACE: f32 = 0.85;
const STRAFE_MS: (u32, u32) = (900, 2200);
/// Nearest a strafing caster stands to its target (m).
const STRAFE_NEAR: f32 = 7.0;
/// A creature off a ledge falls at most this far to the ground (m).
const FALL_REACH: f32 = 80.0;
/// A creature's body when it looks for walls on a straight walk: its
/// radius and the step it walks up without noticing (the navigation mesh's
/// agent's, realm_worldc nav.rs).
const BODY_RADIUS: f32 = 0.35;
const CLIMB: f32 = 0.45;

fn ticks(ms: u32) -> u32 {
    (ms * SIM_HZ).div_ceil(1000)
}

/// Where each awake pack's living members are this tick.
#[derive(Clone, Copy)]
pub(super) struct MateView {
    entity: Entity,
    pos: Vec3,
    target: Option<Entity>,
    /// Attacking, or standing within reach of its target.
    engaged: bool,
}

/// One pack's life: where it stands and who is in it.
pub(super) struct PackState {
    pub anchor: Vec3,
    pub members: Vec<Entity>,
    pub alive: u32,
    pub respawn_at: Option<u32>,
    /// A Dark Shard: the waves it has called this life.
    pub waves_done: usize,
    /// A world boss: "it comes soon" was said for this respawn.
    pub announced: bool,
    /// A Dark Shard: no reinforcements before this tick, and how many it
    /// called this life (each one's turn through its `reinforce` list).
    pub reinforce_at: u32,
    pub reinforced: u32,
}

/// An attack between its first windup tick and the end of its recovery.
#[derive(Clone, Copy)]
pub(super) struct Attack {
    /// A telegraphed ability; None is the plain swing or bolt.
    pub ability: Option<u16>,
    pub target: Entity,
    pub center: Vec3,
    pub dir: Vec3,
    pub release: u32,
    pub done: u32,
    pub released: bool,
    /// A combo's next blow, begun at `done`.
    pub then: Option<u16>,
}

/// What a boss keeps in mind between its blows.
#[derive(Clone, Copy, Default)]
pub(super) struct Mind {
    /// The pattern it threw last (it never throws one twice running when
    /// another fits).
    pub last: Option<u16>,
    /// A new phase's opener, thrown before anything else.
    pub opener: Option<u16>,
    /// Sprinting until then; ready to sprint again from `rush_ready`.
    pub rush_until: u32,
    pub rush_ready: u32,
    /// It keeps its target until then, whoever else hits it.
    pub locked_until: u32,
    /// A caster's next spot round its target, and when it may pick another.
    pub strafe: Option<Vec3>,
    pub strafe_ready: u32,
}

/// A caster's bolt in flight: straight, flat damage.
pub(super) struct MobBolt {
    pub owner: Entity,
    pub spell: u8,
    pub pos: Vec3,
    pub dir: Vec3,
    pub speed: f32,
    pub left: f32,
    pub damage: f32,
    pub level: u32,
}

/// What a creature did this tick that touches others; applied after the
/// creatures have all thought.
enum Deed {
    /// Turned on a player: its mates may join.
    Aggro(Entity, Entity),
    /// Gave up the fight.
    Break(Entity),
    /// A telegraph was broken off.
    Cancel(Entity),
    Telegraph(Vec3, CombatEvent),
    Strike(Entity, Attack),
}

struct Walk<'a> {
    terrain: &'a Terrain,
    nav: &'a NavQuery,
    /// Closed dungeon gates' footprints: no creature walks through one.
    barriers: &'a [[f32; 4]],
    scratch: &'a mut NavScratch,
    paths: u64,
    path_ms: f64,
    ground_ms: f64,
}

impl Walk<'_> {
    /// Walks `mob` toward `goal` at `speed` and stops `stop` short; the
    /// navigation mesh when far, straight when close. `apart` is the
    /// spacing push from pack mates. Returns whether it moved.
    fn step(
        &mut self,
        mob: &mut Mob,
        goal: Vec3,
        speed: f32,
        stop: f32,
        tick: u32,
        apart: Vec3,
    ) -> bool {
        let to = Vec3::new(goal.x - mob.pos.x, 0.0, goal.z - mob.pos.z);
        let dist = to.length();
        if dist <= stop {
            return false;
        }
        // Straight at a goal close by, unless the body would brush a wall,
        // a building or a trunk on the way (then round it on the mesh like
        // a far one).
        if dist < DIRECT_CHASE && self.terrain.walk_clear(mob.pos, goal, BODY_RADIUS, CLIMB) {
            mob.path.clear();
            mob.path.push(goal);
            // Whenever the line closes, a path is planned at once.
            mob.replan_at = tick;
        } else {
            let goal_moved = planar_distance_sq(goal, mob.path_goal) > REPLAN_DRIFT * REPLAN_DRIFT;
            if mob.path.is_empty() || goal_moved || tick >= mob.replan_at {
                let t0 = Instant::now();
                let planned = self.nav.path(mob.pos, goal, PATH_NODE_BUDGET, self.scratch);
                self.path_ms += t0.elapsed().as_secs_f64() * 1000.0;
                mob.path = match planned {
                    Some(mut corners) => {
                        corners.reverse();
                        corners
                    }
                    None => vec![goal],
                };
                mob.path_goal = goal;
                mob.replan_at = tick + 30 + (mob.rng % 10);
                self.paths += 1;
            } else if let Some(end) = mob.path.first_mut() {
                *end = goal;
            }
        }
        let start = mob.pos;
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
        if apart != Vec3::ZERO {
            // Spacing never pushes a body off the walkable mesh (into a
            // wall, where it would stand out of everyone's reach).
            let pushed = mob.pos + apart * (speed * SIM_DT);
            if self.nav.locate(pushed, 2.5).is_some() || self.nav.locate(mob.pos, 2.5).is_none() {
                mob.pos = pushed;
            }
        }
        // A closed gate stops it (half a metre of body round its feet).
        let inside = |p: Vec3, b: &[f32; 4]| {
            p.x > b[0] - 0.5 && p.x < b[2] + 0.5 && p.z > b[1] - 0.5 && p.z < b[3] + 0.5
        };
        if self
            .barriers
            .iter()
            .any(|b| inside(mob.pos, b) && !inside(start, b))
        {
            mob.pos = start;
            return false;
        }
        true
    }

    /// Puts `mob` on the ground under it: up a step at most, down any
    /// height (off a ledge it falls to whatever lies below).
    fn settle(&mut self, mob: &mut Mob) {
        let t_ground = Instant::now();
        // Never more than a step up at once: a probe that starts inside a
        // wall (a body pushed into one) would otherwise lift the creature
        // onto the wall's top.
        if let Some(ground) = self
            .terrain
            .ray_down(mob.pos + Vec3::new(0.0, 1.5, 0.0), 1.5 + FALL_REACH)
            .filter(|g| g.point.y <= mob.pos.y + 1.0)
        {
            mob.pos.y = ground.point.y;
        }
        self.ground_ms += t_ground.elapsed().as_secs_f64() * 1000.0;
    }
}

/// The spacing push from pack mates within `radius`, going round one that is
/// ahead along `heading`.
fn apart(
    me: Entity,
    pos: Vec3,
    heading: Vec3,
    mates: &[MateView],
    radius: f32,
    weight: f32,
) -> Vec3 {
    let mut push = Vec3::ZERO;
    for m in mates {
        if m.entity == me {
            continue;
        }
        let away = Vec3::new(pos.x - m.pos.x, 0.0, pos.z - m.pos.z);
        let d = away.length();
        if d >= radius || d < 1.0e-3 {
            continue;
        }
        let share = 1.0 - d / radius;
        push += away / d * share;
        if heading != Vec3::ZERO && (-away / d).dot(heading) > AHEAD_DOT {
            push += Vec3::new(-heading.z, 0.0, heading.x) * (GO_ROUND * share);
        }
    }
    let len = push.length();
    if len > 1.0 {
        push /= len;
    }
    push * (weight * 0.5)
}

fn flat_dir(from: Vec3, to: Vec3) -> Vec3 {
    let d = Vec3::new(to.x - from.x, 0.0, to.z - from.z);
    if d.length_squared() > 1.0e-6 {
        d.normalize()
    } else {
        Vec3::new(0.0, 0.0, -1.0)
    }
}

fn facing(yaw: u16) -> Vec3 {
    let a = f32::from(yaw) * (core::f32::consts::TAU / 65_536.0);
    Vec3::new(-libm::sinf(a), 0.0, -libm::cosf(a))
}

/// Telegraph facing in radians, the snapshot convention (0 looks along -Z).
fn yaw_radians(dir: Vec3) -> f32 {
    f32::from(yaw_of(dir)) * (core::f32::consts::TAU / 65_536.0)
}

impl Sim {
    /// Every awake creature thinks and moves; what touches others is applied
    /// after all have.
    pub(super) fn creatures(&mut self) {
        let tick = self.tick;
        self.wake_cells();
        self.respawn_packs();
        let rules = self.rules();
        let tuning = rules.mobs.tuning;
        let scan_ticks = ticks(AGGRO_SCAN_MS);
        let hot_ticks = ticks(LEASH_HOT_MS);
        let unreachable_ticks = ticks(UNREACHABLE_MS);

        // Pack views first: the ring and the spacing read the mates.
        let mut views = std::mem::take(&mut self.pack_views);
        let mut touched = std::mem::take(&mut self.touched_packs);
        for p in touched.drain(..) {
            views[p].clear();
        }
        {
            let mut q = self.world.query::<(Entity, &Mob)>();
            for (entity, m) in q.iter(&self.world) {
                if m.mode == MobMode::Dead || !cell_of(m.pos).is_some_and(|c| self.awake[c]) {
                    continue;
                }
                if views[m.pack].is_empty() {
                    touched.push(m.pack);
                }
                let target = match m.mode {
                    MobMode::Chase(t) => Some(t),
                    _ => None,
                };
                let reach = m.attack_range + 0.8;
                let engaged = m.attack.is_some()
                    || target
                        .and_then(|t| self.player_pos.get(&t))
                        .is_some_and(|p| planar_distance(*p, m.pos) <= reach);
                views[m.pack].push(MateView {
                    entity,
                    pos: m.pos,
                    target,
                    engaged,
                });
            }
        }

        self.auras.clear();
        let mut deeds: Vec<Deed> = Vec::new();
        let mut awake = 0;
        let mut thinking = 0;
        let game = &self.game;
        let terrain = &self.terrain;
        let packs = &self.packs;
        let player_cells = &self.player_cells;
        let player_pos = &self.player_pos;
        let player_vel = &self.player_vel;
        let awake_cells = &self.awake;
        let auras = &mut self.auras;
        let mut scratch = std::mem::take(&mut self.nav_scratch);
        let barriers = if self.gates.is_empty() {
            Vec::new()
        } else {
            self.gates.closed_footprints(self.tick)
        };
        let mut walk = Walk {
            terrain,
            nav: &self.nav,
            barriers: &barriers,
            scratch: &mut scratch,
            paths: 0,
            path_ms: 0.0,
            ground_ms: 0.0,
        };
        let protected = |p: Vec3| game.rules.protected(&game.map, p.x, p.y, p.z);
        let clear = |from: Vec3, to: Vec3| terrain.line_hit(from, to).is_none();
        let mut query = self.world.query::<(Entity, &NetId, &mut Mob)>();
        for (me, net_id, mut mob) in query.iter_mut(&mut self.world) {
            if mob.mode == MobMode::Dead {
                continue;
            }
            if !cell_of(mob.pos).is_some_and(|c| awake_cells[c]) {
                continue;
            }
            awake += 1;
            let pack = &game.packs[mob.pack];
            let species = &game.species[usize::from(mob.species)];
            // Dark Shards and dummies stand, and so do a boss's parts (the
            // body carries them).
            if species.object || mob.part_of.is_some() {
                continue;
            }
            let brain = &species.brain;
            let rage = mob.enraged;
            // Bound where it stands (its own web thrown back): it still
            // strikes, it does not walk.
            let move_speed = if mob.status.rooted(tick) {
                0.0
            } else {
                mob.move_speed * if rage { ENRAGE_SPEED } else { 1.0 }
            };
            let attack_range = mob.attack_range;
            let boss = pack.boss_setup.as_ref().filter(|_| mob.boss);
            let boss_def = boss.and_then(|b| rules.mobs.bosses.get(&b.key));
            let extras: &[u16] = boss_def.map_or(&[], |b| b.extras.as_slice());
            // A boss's patterns (its style's) and its phase's pace.
            let style: &[u16] = boss
                .and_then(|b| rules.mobs.patterns.get(&b.style))
                .map_or(&[], Vec::as_slice);
            let phase = boss_def.and_then(|d| {
                usize::from(mob.phase)
                    .checked_sub(2)
                    .and_then(|k| d.phases.get(k))
            });
            let (phase_windup, phase_cooldown) =
                phase.map_or((1.0, 1.0), |p| (p.windup, p.cooldown));
            let cooldown = f32::from(species.attack_cooldown_ticks)
                * if rage { ENRAGE_COOLDOWN } else { 1.0 }
                * phase_cooldown;
            let windup_scale = mob.windup_scale * phase_windup;
            let anchor = packs[mob.pack].anchor;
            let mates = views[mob.pack].as_slice();
            let pace = mob.status.speed(tick);
            mob.attack_cd = (mob.attack_cd - pace).max(0.0);

            // Held or thrown: no thought, no step, no strike; a telegraph
            // breaks off.
            if mob.status.locked(tick) {
                if let Some(a) = mob.attack.take()
                    && a.ability.is_some()
                    && !a.released
                {
                    deeds.push(Deed::Cancel(me));
                }
                mob.state = STATE_IDLE;
                continue;
            }
            // Height follows the ground every third tick (creatures spread
            // over the three) while it walks, fights or goes home; at rest
            // it stays where it settled.
            if mob.mode != MobMode::Idle && (tick + mob.rng).is_multiple_of(GROUND_EVERY) {
                walk.settle(&mut mob);
            }
            // A creature that walked into a protected zone leaves it.
            if (tick + mob.rng).is_multiple_of(SAFE_CHECK_TICKS)
                && matches!(mob.mode, MobMode::Chase(_))
                && protected(mob.pos)
                && !protected(mob.home)
            {
                deeds.push(Deed::Break(me));
                continue;
            }

            match mob.mode {
                MobMode::Dead => {}
                MobMode::Return => {
                    let regen = mob.max_hp * RETURN_REGEN_SHARE * SIM_DT;
                    mob.hp = (mob.hp + regen).min(mob.max_hp);
                    let home = mob.home;
                    let moved = walk.step(&mut mob, home, move_speed * pace, 0.3, tick, Vec3::ZERO);
                    mob.state = if moved { STATE_MOVING } else { STATE_IDLE };
                    if planar_distance(mob.pos, home) < HOME_RADIUS {
                        mob.hp = mob.max_hp;
                        mob.mode = MobMode::Idle;
                        mob.path.clear();
                        // Whole again, a boss starts its fight over.
                        if boss_def.is_some_and(|d| !d.phases.is_empty()) {
                            mob.phase = 1;
                        }
                        mob.mind = Mind::default();
                        walk.settle(&mut mob);
                    }
                }
                MobMode::Idle | MobMode::Wander(_) => {
                    if pack.aggressive && tick >= mob.next_scan {
                        mob.next_scan = tick + scan_ticks;
                        thinking += 1;
                        let radius = game.aggro_radius(mob.level);
                        let eye = mob.pos + Vec3::new(0.0, CHEST, 0.0);
                        let mut seen: Vec<(f32, Entity, Vec3)> = Vec::new();
                        for c in cells_around(mob.pos, 1) {
                            for &(entity, pos) in &player_cells[c] {
                                let d = (pos - mob.pos).length();
                                if d <= radius {
                                    seen.push((d, entity, pos));
                                }
                            }
                        }
                        seen.sort_unstable_by(|a, b| a.0.total_cmp(&b.0));
                        let found = seen.into_iter().find(|&(_, _, pos)| {
                            !protected(pos)
                                && ((species.bolt.is_some() && !mob.boss)
                                    || !out_of_reach(mob.pos, pos, attack_range))
                                && clear(eye, pos + Vec3::new(0.0, CHEST, 0.0))
                        });
                        if let Some((_, player, _)) = found {
                            mob.mode = MobMode::Chase(player);
                            mob.mind.locked_until = tick + ticks(BOSS_TARGET_LOCK_MS);
                            deeds.push(Deed::Aggro(me, player));
                            continue;
                        }
                    }
                    // Stand a few seconds, stroll a few metres from home,
                    // stand again.
                    if let MobMode::Wander(to) = mob.mode {
                        let speed = move_speed * WANDER_PACE * pace;
                        let moved = walk.step(&mut mob, to, speed, 0.3, tick, Vec3::ZERO);
                        mob.state = if moved { STATE_MOVING } else { STATE_IDLE };
                        if !moved || tick >= mob.next_think {
                            mob.mode = MobMode::Idle;
                            walk.settle(&mut mob);
                            let rest = ticks(WANDER_REST_MS.0)
                                + xorshift(&mut mob.rng)
                                    % ticks(WANDER_REST_MS.1 - WANDER_REST_MS.0);
                            mob.next_think = tick + rest;
                        }
                    } else {
                        mob.state = STATE_IDLE;
                        if tick >= mob.next_think {
                            let a = unit(&mut mob.rng) * core::f32::consts::TAU;
                            let r = WANDER_RANGE.0
                                + unit(&mut mob.rng) * (WANDER_RANGE.1 - WANDER_RANGE.0);
                            let (x, z) = (
                                mob.home.x + libm::cosf(a) * r,
                                mob.home.z + libm::sinf(a) * r,
                            );
                            // A stroll stays on the ground it stands on (found
                            // from its own height, so indoors too): not onto
                            // a roof or a prop, over an edge, into a trunk or
                            // through a wall.
                            let to = terrain
                                .ray_down(Vec3::new(x, mob.home.y + 1.5, z), 4.0)
                                .map(|g| g.point)
                                .filter(|to| walk.nav.on_ground(terrain, *to))
                                .filter(|to| !terrain.in_obstacle(*to, OBSTACLE_CLEARANCE))
                                .filter(|to| terrain.walk_clear(mob.pos, *to, BODY_RADIUS, CLIMB));
                            if let Some(to) = to {
                                mob.mode = MobMode::Wander(to);
                                mob.next_think = tick + ticks(WANDER_GIVE_UP_MS);
                            } else {
                                mob.next_think = tick + ticks(WANDER_REST_MS.0);
                            }
                        }
                    }
                }
                MobMode::Chase(target) => {
                    thinking += 1;
                    let Some(tpos) = player_pos.get(&target).copied().filter(|p| !protected(*p))
                    else {
                        deeds.push(Deed::Break(me));
                        continue;
                    };
                    if brain.aura.is_some() {
                        auras.push(me);
                    }
                    let hot = tick < mob.hit_at + hot_ticks;
                    // A boss keeps to its arena.
                    let leash = boss.map_or(pack.leash, |b| {
                        if b.arena_radius > 0.0 {
                            b.arena_radius
                        } else {
                            pack.leash
                        }
                    });
                    let limit = leash * if hot { LEASH_HOT_SCALE } else { 1.0 };
                    if (mob.pos - anchor).length() > limit {
                        deeds.push(Deed::Break(me));
                        continue;
                    }
                    if species.bolt.is_none() && !mob.boss {
                        if out_of_reach(mob.pos, tpos, attack_range) {
                            if mob.unreachable_since == 0 {
                                mob.unreachable_since = tick;
                            } else if tick - mob.unreachable_since > unreachable_ticks {
                                deeds.push(Deed::Break(me));
                                continue;
                            }
                        } else {
                            mob.unreachable_since = 0;
                        }
                    }

                    // Its health crossing into a boss's next phase: the
                    // phase's opener goes before anything else.
                    if let Some(def) = boss_def
                        && mob.parts.is_empty()
                    {
                        let share = mob.hp / mob.max_hp.max(1.0);
                        while let Some(p) = def.phases.get(usize::from(mob.phase.max(1)) - 1)
                            && share < p.below
                        {
                            mob.phase = mob.phase.max(1) + 1;
                            mob.mind.opener = rules
                                .mobs
                                .named(style, &p.opener)
                                .or_else(|| rules.mobs.named(extras, &p.opener));
                        }
                    }
                    let tvel = player_vel.get(&target).copied().unwrap_or(Vec3::ZERO);

                    // An attack under way: wind up, land, recover.
                    if let Some(mut a) = mob.attack {
                        mob.state = STATE_ATTACKING;
                        if !a.released {
                            // A plain swing follows a retreating target.
                            if a.ability.is_none() && (species.bolt.is_none() || mob.boss) {
                                let stop = attack_range * 0.8;
                                walk.step(
                                    &mut mob,
                                    tpos,
                                    move_speed * WINDUP_STEP * pace,
                                    stop,
                                    tick,
                                    Vec3::ZERO,
                                );
                                mob.yaw = yaw_of(flat_dir(mob.pos, tpos));
                                a.center = tpos;
                            }
                            if tick >= a.release {
                                a.released = true;
                                deeds.push(Deed::Strike(me, a));
                            }
                            mob.attack = Some(a);
                        } else if tick >= a.done {
                            mob.attack = None;
                            mob.state = STATE_IDLE;
                            // A combo goes on: its next blow, aimed at where
                            // the target stands now (where it dodged to).
                            if let Some(ab) = a.then.and_then(|i| rules.mobs.ability(i)) {
                                let aim = lead_aim(terrain, tpos, tvel, ab.lead_ms);
                                let a =
                                    begin(&mut mob, ab, target, aim, tick, cooldown, windup_scale);
                                deeds.push(telegraph(net_id.0, ab, &a));
                            }
                        }
                        continue;
                    }

                    let dist = planar_distance(mob.pos, tpos);
                    let eye = mob.pos + Vec3::new(0.0, CHEST, 0.0);
                    let chest = tpos + Vec3::new(0.0, CHEST, 0.0);
                    let can_act =
                        brain.windup_ms > 0 || !brain.abilities.is_empty() || boss.is_some();
                    // A target out of reach draws a thrown ability.
                    if can_act && mob.attack_cd <= 0.0 && dist > attack_range {
                        let elite = mob.elite;
                        let throw = brain.abilities.iter().chain(extras).copied().find(|&i| {
                            rules.mobs.ability(i).is_some_and(|ab| match ab.trigger {
                                Trigger::Thrown {
                                    min_range,
                                    max_range,
                                    ..
                                } => {
                                    dist >= min_range
                                        && dist <= max_range
                                        && (elite || !ab.elite_only)
                                        && mob.thrown_ready(i) <= tick
                                }
                                _ => false,
                            })
                        });
                        // Not every chance is taken: a missed one comes
                        // round again after a third of its cooldown.
                        let throw = throw.filter(|&i| {
                            let Some(ab) = rules.mobs.ability(i) else {
                                return false;
                            };
                            if ab.chance >= 1.0 || unit(&mut mob.rng) < ab.chance {
                                return true;
                            }
                            if let Trigger::Thrown { cooldown_ms, .. } = ab.trigger {
                                mob.set_thrown_ready(i, tick + ticks(cooldown_ms / 3));
                            }
                            false
                        });
                        if let Some(i) = throw
                            && clear(eye, chest)
                            && let Some(ab) = rules.mobs.ability(i)
                        {
                            if let Trigger::Thrown { cooldown_ms, .. } = ab.trigger {
                                mob.set_thrown_ready(i, tick + ticks(cooldown_ms));
                            }
                            let aim = lead_aim(terrain, tpos, tvel, ab.lead_ms);
                            let a = begin(&mut mob, ab, target, aim, tick, cooldown, windup_scale);
                            deeds.push(telegraph(net_id.0, ab, &a));
                            continue;
                        }
                    }
                    // A boss with a style picks its next pattern by where its
                    // target stands; between blows it closes in, sprinting
                    // at one that keeps away.
                    if !style.is_empty() {
                        if mob.attack_cd <= 0.0 {
                            let pick = mob.mind.opener.take().or_else(|| {
                                let sight = dist <= attack_range || clear(eye, chest);
                                choose(&rules.mobs, style, &mut mob, dist, sight, tick)
                            });
                            if let Some(ab) = pick.and_then(|i| rules.mobs.ability(i)) {
                                if ab.rest_ms > 0 {
                                    mob.set_thrown_ready(ab.index, tick + ticks(ab.rest_ms));
                                }
                                mob.mind.last = Some(ab.index);
                                mob.mind.rush_until = 0;
                                mob.attacks_made += 1;
                                let aim = lead_aim(terrain, tpos, tvel, ab.lead_ms);
                                let a =
                                    begin(&mut mob, ab, target, aim, tick, cooldown, windup_scale);
                                deeds.push(telegraph(net_id.0, ab, &a));
                                continue;
                            }
                        }
                        let mut speed = move_speed * pace;
                        if let Some(r) = boss_def.and_then(|d| d.rush) {
                            if tick >= mob.mind.rush_until
                                && tick >= mob.mind.rush_ready
                                && dist > r.beyond
                            {
                                mob.mind.rush_until = tick + ticks(r.ms);
                                mob.mind.rush_ready = mob.mind.rush_until + ticks(r.cooldown_ms);
                            }
                            if tick < mob.mind.rush_until {
                                speed *= r.speed;
                            }
                        }
                        let moved = dist > attack_range
                            && walk.step(
                                &mut mob,
                                tpos,
                                speed,
                                attack_range * 0.8,
                                tick,
                                Vec3::ZERO,
                            );
                        if !moved {
                            mob.yaw = yaw_of(flat_dir(mob.pos, tpos));
                        }
                        mob.state = if moved { STATE_MOVING } else { STATE_IDLE };
                        continue;
                    }
                    let ranged = species.bolt.is_some() && !mob.boss;
                    let reach = if ranged { BOLT_REACH } else { attack_range };
                    let in_reach = dist <= reach && (!ranged || clear(eye, chest));
                    // The ring: past `attack_slots` mates on this target, wait.
                    let mut ring = None;
                    if !ranged && !mob.boss && mates.len() > 1 {
                        let ahead = mates
                            .iter()
                            .filter(|m| {
                                m.entity.index() < me.index()
                                    && m.target == Some(target)
                                    && m.engaged
                            })
                            .count();
                        if ahead >= tuning.attack_slots as usize {
                            let rank = mates.iter().position(|m| m.entity == me).unwrap_or(0);
                            let a = core::f32::consts::TAU * rank as f32 / mates.len() as f32;
                            ring = Some(
                                tpos + Vec3::new(libm::cosf(a), 0.0, libm::sinf(a))
                                    * tuning.slot_ring,
                            );
                        }
                    }
                    if can_act && in_reach && ring.is_none() && mob.attack_cd <= 0.0 {
                        mob.attacks_made += 1;
                        // Every Nth attack may be one of the species' abilities
                        // (an elite's own ones too), each on its own odds.
                        let elite = mob.elite;
                        let made = mob.attacks_made;
                        let every = brain.abilities.iter().copied().find(|&i| {
                            rules.mobs.ability(i).is_some_and(|ab| {
                                matches!(ab.trigger, Trigger::Every(n) if made.is_multiple_of(n))
                                    && (elite || !ab.elite_only)
                                    && (ab.chance >= 1.0 || unit(&mut mob.rng) < ab.chance)
                            })
                        });
                        mob.mind.strafe = None;
                        mob.yaw = yaw_of(flat_dir(mob.pos, tpos));
                        if let Some(ab) = every.and_then(|i| rules.mobs.ability(i)) {
                            let aim = lead_aim(terrain, tpos, tvel, ab.lead_ms);
                            let a = begin(&mut mob, ab, target, aim, tick, cooldown, windup_scale);
                            deeds.push(telegraph(net_id.0, ab, &a));
                        } else if brain.windup_ms > 0 || brain.recovery_ms > 0 {
                            let release =
                                tick + ticks((brain.windup_ms as f32 * mob.windup_scale) as u32);
                            mob.attack = Some(Attack {
                                ability: None,
                                target,
                                center: tpos,
                                dir: flat_dir(mob.pos, tpos),
                                release,
                                done: release + ticks(brain.recovery_ms),
                                released: false,
                                then: None,
                            });
                            mob.attack_cd = cooldown;
                        }
                        mob.state = STATE_ATTACKING;
                        continue;
                    }
                    // Close in (or take the place on the ring).
                    let heading = flat_dir(mob.pos, tpos);
                    let push = apart(
                        me,
                        mob.pos,
                        heading,
                        mates,
                        tuning.separation_radius,
                        tuning.separation_weight,
                    );
                    // A caster does not stand still between its bolts: it
                    // shifts round its target to a new spot it can see it
                    // from.
                    if ranged
                        && in_reach
                        && ring.is_none()
                        && mob.mind.strafe.is_none()
                        && tick >= mob.mind.strafe_ready
                    {
                        let wait = STRAFE_MS.0
                            + (unit(&mut mob.rng) * (STRAFE_MS.1 - STRAFE_MS.0) as f32) as u32;
                        mob.mind.strafe_ready = tick + ticks(wait);
                        let side = if unit(&mut mob.rng) < 0.5 { -1.0 } else { 1.0 };
                        let turn = side
                            * (STRAFE_TURN.0
                                + unit(&mut mob.rng) * (STRAFE_TURN.1 - STRAFE_TURN.0));
                        let away = flat_dir(tpos, mob.pos);
                        let (sin, cos) = (libm::sinf(turn), libm::cosf(turn));
                        let round = Vec3::new(
                            away.x * cos - away.z * sin,
                            0.0,
                            away.x * sin + away.z * cos,
                        );
                        let far = (dist + (unit(&mut mob.rng) - 0.5) * 4.0)
                            .clamp(STRAFE_NEAR, BOLT_REACH - 1.5);
                        let spot = tpos + round * far;
                        mob.mind.strafe = terrain
                            .ray_down(Vec3::new(spot.x, mob.pos.y + 1.5, spot.z), 4.0)
                            .map(|g| g.point)
                            .filter(|to| walk.nav.on_ground(terrain, *to))
                            .filter(|to| !terrain.in_obstacle(*to, OBSTACLE_CLEARANCE))
                            .filter(|to| terrain.walk_clear(mob.pos, *to, BODY_RADIUS, CLIMB))
                            .filter(|to| clear(*to + Vec3::new(0.0, CHEST, 0.0), chest));
                    }
                    let strafe = mob.mind.strafe.filter(|_| ranged && ring.is_none());
                    let moved = match ring {
                        Some(spot) => walk.step(
                            &mut mob,
                            spot,
                            move_speed * RING_PACE * pace,
                            RING_HOLD,
                            tick,
                            push,
                        ),
                        None if strafe.is_some() => {
                            let to = strafe.unwrap_or(tpos);
                            let going = walk.step(
                                &mut mob,
                                to,
                                move_speed * STRAFE_PACE * pace,
                                0.4,
                                tick,
                                push,
                            );
                            if !going {
                                mob.mind.strafe = None;
                            }
                            going
                        }
                        None if in_reach => false,
                        None => {
                            let stop = if ranged { 0.3 } else { attack_range * 0.8 };
                            walk.step(&mut mob, tpos, move_speed * pace, stop, tick, push)
                        }
                    };
                    if !moved {
                        mob.yaw = yaw_of(heading);
                    }
                    mob.state = if moved { STATE_MOVING } else { STATE_IDLE };
                }
            }
        }
        self.stats.awake_mobs = awake;
        self.stats.thinking_mobs += thinking;
        self.stats.paths += walk.paths;
        self.stats.path_ms += walk.path_ms;
        self.stats.ground_ms += walk.ground_ms;
        self.nav_scratch = scratch;
        self.pack_views = views;
        self.touched_packs = touched;

        for deed in deeds {
            match deed {
                Deed::Aggro(mob, player) => self.assist(mob, player),
                Deed::Break(mob) => self.break_fight(mob),
                Deed::Cancel(mob) => {
                    let (at, caster) = (self.mob_pos(mob), self.net_id_of(mob));
                    self.event(at, CombatEvent::TelegraphCancelled { caster });
                }
                Deed::Telegraph(at, event) => {
                    self.stats.telegraphs += 1;
                    self.event(at, event);
                }
                Deed::Strike(mob, attack) => self.strike(mob, attack),
            }
        }
    }

    fn mob_pos(&self, mob: Entity) -> Vec3 {
        self.world.get::<Mob>(mob).map_or(Vec3::ZERO, |m| m.pos)
    }

    /// Which cells are awake (players near), and where the living players are
    /// (one still rising wakes its cells but is not there to be seen: a
    /// creature chasing it gives up, none turns on it).
    fn wake_cells(&mut self) {
        self.awake.iter_mut().for_each(|a| *a = false);
        for cell in &mut self.player_cells {
            cell.clear();
        }
        self.player_pos.clear();
        self.player_vel.clear();
        let tick = self.tick;
        let mut players = self.world.query::<(Entity, &Player)>();
        for (entity, player) in players.iter(&self.world) {
            if player.dead_until != 0 {
                continue;
            }
            let pos = player.body.pos;
            for cell in cells_around(pos, super::WAKE_CELLS) {
                self.awake[cell] = true;
            }
            if tick < player.protect_until {
                continue;
            }
            self.player_pos.insert(entity, pos);
            self.player_vel.insert(entity, player.body.vel);
            if let Some(cell) = cell_of(pos) {
                self.player_cells[cell].push((entity, pos));
            }
        }
    }

    /// `player` fell: every creature on it turns to the nearest other player
    /// its pack may still fight (on its home ground, within assist reach), or
    /// stops where it stands and waits (`stand_by`): no blows on the corpse,
    /// no walking off. Done at once: a creature whose cell no living player
    /// keeps awake would otherwise sleep with the corpse as its target, frozen
    /// mid-swing, and run after the body once it rose at the entrance.
    pub(super) fn release_player(&mut self, player: Entity) {
        let tick = self.tick;
        let mut living: Vec<(Entity, Vec3)> = Vec::new();
        {
            let mut players = self.world.query::<(Entity, &Player)>();
            for (entity, p) in players.iter(&self.world) {
                if entity != player && p.dead_until == 0 && tick >= p.protect_until {
                    living.push((entity, p.body.pos));
                }
            }
        }
        let mut chasers: Vec<(Entity, usize, Vec3)> = Vec::new();
        {
            let mut mobs = self.world.query::<(Entity, &Mob)>();
            for (entity, m) in mobs.iter(&self.world) {
                let on_it = m.mode == MobMode::Chase(player)
                    || m.attack.as_ref().is_some_and(|a| a.target == player);
                if on_it && m.mode != MobMode::Dead {
                    chasers.push((entity, m.pack, m.pos));
                }
            }
        }
        for (mob, pack, pos) in chasers {
            let anchor = self.packs[pack].anchor;
            let (leash, reach) = (
                self.game.packs[pack].leash,
                self.game.packs[pack].assist_radius,
            );
            let next = living
                .iter()
                .filter(|(_, at)| {
                    planar_distance(*at, anchor) <= leash && planar_distance(*at, pos) <= reach
                })
                .min_by(|a, b| planar_distance(a.1, pos).total_cmp(&planar_distance(b.1, pos)))
                .map(|(e, _)| *e);
            match next {
                Some(other) => {
                    let Some(mut m) = self.world.get_mut::<Mob>(mob) else {
                        continue;
                    };
                    // a blow wound up at the corpse is called off
                    let cancelled = if m.attack.as_ref().is_some_and(|a| a.target == player) {
                        m.attack
                            .take()
                            .is_some_and(|a| a.ability.is_some() && !a.released)
                    } else {
                        false
                    };
                    m.mode = MobMode::Chase(other);
                    m.next_think = tick;
                    if cancelled {
                        let caster = self.net_id_of(mob);
                        self.event(pos, CombatEvent::TelegraphCancelled { caster });
                    }
                }
                None => self.stand_by(mob),
            }
        }
    }

    /// `mob` lost its foe and stays where it is: idle (the pose too, so a
    /// sleeping cell does not freeze it mid-swing), a blow it was winding up
    /// called off; it looks round again at once and drifts home only by its
    /// usual strolls.
    fn stand_by(&mut self, mob: Entity) {
        let tick = self.tick;
        let Some(mut m) = self.world.get_mut::<Mob>(mob) else {
            return;
        };
        if m.mode == MobMode::Dead {
            return;
        }
        let cancelled = m
            .attack
            .take()
            .is_some_and(|a| a.ability.is_some() && !a.released);
        m.mode = MobMode::Idle;
        m.state = STATE_IDLE;
        m.path.clear();
        m.unreachable_since = 0;
        m.next_scan = tick;
        m.next_think = tick + ticks(WANDER_REST_MS.1);
        let at = m.pos;
        if cancelled {
            let caster = self.net_id_of(mob);
            self.event(at, CombatEvent::TelegraphCancelled { caster });
        }
    }

    /// `mob` turned on `player`: its pack mates within the assist radius join
    /// in (a returning one only for a player inside its home ground).
    pub(super) fn assist(&mut self, mob: Entity, player: Entity) {
        let Some((pack, pos)) = self.world.get::<Mob>(mob).map(|m| (m.pack, m.pos)) else {
            return;
        };
        let p = &self.game.packs[pack];
        let (radius, leash) = (p.assist_radius, p.leash);
        let anchor = self.packs[pack].anchor;
        let home_ground = self
            .player_pos
            .get(&player)
            .is_some_and(|pp| planar_distance(*pp, anchor) <= leash);
        let tick = self.tick;
        for i in 0..self.packs[pack].members.len() {
            let mate = self.packs[pack].members[i];
            if mate == mob {
                continue;
            }
            let Some(mut m) = self.world.get_mut::<Mob>(mate) else {
                continue;
            };
            if m.mode == MobMode::Dead
                || (m.mode == MobMode::Return && !home_ground)
                || (m.pos - pos).length() > radius
                || holds_target(&m, player, &self.player_pos, tick)
            {
                continue;
            }
            if m.boss && m.mode != MobMode::Chase(player) {
                m.mind.locked_until = tick + ticks(BOSS_TARGET_LOCK_MS);
            }
            m.mode = MobMode::Chase(player);
            m.next_think = tick;
        }
    }

    /// A player's blow on `mob`: it turns on the attacker (the last hitter is
    /// always the target), and its mates join.
    pub(super) fn provoke(&mut self, mob: Entity, attacker: Entity) {
        let tick = self.tick;
        let Some(mut m) = self.world.get_mut::<Mob>(mob) else {
            return;
        };
        if m.mode == MobMode::Dead {
            return;
        }
        m.hit_at = tick;
        // A boss keeps the foe it turned on for a while: blows from the
        // others do not drag it about the arena.
        if holds_target(&m, attacker, &self.player_pos, tick) {
            return;
        }
        if m.boss && m.mode != MobMode::Chase(attacker) {
            m.mind.locked_until = tick + ticks(BOSS_TARGET_LOCK_MS);
        }
        m.mode = MobMode::Chase(attacker);
        m.next_think = tick;
        self.assist(mob, attacker);
    }

    /// Whether a blow on a returning creature is shrugged off: the attacker
    /// stands outside its home ground.
    pub(super) fn evades(&self, mob: Entity, attacker_pos: Vec3) -> bool {
        self.world.get::<Mob>(mob).is_some_and(|m| {
            m.mode == MobMode::Return
                && planar_distance(attacker_pos, self.packs[m.pack].anchor)
                    > self.game.packs[m.pack].leash
        })
    }

    /// `mob` gives up: it walks home, and it and its pack mates that are not
    /// fighting lose what was on them.
    fn break_fight(&mut self, mob: Entity) {
        let Some(mut m) = self.world.get_mut::<Mob>(mob) else {
            return;
        };
        if m.mode == MobMode::Dead {
            return;
        }
        let cancelled = m
            .attack
            .take()
            .is_some_and(|a| a.ability.is_some() && !a.released);
        m.mode = MobMode::Return;
        m.status = super::status::Status::default();
        m.credit.clear();
        m.unreachable_since = 0;
        m.path.clear();
        let (pack, at) = (m.pack, m.pos);
        if cancelled {
            let caster = self.net_id_of(mob);
            self.event(at, CombatEvent::TelegraphCancelled { caster });
        }
        for i in 0..self.packs[pack].members.len() {
            let mate = self.packs[pack].members[i];
            if let Some(mut m) = self.world.get_mut::<Mob>(mate)
                && !matches!(m.mode, MobMode::Chase(_) | MobMode::Dead)
            {
                m.status = super::status::Status::default();
                m.credit.clear();
            }
        }
    }

    /// A creature fell: its corpse lingers, and the last of a pack starts
    /// the pack's respawn clock.
    /// `killer`: whose blow (or burn) felled it, if anyone's.
    pub(super) fn mob_died(&mut self, mob: Entity, killer: Option<Entity>) {
        let tick = self.tick;
        let Some(mut m) = self.world.get_mut::<Mob>(mob) else {
            return;
        };
        // A training dummy never falls: it stands up whole.
        if self.game.packs[m.pack].kind == PackKind::Dummy {
            m.hp = m.max_hp;
            return;
        }
        self.reward_kill(mob);
        let Some(mut m) = self.world.get_mut::<Mob>(mob) else {
            return;
        };
        let body = m.part_of;
        m.hp = 0.0;
        m.mode = MobMode::Dead;
        m.state = STATE_DEAD;
        m.died_at = tick;
        m.status = super::status::Status::default();
        let cancelled = m
            .attack
            .take()
            .is_some_and(|a| a.ability.is_some() && !a.released);
        let pack = m.pack;
        let roll = xorshift(&mut m.rng);
        let at = m.pos;
        self.stats.kills += 1;
        if let Some(body) = body {
            self.part_fell(mob, body, killer);
        }
        // A creature that falls mid-windup takes its warning with it.
        if cancelled {
            let caster = self.net_id_of(mob);
            self.event(at, CombatEvent::TelegraphCancelled { caster });
        }
        let state = &mut self.packs[pack];
        state.alive = state.alive.saturating_sub(1);
        let p = &self.game.packs[pack];
        let summoned = matches!(p.kind, PackKind::Summons(_) | PackKind::Dungeon(_));
        if state.alive == 0 && !summoned {
            let (lo, hi) = p.respawn_ticks;
            state.respawn_at = Some(tick + lo + roll % hi.saturating_sub(lo).max(1));
            state.announced = false;
        }
        // A commander rages when a pack mate falls.
        if p.commander {
            for i in 0..self.packs[pack].members.len() {
                let mate = self.packs[pack].members[i];
                if let Some(mut m) = self.world.get_mut::<Mob>(mate)
                    && m.boss
                    && m.mode != MobMode::Dead
                {
                    m.enraged = true;
                }
            }
        }
        let actor = killer
            .and_then(|k| self.world.get::<Player>(k))
            .map(|p| p.sheet.name.clone())
            .unwrap_or_default();
        let world_boss = self.game.packs[pack].world_boss;
        if world_boss && self.world.get::<Mob>(mob).is_some_and(|m| m.boss) {
            let name = self.boss_name(pack);
            self.notice(None, "boss_slain", name, actor.clone(), (0, 0));
        }
        let stone = match &self.game.packs[pack].kind {
            PackKind::Stone(kind) => self
                .game
                .rules
                .mobs
                .stone_types
                .get(kind)
                .map(|t| t.name.clone()),
            _ => None,
        };
        if let Some(name) = stone {
            self.notice(Some(at), "stone_shattered", name, actor, (0, 0));
        }
    }

    /// A boss pack's boss name.
    fn boss_name(&self, pack: usize) -> String {
        self.game.packs[pack]
            .boss_setup
            .as_ref()
            .and_then(|b| self.game.rules.mobs.bosses.get(&b.key))
            .map(|b| b.name.clone())
            .unwrap_or_default()
    }

    /// Tells the players near `at` (everyone on the map when None).
    pub(super) fn notice(
        &mut self,
        at: Option<Vec3>,
        kind: &str,
        subject: String,
        actor: String,
        (value, of): (u32, u32),
    ) {
        println!("[notice] {kind} {subject} {actor} {value}/{of}");
        let msg = realm_proto::control::ServerMsg::Notice {
            kind: kind.to_owned(),
            subject,
            actor,
            value,
            of,
            place: if at.is_none() {
                self.game.map.clone()
            } else {
                String::new()
            },
        };
        // A map-wide notice is the realm's: every map hears it through the
        // coordinator (this one too); alone, only this map.
        if at.is_none() && self.coord_send(realm_proto::coord::MapMsg::Announce(msg.clone())) {
            return;
        }
        let conns: Vec<super::ConnId> = self
            .clients
            .iter()
            .filter(|(_, c)| {
                at.is_none_or(|at| {
                    self.world
                        .get::<Player>(c.entity)
                        .is_some_and(|p| planar_distance(p.body.pos, at) <= super::INTEREST_RADIUS)
                })
            })
            .map(|(conn, _)| *conn)
            .collect();
        for conn in conns {
            self.send_control(conn, &msg);
        }
    }

    /// What a creature is, for `Inspect`.
    pub(super) fn creature_info(&self, id: u32) -> Option<realm_proto::control::ServerMsg> {
        let entity = *self.ids.get(&id)?;
        let m = self.world.get::<Mob>(entity)?;
        let p = &self.game.packs[m.pack];
        let name = match &p.kind {
            PackKind::Stone(kind) => self
                .game
                .rules
                .mobs
                .stone_types
                .get(kind)
                .map(|t| t.name.clone()),
            PackKind::Dummy => Some(self.game.rules.mobs.dummy_name.clone()),
            _ if m.boss => Some(self.boss_name(m.pack)),
            _ => None,
        };
        let boss_key = if m.boss {
            p.boss_setup
                .as_ref()
                .map(|b| b.key.clone())
                .unwrap_or_default()
        } else {
            String::new()
        };
        Some(realm_proto::control::ServerMsg::CreatureInfo {
            entity: id,
            boss_key,
            name: name.unwrap_or_default(),
            level: m.level,
            elite: m.elite,
            boss: m.boss,
            parts: m
                .parts
                .iter()
                .map(|(e, name)| (self.net_id_of(*e), name.clone()))
                .collect(),
            part_of: m.part_of.map_or(0, |b| self.net_id_of(b)),
            max_hp: m.max_hp.round().max(1.0) as u32,
        })
    }

    /// `mob`'s info again to the players near it (its whole health changed).
    pub(super) fn refresh_creature_info(&mut self, mob: Entity) {
        let id = self.net_id_of(mob);
        let Some(at) = self.world.get::<Mob>(mob).map(|m| m.pos) else {
            return;
        };
        let Some(msg) = self.creature_info(id) else {
            return;
        };
        let conns: Vec<super::ConnId> = self
            .clients
            .iter()
            .filter(|(_, c)| {
                self.world
                    .get::<Player>(c.entity)
                    .is_some_and(|p| planar_distance(p.body.pos, at) <= super::INTEREST_RADIUS)
            })
            .map(|(conn, _)| *conn)
            .collect();
        for conn in conns {
            self.send_control(conn, &msg);
        }
    }

    /// A Dark Shard under attack calls a wave each time its health drops past
    /// one of its thresholds; the wave turns on the attacker.
    pub(super) fn stone_waves(&mut self, stone: Entity, attacker: Entity) {
        let Some((pack, pos, share)) = self
            .world
            .get::<Mob>(stone)
            .map(|m| (m.pack, m.pos, m.hp / m.max_hp.max(1.0)))
        else {
            return;
        };
        let PackKind::Stone(kind) = &self.game.packs[pack].kind else {
            return;
        };
        let rules = self.rules();
        let Some(t) = rules.mobs.stone_types.get(kind) else {
            return;
        };
        // The stone's waves are the next pack (game.rs puts them there).
        let waves = pack + 1;
        let tick = self.tick;
        // Struck again and again, it calls more than its waves.
        if let Some(r) = t.reinforce.as_ref().filter(|r| !r.mobs.is_empty())
            && self.packs[pack].reinforce_at <= tick
        {
            let first = self.packs[pack].reinforce_at == 0;
            self.packs[pack].reinforce_at = tick + (r.every_ms * realm_sim::SIM_HZ).div_ceil(1000);
            // The first blow only starts the clock.
            if !first {
                let room = r.cap.saturating_sub(self.packs[waves].alive);
                for _ in 0..r.count.min(room) {
                    let k = self.packs[pack].reinforced as usize % r.mobs.len();
                    self.packs[pack].reinforced += 1;
                    let (species, level) = &r.mobs[k];
                    let at = self.round_stone(pos, t.spawn_distance);
                    self.summon(waves, species, *level, at, attacker, false);
                }
            }
        }
        while self.packs[pack].waves_done < t.waves.len()
            && share <= t.waves[self.packs[pack].waves_done].ratio
        {
            let wave = &t.waves[self.packs[pack].waves_done];
            self.packs[pack].waves_done += 1;
            for (species, count, level, elites) in &wave.spawns {
                for k in 0..*count {
                    let at = self.round_stone(pos, t.spawn_distance);
                    self.summon(waves, species, *level, at, attacker, k < *elites);
                }
            }
            let (wave, of) = (self.packs[pack].waves_done as u32, t.waves.len() as u32);
            self.notice(
                Some(pos),
                "stone_wave",
                t.name.clone(),
                String::new(),
                (wave, of),
            );
        }
    }

    /// A spot on the ground round a stone at `pos`, `spread` (from, to)
    /// metres out (not on a roof, in a trunk or a spire); the stone's own
    /// spot when none is.
    fn round_stone(&mut self, pos: Vec3, spread: (f32, f32)) -> Vec3 {
        let a = unit(&mut self.dice_state) * core::f32::consts::TAU;
        let (lo, hi) = spread;
        let r = lo + unit(&mut self.dice_state) * (hi - lo).max(0.0);
        (0..8)
            .find_map(|k| {
                let a = a + 0.4 * k as f32;
                let (x, z) = (pos.x + libm::cosf(a) * r, pos.z + libm::sinf(a) * r);
                self.nav.creature_spot(&self.terrain, x, z)
            })
            .unwrap_or(pos)
    }

    /// A creature of `species` at `level` (an elite when `elite`) comes into
    /// the summons pack at `at` and turns on `target`.
    fn summon(
        &mut self,
        pack: usize,
        species: &str,
        level: u32,
        at: Vec3,
        target: Entity,
        elite: bool,
    ) {
        let Some(index) = self.game.species.iter().position(|s| s.id == species) else {
            return;
        };
        let (hp, power) = self.game.stats_at(index, level);
        let mods = self.game.rules.mobs.elite;
        let (hp, power) = if elite {
            (hp * mods.hp_mult, power * mods.attack_mult)
        } else {
            (hp, power)
        };
        let sp = &self.game.species[index];
        let mob = Mob {
            pack,
            species: index as u16,
            home: at,
            pos: at,
            yaw: (xorshift(&mut self.dice_state) & 0xFFFF) as u16,
            hp,
            max_hp: hp,
            level,
            attack_power: power,
            attack_range: sp.attack_range,
            move_speed: sp.move_speed,
            elite,
            boss: false,
            enraged: false,
            mind: Mind::default(),
            exp_reward: self.game.rules.progress.creature_exp(species, level, elite),
            credit: Vec::new(),
            mode: MobMode::Chase(target),
            attack_cd: 0.0,
            attack: None,
            attacks_made: 0,
            thrown: Vec::new(),
            hit_at: self.tick,
            unreachable_since: 0,
            next_scan: 0,
            next_think: self.tick,
            died_at: 0,
            rng: xorshift(&mut self.dice_state) | 1,
            state: STATE_IDLE,
            path: Vec::new(),
            path_goal: at,
            replan_at: 0,
            status: super::status::Status::default(),
            drop_scale: 1.0,
            windup_scale: 1.0,
            part_of: None,
            parts: Vec::new(),
            phase: 1,
        };
        let entity = self.world.spawn(mob).id();
        let id = self.new_id(entity);
        self.world.entity_mut(entity).insert(NetId(id));
        self.packs[pack].members.push(entity);
        self.packs[pack].alive += 1;
        self.packs[pack].anchor = at;
        self.assist(entity, target);
    }

    /// Takes a creature out of the world for good (a wave's corpse, or a
    /// wave left standing when its stone comes back).
    pub(super) fn despawn(&mut self, entity: Entity) {
        if let Some(id) = self.world.get::<NetId>(entity).map(|n| n.0) {
            self.ids.remove(&id);
        }
        self.world.despawn(entity);
    }

    /// Waves' corpses go once they have lain a while.
    fn clear_corpses(&mut self) {
        let tick = self.tick;
        for pack in 0..self.packs.len() {
            if !matches!(
                self.game.packs[pack].kind,
                PackKind::Summons(_) | PackKind::Dungeon(_)
            ) {
                continue;
            }
            let gone: Vec<Entity> = self.packs[pack]
                .members
                .iter()
                .copied()
                .filter(|&e| {
                    self.world.get::<Mob>(e).is_none_or(|m| {
                        m.mode == MobMode::Dead && tick > m.died_at + super::CORPSE_TICKS
                    })
                })
                .collect();
            for e in gone {
                self.packs[pack].members.retain(|m| *m != e);
                self.despawn(e);
            }
        }
    }

    /// Packs whose time has come stand up again on a fresh anchor; one with
    /// no free spot tries again shortly.
    fn respawn_packs(&mut self) {
        let tick = self.tick;
        if !tick.is_multiple_of(RESPAWN_CHECK_TICKS) {
            return;
        }
        self.clear_corpses();
        for pack in 0..self.packs.len() {
            let Some(at) = self.packs[pack].respawn_at else {
                continue;
            };
            if self.game.packs[pack].world_boss
                && !self.packs[pack].announced
                && at <= tick + WORLD_BOSS_WARNING
            {
                self.packs[pack].announced = true;
                let name = self.boss_name(pack);
                let seconds = at.saturating_sub(tick).div_ceil(SIM_HZ);
                self.notice(None, "boss_soon", name, String::new(), (seconds, 0));
            }
            if at > tick {
                continue;
            }
            if self.place_pack(pack, false) {
                if self.game.packs[pack].world_boss {
                    let name = self.boss_name(pack);
                    let level = self.game.packs[pack].level;
                    self.notice(None, "boss_spawned", name, String::new(), (level, 0));
                }
            } else {
                let retry = ticks(self.game.rules.mobs.tuning.respawn_retry_ms.max(1000));
                let jitter = xorshift(&mut self.dice_state) % retry.max(1);
                self.packs[pack].respawn_at = Some(tick + retry + jitter);
            }
        }
    }

    /// A spot in the pack's area: on the walkable ground (`creature_spot`:
    /// never a roof or a prop, dry, not too steep), not protected, apart
    /// from other packs and (`initial` aside) from players.
    fn pack_spot(&mut self, pack: usize, initial: bool) -> Option<Vec3> {
        let p = &self.game.packs[pack];
        let (center, half, clear_radius) = (p.center, p.half_extent, p.clear_radius);
        let attempts = self.game.rules.mobs.tuning.placement_attempts.max(1);
        for _ in 0..attempts {
            let x = center.0 + (unit(&mut self.dice_state) * 2.0 - 1.0) * half.0.max(1.0);
            let z = center.1 + (unit(&mut self.dice_state) * 2.0 - 1.0) * half.1.max(1.0);
            let Some(spot) = self.nav.creature_spot(&self.terrain, x, z) else {
                continue;
            };
            if self.spot_free(pack, spot, initial, clear_radius) {
                return Some(spot);
            }
        }
        // At boot a pack whose draws all missed looks through its whole
        // area, nearest the centre first (its ground can be a corner of it):
        // it stands up wherever `realm_worldc check` found ground for it.
        if initial {
            let half = (half.0.max(1.0), half.1.max(1.0));
            return self
                .nav
                .ground_in_area(&self.terrain, center, half, |spot| {
                    self.spot_free(pack, spot, initial, clear_radius)
                });
        }
        None
    }

    /// Whether a creature spot is free for `pack`'s anchor: not protected,
    /// apart from other packs and (`initial` aside) from players.
    fn spot_free(&self, pack: usize, spot: Vec3, initial: bool, clear_radius: f32) -> bool {
        !(self.protected(spot)
            || self.packs.iter().enumerate().any(|(i, s)| {
                i != pack
                    && !s.members.is_empty()
                    && planar_distance(s.anchor, spot) < ANCHOR_SPACING
            })
            || (!initial
                && self
                    .player_pos
                    .values()
                    .any(|pp| planar_distance(*pp, spot) < clear_radius)))
    }

    /// Prints where the creatures stood up at boot: how many stand on the
    /// walkable ground (`NavQuery::on_ground`) and every one that does not
    /// (on a roof, a prop, in the air), which the placement never allows.
    pub(super) fn report_creature_ground(&self) {
        let (mut on, mut off) = (0, Vec::new());
        for m in self.world.iter_entities().filter_map(|e| e.get::<Mob>()) {
            let pack = &self.game.packs[m.pack];
            // Dark Shards and dummies stand on their authored posts.
            if self.game.species[pack.species].object || m.mode == MobMode::Dead {
                continue;
            }
            let rests = self
                .terrain
                .ray_down(m.pos + Vec3::new(0.0, 0.2, 0.0), 0.5)
                .is_some_and(|g| (g.point.y - m.pos.y).abs() < 0.05);
            if rests && self.nav.on_ground(&self.terrain, m.pos) {
                on += 1;
            } else {
                off.push((m.pack, m.pos));
            }
        }
        println!("[creatures] {} on the ground, {} off it", on, off.len());
        for (pack, pos) in off.iter().take(10) {
            println!("[creatures]   pack {pack} stands off the ground at {pos}");
        }
    }

    /// Stands a pack up on a fresh anchor: members on a ring around it,
    /// full health, elites rolled. Returns false when no spot was free.
    pub(super) fn place_pack(&mut self, pack: usize, initial: bool) -> bool {
        let kind = self.game.packs[pack].kind.clone();
        let fixed = match &kind {
            // A dummy stands on its post; a Dark Shard lands on its site the
            // first time.
            PackKind::Dummy => true,
            PackKind::Stone(_) => initial,
            _ => false,
        };
        let anchor = match self.pack_spot(pack, initial) {
            _ if fixed => {
                let (x, z) = self.game.packs[pack].center;
                let y = self.terrain.ground_height(x, z).unwrap_or(0.0);
                Vec3::new(x, y, z)
            }
            Some(spot) => spot,
            None if initial => {
                // No ground anywhere in its area: it is left out (its
                // members lie unseen until a respawn finds a spot), never
                // stood off the ground; realm_worldc check fails on such a
                // pack.
                let p = &self.game.packs[pack];
                println!(
                    "[creatures] pack {pack} ({}) finds no ground in its area around ({}, {}): left out",
                    self.game.species[p.species].id, p.center.0, p.center.1
                );
                for i in 0..self.packs[pack].members.len() {
                    let member = self.packs[pack].members[i];
                    if let Some(mut m) = self.world.get_mut::<Mob>(member) {
                        m.hp = 0.0;
                        m.mode = MobMode::Dead;
                        m.state = STATE_DEAD;
                        m.died_at = 0;
                    }
                }
                let retry = ticks(self.game.rules.mobs.tuning.respawn_retry_ms.max(1000));
                let state = &mut self.packs[pack];
                state.alive = 0;
                state.respawn_at = Some(self.tick + retry);
                return false;
            }
            None => return false,
        };
        let tick = self.tick;
        let rules = self.rules();
        let elite = rules.mobs.elite;
        let spacing = rules.mobs.tuning.pack_spacing;
        let p = &self.game.packs[pack];
        let (boss, count, level) = (p.boss, self.packs[pack].members.len().max(1), p.level);
        let object = self.game.species[p.species].object;
        let (max_hp, attack) = if object {
            (self.game.species[p.species].max_hp, 0.0)
        } else {
            self.game.stats_at(p.species, level)
        };
        let boss_stats = p
            .boss_setup
            .as_ref()
            .and_then(|b| {
                self.game
                    .boss_stats(&b.key)
                    .zip(self.game.rules.mobs.bosses.get(&b.key))
            })
            .map(|((hp, power), def)| (hp, power, def.attack_range, def.move_speed));
        let (range, speed) = {
            let sp = &self.game.species[p.species];
            (sp.attack_range, sp.move_speed)
        };
        let ring = if count > 1 {
            spacing / (2.0 * libm::sinf(core::f32::consts::PI / count as f32))
        } else {
            0.0
        };
        let start = unit(&mut self.dice_state) * core::f32::consts::TAU;
        for i in 0..self.packs[pack].members.len() {
            let a = start + core::f32::consts::TAU * i as f32 / count as f32;
            // A member whose place on the ring is no ground for it (a roof,
            // a trunk, a spire) steps round the ring; with no room it stands
            // on the anchor.
            let home = (0..8)
                .find_map(|k| {
                    let a = a + 0.35 * k as f32;
                    let (x, z) = (
                        anchor.x + libm::cosf(a) * ring,
                        anchor.z + libm::sinf(a) * ring,
                    );
                    self.nav.creature_spot(&self.terrain, x, z)
                })
                .unwrap_or(anchor);
            // Bosses and their escorts never roll elite, nor do objects.
            let is_elite = !boss && !object && unit(&mut self.dice_state) < elite.chance;
            let is_boss = i == 0 && boss_stats.is_some();
            let (hp, power, reach, pace) = match boss_stats {
                Some(b) if is_boss => b,
                _ if is_elite => (
                    max_hp * elite.hp_mult,
                    attack * elite.attack_mult,
                    range,
                    speed,
                ),
                _ => (max_hp, attack, range, speed),
            };
            let home = if count == 1 { anchor } else { home };
            let member = self.packs[pack].members[i];
            if let Some(mut m) = self.world.get_mut::<Mob>(member) {
                m.home = home;
                m.pos = home;
                m.max_hp = hp;
                m.hp = hp;
                m.attack_power = power;
                m.attack_range = reach;
                m.move_speed = pace;
                m.level = level;
                m.elite = is_elite;
                m.boss = is_boss;
                m.enraged = false;
                m.mind = Mind::default();
                m.credit.clear();
                m.mode = MobMode::Idle;
                m.state = STATE_IDLE;
                m.attack = None;
                m.attack_cd = 0.0;
                m.attacks_made = 0;
                m.thrown.clear();
                m.status = super::status::Status::default();
                m.path.clear();
                m.path_goal = home;
                m.next_think = tick;
                m.unreachable_since = 0;
            }
        }
        for i in 0..self.packs[pack].members.len() {
            let member = self.packs[pack].members[i];
            let exp = self.world.get::<Mob>(member).map(|m| self.exp_reward_of(m));
            if let (Some(exp), Some(mut m)) = (exp, self.world.get_mut::<Mob>(member)) {
                m.exp_reward = exp;
            }
        }
        let state = &mut self.packs[pack];
        state.anchor = anchor;
        state.alive = state.members.len() as u32;
        state.respawn_at = None;
        state.waves_done = 0;
        state.announced = false;
        state.reinforce_at = 0;
        state.reinforced = 0;
        // A Dark Shard back on its feet clears the waves left idle.
        if matches!(kind, PackKind::Stone(_)) {
            let waves = pack + 1;
            let idle: Vec<Entity> = self.packs[waves]
                .members
                .iter()
                .copied()
                .filter(|&e| {
                    self.world
                        .get::<Mob>(e)
                        .is_none_or(|m| !matches!(m.mode, MobMode::Chase(_)))
                })
                .collect();
            for e in idle {
                self.packs[waves].members.retain(|m| *m != e);
                self.despawn(e);
            }
            let alive = self.packs[waves].members.len() as u32;
            self.packs[waves].alive = alive;
        }
        true
    }

    /// An attack lands: a plain swing on its target, a bolt off the wand, an
    /// ability on everyone in its shape.
    fn strike(&mut self, mob: Entity, attack: Attack) {
        let tick = self.tick;
        let rules = self.rules();
        let Some((pos, power, species, level)) = self.world.get::<Mob>(mob).and_then(|m| {
            (m.mode != MobMode::Dead).then(|| {
                (
                    m.pos,
                    m.attack_power
                        * m.status.strength(tick)
                        * if m.enraged { ENRAGE_ATTACK } else { 1.0 },
                    usize::from(m.species),
                    m.level,
                )
            })
        }) else {
            return;
        };
        let sp = &self.game.species[species];
        let eye = pos + Vec3::new(0.0, CHEST, 0.0);
        let Some(index) = attack.ability else {
            let Some(tpos) = self.player_pos.get(&attack.target).copied() else {
                return;
            };
            // A boss fights with its patterns, never with a caster's bolt.
            let boss = self.world.get::<Mob>(mob).is_some_and(|m| m.boss);
            if let Some((spell, speed, range)) = sp.bolt.filter(|_| !boss) {
                let from = pos + Vec3::new(0.0, WAND, 0.0);
                let aim = tpos + Vec3::new(0.0, CHEST, 0.0);
                if self.terrain.line_hit(from, aim).is_some() {
                    return;
                }
                let dir = (aim - from).normalize_or_zero();
                let caster = self.net_id_of(mob);
                self.event(
                    pos,
                    CombatEvent::CastReleased {
                        caster,
                        spell,
                        from: [from.x, from.y, from.z],
                        dir: [dir.x, dir.y, dir.z],
                    },
                );
                self.mob_bolts.push(MobBolt {
                    owner: mob,
                    spell,
                    pos: from,
                    dir,
                    speed,
                    left: range,
                    damage: power,
                    level,
                });
                return;
            }
            let reach = self
                .world
                .get::<Mob>(mob)
                .map_or(sp.attack_range, |m| m.attack_range);
            let lunge = if sp.brain.windup_ms > 0 {
                MELEE_LUNGE * reach
            } else {
                0.0
            };
            if planar_distance(pos, tpos) <= reach + MELEE_SLACK + lunge
                && self
                    .terrain
                    .line_hit(eye, tpos + Vec3::new(0.0, CHEST, 0.0))
                    .is_none()
            {
                self.hit_player(attack.target, mob, power, "melee", level);
                self.curse_bleed(mob, attack.target);
            }
            return;
        };
        let Some(ability) = rules.mobs.ability(index) else {
            return;
        };
        let name: &str = if !ability.fx.is_empty() {
            &ability.fx
        } else if matches!(ability.shape, Shape::Cone { .. }) {
            "boss_cone"
        } else {
            "boss_area"
        };
        let damage = power * ability.damage_multiplier;
        let mut victims: Vec<Entity> = Vec::new();
        for c in cells_around(attack.center, 1) {
            for &(player, ppos) in &self.player_cells[c] {
                let chest = ppos + Vec3::new(0.0, CHEST, 0.0);
                let inside = match ability.shape {
                    Shape::Area { radius, .. } => {
                        (ppos - attack.center).length() <= radius
                            && self
                                .terrain
                                .line_hit(attack.center + Vec3::new(0.0, 0.5, 0.0), chest)
                                .is_none()
                    }
                    Shape::Cone { range, half_angle } => {
                        planar_distance(ppos, pos) <= range
                            && flat_dir(pos, ppos).dot(attack.dir) >= libm::cosf(half_angle)
                            && self.terrain.line_hit(eye, chest).is_none()
                    }
                };
                if inside {
                    victims.push(player);
                }
            }
        }
        let mut drained = 0.0;
        for victim in victims {
            // A ward raised just in time throws the blow back.
            if self.perfect_ward(victim) {
                self.throw_back(victim, mob, damage, &ability.riders);
                continue;
            }
            let dealt = self.hit_player(victim, mob, damage, name, level);
            if dealt > 0 {
                let from = match ability.shape {
                    Shape::Area { .. } => attack.center,
                    Shape::Cone { .. } => pos,
                };
                self.afflict(victim, mob, from, &ability.riders, power);
                drained += dealt as f32 * ability.riders.drain;
            }
        }
        if drained > 0.0
            && let Some(mut m) = self.world.get_mut::<Mob>(mob)
        {
            m.hp = (m.hp + drained).min(m.max_hp);
        }
    }

    /// Creature bolts fly straight; the first player near the path takes the
    /// blow, a wall stops it.
    pub(super) fn advance_mob_bolts(&mut self) {
        let mut bolts = std::mem::take(&mut self.mob_bolts);
        let mut hits: Vec<(Entity, Entity, f32, u8, u32)> = Vec::new();
        bolts.retain_mut(|b| {
            let step = (b.speed * SIM_DT).min(b.left);
            let to = b.pos + b.dir * step;
            let wall = self.terrain.line_hit(b.pos, to);
            let reach = wall.map_or(step, |t| step * t);
            let mut best: Option<(f32, Entity)> = None;
            for c in cells_around(b.pos, 1) {
                for &(player, ppos) in &self.player_cells[c] {
                    let chest = ppos + Vec3::new(0.0, CHEST, 0.0);
                    let along = (chest - b.pos).dot(b.dir);
                    if along < 0.0 || along > reach {
                        continue;
                    }
                    let miss = (b.pos + b.dir * along - chest).length();
                    if miss <= BOLT_RADIUS && best.is_none_or(|(d, _)| along < d) {
                        best = Some((along, player));
                    }
                }
            }
            if let Some((_, player)) = best {
                hits.push((player, b.owner, b.damage, b.spell, b.level));
                return false;
            }
            b.pos = to;
            b.left -= step;
            wall.is_none() && b.left > 0.0
        });
        self.mob_bolts = bolts;
        let rules = self.rules();
        for (player, owner, damage, spell, level) in hits {
            // A ward raised just in time sends the bolt back at its caster.
            if self.perfect_ward(player) {
                self.throw_back(player, owner, damage, &Riders::default());
                continue;
            }
            let name = rules
                .combat
                .spell_order
                .get(usize::from(spell))
                .map_or("basic_cast", String::as_str);
            self.hit_player(player, owner, damage, name, level);
        }
    }
}

/// Whether a boss stays on the target it holds rather than turn on
/// `other`: its hold has not run out and that target is still there to
/// fight.
fn holds_target(m: &Mob, other: Entity, alive: &HashMap<Entity, Vec3>, tick: u32) -> bool {
    m.boss
        && tick < m.mind.locked_until
        && matches!(m.mode, MobMode::Chase(t) if t != other && alive.contains_key(&t))
}

/// A melee creature cannot reach a target this far above it.
fn out_of_reach(mob: Vec3, target: Vec3, attack_range: f32) -> bool {
    let up = target.y - mob.y;
    up >= 12.0 || (up >= (attack_range + 1.5).max(4.0) && planar_distance(mob, target) < 9.0)
}

/// Starts a telegraphed ability aimed at `aim` (the target, or where it is
/// going): its shape is fixed now (a target that steps out dodges it).
/// `scale`: the difficulty's and the phase's share of its windup.
fn begin(
    mob: &mut Mob,
    ab: &AbilityDef,
    target: Entity,
    aim: Vec3,
    tick: u32,
    cooldown: f32,
    scale: f32,
) -> Attack {
    let dir = flat_dir(mob.pos, aim);
    mob.yaw = yaw_of(dir);
    let center = match ab.shape {
        Shape::Area {
            at_target: true, ..
        } => aim,
        Shape::Area { offset, .. } => mob.pos + facing(mob.yaw) * offset,
        Shape::Cone { .. } => mob.pos,
    };
    let release = tick + ticks(windup_of(ab, scale));
    // A combo's blow is followed by the next one, not by its recovery.
    let after = if ab.then.is_some() {
        ab.chain_ms
    } else {
        ab.recovery_ms
    };
    let a = Attack {
        ability: Some(ab.index),
        target,
        center,
        dir,
        release,
        done: release + ticks(after),
        released: false,
        then: ab.then,
    };
    mob.attack = Some(a);
    mob.attack_cd = cooldown;
    mob.state = STATE_ATTACKING;
    a
}

/// `ab`'s windup at `scale` (the difficulty's and the phase's): shortened,
/// never below the time a player on foot needs to run out of it (one
/// authored shorter keeps its own length).
fn windup_of(ab: &AbilityDef, scale: f32) -> u32 {
    let ms = ab.windup_ms;
    let scaled = (ms as f32 * scale) as u32;
    if scale < 1.0 {
        scaled.max(ms.min(ab.fair_windup_ms(realm_sim::movement::WALK_SPEED)))
    } else {
        scaled
    }
}

/// Where a mark aimed `lead_ms` ahead of a target at `tpos` going `vel`
/// lands: on the ground ahead of it (at most LEAD_REACH), never through a
/// wall; the target's own spot when it stands or there is no ground.
fn lead_aim(terrain: &Terrain, tpos: Vec3, vel: Vec3, lead_ms: u32) -> Vec3 {
    if lead_ms == 0 {
        return tpos;
    }
    let mut ahead = Vec3::new(vel.x, 0.0, vel.z) * (lead_ms as f32 / 1000.0);
    let len = ahead.length();
    if len < 0.05 {
        return tpos;
    }
    if len > LEAD_REACH {
        ahead *= LEAD_REACH / len;
    }
    let spot = tpos + ahead;
    let chest = Vec3::new(0.0, CHEST, 0.0);
    if terrain.line_hit(tpos + chest, spot + chest).is_some() {
        return tpos;
    }
    terrain
        .ray_down(spot + Vec3::new(0.0, 2.0, 0.0), 5.0)
        .map_or(tpos, |g| g.point)
}

/// A boss's next pattern from its style's `list`: one that fits where its
/// target stands (its band, or within reach; one beyond reach needs a clear
/// line), its phase and its own rest; never the one it threw last when
/// another fits; by weight. None: nothing fits, it closes in.
fn choose(
    mobs: &realm_rules::creatures::CreatureRules,
    list: &[u16],
    mob: &mut Mob,
    dist: f32,
    sight: bool,
    tick: u32,
) -> Option<u16> {
    let reach = mob.attack_range;
    let phase = mob.phase.max(1);
    let fits: Vec<(u16, f32)> = list
        .iter()
        .copied()
        .filter_map(|i| {
            let ab = mobs.ability(i)?;
            let near = match ab.band {
                Some((lo, hi)) => dist >= lo && dist <= hi,
                None => dist <= reach,
            };
            (near
                && !ab.chain_only
                && ab.weight > 0.0
                && ab.min_phase <= phase
                && (dist <= reach || sight)
                && mob.thrown_ready(i) <= tick)
                .then_some((i, ab.weight))
        })
        .collect();
    let fresh: Vec<(u16, f32)> = if fits.len() > 1 {
        fits.into_iter()
            .filter(|f| Some(f.0) != mob.mind.last)
            .collect()
    } else {
        fits
    };
    let total: f32 = fresh.iter().map(|f| f.1).sum();
    if total <= 0.0 {
        return None;
    }
    let mut roll = unit(&mut mob.rng) * total;
    for &(i, w) in &fresh {
        if roll < w {
            return Some(i);
        }
        roll -= w;
    }
    fresh.last().map(|f| f.0)
}

fn telegraph(caster: u32, ab: &AbilityDef, a: &Attack) -> Deed {
    Deed::Telegraph(
        a.center,
        CombatEvent::Telegraph {
            caster,
            ability: ab.index,
            center: [a.center.x, a.center.y, a.center.z],
            yaw: yaw_radians(a.dir),
            release_tick: a.release,
            recovery_tick: a.done,
        },
    )
}
