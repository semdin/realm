//! What the map server reads from the content for its creatures: species,
//! spawn packs, respawn and tuning numbers. Character, item and combat rules
//! are realm_rules (`Game::rules`).

use realm_data::Content;
use realm_sim::Vec3;
use serde_json::Value;

pub struct Species {
    pub id: String,
    pub max_hp: f32,
    pub attack_power: f32,
    pub move_speed: f32,
    pub attack_range: f32,
    pub attack_cooldown_ticks: u16,
    /// Its own fighting (realm_rules creatures): timings, abilities, aura.
    pub brain: realm_rules::creatures::Brain,
    /// A caster's bolt: spell index, speed (m/s), range (m).
    pub bolt: Option<(u8, f32, f32)>,
    /// A Dark Shard or a training dummy: it stands, takes blows and never
    /// thinks.
    pub object: bool,
    /// Its loot_tables.json table (mobs.json `loot_table`).
    pub loot_table: String,
    /// A dungeon object (an egg sac, a cocoon: mobs.json role "object"):
    /// breaking it is the run's business and pays nothing.
    pub pays: bool,
}

/// combat.json death: when a fallen player may rise, when it goes to town by
/// itself, and what rising where it fell gives.
pub struct DeathRules {
    pub ready_ticks: u32,
    pub auto_ticks: u32,
    pub here_fraction: f32,
    pub here_ward_ticks: u32,
}

/// What a pack is.
#[derive(Clone, Debug, PartialEq)]
pub enum PackKind {
    Creatures,
    /// A dungeon run's step in copy N: never respawns.
    Dungeon(u8),
    /// A Dark Shard of this type (its one member is the stone).
    Stone(String),
    /// A training dummy.
    Dummy,
    /// The waves the Dark Shard of this pack calls (members come and go).
    Summons(usize),
}

/// A boss pack's first member.
pub struct BossSetup {
    pub key: String,
    /// Boss pattern style; empty when the template names none.
    pub style: String,
    pub arena_radius: f32,
}

pub struct Pack {
    pub kind: PackKind,
    /// Index into [`Game::species`].
    pub species: usize,
    pub level: u32,
    pub count: u32,
    pub boss: bool,
    pub center: (f32, f32),
    pub half_extent: (f32, f32),
    pub leash: f32,
    /// Aggressive packs attack a player who comes near; reactive ones only
    /// answer a blow.
    pub aggressive: bool,
    /// Pack mates this close to a creature that turns on a player join in.
    pub assist_radius: f32,
    /// No respawn while a player stands this close to the new anchor.
    pub clear_radius: f32,
    /// The whole pack comes back this long after its last member falls.
    pub respawn_ticks: (u32, u32),
    /// Its first member is a boss.
    pub boss_setup: Option<BossSetup>,
    /// The boss enrages when a pack mate falls.
    pub commander: bool,
    /// Everyone on the map hears when it is about to come, comes and falls.
    pub world_boss: bool,
}

pub struct Game {
    /// The map this server runs.
    pub map: String,
    /// The typed rules (character sheets, items, looks, combat). Shared, so
    /// a system can hold a rule while it changes the world.
    pub rules: std::sync::Arc<realm_rules::Rules>,
    /// House ids, for characters made by the development store.
    pub houses: Vec<String>,
    pub species: Vec<Species>,
    pub packs: Vec<Pack>,
    pub spawn_point: Vec3,
    /// Where a fallen player rises in town (maps.json respawn_spawn).
    pub town_point: Vec3,
    pub death: DeathRules,
    /// Bottom of the map's height band: a body below it fell out of the map.
    pub y_min: f32,
    pub hp_multiplier: f32,
    attack_multiplier: f32,
    strength: (f32, f32, f32),
    aggro: (f32, f32, u32),
}

fn num(v: &Value, what: &str) -> Result<f32, String> {
    v.as_f64()
        .map(|n| n as f32)
        .ok_or_else(|| format!("content: {what} is missing or not a number"))
}

fn ticks(seconds: f32) -> u16 {
    libm::roundf(seconds * realm_sim::SIM_HZ as f32) as u16
}

impl Game {
    /// The rules for one map: only its own creature packs, its spawn point.
    pub fn from_content(content: &Content, map: &str) -> Result<Self, String> {
        let get = |name: &str| {
            content
                .file(name)
                .ok_or_else(|| format!("content: {name} missing"))
        };
        let mobs = get("mobs.json")?;
        let spawns = get("spawn_tables.json")?;
        let combat = get("combat.json")?;
        let maps = get("maps.json")?;
        let loot = get("loot_tables.json")?;

        let rules = realm_rules::Rules::from_content(content)?;
        let mut species = Vec::new();
        for id in &rules.mobs.species_order {
            let def = &mobs["mobs"][id.as_str()];
            if def.is_object() {
                let base = &def["base"];
                let brain = rules.mobs.brain(id).cloned().unwrap_or_default();
                let bolt = match &brain.bolt {
                    Some(spell) => {
                        let s = rules.combat.spell(spell).ok_or_else(|| {
                            format!("content: {id} throws unknown spell '{spell}'")
                        })?;
                        Some((s.index, s.projectile_speed, s.range))
                    }
                    None => None,
                };
                species.push(Species {
                    id: id.clone(),
                    max_hp: num(&base["max_hp"], &format!("{id} max_hp"))?,
                    attack_power: num(&base["attack_power"], &format!("{id} attack_power"))?,
                    move_speed: num(&base["move_speed"], &format!("{id} move_speed"))?,
                    attack_range: num(&base["attack_range"], &format!("{id} attack_range"))?,
                    attack_cooldown_ticks: ticks(num(
                        &base["attack_cooldown"],
                        &format!("{id} attack_cooldown"),
                    )?),
                    brain,
                    bolt,
                    object: false,
                    loot_table: def["loot_table"].as_str().unwrap_or("").to_owned(),
                    pays: def["role"].as_str() != Some("object"),
                });
            } else {
                // A Dark Shard type's body or the training dummy.
                let max_hp = rules
                    .mobs
                    .stone_types
                    .iter()
                    .find(|(k, _)| realm_rules::creatures::stone_species(k) == *id)
                    .map_or(rules.mobs.dummy_hp, |(_, t)| t.max_hp);
                species.push(Species {
                    id: id.clone(),
                    max_hp,
                    attack_power: 0.0,
                    move_speed: 0.0,
                    attack_range: 0.0,
                    attack_cooldown_ticks: 0,
                    brain: realm_rules::creatures::Brain::default(),
                    bolt: None,
                    object: true,
                    loot_table: String::new(),
                    pays: true,
                });
            }
        }

        let mut packs = Vec::new();
        for pack in spawns["packs"].as_array().into_iter().flatten() {
            if pack["map"].as_str() != Some(map) {
                continue;
            }
            let mob = pack["mob"].as_str().unwrap_or_default();
            let Some(species_index) = species.iter().position(|s| s.id == mob) else {
                return Err(format!(
                    "content: pack {} uses unknown creature '{mob}'",
                    pack["id"]
                ));
            };
            let area = &pack["area"];
            let boss = pack["boss"].as_bool().unwrap_or(false);
            let (lo, hi) = match pack["respawn_s"].as_array() {
                Some(range) => (
                    num(&range[0], "pack respawn_s")? * 1000.0,
                    num(&range[1], "pack respawn_s")? * 1000.0,
                ),
                None if boss => (
                    num(&loot["respawn_ms"]["pack_boss_min"], "respawn")?,
                    num(&loot["respawn_ms"]["pack_boss_max"], "respawn")?,
                ),
                None => (
                    num(&loot["respawn_ms"]["pack_normal_min"], "respawn")?,
                    num(&loot["respawn_ms"]["pack_normal_max"], "respawn")?,
                ),
            };
            let template = rules
                .mobs
                .templates
                .get(pack["template"].as_str().unwrap_or(""));
            let commander = pack["commander"].as_bool().unwrap_or(false);
            let boss_setup = boss.then(|| BossSetup {
                // The two first bosses predate `boss_key`.
                key: pack["boss_key"]
                    .as_str()
                    .unwrap_or(if commander { "commander" } else { "matriarch" })
                    .to_owned(),
                // The old director's defaults for a template without them.
                style: template
                    .map(|t| t.style.clone())
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| "spider".to_owned()),
                arena_radius: template
                    .map(|t| t.arena_radius)
                    .filter(|r| *r > 0.0)
                    .unwrap_or(18.0),
            });
            packs.push(Pack {
                kind: PackKind::Creatures,
                species: species_index,
                level: pack["level"].as_u64().unwrap_or(1) as u32,
                count: pack["count"].as_u64().unwrap_or(1) as u32,
                boss,
                center: (num(&area[0], "pack area")?, num(&area[1], "pack area")?),
                half_extent: (num(&area[2], "pack area")?, num(&area[3], "pack area")?),
                leash: pack["leash_distance"].as_f64().unwrap_or(40.0) as f32,
                aggressive: pack["aggro_mode"].as_str() == Some("aggressive"),
                assist_radius: pack["assist_radius"].as_f64().unwrap_or(16.0) as f32,
                clear_radius: pack["clear_radius"]
                    .as_f64()
                    .map_or(rules.mobs.tuning.respawn_clear_radius, |r| r as f32),
                respawn_ticks: (u32::from(ticks(lo / 1000.0)), u32::from(ticks(hi / 1000.0))),
                boss_setup,
                commander,
                world_boss: pack["world_boss"].as_bool().unwrap_or(false),
            });
        }
        // Dark Shards and their waves, then the training dummies.
        let object = |kind: PackKind, species: usize, at: [f32; 3], roam: f32, respawn: u32| Pack {
            kind,
            species,
            level: 1,
            count: 1,
            boss: false,
            center: (at[0], at[2]),
            half_extent: (roam, roam),
            leash: 0.0,
            aggressive: false,
            assist_radius: 0.0,
            clear_radius: 0.0,
            respawn_ticks: (respawn, respawn),
            boss_setup: None,
            commander: false,
            world_boss: false,
        };
        for site in rules.mobs.stones.iter().filter(|s| s.map == map) {
            let Some(stone) = rules.mobs.stone_types.get(&site.kind) else {
                return Err(format!(
                    "content: monolith {} has unknown type {}",
                    site.id, site.kind
                ));
            };
            let body = realm_rules::creatures::stone_species(&site.kind);
            let species_index = species.iter().position(|s| s.id == body).unwrap_or(0);
            let respawn = u32::from(ticks(stone.respawn_ms as f32 / 1000.0));
            let mut p = object(
                PackKind::Stone(site.kind.clone()),
                species_index,
                site.pos,
                stone.roam,
                respawn,
            );
            p.level = stone.level;
            let stone_pack = packs.len();
            packs.push(p);
            let mut waves = object(PackKind::Summons(stone_pack), 0, site.pos, 0.0, 0);
            waves.count = 0;
            waves.aggressive = true;
            waves.assist_radius = 20.0;
            waves.leash = 40.0;
            packs.push(waves);
        }
        if map == "grounds" {
            let dummy = species
                .iter()
                .position(|s| s.id == realm_rules::creatures::DUMMY_SPECIES)
                .unwrap_or(0);
            for at in &rules.mobs.dummies {
                packs.push(object(PackKind::Dummy, dummy, *at, 0.0, 0));
            }
        }

        let tuning = &spawns["pack_tuning"];
        let points = &maps["maps"][map]["spawn_points"];
        let spawn = if points["default"].is_array() {
            &points["default"]
        } else {
            points
                .as_object()
                .and_then(|o| o.values().next())
                .ok_or_else(|| format!("map {map}: no spawn points"))?
        };
        Ok(Self {
            map: map.to_owned(),
            rules: std::sync::Arc::new(rules),
            houses: content
                .file("houses.json")
                .and_then(|h| h.as_object())
                .map(|h| h.keys().filter(|k| !k.starts_with('_')).cloned().collect())
                .unwrap_or_default(),
            species,
            packs,
            y_min: maps["maps"][map]["y_min"].as_f64().unwrap_or(-1.0e6) as f32,
            spawn_point: Vec3::new(
                num(&spawn[0], "spawn")?,
                num(&spawn[1], "spawn")?,
                num(&spawn[2], "spawn")?,
            ),
            town_point: {
                let key = maps["maps"][map]["respawn_spawn"]
                    .as_str()
                    .unwrap_or("default");
                let p = &points[key];
                if p.is_array() {
                    Vec3::new(
                        num(&p[0], "town")?,
                        num(&p[1], "town")?,
                        num(&p[2], "town")?,
                    )
                } else {
                    Vec3::new(
                        num(&spawn[0], "spawn")?,
                        num(&spawn[1], "spawn")?,
                        num(&spawn[2], "spawn")?,
                    )
                }
            },
            death: {
                let d = &combat["death"];
                let t = |key: &str, default: f32| {
                    u32::from(ticks(
                        d[key].as_f64().map_or(default, |v| v as f32) / 1000.0,
                    ))
                };
                DeathRules {
                    ready_ticks: t("respawn_ms", 3000.0),
                    auto_ticks: t("auto_respawn_ms", 180_000.0),
                    here_fraction: d["revive_here_fraction"]
                        .as_f64()
                        .map_or(0.5, |v| v as f32)
                        .clamp(0.05, 1.0),
                    here_ward_ticks: t("revive_here_ward_ms", 3000.0),
                }
            },
            hp_multiplier: num(&tuning["hp_multiplier"], "pack_tuning.hp_multiplier")?,
            attack_multiplier: num(
                &tuning["attack_multiplier"],
                "pack_tuning.attack_multiplier",
            )?,
            strength: (
                num(&tuning["hp_strength_base"], "hp_strength_base")?,
                num(&tuning["hp_strength_per_level"], "hp_strength_per_level")?,
                num(&tuning["hp_strength_floor"], "hp_strength_floor")?,
            ),
            aggro: (
                num(&tuning["aggro_radius_low"], "aggro_radius_low")?,
                num(&tuning["aggro_radius_high"], "aggro_radius_high")?,
                tuning["aggro_radius_level"].as_u64().unwrap_or(8) as u32,
            ),
        })
    }

    /// Health and attack power of `species` at `level` (the old encounter
    /// director's pack strength).
    pub fn stats_at(&self, species: usize, level: u32) -> (f32, f32) {
        let (base, per_level, floor) = self.strength;
        let strength = (base + per_level * level as f32).max(floor);
        let s = &self.species[species];
        (
            s.max_hp * self.hp_multiplier * strength,
            s.attack_power * self.attack_multiplier * strength,
        )
    }

    /// A boss's health and attack power from its override.
    pub fn boss_stats(&self, key: &str) -> Option<(f32, f32)> {
        self.rules
            .mobs
            .bosses
            .get(key)
            .map(|b| (b.hp * self.hp_multiplier, b.attack_power))
    }

    /// The pack strength multiplier at `level` (what a creature's numbers
    /// grow by).
    pub fn strength_at(&self, level: u32) -> f32 {
        let (base, per_level, floor) = self.strength;
        (base + per_level * level as f32).max(floor)
    }

    pub fn aggro_radius(&self, level: u32) -> f32 {
        let (low, high, threshold) = self.aggro;
        if level < threshold { low } else { high }
    }
}
