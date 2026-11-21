//! Duels and group duels, the old game's `DuelBook` and its authority hooks.
//!
//! `/duel Name` challenges a player within 30 m; `/gduel Name` makes a party
//! leader challenge another party's leader. The challenged has 30 s to
//! `/daccept` (or `/ddecline`). The arena is the midpoint of the two at the
//! accept, 40 m round; a group duel gathers each leader's party members
//! standing within it. Three seconds of countdown, then up to five minutes of
//! fighting. Only foes hurt each other, at half strength, and protection does
//! not hold. A blow that would kill leaves the foe at 1 health and out of
//! the duel; so does dying to a creature, fleeing the arena, leaving, or
//! `/yield`. The side with someone standing when the other has none wins;
//! time runs out into a draw.

use std::collections::HashMap;

use realm_proto::control::{
    CombatEvent, DuelView, HIT_CRIT, HIT_FINISHER, HIT_REFLECTED, ServerMsg,
};
use realm_rules::{Delivery, SpellDef};
use realm_sim::{SIM_HZ, Vec3};

use super::{ConnId, Entity, Player, Sim, planar_distance, unit};

const REQUEST_TICKS: u32 = 30 * SIM_HZ;
const COUNTDOWN_TICKS: u32 = 3 * SIM_HZ;
const FIGHT_TICKS: u32 = 5 * 60 * SIM_HZ;
const CHALLENGE_RANGE: f32 = 30.0;
/// The accept may come from a little further than the challenge.
const ACCEPT_RANGE: f32 = CHALLENGE_RANGE + 10.0;
pub(super) const ARENA_RADIUS: f32 = 40.0;
const DAMAGE_MULTIPLIER: f32 = 0.5;
/// Duelists are checked against the arena this often.
const CHECK_TICKS: u32 = 8;

fn ticks(ms: f32) -> u32 {
    (ms / 1000.0 * SIM_HZ as f32).ceil().max(0.0) as u32
}

struct Request {
    from: Entity,
    group: bool,
    expires: u32,
}

struct Duel {
    id: u32,
    group: bool,
    center: Vec3,
    sides: [Vec<Entity>; 2],
    /// Who is out: (reason, by).
    out: HashMap<Entity, (String, String)>,
    names: HashMap<Entity, String>,
    fight_tick: u32,
    end_tick: u32,
    live: bool,
    last: String,
}

#[derive(Default)]
pub(super) struct DuelBook {
    requests: HashMap<Entity, Request>,
    duels: Vec<Duel>,
    next: u32,
}

impl DuelBook {
    fn duel_of(&self, e: Entity) -> Option<usize> {
        self.duels
            .iter()
            .position(|d| d.sides.iter().any(|s| s.contains(&e)))
    }
}

impl Sim {
    /// Whether `a`'s spells may hurt `b`: foes in a duel's fight, neither
    /// out.
    pub(super) fn foes(&self, a: Entity, b: Entity) -> bool {
        self.duels.duels.iter().any(|d| {
            d.live
                && !d.out.contains_key(&a)
                && !d.out.contains_key(&b)
                && ((d.sides[0].contains(&a) && d.sides[1].contains(&b))
                    || (d.sides[1].contains(&a) && d.sides[0].contains(&b)))
        })
    }

    fn named_here(&self, name: &str) -> Option<Entity> {
        let wanted = name.to_lowercase();
        self.clients
            .values()
            .find(|c| {
                self.world
                    .get::<Player>(c.entity)
                    .is_some_and(|p| p.sheet.name.to_lowercase() == wanted)
            })
            .map(|c| c.entity)
    }

    fn duel_tell(&mut self, player: Entity, text: &str) {
        if let Some(conn) = self.conn_of(player) {
            self.send_control(
                conn,
                &ServerMsg::Chat {
                    channel: realm_proto::coord::CHANNEL_SYSTEM,
                    from: String::new(),
                    text: text.to_owned(),
                    speaker: 0,
                },
            );
        }
    }

    /// A party leader on this map: its character's entity.
    fn party_leader_of(&self, player: Entity) -> Option<Entity> {
        let p = self.world.get::<Player>(player)?;
        if p.party.party == 0 {
            return None;
        }
        let leader = p.party.leader;
        self.clients
            .values()
            .find(|c| c.character == leader)
            .map(|c| c.entity)
    }

    /// `/duel Name` or `/gduel Name`.
    pub(super) fn challenge(&mut self, from: Entity, name: &str, group: bool) {
        let tick = self.tick;
        let Some(mut target) = self.named_here(name) else {
            return self.duel_tell(from, "That player is not here.");
        };
        if target == from {
            return self.duel_tell(from, "You cannot duel yourself.");
        }
        if group {
            let (me, mine) = match self.world.get::<Player>(from) {
                Some(p) => (p.sheet.id, p.party.clone()),
                None => return,
            };
            if mine.party == 0 || mine.leader != me {
                return self.duel_tell(from, "Only a party leader can call a group duel.");
            }
            let theirs = self
                .world
                .get::<Player>(target)
                .map(|p| p.party.party)
                .unwrap_or(0);
            if theirs == 0 || theirs == mine.party {
                return self.duel_tell(from, "A group duel needs another party.");
            }
            // The request goes to that party's leader.
            match self.party_leader_of(target) {
                Some(leader) => target = leader,
                None => return self.duel_tell(from, "Their party leader is not here."),
            }
        }
        if let Err(why) = self.duel_allowed(from, target) {
            return self.duel_tell(from, why);
        }
        if self.duels.duel_of(from).is_some() || self.duels.duel_of(target).is_some() {
            return self.duel_tell(from, "One of you is already in a duel.");
        }
        let (Some(a), Some(b)) = (
            self.world.get::<Player>(from),
            self.world.get::<Player>(target),
        ) else {
            return;
        };
        if a.dead_until != 0 || b.dead_until != 0 {
            return self.duel_tell(from, "The dead do not duel.");
        }
        if planar_distance(a.body.pos, b.body.pos) > CHALLENGE_RANGE {
            return self.duel_tell(from, "Too far away to challenge.");
        }
        let from_name = a.sheet.name.clone();
        let size = if group {
            a.party.members.len() as u8
        } else {
            1
        };
        self.duels.requests.insert(
            target,
            Request {
                from,
                group,
                expires: tick + REQUEST_TICKS,
            },
        );
        if let Some(conn) = self.conn_of(target) {
            self.send_control(
                conn,
                &ServerMsg::DuelInvite {
                    from: from_name,
                    group,
                    size,
                },
            );
        }
        self.duel_tell(from, "Challenge sent.");
    }

    /// `/daccept`: the arena opens between the two, sides gather.
    pub(super) fn accept_duel(&mut self, player: Entity) {
        let tick = self.tick;
        let Some(req) = self.duels.requests.remove(&player) else {
            return self.duel_tell(player, "You have no duel challenge.");
        };
        if tick > req.expires {
            return self.duel_tell(player, "The challenge expired.");
        }
        let (Some(a), Some(b)) = (
            self.world.get::<Player>(req.from),
            self.world.get::<Player>(player),
        ) else {
            return self.duel_tell(player, "The challenger is gone.");
        };
        if a.dead_until != 0
            || b.dead_until != 0
            || planar_distance(a.body.pos, b.body.pos) > ACCEPT_RANGE
        {
            return self.duel_tell(player, "The challenger is too far away.");
        }
        if self.duels.duel_of(req.from).is_some() || self.duels.duel_of(player).is_some() {
            return self.duel_tell(player, "One of you is already in a duel.");
        }
        let center = (a.body.pos + b.body.pos) * 0.5;
        let sides = if req.group {
            let lead = |p: &Player| p.party.party != 0 && p.party.leader == p.sheet.id;
            if !lead(a) || !lead(b) || a.party.party == b.party.party {
                return self.duel_tell(player, "Both must still lead different parties.");
            }
            [self.gather(req.from, center), self.gather(player, center)]
        } else {
            [vec![req.from], vec![player]]
        };
        self.duels.next += 1;
        let mut names = HashMap::new();
        for e in sides.iter().flatten() {
            if let Some(p) = self.world.get::<Player>(*e) {
                names.insert(*e, p.sheet.name.clone());
            }
        }
        let fight_tick = tick + COUNTDOWN_TICKS;
        self.duels.duels.push(Duel {
            id: self.duels.next,
            group: req.group,
            center,
            sides,
            out: HashMap::new(),
            names,
            fight_tick,
            end_tick: fight_tick + FIGHT_TICKS,
            live: false,
            last: String::new(),
        });
        let i = self.duels.duels.len() - 1;
        self.sync_duel(i);
    }

    /// A leader and its party members standing in the arena, five at most.
    fn gather(&self, leader: Entity, center: Vec3) -> Vec<Entity> {
        let mut out = vec![leader];
        let Some(party) = self.world.get::<Player>(leader).map(|p| p.party.clone()) else {
            return out;
        };
        for m in &party.members {
            let Some(e) = self
                .clients
                .values()
                .find(|c| c.character == m.character)
                .map(|c| c.entity)
            else {
                continue;
            };
            if out.contains(&e) || self.duels.duel_of(e).is_some() {
                continue;
            }
            if self.world.get::<Player>(e).is_some_and(|p| {
                p.dead_until == 0 && planar_distance(p.body.pos, center) <= ARENA_RADIUS
            }) {
                out.push(e);
            }
            if out.len() >= realm_proto::coord::PARTY_MAX {
                break;
            }
        }
        out
    }

    pub(super) fn decline_duel(&mut self, player: Entity) {
        let Some(req) = self.duels.requests.remove(&player) else {
            return self.duel_tell(player, "You have no duel challenge.");
        };
        let name = self
            .world
            .get::<Player>(player)
            .map(|p| p.sheet.name.clone())
            .unwrap_or_default();
        if let Some(conn) = self.conn_of(req.from) {
            self.send_control(
                conn,
                &ServerMsg::Duel(DuelView {
                    declined_by: name,
                    ..DuelView::default()
                }),
            );
        }
        self.duel_tell(player, "Duel declined.");
    }

    pub(super) fn yield_duel(&mut self, player: Entity) {
        match self.duels.duel_of(player) {
            Some(i) if self.duels.duels[i].live => self.knock_out(i, player, "yield", ""),
            Some(_) => self.duel_tell(player, "The duel has not begun."),
            None => self.duel_tell(player, "You are not in a duel."),
        }
    }

    fn knock_out(&mut self, i: usize, player: Entity, reason: &str, by: &str) {
        let d = &mut self.duels.duels[i];
        if d.out.contains_key(&player) {
            return;
        }
        d.out.insert(player, (reason.to_owned(), by.to_owned()));
        d.last = d.names.get(&player).cloned().unwrap_or_default();
        self.sync_duel(i);
    }

    /// Whether `player` is in a duel (counting down or fighting).
    pub(super) fn duels_has(&self, player: Entity) -> bool {
        self.duels.duel_of(player).is_some()
    }

    /// `player` leaves the map in a duel: it fled.
    pub(super) fn flee_duel(&mut self, player: Entity) {
        if let Some(i) = self.duels.duel_of(player) {
            self.knock_out(i, player, "fled", "");
        }
    }

    /// The duel as `player` sees it.
    fn duel_view(&self, i: usize, player: Entity) -> DuelView {
        let d = &self.duels.duels[i];
        let mine = usize::from(!d.sides[0].contains(&player));
        let list = |side: &Vec<Entity>| -> Vec<(u32, String)> {
            side.iter()
                .map(|e| {
                    (
                        self.net_id_of(*e),
                        d.names.get(e).cloned().unwrap_or_default(),
                    )
                })
                .collect()
        };
        DuelView {
            duel: d.id,
            group: d.group,
            phase: u8::from(d.live),
            fight_tick: d.fight_tick,
            end_tick: d.end_tick,
            center: [d.center.x, d.center.y, d.center.z],
            radius: ARENA_RADIUS,
            allies: list(&d.sides[mine]),
            foes: list(&d.sides[1 - mine]),
            out: d.out.keys().map(|e| self.net_id_of(*e)).collect(),
            ..DuelView::default()
        }
    }

    fn sync_duel(&mut self, i: usize) {
        let members: Vec<Entity> = self.duels.duels[i]
            .sides
            .iter()
            .flatten()
            .copied()
            .collect();
        for m in members {
            let view = self.duel_view(i, m);
            if let Some(conn) = self.conn_of(m) {
                self.send_control(conn, &ServerMsg::Duel(view));
            }
        }
    }

    /// The duel ends: every duelist hears how it went.
    fn end_duel(&mut self, i: usize, winner: Option<usize>, reason: &str) {
        let members: Vec<Entity> = self.duels.duels[i]
            .sides
            .iter()
            .flatten()
            .copied()
            .collect();
        for m in members {
            let mut view = self.duel_view(i, m);
            let d = &self.duels.duels[i];
            let side = usize::from(!d.sides[0].contains(&m));
            view.duel = 0;
            view.result = match winner {
                Some(w) if w == side => "won",
                Some(_) => "lost",
                None => "draw",
            }
            .to_owned();
            // The reason the last one went out, or the time running out.
            let last_out = d.out.iter().find(|(e, _)| d.names.get(*e) == Some(&d.last));
            view.reason = last_out.map_or(reason.to_owned(), |(_, (r, _))| r.clone());
            view.by = last_out.map(|(_, (_, by))| by.clone()).unwrap_or_default();
            view.last = d.last.clone();
            if let Some(conn) = self.conn_of(m) {
                self.send_control(conn, &ServerMsg::Duel(view));
            }
        }
        self.duels.duels.remove(i);
    }

    /// Requests expire; countdowns open; duelists who left, died or fled the
    /// arena are out; a side with no one standing loses; time draws.
    pub(super) fn tick_duels(&mut self) {
        let tick = self.tick;
        if !tick.is_multiple_of(CHECK_TICKS) {
            return;
        }
        self.duels.requests.retain(|_, r| tick <= r.expires);
        let mut i = 0;
        while i < self.duels.duels.len() {
            if !self.duels.duels[i].live && tick >= self.duels.duels[i].fight_tick {
                self.duels.duels[i].live = true;
                self.sync_duel(i);
            }
            if self.duels.duels[i].live {
                let center = self.duels.duels[i].center;
                let members: Vec<Entity> = self.duels.duels[i]
                    .sides
                    .iter()
                    .flatten()
                    .copied()
                    .collect();
                for m in members {
                    if self.duels.duels[i].out.contains_key(&m) {
                        continue;
                    }
                    let reason = match self.world.get::<Player>(m) {
                        None => Some("left"),
                        Some(p) if p.dead_until != 0 => Some("died"),
                        Some(p) if planar_distance(p.body.pos, center) > ARENA_RADIUS => {
                            Some("fled")
                        }
                        _ => None,
                    };
                    if let Some(r) = reason {
                        self.knock_out(i, m, r, "");
                    }
                }
                let d = &self.duels.duels[i];
                let standing = |s: usize| d.sides[s].iter().any(|e| !d.out.contains_key(e));
                let (a, b) = (standing(0), standing(1));
                if !a || !b {
                    let winner = match (a, b) {
                        (true, false) => Some(0),
                        (false, true) => Some(1),
                        _ => None,
                    };
                    self.end_duel(i, winner, "defeat");
                    continue;
                }
                if tick >= self.duels.duels[i].end_tick {
                    self.end_duel(i, None, "timeout");
                    continue;
                }
            }
            i += 1;
        }
    }

    /// A duelist's spell on a foe: its resistance, the ward, the critical
    /// roll, half strength against armour, defence; a blow that would kill
    /// leaves 1 health and puts the foe out. Then the spell's holds, slow,
    /// throw, burns and weakening land on the foe.
    pub(super) fn hit_duelist(
        &mut self,
        attacker: Entity,
        victim: Entity,
        raw: f32,
        spell: &SpellDef,
        mut flags: u8,
    ) -> u32 {
        let tick = self.tick;
        let rules = self.rules();
        let combat = &rules.combat;
        let Some((crit_bonus, level, strength, skill)) =
            self.world.get::<Player>(attacker).map(|p| {
                (
                    p.caster.stat("crit_chance"),
                    u32::from(p.sheet.level),
                    p.afflictions.strength(tick),
                    combat.skill_level(&p.sheet, &spell.id),
                )
            })
        else {
            return 0;
        };
        let Some(v) = self
            .world
            .get::<Player>(victim)
            .filter(|p| p.dead_until == 0)
        else {
            return 0;
        };
        let kind = combat.attack_kind(&spell.id);
        let c = &v.caster;
        let mut amount = raw * strength;
        let resist = c
            .stat(&format!("{kind}_resist"))
            .clamp(0.0, combat.resist_cap);
        amount *= 1.0 - resist / 100.0;
        // The ward: a single-target bolt goes back at its caster (at the
        // strength it would have struck with); everything else is weakened.
        let mut reflected = false;
        if c.ward_until > tick {
            let ward = combat.ward(c.ward_spell);
            if spell.delivery == Delivery::Projectile && ward.is_some_and(|w| w.reflects) {
                reflected = true;
            } else {
                amount *= ward.map_or(1.0, |w| w.other_damage_multiplier);
            }
        }
        let mut state = self.dice_state;
        let chance = combat.crit_chance(crit_bonus, flags & HIT_FINISHER != 0);
        if amount > 0.0 && chance > 0.0 && unit(&mut state) * 100.0 < chance {
            amount *= combat.crit_multiplier;
            flags |= HIT_CRIT;
        }
        self.dice_state = state;
        amount *= DAMAGE_MULTIPLIER * (1.0 - combat.armor_reduction(c.derived.armor, level));
        amount *= 1.0 - c.stat("defense").clamp(0.0, 50.0) / 100.0;
        let amount = amount.round().max(0.0);
        if reflected {
            let by = self
                .world
                .get::<Player>(victim)
                .map(|p| p.sheet.name.clone())
                .unwrap_or_default();
            self.duel_wound(
                attacker,
                victim,
                amount,
                spell.index,
                flags | HIT_REFLECTED,
                &by,
            );
            return 0;
        }
        let by = self
            .world
            .get::<Player>(attacker)
            .map(|p| p.sheet.name.clone())
            .unwrap_or_default();
        let dealt = self.duel_wound(victim, attacker, amount, spell.index, flags, &by);
        if dealt > 0 && self.foes(attacker, victim) {
            self.duel_afflict(attacker, victim, spell, combat.skill_effect(skill), amount);
        }
        dealt
    }

    /// Damage between duelists: never below 1 health; the blow that would
    /// have killed puts the victim out.
    pub(super) fn duel_wound(
        &mut self,
        victim: Entity,
        attacker: Entity,
        amount: f32,
        spell: u8,
        flags: u8,
        by: &str,
    ) -> u32 {
        let tick = self.tick;
        // A duelist who fell to something else stays down: "never below 1"
        // would hand a corpse a point of health.
        let Some(mut p) = self
            .world
            .get_mut::<Player>(victim)
            .filter(|p| p.dead_until == 0)
        else {
            return 0;
        };
        let beaten = p.hp - amount < 1.0;
        p.hp = (p.hp - amount).max(1.0);
        p.last_combat = tick;
        if amount > 0.0 {
            p.last_hurt = tick;
        }
        let (at, hp) = (p.body.pos, super::hp_byte(p.hp, p.max_hp));
        if let Some(mut a) = self.world.get_mut::<Player>(attacker) {
            a.last_combat = tick;
        }
        let (target, attacker_id) = (self.net_id_of(victim), self.net_id_of(attacker));
        self.event(
            at,
            CombatEvent::Hit {
                target,
                attacker: attacker_id,
                spell,
                amount: amount as u32,
                flags,
                hp,
            },
        );
        if beaten && let Some(i) = self.duels.duel_of(victim) {
            self.knock_out(i, victim, "defeat", by);
        }
        amount as u32
    }

    /// A spell's riders on a duel foe (players have no hold resistance; the
    /// skill level scales the times).
    fn duel_afflict(
        &mut self,
        attacker: Entity,
        victim: Entity,
        spell: &SpellDef,
        effect: f32,
        amount: f32,
    ) {
        let tick = self.tick;
        let from = self.world.get::<Player>(attacker).map(|a| a.body.pos);
        let Some(mut p) = self.world.get_mut::<Player>(victim) else {
            return;
        };
        let now = p.last_input_tick + 1;
        let stun_immune = p.caster.stat("stun_immunity") > 0.0;
        let slow_immune = p.caster.stat("slow_immunity") > 0.0;
        let mut locked = false;
        if spell.stun_ms > 0 && !stun_immune {
            let t = ticks(spell.stun_ms as f32 * effect);
            p.afflictions.stun_until = p.afflictions.stun_until.max(tick + t);
            p.restraint.lock(now, now + t);
            locked = true;
        }
        let mut thaw = now;
        if spell.freeze_ms > 0 && !stun_immune {
            let t = ticks(spell.freeze_ms as f32 * effect);
            p.afflictions.freeze_until = p.afflictions.freeze_until.max(tick + t);
            p.restraint.lock(now, now + t);
            thaw = now + t;
            locked = true;
        }
        if let Some(slow) = spell.slow
            && !slow_immune
        {
            let t = ticks(slow.ms as f32 * effect);
            p.afflictions.web_until = p.afflictions.web_until.max(tick + (thaw - now) + t);
            p.restraint
                .web(thaw, thaw + t, (slow.factor.clamp(0.1, 1.0) * 100.0) as u8);
        }
        if let Some(launch) = spell.launch {
            let away = p.body.pos - from.unwrap_or(p.body.pos);
            let away = Vec3::new(away.x, 0.0, away.z).normalize_or_zero();
            if !p.body.mounted {
                p.body.shove = away * launch.push;
                p.body.vel.y = launch.lift;
                p.body.on_floor = false;
            }
            let t = ticks(realm_rules::creatures::shove_lock_ms(launch.push, launch.lift) as f32);
            p.afflictions.knock_until = p.afflictions.knock_until.max(tick + t);
            p.restraint.lock(now, now + t);
            let land = ticks(launch.land_stun_ms as f32 * effect);
            if land > 0 && !stun_immune {
                p.afflictions.stun_until = p.afflictions.stun_until.max(tick + t + land);
                p.restraint.lock(now, now + t + land);
            }
            locked = true;
        }
        if spell.weaken_ms > 0 {
            p.afflictions.weak_until = tick + ticks(spell.weaken_ms as f32 * effect);
            p.afflictions.weak_factor = spell.weaken_factor;
        }
        for (dot, burn) in [(spell.burn, true), (spell.bleed, false)] {
            let Some(dot) = dot else { continue };
            let interval = ticks(dot.interval_ms as f32).max(1);
            let damage = dot.damage.max((amount * dot.hit_share).round());
            let slot = if burn {
                &mut p.afflictions.burn
            } else {
                &mut p.afflictions.bleed
            };
            *slot = Some(super::afflict::Venom {
                until: tick + dot.ticks * interval,
                next: tick + interval,
                interval,
                damage,
                source: attacker,
            });
        }
        if locked {
            p.caster.cast = None;
            p.caster.queued = None;
        }
        let dotted = spell.burn.is_some() || spell.bleed.is_some();
        if dotted && !self.poisoned.contains(&victim) {
            self.poisoned.push(victim);
        }
    }

    /// The duel commands from chat.
    pub(super) fn duel_command(
        &mut self,
        conn: ConnId,
        player: Entity,
        word: &str,
        rest: &str,
    ) -> bool {
        let _ = conn;
        match word {
            "/duel" if !rest.is_empty() => self.challenge(player, rest, false),
            "/gduel" | "/groupduel" if !rest.is_empty() => self.challenge(player, rest, true),
            "/daccept" | "/duelaccept" => self.accept_duel(player),
            "/ddecline" | "/dueldecline" => self.decline_duel(player),
            "/yield" | "/surrender" => self.yield_duel(player),
            _ => return false,
        }
        true
    }
}
