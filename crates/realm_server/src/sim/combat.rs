//! Casting and hits: a cast request (an input frame's action) passes its
//! gates, spends mana and starts a windup; on its release tick the spell
//! leaves the wand as a bolt, a burst, a cone or a ward; a hit runs the old
//! game's damage path in order. Everything a client should see goes out as a
//! combat event to the clients near it.
//!
//! The numbers are `realm_rules::combat`; this module only applies them.

use realm_proto::control::{CombatEvent, HIT_CRIT, HIT_EVADE, HIT_FINISHER, HIT_PIERCE};
use std::sync::Arc;

use realm_rules::{BASIC_SPELL, CastPower, Delivery, Derived, Rules, SpellDef};
use realm_sim::Vec3;
use realm_sim::world::World as Terrain;

use super::{
    CELL, CHEST, ConnId, Entity, GRID_DIM, INTEREST_RADIUS, InputFrame, MobMode, Player, Sim,
    cell_of, planar_distance, unit,
};

/// A request this close to its caster's readiness waits instead of being
/// refused (old CAST_QUEUE_MS 250).
const QUEUE_TICKS: u32 = 8;
/// A target named by the client still counts this far from its aim point
/// (the client aims at the body it sees, a ping behind).
const AIM_HINT_SLACK: f32 = 4.5;
/// Without a named target, the body within this of the aim point.
const AIM_TARGET_RADIUS: f32 = 1.6;
/// A bolt brushing this close past a body still hits it.
const ASSIST_RADIUS: f32 = 0.55;
/// A bolt meets its homing target within this.
const MEET_RADIUS: f32 = 0.7;
/// Bolts leave the wand at this height above the feet.
const WAND_HEIGHT: f32 = 1.2;
/// Regeneration runs every this many ticks (200 ms).
const REGEN_TICKS: u32 = 6;

/// A player's combat state.
pub(super) struct Caster {
    pub mana: f32,
    pub max_mana: f32,
    /// What the gear adds up to (recomputed when the sheet changes).
    pub derived: Derived,
    pub cast: Option<ActiveCast>,
    /// Tick each spell (by index) is ready again.
    pub ready_at: [u32; 16],
    pub combo: u8,
    pub combo_until: u32,
    /// A request that arrived just before the caster was ready.
    pub queued: Option<(InputFrame, u32)>,
    pub ward_until: u32,
}

impl Caster {
    pub fn new(mana: f32, derived: Derived) -> Self {
        Self {
            mana: mana.min(derived.max_mana as f32),
            max_mana: derived.max_mana as f32,
            derived,
            cast: None,
            ready_at: [0; 16],
            combo: 0,
            combo_until: 0,
            queued: None,
            ward_until: 0,
        }
    }

    pub fn stat(&self, name: &str) -> f32 {
        self.derived.stats.get(name).copied().unwrap_or(0.0)
    }
}

pub(super) struct ActiveCast {
    pub spell: u8,
    pub release_tick: u32,
    pub end_tick: u32,
    pub aim: Vec3,
    pub target: Option<Entity>,
    pub damage: f32,
    pub finisher: bool,
    pub released: bool,
}

pub(super) struct Bolt {
    pub owner: Entity,
    pub spell: u8,
    pub pos: Vec3,
    pub dir: Vec3,
    pub speed: f32,
    pub left: f32,
    pub target: Option<Entity>,
    pub damage: f32,
    pub finisher: bool,
}

fn arr(v: Vec3) -> [f32; 3] {
    [v.x, v.y, v.z]
}

impl Sim {
    /// The rules, held apart from `self` so a spell can be read while the
    /// world changes.
    pub(super) fn rules(&self) -> Arc<Rules> {
        Arc::clone(&self.game.rules)
    }

    pub(super) fn net_id_of(&self, entity: Entity) -> u32 {
        self.world.get::<super::NetId>(entity).map_or(0, |n| n.0)
    }

    pub(super) fn event(&mut self, at: Vec3, event: CombatEvent) {
        self.events.push((at, event));
    }

    fn refuse(&mut self, caster: Entity, spell: u8, reason: &str) {
        self.stats.refused[0] += 1;
        self.private_events.push((
            caster,
            CombatEvent::CastRefused {
                spell,
                reason: reason.to_owned(),
            },
        ));
    }

    pub(super) fn protected(&self, at: Vec3) -> bool {
        self.game.rules.protected(&self.game.map, at.x, at.y, at.z)
    }

    /// A cast request from an input frame (its action is the spell index + 1).
    pub(super) fn request_cast(&mut self, caster: Entity, frame: InputFrame) {
        let tick = self.tick;
        let index = frame.action.saturating_sub(1);
        let rules = self.rules();
        let Some(spell) = rules.combat.spell_by_index(index) else {
            self.refuse(caster, index, "unknown_spell");
            return;
        };
        let Some(player) = self.world.get::<Player>(caster) else {
            return;
        };
        if player.dead_until != 0 {
            return;
        }
        // A held body casts nothing (judged on the input's own tick, as the
        // owner's prediction does).
        let refusal = if player.restraint.locked(frame.tick) {
            Some("held")
        } else if player.sheet.level < spell.requires_level {
            Some("level")
        } else if rules.combat.skill_level(&player.sheet, &spell.id) == 0 {
            Some("skill_locked")
        } else if spell.delivery != Delivery::SelfCast
            && player.sheet.equipped(realm_rules::Slot::MainHand).is_none()
        {
            Some("no_wand")
        } else if player.body.mounted && spell.delivery != Delivery::SelfCast {
            Some("mounted")
        } else {
            None
        };
        if let Some(reason) = refusal {
            self.refuse(caster, index, reason);
            return;
        }
        let c = &player.caster;
        let busy_until = c.cast.as_ref().map_or(0, |a| a.end_tick);
        let ready = busy_until.max(c.ready_at[usize::from(index)]);
        if ready > tick {
            let queue = ready - tick <= QUEUE_TICKS && c.queued.is_none();
            if queue && let Some(mut player) = self.world.get_mut::<Player>(caster) {
                player.caster.queued = Some((frame, tick + QUEUE_TICKS));
                return;
            }
            self.refuse(caster, index, "cooldown");
            return;
        }
        if c.mana < spell.mana_cost as f32 {
            self.refuse(caster, index, "no_mana");
            return;
        }
        self.begin_cast(caster, spell, frame);
    }

    fn begin_cast(&mut self, caster: Entity, spell: &SpellDef, frame: InputFrame) {
        let tick = self.tick;
        let aim = frame.aim_point();
        let target = self.pick_target(caster, frame.target, aim);
        let mut roll_state = self.dice_state;
        let rules = self.rules();
        let Some(mut player) = self.world.get_mut::<Player>(caster) else {
            return;
        };
        let skill = rules.combat.skill_level(&player.sheet, &spell.id);
        let derived = player.caster.derived.clone();
        // The basic attack chains on hits: a flick at nothing starts over.
        let (mut combo, mut finisher) = (1.0, false);
        if spell.id == BASIC_SPELL {
            let steps = spell.combo_multipliers.len().max(1) as u8;
            if target.is_some() {
                if tick > player.caster.combo_until {
                    player.caster.combo = 0;
                }
                let step = player.caster.combo % steps;
                player.caster.combo = (step + 1) % steps;
                player.caster.combo_until =
                    tick + (spell.combo_window * realm_sim::SIM_HZ as f32).ceil() as u32;
                combo = spell.combo_multipliers[usize::from(step)];
                finisher = step > 0 && step == steps - 1;
            } else {
                player.caster.combo = 0;
            }
        }
        let range = if spell.id == BASIC_SPELL {
            derived.attack_value
        } else {
            derived.magic_attack
        };
        let roll = if range.1 > range.0 {
            range.0
                + ((range.1 - range.0 + 1.0) * unit(&mut roll_state))
                    .floor()
                    .min(range.1 - range.0)
        } else {
            range.0
        };
        let wand_multiplier = rules
            .item_rules
            .steps
            .get(usize::from(derived.wand_tier))
            .map_or(1.0, |s| s.multiplier);
        let damage = rules.combat.cast_damage(
            spell,
            &CastPower {
                house: player.sheet.house.clone(),
                skill,
                wand_multiplier,
                weapon_roll: roll,
                combo,
                weapon_multiplier: derived.weapon_multiplier,
            },
        );
        let lock = spell.cast_lock * realm_sim::SIM_HZ as f32;
        let windup = ((lock * 0.5).round() as u32).max(1);
        let recovery = ((lock.ceil() as u32).saturating_sub(windup)).max(1);
        let cooldown = rules.combat.cooldown(
            spell,
            &player.sheet.house,
            skill,
            player.caster.stat("attack_speed"),
            player.caster.stat("cast_speed"),
        );
        player.caster.mana -= spell.mana_cost as f32;
        player.caster.ready_at[usize::from(spell.index)] =
            tick + (cooldown * realm_sim::SIM_HZ as f32).ceil() as u32;
        player.caster.cast = Some(ActiveCast {
            spell: spell.index,
            release_tick: tick + windup,
            end_tick: tick + windup + recovery,
            aim,
            target,
            damage,
            finisher,
            released: false,
        });
        let at = player.body.pos;
        self.dice_state = roll_state;
        self.stats.casts += 1;
        let caster_id = self.net_id_of(caster);
        let target_id = target.map_or(0, |t| self.net_id_of(t));
        let shown_aim = target.and_then(|t| self.chest_of(t)).unwrap_or(aim);
        self.event(
            at,
            CombatEvent::CastStarted {
                caster: caster_id,
                spell: spell.index,
                target: target_id,
                aim: arr(shown_aim),
                release_tick: tick + windup,
            },
        );
    }

    /// Where a living creature's or player's chest is.
    fn chest_of(&self, entity: Entity) -> Option<Vec3> {
        if let Some(m) = self.world.get::<super::Mob>(entity) {
            return (m.mode != MobMode::Dead).then(|| m.pos + Vec3::new(0.0, CHEST, 0.0));
        }
        self.world
            .get::<Player>(entity)
            .filter(|p| p.dead_until == 0)
            .map(|p| p.body.pos + Vec3::new(0.0, CHEST, 0.0))
    }

    /// The creature the cast is aimed at: the one the client named when it is
    /// alive and near the aim point, else the one at the aim point, else none.
    fn pick_target(&self, caster: Entity, hint: u32, aim: Vec3) -> Option<Entity> {
        let origin = self.world.get::<Player>(caster)?.body.pos;
        if hint != 0
            && let Some(&entity) = self.ids.get(&hint)
        {
            if let Some(mob) = self.world.get::<super::Mob>(entity)
                && mob.mode != MobMode::Dead
                && planar_distance(mob.pos, aim) <= AIM_HINT_SLACK
                && !self.protected(mob.pos)
                && !self.protected(origin)
            {
                return Some(entity);
            }
            // A duel foe: protection does not hold in a duel.
            if self.foes(caster, entity)
                && let Some(p) = self.world.get::<Player>(entity)
                && planar_distance(p.body.pos, aim) <= AIM_HINT_SLACK
            {
                return Some(entity);
            }
        }
        let mut best: Option<(f32, Entity)> = None;
        self.targets_near(caster, aim, AIM_TARGET_RADIUS + 2.0, |entity, pos| {
            let d = planar_distance(pos, aim);
            if d <= AIM_TARGET_RADIUS
                && aim.y >= pos.y - 0.6
                && aim.y <= pos.y + 3.0
                && best.is_none_or(|(b, _)| d < b)
            {
                best = Some((d, entity));
            }
        });
        best.map(|(_, e)| e).filter(|e| {
            self.world
                .get::<super::Mob>(*e)
                .is_none_or(|m| !self.protected(m.pos))
        })
    }

    /// Calls `f` for every living creature within `radius` of `at` (the
    /// replication grid of the previous tick finds them).
    /// What `attacker`'s spells may hit near `at`: living creatures, and its
    /// duel foes still standing. The callback gets the body's feet.
    fn targets_near(
        &self,
        attacker: Entity,
        at: Vec3,
        radius: f32,
        mut f: impl FnMut(Entity, Vec3),
    ) {
        let reach = (radius / CELL).ceil() as i32;
        let Some(center) = cell_of(at) else { return };
        let (cx, cz) = ((center % GRID_DIM) as i32, (center / GRID_DIM) as i32);
        let near = (radius + 1.0) * (radius + 1.0);
        for dz in -reach..=reach {
            for dx in -reach..=reach {
                let (x, z) = (cx + dx, cz + dz);
                if x < 0 || z < 0 || x >= GRID_DIM as i32 || z >= GRID_DIM as i32 {
                    continue;
                }
                for &row in &self.cells[z as usize * GRID_DIM + x as usize] {
                    let row = &self.rows[row as usize];
                    let pos = if row.is_player {
                        if !self.foes(attacker, row.entity) {
                            continue;
                        }
                        match self.world.get::<Player>(row.entity) {
                            Some(p) => p.body.pos,
                            None => continue,
                        }
                    } else {
                        match self.world.get::<super::Mob>(row.entity) {
                            Some(m) if m.mode != MobMode::Dead => m.pos,
                            _ => continue,
                        }
                    };
                    if (pos - at).length_squared() <= near {
                        f(row.entity, pos);
                    }
                }
            }
        }
    }

    /// Releases casts whose windup ended, ends finished ones, fires queued
    /// requests whose caster is ready.
    pub(super) fn advance_casts(&mut self) {
        let tick = self.tick;
        let mut releases: Vec<(Entity, u8, Vec3, Option<Entity>, f32, bool)> = Vec::new();
        let mut queued: Vec<(Entity, InputFrame)> = Vec::new();
        let mut query = self.world.query::<(Entity, &mut Player)>();
        for (entity, mut player) in query.iter_mut(&mut self.world) {
            let c = &mut player.caster;
            if let Some(cast) = c.cast.as_mut() {
                if !cast.released && tick >= cast.release_tick {
                    cast.released = true;
                    releases.push((
                        entity,
                        cast.spell,
                        cast.aim,
                        cast.target,
                        cast.damage,
                        cast.finisher,
                    ));
                }
                if tick >= cast.end_tick {
                    c.cast = None;
                }
            }
            if let Some((frame, until)) = c.queued {
                if tick > until {
                    c.queued = None;
                } else if c.cast.is_none()
                    && c.ready_at[usize::from(frame.action.saturating_sub(1))] <= tick
                {
                    c.queued = None;
                    queued.push((entity, frame));
                }
            }
        }
        for (caster, spell, aim, target, damage, finisher) in releases {
            self.release(caster, spell, aim, target, damage, finisher);
        }
        for (caster, frame) in queued {
            self.request_cast(caster, frame);
        }
    }

    fn release(
        &mut self,
        caster: Entity,
        index: u8,
        aim: Vec3,
        target: Option<Entity>,
        damage: f32,
        finisher: bool,
    ) {
        let rules = self.rules();
        let Some(spell) = rules.combat.spell_by_index(index) else {
            return;
        };
        let Some(pos) = self
            .world
            .get::<Player>(caster)
            .filter(|p| p.dead_until == 0)
            .map(|p| p.body.pos)
        else {
            return;
        };
        let origin = pos + Vec3::new(0.0, WAND_HEIGHT, 0.0);
        // Re-aim from where the caster stands now (it moved during the windup).
        let aim_at = target.and_then(|t| self.chest_of(t)).unwrap_or(aim);
        let mut dir = (aim_at - origin).normalize_or_zero();
        if dir == Vec3::ZERO {
            dir = Vec3::new(0.0, 0.0, -1.0);
        }
        if spell.delivery == Delivery::Cone && dir.y < 0.0 {
            dir = Vec3::new(dir.x, 0.0, dir.z).normalize_or_zero();
        }
        let caster_id = self.net_id_of(caster);
        self.event(
            pos,
            CombatEvent::CastReleased {
                caster: caster_id,
                spell: index,
                from: arr(origin),
                dir: arr(dir),
            },
        );
        match spell.delivery {
            Delivery::SelfCast => {
                let tick = self.tick;
                let skill = self.world.get::<Player>(caster).map_or(1, |p| {
                    self.game.rules.combat.skill_level(&p.sheet, &spell.id)
                });
                let ms = spell.duration_ms as f32 * self.game.rules.combat.skill_effect(skill);
                if let Some(mut player) = self.world.get_mut::<Player>(caster) {
                    player.caster.ward_until =
                        tick + (ms / 1000.0 * realm_sim::SIM_HZ as f32).ceil() as u32;
                }
            }
            Delivery::Cone => {
                let half = (spell.cone_angle * 0.5).to_radians().cos();
                let mut victims = Vec::new();
                self.targets_near(caster, origin, spell.range, |entity, pos| {
                    let offset = pos + Vec3::new(0.0, 1.0, 0.0) - origin;
                    let d = offset.length();
                    if d <= spell.range && (d < 0.01 || dir.dot(offset / d) >= half) {
                        victims.push(entity);
                    }
                });
                for victim in victims {
                    if self.line_clear(origin, victim) {
                        self.hit(
                            caster,
                            victim,
                            damage,
                            spell,
                            if finisher { HIT_FINISHER } else { 0 },
                        );
                    }
                }
            }
            Delivery::Projectile | Delivery::ProjectileAoe => {
                self.bolts.push(Bolt {
                    owner: caster,
                    spell: index,
                    pos: origin,
                    dir,
                    speed: spell.projectile_speed,
                    left: spell.range * 1.5,
                    target,
                    damage,
                    finisher,
                });
            }
        }
    }

    fn line_clear(&self, from: Vec3, target: Entity) -> bool {
        self.chest_of(target)
            .is_some_and(|chest| self.terrain.line_hit(from, chest).is_none())
    }

    /// Bolts fly: homing onto their target's chest, else straight; a wall or
    /// the ground stops them (an area bolt bursts there), a body on the way is
    /// hit, the end of the range bursts an area bolt.
    pub(super) fn advance_bolts(&mut self) {
        let mut bolts = std::mem::take(&mut self.bolts);
        let mut keep = Vec::with_capacity(bolts.len());
        for mut bolt in bolts.drain(..) {
            let rules = self.rules();
            let Some(spell) = rules.combat.spell_by_index(bolt.spell) else {
                continue;
            };
            let aoe = spell.delivery == Delivery::ProjectileAoe;
            let homing_to = bolt.target.and_then(|t| self.chest_of(t));
            if let Some(chest) = homing_to {
                let to = chest - bolt.pos;
                if to.length_squared() > 1.0e-4 {
                    bolt.dir = to.normalize();
                }
            }
            let step = (bolt.speed * realm_sim::SIM_DT).min(bolt.left);
            let to = bolt.pos + bolt.dir * step;
            bolt.left -= step;
            // The homing target is met.
            if let (Some(target), Some(chest)) = (bolt.target, homing_to)
                && (chest - bolt.pos).length() <= step + MEET_RADIUS
            {
                self.impact(&bolt, spell, Some(target), chest, aoe);
                continue;
            }
            let wall = blocked(&self.terrain, bolt.pos, to, homing_to.is_some());
            let end = wall.map_or(to, |f| bolt.pos + (to - bolt.pos) * f);
            if let Some((victim, at)) = self.brushed(bolt.owner, bolt.pos, end) {
                self.impact(&bolt, spell, Some(victim), at, aoe);
                continue;
            }
            if wall.is_some() || bolt.left <= 0.0 {
                self.impact(&bolt, spell, None, end, aoe);
                continue;
            }
            bolt.pos = to;
            keep.push(bolt);
        }
        // Bolts released while these flew (none today) join the rest.
        keep.append(&mut self.bolts);
        self.bolts = keep;
    }

    /// The first creature whose upright body the segment passes within
    /// ASSIST_RADIUS of, and where.
    fn brushed(&self, owner: Entity, from: Vec3, to: Vec3) -> Option<(Entity, Vec3)> {
        let seg = to - from;
        let flat = Vec3::new(seg.x, 0.0, seg.z);
        let flat_len_sq = flat.length_squared();
        if flat_len_sq < 1.0e-6 {
            return None;
        }
        let middle = from + seg * 0.5;
        let reach = seg.length() * 0.5 + ASSIST_RADIUS + 1.5;
        let mut best: Option<(f32, Entity, Vec3)> = None;
        self.targets_near(owner, middle, reach, |entity, pos| {
            let rel = Vec3::new(pos.x - from.x, 0.0, pos.z - from.z);
            let t = (rel.dot(flat) / flat_len_sq).clamp(0.0, 1.0);
            let point = from + seg * t;
            if planar_distance(point, pos) <= ASSIST_RADIUS
                && point.y >= pos.y - 0.4
                && point.y <= pos.y + 2.6
                && best.is_none_or(|(b, _, _)| t < b)
            {
                best = Some((t, entity, point));
            }
        });
        best.map(|(_, e, p)| (e, p))
    }

    fn impact(
        &mut self,
        bolt: &Bolt,
        spell: &SpellDef,
        victim: Option<Entity>,
        at: Vec3,
        aoe: bool,
    ) {
        let flags = if bolt.finisher { HIT_FINISHER } else { 0 };
        let mut landed = false;
        if aoe {
            let caster_id = self.net_id_of(bolt.owner);
            self.event(
                at,
                CombatEvent::Burst {
                    caster: caster_id,
                    spell: bolt.spell,
                    at: arr(at),
                },
            );
            let mut victims = Vec::new();
            self.targets_near(bolt.owner, at, spell.radius, |entity, pos| {
                let d = (pos + Vec3::new(0.0, 1.0, 0.0) - at).length();
                if d <= spell.radius {
                    victims.push((entity, d));
                }
            });
            let from = at + Vec3::new(0.0, 0.3, 0.0);
            for (entity, d) in victims {
                if !self.line_clear(from, entity) {
                    continue;
                }
                let share =
                    realm_rules::combat::CombatRules::falloff(d, spell.radius, spell.falloff_floor);
                landed |= self.hit(
                    bolt.owner,
                    entity,
                    (bolt.damage * share).trunc(),
                    spell,
                    flags,
                ) > 0;
            }
        } else if let Some(victim) = victim {
            landed = self.hit(bolt.owner, victim, bolt.damage, spell, flags) > 0;
        }
        // A basic attack that hits nothing breaks the chain.
        if spell.id == BASIC_SPELL
            && !landed
            && let Some(mut player) = self.world.get_mut::<Player>(bolt.owner)
        {
            player.caster.combo = 0;
        }
    }

    /// A player's spell lands on `victim`: a creature, or a duel foe.
    fn hit(
        &mut self,
        attacker: Entity,
        victim: Entity,
        raw: f32,
        spell: &SpellDef,
        flags: u8,
    ) -> u32 {
        if self.world.get::<super::Mob>(victim).is_some() {
            self.hit_mob(attacker, victim, raw, spell, flags)
        } else if self.foes(attacker, victim) {
            self.hit_duelist(attacker, victim, raw, spell, flags)
        } else {
            0
        }
    }

    /// A player's hit on a creature, in the old order: protection, element
    /// resistance, piercing, the "strong against" bonus, the critical roll;
    /// then the creature's health, its death or its anger, life and mana
    /// steal. Returns the damage dealt.
    pub(super) fn hit_mob(
        &mut self,
        attacker: Entity,
        victim: Entity,
        raw: f32,
        spell: &SpellDef,
        mut flags: u8,
    ) -> u32 {
        let tick = self.tick;
        if raw <= 0.0 {
            return 0;
        }
        let Some(attacker_pos) = self.world.get::<Player>(attacker).map(|p| p.body.pos) else {
            return 0;
        };
        let Some(mob) = self
            .world
            .get::<super::Mob>(victim)
            .filter(|m| m.mode != MobMode::Dead)
        else {
            return 0;
        };
        // Dummies stand in the training yard, inside the protection.
        let dummy = self.game.packs[mob.pack].kind == crate::game::PackKind::Dummy;
        if !dummy && (self.protected(mob.pos) || self.protected(attacker_pos)) {
            return 0;
        }
        // Walking home, a creature shrugs off a blow from outside its home
        // ground.
        if self.evades(victim, attacker_pos) {
            let at = mob.pos;
            let hp = super::hp_byte(mob.hp, mob.max_hp);
            let (target, attacker_id) = (self.net_id_of(victim), self.net_id_of(attacker));
            self.event(
                at,
                CombatEvent::Hit {
                    target,
                    attacker: attacker_id,
                    spell: spell.index,
                    amount: 0,
                    flags: flags | HIT_EVADE,
                    hp,
                },
            );
            return 0;
        }
        let (mob_pos, mob_yaw) = (mob.pos, mob.yaw);
        let rules = self.rules();
        let combat = &rules.combat;
        let mob_species = mob.species;
        let species = &self.game.species[usize::from(mob.species)].id;
        let Some(caster) = self.world.get::<Player>(attacker).map(|p| {
            (
                p.caster.stat("pierce_chance"),
                p.caster.stat("crit_chance"),
                p.caster.stat("monster_damage"),
                p.caster.stat("life_steal"),
                p.caster.stat("mana_steal"),
            )
        }) else {
            return 0;
        };
        let (pierce_chance, crit_bonus, monster_damage, life_steal, mana_steal) = caster;
        let raw = raw
            * self
                .world
                .get::<Player>(attacker)
                .map_or(1.0, |p| p.afflictions.strength(tick));
        let mut state = self.dice_state;
        let mut amount = (raw * combat.resist_factor(species, &spell.element)).round();
        if pierce_chance > 0.0 && unit(&mut state) * 100.0 < pierce_chance {
            amount = amount.max(raw);
            flags |= HIT_PIERCE;
        }
        let family_bonus = combat
            .creatures
            .get(species)
            .and_then(|c| combat.family_stats.get(&c.family))
            .and_then(|stat| {
                self.world
                    .get::<Player>(attacker)
                    .map(|p| p.caster.stat(stat))
            })
            .unwrap_or(0.0);
        let bonus = monster_damage + family_bonus;
        if bonus > 0.0 {
            amount = (amount * (1.0 + bonus / 100.0)).round();
        }
        // A shield-bearer ignores part of a blow from in front of it.
        let guard = self.game.species[usize::from(mob_species)]
            .brain
            .front_guard;
        if guard > 0.0 && flags & HIT_PIERCE == 0 {
            let a = f32::from(mob_yaw) * (core::f32::consts::TAU / 65_536.0);
            let ahead = Vec3::new(-libm::sinf(a), 0.0, -libm::cosf(a));
            let to_attacker =
                Vec3::new(attacker_pos.x - mob_pos.x, 0.0, attacker_pos.z - mob_pos.z)
                    .normalize_or_zero();
            if ahead.dot(to_attacker) >= 0.5 {
                amount = (amount * (1.0 - guard)).round();
            }
        }
        let chance = combat.crit_chance(crit_bonus, flags & HIT_FINISHER != 0);
        if amount > 0.0 && chance > 0.0 && unit(&mut state) * 100.0 < chance {
            amount = (amount * combat.crit_multiplier).round();
            flags |= HIT_CRIT;
        }
        let life_cap = combat.life_steal_cap;
        let mana_roll = unit(&mut state) * 100.0;
        self.dice_state = state;
        let amount = amount.max(0.0);
        if amount <= 0.0 {
            return 0;
        }
        self.note_credit(victim, attacker);
        if dummy {
            self.quest_event(attacker, "dummy", "", false);
        }
        let Some(mut mob) = self.world.get_mut::<super::Mob>(victim) else {
            return 0;
        };
        mob.hp -= amount;
        let at = mob.pos;
        let hp_byte = super::hp_byte(mob.hp, mob.max_hp);
        let object = self.game.species[usize::from(mob.species)].object;
        if mob.hp <= 0.0 {
            self.mob_died(victim, Some(attacker));
        } else if object {
            flags |= self.apply_status(attacker, victim, spell, amount);
            self.stone_waves(victim, attacker);
        } else {
            self.provoke(victim, attacker);
            flags |= self.apply_status(attacker, victim, spell, amount);
        }
        self.stats.hits += 1;
        if let Some(mut player) = self.world.get_mut::<Player>(attacker) {
            player.last_combat = tick;
            let heal = (amount * life_steal.min(life_cap) / 100.0).round();
            if heal > 0.0 {
                player.hp = (player.hp + heal).min(player.max_hp);
            }
            if mana_steal > 0.0 && mana_roll < mana_steal {
                let c = &mut player.caster;
                c.mana = (c.mana + (amount * 0.1).round().max(1.0)).min(c.max_mana);
            }
        }
        let (target_id, attacker_id) = (self.net_id_of(victim), self.net_id_of(attacker));
        self.event(
            at,
            CombatEvent::Hit {
                target: target_id,
                attacker: attacker_id,
                spell: spell.index,
                amount: amount as u32,
                flags,
                hp: hp_byte,
            },
        );
        amount as u32
    }

    /// A creature's hit on a player: block or dodge, armour against the
    /// creature's level, the matching resistance, defence, the ward; mana
    /// first for the soul-drinkers; reflection back. Returns the damage.
    pub(super) fn hit_player(
        &mut self,
        victim: Entity,
        attacker: Entity,
        raw: f32,
        attack: &str,
        level: u32,
    ) -> u32 {
        let tick = self.tick;
        let rules = self.rules();
        let combat = &rules.combat;
        let kind = combat.attack_kind(attack);
        let Some(player) = self
            .world
            .get::<Player>(victim)
            .filter(|p| p.dead_until == 0)
        else {
            return 0;
        };
        if self.protected(player.body.pos) {
            return 0;
        }
        let c = &player.caster;
        let mut state = self.dice_state;
        let avoid = match kind {
            "melee" => c.stat("block_chance").min(combat.block_cap),
            "projectile" => c.stat("projectile_dodge").min(combat.dodge_cap),
            _ => 0.0,
        };
        if avoid > 0.0 && unit(&mut state) * 100.0 < avoid {
            self.dice_state = state;
            return 0;
        }
        self.dice_state = state;
        let mut amount = (raw * (1.0 - combat.armor_reduction(c.derived.armor, level))).round();
        let resist = c
            .stat(&format!("{kind}_resist"))
            .clamp(0.0, combat.resist_cap);
        amount = (amount * (1.0 - resist / 100.0)).round();
        let creature_resist = c.stat("creature_resist");
        if creature_resist > 0.0 {
            amount = (amount * (1.0 - creature_resist.clamp(0.0, 50.0) / 100.0)).round();
        }
        if c.ward_until > tick {
            let ward = combat
                .spells
                .values()
                .find(|s| s.delivery == Delivery::SelfCast)
                .map_or(1.0, |s| s.other_damage_multiplier);
            amount = (amount * ward).trunc();
        }
        amount = (amount * (1.0 - c.stat("defense").clamp(0.0, 50.0) / 100.0))
            .trunc()
            .max(0.0);
        let reflect_share = c.stat("reflect").min(combat.reflect_cap) / 100.0;
        let mana_first = self
            .world
            .get::<super::Mob>(attacker)
            .and_then(|m| {
                combat
                    .creatures
                    .get(&self.game.species[usize::from(m.species)].id)
            })
            .is_some_and(|c| c.mana_first);
        // A creature's bolt names its spell; a swing or an ability none.
        let spell = combat.spell(attack).map_or(u8::MAX, |s| s.index);
        self.wound_player(victim, attacker, amount, reflect_share, mana_first, spell)
    }

    /// Damage that got through: mana first for the soul-drinkers, then
    /// health, death, reflection back at a creature, the hit event.
    pub(super) fn wound_player(
        &mut self,
        victim: Entity,
        attacker: Entity,
        amount: f32,
        reflect_share: f32,
        mana_first: bool,
        spell: u8,
    ) -> u32 {
        let tick = self.tick;
        let Some(mut player) = self
            .world
            .get_mut::<Player>(victim)
            .filter(|p| p.dead_until == 0)
        else {
            return 0;
        };
        let mut to_hp = amount;
        if mana_first && amount > 0.0 {
            let drained = amount.min(player.caster.mana);
            player.caster.mana -= drained;
            to_hp -= drained;
        }
        player.hp -= to_hp;
        player.last_combat = tick;
        let at = player.body.pos;
        let died = player.hp <= 0.0;
        if died {
            player.hp = 0.0;
            // A placeholder until player_died sets the real times below.
            player.dead_until = tick + 1;
            player.caster.cast = None;
            player.caster.queued = None;
            player.afflictions = super::afflict::Afflictions::default();
            player.restraint = Default::default();
            player.life = player.life.wrapping_add(1);
            self.stats.player_deaths += 1;
        }
        let hp_byte = super::hp_byte(player.hp, player.max_hp);
        if amount > 0.0 && reflect_share > 0.0 {
            let reflected = (amount * reflect_share).round();
            if let Some(mut mob) = self.world.get_mut::<super::Mob>(attacker)
                && mob.mode != MobMode::Dead
            {
                mob.hp = (mob.hp - reflected).max(1.0);
            }
        }
        let (target_id, attacker_id) = (self.net_id_of(victim), self.net_id_of(attacker));
        self.event(
            at,
            CombatEvent::Hit {
                target: target_id,
                attacker: attacker_id,
                spell,
                amount: amount as u32,
                flags: 0,
                hp: hp_byte,
            },
        );
        if died {
            self.player_died(victim, attacker);
        }
        amount as u32
    }

    /// Health and mana come back five times a second (base rates for the
    /// house plus the gear's regeneration).
    pub(super) fn regenerate(&mut self) {
        if !self.tick.is_multiple_of(REGEN_TICKS) {
            return;
        }
        let tick = self.tick;
        let dt = REGEN_TICKS as f32 / realm_sim::SIM_HZ as f32;
        let combat = &self.game.rules.combat;
        let mut query = self.world.query::<&mut Player>();
        for mut player in query.iter_mut(&mut self.world) {
            // Despair stops natural regeneration.
            if player.dead_until != 0 || player.afflictions.despair_until > tick {
                continue;
            }
            let (hp_rate, mana_rate) = combat.regen(&player.sheet.house);
            let hp = hp_rate + player.caster.stat("hp_regen");
            let mana = mana_rate + player.caster.stat("mana_regen");
            player.hp = (player.hp + hp * dt).min(player.max_hp);
            let c = &mut player.caster;
            c.mana = (c.mana + mana * dt).min(c.max_mana);
        }
        self.chill();
    }

    /// Hands this tick's combat events to the clients near them (and refusals
    /// to their caster); they leave with the client's next snapshot.
    pub(super) fn dispatch_events(&mut self) {
        let events = std::mem::take(&mut self.events);
        let private = std::mem::take(&mut self.private_events);
        if events.is_empty() && private.is_empty() {
            return;
        }
        let mut owners: Vec<(ConnId, Entity, Vec3)> = Vec::with_capacity(self.clients.len());
        for (&conn, client) in &self.clients {
            if let Some(p) = self.world.get::<Player>(client.entity) {
                owners.push((conn, client.entity, p.body.pos));
            }
        }
        let r2 = INTEREST_RADIUS * INTEREST_RADIUS;
        for (conn, entity, pos) in owners {
            let Some(client) = self.clients.get_mut(&conn) else {
                continue;
            };
            for (at, event) in &events {
                let d = Vec3::new(at.x - pos.x, 0.0, at.z - pos.z).length_squared();
                if d <= r2 {
                    client.events.push(event.clone());
                }
            }
            for (owner, event) in &private {
                if *owner == entity {
                    client.events.push(event.clone());
                }
            }
        }
    }
}

/// Where the segment is blocked, as a fraction: a homing bolt skims over the
/// ground (a hump between caster and target) and stops only at colliders.
fn blocked(terrain: &Terrain, from: Vec3, to: Vec3, homing: bool) -> Option<f32> {
    if homing {
        let bead = realm_sim::world::bead();
        terrain
            .sweep(&bead, from, to - from)
            .map(|hit| hit.fraction)
    } else {
        terrain.line_hit(from, to)
    }
}
