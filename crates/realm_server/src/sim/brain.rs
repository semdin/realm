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

use realm_proto::control::CombatEvent;
use realm_rules::creatures::{
    AGGRO_SCAN_MS, AbilityDef, BOLT_REACH, HOME_RADIUS, LEASH_HOT_MS, LEASH_HOT_SCALE, MELEE_LUNGE,
    MELEE_SLACK, RETURN_REGEN_SHARE, RING_PACE, Shape, Trigger, UNREACHABLE_MS, WINDUP_STEP,
};
use realm_sim::nav::{NavQuery, NavScratch};
use realm_sim::world::World as Terrain;
use realm_sim::{SIM_DT, SIM_HZ, Vec3};
use std::time::Instant;

use super::{
    DIRECT_CHASE, Entity, GROUND_EVERY, Mob, MobMode, NetId, PATH_NODE_BUDGET, Player,
    REPLAN_DRIFT, STATE_ATTACKING, STATE_DEAD, STATE_IDLE, STATE_MOVING, Sim, cell_of,
    cells_around, planar_distance, planar_distance_sq, unit, xorshift, yaw_of,
};

/// Packs are checked for their respawn this often.
const RESPAWN_CHECK_TICKS: u32 = 15;
/// Another pack's anchor this close rejects a respawn spot.
const ANCHOR_SPACING: f32 = 6.2;
/// Steepest ground a pack respawns on (normal's up component).
const FLAT_ENOUGH: f32 = 0.72;
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
        if dist < DIRECT_CHASE {
            mob.path.clear();
            mob.path.push(goal);
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
            mob.pos += apart * (speed * SIM_DT);
        }
        // Height follows the ground every third tick, creatures spread over
        // the three.
        if (tick + mob.rng).is_multiple_of(GROUND_EVERY) {
            let t_ground = Instant::now();
            if let Some(ground) = self
                .terrain
                .ray_down(mob.pos + Vec3::new(0.0, 1.5, 0.0), 4.0)
            {
                mob.pos.y = ground.point.y;
            }
            self.ground_ms += t_ground.elapsed().as_secs_f64() * 1000.0;
        }
        true
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
                let reach = self.game.species[usize::from(m.species)].attack_range + 0.8;
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
        let awake_cells = &self.awake;
        let auras = &mut self.auras;
        let mut scratch = std::mem::take(&mut self.nav_scratch);
        let mut walk = Walk {
            terrain,
            nav: &self.nav,
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
            let species = &game.species[pack.species];
            let brain = &species.brain;
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
                    let moved = walk.step(
                        &mut mob,
                        home,
                        species.move_speed * pace,
                        0.3,
                        tick,
                        Vec3::ZERO,
                    );
                    mob.state = if moved { STATE_MOVING } else { STATE_IDLE };
                    if planar_distance(mob.pos, home) < HOME_RADIUS {
                        mob.hp = mob.max_hp;
                        mob.mode = MobMode::Idle;
                        mob.path.clear();
                    }
                }
                MobMode::Idle | MobMode::Wander(_) => {
                    if pack.aggressive && tick >= mob.next_scan {
                        mob.next_scan = tick + scan_ticks;
                        thinking += 1;
                        let radius = game.aggro_radius(pack);
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
                                && (species.bolt.is_some()
                                    || !out_of_reach(mob.pos, pos, species.attack_range))
                                && clear(eye, pos + Vec3::new(0.0, CHEST, 0.0))
                        });
                        if let Some((_, player, _)) = found {
                            mob.mode = MobMode::Chase(player);
                            deeds.push(Deed::Aggro(me, player));
                            continue;
                        }
                    }
                    // Stand a few seconds, stroll a few metres from home,
                    // stand again.
                    if let MobMode::Wander(to) = mob.mode {
                        let speed = species.move_speed * WANDER_PACE * pace;
                        let moved = walk.step(&mut mob, to, speed, 0.3, tick, Vec3::ZERO);
                        mob.state = if moved { STATE_MOVING } else { STATE_IDLE };
                        if !moved || tick >= mob.next_think {
                            mob.mode = MobMode::Idle;
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
                            mob.mode = MobMode::Wander(
                                mob.home + Vec3::new(libm::cosf(a) * r, 0.0, libm::sinf(a) * r),
                            );
                            mob.next_think = tick + ticks(WANDER_GIVE_UP_MS);
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
                    let limit = pack.leash * if hot { LEASH_HOT_SCALE } else { 1.0 };
                    if (mob.pos - anchor).length() > limit {
                        deeds.push(Deed::Break(me));
                        continue;
                    }
                    if species.bolt.is_none() && !pack.boss {
                        if out_of_reach(mob.pos, tpos, species.attack_range) {
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

                    // An attack under way: wind up, land, recover.
                    if let Some(mut a) = mob.attack {
                        mob.state = STATE_ATTACKING;
                        if !a.released {
                            // A plain swing follows a retreating target.
                            if a.ability.is_none() && species.bolt.is_none() {
                                let stop = species.attack_range * 0.8;
                                walk.step(
                                    &mut mob,
                                    tpos,
                                    species.move_speed * WINDUP_STEP * pace,
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
                        }
                        continue;
                    }

                    let dist = planar_distance(mob.pos, tpos);
                    let eye = mob.pos + Vec3::new(0.0, CHEST, 0.0);
                    let chest = tpos + Vec3::new(0.0, CHEST, 0.0);
                    let can_act = brain.windup_ms > 0 || !brain.abilities.is_empty();
                    // A target out of reach draws a thrown ability.
                    if can_act && mob.attack_cd <= 0.0 && dist > species.attack_range {
                        let throw = brain.abilities.iter().copied().find(|&i| {
                            rules.mobs.ability(i).is_some_and(|ab| match ab.trigger {
                                Trigger::Thrown {
                                    min_range,
                                    max_range,
                                    ..
                                } => {
                                    dist >= min_range
                                        && dist <= max_range
                                        && mob.thrown_ready(i) <= tick
                                }
                                _ => false,
                            })
                        });
                        if let Some(i) = throw
                            && clear(eye, chest)
                            && let Some(ab) = rules.mobs.ability(i)
                        {
                            if let Trigger::Thrown { cooldown_ms, .. } = ab.trigger {
                                mob.set_thrown_ready(i, tick + ticks(cooldown_ms));
                            }
                            let a = begin(
                                &mut mob,
                                ab,
                                target,
                                tpos,
                                tick,
                                species.attack_cooldown_ticks,
                            );
                            deeds.push(telegraph(net_id.0, ab, &a));
                            continue;
                        }
                    }
                    let ranged = species.bolt.is_some();
                    let reach = if ranged {
                        BOLT_REACH
                    } else {
                        species.attack_range
                    };
                    let in_reach = dist <= reach && (!ranged || clear(eye, chest));
                    // The ring: past `attack_slots` mates on this target, wait.
                    let mut ring = None;
                    if !ranged && !pack.boss && mates.len() > 1 {
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
                        let every = brain.abilities.iter().copied().find(|&i| {
                            rules.mobs.ability(i).is_some_and(|ab| {
                                matches!(ab.trigger, Trigger::Every(n) if mob.attacks_made.is_multiple_of(n))
                            })
                        });
                        mob.yaw = yaw_of(flat_dir(mob.pos, tpos));
                        if let Some(ab) = every.and_then(|i| rules.mobs.ability(i)) {
                            let a = begin(
                                &mut mob,
                                ab,
                                target,
                                tpos,
                                tick,
                                species.attack_cooldown_ticks,
                            );
                            deeds.push(telegraph(net_id.0, ab, &a));
                        } else if brain.windup_ms > 0 || brain.recovery_ms > 0 {
                            let release = tick + ticks(brain.windup_ms);
                            mob.attack = Some(Attack {
                                ability: None,
                                target,
                                center: tpos,
                                dir: flat_dir(mob.pos, tpos),
                                release,
                                done: release + ticks(brain.recovery_ms),
                                released: false,
                            });
                            mob.attack_cd = f32::from(species.attack_cooldown_ticks);
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
                    let moved = match ring {
                        Some(spot) => walk.step(
                            &mut mob,
                            spot,
                            species.move_speed * RING_PACE * pace,
                            RING_HOLD,
                            tick,
                            push,
                        ),
                        None if in_reach => false,
                        None => {
                            let stop = if ranged {
                                0.3
                            } else {
                                species.attack_range * 0.8
                            };
                            walk.step(&mut mob, tpos, species.move_speed * pace, stop, tick, push)
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

    /// Which cells are awake (players near), and where the living players are.
    fn wake_cells(&mut self) {
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
            for cell in cells_around(pos, super::WAKE_CELLS) {
                self.awake[cell] = true;
            }
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
            {
                continue;
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
            }
        }
    }

    /// A creature fell: its corpse lingers, and the last of a pack starts
    /// the pack's respawn clock.
    pub(super) fn mob_died(&mut self, mob: Entity) {
        let tick = self.tick;
        let Some(mut m) = self.world.get_mut::<Mob>(mob) else {
            return;
        };
        m.hp = 0.0;
        m.mode = MobMode::Dead;
        m.state = STATE_DEAD;
        m.died_at = tick;
        m.status = super::status::Status::default();
        m.attack = None;
        let pack = m.pack;
        let roll = xorshift(&mut m.rng);
        self.stats.kills += 1;
        let state = &mut self.packs[pack];
        state.alive = state.alive.saturating_sub(1);
        if state.alive == 0 {
            let (lo, hi) = self.game.packs[pack].respawn_ticks;
            state.respawn_at = Some(tick + lo + roll % hi.saturating_sub(lo).max(1));
        }
    }

    /// Packs whose time has come stand up again on a fresh anchor; one with
    /// no free spot tries again shortly.
    fn respawn_packs(&mut self) {
        let tick = self.tick;
        if !tick.is_multiple_of(RESPAWN_CHECK_TICKS) {
            return;
        }
        for pack in 0..self.packs.len() {
            if self.packs[pack].respawn_at.is_none_or(|t| t > tick) {
                continue;
            }
            if !self.place_pack(pack, false) {
                let retry = ticks(self.game.rules.mobs.tuning.respawn_retry_ms.max(1000));
                let jitter = xorshift(&mut self.dice_state) % retry.max(1);
                self.packs[pack].respawn_at = Some(tick + retry + jitter);
            }
        }
    }

    /// A spot in the pack's area: on the ground, dry, not too steep, not
    /// protected, apart from other packs and (`initial` aside) from players.
    fn pack_spot(&mut self, pack: usize, initial: bool) -> Option<Vec3> {
        let p = &self.game.packs[pack];
        let (center, half, clear_radius) = (p.center, p.half_extent, p.clear_radius);
        let attempts = self.game.rules.mobs.tuning.placement_attempts.max(1);
        for _ in 0..attempts {
            let x = center.0 + (unit(&mut self.dice_state) * 2.0 - 1.0) * half.0.max(1.0);
            let z = center.1 + (unit(&mut self.dice_state) * 2.0 - 1.0) * half.1.max(1.0);
            let Some(h) = self.terrain.ground_height(x, z) else {
                continue;
            };
            let spot = Vec3::new(x, h, z);
            let flat = self
                .terrain
                .ray_down(spot + Vec3::new(0.0, 1.0, 0.0), 2.0)
                .is_some_and(|g| g.normal.y >= FLAT_ENOUGH);
            if !flat
                || self.terrain.water_surface_at(x, z).is_some_and(|w| w > h)
                || self.protected(spot)
                || self.packs.iter().enumerate().any(|(i, s)| {
                    i != pack
                        && !s.members.is_empty()
                        && planar_distance(s.anchor, spot) < ANCHOR_SPACING
                })
                || (!initial
                    && self
                        .player_pos
                        .values()
                        .any(|pp| planar_distance(*pp, spot) < clear_radius))
            {
                continue;
            }
            return Some(spot);
        }
        None
    }

    /// Stands a pack up on a fresh anchor: members on a ring around it,
    /// full health, elites rolled. Returns false when no spot was free.
    pub(super) fn place_pack(&mut self, pack: usize, initial: bool) -> bool {
        let anchor = match self.pack_spot(pack, initial) {
            Some(spot) => spot,
            None if initial => {
                let (x, z) = self.game.packs[pack].center;
                Vec3::new(x, self.ground(x, z), z)
            }
            None => return false,
        };
        let tick = self.tick;
        let rules = self.rules();
        let elite = rules.mobs.elite;
        let spacing = rules.mobs.tuning.pack_spacing;
        let p = &self.game.packs[pack];
        let (boss, count) = (p.boss, self.packs[pack].members.len().max(1));
        let max_hp = self.game.mob_max_hp(p);
        let attack = self.game.mob_attack(p);
        let ring = if count > 1 {
            spacing / (2.0 * libm::sinf(core::f32::consts::PI / count as f32))
        } else {
            0.0
        };
        let start = unit(&mut self.dice_state) * core::f32::consts::TAU;
        for i in 0..self.packs[pack].members.len() {
            let a = start + core::f32::consts::TAU * i as f32 / count as f32;
            let (x, z) = (
                anchor.x + libm::cosf(a) * ring,
                anchor.z + libm::sinf(a) * ring,
            );
            let home = Vec3::new(x, self.terrain.ground_height(x, z).unwrap_or(anchor.y), z);
            let is_elite = !boss && unit(&mut self.dice_state) < elite.chance;
            let (hp, power) = if is_elite {
                (max_hp * elite.hp_mult, attack * elite.attack_mult)
            } else {
                (max_hp, attack)
            };
            let member = self.packs[pack].members[i];
            if let Some(mut m) = self.world.get_mut::<Mob>(member) {
                m.home = home;
                m.pos = home;
                m.max_hp = hp;
                m.hp = hp;
                m.attack_power = power;
                m.elite = is_elite;
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
        let state = &mut self.packs[pack];
        state.anchor = anchor;
        state.alive = state.members.len() as u32;
        state.respawn_at = None;
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
                    m.attack_power * m.status.strength(tick),
                    usize::from(m.species),
                    self.game.packs[m.pack].level,
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
            if let Some((spell, speed, range)) = sp.bolt {
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
            let lunge = if sp.brain.windup_ms > 0 {
                MELEE_LUNGE * sp.attack_range
            } else {
                0.0
            };
            if planar_distance(pos, tpos) <= sp.attack_range + MELEE_SLACK + lunge
                && self
                    .terrain
                    .line_hit(eye, tpos + Vec3::new(0.0, CHEST, 0.0))
                    .is_none()
            {
                self.hit_player(attack.target, mob, power, "melee", level);
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
            let name = rules
                .combat
                .spell_order
                .get(usize::from(spell))
                .map_or("basic_cast", String::as_str);
            self.hit_player(player, owner, damage, name, level);
        }
    }
}

/// A melee creature cannot reach a target this far above it.
fn out_of_reach(mob: Vec3, target: Vec3, attack_range: f32) -> bool {
    let up = target.y - mob.y;
    up >= 12.0 || (up >= (attack_range + 1.5).max(4.0) && planar_distance(mob, target) < 9.0)
}

/// Starts a telegraphed ability: its shape is fixed now (a target that steps
/// out dodges it).
fn begin(
    mob: &mut Mob,
    ab: &AbilityDef,
    target: Entity,
    tpos: Vec3,
    tick: u32,
    cooldown: u16,
) -> Attack {
    let dir = flat_dir(mob.pos, tpos);
    mob.yaw = yaw_of(dir);
    let center = match ab.shape {
        Shape::Area {
            at_target: true, ..
        } => tpos,
        Shape::Area { offset, .. } => mob.pos + facing(mob.yaw) * offset,
        Shape::Cone { .. } => mob.pos,
    };
    let release = tick + ticks(ab.windup_ms);
    let a = Attack {
        ability: Some(ab.index),
        target,
        center,
        dir,
        release,
        done: release + ticks(ab.recovery_ms),
        released: false,
    };
    mob.attack = Some(a);
    mob.attack_cd = f32::from(cooldown);
    mob.state = STATE_ATTACKING;
    a
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
