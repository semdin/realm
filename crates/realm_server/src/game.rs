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
}

pub struct Pack {
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
    /// Bottom of the map's height band: a body below it fell out of the map.
    pub y_min: f32,
    pub respawn_ticks: u16,
    hp_multiplier: f32,
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
        for (id, def) in mobs["mobs"].as_object().into_iter().flatten() {
            if id.starts_with('_') {
                continue;
            }
            let base = &def["base"];
            let brain = rules.mobs.brain(id).cloned().unwrap_or_default();
            let bolt = match &brain.bolt {
                Some(spell) => {
                    let s = rules
                        .combat
                        .spell(spell)
                        .ok_or_else(|| format!("content: {id} throws unknown spell '{spell}'"))?;
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
            });
        }
        species.sort_by(|a, b| a.id.cmp(&b.id));

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
            packs.push(Pack {
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
            });
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
            respawn_ticks: ticks(num(&combat["death"]["respawn_ms"], "death.respawn_ms")? / 1000.0),
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

    /// A pack creature's health at its level (old game's pack strength).
    pub fn mob_max_hp(&self, pack: &Pack) -> f32 {
        let (base, per_level, floor) = self.strength;
        let strength = (base + per_level * pack.level as f32).max(floor);
        let boss = if pack.boss { 4.0 } else { 1.0 };
        self.species[pack.species].max_hp * self.hp_multiplier * strength * boss
    }

    pub fn mob_attack(&self, pack: &Pack) -> f32 {
        self.species[pack.species].attack_power * self.attack_multiplier
    }

    pub fn aggro_radius(&self, pack: &Pack) -> f32 {
        let (low, high, level) = self.aggro;
        if pack.level < level { low } else { high }
    }
}
