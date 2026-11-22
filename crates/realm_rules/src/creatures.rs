//! What creatures do on their own (mobs.json, spawn_tables.json): their plain
//! attack, the telegraphed abilities they mix in or throw at a target out of
//! reach, what those leave on a player, and the numbers the brain reads.
//! Every ability, boss pattern and boss extra has one index in
//! [`CreatureRules::abilities`]; telegraph events carry that index.
//!
//! The data's seconds are milliseconds here; the server makes them ticks.

use std::collections::BTreeMap;

use serde_json::Value;

use crate::combat::airborne_ms;

/// Ranged casters close to this distance with a clear line, then plant.
pub const BOLT_REACH: f32 = 15.0;
/// Hit within this long, a creature follows further: its leash stretches.
pub const LEASH_HOT_MS: u32 = 4000;
pub const LEASH_HOT_SCALE: f32 = 1.6;
/// A returning creature heals this share of its health per second, and is
/// home (full health, calm) within this distance of its spawn.
pub const RETURN_REGEN_SHARE: f32 = 0.15;
pub const HOME_RADIUS: f32 = 1.3;
/// A melee creature whose target stays out of reach this long gives up.
pub const UNREACHABLE_MS: u32 = 2000;
/// Aggressive creatures look for a player this often.
pub const AGGRO_SCAN_MS: u32 = 350;
/// A plain melee attack that winds up reaches this much further (the
/// creature lunges as it releases).
pub const MELEE_LUNGE: f32 = 0.35;
pub const MELEE_SLACK: f32 = 0.4;
/// Pace of a creature stepping after a retreating target while it winds
/// up, and of one walking to its place on the ring.
pub const WINDUP_STEP: f32 = 0.6;
pub const RING_PACE: f32 = 0.7;
/// A combo's next blow starts this long after the last one lands (ms) when
/// its data names no `gap`.
pub const CHAIN_GAP_MS: u32 = 200;
/// A player sees a mark this long after it is laid (its reaction and the
/// way to it, ms); a phase or a difficulty never shortens a windup below the
/// time such a player needs to run out of it (one authored shorter keeps its
/// own length: a combo's follow-up, aimed ahead of a player already moving).
pub const REACTION_MS: u32 = 350;
/// Where a fair windup assumes the player stands from the creature (m).
const FAIR_STAND: f32 = 1.5;
const FAIR_STAND_CONE: f32 = 3.0;
/// A boss keeps the target it turned on this long before another
/// attacker's blow turns it (ms).
pub const BOSS_TARGET_LOCK_MS: u32 = 5000;
/// A lead never reaches further ahead of the target than this (m).
pub const LEAD_REACH: f32 = 5.0;
/// Plain attack timings when the species names none.
const MELEE_TIMING: (u32, u32) = (420, 350);
const BOLT_TIMING: (u32, u32) = (550, 500);

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Shape {
    /// A disc of `radius` around the target's feet (`at_target`) or `offset`
    /// metres along the creature's facing (negative: behind it).
    Area {
        radius: f32,
        offset: f32,
        at_target: bool,
    },
    /// A wedge from the body: `range` flat, `half_angle` radians each side.
    Cone { range: f32, half_angle: f32 },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Trigger {
    /// Mixed into the plain attacks: every Nth attack.
    Every(u32),
    /// Thrown at a target between the ranges, on its own cooldown.
    Thrown {
        min_range: f32,
        max_range: f32,
        cooldown_ms: u32,
    },
    /// A boss pattern, cycled in order.
    Pattern,
}

/// Venom: attack power x `ratio` per beat.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Poison {
    pub ratio: f32,
    pub ticks: u32,
    pub interval_ms: u32,
}

/// What an ability leaves on each player it hits.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Riders {
    pub stun_ms: u32,
    /// Slowed on foot (WEB_FACTOR).
    pub web_ms: u32,
    /// Bound where it stands (a web, a hex): no walking, casting still free.
    pub root_ms: u32,
    /// No natural health or mana regeneration.
    pub despair_ms: u32,
    /// Thrown: metres per second away from the creature, and up.
    pub push: f32,
    pub lift: f32,
    pub poison: Option<Poison>,
    /// The creature heals this share of the damage it dealt.
    pub drain: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AbilityDef {
    pub index: u16,
    /// "species/id", "pattern/style/n" or "boss/key/id".
    pub key: String,
    /// Effect id the client plays for it (spells.json-style `spell_id`).
    pub fx: String,
    /// Creature clip slot.
    pub clip: String,
    /// What flies from the creature to the centre ("boulder"), if anything.
    pub flight: String,
    pub impact_fx: String,
    pub shape: Shape,
    pub trigger: Trigger,
    pub windup_ms: u32,
    pub recovery_ms: u32,
    pub damage_multiplier: f32,
    pub riders: Riders,
    /// Boss patterns: only from this phase on.
    pub min_phase: u8,
    /// Multi-part bosses: one strike per standing part.
    pub per_part: bool,
    /// Its name in its own list ("swing"; empty when the data names none).
    pub id: String,
    /// A combo: the ability that starts `chain_ms` after this one lands,
    /// aimed afresh at where the target is then.
    pub then: Option<u16>,
    pub chain_ms: u32,
    /// Only a combo's follow-up or a phase's opener, never picked alone.
    pub chain_only: bool,
    /// A boss picks it while its target stands this far away (m, from..to);
    /// None: within its reach.
    pub band: Option<(f32, f32)>,
    /// A boss's odds of picking it among those that fit.
    pub weight: f32,
    /// Aimed where the target will be this long from now at its pace (ms):
    /// running straight on does not leave the mark.
    pub lead_ms: u32,
    /// A boss pattern's own rest after it was picked (ms; 0: none).
    pub rest_ms: u32,
    /// Only an elite of the species uses it.
    pub elite_only: bool,
    /// Odds it is used when its trigger comes round (1: always); missed, a
    /// thrown one tries again after a third of its cooldown, a mixed-in one
    /// leaves the plain attack.
    pub chance: f32,
}

/// A pallid's cold: players near a fighting one lose health and hope.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Aura {
    pub radius: f32,
    pub damage_ratio: f32,
    pub despair_ms: u32,
}

/// One species' own fighting.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Brain {
    /// Plain attack windup and recovery; (0, 0) never attacks on its own.
    pub windup_ms: u32,
    pub recovery_ms: u32,
    /// A caster: the spell its plain attack throws.
    pub bolt: Option<String>,
    /// Indices into [`CreatureRules::abilities`], data order.
    pub abilities: Vec<u16>,
    pub aura: Option<Aura>,
    /// Share of a blow from in front (~60 degrees) a shield-bearer ignores.
    pub front_guard: f32,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Elite {
    pub chance: f32,
    pub hp_mult: f32,
    pub attack_mult: f32,
    pub exp_mult: f32,
}

/// spawn_tables.json pack_tuning: placement, the attack ring, spacing.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PackTuning {
    pub attack_slots: u32,
    pub slot_ring: f32,
    pub separation_radius: f32,
    pub separation_weight: f32,
    pub pack_spacing: f32,
    pub placement_attempts: u32,
    pub respawn_clear_radius: f32,
    pub respawn_retry_ms: u32,
}

/// A boss's own numbers (spawn_tables.json boss_overrides).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct BossDef {
    pub key: String,
    pub name: String,
    /// Health before pack_tuning.hp_multiplier.
    pub hp: f32,
    pub attack_power: f32,
    pub attack_range: f32,
    pub move_speed: f32,
    pub exp_reward: u32,
    /// Indices of its extra abilities.
    pub extras: Vec<u16>,
    /// The level its numbers are authored for (0: they hold at any level);
    /// a dungeon boss at another level scales by the pack strength ratio.
    pub stat_level: u32,
    /// A multi-part boss: each part's health (before scaling).
    pub part_hp: f32,
    /// It enrages after this long fighting (0: never on its own).
    pub enrage_s: f32,
    /// Fight phases by health (the second, third...), highest first.
    pub phases: Vec<Phase>,
    /// It sprints at a target that keeps away.
    pub rush: Option<Rush>,
}

/// A boss's fight phase: from below `below` of its health on, its windups
/// and its cooldown run at these shares, and it opens the phase with the
/// pattern `opener` (an id in its style's list).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Phase {
    pub below: f32,
    pub windup: f32,
    pub cooldown: f32,
    pub opener: String,
}

/// A boss sprints `speed` x its pace for `ms` at a target further than
/// `beyond`, then waits `cooldown_ms` before it sprints again.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rush {
    pub beyond: f32,
    pub speed: f32,
    pub ms: u32,
    pub cooldown_ms: u32,
}

/// A boss made of parts (Threehead's heads, the Strangling Vine's vines):
/// each part a creature of `species` held at its bone on the body.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PartsDef {
    pub species: String,
    /// (bone key, rest position in the model, which faces +z)
    pub offsets: Vec<(String, [f32; 3])>,
    /// The body's health is its parts' together; it falls with the last.
    pub hp_is_sum: bool,
}

/// An encounter template (spawn_tables.json templates).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Template {
    /// Boss pattern style ("troll", "wraith", ...); empty for a plain pack.
    pub style: String,
    /// A boss's leash.
    pub arena_radius: f32,
}

/// A commander's rage when a pack mate falls.
pub const ENRAGE_ATTACK: f32 = 1.3;
pub const ENRAGE_SPEED: f32 = 1.25;
pub const ENRAGE_COOLDOWN: f32 = 0.8;

/// One wave a Dark Shard calls when its health drops to `ratio`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Wave {
    pub ratio: f32,
    /// (species, count, level, how many of the count come as elites).
    pub spawns: Vec<(String, u32, u32, u32)>,
}

/// A kind of Dark Shard (spawn_tables.json monolith_types).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct StoneType {
    pub key: String,
    pub name: String,
    pub level: u32,
    pub max_hp: f32,
    pub exp_reward: u32,
    pub respawn_ms: u32,
    pub loot_table: String,
    /// Waves land this far from the stone (m).
    pub spawn_distance: (f32, f32),
    /// It comes back within this far of its site (m).
    pub roam: f32,
    pub waves: Vec<Wave>,
    /// More creatures while players keep striking it.
    pub reinforce: Option<Reinforce>,
}

/// A stone under attack calls `count` creatures (picked in turn from `mobs`:
/// species, level) every `every_ms`, while fewer than `cap` it called that
/// way still live.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Reinforce {
    pub every_ms: u32,
    pub mobs: Vec<(String, u32)>,
    pub count: u32,
    pub cap: u32,
}

/// A Dark Shard's site (spawn_tables.json monoliths).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct StoneSite {
    pub id: u32,
    pub kind: String,
    pub map: String,
    pub pos: [f32; 3],
}

#[derive(Clone, Debug, Default)]
pub struct CreatureRules {
    pub abilities: Vec<AbilityDef>,
    pub brains: BTreeMap<String, Brain>,
    /// Boss attack style -> its patterns, in cycle order.
    pub patterns: BTreeMap<String, Vec<u16>>,
    /// Boss key -> its extra abilities.
    pub boss_extras: BTreeMap<String, Vec<u16>>,
    pub elite: Elite,
    pub tuning: PackTuning,
    pub bosses: BTreeMap<String, BossDef>,
    pub templates: BTreeMap<String, Template>,
    pub stone_types: BTreeMap<String, StoneType>,
    pub stones: Vec<StoneSite>,
    /// Training dummy posts on the grounds, its name and health.
    pub dummies: Vec<[f32; 3]>,
    pub dummy_name: String,
    pub dummy_hp: f32,
    /// Species -> its parts (a multi-part boss).
    pub parts: BTreeMap<String, PartsDef>,
    /// Snapshot creature kinds: kind = index here + 1. The species of
    /// mobs.json sorted by id, then a body per Dark Shard type
    /// (`stone_<type>`), then `training_dummy`.
    pub species_order: Vec<String>,
}

/// The species id of a Dark Shard type's body.
#[must_use]
pub fn stone_species(kind: &str) -> String {
    format!("stone_{kind}")
}

pub const DUMMY_SPECIES: &str = "training_dummy";

fn point(v: &Value) -> [f32; 3] {
    [f(&v[0], 0.0), f(&v[1], 0.0), f(&v[2], 0.0)]
}

fn f(v: &Value, default: f32) -> f32 {
    v.as_f64().map_or(default, |x| x as f32)
}

fn ms_of_seconds(v: &Value) -> u32 {
    (f(v, 0.0).max(0.0) * 1000.0).round() as u32
}

fn text(v: &Value) -> String {
    v.as_str().unwrap_or("").to_owned()
}

/// How long a thrown player is locked: until it lands, and at least a beat
/// that grows with the shove (old `shove_lock_ms`).
#[must_use]
pub fn shove_lock_ms(push: f32, lift: f32) -> u32 {
    let floor = (push.abs() * 70.0).clamp(300.0, 700.0) as u32;
    airborne_ms(lift, floor)
}

fn ability(index: u16, key: String, a: &Value, pattern: bool) -> Result<AbilityDef, String> {
    let shape = match a["kind"].as_str().unwrap_or("area") {
        "area" | "slam" => Shape::Area {
            radius: f(&a["radius"], 0.0),
            offset: f(&a["offset"], 0.0),
            at_target: a["at_target"].as_bool().unwrap_or(false),
        },
        "directional" => Shape::Cone {
            range: f(&a["range"], 0.0),
            half_angle: f(&a["half_angle"], 0.5),
        },
        other => return Err(format!("creature ability {key}: unknown kind '{other}'")),
    };
    let trigger = if a["every"].is_u64() {
        Trigger::Every(a["every"].as_u64().unwrap_or(1).max(1) as u32)
    } else if a["max_range"].is_number() {
        Trigger::Thrown {
            min_range: f(&a["min_range"], 0.0),
            max_range: f(&a["max_range"], 0.0),
            cooldown_ms: ms_of_seconds(&a["cooldown"]),
        }
    } else if pattern {
        Trigger::Pattern
    } else {
        return Err(format!(
            "creature ability {key}: neither `every` nor a range band"
        ));
    };
    let poison = &a["poison"];
    Ok(AbilityDef {
        index,
        key,
        fx: text(&a["spell_id"]),
        clip: text(&a["clip"]),
        flight: text(&a["fx"]),
        impact_fx: text(&a["impact_fx"]),
        shape,
        trigger,
        windup_ms: ms_of_seconds(&a["anticipation"]),
        recovery_ms: ms_of_seconds(&a["recovery"]),
        damage_multiplier: f(&a["damage_multiplier"], 1.0),
        riders: Riders {
            stun_ms: ms_of_seconds(&a["stun_s"]),
            web_ms: ms_of_seconds(&a["web_s"]),
            root_ms: ms_of_seconds(&a["root_s"]),
            despair_ms: ms_of_seconds(&a["despair_s"]),
            push: f(&a["push"], 0.0),
            lift: f(&a["lift"], 0.0),
            poison: poison.is_object().then(|| Poison {
                ratio: f(&poison["ratio"], 0.0),
                ticks: poison["ticks"].as_u64().unwrap_or(0) as u32,
                interval_ms: poison["interval_ms"].as_u64().unwrap_or(1000).max(1) as u32,
            }),
            drain: f(&a["drain"], 0.0),
        },
        min_phase: a["min_phase"].as_u64().unwrap_or(0) as u8,
        per_part: a["per_part"].as_bool().unwrap_or(false),
        id: text(&a["id"]),
        then: None,
        chain_ms: if a["gap"].is_number() {
            ms_of_seconds(&a["gap"])
        } else {
            CHAIN_GAP_MS
        },
        chain_only: a["chain_only"].as_bool().unwrap_or(false),
        band: a["use"]
            .as_array()
            .filter(|b| b.len() == 2)
            .map(|b| (f(&b[0], 0.0), f(&b[1], 0.0))),
        weight: f(&a["weight"], 1.0).max(0.0),
        lead_ms: ms_of_seconds(&a["lead"]),
        rest_ms: ms_of_seconds(&a["rest"]),
        elite_only: a["elite_only"].as_bool().unwrap_or(false),
        chance: f(&a["chance"], 1.0).clamp(0.0, 1.0),
    })
}

/// Joins a list's combos: each `then` names another ability of the same
/// list by its `id`.
fn link(
    rules: &mut CreatureRules,
    list: &[u16],
    data: &[Value],
    owner: &str,
) -> Result<(), String> {
    for (k, a) in data.iter().enumerate() {
        let Some(next) = a["then"].as_str() else {
            continue;
        };
        let Some(&to) = list
            .iter()
            .find(|&&i| rules.abilities[usize::from(i)].id == next)
        else {
            return Err(format!("{owner}: `then` names '{next}', not in its list"));
        };
        rules.abilities[usize::from(list[k])].then = Some(to);
    }
    // A combo that runs back into itself would never end.
    for &start in list {
        let mut seen = vec![start];
        let mut at = rules.abilities[usize::from(start)].then;
        while let Some(i) = at {
            if seen.contains(&i) {
                return Err(format!(
                    "{owner}: the combo from '{}' runs in a circle",
                    rules.abilities[usize::from(start)].id
                ));
            }
            seen.push(i);
            at = rules.abilities[usize::from(i)].then;
        }
    }
    Ok(())
}

fn phases(o: &Value) -> Vec<Phase> {
    let mut list: Vec<Phase> = o["phases"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|p| Phase {
            below: f(&p["below"], 0.5),
            windup: f(&p["windup"], 1.0).clamp(0.3, 2.0),
            cooldown: f(&p["cooldown"], 1.0).clamp(0.3, 2.0),
            opener: text(&p["opener"]),
        })
        .collect();
    list.sort_by(|a, b| b.below.total_cmp(&a.below));
    list
}

impl AbilityDef {
    /// The shortest fair windup at a run of `speed` (m/s): out of a disc
    /// laid on the player (at the target or off the creature's front), out
    /// of a ring round the creature from FAIR_STAND off it, out of a wedge
    /// sideways or to its end from FAIR_STAND_CONE in front.
    #[must_use]
    pub fn fair_windup_ms(&self, speed: f32) -> u32 {
        let way = match self.shape {
            Shape::Area {
                radius,
                offset,
                at_target,
            } => {
                if at_target || offset != 0.0 {
                    radius
                } else {
                    (radius - FAIR_STAND).max(0.0)
                }
            }
            Shape::Cone { range, half_angle } => (range - FAIR_STAND_CONE)
                .max(0.0)
                .min(FAIR_STAND_CONE * half_angle.clamp(0.0, 1.5).sin()),
        };
        REACTION_MS + (way / speed.max(0.1) * 1000.0) as u32
    }
}

impl CreatureRules {
    pub fn from_json(mobs: &Value, spawns: &Value) -> Result<Self, String> {
        let mut rules = Self::default();
        let push = |rules: &mut Self, key: String, a: &Value, pattern: bool| {
            let index = u16::try_from(rules.abilities.len())
                .map_err(|_| "too many creature abilities".to_owned())?;
            rules.abilities.push(ability(index, key, a, pattern)?);
            Ok::<u16, String>(index)
        };
        for (id, m) in mobs["mobs"].as_object().into_iter().flatten() {
            if m["parts"].is_object() {
                let p = &m["parts"];
                rules.parts.insert(
                    id.clone(),
                    PartsDef {
                        species: p["species"].as_str().unwrap_or("").to_owned(),
                        offsets: p["offsets"]
                            .as_object()
                            .into_iter()
                            .flatten()
                            .map(|(k, v)| {
                                (k.clone(), [f(&v[0], 0.0), f(&v[1], 0.0), f(&v[2], 0.0)])
                            })
                            .collect(),
                        hp_is_sum: p["hp_is_sum"].as_bool().unwrap_or(false),
                    },
                );
            }
            let mut abilities = Vec::new();
            for a in m["abilities"].as_array().into_iter().flatten() {
                let key = format!("{id}/{}", a["id"].as_str().unwrap_or("?"));
                abilities.push(push(&mut rules, key, a, false)?);
            }
            let data: Vec<Value> = m["abilities"].as_array().cloned().unwrap_or_default();
            link(&mut rules, &abilities, &data, id)?;
            let bolt = m["bolt"].as_str().map(str::to_owned);
            let base = &m["base"];
            let (windup_ms, recovery_ms) = if base["windup"].is_number() {
                (
                    ms_of_seconds(&base["windup"]),
                    ms_of_seconds(&base["recovery"]),
                )
            } else if bolt.is_some() {
                BOLT_TIMING
            } else {
                MELEE_TIMING
            };
            let aura = &m["aura"];
            rules.brains.insert(
                id.clone(),
                Brain {
                    windup_ms,
                    recovery_ms,
                    bolt,
                    abilities,
                    aura: aura.is_object().then(|| Aura {
                        radius: f(&aura["radius"], 0.0),
                        damage_ratio: f(&aura["damage_ratio"], 0.0),
                        despair_ms: ms_of_seconds(&aura["despair_s"]),
                    }),
                    front_guard: f(&m["front_guard"], 0.0),
                },
            );
        }
        for (style, list) in spawns["boss_patterns"].as_object().into_iter().flatten() {
            let mut cycle = Vec::new();
            for (n, a) in list.as_array().into_iter().flatten().enumerate() {
                cycle.push(push(&mut rules, format!("pattern/{style}/{n}"), a, true)?);
            }
            let data: Vec<Value> = list.as_array().cloned().unwrap_or_default();
            link(&mut rules, &cycle, &data, &format!("boss_patterns.{style}"))?;
            rules.patterns.insert(style.clone(), cycle);
        }
        for (key, o) in spawns["boss_overrides"].as_object().into_iter().flatten() {
            let mut extras = Vec::new();
            for a in o["abilities"].as_array().into_iter().flatten() {
                let akey = format!("boss/{key}/{}", a["id"].as_str().unwrap_or("?"));
                extras.push(push(&mut rules, akey, a, false)?);
            }
            let data: Vec<Value> = o["abilities"].as_array().cloned().unwrap_or_default();
            link(&mut rules, &extras, &data, key)?;
            rules.boss_extras.insert(key.clone(), extras);
        }
        let e = &mobs["elite"];
        rules.elite = Elite {
            chance: f(&e["chance"], 0.0),
            hp_mult: f(&e["hp_mult"], 1.0),
            attack_mult: f(&e["attack_mult"], 1.0),
            exp_mult: f(&e["exp_mult"], 1.0),
        };
        for (key, o) in spawns["boss_overrides"].as_object().into_iter().flatten() {
            rules.bosses.insert(
                key.clone(),
                BossDef {
                    key: key.clone(),
                    name: text(&o["name"]),
                    hp: f(&o["hp"], 1000.0),
                    attack_power: f(&o["attack_power"], 50.0),
                    attack_range: f(&o["attack_range"], 4.5),
                    move_speed: f(&o["move_speed"], 3.0),
                    exp_reward: o["exp_reward"].as_u64().unwrap_or(0) as u32,
                    extras: rules.boss_extras.get(key).cloned().unwrap_or_default(),
                    stat_level: o["stat_level"].as_u64().unwrap_or(0) as u32,
                    part_hp: f(&o["part_hp"], 0.0),
                    enrage_s: f(&o["enrage_s"], 0.0),
                    phases: phases(o),
                    rush: o["rush"].is_object().then(|| Rush {
                        beyond: f(&o["rush"]["beyond"], 10.0),
                        speed: f(&o["rush"]["speed"], 1.8).max(1.0),
                        ms: ms_of_seconds(&o["rush"]["seconds"]),
                        cooldown_ms: ms_of_seconds(&o["rush"]["cooldown"]),
                    }),
                },
            );
        }
        for (key, t) in spawns["templates"].as_object().into_iter().flatten() {
            rules.templates.insert(
                key.clone(),
                Template {
                    style: text(&t["attack_style"]),
                    arena_radius: f(&t["arena_radius"], 0.0),
                },
            );
        }
        for (key, t) in spawns["monolith_types"].as_object().into_iter().flatten() {
            let mut waves = Vec::new();
            for w in t["wave_thresholds"].as_array().into_iter().flatten() {
                let spawns = w["spawns"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|s| {
                        (
                            text(&s["mob"]),
                            s["count"].as_u64().unwrap_or(1) as u32,
                            s["level"].as_u64().unwrap_or(1) as u32,
                            s["elite"].as_u64().unwrap_or(0) as u32,
                        )
                    })
                    .collect();
                waves.push(Wave {
                    ratio: f(&w["ratio"], 0.5),
                    spawns,
                });
            }
            waves.sort_by(|a, b| b.ratio.total_cmp(&a.ratio));
            rules.stone_types.insert(
                key.clone(),
                StoneType {
                    key: key.clone(),
                    name: text(&t["name"]),
                    level: t["level"].as_u64().unwrap_or(1) as u32,
                    max_hp: f(&t["max_hp"], 1000.0),
                    exp_reward: t["exp_reward"].as_u64().unwrap_or(0) as u32,
                    respawn_ms: t["respawn_ms"].as_u64().unwrap_or(30_000) as u32,
                    loot_table: text(&t["loot_table"]),
                    spawn_distance: (
                        f(&t["spawn_distance_min"], 4.0),
                        f(&t["spawn_distance_max"], 9.0),
                    ),
                    roam: f(&t["roam"], 30.0),
                    waves,
                    reinforce: t["reinforce"].is_object().then(|| {
                        let r = &t["reinforce"];
                        Reinforce {
                            every_ms: r["every_ms"].as_u64().unwrap_or(15_000).max(1000) as u32,
                            mobs: r["mobs"]
                                .as_array()
                                .into_iter()
                                .flatten()
                                .filter_map(|m| {
                                    Some((m[0].as_str()?.to_owned(), m[1].as_u64()? as u32))
                                })
                                .collect(),
                            count: r["count"].as_u64().unwrap_or(1) as u32,
                            cap: r["cap"].as_u64().unwrap_or(4) as u32,
                        }
                    }),
                },
            );
        }
        for m in spawns["monoliths"].as_array().into_iter().flatten() {
            let zone = m["zone"].as_str().unwrap_or("");
            rules.stones.push(StoneSite {
                id: m["id"].as_u64().unwrap_or(0) as u32,
                kind: m["type"].as_str().unwrap_or("dark").to_owned(),
                // The old game told the caverns apart by zone name.
                map: if zone.starts_with("caverns") {
                    "spider_caverns"
                } else {
                    "grounds"
                }
                .to_owned(),
                pos: point(&m["pos"]),
            });
        }
        rules.dummies = spawns["dummies"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|d| point(&d["pos"]))
            .collect();
        rules.dummy_name = text(&spawns["dummy_config"]["name"]);
        rules.dummy_hp = f(&spawns["dummy_config"]["max_hp"], 800.0);
        let mut order: Vec<String> = mobs["mobs"]
            .as_object()
            .into_iter()
            .flatten()
            .map(|(id, _)| id.clone())
            .filter(|id| !id.starts_with('_'))
            .collect();
        order.sort();
        order.extend(rules.stone_types.keys().map(|k| stone_species(k)));
        order.push(DUMMY_SPECIES.to_owned());
        rules.species_order = order;
        let t = &spawns["pack_tuning"];
        rules.tuning = PackTuning {
            attack_slots: t["attack_slots"].as_u64().unwrap_or(3) as u32,
            slot_ring: f(&t["attack_slot_ring"], 3.4),
            separation_radius: f(&t["separation_radius"], 1.7),
            separation_weight: f(&t["separation_weight"], 1.35),
            pack_spacing: f(&t["pack_spacing"], 3.1),
            placement_attempts: t["placement_attempts"].as_u64().unwrap_or(40) as u32,
            respawn_clear_radius: f(&t["respawn_clear_radius"], 16.0),
            respawn_retry_ms: ms_of_seconds(&t["respawn_retry_seconds"]),
        };
        Ok(rules)
    }

    #[must_use]
    pub fn brain(&self, species: &str) -> Option<&Brain> {
        self.brains.get(species)
    }

    #[must_use]
    pub fn ability(&self, index: u16) -> Option<&AbilityDef> {
        self.abilities.get(usize::from(index))
    }

    /// The ability named `id` among `list`.
    #[must_use]
    pub fn named(&self, list: &[u16], id: &str) -> Option<u16> {
        if id.is_empty() {
            return None;
        }
        list.iter()
            .copied()
            .find(|&i| self.ability(i).is_some_and(|a| a.id == id))
    }
}
