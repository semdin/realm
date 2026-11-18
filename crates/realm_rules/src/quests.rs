//! The quest chain (quests.json) and the people who give it (npcs.json).
//!
//! A quest opens by itself once the character reached its level and claimed
//! every quest it requires; open quests count in parallel. Events (a kill, a
//! talk, a visit, a refinement...) advance every open quest they match; a
//! quest that reaches its count waits in `ready` until the player claims it,
//! which pays experience, oril, house reputation and items. House standing
//! comes from quests only; its rank follows combat.json house_ranks.
//!
//! The old game's `authority.quest_event`, `quest_claim_for_record`,
//! `_complete_quest` and `quests_open`.

use serde_json::Value;

use crate::Rules;
use crate::items::add_item;
use crate::sheet::{CharacterSheet, Item};

#[derive(Clone, Debug, Default, PartialEq)]
pub struct QuestDef {
    pub id: String,
    pub chapter: String,
    pub level: u16,
    pub title: String,
    /// The objective line.
    pub name: String,
    pub desc: String,
    /// NPC name whose dialogue lists the quest.
    pub giver: String,
    /// kill, talk, visit, refine, enchant, equip, monolith, dungeon, dummy,
    /// enter_map.
    pub kind: String,
    /// Species, NPC name, place, slot, map or dungeon; empty matches any.
    pub target: String,
    pub count: u32,
    /// Kill quests: only a boss counts.
    pub boss: bool,
    /// Visit quests: only on a broom.
    pub mounted: bool,
    pub requires: Vec<String>,
    pub reward_exp: u64,
    pub reward_oril: u64,
    pub reward_rep: u32,
    pub reward_items: Vec<(String, u32)>,
}

/// A named circle on a map (visit quests).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Place {
    pub name: String,
    pub map: String,
    pub center: (f32, f32),
    pub radius: f32,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct NpcDef {
    pub id: String,
    pub name: String,
    pub map: String,
    pub pos: (f32, f32),
}

#[derive(Clone, Debug, Default)]
pub struct QuestRules {
    pub chain: Vec<QuestDef>,
    /// Data order (the first containing place wins).
    pub places: Vec<Place>,
    pub talk_radius: f32,
    pub npcs: Vec<NpcDef>,
    /// combat.json house_ranks: rank i+1 needs thresholds[i].
    pub rank_thresholds: Vec<u32>,
    pub rank_titles: Vec<String>,
}

/// What a claim paid.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct QuestReward {
    pub exp: u64,
    pub oril: u64,
    pub rep: u32,
    pub items: Vec<(String, u32)>,
    pub levels: u16,
}

fn text(v: &Value) -> String {
    v.as_str().unwrap_or("").to_owned()
}

impl QuestRules {
    pub fn from_json(quests: &Value, npcs: &Value, combat: &Value) -> Self {
        let chain = quests["chain"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|q| QuestDef {
                id: text(&q["id"]),
                chapter: text(&q["chapter"]),
                level: q["level"].as_u64().unwrap_or(1) as u16,
                title: text(&q["title"]),
                name: text(&q["name"]),
                desc: text(&q["desc"]),
                giver: text(&q["giver"]),
                kind: text(&q["type"]),
                target: text(&q["target"]),
                count: q["count"].as_u64().unwrap_or(1).max(1) as u32,
                boss: q["boss"].as_bool().unwrap_or(false),
                mounted: q["mounted"].as_bool().unwrap_or(false),
                requires: q["requires"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|r| r.as_str().map(str::to_owned))
                    .collect(),
                reward_exp: q["reward_exp"].as_u64().unwrap_or(0),
                reward_oril: q["reward_gold"].as_u64().unwrap_or(0),
                reward_rep: q["reward_house_rep"].as_u64().unwrap_or(0) as u32,
                reward_items: q["reward_items"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|i| (text(&i["id"]), i["amount"].as_u64().unwrap_or(1) as u32))
                    .collect(),
            })
            .collect();
        let places = quests["places"]
            .as_object()
            .into_iter()
            .flatten()
            .map(|(name, p)| Place {
                name: name.clone(),
                map: text(&p["map"]),
                center: (
                    p["center"][0].as_f64().unwrap_or(0.0) as f32,
                    p["center"][1].as_f64().unwrap_or(0.0) as f32,
                ),
                radius: p["radius"].as_f64().unwrap_or(0.0) as f32,
            })
            .collect();
        let npcs = npcs["npcs"]
            .as_object()
            .into_iter()
            .flatten()
            .map(|(id, n)| NpcDef {
                id: id.clone(),
                name: text(&n["name"]),
                map: text(&n["map"]),
                pos: (
                    n["pos"][0].as_f64().unwrap_or(0.0) as f32,
                    n["pos"][1].as_f64().unwrap_or(0.0) as f32,
                ),
            })
            .collect();
        let ranks = &combat["house_ranks"];
        Self {
            chain,
            places,
            talk_radius: quests["talk_radius"].as_f64().unwrap_or(6.0) as f32,
            npcs,
            rank_thresholds: ranks["thresholds"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_u64)
                .map(|t| t as u32)
                .collect(),
            rank_titles: ranks["titles"]
                .as_array()
                .into_iter()
                .flatten()
                .map(text)
                .collect(),
        }
    }

    #[must_use]
    pub fn quest(&self, id: &str) -> Option<&QuestDef> {
        self.chain.iter().find(|q| q.id == id)
    }

    /// Whether `q` is open for `sheet`: its level reached, not finished,
    /// every quest it requires claimed.
    #[must_use]
    pub fn is_open(&self, sheet: &CharacterSheet, q: &QuestDef) -> bool {
        let log = &sheet.quests;
        q.level <= sheet.level
            && !log.done.contains(&q.id)
            && !log.ready.contains(&q.id)
            && q.requires.iter().all(|r| log.done.contains(r))
    }

    /// The first place on `map` containing x, z.
    #[must_use]
    pub fn place_at(&self, map: &str, x: f32, z: f32) -> Option<&Place> {
        self.places.iter().find(|p| {
            p.map == map && {
                let (dx, dz) = (x - p.center.0, z - p.center.1);
                dx * dx + dz * dz <= p.radius * p.radius
            }
        })
    }

    #[must_use]
    pub fn npc_named(&self, name: &str) -> Option<&NpcDef> {
        self.npcs.iter().find(|n| n.name == name)
    }

    /// Advances every open quest the event matches by `amount`; a quest that
    /// reaches its count moves to `ready`. `mounted` is whether a visitor
    /// rides (a mounted visit quest counts only then). Returns whether
    /// anything changed.
    pub fn event(
        &self,
        sheet: &mut CharacterSheet,
        kind: &str,
        target: &str,
        amount: u32,
        boss: bool,
        mounted: bool,
    ) -> bool {
        if amount == 0 {
            return false;
        }
        let mut changed = false;
        for q in &self.chain {
            if q.kind != kind
                || (q.boss && !boss)
                || (q.mounted && !mounted)
                || (!q.target.is_empty() && q.target != target)
                || !self.is_open(sheet, q)
            {
                continue;
            }
            let log = &mut sheet.quests;
            let done = match log.progress.iter_mut().find(|(id, _)| *id == q.id) {
                Some((_, n)) => {
                    *n = n.saturating_add(amount);
                    *n >= q.count
                }
                None => {
                    log.progress.push((q.id.clone(), amount));
                    amount >= q.count
                }
            };
            if done {
                log.progress.retain(|(id, _)| *id != q.id);
                log.ready.push(q.id.clone());
            }
            changed = true;
        }
        changed
    }

    /// The house rank (1..) a reputation holds.
    #[must_use]
    pub fn rank(&self, rep: u32) -> u8 {
        self.rank_thresholds
            .iter()
            .filter(|t| rep >= **t)
            .count()
            .max(1) as u8
    }

    /// Reputation stops at the last rank's threshold.
    #[must_use]
    pub fn max_rep(&self) -> u32 {
        self.rank_thresholds.last().copied().unwrap_or(u32::MAX)
    }
}

impl Rules {
    /// Claims a ready quest: experience (levels), oril, reputation and the
    /// reward items into the bag; refused as "not_ready", or "bag_full" when
    /// the items do not fit (the quest stays ready).
    pub fn claim_quest(
        &self,
        sheet: &mut CharacterSheet,
        id: &str,
    ) -> Result<QuestReward, &'static str> {
        let q = self.quests.quest(id).ok_or("not_ready")?;
        if !sheet.quests.ready.iter().any(|r| r == id) {
            return Err("not_ready");
        }
        let mut trial = sheet.clone();
        for (item, amount) in &q.reward_items {
            let piece: Item = self.new_item(item, *amount);
            add_item(&mut trial, piece, self).map_err(|_| "bag_full")?;
        }
        *sheet = trial;
        sheet.quests.ready.retain(|r| r != id);
        sheet.quests.done.push(id.to_owned());
        sheet.oril = sheet.oril.saturating_add(q.reward_oril);
        let levels = self.progress.grant_exp(sheet, q.reward_exp);
        let before = sheet.house_rep;
        sheet.house_rep = (sheet.house_rep + q.reward_rep).min(self.quests.max_rep());
        Ok(QuestReward {
            exp: q.reward_exp,
            oril: q.reward_oril,
            rep: sheet.house_rep - before,
            items: q.reward_items.clone(),
            levels,
        })
    }
}
