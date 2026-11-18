//! What a kill drops (loot_tables.json): oril rows are summed for the killer,
//! everything else goes into the one chest the kill leaves. Item chances
//! scale with the drop factor (level gap, the killer's drop chance, the
//! ordinary-creature `creature_drop`); `always` rows never do. Gear pieces
//! come from the level band below the creature, some with enchantment
//! bonuses.
//!
//! The old game's `mob_loot` / `roll_loot` and
//! `authority._roll_drops`.

use std::collections::BTreeMap;

use serde_json::Value;

use crate::Rules;
use crate::items::Dice;
use crate::sheet::{Bonus, Item};

/// One row: an item and its count range; `chance` None = always.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Row {
    pub id: String,
    pub chance: Option<f32>,
    pub min: u32,
    pub max: u32,
}

/// Gear and accessory chances (loot_tables.json gear, or a table's own).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct GearRules {
    pub accessory_chance: f32,
    pub chance: f32,
    pub elite_chance: f32,
    pub boss_chance: f32,
    pub monolith_chance: f32,
    pub level_band: u16,
    pub enchanted_chance: f32,
    /// Weight of 1, 2, 3... bonuses on an enchanted piece.
    pub bonus_count_weights: Vec<u32>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Table {
    pub always: Vec<Row>,
    pub rolls: Vec<Row>,
    pub boss_always: Vec<Row>,
    pub boss_rolls: Vec<Row>,
    /// Only the base table's `always` rows (goblins carry gold, not junk).
    pub no_base_rolls: bool,
    pub gear: Option<GearRules>,
}

#[derive(Clone, Debug, Default)]
pub struct LootRules {
    /// The base table every creature rolls (`mob`).
    pub base: Table,
    /// Species tables (`tables`), and the top-level ones (`monolith`, ...).
    pub tables: BTreeMap<String, Table>,
    pub elite: Table,
    pub gear: GearRules,
    /// Ordinary (non-boss) creatures' item chances are scaled by this.
    pub creature_drop: f32,
}

/// What a kill leaves.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Loot {
    pub oril: u64,
    pub items: Vec<Item>,
}

/// The kill being rolled for.
#[derive(Clone, Copy, Debug)]
pub struct Kill<'a> {
    /// The species' loot table (mobs.json `loot_table`), or a Dark Shard's.
    pub table: &'a str,
    pub level: u32,
    pub elite: bool,
    pub boss: bool,
    /// A Dark Shard: its own table only, unscaled, a ring and gear.
    pub stone: bool,
    /// Level gap x the killer's drop chance (x creature_drop is applied here
    /// for ordinary creatures).
    pub drop_factor: f32,
}

fn f(v: &Value, default: f32) -> f32 {
    v.as_f64().map_or(default, |x| x as f32)
}

fn rows(v: &Value) -> Vec<Row> {
    v.as_array()
        .into_iter()
        .flatten()
        .map(|r| Row {
            id: r["id"].as_str().unwrap_or("").to_owned(),
            chance: r["chance"].as_f64().map(|c| c as f32),
            min: r["min"].as_u64().unwrap_or(1) as u32,
            max: r["max"].as_u64().unwrap_or(1) as u32,
        })
        .collect()
}

fn gear(v: &Value, base: &GearRules) -> GearRules {
    GearRules {
        accessory_chance: f(&v["accessory_chance"], base.accessory_chance),
        chance: f(&v["chance"], base.chance),
        elite_chance: f(&v["elite_chance"], base.elite_chance),
        boss_chance: f(&v["boss_chance"], base.boss_chance),
        monolith_chance: f(&v["monolith_chance"], base.monolith_chance),
        level_band: v["level_band"]
            .as_u64()
            .map_or(base.level_band, |b| b as u16),
        enchanted_chance: f(&v["enchanted_chance"], base.enchanted_chance),
        bonus_count_weights: v["bonus_count_weights"].as_array().map_or_else(
            || base.bonus_count_weights.clone(),
            |a| {
                a.iter()
                    .filter_map(Value::as_u64)
                    .map(|w| w as u32)
                    .collect()
            },
        ),
    }
}

fn table(v: &Value, base_gear: &GearRules) -> Table {
    Table {
        always: rows(&v["always"]),
        rolls: rows(&v["rolls"]),
        boss_always: rows(&v["boss_always"]),
        boss_rolls: rows(&v["boss_rolls"]),
        no_base_rolls: v["no_base_rolls"].as_bool().unwrap_or(false),
        gear: v["gear"].is_object().then(|| gear(&v["gear"], base_gear)),
    }
}

impl LootRules {
    pub fn from_json(loot: &Value) -> Self {
        let base_gear = gear(&loot["gear"], &GearRules::default());
        let mut tables = BTreeMap::new();
        for (key, t) in loot["tables"].as_object().into_iter().flatten() {
            tables.insert(key.clone(), table(t, &base_gear));
        }
        // Dark Shard and dungeon tables sit at the top level.
        for (key, t) in loot.as_object().into_iter().flatten() {
            if !key.starts_with('_')
                && ![
                    "mob",
                    "tables",
                    "elite",
                    "gear",
                    "respawn_ms",
                    "creature_drop",
                ]
                .contains(&key.as_str())
                && t.is_object()
                && (t["always"].is_array() || t["rolls"].is_array())
            {
                tables.insert(key.clone(), table(t, &base_gear));
            }
        }
        Self {
            base: table(&loot["mob"], &base_gear),
            tables,
            elite: table(&loot["elite"], &base_gear),
            gear: base_gear,
            creature_drop: f(&loot["creature_drop"], 1.0),
        }
    }
}

impl Rules {
    /// Rolls a kill's loot.
    pub fn roll_loot(&self, kill: &Kill, dice: &mut dyn Dice) -> Loot {
        let l = &self.loot;
        let mut out = Loot::default();
        let species = l.tables.get(kill.table);
        let gear = species
            .and_then(|t| t.gear.clone())
            .unwrap_or_else(|| l.gear.clone());
        if kill.stone {
            let t = species.or_else(|| l.tables.get("monolith"));
            if let Some(t) = t {
                self.roll_rows(&t.always, 1.0, &mut out, dice);
                self.roll_rows(&t.rolls, 1.0, &mut out, dice);
            }
            // A Dark Shard always has a chance at a ring of its level.
            if dice.unit() < 0.25
                && let Some(ring) = self.pick_accessory(kill.level, gear.level_band, true, dice)
            {
                out.items.push(self.new_item(&ring, 1));
            }
            if dice.unit() < gear.monolith_chance {
                self.roll_gear(kill.level, &gear, &mut out, dice);
            }
            merge(&mut out.items, self);
            return out;
        }
        let df = kill.drop_factor * if kill.boss { 1.0 } else { l.creature_drop };
        let no_base = species.is_some_and(|t| t.no_base_rolls);
        self.roll_rows(&l.base.always, 1.0, &mut out, dice);
        if !no_base {
            self.roll_rows(&l.base.rolls, df, &mut out, dice);
        }
        if let Some(t) = species {
            self.roll_rows(&t.always, 1.0, &mut out, dice);
            self.roll_rows(&t.rolls, df, &mut out, dice);
        }
        if kill.elite {
            self.roll_rows(&l.elite.always, 1.0, &mut out, dice);
            self.roll_rows(&l.elite.rolls, df, &mut out, dice);
        }
        if kill.boss {
            self.roll_rows(&l.base.boss_always, 1.0, &mut out, dice);
            self.roll_rows(&l.base.boss_rolls, df, &mut out, dice);
        }
        // An accessory: always from a boss.
        if (kill.boss || dice.unit() < gear.accessory_chance * df)
            && let Some(id) = self.pick_accessory(kill.level, gear.level_band, false, dice)
        {
            out.items.push(self.new_item(&id, 1));
        }
        let chance = if kill.boss {
            gear.boss_chance
        } else if kill.elite {
            gear.elite_chance * df
        } else {
            gear.chance * df
        };
        if dice.unit() < chance {
            self.roll_gear(kill.level, &gear, &mut out, dice);
        }
        merge(&mut out.items, self);
        out
    }

    fn roll_rows(&self, rows: &[Row], factor: f32, out: &mut Loot, dice: &mut dyn Dice) {
        for row in rows {
            if let Some(chance) = row.chance
                && dice.unit() >= chance * factor
            {
                continue;
            }
            let span = row.max.saturating_sub(row.min) + 1;
            let amount = row.min + dice.below(span);
            if amount == 0 {
                continue;
            }
            if row.id == "oril" {
                out.oril += u64::from(amount);
            } else if self.item(&row.id).is_some() {
                out.items.push(self.new_item(&row.id, amount));
            }
        }
    }

    /// The pieces dropped at `level`: required level in (level - band,
    /// level], else the lowest there is.
    fn band(&self, level: u32, band: u16, accept: impl Fn(&crate::ItemDef) -> bool) -> Vec<String> {
        let level = level.min(u32::from(u16::MAX)) as u16;
        let fits: Vec<&crate::ItemDef> = self.items.values().filter(|d| accept(d)).collect();
        let mut pool: Vec<String> = fits
            .iter()
            .filter(|d| d.required_level <= level && d.required_level + band > level)
            .map(|d| d.id.clone())
            .collect();
        if pool.is_empty() {
            let lowest = fits.iter().map(|d| d.required_level).min();
            pool = fits
                .iter()
                .filter(|d| Some(d.required_level) == lowest)
                .map(|d| d.id.clone())
                .collect();
        }
        pool
    }

    fn pick_accessory(
        &self,
        level: u32,
        band: u16,
        ring: bool,
        dice: &mut dyn Dice,
    ) -> Option<String> {
        let pool = self.band(level, band, |d| {
            d.kind == "accessory" && (!ring || d.slots.contains(&crate::Slot::RingLeft))
        });
        (!pool.is_empty()).then(|| pool[dice.below(pool.len() as u32) as usize].clone())
    }

    /// A gear piece from the level band, enchanted with 1..N bonuses at the
    /// table's chance.
    /// A dungeon chest's gear piece at `level` with exactly `count`
    /// enchantments (30 % of the time an accessory instead).
    pub fn dungeon_gear(&self, level: u32, count: u8, dice: &mut dyn Dice) -> Option<Item> {
        let band = self.loot.gear.level_band;
        if dice.unit() < 0.3
            && let Some(id) = self.pick_accessory(level, band, false, dice)
        {
            return Some(self.new_item(&id, 1));
        }
        let pool = self.band(level, band, |d| {
            d.kind != "accessory" && self.enchantable(&d.id)
        });
        if pool.is_empty() {
            return None;
        }
        let id = pool[dice.below(pool.len() as u32) as usize].clone();
        let mut item = self.new_item(&id, 1);
        let mut bonuses: Vec<Bonus> = Vec::new();
        for _ in 0..count {
            if let Some(b) = self.roll_bonus(&id, &bonuses, dice) {
                bonuses.push(b);
            }
        }
        item.bonuses = bonuses;
        Some(item)
    }

    fn roll_gear(&self, level: u32, gear: &GearRules, out: &mut Loot, dice: &mut dyn Dice) {
        let pool = self.band(level, gear.level_band, |d| {
            d.kind != "accessory" && self.enchantable(&d.id)
        });
        if pool.is_empty() {
            return;
        }
        let id = pool[dice.below(pool.len() as u32) as usize].clone();
        let mut item = self.new_item(&id, 1);
        if dice.unit() < gear.enchanted_chance {
            let total: u32 = gear.bonus_count_weights.iter().sum();
            let mut pick = dice.below(total.max(1));
            let mut count = 1;
            for (i, w) in gear.bonus_count_weights.iter().enumerate() {
                if pick < *w {
                    count = i + 1;
                    break;
                }
                pick -= w;
            }
            let mut bonuses: Vec<Bonus> = Vec::new();
            for _ in 0..count {
                if let Some(b) = self.roll_bonus(&id, &bonuses, dice) {
                    bonuses.push(b);
                }
            }
            item.bonuses = bonuses;
        }
        out.items.push(item);
    }
}

/// Stackable rows of the same item become one stack.
fn merge(items: &mut Vec<Item>, rules: &Rules) {
    let mut out: Vec<Item> = Vec::new();
    for item in items.drain(..) {
        if rules.stackable(&item.id)
            && let Some(held) = out.iter_mut().find(|h| h.id == item.id && h.uid == 0)
        {
            held.amount = held
                .amount
                .saturating_add(item.amount)
                .min(crate::MAX_STACK);
            continue;
        }
        out.push(item);
    }
    *items = out;
}
