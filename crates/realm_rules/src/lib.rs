//! Game rules beyond movement, shared by the map server (which decides) and
//! the client (which shows them: tooltips, totals, what a button would do).
//!
//! `Rules` is the typed part of the content these rules read; each Phase 5
//! slice adds the tables it needs. `sheet` is the character record: what is
//! saved, what the owner sees, and the only input the server's systems
//! change.

pub mod combat;
pub mod creatures;
pub mod dungeons;
pub mod items;
pub mod loot;
pub mod progress;
pub mod quests;
pub mod sheet;
pub mod travel;

use std::collections::BTreeMap;

use realm_data::{Content, without_notes};
use serde::Deserialize;
use serde_json::Value;

pub use combat::{BASIC_SPELL, CastPower, CombatRules, Delivery, SpellDef};
pub use items::{Cell, Derived, Dice, Done, ItemContext, ItemOp, ItemRules, ItemStats};
pub use sheet::{BAG_SLOTS, Bonus, CharacterSheet, Item, MAX_STACK, Place, QuestLog, Slot};

/// Item facts the rules need (`items.json`).
#[derive(Clone, Debug, Default)]
pub struct ItemDef {
    pub id: String,
    pub kind: String,
    pub slots: Vec<Slot>,
    /// Stacks share one bag cell; everything else is an instance with a uid.
    pub stackable: bool,
    pub rarity: String,
    pub required_level: u16,
    pub buy_price: Option<u64>,
    pub sell_price: Option<u64>,
    pub attack_value: Option<(f32, f32)>,
    pub magic_attack: Option<(f32, f32)>,
    pub armor: f32,
    pub bonus_hp: f32,
    pub bonus_mana: f32,
    /// Fixed percent / per-second stats (items::FIXED_PERCENT keys).
    pub percent: BTreeMap<String, f32>,
    pub mount_speed: Option<f32>,
    pub heal_hp: u32,
    pub heal_mana: u32,
}

#[derive(Clone, Debug, Deserialize)]
pub struct StarterItem {
    pub item: String,
    pub amount: u32,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Starter {
    /// Slot name -> item id.
    pub equipment: BTreeMap<String, String>,
    pub bag: Vec<StarterItem>,
}

#[derive(Clone, Debug)]
pub struct BaseStats {
    pub max_hp: u32,
    pub max_mana: u32,
    pub oril: u64,
}

/// What a look may hold (`looks.json`): each palette key and how many
/// entries its list has, each slider and its range.
#[derive(Clone, Debug, Default)]
pub struct LookRules {
    pub picks: BTreeMap<String, usize>,
    pub sliders: BTreeMap<String, (f32, f32)>,
}

/// A protected volume (safe_zones.json): no attack lands inside it, and no
/// attack is made from inside it.
#[derive(Clone, Debug)]
pub struct SafeZone {
    pub id: String,
    pub x: f32,
    pub z: f32,
    pub radius: f32,
    pub y_min: f32,
    pub y_max: f32,
}

/// The typed content the rules read.
#[derive(Clone, Debug)]
pub struct Rules {
    pub base: BaseStats,
    pub starter: Starter,
    pub items: BTreeMap<String, ItemDef>,
    pub looks: LookRules,
    pub item_rules: ItemRules,
    pub combat: CombatRules,
    /// What creatures do on their own: attacks, abilities, pack tuning.
    pub mobs: creatures::CreatureRules,
    /// Experience, levels, attribute points.
    pub progress: progress::ProgressRules,
    /// What kills drop.
    pub loot: loot::LootRules,
    /// The quest chain, its places and the NPCs who give it.
    pub quests: quests::QuestRules,
    /// Doors, the Hearthway, cabinets, passages, the Waylink, flight.
    pub travel: travel::TravelRules,
    /// Dungeons: difficulties, party rules, rewards, director steps.
    pub dungeons: dungeons::DungeonRules,
    pub safe_zones: Vec<SafeZone>,
    /// Map -> the ids of its safe zones (maps.json `safe_zones`).
    pub map_zones: BTreeMap<String, Vec<String>>,
}

fn file<'a>(content: &'a Content, name: &str) -> Result<&'a Value, String> {
    content
        .file(name)
        .ok_or_else(|| format!("content has no {name}"))
}

fn uint(value: &Value, what: &str) -> Result<u64, String> {
    value
        .as_u64()
        .or_else(|| value.as_f64().filter(|f| *f >= 0.0).map(|f| f as u64))
        .ok_or_else(|| format!("{what} must be a non-negative number"))
}

impl Rules {
    pub fn from_content(content: &Content) -> Result<Self, String> {
        let combat = without_notes(file(content, "combat.json")?);
        let base = &combat["base_stats"];
        let base = BaseStats {
            max_hp: uint(&base["max_hp"], "base_stats.max_hp")? as u32,
            max_mana: uint(&base["max_mana"], "base_stats.max_mana")? as u32,
            oril: uint(&base["oril"], "base_stats.oril")?,
        };
        let characters = without_notes(file(content, "characters.json")?);
        let starter: Starter = serde_json::from_value(characters["starter"].clone())
            .map_err(|e| format!("characters.json starter: {e}"))?;

        let mut items = BTreeMap::new();
        for (id, def) in without_notes(file(content, "items.json")?)
            .as_object()
            .into_iter()
            .flatten()
        {
            let kind = def["type"].as_str().unwrap_or("").to_owned();
            let mut slots = Vec::new();
            for slot in def["slots"].as_array().into_iter().flatten() {
                let name = slot.as_str().unwrap_or("");
                slots.push(
                    Slot::parse(name).ok_or_else(|| format!("item {id}: unknown slot '{name}'"))?,
                );
            }
            let stackable = def["stackable"]
                .as_bool()
                .unwrap_or(matches!(kind.as_str(), "consumable" | "material"));
            let mut item = ItemDef {
                id: id.clone(),
                kind,
                slots,
                stackable,
                ..ItemDef::default()
            };
            items::read_item(&mut item, def);
            items.insert(id.clone(), item);
        }
        let looks_file = without_notes(file(content, "looks.json")?);
        let mut looks = LookRules::default();
        for (key, list) in looks_file["picks"].as_object().into_iter().flatten() {
            let list = list.as_str().unwrap_or("");
            let size = looks_file[list]
                .as_array()
                .map(Vec::len)
                .ok_or_else(|| format!("looks.json: pick '{key}' names no list '{list}'"))?;
            looks.picks.insert(key.clone(), size);
        }
        for (key, span) in looks_file["sliders"].as_object().into_iter().flatten() {
            let lo = span[0].as_f64().unwrap_or(-1.0) as f32;
            let hi = span[1].as_f64().unwrap_or(1.0) as f32;
            looks.sliders.insert(key.clone(), (lo, hi));
        }
        let rules = Self {
            base,
            starter,
            items,
            looks,
            item_rules: ItemRules::from_content(content)?,
            combat: CombatRules::from_content(content)?,
            progress: progress::ProgressRules::from_json(
                &combat,
                file(content, "mobs.json")?,
                file(content, "spawn_tables.json")?,
            ),
            loot: loot::LootRules::from_json(file(content, "loot_tables.json")?),
            quests: quests::QuestRules::from_json(
                file(content, "quests.json")?,
                file(content, "npcs.json")?,
                &combat,
            ),
            mobs: creatures::CreatureRules::from_json(
                file(content, "mobs.json")?,
                file(content, "spawn_tables.json")?,
            )?,
            travel: travel::TravelRules::from_content(content)?,
            dungeons: dungeons::DungeonRules::from_json(file(content, "dungeons.json")?)?,
            safe_zones: Vec::new(),
            map_zones: BTreeMap::new(),
        };
        let mut rules = rules;
        for z in without_notes(file(content, "safe_zones.json")?)["zones"]
            .as_array()
            .into_iter()
            .flatten()
        {
            let num = |v: &Value, d: f64| v.as_f64().unwrap_or(d) as f32;
            rules.safe_zones.push(SafeZone {
                id: z["id"].as_str().unwrap_or("").to_owned(),
                x: num(&z["center"][0], 0.0),
                z: num(&z["center"][2], 0.0),
                radius: num(&z["radius"], 0.0),
                y_min: num(&z["y_min"], -1.0e6),
                y_max: num(&z["y_max"], 1.0e6),
            });
        }
        for (map, def) in without_notes(file(content, "maps.json")?)["maps"]
            .as_object()
            .into_iter()
            .flatten()
        {
            let ids = def["safe_zones"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|v| v.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default();
            rules.map_zones.insert(map.clone(), ids);
        }
        rules.check()?;
        Ok(rules)
    }

    fn check(&self) -> Result<(), String> {
        for (slot, id) in &self.starter.equipment {
            let slot =
                Slot::parse(slot).ok_or_else(|| format!("starter: unknown slot '{slot}'"))?;
            let def = self
                .items
                .get(id)
                .ok_or_else(|| format!("starter: unknown item '{id}'"))?;
            if !def.slots.contains(&slot) {
                return Err(format!("starter: {id} does not go in {}", slot.name()));
            }
        }
        for entry in &self.starter.bag {
            if !self.items.contains_key(&entry.item) {
                return Err(format!("starter: unknown item '{}'", entry.item));
            }
        }
        Ok(())
    }

    /// A stackable item counts by amount; an instance always has amount 1
    /// and its own uid.
    #[must_use]
    pub fn stackable(&self, id: &str) -> bool {
        self.items.get(id).is_none_or(|d| d.stackable)
    }

    /// One item as it enters the world: a stack, or an instance with a new
    /// uid.
    #[must_use]
    pub fn new_item(&self, id: &str, amount: u32) -> Item {
        if self.stackable(id) {
            Item {
                id: id.to_owned(),
                amount: amount.clamp(1, MAX_STACK),
                ..Item::default()
            }
        } else {
            Item {
                id: id.to_owned(),
                amount: 1,
                uid: new_uid(),
                ..Item::default()
            }
        }
    }

    /// A new character with the base numbers and the starter kit, not yet
    /// placed in the world.
    #[must_use]
    pub fn new_character(&self, id: u64, name: &str, house: &str) -> CharacterSheet {
        // The house shapes the body: more health or more mana.
        let (max_hp, max_mana) =
            self.combat
                .base_vitals(house, self.base.max_hp, self.base.max_mana);
        let mut sheet = CharacterSheet {
            id,
            name: name.to_owned(),
            house: house.to_owned(),
            level: 1,
            exp: 0,
            hp: max_hp,
            mana: max_mana,
            base_max_hp: max_hp,
            base_max_mana: max_mana,
            oril: self.base.oril,
            bag: vec![None; BAG_SLOTS],
            equipment: vec![None; Slot::ALL.len()],
            look: Vec::new(),
            place: None,
            skills: Vec::new(),
            attributes: Vec::new(),
            quests: QuestLog::default(),
            house_rep: 0,
            dungeons: dungeons::DungeonLog::default(),
            revision: 1,
        };
        for (slot, item) in &self.starter.equipment {
            if let Some(slot) = Slot::parse(slot) {
                sheet.equipment[slot as usize] = Some(self.new_item(item, 1));
            }
        }
        for entry in &self.starter.bag {
            let item = self.new_item(&entry.item, entry.amount);
            if let Some(cell) = sheet.bag.iter_mut().find(|c| c.is_none()) {
                *cell = Some(item);
            }
        }
        sheet
    }
}

impl Rules {
    /// Whether the point on `map` is inside one of the map's safe zones.
    #[must_use]
    pub fn protected(&self, map: &str, x: f32, y: f32, z: f32) -> bool {
        let Some(ids) = self.map_zones.get(map) else {
            return false;
        };
        self.safe_zones.iter().any(|zone| {
            ids.contains(&zone.id)
                && y >= zone.y_min
                && y <= zone.y_max
                && (x - zone.x).powi(2) + (z - zone.z).powi(2) <= zone.radius * zone.radius
        })
    }
}

impl LookRules {
    /// A look reduced to known keys with valid values: palette picks clamped
    /// to their list, sliders clamped to their range and to two decimals,
    /// anything unknown or not finite dropped. A look can never name a mesh
    /// or colour that does not exist.
    #[must_use]
    pub fn clean(&self, raw: &[(String, f32)]) -> Vec<(String, f32)> {
        let mut out = Vec::new();
        for (key, value) in raw {
            if !value.is_finite() || out.iter().any(|(k, _): &(String, f32)| k == key) {
                continue;
            }
            if let Some(&size) = self.picks.get(key) {
                if size > 0 {
                    out.push((key.clone(), value.clamp(0.0, (size - 1) as f32).trunc()));
                }
            } else if let Some(&(lo, hi)) = self.sliders.get(key) {
                out.push((key.clone(), (value.clamp(lo, hi) * 100.0).round() / 100.0));
            }
        }
        out
    }
}

/// A fresh instance id: random, non-zero and below 2^53 so it survives any
/// JSON reader.
#[must_use]
pub fn new_uid() -> u64 {
    loop {
        let uid = getrandom::u64().unwrap_or(0) & ((1 << 53) - 1);
        if uid != 0 {
            return uid;
        }
    }
}
