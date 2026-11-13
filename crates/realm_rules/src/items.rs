//! Items: an item's stats at a refine level, what a character's gear adds up
//! to, and every item operation (move, use, sell, destroy, buy, refine,
//! enchant) as an all-or-nothing change to a sheet.
//!
//! The rules are the old game's (equipment.gd and the authority's equipment
//! requests), with one change of model: bag cells are server state, so moving
//! things around the bag is an operation too, and equip / unequip are moves
//! between a bag cell and a slot.

use std::collections::BTreeMap;

use realm_data::{Content, without_notes};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::sheet::{BAG_SLOTS, Bonus, CharacterSheet, Item, MAX_STACK, Slot};
use crate::{ItemDef, Rules};

/// Fixed stats that are percentages or per-second rates: they never grow
/// with +N.
pub const FIXED_PERCENT: [&str; 5] = [
    "attack_speed",
    "move_speed",
    "spell_power",
    "hp_regen",
    "mana_regen",
];

/// Highest refinement.
pub const MAX_TIER: u8 = 9;

/// Where an item sits: a bag cell or an equipment slot.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Cell {
    Bag(u8),
    Worn(Slot),
}

/// What the player asks to do with items.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum ItemOp {
    /// Bag to bag (move, swap, merge stacks), bag to slot (equip), slot to
    /// bag (unequip), slot to slot (the two rings).
    Move { from: Cell, to: Cell },
    /// Drink a potion.
    Use { cell: u8 },
    /// Sell a whole bag cell to the merchant.
    Sell { cell: u8 },
    /// Throw a whole bag cell away.
    Destroy { cell: u8 },
    /// Buy an item that has a price (Hearth Dust at a hearth).
    Buy { item: String, amount: u16 },
    /// Refine one step (+N).
    Refine { target: Cell },
    /// Use the scroll in `scroll` on `target`.
    Enchant { scroll: u8, target: Cell },
}

impl ItemOp {
    /// Changes what the character wears or trades, so not in the middle of a
    /// fight (moving inside the bag, drinking and throwing away are fine).
    fn needs_peace(&self) -> bool {
        match self {
            Self::Move { from, to } => matches!(from, Cell::Worn(_)) || matches!(to, Cell::Worn(_)),
            Self::Use { .. } | Self::Destroy { .. } => false,
            Self::Sell { .. } | Self::Buy { .. } | Self::Refine { .. } | Self::Enchant { .. } => {
                true
            }
        }
    }
}

/// The server's view of the moment, for the operation's gates.
#[derive(Clone, Copy, Debug, Default)]
pub struct ItemContext {
    pub dead: bool,
    /// Hit or attacking within the last few seconds.
    pub in_combat: bool,
    pub casting: bool,
    pub mounted: bool,
    /// Standing at a shop that sells what is bought (a hearth for Hearth
    /// Dust).
    pub at_shop: bool,
}

/// What a successful operation did: a reason word for the client's message
/// and an amount (oril earned, points restored) where it has one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Done {
    pub reason: &'static str,
    pub amount: i64,
}

/// Randomness for refining and enchanting; the server rolls.
pub trait Dice {
    /// Uniform in [0, 1).
    fn unit(&mut self) -> f32;
    /// Uniform in 0..n (n > 0).
    fn below(&mut self, n: u32) -> u32 {
        ((self.unit() * n as f32) as u32).min(n.saturating_sub(1))
    }
}

#[derive(Clone, Debug)]
pub struct RefineStep {
    pub chance: f32,
    pub cost: u64,
    pub material: String,
    pub amount: u32,
    /// Weapon damage and range multiplier at this tier.
    pub multiplier: f32,
}

#[derive(Clone, Debug, Default)]
pub struct StatSpec {
    pub label: String,
    pub unit: String,
    pub values: Vec<f32>,
    pub theme: String,
    pub disabled: bool,
    pub flag: bool,
}

#[derive(Clone, Debug, Default)]
pub struct EnchantRules {
    pub max_bonuses: usize,
    pub imbue_scroll: String,
    pub reweave_scroll: String,
    pub imbue_chance: Vec<f32>,
    pub grade_weights: Vec<u32>,
    pub stats: BTreeMap<String, StatSpec>,
    pub pools: BTreeMap<String, Vec<String>>,
    pub slot_kinds: BTreeMap<String, String>,
    pub slot_themes: BTreeMap<String, Vec<String>>,
}

#[derive(Clone, Debug)]
pub struct Hearth {
    pub map: String,
    pub x: f32,
    pub z: f32,
}

#[derive(Clone, Debug, Default)]
pub struct ItemRules {
    pub steps: Vec<RefineStep>,
    pub refinable_types: Vec<String>,
    pub fail_downgrade_from: u8,
    pub stat_mult: Vec<f32>,
    pub armor_mult: Vec<f32>,
    pub mount_speed_mult: Vec<f32>,
    pub enchant: EnchantRules,
    pub sell_by_rarity: BTreeMap<String, u64>,
    pub move_speed_range: (f32, f32),
    pub attack_speed_cap: f32,
    pub cast_speed_cap: f32,
    pub hearths: Vec<Hearth>,
    /// How far from a hearth its shop still sells.
    pub hearth_shop_radius: f32,
}

fn f(v: &Value) -> f32 {
    v.as_f64().unwrap_or(0.0) as f32
}

fn floats(v: &Value) -> Vec<f32> {
    v.as_array()
        .map(|a| a.iter().map(f).collect())
        .unwrap_or_default()
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array()
        .map(|a| {
            a.iter()
                .filter_map(|s| s.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}

fn range(v: &Value) -> Option<(f32, f32)> {
    let a = v.as_array()?;
    (a.len() >= 2).then(|| (f(&a[0]), f(&a[1])))
}

/// Reads the item numbers into `ItemDef`s (called by `Rules::from_content`).
pub(crate) fn read_item(def: &mut ItemDef, raw: &Value) {
    def.rarity = raw["rarity"].as_str().unwrap_or("common").to_owned();
    def.required_level = raw["required_level"].as_u64().unwrap_or(1).max(1) as u16;
    def.buy_price = raw["buy_price"].as_u64();
    def.sell_price = raw["sell_price"].as_u64();
    def.attack_value = range(&raw["attack_value"]);
    def.magic_attack = range(&raw["magic_attack"]);
    def.armor = f(&raw["armor"]);
    def.bonus_hp = f(&raw["bonus_hp"]);
    def.bonus_mana = f(&raw["bonus_mana"]);
    for key in FIXED_PERCENT {
        let value = f(&raw[key]);
        if value != 0.0 {
            def.percent.insert(key.to_owned(), value);
        }
    }
    def.mount_speed = raw["mount_speed"].as_f64().map(|v| v as f32);
    def.heal_hp = raw["heal_hp"].as_u64().unwrap_or(0) as u32;
    def.heal_mana = raw["heal_mana"].as_u64().unwrap_or(0) as u32;
}

impl ItemRules {
    pub(crate) fn from_content(content: &Content) -> Result<Self, String> {
        let combat = without_notes(
            content
                .file("combat.json")
                .ok_or("content has no combat.json")?,
        );
        let mut steps = Vec::new();
        for step in combat["wand_tiers"].as_array().into_iter().flatten() {
            steps.push(RefineStep {
                chance: f(&step["chance"]),
                cost: step["cost"].as_u64().unwrap_or(0),
                material: step["material_id"].as_str().unwrap_or("").to_owned(),
                amount: step["material_amount"].as_u64().unwrap_or(1) as u32,
                multiplier: step["multiplier"].as_f64().unwrap_or(1.0) as f32,
            });
        }
        if steps.len() < usize::from(MAX_TIER) + 1 {
            return Err(format!(
                "combat.json wand_tiers: {} steps, need {}",
                steps.len(),
                MAX_TIER + 1
            ));
        }
        let curves = &combat["upgrade_curves"];
        let e = &combat["enchant"];
        let mut enchant = EnchantRules {
            max_bonuses: e["max_bonuses"].as_u64().unwrap_or(5) as usize,
            imbue_scroll: e["imbue_scroll"].as_str().unwrap_or("").to_owned(),
            reweave_scroll: e["reweave_scroll"].as_str().unwrap_or("").to_owned(),
            imbue_chance: floats(&e["imbue_chance"]),
            grade_weights: floats(&e["grade_weights"])
                .into_iter()
                .map(|w| w as u32)
                .collect(),
            ..EnchantRules::default()
        };
        for (stat, spec) in e["stats"].as_object().into_iter().flatten() {
            enchant.stats.insert(
                stat.clone(),
                StatSpec {
                    label: spec["label"].as_str().unwrap_or(stat).to_owned(),
                    unit: spec["unit"].as_str().unwrap_or("").to_owned(),
                    values: floats(&spec["values"]),
                    theme: spec["theme"].as_str().unwrap_or("").to_owned(),
                    disabled: spec["disabled"].as_bool().unwrap_or(false),
                    flag: spec["flag"].as_bool().unwrap_or(false),
                },
            );
        }
        for (kind, pool) in e["pools"].as_object().into_iter().flatten() {
            enchant.pools.insert(kind.clone(), strings(pool));
        }
        for (slot, kind) in e["slot_kinds"].as_object().into_iter().flatten() {
            enchant
                .slot_kinds
                .insert(slot.clone(), kind.as_str().unwrap_or("").to_owned());
        }
        for (kind, themes) in e["slot_themes"].as_object().into_iter().flatten() {
            enchant.slot_themes.insert(kind.clone(), strings(themes));
        }
        let caps = &combat["item_stats"];
        let mut sell_by_rarity = BTreeMap::new();
        for (rarity, price) in caps["sell_by_rarity"].as_object().into_iter().flatten() {
            sell_by_rarity.insert(rarity.clone(), price.as_u64().unwrap_or(0));
        }
        let travel = without_notes(
            content
                .file("travel.json")
                .ok_or("content has no travel.json")?,
        );
        let mut hearths = Vec::new();
        for node in travel["nodes"]
            .as_object()
            .into_iter()
            .flatten()
            .map(|n| n.1)
        {
            if node["kind"].as_str() == Some("hearthway") {
                hearths.push(Hearth {
                    map: node["map"].as_str().unwrap_or("").to_owned(),
                    x: f(&node["pos"][0]),
                    z: f(&node["pos"][2]),
                });
            }
        }
        Ok(Self {
            steps,
            refinable_types: strings(&curves["refinable_types"]),
            fail_downgrade_from: curves["fail_downgrade_from"].as_u64().unwrap_or(4) as u8,
            stat_mult: floats(&curves["stat_mult"]),
            armor_mult: floats(&curves["armor_mult"]),
            mount_speed_mult: floats(&curves["mount"]["speed_mult"]),
            enchant,
            sell_by_rarity,
            move_speed_range: (
                caps["move_speed_min"].as_f64().unwrap_or(-20.0) as f32,
                caps["move_speed_max"].as_f64().unwrap_or(40.0) as f32,
            ),
            attack_speed_cap: caps["attack_speed_cap"].as_f64().unwrap_or(100.0) as f32,
            cast_speed_cap: caps["cast_speed_cap"].as_f64().unwrap_or(40.0) as f32,
            hearth_shop_radius: travel["hearthway"]["radius"].as_f64().unwrap_or(3.8) as f32 * 2.0,
            hearths,
        })
    }
}

fn at(values: &[f32], tier: u8) -> f32 {
    if values.is_empty() {
        1.0
    } else {
        values[usize::from(tier).min(values.len() - 1)]
    }
}

/// One item's fixed stats at refine level `tier`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ItemStats {
    pub bonus_hp: f32,
    pub bonus_mana: f32,
    pub armor: f32,
    /// Scaled by the +N multiplier (for display; damage scales the spell).
    pub attack_value: Option<(f32, f32)>,
    pub magic_attack: Option<(f32, f32)>,
    pub percent: BTreeMap<String, f32>,
    pub mount_speed: Option<f32>,
}

/// What everything worn adds up to.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Derived {
    pub max_hp: u32,
    pub max_mana: u32,
    pub armor: f32,
    pub wand_tier: u8,
    /// The wand's +0 ranges (damage applies the +N multiplier).
    pub attack_value: (f32, f32),
    pub magic_attack: (f32, f32),
    pub mount_speed: f32,
    /// 1 + spell power / 100.
    pub weapon_multiplier: f32,
    /// Every enchantment stat and fixed percent stat, summed and capped.
    pub stats: BTreeMap<String, f32>,
}

impl Rules {
    #[must_use]
    pub fn item(&self, id: &str) -> Option<&ItemDef> {
        self.items.get(id)
    }

    #[must_use]
    pub fn fits(&self, id: &str, slot: Slot) -> bool {
        self.item(id).is_some_and(|d| d.slots.contains(&slot))
    }

    #[must_use]
    pub fn refinable(&self, id: &str) -> bool {
        self.item(id)
            .is_some_and(|d| self.item_rules.refinable_types.contains(&d.kind))
    }

    fn slot_kind(&self, id: &str) -> Option<&String> {
        let slot = self.item(id)?.slots.first()?;
        self.item_rules.enchant.slot_kinds.get(slot.name())
    }

    #[must_use]
    pub fn enchantable(&self, id: &str) -> bool {
        self.slot_kind(id)
            .and_then(|k| self.item_rules.enchant.pools.get(k))
            .is_some_and(|p| !p.is_empty())
    }

    /// One item's fixed stats at refine level `tier`.
    #[must_use]
    pub fn item_stats(&self, id: &str, tier: u8) -> ItemStats {
        let Some(def) = self.item(id) else {
            return ItemStats::default();
        };
        let r = &self.item_rules;
        let stat_mult = if def.kind == "mount" {
            1.0
        } else {
            at(&r.stat_mult, tier)
        };
        let weapon = r.steps.get(usize::from(tier)).map_or(1.0, |s| s.multiplier);
        let scale = |span: Option<(f32, f32)>| {
            span.map(|(a, b)| ((a * weapon).round(), (b * weapon).round()))
        };
        ItemStats {
            bonus_hp: (def.bonus_hp * stat_mult).round(),
            bonus_mana: (def.bonus_mana * stat_mult).round(),
            armor: (def.armor * at(&r.armor_mult, tier)).round(),
            attack_value: scale(def.attack_value),
            magic_attack: scale(def.magic_attack),
            percent: def.percent.clone(),
            mount_speed: (def.kind == "mount")
                .then(|| def.mount_speed.unwrap_or(16.0) * at(&r.mount_speed_mult, tier)),
        }
    }

    /// Stats an item carries as fixed stats (never rolled as enchantments).
    fn fixed_stat_keys(&self, id: &str) -> Vec<&str> {
        let Some(def) = self.item(id) else {
            return Vec::new();
        };
        let mut keys: Vec<&str> = def.percent.keys().map(String::as_str).collect();
        if def.bonus_hp > 0.0 {
            keys.push("max_hp");
        }
        if def.bonus_mana > 0.0 {
            keys.push("max_mana");
        }
        keys
    }

    /// Everything worn, summed: fixed item stats and enchantments.
    #[must_use]
    pub fn derived(&self, sheet: &CharacterSheet) -> Derived {
        let r = &self.item_rules;
        let mut out = Derived {
            max_hp: sheet.base_max_hp,
            max_mana: sheet.base_max_mana,
            weapon_multiplier: 1.0,
            ..Derived::default()
        };
        for stat in r.enchant.stats.keys() {
            out.stats.insert(stat.clone(), 0.0);
        }
        for key in FIXED_PERCENT {
            out.stats.insert(key.to_owned(), 0.0);
        }
        let (mut hp, mut mana) = (sheet.base_max_hp as f32, sheet.base_max_mana as f32);
        for slot in Slot::ALL {
            let Some(worn) = sheet.equipped(slot) else {
                continue;
            };
            if !self.fits(&worn.id, slot) {
                continue;
            }
            let n = self.item_stats(&worn.id, worn.tier);
            hp += n.bonus_hp;
            mana += n.bonus_mana;
            out.armor += n.armor;
            for (key, value) in &n.percent {
                *out.stats.entry(key.clone()).or_default() += value;
            }
            if slot == Slot::MainHand {
                out.wand_tier = worn.tier;
                if let Some(def) = self.item(&worn.id) {
                    out.attack_value = def.attack_value.unwrap_or_default();
                    out.magic_attack = def.magic_attack.unwrap_or_default();
                }
            }
            if slot == Slot::Broom {
                out.mount_speed = n.mount_speed.unwrap_or(0.0);
            }
            for bonus in &worn.bonuses {
                match bonus.stat.as_str() {
                    "max_hp" => hp += bonus.value,
                    "max_mana" => mana += bonus.value,
                    // a legacy broom enchantment, percent of the broom's speed
                    "mount_speed" => out.mount_speed *= 1.0 + bonus.value / 100.0,
                    stat => *out.stats.entry(stat.to_owned()).or_default() += bonus.value,
                }
            }
        }
        out.max_hp = hp.round().max(1.0) as u32;
        out.max_mana = mana.round().max(0.0) as u32;
        let stat = |out: &mut Derived, key: &str, lo: f32, hi: f32| {
            let v = out.stats.get(key).copied().unwrap_or(0.0).clamp(lo, hi);
            out.stats.insert(key.to_owned(), v);
        };
        stat(
            &mut out,
            "move_speed",
            r.move_speed_range.0,
            r.move_speed_range.1,
        );
        stat(&mut out, "attack_speed", 0.0, r.attack_speed_cap);
        stat(&mut out, "cast_speed", 0.0, r.cast_speed_cap);
        stat(&mut out, "defense", 0.0, 50.0);
        out.weapon_multiplier = 1.0 + out.stats.get("spell_power").copied().unwrap_or(0.0) / 100.0;
        out
    }

    /// What a merchant pays for one piece: by rarity (or the item's own
    /// `sell_price`), +50 % per refinement tier; stackables fetch a tenth.
    #[must_use]
    pub fn sell_price(&self, id: &str, tier: u8) -> u64 {
        let Some(def) = self.item(id) else {
            return 0;
        };
        let mut base = def.sell_price.unwrap_or_else(|| {
            self.item_rules
                .sell_by_rarity
                .get(&def.rarity)
                .copied()
                .unwrap_or(40)
        });
        if def.sell_price.is_none() && def.stackable {
            base = (base / 10).max(1);
        }
        (base as f64 * (1.0 + 0.5 * f64::from(tier))).round() as u64
    }

    /// Whether `x, z` on `map` is at a hearth's shop.
    #[must_use]
    pub fn at_hearth(&self, map: &str, x: f32, z: f32) -> bool {
        let r = self.item_rules.hearth_shop_radius;
        self.item_rules
            .hearths
            .iter()
            .any(|h| h.map == map && (h.x - x).powi(2) + (h.z - z).powi(2) <= r * r)
    }

    /// Applies `op` to `sheet`, all or nothing. `hp` / `mana` are the live
    /// values (a potion changes them). On success the sheet's revision is
    /// bumped.
    pub fn apply_item_op(
        &self,
        sheet: &mut CharacterSheet,
        op: &ItemOp,
        ctx: ItemContext,
        dice: &mut dyn Dice,
    ) -> Result<Done, &'static str> {
        if ctx.dead {
            return Err("dead");
        }
        if ctx.casting && !matches!(op, ItemOp::Use { .. }) {
            return Err("casting");
        }
        if ctx.in_combat && op.needs_peace() {
            return Err("in_combat");
        }
        let mut next = sheet.clone();
        next.normalize();
        let done = match op {
            ItemOp::Move { from, to } => self.move_item(&mut next, *from, *to, ctx)?,
            ItemOp::Use { cell } => self.use_item(&mut next, *cell)?,
            ItemOp::Sell { cell } => {
                let item = take_cell(&mut next, *cell)?;
                let price = self.sell_price(&item.id, item.tier) * u64::from(item.amount);
                if price == 0 {
                    return Err("not_sellable");
                }
                next.oril += price;
                Done {
                    reason: "sold",
                    amount: price as i64,
                }
            }
            ItemOp::Destroy { cell } => {
                take_cell(&mut next, *cell)?;
                Done {
                    reason: "destroyed",
                    amount: 0,
                }
            }
            ItemOp::Buy { item, amount } => self.buy(&mut next, item, *amount, ctx)?,
            ItemOp::Refine { target } => self.refine(&mut next, *target, dice)?,
            ItemOp::Enchant { scroll, target } => {
                self.enchant(&mut next, *scroll, *target, dice)?
            }
        };
        next.revision += 1;
        *sheet = next;
        Ok(done)
    }

    fn move_item(
        &self,
        sheet: &mut CharacterSheet,
        from: Cell,
        to: Cell,
        ctx: ItemContext,
    ) -> Result<Done, &'static str> {
        if from == to {
            return Err("nothing_to_do");
        }
        let moving = get(sheet, from)?.clone().ok_or("item_missing")?;
        let there = get(sheet, to)?.clone();
        // Anything going into a slot must fit it and its wearer.
        for (item, cell) in [(Some(&moving), to), (there.as_ref(), from)] {
            if let (Some(item), Cell::Worn(slot)) = (item, cell) {
                if !self.fits(&item.id, slot) {
                    return Err("wrong_slot");
                }
                if self
                    .item(&item.id)
                    .is_some_and(|d| d.required_level > sheet.level)
                {
                    return Err("level_too_low");
                }
            }
        }
        if ctx.mounted && (from == Cell::Worn(Slot::Broom) || to == Cell::Worn(Slot::Broom)) {
            return Err("mounted");
        }
        // Two stacks of the same thing in the bag merge.
        if let (Cell::Bag(_), Cell::Bag(_), Some(dest)) = (from, to, &there)
            && dest.uid == 0
            && moving.uid == 0
            && dest.id == moving.id
            && dest.tier == moving.tier
        {
            let room = MAX_STACK.saturating_sub(dest.amount);
            if room == 0 {
                return Err("stack_full");
            }
            let carried = room.min(moving.amount);
            let mut merged = dest.clone();
            merged.amount += carried;
            *get(sheet, to)? = Some(merged);
            let rest = moving.amount - carried;
            *get(sheet, from)? = (rest > 0).then(|| Item {
                amount: rest,
                ..moving.clone()
            });
            return Ok(Done {
                reason: "moved",
                amount: 0,
            });
        }
        *get(sheet, to)? = Some(moving);
        *get(sheet, from)? = there;
        let reason = match (from, to) {
            (Cell::Bag(_), Cell::Worn(_)) => "equipped",
            (Cell::Worn(_), Cell::Bag(_)) => "unequipped",
            _ => "moved",
        };
        Ok(Done { reason, amount: 0 })
    }

    fn use_item(&self, sheet: &mut CharacterSheet, cell: u8) -> Result<Done, &'static str> {
        let item = get(sheet, Cell::Bag(cell))?.clone().ok_or("item_missing")?;
        let def = self.item(&item.id).ok_or("item_missing")?;
        let derived = self.derived(sheet);
        let (current, maximum, heal) = if def.heal_hp > 0 {
            (&mut sheet.hp, derived.max_hp, def.heal_hp)
        } else if def.heal_mana > 0 {
            (&mut sheet.mana, derived.max_mana, def.heal_mana)
        } else {
            return Err("not_usable");
        };
        if *current >= maximum {
            return Err("resource_full");
        }
        let restored = heal.min(maximum - *current);
        *current += restored;
        take_amount(sheet, &item.id, item.tier, 1, Some(cell))?;
        Ok(Done {
            reason: "consumed",
            amount: i64::from(restored),
        })
    }

    fn buy(
        &self,
        sheet: &mut CharacterSheet,
        id: &str,
        amount: u16,
        ctx: ItemContext,
    ) -> Result<Done, &'static str> {
        let price = self
            .item(id)
            .and_then(|d| d.buy_price)
            .ok_or("not_for_sale")?;
        if !ctx.at_shop {
            return Err("not_at_shop");
        }
        let amount = u32::from(amount.clamp(1, 20));
        let total = price * u64::from(amount);
        if sheet.oril < total {
            return Err("no_gold");
        }
        add_item(sheet, self.new_item(id, amount), self)?;
        sheet.oril -= total;
        Ok(Done {
            reason: "bought",
            amount: total as i64,
        })
    }

    fn refine(
        &self,
        sheet: &mut CharacterSheet,
        target: Cell,
        dice: &mut dyn Dice,
    ) -> Result<Done, &'static str> {
        let item = get(sheet, target)?.clone().ok_or("item_missing")?;
        if !self.refinable(&item.id) {
            return Err("not_refinable");
        }
        if item.tier >= MAX_TIER {
            return Err("max_tier");
        }
        let step = &self.item_rules.steps[usize::from(item.tier)];
        if sheet.oril < step.cost {
            return Err("no_gold");
        }
        take_amount(sheet, &step.material, 0, step.amount, None).map_err(|_| "no_material")?;
        sheet.oril -= step.cost;
        let success = dice.unit() * 100.0 < step.chance;
        let tier = if success {
            item.tier + 1
        } else if item.tier >= self.item_rules.fail_downgrade_from {
            item.tier - 1
        } else {
            item.tier
        };
        if let Some(held) = get(sheet, target)?.as_mut() {
            held.tier = tier;
        }
        Ok(Done {
            reason: if success {
                "refined"
            } else {
                "refinement_failed"
            },
            amount: i64::from(tier),
        })
    }

    fn enchant(
        &self,
        sheet: &mut CharacterSheet,
        scroll_cell: u8,
        target: Cell,
        dice: &mut dyn Dice,
    ) -> Result<Done, &'static str> {
        let e = &self.item_rules.enchant;
        let scroll = get(sheet, Cell::Bag(scroll_cell))?
            .clone()
            .ok_or("no_scroll")?;
        let imbue = scroll.id == e.imbue_scroll;
        if !imbue && scroll.id != e.reweave_scroll {
            return Err("invalid_operation");
        }
        let item = get(sheet, target)?.clone().ok_or("item_missing")?;
        if item.uid == 0 || !self.enchantable(&item.id) {
            return Err("not_enchantable");
        }
        let mut held = item.bonuses.clone();
        if imbue && held.len() >= e.max_bonuses {
            return Err("bonus_full");
        }
        if !imbue && held.is_empty() {
            return Err("no_bonus");
        }
        take_amount(sheet, &scroll.id, scroll.tier, 1, Some(scroll_cell))?;
        let mut reason = "enchanted";
        if imbue {
            let chance = e
                .imbue_chance
                .get(held.len())
                .or(e.imbue_chance.last())
                .copied()
                .unwrap_or(100.0);
            if dice.unit() * 100.0 < chance {
                let bonus = self.roll_bonus(&item.id, &held, dice).ok_or("bonus_full")?;
                held.push(bonus);
            } else {
                reason = "enchant_failed";
            }
        } else {
            let count = held.len();
            held.clear();
            for _ in 0..count {
                if let Some(bonus) = self.roll_bonus(&item.id, &held, dice) {
                    held.push(bonus);
                }
            }
        }
        // The scroll may have sat in front of the target in the bag: find the
        // target again by its uid.
        let uid = item.uid;
        let cells = sheet.bag.iter_mut().chain(sheet.equipment.iter_mut());
        if let Some(target) = cells.flatten().find(|i| i.uid == uid) {
            target.bonuses = held;
        }
        Ok(Done { reason, amount: 0 })
    }

    /// One new bonus for `id`: a stat from its pool it does not hold yet (nor
    /// as a fixed stat), not disabled, of a theme the piece may carry, at a
    /// weighted grade.
    fn roll_bonus(&self, id: &str, held: &[Bonus], dice: &mut dyn Dice) -> Option<Bonus> {
        let e = &self.item_rules.enchant;
        let kind = self.slot_kind(id)?;
        let themes = e.slot_themes.get(kind)?;
        let fixed = self.fixed_stat_keys(id);
        let free: Vec<&String> = e
            .pools
            .get(kind)?
            .iter()
            .filter(|stat| {
                !held.iter().any(|b| &&b.stat == stat)
                    && !fixed.contains(&stat.as_str())
                    && e.stats
                        .get(*stat)
                        .is_some_and(|s| !s.disabled && themes.contains(&s.theme))
            })
            .collect();
        if free.is_empty() {
            return None;
        }
        let stat = free[dice.below(free.len() as u32) as usize];
        let total: u32 = e.grade_weights.iter().sum::<u32>().max(1);
        let mut pick = dice.below(total) + 1;
        let mut grade = 0;
        for (i, w) in e.grade_weights.iter().enumerate() {
            if pick <= *w {
                grade = i;
                break;
            }
            pick -= w;
        }
        let values = &e.stats.get(stat)?.values;
        let value = values.get(grade).or(values.last()).copied().unwrap_or(0.0);
        Some(Bonus {
            stat: stat.clone(),
            value,
            grade: grade as u8,
        })
    }
}

fn get(sheet: &mut CharacterSheet, cell: Cell) -> Result<&mut Option<Item>, &'static str> {
    match cell {
        Cell::Bag(i) => sheet.bag.get_mut(usize::from(i)).ok_or("bad_cell"),
        Cell::Worn(slot) => sheet.equipment.get_mut(slot as usize).ok_or("bad_cell"),
    }
}

/// Empties a bag cell and returns what it held.
fn take_cell(sheet: &mut CharacterSheet, cell: u8) -> Result<Item, &'static str> {
    get(sheet, Cell::Bag(cell))?.take().ok_or("item_missing")
}

/// Removes `amount` of a stackable (id, tier) from the bag, from `first`
/// before any other cell. All or nothing.
fn take_amount(
    sheet: &mut CharacterSheet,
    id: &str,
    tier: u8,
    amount: u32,
    first: Option<u8>,
) -> Result<(), &'static str> {
    let matches = |i: &Item| i.id == id && i.tier == tier;
    let held: u32 = sheet
        .bag
        .iter()
        .flatten()
        .filter(|i| matches(i))
        .map(|i| i.amount)
        .sum();
    if held < amount {
        return Err("item_missing");
    }
    let mut order: Vec<usize> = (0..sheet.bag.len()).collect();
    if let Some(first) = first {
        order.retain(|&i| i != usize::from(first));
        order.insert(0, usize::from(first));
    }
    let mut left = amount;
    for i in order {
        if left == 0 {
            break;
        }
        let cell = &mut sheet.bag[i];
        if let Some(item) = cell.as_mut()
            && matches(item)
        {
            let used = left.min(item.amount);
            item.amount -= used;
            left -= used;
            if item.amount == 0 {
                *cell = None;
            }
        }
    }
    Ok(())
}

/// Puts `item` in the bag: a stack tops up stacks of the same kind first,
/// then takes empty cells. All or nothing ("bag_full").
pub fn add_item(sheet: &mut CharacterSheet, item: Item, rules: &Rules) -> Result<(), &'static str> {
    let mut bag = sheet.bag.clone();
    bag.resize(BAG_SLOTS, None);
    let mut left = item.amount;
    if rules.stackable(&item.id) {
        for held in bag.iter_mut().flatten() {
            if held.uid == 0 && held.id == item.id && held.tier == item.tier {
                let carried = MAX_STACK.saturating_sub(held.amount).min(left);
                held.amount += carried;
                left -= carried;
            }
        }
        while left > 0 {
            let cell = bag.iter_mut().find(|c| c.is_none()).ok_or("bag_full")?;
            let here = left.min(MAX_STACK);
            *cell = Some(Item {
                amount: here,
                ..item.clone()
            });
            left -= here;
        }
    } else {
        for n in 0..left {
            let cell = bag.iter_mut().find(|c| c.is_none()).ok_or("bag_full")?;
            let mut one = item.clone();
            one.amount = 1;
            if n > 0 || one.uid == 0 {
                one.uid = crate::new_uid();
            }
            *cell = Some(one);
        }
    }
    sheet.bag = bag;
    Ok(())
}
