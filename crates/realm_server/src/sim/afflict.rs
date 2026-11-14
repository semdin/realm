//! What creatures leave on players: a stun or a throw locks the body (no
//! steering, no jump, no casts), a web slows it, venom ticks, despair stops
//! natural regeneration, a pallid's cold seeps into those near it. Holds on
//! the body go into the player's `Restraint`, which the owner's snapshots
//! carry so its prediction applies them to the same inputs. A hold starts
//! with the player's next input (input ticks, not server ticks: a client's
//! labels may run a little behind or ahead of the server's clock).

use realm_proto::{STATUS_KNOCKED, STATUS_POISON, STATUS_SLOW, STATUS_STUN};
use realm_rules::creatures::{Riders, shove_lock_ms};
use realm_sim::{SIM_HZ, Vec3};

use super::{Entity, Mob, MobMode, Player, Sim, planar_distance};

/// A restraint this long past is dropped from snapshots (no input that
/// could still be replayed is that old).
const RESTRAINT_FORGET_TICKS: u32 = 120;

fn ticks(ms: u32) -> u32 {
    (ms * SIM_HZ).div_ceil(1000)
}

/// Venom running on a player.
#[derive(Clone, Copy)]
pub(super) struct Venom {
    pub until: u32,
    pub next: u32,
    pub interval: u32,
    pub damage: f32,
    pub source: Entity,
}

/// Lasting effects on a player, as ticks.
#[derive(Clone, Copy, Default)]
pub(super) struct Afflictions {
    pub stun_until: u32,
    pub knock_until: u32,
    pub web_until: u32,
    pub despair_until: u32,
    pub venom: Option<Venom>,
}

impl Afflictions {
    /// The STATUS_* bits other clients see on this player.
    pub fn bits(&self, tick: u32) -> u8 {
        let mut bits = 0;
        if self.stun_until > tick {
            bits |= STATUS_STUN;
        }
        if self.knock_until > tick {
            bits |= STATUS_KNOCKED;
        }
        if self.web_until > tick {
            bits |= STATUS_SLOW;
        }
        if self.venom.is_some_and(|v| v.until > tick) {
            bits |= STATUS_POISON;
        }
        bits
    }
}

impl Sim {
    /// An ability's riders on a player `attacker` hit from `from`: `power` is
    /// the creature's attack power (venom is a share of it).
    pub(super) fn afflict(
        &mut self,
        victim: Entity,
        attacker: Entity,
        from: Vec3,
        riders: &Riders,
        power: f32,
    ) {
        let tick = self.tick;
        let Some(mut p) = self.world.get_mut::<Player>(victim) else {
            return;
        };
        if p.dead_until != 0 {
            return;
        }
        // Holds count in the owner's input ticks, from its next input.
        let now = p.last_input_tick + 1;
        let stun_immune = p.caster.stat("stun_immunity") > 0.0;
        let slow_immune = p.caster.stat("slow_immunity") > 0.0;
        let mut locked = false;
        if riders.stun_ms > 0 && !stun_immune {
            p.afflictions.stun_until = p.afflictions.stun_until.max(tick + ticks(riders.stun_ms));
            p.restraint.lock(now, now + ticks(riders.stun_ms));
            locked = true;
        }
        if riders.push != 0.0 || riders.lift != 0.0 {
            let away = Vec3::new(p.body.pos.x - from.x, 0.0, p.body.pos.z - from.z);
            let away = if away.length_squared() > 1.0e-4 {
                away.normalize()
            } else {
                Vec3::ZERO
            };
            if !p.body.mounted {
                p.body.shove = away * riders.push;
                if riders.lift > 0.0 {
                    p.body.vel.y = riders.lift;
                    p.body.on_floor = false;
                }
            }
            let lock = ticks(shove_lock_ms(riders.push, riders.lift));
            p.afflictions.knock_until = p.afflictions.knock_until.max(tick + lock);
            p.restraint.lock(now, now + lock);
            locked = true;
        }
        if riders.web_ms > 0 && !slow_immune {
            p.afflictions.web_until = p.afflictions.web_until.max(tick + ticks(riders.web_ms));
            p.restraint.web(now, now + ticks(riders.web_ms));
        }
        if riders.despair_ms > 0 {
            p.afflictions.despair_until = p
                .afflictions
                .despair_until
                .max(tick + ticks(riders.despair_ms));
        }
        if let Some(poison) = riders.poison {
            let damage = (power * poison.ratio).round().max(1.0);
            let weaker = p
                .afflictions
                .venom
                .is_some_and(|v| v.until > tick && v.damage > damage);
            if !weaker {
                let interval = ticks(poison.interval_ms).max(1);
                p.afflictions.venom = Some(Venom {
                    until: tick + poison.ticks * interval,
                    next: tick + interval,
                    interval,
                    damage,
                    source: attacker,
                });
                if !self.poisoned.contains(&victim) {
                    self.poisoned.push(victim);
                }
            }
        }
        // A held body drops the spell it was winding up.
        if locked {
            self.stats.player_holds += 1;
            p.caster.cast = None;
            p.caster.queued = None;
        }
    }

    /// Venom ticks on its own clock; the dead and the cured leave the list.
    /// Expired holds are forgotten so snapshots stop carrying them.
    pub(super) fn advance_afflictions(&mut self) {
        let tick = self.tick;
        let mut doses: Vec<(Entity, Entity, f32)> = Vec::new();
        let mut list = std::mem::take(&mut self.poisoned);
        list.retain(|&player| {
            let Some(mut p) = self.world.get_mut::<Player>(player) else {
                return false;
            };
            if p.dead_until != 0 {
                p.afflictions.venom = None;
                return false;
            }
            let Some(mut venom) = p.afflictions.venom else {
                return false;
            };
            if tick > venom.until {
                p.afflictions.venom = None;
                return false;
            }
            if tick >= venom.next {
                venom.next = tick + venom.interval;
                doses.push((player, venom.source, venom.damage));
            }
            p.afflictions.venom = Some(venom);
            true
        });
        list.append(&mut self.poisoned);
        self.poisoned = list;
        // Venom is not armour's business: it bites flat.
        for (player, source, damage) in doses {
            self.wound_player(player, source, damage, 0.0, false, u8::MAX);
        }
        if tick.is_multiple_of(RESTRAINT_FORGET_TICKS) {
            let mut q = self.world.query::<&mut Player>();
            for mut p in q.iter_mut(&mut self.world) {
                let r = p.restraint;
                let input = p.last_input_tick;
                if r != Default::default()
                    && r.lock_until + RESTRAINT_FORGET_TICKS < input
                    && r.web_until + RESTRAINT_FORGET_TICKS < input
                {
                    p.restraint = Default::default();
                }
            }
        }
    }

    /// Pallids that are fighting chill the players near them each
    /// regeneration beat: a share of their attack power, and despair.
    pub(super) fn chill(&mut self) {
        let tick = self.tick;
        let auras = std::mem::take(&mut self.auras);
        for &mob in &auras {
            let Some((pos, power, aura, level)) = self.world.get::<Mob>(mob).and_then(|m| {
                let species = &self.game.species[usize::from(m.species)];
                (m.mode != MobMode::Dead)
                    .then_some(())
                    .and(species.brain.aura)
                    .map(|a| (m.pos, m.attack_power, a, m.level))
            }) else {
                continue;
            };
            let near: Vec<Entity> = self
                .player_pos
                .iter()
                .filter(|(_, pp)| {
                    planar_distance(**pp, pos) <= aura.radius && (pp.y - pos.y).abs() < aura.radius
                })
                .map(|(e, _)| *e)
                .collect();
            for player in near {
                self.hit_player(player, mob, power * aura.damage_ratio, "poison", level);
                if let Some(mut p) = self.world.get_mut::<Player>(player) {
                    p.afflictions.despair_until = p
                        .afflictions
                        .despair_until
                        .max(tick + ticks(aura.despair_ms));
                }
            }
        }
        self.auras = auras;
    }
}
