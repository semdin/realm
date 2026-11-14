//! Quest events on the server: kills, Dark Shards and dummy hits come from
//! combat, talks from the client (range-checked against the NPC), visits
//! from a sweep of where players stand, equips, refinements and imbues from
//! item operations. A quest that changes sends the sheet (it carries the
//! log); a claim pays through the rules and answers the client.

use realm_proto::control::ServerMsg;
use realm_sim::{SIM_HZ, Vec3};

use super::{ConnId, Entity, Player, Sim, planar_distance};

/// Players are checked against the quest places this often (0.5 s).
const VISIT_TICKS: u32 = SIM_HZ / 2;

impl Sim {
    /// One quest event for `player`: every open quest it matches advances.
    pub(super) fn quest_event(&mut self, player: Entity, kind: &str, target: &str, boss: bool) {
        let tick = self.tick;
        let rules = self.rules();
        let Some(mut p) = self.world.get_mut::<Player>(player) else {
            return;
        };
        let mounted = p.body.mounted;
        if !rules
            .quests
            .event(&mut p.sheet, kind, target, 1, boss, mounted)
        {
            return;
        }
        p.sheet.revision += 1;
        p.dirty_since.get_or_insert(tick);
        if let Some(conn) = self.conn_of(player) {
            self.send_sheet(conn);
        }
    }

    /// Where every living player stands, against the quest places.
    pub(super) fn quest_visits(&mut self) {
        if !self.tick.is_multiple_of(VISIT_TICKS) {
            return;
        }
        let rules = self.rules();
        let map = self.game.map.clone();
        let mut visits: Vec<(Entity, String)> = Vec::new();
        let mut q = self.world.query::<(Entity, &Player)>();
        for (entity, p) in q.iter(&self.world) {
            if p.dead_until != 0 {
                continue;
            }
            if let Some(place) = rules.quests.place_at(&map, p.body.pos.x, p.body.pos.z) {
                // Only worth a call when an open visit quest names it.
                let wanted = rules.quests.chain.iter().any(|quest| {
                    quest.kind == "visit"
                        && quest.target == place.name
                        && rules.quests.is_open(&p.sheet, quest)
                });
                if wanted {
                    visits.push((entity, place.name.clone()));
                }
            }
        }
        for (player, place) in visits {
            self.quest_event(player, "visit", &place, false);
        }
    }

    /// The client talked to `name`: within reach of that NPC on this map, it
    /// counts for the talk quests naming it.
    pub(super) fn talk(&mut self, player: Entity, name: &str) {
        let rules = self.rules();
        let Some(npc) = rules.quests.npc_named(name) else {
            return;
        };
        let Some(pos) = self
            .world
            .get::<Player>(player)
            .filter(|p| p.dead_until == 0)
            .map(|p| p.body.pos)
        else {
            return;
        };
        if npc.map != self.game.map
            || planar_distance(pos, Vec3::new(npc.pos.0, pos.y, npc.pos.1))
                > rules.quests.talk_radius
        {
            return;
        }
        self.quest_event(player, "talk", name, false);
    }

    /// Claims a ready quest; the reward, the sheet and the answer go back.
    pub(super) fn claim_quest(&mut self, conn: ConnId, player: Entity, id: String) {
        let tick = self.tick;
        let rules = self.rules();
        let Some(mut p) = self.world.get_mut::<Player>(player) else {
            return;
        };
        let result = rules.claim_quest(&mut p.sheet, &id);
        if let Ok(reward) = &result {
            p.sheet.revision += 1;
            p.dirty_since.get_or_insert(tick);
            if reward.levels > 0 {
                let derived = rules.derived(&p.sheet);
                p.max_hp = derived.max_hp.max(1) as f32;
                p.caster.max_mana = derived.max_mana as f32;
                p.caster.derived = derived;
                if p.dead_until == 0 {
                    p.hp = p.max_hp;
                    p.caster.mana = p.caster.max_mana;
                }
            }
        }
        match result {
            Ok(reward) => {
                self.send_sheet(conn);
                self.send_control(
                    conn,
                    &ServerMsg::Reward {
                        exp: reward.exp,
                        oril: reward.oril,
                        items: reward.items,
                        levels: reward.levels,
                        rep: reward.rep,
                    },
                );
                self.send_control(
                    conn,
                    &ServerMsg::QuestResult {
                        quest: id,
                        ok: true,
                        reason: "claimed".to_owned(),
                    },
                );
            }
            Err(reason) => self.send_control(
                conn,
                &ServerMsg::QuestResult {
                    quest: id,
                    ok: false,
                    reason: reason.to_owned(),
                },
            ),
        }
    }
}
