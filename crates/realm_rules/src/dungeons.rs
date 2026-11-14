//! Dungeons (dungeons.json): difficulties, party rules, spawn roles,
//! medals, rewards, and each dungeon's director steps. Also what a character
//! keeps of its runs (unlocks, best times, today's rewarded runs).
//!
//! A run's creatures stand at the party's level: the reference level
//! `round(0.6 x highest + 0.4 x mean)` clamped to the dungeon's band, plus
//! the difficulty's offset and the spawn role's. Health grows with the
//! party, damage does not. Ordinary rewards come from the kills; a full run
//! adds the completion share, oril and a personal chest for members with a
//! daily reward right left (the others go in as helpers).
//!
//! The old game's `HPRules.dungeon_*`, `dungeon_director` parameters and
//! `player.record_dungeon_run`, with these faults fixed: a run that timed out
//! records no clear (it unlocked harder difficulties and set best times
//! without a full clear); the gate holds the party to `max_party`.

use std::collections::BTreeMap;

use realm_data::without_notes;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::sheet::CharacterSheet;

/// Difficulty ids, easiest first (their index is the difficulty's rank).
pub const DIFFICULTIES: [&str; 5] = ["easy", "normal", "hard", "very_hard", "legendary"];

/// Medal ranks: what a recorded clear earned.
pub const RANK_CLEAR: i8 = 0;
pub const RANK_BRONZE: i8 = 1;
pub const RANK_SILVER: i8 = 2;
pub const RANK_GOLD: i8 = 3;

/// Copies of a dungeon a map server holds at once.
pub const COPIES: u8 = 8;
/// Copies stand side by side this far apart along x (a dungeon spans less
/// than 70 m across; the gap keeps copies out of each other's sight).
pub const COPY_STRIDE: f32 = 240.0;

/// Where copy `copy` (1..=COPIES) of a dungeon stands: its offset along x
/// (0 for copy 0, a map without copies).
#[must_use]
pub fn copy_offset(copy: u8) -> [f32; 3] {
    if copy == 0 {
        return [0.0; 3];
    }
    [
        (f32::from(copy) - (f32::from(COPIES) + 1.0) / 2.0) * COPY_STRIDE,
        0.0,
        0.0,
    ]
}

/// The copy a point lies in (0: none).
#[must_use]
pub fn copy_at(x: f32) -> u8 {
    let slot = (x / COPY_STRIDE + (f32::from(COPIES) + 1.0) / 2.0).round();
    if (1.0..=f32::from(COPIES)).contains(&slot) {
        slot as u8
    } else {
        0
    }
}

#[must_use]
pub fn difficulty_index(id: &str) -> Option<usize> {
    DIFFICULTIES.iter().position(|d| *d == id)
}

#[must_use]
pub fn medal_rank(name: &str) -> i8 {
    match name {
        "gold" => RANK_GOLD,
        "silver" => RANK_SILVER,
        "bronze" => RANK_BRONZE,
        _ => RANK_CLEAR,
    }
}

#[must_use]
pub fn medal_name(rank: i8) -> &'static str {
    match rank {
        RANK_GOLD => "gold",
        RANK_SILVER => "silver",
        RANK_BRONZE => "bronze",
        _ => "",
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Difficulty {
    pub id: String,
    pub display: String,
    pub level_offset: i32,
    pub hp: f32,
    pub damage: f32,
    pub mobs: f32,
    pub affixes: u8,
    pub min_party: u8,
    pub min_level_add: u16,
    pub death_penalty_s: f32,
    /// -1: deaths cost nothing but time.
    pub lives: i32,
    pub exp_budget: f32,
    pub kill_exp: f32,
    pub gold: f32,
    pub drop: f32,
    pub bonus_count: (u8, u8),
    pub tier_up: f32,
    /// Rewarded runs a day (-1 unlimited).
    pub daily_rewards: i32,
    pub unlock_after: Option<usize>,
    pub unlock_medal: i8,
    pub keys: u32,
    pub par_mult: f32,
    pub seals: u32,
    pub telegraph: f32,
    pub hazard_mult: f32,
    pub boss_enrage_s: f32,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Group {
    pub max_party: usize,
    pub max_level_spread: u16,
    pub ref_max_weight: f32,
    pub party_hp_trash: f32,
    pub party_hp_boss: f32,
    pub party_mobs: f32,
    pub party_exp_per_member: f32,
    pub party_exp_cap: f32,
    pub gather_radius: f32,
    pub ready_s: f32,
    pub countdown_s: f32,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Role {
    pub lvl: i32,
    pub forces: u32,
    /// Health grows with the party like a boss's (else like trash).
    pub boss_hp: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Trigger {
    Enter,
    Cleared(String),
    ClearedAll,
    /// A creature of the step is below this share of its health (or dead).
    HpBelow(String, f32),
    /// A living player stands past this local z.
    Area(f32),
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Hatch {
    pub after_s: f32,
    pub into: Vec<(String, String)>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct SpawnEntry {
    pub mob: String,
    pub role: String,
    /// A group (trash and elites grow with difficulty and party); 0: one.
    pub count: u32,
    pub spread: f32,
    /// Local position (x, y, z) in the dungeon's frame.
    pub at: [f32; 3],
    pub lvl: i32,
    pub assist: Option<f32>,
    pub boss_key: Option<String>,
    pub template: Option<String>,
    pub min_difficulty: usize,
    pub hatch: Option<Hatch>,
    pub harp: Option<[f32; 3]>,
    /// Difficulty -> the sleep chime's scale.
    pub harp_scale: BTreeMap<usize, f32>,
    /// Difficulty -> marks set on the creature.
    pub marks: BTreeMap<usize, Vec<String>>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Cocoon {
    pub mob: String,
    pub hold_s: f32,
    pub hp_share: f32,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Pool {
    /// "venom" or "web".
    pub kind: String,
    pub at: [f32; 3],
    pub radius: f32,
    pub duration_s: f32,
    pub hp_share_s: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Step {
    pub id: String,
    pub on: Trigger,
    pub optional: bool,
    pub min_difficulty: usize,
    pub spawn: Vec<SpawnEntry>,
    pub open: Vec<String>,
    pub close: Vec<String>,
    pub message: String,
    pub complete: bool,
    /// The final chest: loot table, local point.
    pub chest: Option<(String, [f32; 3])>,
    pub cocoon: Option<Cocoon>,
    pub pools: Vec<Pool>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Hazard {
    pub id: String,
    pub x: (f32, f32),
    pub z: (f32, f32),
    pub push: [f32; 3],
    pub lift: f32,
    pub every_s: f32,
    pub warn_s: f32,
    pub from_step: String,
    pub until_step: String,
    pub message: String,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct DungeonDef {
    pub id: String,
    pub map: String,
    pub display: String,
    pub level_min: u16,
    pub level_max: u16,
    pub par_s: f32,
    pub key: String,
    /// First-clear title (id, name).
    pub title: Option<(String, String)>,
    pub hazards: Vec<Hazard>,
    pub steps: Vec<Step>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Medals {
    pub gold: f32,
    pub silver: f32,
    pub bronze: f32,
    pub limit: f32,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Rewards {
    pub creature_drop: f32,
    pub completion_share: f32,
    pub first_run_exp: f32,
    pub oril_per_level: (u32, u32),
    /// Per medal rank (index RANK_*): exp, gold, seals, item chance.
    pub medal_exp: [f32; 4],
    pub medal_gold: [f32; 4],
    pub medal_seals: [u32; 4],
    pub medal_item: [f32; 4],
    pub flawless_seals: u32,
    /// Difficulty -> keys in the chest.
    pub key_drop: BTreeMap<usize, u32>,
    /// The seal shop: item, amount, seals.
    pub shop: Vec<(String, u32, u32)>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct DungeonRules {
    pub difficulties: Vec<Difficulty>,
    pub group: Group,
    pub roles: BTreeMap<String, Role>,
    pub medals: Medals,
    pub rewards: Rewards,
    pub dungeons: BTreeMap<String, DungeonDef>,
}

fn f(v: &Value, default: f32) -> f32 {
    v.as_f64().map_or(default, |n| n as f32)
}

fn point(v: &Value) -> [f32; 3] {
    [f(&v[0], 0.0), f(&v[1], 0.0), f(&v[2], 0.0)]
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array()
        .into_iter()
        .flatten()
        .filter_map(|s| s.as_str().map(str::to_owned))
        .collect()
}

fn by_medal<T: Copy>(v: &Value, read: impl Fn(&Value) -> T, none: T) -> [T; 4] {
    let mut out = [none; 4];
    for (name, x) in v.as_object().into_iter().flatten() {
        let rank = medal_rank(name);
        if rank > RANK_CLEAR {
            out[rank as usize] = read(x);
        }
    }
    out
}

fn trigger(on: &str) -> Result<Trigger, String> {
    let mut parts = on.split(':');
    Ok(match (parts.next(), parts.next(), parts.next()) {
        (Some("enter"), None, None) => Trigger::Enter,
        (Some("cleared"), Some("all"), None) => Trigger::ClearedAll,
        (Some("cleared"), Some(step), None) => Trigger::Cleared(step.to_owned()),
        (Some("hp_below"), Some(step), Some(share)) => Trigger::HpBelow(
            step.to_owned(),
            share.parse().map_err(|_| format!("trigger {on}"))?,
        ),
        (Some("area"), Some(z), None) => {
            Trigger::Area(z.parse().map_err(|_| format!("trigger {on}"))?)
        }
        _ => return Err(format!("unknown trigger {on}")),
    })
}

fn min_difficulty(v: &Value, what: &str) -> Result<usize, String> {
    match v.as_str() {
        None => Ok(0),
        Some(d) => difficulty_index(d).ok_or_else(|| format!("{what}: unknown difficulty {d}")),
    }
}

fn spawn_entry(e: &Value, what: &str) -> Result<SpawnEntry, String> {
    let per_difficulty = |v: &Value| -> BTreeMap<usize, Value> {
        v.as_object()
            .into_iter()
            .flatten()
            .filter_map(|(d, x)| Some((difficulty_index(d)?, x.clone())))
            .collect()
    };
    Ok(SpawnEntry {
        mob: e["mob"].as_str().unwrap_or("").to_owned(),
        role: e["role"].as_str().unwrap_or("trash").to_owned(),
        count: e["count"].as_u64().unwrap_or(0) as u32,
        spread: f(&e["spread"], 3.0),
        at: point(&e["at"]),
        lvl: e["lvl"].as_i64().unwrap_or(0) as i32,
        assist: e["assist"].as_f64().map(|a| a as f32),
        boss_key: e["boss_key"].as_str().map(str::to_owned),
        template: e["template"].as_str().map(str::to_owned),
        min_difficulty: min_difficulty(&e["min_difficulty"], what)?,
        hatch: e["hatch"].is_object().then(|| Hatch {
            after_s: f(&e["hatch"]["after_s"], 45.0),
            into: e["hatch"]["into"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|i| {
                    (
                        i["mob"].as_str().unwrap_or("").to_owned(),
                        i["role"].as_str().unwrap_or("hatchling").to_owned(),
                    )
                })
                .collect(),
        }),
        harp: e["harp"].is_array().then(|| point(&e["harp"])),
        harp_scale: per_difficulty(&e["harp_scale"])
            .into_iter()
            .map(|(d, x)| (d, f(&x, 1.0)))
            .collect(),
        marks: per_difficulty(&e["marks"])
            .into_iter()
            .map(|(d, x)| (d, strings(&x)))
            .collect(),
    })
}

impl DungeonRules {
    pub fn from_json(file: &Value) -> Result<Self, String> {
        let d = without_notes(file);
        let mut rules = Self::default();
        for (i, id) in DIFFICULTIES.iter().enumerate() {
            let x = &d["difficulty"][*id];
            if !x.is_object() {
                return Err(format!("dungeons.json: difficulty {id} missing"));
            }
            let unlock_after = match x["unlock_after"].as_str().unwrap_or("") {
                "" => None,
                prior => Some(
                    difficulty_index(prior)
                        .filter(|p| *p < i)
                        .ok_or_else(|| format!("difficulty {id}: unlock_after {prior}"))?,
                ),
            };
            rules.difficulties.push(Difficulty {
                id: (*id).to_owned(),
                display: x["display"].as_str().unwrap_or(id).to_owned(),
                level_offset: x["level_offset"].as_i64().unwrap_or(0) as i32,
                hp: f(&x["hp"], 1.0),
                damage: f(&x["damage"], 1.0),
                mobs: f(&x["mobs"], 1.0),
                affixes: x["affixes"].as_u64().unwrap_or(0) as u8,
                min_party: x["min_party"].as_u64().unwrap_or(1) as u8,
                min_level_add: x["min_level_add"].as_u64().unwrap_or(0) as u16,
                death_penalty_s: f(&x["death_penalty_s"], 0.0),
                lives: x["lives"].as_i64().unwrap_or(-1) as i32,
                exp_budget: f(&x["exp_budget"], 0.2),
                kill_exp: f(&x["kill_exp"], 1.0),
                gold: f(&x["gold"], 1.0),
                drop: f(&x["drop"], 1.0),
                bonus_count: (
                    x["bonus_count"][0].as_u64().unwrap_or(0) as u8,
                    x["bonus_count"][1].as_u64().unwrap_or(0) as u8,
                ),
                tier_up: f(&x["tier_up"], 0.0),
                daily_rewards: x["daily_rewards"].as_i64().unwrap_or(-1) as i32,
                unlock_after,
                unlock_medal: medal_rank(x["unlock_medal"].as_str().unwrap_or("")),
                keys: x["keys"].as_u64().unwrap_or(0) as u32,
                par_mult: f(&x["par_mult"], 1.0),
                seals: x["seals"].as_u64().unwrap_or(0) as u32,
                telegraph: f(&x["telegraph"], 1.0),
                hazard_mult: f(&x["hazard_mult"], 1.0),
                boss_enrage_s: f(&x["boss_enrage_s"], 0.0),
            });
        }
        let g = &d["group"];
        rules.group = Group {
            max_party: g["max_party"].as_u64().unwrap_or(5) as usize,
            max_level_spread: g["max_level_spread"].as_u64().unwrap_or(15) as u16,
            ref_max_weight: f(&g["ref_max_weight"], 0.6),
            party_hp_trash: f(&g["party_hp_trash"], 0.35),
            party_hp_boss: f(&g["party_hp_boss"], 0.7),
            party_mobs: f(&g["party_mobs"], 0.12),
            party_exp_per_member: f(&g["party_exp_per_member"], 0.05),
            party_exp_cap: f(&g["party_exp_cap"], 0.2),
            gather_radius: f(&g["gather_radius"], 30.0),
            ready_s: f(&g["ready_s"], 30.0),
            countdown_s: f(&g["countdown_s"], 10.0),
        };
        for (id, r) in d["roles"].as_object().into_iter().flatten() {
            rules.roles.insert(
                id.clone(),
                Role {
                    lvl: r["lvl"].as_i64().unwrap_or(0) as i32,
                    forces: r["forces"].as_u64().unwrap_or(0) as u32,
                    boss_hp: r["party_hp"].as_str() == Some("boss"),
                },
            );
        }
        let m = &d["medals"];
        rules.medals = Medals {
            gold: f(&m["gold"], 1.0),
            silver: f(&m["silver"], 1.3),
            bronze: f(&m["bronze"], 1.6),
            limit: f(&m["limit"], 2.0),
        };
        let r = &d["rewards"];
        rules.rewards = Rewards {
            creature_drop: f(&r["creature_drop"], 0.75),
            completion_share: f(&r["completion_share"], 0.4),
            first_run_exp: f(&r["first_run_exp"], 1.25),
            oril_per_level: (
                r["oril_per_level"][0].as_u64().unwrap_or(40) as u32,
                r["oril_per_level"][1].as_u64().unwrap_or(80) as u32,
            ),
            medal_exp: by_medal(&r["medal_exp"], |v| f(v, 1.0), 1.0),
            medal_gold: by_medal(&r["medal_gold"], |v| f(v, 0.0), 0.0),
            medal_seals: by_medal(&r["medal_seals"], |v| v.as_u64().unwrap_or(0) as u32, 0),
            medal_item: by_medal(&r["medal_item"], |v| f(v, 0.0), 0.0),
            flawless_seals: r["flawless_seals"].as_u64().unwrap_or(0) as u32,
            key_drop: r["key_drop"]
                .as_object()
                .into_iter()
                .flatten()
                .filter_map(|(d, n)| Some((difficulty_index(d)?, n.as_u64()? as u32)))
                .collect(),
            shop: r["shop"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|s| {
                    (
                        s["item"].as_str().unwrap_or("").to_owned(),
                        s["amount"].as_u64().unwrap_or(1) as u32,
                        s["seals"].as_u64().unwrap_or(1) as u32,
                    )
                })
                .collect(),
        };
        for (id, x) in d["dungeons"].as_object().into_iter().flatten() {
            let mut steps = Vec::new();
            for s in x["steps"].as_array().into_iter().flatten() {
                let sid = s["id"].as_str().unwrap_or("").to_owned();
                let what = format!("dungeon {id} step {sid}");
                let mut spawn = Vec::new();
                for e in s["spawn"].as_array().into_iter().flatten() {
                    spawn.push(spawn_entry(e, &what)?);
                }
                steps.push(Step {
                    on: trigger(s["on"].as_str().unwrap_or("enter"))
                        .map_err(|e| format!("{what}: {e}"))?,
                    optional: s["optional"].as_bool().unwrap_or(false),
                    min_difficulty: min_difficulty(&s["min_difficulty"], &what)?,
                    spawn,
                    open: strings(&s["open"]),
                    close: strings(&s["close"]),
                    message: s["message"].as_str().unwrap_or("").to_owned(),
                    complete: s["complete"].as_bool().unwrap_or(false),
                    chest: s["chest"].is_object().then(|| {
                        (
                            s["chest"]["table"].as_str().unwrap_or("").to_owned(),
                            point(&s["chest"]["at"]),
                        )
                    }),
                    cocoon: s["cocoon"].is_object().then(|| Cocoon {
                        mob: s["cocoon"]["mob"].as_str().unwrap_or("").to_owned(),
                        hold_s: f(&s["cocoon"]["hold_s"], 12.0),
                        hp_share: f(&s["cocoon"]["hp_share"], 0.4),
                    }),
                    pools: s["pools"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .map(|p| Pool {
                            kind: p["kind"].as_str().unwrap_or("venom").to_owned(),
                            at: point(&p["at"]),
                            radius: f(&p["radius"], 4.0),
                            duration_s: f(&p["duration_s"], 20.0),
                            hp_share_s: f(&p["hp_share_s"], 0.0),
                        })
                        .collect(),
                    id: sid,
                });
            }
            rules.dungeons.insert(
                id.clone(),
                DungeonDef {
                    id: id.clone(),
                    map: x["map"].as_str().unwrap_or("").to_owned(),
                    display: x["display"].as_str().unwrap_or(id).to_owned(),
                    level_min: x["level_min"].as_u64().unwrap_or(1) as u16,
                    level_max: x["level_max"].as_u64().unwrap_or(100) as u16,
                    par_s: f(&x["par_s"], 600.0),
                    key: x["key"].as_str().unwrap_or("").to_owned(),
                    title: x["first_clear_title"].is_object().then(|| {
                        (
                            x["first_clear_title"]["id"]
                                .as_str()
                                .unwrap_or("")
                                .to_owned(),
                            x["first_clear_title"]["name"]
                                .as_str()
                                .unwrap_or("")
                                .to_owned(),
                        )
                    }),
                    hazards: x["hazards"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .map(|h| Hazard {
                            id: h["id"].as_str().unwrap_or("").to_owned(),
                            x: (f(&h["x"][0], -1.0e6), f(&h["x"][1], 1.0e6)),
                            z: (f(&h["z"][0], -1.0e6), f(&h["z"][1], 1.0e6)),
                            push: point(&h["push"]),
                            lift: f(&h["lift"], 0.0),
                            every_s: f(&h["every_s"], 7.0),
                            warn_s: f(&h["warn_s"], 1.5),
                            from_step: h["from_step"].as_str().unwrap_or("").to_owned(),
                            until_step: h["until_step"].as_str().unwrap_or("").to_owned(),
                            message: h["message"].as_str().unwrap_or("").to_owned(),
                        })
                        .collect(),
                    steps,
                },
            );
        }
        rules.check()?;
        Ok(rules)
    }

    fn check(&self) -> Result<(), String> {
        for d in self.dungeons.values() {
            let ids: Vec<&str> = d.steps.iter().map(|s| s.id.as_str()).collect();
            for s in &d.steps {
                match &s.on {
                    Trigger::Cleared(x) | Trigger::HpBelow(x, _) if !ids.contains(&x.as_str()) => {
                        return Err(format!("dungeon {} step {}: no step {x}", d.id, s.id));
                    }
                    _ => {}
                }
                for e in &s.spawn {
                    if !self.roles.contains_key(&e.role) {
                        return Err(format!("dungeon {} step {}: role {}", d.id, s.id, e.role));
                    }
                }
            }
        }
        Ok(())
    }

    /// The dungeon whose map is `map`.
    #[must_use]
    pub fn on_map(&self, map: &str) -> Option<&DungeonDef> {
        self.dungeons.values().find(|d| d.map == map)
    }

    /// The run's reference level for a party of these levels.
    #[must_use]
    pub fn ref_level(&self, def: &DungeonDef, levels: &[u16]) -> u16 {
        if levels.is_empty() {
            return def.level_min;
        }
        let max = f32::from(*levels.iter().max().unwrap_or(&1));
        let mean = levels.iter().map(|l| f32::from(*l)).sum::<f32>() / levels.len() as f32;
        let w = self.group.ref_max_weight;
        let r = (w * max + (1.0 - w) * mean).round() as u16;
        r.clamp(def.level_min, def.level_max)
    }

    /// A creature's level in a run.
    #[must_use]
    pub fn mob_level(
        &self,
        ref_level: u16,
        difficulty: usize,
        role: &str,
        entry_lvl: i32,
        max_level: u16,
    ) -> u32 {
        let d = &self.difficulties[difficulty];
        let r = self.roles.get(role).map_or(0, |r| r.lvl);
        (i32::from(ref_level) + d.level_offset + r + entry_lvl).clamp(1, i32::from(max_level))
            as u32
    }

    /// How many creatures a spawn entry fields.
    #[must_use]
    pub fn group_count(&self, entry: &SpawnEntry, difficulty: usize, party: usize) -> u32 {
        if entry.count == 0 || !matches!(entry.role.as_str(), "trash" | "elite") {
            return 1;
        }
        let d = &self.difficulties[difficulty];
        let party = party.max(1) as f32;
        let grow = d.mobs * (1.0 + self.group.party_mobs * (party - 1.0));
        let grow = if entry.role == "elite" {
            1.0 + (grow - 1.0) * 0.5
        } else {
            grow
        };
        ((entry.count as f32 * grow).round() as u32).max(1)
    }

    /// Health multiplier of a role in a run.
    #[must_use]
    pub fn hp_scale(&self, difficulty: usize, role: &str, party: usize) -> f32 {
        let d = &self.difficulties[difficulty];
        let per = if self.roles.get(role).is_some_and(|r| r.boss_hp) {
            self.group.party_hp_boss
        } else {
            self.group.party_hp_trash
        };
        d.hp * (1.0 + per * (party.max(1) as f32 - 1.0))
    }

    /// Kill and completion experience multiplier for the party.
    #[must_use]
    pub fn party_exp(&self, party: usize) -> f32 {
        1.0 + (self.group.party_exp_per_member * (party.max(1) as f32 - 1.0))
            .min(self.group.party_exp_cap)
    }

    /// The medal a run earned: needs a full clear and no broken lives.
    #[must_use]
    pub fn medal(&self, elapsed_s: f32, par_s: f32, full: bool, broken: bool) -> i8 {
        if !full || broken {
            return RANK_CLEAR;
        }
        let m = &self.medals;
        if elapsed_s <= par_s * m.gold {
            RANK_GOLD
        } else if elapsed_s <= par_s * m.silver {
            RANK_SILVER
        } else if elapsed_s <= par_s * m.bronze {
            RANK_BRONZE
        } else {
            RANK_CLEAR
        }
    }

    /// Whether `sheet` may run `dungeon` at `difficulty`.
    #[must_use]
    pub fn unlocked(&self, sheet: &CharacterSheet, dungeon: &str, difficulty: usize) -> bool {
        let Some(d) = self.difficulties.get(difficulty) else {
            return false;
        };
        match d.unlock_after {
            None => true,
            Some(prior) => sheet
                .dungeons
                .rank(dungeon, prior)
                .is_some_and(|r| r >= d.unlock_medal),
        }
    }

    /// Rewarded runs left today (-1: unlimited).
    #[must_use]
    pub fn rights_left(
        &self,
        sheet: &CharacterSheet,
        dungeon: &str,
        difficulty: usize,
        day: u32,
    ) -> i32 {
        let daily = self.difficulties[difficulty].daily_rewards;
        if daily < 0 {
            return -1;
        }
        (daily - i32::from(sheet.dungeons.used(dungeon, difficulty, day))).max(0)
    }
}

/// The reward day: it turns at 03:00 UTC.
#[must_use]
pub fn reward_day(unix_seconds: u64) -> u32 {
    (unix_seconds.saturating_sub(3 * 3600) / 86_400) as u32
}

/// One dungeon at one difficulty in a character's log.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DungeonRecord {
    pub dungeon: String,
    pub difficulty: u8,
    /// Best medal rank cleared (RANK_*), or -1 never cleared.
    pub rank: i8,
    /// Fastest full clear in milliseconds (0: none).
    pub best_ms: u32,
    /// The reward day of `rewarded` and how many rewarded runs it held.
    pub day: u32,
    pub rewarded: u8,
}

/// What a character keeps of its runs.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DungeonLog {
    pub records: Vec<DungeonRecord>,
    /// The last reward day it had a rewarded run (its first run of a day
    /// pays the first-run bonus).
    pub last_rewarded_day: u32,
    /// First-clear titles earned.
    pub titles: Vec<String>,
}

impl DungeonLog {
    fn get(&self, dungeon: &str, difficulty: usize) -> Option<&DungeonRecord> {
        self.records
            .iter()
            .find(|r| r.dungeon == dungeon && usize::from(r.difficulty) == difficulty)
    }

    fn entry(&mut self, dungeon: &str, difficulty: usize) -> &mut DungeonRecord {
        if let Some(i) = self
            .records
            .iter()
            .position(|r| r.dungeon == dungeon && usize::from(r.difficulty) == difficulty)
        {
            return &mut self.records[i];
        }
        self.records.push(DungeonRecord {
            dungeon: dungeon.to_owned(),
            difficulty: difficulty as u8,
            rank: -1,
            ..DungeonRecord::default()
        });
        self.records.last_mut().expect("just pushed")
    }

    /// The best rank cleared, if ever.
    #[must_use]
    pub fn rank(&self, dungeon: &str, difficulty: usize) -> Option<i8> {
        self.get(dungeon, difficulty)
            .map(|r| r.rank)
            .filter(|r| *r >= 0)
    }

    #[must_use]
    pub fn best_ms(&self, dungeon: &str, difficulty: usize) -> u32 {
        self.get(dungeon, difficulty).map_or(0, |r| r.best_ms)
    }

    /// Rewarded runs used on `day`.
    #[must_use]
    pub fn used(&self, dungeon: &str, difficulty: usize, day: u32) -> u8 {
        self.get(dungeon, difficulty)
            .filter(|r| r.day == day)
            .map_or(0, |r| r.rewarded)
    }

    /// Records a finished run: `rank` (RANK_* for a full clear, None for a
    /// run that did not clear), its time, and whether it was rewarded.
    pub fn record(
        &mut self,
        dungeon: &str,
        difficulty: usize,
        rank: Option<i8>,
        ms: u32,
        rewarded: bool,
        day: u32,
    ) {
        let r = self.entry(dungeon, difficulty);
        if let Some(rank) = rank {
            r.rank = r.rank.max(rank);
            if r.best_ms == 0 || ms < r.best_ms {
                r.best_ms = ms;
            }
        }
        if rewarded {
            if r.day != day {
                r.day = day;
                r.rewarded = 0;
            }
            r.rewarded = r.rewarded.saturating_add(1);
            self.last_rewarded_day = day;
        }
    }
}
