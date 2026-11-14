//! Crowd control and damage over time on creatures: what a player's spell or
//! a control enchantment does to the body it hit, how long it lasts, and how
//! the creature's brain reads it (locked bodies neither move nor strike, a
//! slowed one walks slower, a weakened one hits softer, a thrown one flies
//! and lands). Burns and bleeds tick on their own clocks; only creatures with
//! one running are visited.
//!
//! The rules are the old game's `_apply_status_on_hit`, `_roll_cc_procs` and
//! `_advance_effects`.

use realm_proto::control::{CombatEvent, HIT_BURN, HIT_SLOW, HIT_STUN};
use realm_proto::{
    STATUS_BLEED, STATUS_BURN, STATUS_FREEZE, STATUS_KNOCKED, STATUS_SLOW, STATUS_STUN, STATUS_WEAK,
};
use realm_rules::SpellDef;
use realm_rules::combat::{Dot as DotSpec, LAUNCH_GRAVITY, airborne_ms};
use realm_sim::{SIM_DT, Vec3};

use super::{Entity, MobMode, Player, Sim, unit};

/// A running burn or bleed.
#[derive(Clone, Copy)]
pub(super) struct Dot {
    pub until: u32,
    pub next: u32,
    pub interval: u32,
    pub damage: f32,
    pub source: Entity,
}

/// Every lasting effect on one creature, as ticks.
#[derive(Clone, Copy, Default)]
pub(super) struct Status {
    pub stun_until: u32,
    pub freeze_until: u32,
    pub knock_until: u32,
    pub slow_from: u32,
    pub slow_until: u32,
    pub slow_factor: f32,
    pub weak_until: u32,
    pub weak_factor: f32,
    pub proc_stun_ready: u32,
    pub burn: Option<Dot>,
    pub bleed: Option<Dot>,
    /// A throw in flight: the body's velocity.
    pub launch: Option<Vec3>,
}

/// A throw still in the air this long after it should have landed found no
/// floor under it.
const LOST_FLIGHT_TICKS: u32 = 90;

fn ticks(ms: f32) -> u32 {
    (ms / 1000.0 * realm_sim::SIM_HZ as f32).ceil().max(0.0) as u32
}

impl Status {
    /// Stunned, frozen or still in the air: no steering, no strikes.
    pub fn locked(&self, tick: u32) -> bool {
        self.stun_until > tick
            || self.freeze_until > tick
            || self.knock_until > tick
            || self.launch.is_some()
    }

    /// Movement speed multiplier.
    pub fn speed(&self, tick: u32) -> f32 {
        if self.slow_from <= tick && tick < self.slow_until {
            self.slow_factor
        } else {
            1.0
        }
    }

    /// Outgoing damage multiplier.
    pub fn strength(&self, tick: u32) -> f32 {
        if tick < self.weak_until {
            self.weak_factor
        } else {
            1.0
        }
    }

    /// The STATUS_* bits for snapshots.
    pub fn bits(&self, tick: u32) -> u8 {
        let mut bits = 0;
        if self.stun_until > tick {
            bits |= STATUS_STUN;
        }
        if self.freeze_until > tick {
            bits |= STATUS_FREEZE;
        }
        if self.knock_until > tick || self.launch.is_some() {
            bits |= STATUS_KNOCKED;
        }
        if self.slow_from <= tick && tick < self.slow_until {
            bits |= STATUS_SLOW;
        }
        if self.bleed.is_some_and(|d| d.until > tick) {
            bits |= STATUS_BLEED;
        }
        if self.burn.is_some_and(|d| d.until > tick) {
            bits |= STATUS_BURN;
        }
        if self.weak_until > tick {
            bits |= STATUS_WEAK;
        }
        bits
    }

    /// Lasting effects that need a visit every tick.
    pub fn ticking(&self) -> bool {
        self.burn.is_some() || self.bleed.is_some() || self.launch.is_some()
    }
}

fn start_dot(
    slot: &mut Option<Dot>,
    spec: &DotSpec,
    damage: f32,
    source: Entity,
    tick: u32,
    keep_stronger: bool,
) {
    if keep_stronger && slot.is_some_and(|d| d.until > tick && d.damage > damage) {
        return;
    }
    let interval = ticks(spec.interval_ms as f32).max(1);
    *slot = Some(Dot {
        until: tick + spec.ticks * interval,
        next: tick + interval,
        interval,
        damage,
        source,
    });
}

impl Sim {
    /// What a player's hit leaves on a living creature: the spell's holds,
    /// slow, bleed, burn, throw and weakening, then the control enchantments'
    /// procs. Returns the HIT_* bits the procs add.
    pub(super) fn apply_status(
        &mut self,
        attacker: Entity,
        victim: Entity,
        spell: &SpellDef,
        amount: f32,
    ) -> u8 {
        let tick = self.tick;
        let rules = self.rules();
        let combat = &rules.combat;
        let Some((skill, attacker_pos, stats)) = self.world.get::<Player>(attacker).map(|p| {
            (
                combat.skill_level(&p.sheet, &spell.id),
                p.body.pos,
                (
                    p.caster.stat("stun_chance"),
                    p.caster.stat("slow_chance"),
                    p.caster.stat("burn_chance"),
                ),
            )
        }) else {
            return 0;
        };
        let Some(mob) = self.world.get::<super::Mob>(victim) else {
            return 0;
        };
        if mob.mode == MobMode::Dead {
            return 0;
        }
        let species = &self.game.species[usize::from(mob.species)].id;
        let boss = mob.boss;
        // A Dark Shard takes no holds; a dummy shows them but never moves.
        let pack_kind = &self.game.packs[mob.pack].kind;
        if matches!(pack_kind, crate::game::PackKind::Stone(_)) {
            return 0;
        }
        let object = self.game.species[usize::from(mob.species)].object;
        let effect = combat.skill_effect(skill);
        let hold = effect * combat.hold_scale(species);
        let displace = if object {
            0.0
        } else {
            combat.displace_scale(species, boss)
        };
        let banished = combat
            .creatures
            .get(species)
            .is_some_and(|c| spell.banishes.contains(&c.family));
        let mut state = self.dice_state;
        let mut flags = 0;
        let procs = &combat.procs;
        let away = {
            let d = Vec3::new(mob.pos.x - attacker_pos.x, 0.0, mob.pos.z - attacker_pos.z);
            if d.length_squared() > 1.0e-4 {
                d.normalize()
            } else {
                Vec3::ZERO
            }
        };
        let cooldown = self.game.species[usize::from(mob.species)].attack_cooldown_ticks;
        let Some(mut mob) = self.world.get_mut::<super::Mob>(victim) else {
            return 0;
        };
        let s = &mut mob.status;
        let mut interrupted = banished || spell.interrupts;
        let mut spell_hold = false;
        // Holds from the spell.
        let stun = if boss {
            spell.stun_ms_boss
        } else {
            spell.stun_ms
        };
        if stun > 0 && hold > 0.0 {
            s.stun_until = s.stun_until.max(tick + ticks(stun as f32 * hold));
            interrupted = true;
            spell_hold = true;
        }
        let freeze = if boss {
            spell.freeze_ms_boss
        } else {
            spell.freeze_ms
        };
        if freeze > 0 && hold > 0.0 {
            s.freeze_until = s.freeze_until.max(tick + ticks(freeze as f32 * hold));
            interrupted = true;
            spell_hold = true;
        }
        if let Some(slow) = spell.slow {
            let ms = if boss {
                slow.boss_ms as f32
            } else {
                slow.ms as f32
            } * effect;
            // The chill after a freeze runs from the thaw.
            let from = tick.max(s.freeze_until);
            let until = from + ticks(ms);
            if ms > 0.0 && until > s.slow_until {
                s.slow_from = from;
                s.slow_until = until;
                s.slow_factor = slow.factor.clamp(0.1, 1.0);
            }
        }
        if let Some(bleed) = spell.bleed {
            let damage = bleed.damage.max((amount * bleed.hit_share).round());
            start_dot(&mut s.bleed, &bleed, damage, attacker, tick, true);
        }
        if let Some(burn) = spell.burn {
            start_dot(&mut s.burn, &burn, burn.damage, attacker, tick, false);
        }
        if let Some(launch) = spell.launch
            && displace > 0.0
        {
            let lift = launch.lift * displace;
            s.launch = Some(away * launch.push * displace + Vec3::new(0.0, lift, 0.0));
            s.knock_until = tick + ticks(airborne_ms(lift, 350) as f32);
            let land = launch.land_stun_ms as f32 * hold;
            if land > 0.0 {
                s.stun_until = s.stun_until.max(s.knock_until + ticks(land));
            }
            interrupted = true;
            spell_hold = true;
        }
        if spell.weaken_ms > 0 {
            s.weak_until = tick + ticks(spell.weaken_ms as f32 * effect);
            s.weak_factor = spell.weaken_factor;
        }
        // Control enchantments, each rolled on its own. A stun proc never
        // chains: no new one until a grace window after the last.
        let (stun_chance, slow_chance, burn_chance) = stats;
        if stun_chance > 0.0
            && !boss
            && tick >= s.proc_stun_ready
            && unit(&mut state) * 100.0 < stun_chance
        {
            let ms = procs.stun_ms as f32 * combat.hold_scale(species).min(2.0);
            if ms > 0.0 {
                let until = tick + ticks(ms);
                s.stun_until = s.stun_until.max(until);
                s.proc_stun_ready = until + ticks(procs.stun_grace_ms as f32);
                flags |= HIT_STUN;
                interrupted = true;
            }
        }
        if slow_chance > 0.0 && unit(&mut state) * 100.0 < slow_chance {
            let ms = procs.slow_ms as f32 * if boss { 0.5 } else { 1.0 };
            s.slow_from = tick;
            s.slow_until = s.slow_until.max(tick + ticks(ms));
            s.slow_factor = procs.slow_factor;
            flags |= HIT_SLOW;
        }
        if burn_chance > 0.0 && unit(&mut state) * 100.0 < burn_chance {
            let damage = procs
                .burn
                .damage
                .max((amount * procs.burn.hit_share).round());
            let weaker = s.burn.is_some_and(|d| d.until > tick && damage < d.damage);
            if !weaker {
                start_dot(&mut s.burn, &procs.burn, damage, attacker, tick, false);
                flags |= HIT_BURN;
            }
        }
        // A hold or a throw breaks the attack it was winding up.
        if interrupted {
            mob.attack_cd = mob.attack_cd.max(f32::from(cooldown));
        }
        let ticking = mob.status.ticking();
        self.dice_state = state;
        self.stats.holds += u64::from(spell_hold);
        self.stats.procs += u64::from(flags.count_ones());
        if ticking && !self.ticking.contains(&victim) {
            self.ticking.push(victim);
        }
        flags
    }

    /// Burns and bleeds tick, thrown bodies fly; creatures with nothing left
    /// running leave the list.
    pub(super) fn advance_status(&mut self) {
        let tick = self.tick;
        let mut dots: Vec<(Entity, Entity, f32)> = Vec::new();
        let mut list = std::mem::take(&mut self.ticking);
        list.retain(|&entity| {
            let Some(mut mob) = self.world.get_mut::<super::Mob>(entity) else {
                return false;
            };
            if mob.mode == MobMode::Dead {
                mob.status = Status::default();
                return false;
            }
            let (pos, home) = (mob.pos, mob.home);
            let s = &mut mob.status;
            for slot in [&mut s.burn, &mut s.bleed] {
                if let Some(dot) = slot.as_mut() {
                    if tick > dot.until {
                        *slot = None;
                    } else if tick >= dot.next {
                        dot.next = tick + dot.interval;
                        dots.push((entity, dot.source, dot.damage));
                    }
                }
            }
            if let Some(v) = s.launch.as_mut() {
                let mut next = pos + *v * SIM_DT;
                // A wall stops the throw's drift; the body drops where it is.
                let chest = Vec3::new(0.0, 1.0, 0.0);
                if self.terrain.line_hit(pos + chest, next + chest).is_some() {
                    next.x = pos.x;
                    next.z = pos.z;
                    v.x = 0.0;
                    v.z = 0.0;
                }
                v.y -= LAUNCH_GRAVITY * SIM_DT;
                let falling = v.y < 0.0;
                let reach = 1.5 + v.y.abs() * SIM_DT + 0.5;
                let ground = self
                    .terrain
                    .ray_down(next + Vec3::new(0.0, 1.5, 0.0), reach);
                if falling && let Some(g) = ground.filter(|g| next.y <= g.point.y) {
                    next.y = g.point.y;
                    s.launch = None;
                } else if tick > s.knock_until + LOST_FLIGHT_TICKS {
                    // Thrown off every floor: back home rather than falling on.
                    next = home;
                    s.launch = None;
                }
                mob.pos = next;
            }
            mob.status.ticking()
        });
        list.append(&mut self.ticking);
        self.ticking = list;
        for (victim, source, damage) in dots {
            self.dot_mob(source, victim, damage);
        }
    }

    /// One burn or bleed tick: the creature's arcane resistance, no critical
    /// hit, no procs, protection still counts.
    fn dot_mob(&mut self, source: Entity, victim: Entity, raw: f32) {
        let rules = self.rules();
        let Some(mob) = self
            .world
            .get::<super::Mob>(victim)
            .filter(|m| m.mode != MobMode::Dead)
        else {
            return;
        };
        if self.protected(mob.pos) {
            return;
        }
        let species = &self.game.species[usize::from(mob.species)].id;
        let amount = (raw * rules.combat.resist_factor(species, "arcane"))
            .round()
            .max(0.0);
        if amount <= 0.0 {
            return;
        }
        self.stats.dot_ticks += 1;
        self.note_credit(victim, source);
        let Some(mut mob) = self.world.get_mut::<super::Mob>(victim) else {
            return;
        };
        mob.hp -= amount;
        let (at, hp) = (mob.pos, super::hp_byte(mob.hp.max(0.0), mob.max_hp));
        if mob.hp <= 0.0 {
            self.mob_died(victim, Some(source));
        }
        let (target_id, attacker_id) = (self.net_id_of(victim), self.net_id_of(source));
        self.event(
            at,
            CombatEvent::Hit {
                target: target_id,
                attacker: attacker_id,
                spell: u8::MAX,
                amount: amount as u32,
                flags: 0,
                hp,
            },
        );
    }
}
