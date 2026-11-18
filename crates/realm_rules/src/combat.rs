//! Combat rules: the spells, what a cast costs and deals, critical hits,
//! armour, resistances, skills and regeneration (combat.json, spells.json,
//! mobs.json). Pure numbers; the map server runs the casts and applies the
//! results, the client shows them.
//!
//! The formulas are the old game's (rules.gd spell maths and the authority's
//! damage path); `crate::Rules::damage_*` below lists the order.

use std::collections::BTreeMap;

use realm_data::{Content, without_notes};
use serde_json::Value;

use crate::sheet::CharacterSheet;

/// The basic attack: it chains (combo), rolls the wand's Attack Value and is
/// sped up by attack speed; every other spell rolls the Magic Attack Value and
/// is sped up by cast speed.
pub const BASIC_SPELL: &str = "basic_cast";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Delivery {
    /// A bolt that flies to a body or a point and hits one target.
    Projectile,
    /// A bolt that bursts where it lands, hurting everything in `radius`.
    ProjectileAoe,
    /// Everything in front of the caster within `range` and `cone_angle`.
    Cone,
    /// On the caster (the ward).
    SelfCast,
}

/// A damage-over-time rider (burn, bleed).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Dot {
    pub damage: f32,
    pub ticks: u32,
    pub interval_ms: u32,
    /// Bleed: a share of the hit added to each tick.
    pub hit_share: f32,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Slow {
    pub ms: u32,
    pub boss_ms: u32,
    /// Speed while slowed (0.6 = 40 % slower).
    pub factor: f32,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Launch {
    pub push: f32,
    pub lift: f32,
    pub land_stun_ms: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SpellDef {
    pub id: String,
    /// Index in `CombatRules::spell_order` (wire id + 1 in inputs).
    pub index: u8,
    pub element: String,
    pub delivery: Delivery,
    pub damage: f32,
    pub magic_attack_coef: f32,
    pub cooldown: f32,
    pub mana_cost: u32,
    pub cast_lock: f32,
    pub range: f32,
    pub projectile_speed: f32,
    pub radius: f32,
    pub falloff_floor: f32,
    pub cone_angle: f32,
    pub combo_multipliers: Vec<f32>,
    pub combo_window: f32,
    pub requires_level: u16,
    pub requires_house_rank: u8,
    pub knockback: f32,
    pub interrupts: bool,
    /// The ward: how long it lasts, what it does to bolts and other hits.
    pub duration_ms: u32,
    pub reflects: bool,
    pub other_damage_multiplier: f32,
    /// Creature families a hit breaks the attack of.
    pub banishes: Vec<String>,
    pub stun_ms: u32,
    pub stun_ms_boss: u32,
    pub freeze_ms: u32,
    pub freeze_ms_boss: u32,
    pub slow: Option<Slow>,
    pub burn: Option<Dot>,
    pub bleed: Option<Dot>,
    pub launch: Option<Launch>,
    pub weaken_ms: u32,
    pub weaken_factor: f32,
}

#[derive(Clone, Debug, Default)]
pub struct HouseMods {
    pub hp_multiplier: f32,
    pub mana_multiplier: f32,
    pub cooldown_multiplier: f32,
    pub spell_damage: BTreeMap<String, f32>,
    pub mana_regen: Option<f32>,
}

#[derive(Clone, Debug, Default)]
pub struct SkillRules {
    pub max_level: u8,
    pub master_level: u8,
    pub upgradeable: Vec<String>,
    pub damage_per_level: f32,
    pub master_damage_bonus: f32,
    pub cooldown_per_level: f32,
    pub effect_per_level: f32,
}

/// What a creature brings to a hit (mobs.json).
#[derive(Clone, Debug, Default)]
pub struct CreatureDef {
    pub family: String,
    /// Element -> reduction (1 = immune, negative = weak).
    pub resist: BTreeMap<String, f32>,
    pub displace_resist: f32,
    /// A hit drains mana before health (the pallids).
    pub mana_first: bool,
}

/// What the control enchantments do when they proc on a hit (combat.json
/// enchant.stats stun_chance / slow_chance / burn_chance).
#[derive(Clone, Debug, Default)]
pub struct ProcSpecs {
    pub stun_ms: u32,
    /// No new stun proc until this long after the last one ends.
    pub stun_grace_ms: u32,
    pub slow_ms: u32,
    pub slow_factor: f32,
    pub burn: Dot,
}

/// Gravity a thrown body falls under, m/s².
pub const LAUNCH_GRAVITY: f32 = 24.0;

/// How long a throw of `lift` m/s keeps a body in the air (it lands where it
/// took off), at least `floor_ms`.
#[must_use]
pub fn airborne_ms(lift: f32, floor_ms: u32) -> u32 {
    floor_ms.max((2.0 * lift.max(0.0) / LAUNCH_GRAVITY * 1000.0).round() as u32)
}

#[derive(Clone, Debug, Default)]
pub struct CombatRules {
    pub procs: ProcSpecs,
    pub spells: BTreeMap<String, SpellDef>,
    /// Spells by index (inputs carry the index).
    pub spell_order: Vec<String>,
    pub crit_base: f32,
    pub crit_finisher_bonus: f32,
    pub crit_max: f32,
    pub crit_multiplier: f32,
    pub houses: BTreeMap<String, HouseMods>,
    pub skills: SkillRules,
    pub hp_regen: f32,
    pub mana_regen: f32,
    pub armor_base: f32,
    pub armor_per_level: f32,
    pub armor_max_reduction: f32,
    pub resist_cap: f32,
    pub block_cap: f32,
    pub dodge_cap: f32,
    pub reflect_cap: f32,
    pub life_steal_cap: f32,
    /// Creature attack id -> "melee" / "projectile" / "spell".
    pub mob_attack_kinds: BTreeMap<String, String>,
    /// Creature family -> the "strong against" enchantment stat.
    pub family_stats: BTreeMap<String, String>,
    pub creatures: BTreeMap<String, CreatureDef>,
    pub house_rank_thresholds: Vec<u32>,
}

fn f(v: &Value, default: f32) -> f32 {
    v.as_f64().map_or(default, |x| x as f32)
}

fn ms(v: &Value) -> u32 {
    v.as_u64()
        .or_else(|| v.as_f64().map(|x| x.max(0.0) as u64))
        .unwrap_or(0) as u32
}

fn dot(v: &Value) -> Option<Dot> {
    v.is_object().then(|| Dot {
        damage: f(&v["damage"], 0.0),
        ticks: ms(&v["ticks"]),
        interval_ms: ms(&v["interval_ms"]).max(1),
        hit_share: f(&v["hit_share"], 0.0),
    })
}

impl CombatRules {
    pub(crate) fn from_content(content: &Content) -> Result<Self, String> {
        let file = |name: &str| {
            content
                .file(name)
                .map(without_notes)
                .ok_or_else(|| format!("content has no {name}"))
        };
        let combat = file("combat.json")?;
        let spells_file = file("spells.json")?;
        let mobs = file("mobs.json")?;
        let mut rules = Self::default();
        for (id, s) in spells_file.as_object().into_iter().flatten() {
            let delivery = match s["delivery"].as_str().unwrap_or("projectile") {
                "projectile" => Delivery::Projectile,
                "projectile_aoe" => Delivery::ProjectileAoe,
                "cone" => Delivery::Cone,
                "self" => Delivery::SelfCast,
                other => return Err(format!("spell {id}: unknown delivery '{other}'")),
            };
            let index = u8::try_from(rules.spell_order.len())
                .ok()
                .filter(|i| *i < 15)
                .ok_or("more than 15 spells: the input field holds 4 bits")?;
            rules.spell_order.push(id.clone());
            rules.spells.insert(
                id.clone(),
                SpellDef {
                    id: id.clone(),
                    index,
                    element: s["element"].as_str().unwrap_or("arcane").to_owned(),
                    delivery,
                    damage: f(&s["damage"], 0.0),
                    magic_attack_coef: f(&s["magic_attack_coef"], 1.0),
                    cooldown: f(&s["cooldown"], 0.0),
                    mana_cost: ms(&s["mana_cost"]),
                    cast_lock: f(&s["cast_lock"], 0.28),
                    range: f(&s["range"], 30.0),
                    projectile_speed: f(&s["projectile_speed"], 40.0),
                    radius: f(&s["radius"], 0.0),
                    falloff_floor: f(&s["falloff_floor"], 0.4),
                    cone_angle: f(&s["cone_angle"], 60.0),
                    combo_multipliers: s["combo_multipliers"]
                        .as_array()
                        .map(|a| a.iter().map(|v| f(v, 1.0)).collect())
                        .unwrap_or_else(|| vec![1.0]),
                    combo_window: f(&s["combo_window"], 0.0),
                    requires_level: s["requires_level"].as_u64().unwrap_or(1) as u16,
                    requires_house_rank: s["requires_house_rank"].as_u64().unwrap_or(0) as u8,
                    knockback: f(&s["knockback"], 0.0),
                    interrupts: s["interrupts"].as_bool().unwrap_or(false),
                    duration_ms: ms(&s["duration_ms"]),
                    reflects: s["projectile_rule"].as_str().unwrap_or("reflect") == "reflect",
                    other_damage_multiplier: f(&s["other_damage_multiplier"], 1.0),
                    banishes: s["banishes"]
                        .as_array()
                        .map(|a| {
                            a.iter()
                                .filter_map(|v| v.as_str().map(str::to_owned))
                                .collect()
                        })
                        .unwrap_or_default(),
                    stun_ms: ms(&s["stun_ms"]),
                    stun_ms_boss: s["stun_ms_boss"]
                        .as_u64()
                        .map_or(ms(&s["stun_ms"]), |v| v as u32),
                    freeze_ms: ms(&s["freeze_ms"]),
                    freeze_ms_boss: s["freeze_ms_boss"]
                        .as_u64()
                        .map_or(ms(&s["freeze_ms"]), |v| v as u32),
                    slow: s["slow"].is_object().then(|| Slow {
                        ms: ms(&s["slow"]["ms"]),
                        boss_ms: s["slow"]["boss_ms"]
                            .as_u64()
                            .map_or(ms(&s["slow"]["ms"]), |v| v as u32),
                        factor: f(&s["slow"]["factor"], 1.0),
                    }),
                    burn: dot(&s["burn"]),
                    bleed: dot(&s["bleed"]),
                    launch: s["launch"].is_object().then(|| Launch {
                        push: f(&s["launch"]["push"], 0.0),
                        lift: f(&s["launch"]["lift"], 0.0),
                        land_stun_ms: ms(&s["launch"]["land_stun_ms"]),
                    }),
                    weaken_ms: ms(&s["weaken_ms"]),
                    weaken_factor: f(&s["weaken_factor"], 1.0),
                },
            );
        }
        let crit = &combat["critical"];
        rules.crit_base = f(&crit["base_chance"], 0.0);
        rules.crit_finisher_bonus = f(&crit["finisher_bonus"], 0.0);
        rules.crit_max = f(&crit["max_chance"], 100.0);
        rules.crit_multiplier = f(&crit["multiplier"], 1.5);
        let regen = &combat["regeneration"];
        rules.hp_regen = f(&regen["hp_per_second"], 0.0);
        rules.mana_regen = f(&regen["mana_per_second"], 0.0);
        for (house, h) in combat["houses"].as_object().into_iter().flatten() {
            let mut spell_damage = BTreeMap::new();
            for (spell, m) in h["spell_damage"].as_object().into_iter().flatten() {
                spell_damage.insert(spell.clone(), f(m, 1.0));
            }
            rules.houses.insert(
                house.clone(),
                HouseMods {
                    hp_multiplier: f(&h["hp_multiplier"], 1.0),
                    mana_multiplier: f(&h["mana_multiplier"], 1.0),
                    cooldown_multiplier: f(&h["cooldown_multiplier"], 1.0),
                    spell_damage,
                    mana_regen: regen[format!("mana_per_second_{house}")]
                        .as_f64()
                        .map(|v| v as f32),
                },
            );
        }
        let sk = &combat["skills"];
        rules.skills = SkillRules {
            max_level: sk["max_level"].as_u64().unwrap_or(10) as u8,
            master_level: sk["master_level"].as_u64().unwrap_or(10) as u8,
            upgradeable: sk["upgradeable"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|v| v.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default(),
            damage_per_level: f(&sk["damage_per_level"], 0.0),
            master_damage_bonus: f(&sk["master_damage_bonus"], 0.0),
            cooldown_per_level: f(&sk["cooldown_per_level"], 0.0),
            effect_per_level: f(&sk["effect_per_level"], 0.0),
        };
        let items = &combat["item_stats"];
        rules.armor_base = f(&items["armor_base"], 100.0);
        rules.armor_per_level = f(&items["armor_per_level"], 8.0);
        rules.armor_max_reduction = f(&items["armor_max_reduction"], 75.0);
        rules.resist_cap = f(&items["resist_cap"], 50.0);
        rules.block_cap = f(&items["block_cap"], 50.0);
        rules.dodge_cap = f(&items["dodge_cap"], 50.0);
        rules.reflect_cap = f(&items["reflect_cap"], 30.0);
        rules.life_steal_cap = f(&items["life_steal_cap"], 20.0);
        for (attack, kind) in items["mob_attack_kinds"].as_object().into_iter().flatten() {
            rules
                .mob_attack_kinds
                .insert(attack.clone(), kind.as_str().unwrap_or("spell").to_owned());
        }
        for (family, stat) in combat["enchant"]["families"]
            .as_object()
            .into_iter()
            .flatten()
        {
            rules
                .family_stats
                .insert(family.clone(), stat.as_str().unwrap_or("").to_owned());
        }
        for (id, m) in mobs["mobs"].as_object().into_iter().flatten() {
            let mut resist = BTreeMap::new();
            for (element, r) in m["resist"].as_object().into_iter().flatten() {
                resist.insert(element.clone(), f(r, 0.0));
            }
            rules.creatures.insert(
                id.clone(),
                CreatureDef {
                    family: m["family"].as_str().unwrap_or("").to_owned(),
                    resist,
                    displace_resist: f(&m["displace_resist"], 0.0),
                    mana_first: m["mana_first"].as_bool().unwrap_or(false),
                },
            );
        }
        let stats = &combat["enchant"]["stats"];
        rules.procs = ProcSpecs {
            stun_ms: ms(&stats["stun_chance"]["stun_ms"]),
            stun_grace_ms: ms(&stats["stun_chance"]["grace_ms"]),
            slow_ms: ms(&stats["slow_chance"]["slow_ms"]),
            slow_factor: f(&stats["slow_chance"]["factor"], 0.6),
            burn: dot(&stats["burn_chance"]["burn"]).unwrap_or_default(),
        };
        rules.house_rank_thresholds = combat["house_ranks"]["thresholds"]
            .as_array()
            .map(|a| a.iter().map(ms).collect())
            .unwrap_or_default();
        Ok(rules)
    }

    #[must_use]
    pub fn spell(&self, id: &str) -> Option<&SpellDef> {
        self.spells.get(id)
    }

    #[must_use]
    pub fn spell_by_index(&self, index: u8) -> Option<&SpellDef> {
        self.spell_order
            .get(usize::from(index))
            .and_then(|id| self.spells.get(id))
    }

    fn house(&self, house: &str) -> Option<&HouseMods> {
        self.houses.get(house)
    }

    // ------------------------------------------------------------- skills

    #[must_use]
    pub fn skill_upgradeable(&self, spell: &str) -> bool {
        self.skills.upgradeable.iter().any(|s| s == spell)
    }

    /// A character's level of `spell`: 0 = not learned; spells that are not
    /// skills (the basic attack, the Dawnbreak) are always 1.
    #[must_use]
    pub fn skill_level(&self, sheet: &CharacterSheet, spell: &str) -> u8 {
        if !self.skill_upgradeable(spell) {
            return 1;
        }
        sheet
            .skills
            .iter()
            .find(|(s, _)| s == spell)
            .map_or(0, |(_, l)| (*l).min(self.skills.max_level))
    }

    /// Unspent skill points: one per character level (the level-1 point is
    /// the starter skill), minus every learned level.
    #[must_use]
    pub fn skill_points(&self, sheet: &CharacterSheet) -> u32 {
        let spent: u32 = self
            .skills
            .upgradeable
            .iter()
            .map(|s| u32::from(self.skill_level(sheet, s)))
            .sum();
        u32::from(sheet.level.max(1)).saturating_sub(spent)
    }

    fn skill_damage(&self, level: u8) -> f32 {
        let lv = level.clamp(1, self.skills.max_level);
        let mut m = 1.0 + self.skills.damage_per_level * f32::from(lv - 1);
        if lv >= self.skills.master_level {
            m += self.skills.master_damage_bonus;
        }
        m
    }

    fn skill_cooldown(&self, level: u8) -> f32 {
        let lv = level.clamp(1, self.skills.max_level);
        (1.0 - self.skills.cooldown_per_level * f32::from(lv - 1)).max(0.25)
    }

    /// Duration scaling for a skill's lasting effect (ward, stun, weaken).
    #[must_use]
    pub fn skill_effect(&self, level: u8) -> f32 {
        let lv = level.clamp(1, self.skills.max_level);
        1.0 + self.skills.effect_per_level * f32::from(lv - 1)
    }

    /// House standing rank 1..n from reputation.
    #[must_use]
    pub fn house_rank(&self, rep: u32) -> u8 {
        self.house_rank_thresholds
            .iter()
            .filter(|t| rep >= **t)
            .count()
            .max(1) as u8
    }

    // -------------------------------------------------------- base numbers

    /// A new character's maximum health and mana in `house`.
    #[must_use]
    pub fn base_vitals(&self, house: &str, max_hp: u32, max_mana: u32) -> (u32, u32) {
        let h = self.house(house);
        (
            (max_hp as f32 * h.map_or(1.0, |h| h.hp_multiplier)) as u32,
            (max_mana as f32 * h.map_or(1.0, |h| h.mana_multiplier)) as u32,
        )
    }

    /// Health and mana regained per second (before item regeneration).
    #[must_use]
    pub fn regen(&self, house: &str) -> (f32, f32) {
        let mana = self
            .house(house)
            .and_then(|h| h.mana_regen)
            .unwrap_or(self.mana_regen);
        (self.hp_regen, mana)
    }

    // ------------------------------------------------------------- casting

    /// Cooldown in seconds: the spell's, scaled by the house and the skill,
    /// then attack speed (the basic attack) or cast speed (the rest).
    #[must_use]
    pub fn cooldown(
        &self,
        spell: &SpellDef,
        house: &str,
        skill: u8,
        attack_speed: f32,
        cast_speed: f32,
    ) -> f32 {
        let mut cd = spell.cooldown
            * self.house(house).map_or(1.0, |h| h.cooldown_multiplier)
            * self.skill_cooldown(skill);
        if spell.id == BASIC_SPELL {
            cd /= 1.0 + attack_speed.max(0.0) / 100.0;
        } else {
            cd *= 1.0 - cast_speed.clamp(0.0, 90.0) / 100.0;
        }
        cd
    }

    /// A cast's damage before the victim: (base + wand roll x coefficient)
    /// x the +N multiplier x combo step x house x skill x spell power.
    #[must_use]
    pub fn cast_damage(&self, spell: &SpellDef, cast: &CastPower) -> f32 {
        let base = spell.damage + cast.weapon_roll * spell.magic_attack_coef;
        let house = self
            .house(&cast.house)
            .and_then(|h| h.spell_damage.get(&spell.id))
            .copied()
            .unwrap_or(1.0);
        (base * cast.wand_multiplier * cast.combo * house * self.skill_damage(cast.skill)).trunc()
            * cast.weapon_multiplier
    }

    /// Critical chance in percent: base + enchanted crit_chance, more on a
    /// combo finisher, capped.
    #[must_use]
    pub fn crit_chance(&self, bonus: f32, finisher: bool) -> f32 {
        let extra = if finisher {
            self.crit_finisher_bonus
        } else {
            0.0
        };
        (self.crit_base + bonus + extra).clamp(0.0, self.crit_max)
    }

    /// Share of a hit armour removes against an attacker of `level`.
    #[must_use]
    pub fn armor_reduction(&self, armor: f32, attacker_level: u32) -> f32 {
        if armor <= 0.0 {
            return 0.0;
        }
        let k = self.armor_base + self.armor_per_level * attacker_level.max(1) as f32;
        (armor / (armor + k)).min(self.armor_max_reduction / 100.0)
    }

    /// Damage factor of a creature's resistance to `element` (1 - resist,
    /// 0..3).
    #[must_use]
    pub fn resist_factor(&self, creature: &str, element: &str) -> f32 {
        let resist = self
            .creatures
            .get(creature)
            .and_then(|c| c.resist.get(element))
            .copied()
            .unwrap_or(0.0);
        (1.0 - resist).clamp(0.0, 3.0)
    }

    /// How much of a crowd-control hold a creature keeps (its stun
    /// resistance: 1 = immune, negative = longer), 0..2.
    #[must_use]
    pub fn hold_scale(&self, creature: &str) -> f32 {
        let resist = self
            .creatures
            .get(creature)
            .and_then(|c| c.resist.get("stun"))
            .copied()
            .unwrap_or(0.0);
        (1.0 - resist).clamp(0.0, 2.0)
    }

    /// How far a creature can be thrown (1 - displace_resist; bosses never).
    #[must_use]
    pub fn displace_scale(&self, creature: &str, boss: bool) -> f32 {
        if boss {
            return 0.0;
        }
        let resist = self
            .creatures
            .get(creature)
            .map_or(0.0, |c| c.displace_resist);
        (1.0 - resist).clamp(0.0, 1.0)
    }

    /// "melee", "projectile" or "spell" for a creature attack id.
    #[must_use]
    pub fn attack_kind(&self, attack: &str) -> &str {
        self.mob_attack_kinds
            .get(attack)
            .map_or("spell", String::as_str)
    }

    /// Area damage share at `distance` from the burst.
    #[must_use]
    pub fn falloff(distance: f32, radius: f32, floor: f32) -> f32 {
        if radius <= 0.0 {
            1.0
        } else {
            (1.0 - distance / radius).clamp(floor, 1.0)
        }
    }
}

/// What the caster brings to one cast.
#[derive(Clone, Debug, Default)]
pub struct CastPower {
    pub house: String,
    pub skill: u8,
    /// The +N multiplier of the worn wand.
    pub wand_multiplier: f32,
    /// One roll of the wand range the spell draws on, at +0.
    pub weapon_roll: f32,
    /// The basic attack's chain step multiplier (1 otherwise).
    pub combo: f32,
    /// 1 + spell power / 100.
    pub weapon_multiplier: f32,
}
