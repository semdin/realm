//! The kill loop's payoff and its price. A creature remembers who hit it;
//! when it falls, every player who hit it in the last ten seconds earns its
//! experience (scaled by the level gap and their experience bonus), the
//! killer pockets its oril, and what else it dropped lands in one chest any
//! player may open for a minute and a half. A player who falls chooses: rise
//! where it fell with half its health behind a short ward, or in town whole;
//! with no choice it goes to town by itself.
//!
//! The old game's `authority._grant_kill_rewards`, `_drop_loot`,
//! `_collect_loot`, `_kill` and `respawn_player`.

use bevy_ecs::prelude::*;
use realm_proto::control::ServerMsg;
use realm_rules::loot::Kill;
use realm_rules::{CharacterSheet, Item};
use realm_sim::movement::Body;
use realm_sim::{SIM_HZ, Vec3};

use super::{ConnId, Entity, Mob, NetId, Player, ServerDice, Sim, planar_distance, xorshift};
use crate::game::PackKind;

/// Party members this close to a kill share it (3D).
const SHARE_RADIUS: f32 = 40.0;
/// A party member more than this many levels below the highest sharer
/// does not share.
const SHARE_LEVEL_SPREAD: u16 = 15;
const PARTY_BONUS_CAP: f64 = 0.4;
/// Hits older than this at the kill earn nothing (old KILL_CREDIT_MS).
const CREDIT_TICKS: u32 = 10 * SIM_HZ;
/// A creature remembers at most this many hits.
const CREDIT_KEEP: usize = 64;
/// A chest stands this long (90 s).
const CHEST_TICKS: u32 = 90 * SIM_HZ;
/// A chest opens and gives from this close.
const CHEST_REACH: f32 = 7.0;
/// Expired chests are cleared this often.
const CHEST_SWEEP_TICKS: u32 = SIM_HZ;

/// A kill's leftovers.
#[derive(Component)]
pub(super) struct Chest {
    pub pos: Vec3,
    pub slots: Vec<Option<Item>>,
    pub rare: bool,
    pub expires: u32,
    /// Only this character may open it (0: anyone).
    pub owner: u64,
}

/// Who hit a creature, and when (newest last).
#[derive(Clone, Copy)]
pub(super) struct Credit {
    pub player: Entity,
    pub tick: u32,
}

impl Sim {
    pub(super) fn conn_of(&self, entity: Entity) -> Option<ConnId> {
        self.clients
            .iter()
            .find(|(_, c)| c.entity == entity)
            .map(|(conn, _)| *conn)
    }

    /// A player's blow (or its burn) on `mob`, for the kill's credit.
    pub(super) fn note_credit(&mut self, mob: Entity, player: Entity) {
        let tick = self.tick;
        if self.world.get::<Player>(player).is_none() {
            return;
        }
        if let Some(mut m) = self.world.get_mut::<Mob>(mob) {
            if m.credit.len() >= CREDIT_KEEP {
                m.credit.remove(0);
            }
            m.credit.push(Credit { player, tick });
        }
    }

    /// `mob` fell: experience to everyone who hit it lately, oril to the
    /// killer, the rest into a chest.
    pub(super) fn reward_kill(&mut self, mob: Entity) {
        // A boss's part (a head, a vine) pays nothing of its own: the
        // boss's fall pays everyone who hit any of it.
        if self
            .world
            .get::<Mob>(mob)
            .is_some_and(|m| m.part_of.is_some())
        {
            return;
        }
        let tick = self.tick;
        let rules = self.rules();
        let Some((credit, pos, level, exp_reward, elite, boss, pack, species, drop_scale)) =
            self.world.get::<Mob>(mob).map(|m| {
                (
                    m.credit.clone(),
                    m.pos,
                    m.level,
                    m.exp_reward,
                    m.elite,
                    m.boss,
                    m.pack,
                    usize::from(m.species),
                    m.drop_scale,
                )
            })
        else {
            return;
        };
        let kind = self.game.packs[pack].kind.clone();
        let stone = matches!(kind, PackKind::Stone(_));
        // Credit: every player with a hit inside the window, first hit first.
        let mut earners: Vec<Entity> = Vec::new();
        for c in credit
            .iter()
            .filter(|c| tick.saturating_sub(c.tick) <= CREDIT_TICKS)
        {
            if !earners.contains(&c.player) {
                earners.push(c.player);
            }
        }
        let killer = credit.last().map(|c| c.player);
        if let Some(mut m) = self.world.get_mut::<Mob>(mob) {
            m.credit.clear();
        }
        let earners = self.with_party(earners, pos);
        let species_id = self.game.species[species].id.clone();
        for &player in &earners {
            if stone {
                self.quest_event(player, "monolith", "", false);
            } else {
                self.quest_event(player, "kill", &species_id, boss);
            }
        }
        for &player in &earners {
            let Some((player_level, bonus, party)) = self
                .world
                .get::<Player>(player)
                .map(|p| (p.sheet.level, p.caster.stat("exp_bonus"), p.party.party))
            else {
                continue;
            };
            let base = if stone {
                f64::from(exp_reward)
            } else {
                let gap = rules.progress.gap(level, player_level);
                // A party earns more together: +10 % per member who shares,
                // at most +40 %.
                let sharing = if party == 0 {
                    1
                } else {
                    earners
                        .iter()
                        .filter(|e| {
                            self.world
                                .get::<Player>(**e)
                                .is_some_and(|q| q.party.party == party)
                        })
                        .count()
                };
                let together = 1.0 + (0.1 * (sharing as f64 - 1.0)).min(PARTY_BONUS_CAP);
                ((f64::from(exp_reward) * f64::from(gap.exp)).round() * together).round()
            };
            let exp = (base * (1.0 + f64::from(bonus) / 100.0)).round() as u64;
            self.pay(player, exp, 0);
        }
        // The killer's oril and the chest.
        let Some(killer) = killer else {
            return;
        };
        let Some((killer_level, drop_bonus, oril_bonus)) =
            self.world.get::<Player>(killer).map(|p| {
                (
                    p.sheet.level,
                    p.caster.stat("drop_chance"),
                    p.caster.stat("oril_bonus"),
                )
            })
        else {
            return;
        };
        let table = match &kind {
            PackKind::Stone(t) => rules
                .mobs
                .stone_types
                .get(t)
                .map(|s| s.loot_table.clone())
                .unwrap_or_default(),
            _ => self.game.species[species].loot_table.clone(),
        };
        let gap = rules.progress.gap(level, killer_level);
        let mut dice = ServerDice(xorshift(&mut self.dice_state) | 1);
        let loot = rules.roll_loot(
            &Kill {
                table: &table,
                level,
                elite,
                boss,
                stone,
                drop_factor: gap.drop * (1.0 + drop_bonus / 100.0) * drop_scale,
            },
            &mut dice,
        );
        self.dice_state = dice.0;
        let oril = (loot.oril as f64 * (1.0 + f64::from(oril_bonus) / 100.0)).round() as u64;
        if oril > 0 {
            self.pay(killer, 0, oril);
        }
        if !loot.items.is_empty() {
            let a = (xorshift(&mut self.dice_state) % 628) as f32 / 100.0;
            let d = (xorshift(&mut self.dice_state) % 200) as f32 / 100.0 - 1.0;
            let at = pos + Vec3::new(libm::cosf(a) * d, 0.3, libm::sinf(a) * d);
            self.drop_chest(at, loot.items);
        }
    }

    /// A chest of `items` at `at` (rare when one carries bonuses).
    pub(super) fn drop_chest(&mut self, at: Vec3, items: Vec<Item>) {
        let tick = self.tick;
        let rare = items.iter().any(|i| !i.bonuses.is_empty());
        let chest = self
            .world
            .spawn(Chest {
                pos: at,
                slots: items.into_iter().map(Some).collect(),
                rare,
                expires: tick + CHEST_TICKS,
                owner: 0,
            })
            .id();
        let id = self.new_id(chest);
        self.world.entity_mut(chest).insert(NetId(id));
    }

    /// A chest only `owner` may open (a dungeon's final chest); it stands
    /// as long as the copy may (five minutes).
    pub(super) fn drop_owned_chest(&mut self, at: Vec3, items: Vec<Item>, owner: u64) {
        let tick = self.tick;
        let rare = items.iter().any(|i| !i.bonuses.is_empty());
        let chest = self
            .world
            .spawn(Chest {
                pos: at,
                slots: items.into_iter().map(Some).collect(),
                rare,
                expires: tick + 300 * SIM_HZ,
                owner,
            })
            .id();
        let id = self.new_id(chest);
        self.world.entity_mut(chest).insert(NetId(id));
    }

    /// The earners and their party members who share the kill: on this map,
    /// alive, near it, out of protection, within the level spread.
    fn with_party(&self, earners: Vec<Entity>, at: Vec3) -> Vec<Entity> {
        let mut out = earners;
        let mut candidates: Vec<u64> = Vec::new();
        for e in &out {
            if let Some(p) = self.world.get::<Player>(*e) {
                candidates.extend(p.party.members.iter().map(|m| m.character));
            }
        }
        let top = out
            .iter()
            .filter_map(|e| self.world.get::<Player>(*e).map(|p| p.sheet.level))
            .max()
            .unwrap_or(1);
        for character in candidates {
            let Some(entity) = self
                .clients
                .values()
                .find(|c| c.character == character)
                .map(|c| c.entity)
            else {
                continue;
            };
            if out.contains(&entity) {
                continue;
            }
            let ok = self.world.get::<Player>(entity).is_some_and(|p| {
                p.dead_until == 0
                    && (p.body.pos - at).length() <= SHARE_RADIUS
                    && !self.protected(p.body.pos)
                    && p.sheet.level + SHARE_LEVEL_SPREAD >= top
            });
            if ok {
                out.push(entity);
            }
        }
        out
    }

    /// Pays a player experience and oril: levels gained refill health and
    /// mana; the sheet and the reward go to its client.
    pub(super) fn pay(&mut self, player: Entity, exp: u64, oril: u64) {
        if exp == 0 && oril == 0 {
            return;
        }
        let tick = self.tick;
        let rules = self.rules();
        let Some(mut p) = self.world.get_mut::<Player>(player) else {
            return;
        };
        let levels = rules.progress.grant_exp(&mut p.sheet, exp);
        p.sheet.oril = p.sheet.oril.saturating_add(oril);
        p.sheet.revision += 1;
        p.dirty_since.get_or_insert(tick);
        if levels > 0 {
            let derived = rules.derived(&p.sheet);
            p.max_hp = derived.max_hp.max(1) as f32;
            p.caster.max_mana = derived.max_mana as f32;
            p.caster.derived = derived;
            if p.dead_until == 0 {
                p.hp = p.max_hp;
                p.caster.mana = p.caster.max_mana;
            }
        }
        if let Some(conn) = self.conn_of(player) {
            self.send_sheet(conn);
            self.send_control(
                conn,
                &ServerMsg::Reward {
                    exp,
                    oril,
                    items: Vec::new(),
                    levels,
                    rep: 0,
                },
            );
        }
    }

    /// Chests past their time go.
    pub(super) fn sweep_chests(&mut self) {
        let tick = self.tick;
        if !tick.is_multiple_of(CHEST_SWEEP_TICKS) {
            return;
        }
        let mut q = self.world.query::<(Entity, &Chest)>();
        let gone: Vec<Entity> = q
            .iter(&self.world)
            .filter(|(_, c)| tick >= c.expires || c.slots.iter().all(Option::is_none))
            .map(|(e, _)| e)
            .collect();
        for e in gone {
            if let Some(id) = self.world.get::<NetId>(e).map(|n| n.0) {
                self.ids.remove(&id);
            }
            self.world.despawn(e);
        }
    }

    fn chest_in_reach(&self, player: Entity, id: u32) -> Result<Entity, &'static str> {
        let Some(p) = self.world.get::<Player>(player) else {
            return Err("gone");
        };
        if p.dead_until != 0 {
            return Err("dead");
        }
        let chest = *self.ids.get(&id).ok_or("gone")?;
        let c = self.world.get::<Chest>(chest).ok_or("gone")?;
        if c.owner != 0 && c.owner != p.sheet.id {
            return Err("not_yours");
        }
        if planar_distance(c.pos, p.body.pos) > CHEST_REACH
            || (c.pos.y - p.body.pos.y).abs() > CHEST_REACH
        {
            return Err("out_of_range");
        }
        Ok(chest)
    }

    fn chest_msg(&self, chest: Entity, id: u32) -> ServerMsg {
        ServerMsg::Chest {
            chest: id,
            slots: self
                .world
                .get::<Chest>(chest)
                .map(|c| c.slots.clone())
                .unwrap_or_default(),
        }
    }

    pub(super) fn open_chest(&mut self, conn: ConnId, player: Entity, id: u32) {
        match self.chest_in_reach(player, id) {
            Ok(chest) => {
                let msg = self.chest_msg(chest, id);
                self.send_control(conn, &msg);
            }
            Err(reason) => self.send_control(
                conn,
                &ServerMsg::LootResult {
                    chest: id,
                    ok: false,
                    reason: reason.to_owned(),
                },
            ),
        }
    }

    /// Takes one cell, or every cell that fits the bag; a cell that does not
    /// fit stays in the chest.
    pub(super) fn take_loot(&mut self, conn: ConnId, player: Entity, id: u32, slot: Option<u8>) {
        let tick = self.tick;
        let rules = self.rules();
        let chest = match self.chest_in_reach(player, id) {
            Ok(c) => c,
            Err(reason) => {
                self.send_control(
                    conn,
                    &ServerMsg::LootResult {
                        chest: id,
                        ok: false,
                        reason: reason.to_owned(),
                    },
                );
                return;
            }
        };
        let Some(mut sheet) = self.world.get::<Player>(player).map(|p| p.sheet.clone()) else {
            return;
        };
        let mut slots = self
            .world
            .get::<Chest>(chest)
            .map(|c| c.slots.clone())
            .unwrap_or_default();
        let wanted: Vec<usize> = match slot {
            Some(s) => vec![usize::from(s)],
            None => (0..slots.len()).collect(),
        };
        let mut taken: Vec<(String, u32)> = Vec::new();
        let mut left_out = false;
        for i in wanted {
            let Some(item) = slots.get(i).cloned().flatten() else {
                continue;
            };
            let mut trial: CharacterSheet = sheet.clone();
            if realm_rules::items::add_item(&mut trial, item.clone(), &rules).is_ok() {
                sheet = trial;
                taken.push((item.id.clone(), item.amount));
                slots[i] = None;
            } else {
                left_out = true;
            }
        }
        let reason = if taken.is_empty() {
            if left_out { "bag_full" } else { "gone" }
        } else if left_out {
            "bag_full"
        } else {
            "taken"
        };
        if !taken.is_empty() {
            if let Some(mut c) = self.world.get_mut::<Chest>(chest) {
                c.slots = slots;
            }
            if let Some(mut p) = self.world.get_mut::<Player>(player) {
                sheet.revision += 1;
                p.sheet = sheet;
                p.dirty_since.get_or_insert(tick);
            }
            self.send_sheet(conn);
            self.send_control(
                conn,
                &ServerMsg::Reward {
                    exp: 0,
                    oril: 0,
                    items: taken.clone(),
                    levels: 0,
                    rep: 0,
                },
            );
        }
        let msg = self.chest_msg(chest, id);
        self.send_control(conn, &msg);
        self.send_control(
            conn,
            &ServerMsg::LootResult {
                chest: id,
                ok: !taken.is_empty(),
                reason: reason.to_owned(),
            },
        );
    }

    /// A player fell: it may rise after a moment, and goes to town by itself
    /// after a while.
    pub(super) fn player_died(&mut self, player: Entity, killer: Entity) {
        self.run_player_died(player);
        let tick = self.tick;
        let d = &self.game.death;
        let (ready, auto) = (tick + d.ready_ticks, tick + d.auto_ticks);
        if let Some(mut p) = self.world.get_mut::<Player>(player) {
            p.respawn_ready = ready;
            p.dead_until = auto;
        }
        let killer = self.net_id_of(killer);
        if let Some(conn) = self.conn_of(player) {
            self.send_control(
                conn,
                &ServerMsg::Death {
                    ready_tick: ready,
                    auto_tick: auto,
                    killer,
                },
            );
        }
    }

    /// Rises a dead player: `here` where it fell (half health and mana, a
    /// short ward), else in town whole.
    pub(super) fn respawn(&mut self, player: Entity, here: bool) {
        let tick = self.tick;
        let (fraction, ward) = (
            self.game.death.here_fraction,
            self.game.death.here_ward_ticks,
        );
        let y_min = self.game.y_min;
        // In a dungeon copy the town point is the copy's entry.
        let copy_shift = self
            .world
            .get::<Player>(player)
            .filter(|_| self.instanced)
            .map_or(Vec3::ZERO, |p| {
                super::dungeon::offset_of(realm_rules::dungeons::copy_at(p.body.pos.x))
            });
        let town = if self.dev_spawn_packs.is_empty() {
            Some(self.game.town_point + copy_shift)
        } else {
            None
        };
        let Some(mut p) = self.world.get_mut::<Player>(player) else {
            return;
        };
        if p.dead_until == 0 {
            return;
        }
        let here = here && p.body.pos.y >= y_min;
        p.dead_until = 0;
        p.respawn_ready = 0;
        p.life = p.life.wrapping_add(1);
        p.afflictions = super::afflict::Afflictions::default();
        p.restraint = Default::default();
        p.caster.cast = None;
        p.caster.queued = None;
        if here {
            p.hp = (p.max_hp * fraction).round().max(1.0);
            p.caster.mana = (p.caster.max_mana * fraction).round();
            p.caster.ward_until = tick + ward;
            let at = p.body.pos;
            p.body = Body::at(at);
        } else {
            p.hp = p.max_hp;
            p.caster.mana = p.caster.max_mana;
            let at = town.unwrap_or(p.home);
            p.body = Body::at(at);
        }
    }

    /// The client's choice.
    pub(super) fn request_respawn(&mut self, player: Entity, here: bool) {
        let tick = self.tick;
        if self
            .world
            .get::<Player>(player)
            .is_some_and(|p| p.dead_until != 0 && tick >= p.respawn_ready)
        {
            self.respawn(player, here);
        }
    }

    pub(super) fn spend_attribute(&mut self, conn: ConnId, player: Entity, stat: String) {
        let tick = self.tick;
        let rules = self.rules();
        let Some(mut p) = self.world.get_mut::<Player>(player) else {
            return;
        };
        let reason = if p.dead_until != 0 {
            "dead"
        } else {
            rules.progress.spend_attribute(&mut p.sheet, &stat)
        };
        let ok = reason == "spent";
        if ok {
            // The point's health or mana room comes filled.
            let derived = rules.derived(&p.sheet);
            let (old_hp, old_mana) = (p.max_hp, p.caster.max_mana);
            p.max_hp = derived.max_hp.max(1) as f32;
            p.caster.max_mana = derived.max_mana as f32;
            p.hp = (p.hp + (p.max_hp - old_hp).max(0.0)).min(p.max_hp);
            p.caster.mana =
                (p.caster.mana + (p.caster.max_mana - old_mana).max(0.0)).min(p.caster.max_mana);
            p.caster.derived = derived;
            p.sheet.revision += 1;
            p.dirty_since.get_or_insert(tick);
        }
        if ok {
            self.send_sheet(conn);
        }
        self.send_control(
            conn,
            &ServerMsg::AttributeResult {
                stat,
                ok,
                reason: reason.to_owned(),
            },
        );
    }

    /// The kill's experience a creature carries: a boss's, a Dark Shard's,
    /// else its level's x its species' x an elite's.
    pub(super) fn exp_reward_of(&self, mob: &Mob) -> u32 {
        let rules = &self.game.rules;
        let pack = &self.game.packs[mob.pack];
        match &pack.kind {
            PackKind::Stone(t) => rules.mobs.stone_types.get(t).map_or(0, |s| s.exp_reward),
            PackKind::Dummy => 0,
            _ if mob.boss => pack
                .boss_setup
                .as_ref()
                .and_then(|b| rules.mobs.bosses.get(&b.key))
                .map_or(0, |b| b.exp_reward),
            _ => rules.progress.creature_exp(
                &self.game.species[usize::from(mob.species)].id,
                mob.level,
                mob.elite,
            ),
        }
    }
}
