//! Travel (maps.json, travel.json): doors between maps, the Hearthway
//! (fireplaces linked by Hearth Dust), the Twinned Cabinets and the secret
//! passages (free twin links), the Waylink (an old boot that carries a
//! party), and which maps let a broom fly.
//!
//! A trip names where it ends (`Arrival`): the map and a `Landing` the
//! destination map works out on its own ground (only it has that map's
//! terrain). The map the traveller leaves decides whether it may go.
//!
//! The old game's `request_transfer`, `request_travel`, `HPMaps` travel
//! helpers and its boot travel, with these faults fixed: every check reads
//! the renamed data (`hearthway`, `waylink`), a Waylink rider must meet the
//! destination's level as its owner must, and nothing is learned (every
//! hearth is open; the destination's level is the only gate, as the old
//! game had come to play).

use std::collections::BTreeMap;

use realm_data::{Content, without_notes};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One map's travel facts.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MapInfo {
    pub display: String,
    pub flight_allowed: bool,
    pub capacity: u16,
    /// A dungeon map (copies per party come with the dungeon slice).
    pub instanced: bool,
    /// Named arrival points (x, y, z).
    pub spawns: BTreeMap<String, [f32; 3]>,
    /// Where a fallen player rises.
    pub respawn: String,
}

/// A door: stand in its trigger (a circle with a height band) and ask.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Portal {
    pub id: String,
    pub map: String,
    pub to_map: String,
    pub to_spawn: String,
    pub label: String,
    pub center: [f32; 3],
    pub radius: f32,
    pub y_min: f32,
    pub y_max: f32,
}

impl Portal {
    /// Whether feet at `pos` stand in the trigger.
    #[must_use]
    pub fn holds(&self, pos: [f32; 3]) -> bool {
        let (dx, dz) = (pos[0] - self.center[0], pos[2] - self.center[2]);
        dx * dx + dz * dz <= self.radius * self.radius
            && pos[1] >= self.y_min
            && pos[1] <= self.y_max
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum NodeKind {
    Hearthway,
    Cabinet,
    Passage,
}

/// A fixed place travel starts from or ends at.
#[derive(Clone, Debug, PartialEq)]
pub struct Node {
    pub id: String,
    pub kind: NodeKind,
    pub map: String,
    pub label: String,
    /// y 0 on a terrain map: on the ground.
    pub pos: [f32; 3],
    /// Degrees; the node faces the room along (sin yaw, 0, cos yaw).
    pub yaw: f32,
    /// A traveller below this level may not arrive here.
    pub level_min: u16,
    /// Cabinets and passages: the twin it leads to.
    pub pair: Option<String>,
}

impl Node {
    /// The unit direction the node faces (x, z).
    #[must_use]
    pub fn facing(&self) -> (f32, f32) {
        let yaw = self.yaw.to_radians();
        (yaw.sin(), yaw.cos())
    }

    /// Whether feet at `pos` are close enough to use it: within `radius`
    /// across (plus half a metre), and within 4 m of its height unless it
    /// stands on terrain (y 0: the height is the ground's).
    #[must_use]
    pub fn reaches(&self, pos: [f32; 3], radius: f32) -> bool {
        let (dx, dz) = (pos[0] - self.pos[0], pos[2] - self.pos[2]);
        let reach = radius + 0.5;
        dx * dx + dz * dz <= reach * reach
            && (self.pos[1] == 0.0 || (pos[1] - self.pos[1]).abs() <= 4.0)
    }
}

/// Reach, set-down distance and combat lock of one kind of node.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct NodeRules {
    pub radius: f32,
    pub arrive: f32,
    pub combat_lock_ms: u32,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct WaylinkRules {
    pub item: String,
    pub countdown_ms: u32,
    pub grab_radius: f32,
    pub combat_lock_ms: u32,
    pub arrive: f32,
    pub destinations: Vec<String>,
    pub place_ahead: f32,
    pub scatter: (f32, f32),
}

/// Where a traveller is set down; the destination map finds the point on
/// its own ground.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum Landing {
    /// A spawn point of the map.
    Spawn(String),
    /// `arrive` metres in front of a node.
    Node { node: String, arrive: f32 },
    /// A spawn point, member `slot` of `of` in a 1.4 m ring around it (a
    /// party entering a dungeon together).
    Ring { spawn: String, slot: u8, of: u8 },
    /// A Waylink: an open spot found around the node with `seed`, rider
    /// `slot` of `riders` in a small ring there.
    Scatter {
        node: String,
        seed: u32,
        slot: u8,
        riders: u8,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum TripKind {
    Door,
    Hearthway,
    Cabinet,
    Passage,
    Waylink,
}

impl TripKind {
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::Door => "door",
            Self::Hearthway => "hearthway",
            Self::Cabinet => "cabinet",
            Self::Passage => "passage",
            Self::Waylink => "waylink",
        }
    }
}

/// Where a trip ends.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Arrival {
    pub map: String,
    pub landing: Landing,
    pub kind: TripKind,
    /// The dungeon copy it enters (0: the map itself).
    pub copy: u8,
}

/// A trip the rules allow from where the traveller stands; the map still
/// checks what only it knows (alive, mounted, fighting, the item).
#[derive(Clone, Debug, PartialEq)]
pub struct Trip {
    pub arrival: Arrival,
    /// Shown while travelling: the destination's name.
    pub label: String,
    /// Item and count the trip costs.
    pub cost: Option<(String, u32)>,
    /// No trip this soon after a fight (0: doors do not care).
    pub combat_lock_ms: u32,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct TravelRules {
    pub maps: BTreeMap<String, MapInfo>,
    pub portals: Vec<Portal>,
    pub nodes: BTreeMap<String, Node>,
    pub hearthway: NodeRules,
    pub hearth_item: String,
    pub hearth_cost: u32,
    pub cabinet: NodeRules,
    pub passage: NodeRules,
    pub waylink: WaylinkRules,
}

fn f(v: &Value, default: f32) -> f32 {
    v.as_f64().map_or(default, |n| n as f32)
}

fn point(v: &Value) -> [f32; 3] {
    [f(&v[0], 0.0), f(&v[1], 0.0), f(&v[2], 0.0)]
}

fn ms(seconds: f32) -> u32 {
    (seconds * 1000.0).round() as u32
}

fn node_rules(v: &Value) -> NodeRules {
    NodeRules {
        radius: f(&v["radius"], 3.0),
        arrive: f(&v["arrive"], 2.0),
        combat_lock_ms: ms(f(&v["combat_lock_s"], 5.0)),
    }
}

impl TravelRules {
    pub fn from_content(content: &Content) -> Result<Self, String> {
        let maps = without_notes(
            content
                .file("maps.json")
                .ok_or("content has no maps.json")?,
        );
        let travel = without_notes(
            content
                .file("travel.json")
                .ok_or("content has no travel.json")?,
        );
        let mut rules = Self {
            hearthway: node_rules(&travel["hearthway"]),
            hearth_item: travel["hearthway"]["item"]
                .as_str()
                .unwrap_or("hearth_dust")
                .to_owned(),
            hearth_cost: travel["hearthway"]["cost"].as_u64().unwrap_or(1) as u32,
            cabinet: node_rules(&travel["cabinet"]),
            passage: node_rules(&travel["passage"]),
            ..Self::default()
        };
        let w = &travel["waylink"];
        let scatter = (f(&w["scatter"][0], 10.0), f(&w["scatter"][1], 30.0));
        rules.waylink = WaylinkRules {
            item: w["item"].as_str().unwrap_or("waylink_boot").to_owned(),
            countdown_ms: ms(f(&w["countdown_s"], 10.0)),
            grab_radius: f(&w["grab_radius"], 3.0),
            combat_lock_ms: ms(f(&w["combat_lock_s"], 5.0)),
            arrive: f(&w["arrive"], 3.5),
            destinations: w["destinations"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|d| d.as_str().map(str::to_owned))
                .collect(),
            place_ahead: f(&w["place_ahead"], 0.6),
            scatter,
        };
        for (id, m) in maps["maps"].as_object().into_iter().flatten() {
            let mut spawns = BTreeMap::new();
            for (name, p) in m["spawn_points"].as_object().into_iter().flatten() {
                if p.is_array() {
                    spawns.insert(name.clone(), point(p));
                }
            }
            rules.maps.insert(
                id.clone(),
                MapInfo {
                    display: m["display"].as_str().unwrap_or(id).to_owned(),
                    flight_allowed: m["flight_allowed"].as_bool().unwrap_or(false),
                    capacity: m["capacity"].as_u64().unwrap_or(64) as u16,
                    instanced: m["instanced"].as_bool().unwrap_or(false),
                    spawns,
                    respawn: m["respawn_spawn"].as_str().unwrap_or("default").to_owned(),
                },
            );
        }
        for p in maps["portals"].as_array().into_iter().flatten() {
            let t = &p["trigger"];
            rules.portals.push(Portal {
                id: p["id"].as_str().unwrap_or("").to_owned(),
                map: p["map_id"].as_str().unwrap_or("").to_owned(),
                to_map: p["to_map"].as_str().unwrap_or("").to_owned(),
                to_spawn: p["to_spawn"].as_str().unwrap_or("default").to_owned(),
                label: p["label"].as_str().unwrap_or("").to_owned(),
                center: point(&t["center"]),
                radius: f(&t["radius"], 2.5),
                y_min: f(&t["y_min"], -1.0e6),
                y_max: f(&t["y_max"], 1.0e6),
            });
        }
        for (id, n) in travel["nodes"].as_object().into_iter().flatten() {
            let kind = match n["kind"].as_str() {
                Some("hearthway") => NodeKind::Hearthway,
                Some("cabinet") => NodeKind::Cabinet,
                Some("passage") => NodeKind::Passage,
                other => return Err(format!("travel.json node {id}: unknown kind {other:?}")),
            };
            rules.nodes.insert(
                id.clone(),
                Node {
                    id: id.clone(),
                    kind,
                    map: n["map"].as_str().unwrap_or("").to_owned(),
                    label: n["label"].as_str().unwrap_or(id).to_owned(),
                    pos: point(&n["pos"]),
                    yaw: f(&n["yaw"], 0.0),
                    level_min: n["level_min"].as_u64().unwrap_or(0) as u16,
                    pair: n["pair"].as_str().map(str::to_owned),
                },
            );
        }
        rules.check()?;
        Ok(rules)
    }

    fn check(&self) -> Result<(), String> {
        for p in &self.portals {
            let to = self
                .maps
                .get(&p.to_map)
                .ok_or_else(|| format!("portal {}: unknown map {}", p.id, p.to_map))?;
            if !to.spawns.contains_key(&p.to_spawn) {
                return Err(format!(
                    "portal {}: {} has no spawn {}",
                    p.id, p.to_map, p.to_spawn
                ));
            }
            if !self.maps.contains_key(&p.map) {
                return Err(format!("portal {}: unknown map {}", p.id, p.map));
            }
        }
        for n in self.nodes.values() {
            if !self.maps.contains_key(&n.map) {
                return Err(format!("travel node {}: unknown map {}", n.id, n.map));
            }
            if let Some(pair) = &n.pair
                && self.nodes.get(pair).is_none_or(|p| p.kind != n.kind)
            {
                return Err(format!("travel node {}: pair {pair} is not a twin", n.id));
            }
        }
        for d in &self.waylink.destinations {
            if self
                .nodes
                .get(d)
                .is_none_or(|n| n.kind != NodeKind::Hearthway)
            {
                return Err(format!("waylink destination {d} is not a hearth"));
            }
        }
        Ok(())
    }

    /// Whether a broom may fly on `map`.
    #[must_use]
    pub fn flight_allowed(&self, map: &str) -> bool {
        self.maps.get(map).is_some_and(|m| m.flight_allowed)
    }

    /// The rules of one kind of node.
    #[must_use]
    pub fn rules_of(&self, kind: NodeKind) -> NodeRules {
        match kind {
            NodeKind::Hearthway => self.hearthway,
            NodeKind::Cabinet => self.cabinet,
            NodeKind::Passage => self.passage,
        }
    }

    /// The door `id` of `map`, if feet at `pos` stand in it.
    pub fn door_trip(&self, map: &str, id: &str, pos: [f32; 3]) -> Result<Trip, &'static str> {
        let portal = self
            .portals
            .iter()
            .find(|p| p.id == id && p.map == map)
            .ok_or("no_portal")?;
        if !portal.holds(pos) {
            return Err("out_of_range");
        }
        if portal.to_map == map {
            return Err("map_unavailable");
        }
        Ok(Trip {
            arrival: Arrival {
                map: portal.to_map.clone(),
                landing: Landing::Spawn(portal.to_spawn.clone()),
                kind: TripKind::Door,
                copy: 0,
            },
            label: self
                .maps
                .get(&portal.to_map)
                .map_or_else(|| portal.label.clone(), |m| m.display.clone()),
            cost: None,
            combat_lock_ms: 0,
        })
    }

    /// A trip from node `from` (which feet at `pos` on `map` must reach):
    /// a hearth to the hearth `to`, a cabinet or passage to its twin.
    pub fn node_trip(
        &self,
        map: &str,
        pos: [f32; 3],
        from: &str,
        to: &str,
        level: u16,
    ) -> Result<Trip, &'static str> {
        let source = self
            .nodes
            .get(from)
            .filter(|n| n.map == map)
            .ok_or("no_portal")?;
        let rules = self.rules_of(source.kind);
        if !source.reaches(pos, rules.radius) {
            return Err("out_of_range");
        }
        let dest_id = match source.kind {
            NodeKind::Hearthway => to,
            NodeKind::Cabinet | NodeKind::Passage => source.pair.as_deref().unwrap_or(""),
        };
        let dest = self
            .nodes
            .get(dest_id)
            .filter(|d| d.kind == source.kind && d.id != source.id)
            .ok_or("no_portal")?;
        if level < dest.level_min {
            return Err("level_too_low");
        }
        let kind = match source.kind {
            NodeKind::Hearthway => TripKind::Hearthway,
            NodeKind::Cabinet => TripKind::Cabinet,
            NodeKind::Passage => TripKind::Passage,
        };
        Ok(Trip {
            arrival: Arrival {
                map: dest.map.clone(),
                landing: Landing::Node {
                    node: dest.id.clone(),
                    arrive: self.rules_of(dest.kind).arrive,
                },
                kind,
                copy: 0,
            },
            label: dest.label.clone(),
            cost: (source.kind == NodeKind::Hearthway)
                .then(|| (self.hearth_item.clone(), self.hearth_cost)),
            combat_lock_ms: rules.combat_lock_ms,
        })
    }

    /// The node nearest to feet at `pos` on `map` that they reach, of any
    /// kind (what an interact key would use).
    #[must_use]
    pub fn node_near(&self, map: &str, pos: [f32; 3]) -> Option<&Node> {
        self.nodes
            .values()
            .filter(|n| n.map == map && n.reaches(pos, self.rules_of(n.kind).radius))
            .min_by(|a, b| {
                let d = |n: &Node| (n.pos[0] - pos[0]).powi(2) + (n.pos[2] - pos[2]).powi(2);
                d(a).total_cmp(&d(b))
            })
    }
}
