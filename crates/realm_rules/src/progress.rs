//! Growing a character: the experience a creature gives, the level gap that
//! scales it, the curve a level takes, what a level-up adds, and the
//! attribute points (Vitality, Intellect, Strength, Agility) a character
//! spends. Skill and attribute points are never stored: they follow from the
//! level and what has been spent.
//!
//! The old game's `HPRules` (pack_exp_reward, exp_threshold, level_gap,
//! attribute_points_available) and `authority._grant_exp`.

use std::collections::BTreeMap;

use serde_json::Value;

use crate::sheet::CharacterSheet;

/// One band of the level gap (mobs.json level_gap): from `min_diff`
/// (creature level - player level) up, experience and drop chances scale.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct GapBand {
    pub min_diff: i32,
    pub exp: f32,
    pub drop: f32,
}

/// What one attribute point gives (combat.json attributes.stats).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AttributeDef {
    pub id: String,
    /// Derived stat -> per point ("max_hp", "attack_value", "crit_chance"...).
    pub gives: BTreeMap<String, f32>,
}

#[derive(Clone, Debug, Default)]
pub struct ProgressRules {
    /// pack_tuning: exp_base + exp_per_level x L + exp_per_level_sq x L^2.
    pub exp_base: f32,
    pub exp_per_level: f32,
    pub exp_per_level_sq: f32,
    /// base_stats.exp_curve: a level takes this many kills of its level.
    pub kills_base: f32,
    pub kills_per_level: f32,
    pub max_level: u16,
    pub max_exp: u64,
    pub level_hp_gain: u32,
    pub level_mana_gain: u32,
    /// Bands sorted from the highest `min_diff` down.
    pub gap: Vec<GapBand>,
    pub elite_exp_mult: f32,
    /// Species -> exp_mult.
    pub exp_mult: BTreeMap<String, f32>,
    pub attribute_points_per_level: u32,
    pub attribute_cap: u8,
    pub attributes: Vec<AttributeDef>,
}

fn f(v: &Value, default: f32) -> f32 {
    v.as_f64().map_or(default, |x| x as f32)
}

impl ProgressRules {
    pub fn from_json(combat: &Value, mobs: &Value, spawns: &Value) -> Self {
        let t = &spawns["pack_tuning"];
        let base = &combat["base_stats"];
        let curve = &base["exp_curve"];
        let limits = &combat["limits"];
        let mut gap: Vec<GapBand> = mobs["level_gap"]["bands"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|b| GapBand {
                min_diff: b["min_diff"].as_i64().unwrap_or(-999) as i32,
                exp: f(&b["exp"], 1.0),
                drop: f(&b["drop"], 1.0),
            })
            .collect();
        gap.sort_by_key(|b| std::cmp::Reverse(b.min_diff));
        let attrs = &combat["attributes"];
        let attributes = attrs["stats"]
            .as_object()
            .into_iter()
            .flatten()
            .map(|(id, spec)| AttributeDef {
                id: id.clone(),
                gives: spec
                    .as_object()
                    .into_iter()
                    .flatten()
                    .filter_map(|(k, v)| v.as_f64().map(|x| (k.clone(), x as f32)))
                    .collect(),
            })
            .collect();
        Self {
            exp_base: f(&t["exp_base"], 20.0),
            exp_per_level: f(&t["exp_per_level"], 8.0),
            exp_per_level_sq: f(&t["exp_per_level_sq"], 0.0),
            kills_base: f(&curve["kills_base"], 10.0),
            kills_per_level: f(&curve["kills_per_level"], 10.0),
            max_level: limits["max_level"].as_u64().unwrap_or(100) as u16,
            max_exp: limits["max_exp"].as_u64().unwrap_or(2_000_000_000),
            level_hp_gain: base["level_hp_gain"].as_u64().unwrap_or(40) as u32,
            level_mana_gain: base["level_mana_gain"].as_u64().unwrap_or(25) as u32,
            gap,
            elite_exp_mult: f(&mobs["elite"]["exp_mult"], 1.0),
            exp_mult: mobs["mobs"]
                .as_object()
                .into_iter()
                .flatten()
                .map(|(id, m)| (id.clone(), f(&m["exp_mult"], 1.0)))
                .collect(),
            attribute_points_per_level: attrs["points_per_level"].as_u64().unwrap_or(2) as u32,
            attribute_cap: attrs["max"].as_u64().unwrap_or(90) as u8,
            attributes,
        }
    }

    /// The experience an ordinary creature of `level` gives.
    #[must_use]
    pub fn pack_exp(&self, level: u32) -> f32 {
        let l = level as f32;
        (self.exp_base + self.exp_per_level * l + self.exp_per_level_sq * l * l).round()
    }

    /// A pack creature's experience: its level's, its species' multiplier,
    /// an elite's.
    #[must_use]
    pub fn creature_exp(&self, species: &str, level: u32, elite: bool) -> u32 {
        let mult = self.exp_mult.get(species).copied().unwrap_or(1.0);
        let elite = if elite { self.elite_exp_mult } else { 1.0 };
        (self.pack_exp(level) * mult * elite) as u32
    }

    /// Experience needed to leave `level`: a level's creature x the kills a
    /// level takes, rounded to 10, capped.
    #[must_use]
    pub fn exp_threshold(&self, level: u16) -> u64 {
        let lv = u32::from(level.max(1));
        let kills = self.kills_base + self.kills_per_level * (lv - 1) as f32;
        let raw = (self.pack_exp(lv) * kills / 10.0).round() as u64 * 10;
        raw.min(self.max_exp)
    }

    /// The band for a creature of `mob_level` against a player of
    /// `player_level`.
    #[must_use]
    pub fn gap(&self, mob_level: u32, player_level: u16) -> GapBand {
        let diff = mob_level as i32 - i32::from(player_level);
        self.gap
            .iter()
            .copied()
            .find(|b| diff >= b.min_diff)
            .unwrap_or(GapBand {
                min_diff: i32::MIN,
                exp: 1.0,
                drop: 1.0,
            })
    }

    /// Adds `amount` experience; every level it fills raises the level, adds
    /// the level's health and mana and refills both. Returns the levels
    /// gained.
    pub fn grant_exp(&self, sheet: &mut CharacterSheet, amount: u64) -> u16 {
        sheet.exp = sheet.exp.saturating_add(amount).min(self.max_exp);
        let mut gained = 0;
        while sheet.level < self.max_level {
            let need = self.exp_threshold(sheet.level);
            if sheet.exp < need {
                break;
            }
            sheet.exp -= need;
            sheet.level += 1;
            sheet.base_max_hp += self.level_hp_gain;
            sheet.base_max_mana += self.level_mana_gain;
            gained += 1;
        }
        gained
    }

    /// Attribute points not yet spent.
    #[must_use]
    pub fn attribute_points(&self, sheet: &CharacterSheet) -> u32 {
        let earned = u32::from(sheet.level.max(1) - 1) * self.attribute_points_per_level;
        let spent: u32 = sheet.attributes.iter().map(|(_, n)| u32::from(*n)).sum();
        earned.saturating_sub(spent)
    }

    /// Spends one point on `stat`: "spent", or why not ("unknown",
    /// "no_points", "max").
    pub fn spend_attribute(&self, sheet: &mut CharacterSheet, stat: &str) -> &'static str {
        if !self.attributes.iter().any(|a| a.id == stat) {
            return "unknown";
        }
        if self.attribute_points(sheet) == 0 {
            return "no_points";
        }
        match sheet.attributes.iter_mut().find(|(s, _)| s == stat) {
            Some((_, n)) if *n >= self.attribute_cap => return "max",
            Some((_, n)) => *n += 1,
            None => sheet.attributes.push((stat.to_owned(), 1)),
        }
        "spent"
    }

    /// The attribute points' sum per derived stat.
    #[must_use]
    pub fn attribute_totals(&self, sheet: &CharacterSheet) -> BTreeMap<String, f32> {
        let mut out = BTreeMap::new();
        for (id, points) in &sheet.attributes {
            if let Some(def) = self.attributes.iter().find(|a| &a.id == id) {
                for (stat, per) in &def.gives {
                    *out.entry(stat.clone()).or_default() += per * f32::from(*points);
                }
            }
        }
        out
    }
}
