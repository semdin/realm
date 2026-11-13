//! Typed access to the content's ids and a check of every cross reference:
//! a spawn pack's creature exists, a loot roll's item exists, a quest's
//! target exists, a travel node's map exists, and so on. Rule systems add
//! typed records here as they are ported; until then the rest of each file
//! stays JSON.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

use crate::Content;

/// Ids that are not items but may appear where items do (currency).
pub const CURRENCIES: &[&str] = &["oril"];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Item {
    pub name: String,
    pub kind: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Creature {
    pub display: String,
    pub family: String,
    pub loot_table: Option<String>,
}

/// The ids every system refers to, read from the content.
#[derive(Debug, Default)]
pub struct Catalog {
    pub items: BTreeMap<String, Item>,
    pub spells: BTreeSet<String>,
    pub creatures: BTreeMap<String, Creature>,
    pub maps: BTreeSet<String>,
    pub houses: BTreeSet<String>,
    pub loot_tables: BTreeSet<String>,
    pub pack_templates: BTreeSet<String>,
    pub travel_nodes: BTreeSet<String>,
    pub dungeons: BTreeSet<String>,
    pub quests: BTreeSet<String>,
    pub quest_places: BTreeSet<String>,
    pub safe_zones: BTreeSet<String>,
    pub spawn_packs: usize,
}

impl Catalog {
    /// Reads the catalog and checks every reference. Returns every problem
    /// found, not just the first.
    pub fn build(content: &Content) -> Result<Self, Vec<String>> {
        let mut errors = Vec::new();
        let mut cat = Self::default();
        let file = |name: &str, errors: &mut Vec<String>| -> Value {
            content.file(name).cloned().unwrap_or_else(|| {
                errors.push(format!("missing file {name}"));
                Value::Null
            })
        };

        let items = file("items.json", &mut errors);
        for (id, item) in entries(&items) {
            if item["id"].as_str() != Some(id.as_str()) {
                errors.push(format!("items.json: '{id}' has id {}", item["id"]));
            }
            let name = item["name"].as_str().unwrap_or_default().to_owned();
            let kind = item["type"].as_str().unwrap_or_default().to_owned();
            if name.is_empty() || kind.is_empty() {
                errors.push(format!("items.json: '{id}' needs a name and a type"));
            }
            cat.items.insert(id, Item { name, kind });
        }

        let spells = file("spells.json", &mut errors);
        for (id, spell) in entries(&spells) {
            if spell["id"].as_str() != Some(id.as_str()) {
                errors.push(format!("spells.json: '{id}' has id {}", spell["id"]));
            }
            cat.spells.insert(id);
        }

        let maps = file("maps.json", &mut errors);
        cat.maps = keys(&maps["maps"]);
        let safe = file("safe_zones.json", &mut errors);
        cat.safe_zones = array(&safe["zones"])
            .filter_map(|z| z["id"].as_str().map(str::to_owned))
            .collect();
        for (map, def) in entries(&maps["maps"]) {
            for zone in strings(&def["safe_zones"]) {
                cat.check(&mut errors, cat.safe_zones.contains(&zone), || {
                    format!("maps.json: {map} safe zone '{zone}'")
                });
            }
        }

        let houses = file("houses.json", &mut errors);
        cat.houses = keys(&houses);
        let combat = file("combat.json", &mut errors);
        for house in keys(&combat["houses"]) {
            cat.check(&mut errors, cat.houses.contains(&house), || {
                format!("combat.json: house '{house}'")
            });
        }

        let loot = file("loot_tables.json", &mut errors);
        cat.loot_tables = keys(&loot["tables"]);
        for (path, roll) in loot_rolls(&loot) {
            let id = roll["id"].as_str().unwrap_or_default().to_owned();
            cat.check(&mut errors, cat.is_item(&id), || {
                format!("loot_tables.json: {path} item '{id}'")
            });
        }

        let mobs = file("mobs.json", &mut errors);
        for (id, mob) in entries(&mobs["mobs"]) {
            // An empty loot table means the creature drops nothing.
            let loot_table = mob["loot_table"]
                .as_str()
                .filter(|t| !t.is_empty())
                .map(str::to_owned);
            if let Some(table) = &loot_table {
                cat.check(&mut errors, cat.loot_tables.contains(table), || {
                    format!("mobs.json: {id} loot table '{table}'")
                });
            }
            cat.creatures.insert(
                id,
                Creature {
                    display: mob["display"].as_str().unwrap_or_default().to_owned(),
                    family: mob["family"].as_str().unwrap_or_default().to_owned(),
                    loot_table,
                },
            );
        }

        let spawns = file("spawn_tables.json", &mut errors);
        cat.pack_templates = keys(&spawns["templates"]);
        for pack in array(&spawns["packs"]) {
            cat.spawn_packs += 1;
            let id = pack["id"].as_str().unwrap_or("?");
            let mut species: Vec<String> = pack["mob"]
                .as_str()
                .map(str::to_owned)
                .into_iter()
                .collect();
            species.extend(strings(&pack["roster"]));
            for mob in species {
                cat.check(&mut errors, cat.creatures.contains_key(&mob), || {
                    format!("spawn pack {id}: creature '{mob}'")
                });
            }
            if let Some(template) = pack["template"].as_str() {
                cat.check(&mut errors, cat.pack_templates.contains(template), || {
                    format!("spawn pack {id}: template '{template}'")
                });
            }
        }

        let dungeons = file("dungeons.json", &mut errors);
        cat.dungeons = keys(&dungeons["dungeons"]);
        for (id, dungeon) in entries(&dungeons["dungeons"]) {
            if let Some(map) = dungeon["map"].as_str() {
                cat.check(&mut errors, cat.maps.contains(map), || {
                    format!("dungeon {id}: map '{map}'")
                });
            }
        }

        let travel = file("travel.json", &mut errors);
        cat.travel_nodes = keys(&travel["nodes"]);
        for (id, node) in entries(&travel["nodes"]) {
            if let Some(map) = node["map"].as_str() {
                cat.check(&mut errors, cat.maps.contains(map), || {
                    format!("travel node {id}: map '{map}'")
                });
            }
            if let Some(pair) = node["pair"].as_str() {
                cat.check(&mut errors, cat.travel_nodes.contains(pair), || {
                    format!("travel node {id}: pair '{pair}'")
                });
            }
        }
        for section in ["floo", "portkey"] {
            if let Some(item) = travel[section]["item"].as_str() {
                cat.check(&mut errors, cat.is_item(item), || {
                    format!("travel.json {section}: item '{item}'")
                });
            }
        }
        for node in strings(&travel["floo"]["known_by_default"]) {
            cat.check(&mut errors, cat.travel_nodes.contains(&node), || {
                format!("travel.json floo default '{node}'")
            });
        }

        let quests = file("quests.json", &mut errors);
        cat.quest_places = keys(&quests["places"]);
        cat.quests = array(&quests["chain"])
            .filter_map(|q| q["id"].as_str().map(str::to_owned))
            .collect();
        for quest in array(&quests["chain"]) {
            let id = quest["id"].as_str().unwrap_or("?");
            let target = quest["target"].as_str().unwrap_or_default();
            let kind = quest["type"].as_str().unwrap_or_default();
            let ok = match kind {
                "kill" => cat.creatures.contains_key(target),
                "visit" => cat.quest_places.contains(target),
                "enter_map" => cat.maps.contains(target),
                "dungeon" => cat.dungeons.contains(target),
                "talk" => !target.is_empty(),
                _ => true,
            };
            cat.check(&mut errors, ok, || {
                format!("quest {id}: {kind} target '{target}'")
            });
            for reward in array(&quest["reward_items"]) {
                let item = reward
                    .as_str()
                    .or_else(|| reward["id"].as_str())
                    .unwrap_or_default();
                cat.check(&mut errors, cat.is_item(item), || {
                    format!("quest {id}: reward item '{item}'")
                });
            }
            for required in strings(&quest["requires"]) {
                cat.check(&mut errors, cat.quests.contains(&required), || {
                    format!("quest {id}: requires '{required}'")
                });
            }
        }
        for (place, def) in entries(&quests["places"]) {
            if let Some(map) = def["map"].as_str() {
                cat.check(&mut errors, cat.maps.contains(map), || {
                    format!("quest place {place}: map '{map}'")
                });
            }
        }

        if errors.is_empty() {
            Ok(cat)
        } else {
            Err(errors)
        }
    }

    fn is_item(&self, id: &str) -> bool {
        self.items.contains_key(id) || CURRENCIES.contains(&id)
    }

    fn check(&self, errors: &mut Vec<String>, ok: bool, what: impl FnOnce() -> String) {
        if !ok {
            errors.push(format!("{} does not exist", what()));
        }
    }
}

/// `(key, value)` of an object, skipping author notes.
fn entries(value: &Value) -> Vec<(String, Value)> {
    value
        .as_object()
        .map(|m| {
            m.iter()
                .filter(|(k, _)| !k.starts_with('_'))
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect()
        })
        .unwrap_or_default()
}

fn keys(value: &Value) -> BTreeSet<String> {
    entries(value).into_iter().map(|(k, _)| k).collect()
}

fn array(value: &Value) -> impl Iterator<Item = &Value> {
    value.as_array().into_iter().flatten()
}

fn strings(value: &Value) -> Vec<String> {
    array(value)
        .filter_map(|v| v.as_str().map(str::to_owned))
        .collect()
}

/// Every `{id, ...}` roll in the loot file, with a readable path.
fn loot_rolls(loot: &Value) -> Vec<(String, Value)> {
    let mut out = Vec::new();
    let mut visit = |path: String, block: &Value| {
        for list in ["always", "rolls", "boss_always", "boss_rolls"] {
            for (i, roll) in array(&block[list]).enumerate() {
                out.push((format!("{path}.{list}[{i}]"), roll.clone()));
            }
        }
    };
    for (key, block) in entries(loot) {
        if key == "tables" {
            for (table, def) in entries(&block) {
                visit(format!("tables.{table}"), &def);
            }
        } else {
            visit(key, &block);
        }
    }
    out
}
