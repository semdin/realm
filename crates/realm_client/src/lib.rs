//! Rust side of the Godot client. `RealmSession` is a node the game scene
//! adds once: it owns the connection and the client core (prediction,
//! reconciliation, interpolation), steps the rules at 30 Hz from Godot's
//! frame clock, and hands the view layer what to draw. Game state never
//! lives in GDScript; scripts read it from here and draw it.

// The GDExtension entry point is an `unsafe impl` by design of the bindings.
#![allow(unsafe_code)]

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use godot::classes::mesh::{ArrayType, PrimitiveType};
use godot::classes::{ArrayMesh, INode, Node};
use godot::prelude::*;
use realm_data::Content;
use realm_netclient::{ClientCore, NetEvent, NetHandle};
use realm_proto::SigningKey;
use realm_proto::control::{ClientMsg, ServerMsg};
use realm_proto::ticket::Ticket;
use realm_rules::{Cell, CharacterSheet, Item, ItemOp, Rules, Slot};
use realm_sim::FixedStep;
use realm_sim::input::MoveInput;
use realm_sim::pack::{HOLE, MapPack};

struct RealmExtension;

#[gdextension]
unsafe impl ExtensionLibrary for RealmExtension {}

/// Build facts the client can show or check at start-up.
#[derive(GodotClass)]
#[class(init, base = RefCounted)]
struct RealmInfo {}

#[godot_api]
impl RealmInfo {
    #[func]
    fn protocol_version() -> i64 {
        i64::from(realm_proto::PROTOCOL_VERSION)
    }

    #[func]
    fn sim_hz() -> i64 {
        i64::from(realm_sim::SIM_HZ)
    }
}

/// Content loaded once for the whole client (menus, look tables, item
/// names), read through `RealmContent`.
static CONTENT: Mutex<Option<Content>> = Mutex::new(None);
/// The typed rules built from it (item numbers for tooltips).
static RULES: Mutex<Option<Rules>> = Mutex::new(None);

/// The game's content tables for scripts: the same files, loaded and hashed
/// by the same Rust code as the server's, handed out as dictionaries.
#[derive(GodotClass)]
#[class(init, base = RefCounted)]
struct RealmContent {}

#[godot_api]
impl RealmContent {
    /// Loads `dir` (content/data). False if it cannot be read.
    #[func]
    fn load(dir: GString) -> bool {
        match Content::load(&PathBuf::from(dir.to_string())) {
            Ok(content) => {
                let rules = match Rules::from_content(&content) {
                    Ok(rules) => rules,
                    Err(e) => {
                        godot_error!("realm content rules: {e}");
                        return false;
                    }
                };
                *RULES
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(rules);
                *CONTENT
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(content);
                true
            }
            Err(e) => {
                godot_error!("realm content: {e}");
                false
            }
        }
    }

    /// The species id of a snapshot creature kind (the server's order: the
    /// mark bits are ignored); empty when unknown.
    #[func]
    fn species_of_kind(kind: i64) -> GString {
        let index = (kind as u16 & realm_proto::KIND_SPECIES) as usize;
        RULES
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .and_then(|r| {
                index
                    .checked_sub(1)
                    .and_then(|i| r.mobs.species_order.get(i))
            })
            .map_or_else(GString::new, |s| GString::from(s.as_str()))
    }

    /// One table (`looks` for looks.json) as a dictionary or array; nil when
    /// content is not loaded or the table does not exist.
    #[func]
    fn table(name: GString) -> Variant {
        CONTENT
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .and_then(|c| c.file(&format!("{name}.json")))
            .map(|v| json_to_variant(&realm_data::without_notes(v)))
            .unwrap_or_default()
    }

    /// One item's fixed stats at refine level `tier`, as the rules compute
    /// them (tooltips, the merchant): `bonus_hp`, `bonus_mana`, `armor`,
    /// `attack_value` / `magic_attack` ([min, max] scaled by the +N
    /// multiplier, or absent), the percent stats, `mount_speed`,
    /// `sell_price`, `required_level`, `refinable`, `enchantable`.
    #[func]
    fn item_stats(id: GString, tier: i64) -> VarDictionary {
        RULES
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .map_or_else(VarDictionary::new, |r| {
                item_stats_dict(r, &id.to_string(), tier)
            })
    }

    /// The content hash the server compares at login.
    #[func]
    fn hash() -> GString {
        CONTENT
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .map_or_else(GString::new, |c| GString::from(c.hash().as_str()))
    }
}

/// 0..39: a bag cell; 100 + n: equipment slot n.
fn cell(value: i64) -> Option<Cell> {
    match value {
        0..100 => u8::try_from(value).ok().map(Cell::Bag),
        _ => usize::try_from(value - 100)
            .ok()
            .and_then(|i| Slot::ALL.get(i))
            .map(|s| Cell::Worn(*s)),
    }
}

fn item_dict(item: &Item) -> VarDictionary {
    let mut out = VarDictionary::new();
    out.set("id", &GString::from(item.id.as_str()).to_variant());
    out.set("amount", &i64::from(item.amount).to_variant());
    out.set("tier", &i64::from(item.tier).to_variant());
    out.set("uid", &(item.uid as i64).to_variant());
    let mut bonuses = VarDictionary::new();
    for bonus in &item.bonuses {
        bonuses.set(bonus.stat.as_str(), &bonus.value.to_variant());
    }
    out.set("bonuses", &bonuses.to_variant());
    out
}

/// One item's fixed stats at refine level `tier` (see RealmContent.item_stats).
fn item_stats_dict(rules: &Rules, id: &str, tier: i64) -> VarDictionary {
    let mut out = VarDictionary::new();
    let tier = tier.clamp(0, 9) as u8;
    let n = rules.item_stats(id, tier);
    out.set("bonus_hp", &n.bonus_hp.to_variant());
    out.set("bonus_mana", &n.bonus_mana.to_variant());
    out.set("armor", &n.armor.to_variant());
    if let Some((a, b)) = n.attack_value {
        out.set(
            "attack_value",
            &PackedFloat32Array::from(&[a, b][..]).to_variant(),
        );
    }
    if let Some((a, b)) = n.magic_attack {
        out.set(
            "magic_attack",
            &PackedFloat32Array::from(&[a, b][..]).to_variant(),
        );
    }
    for (key, value) in &n.percent {
        out.set(key.as_str(), &value.to_variant());
    }
    if let Some(speed) = n.mount_speed {
        out.set("mount_speed", &speed.to_variant());
    }
    out.set(
        "sell_price",
        &(rules.sell_price(id, tier) as i64).to_variant(),
    );
    if let Some(def) = rules.item(id) {
        out.set(
            "required_level",
            &i64::from(def.required_level).to_variant(),
        );
    }
    out.set("refinable", &rules.refinable(id).to_variant());
    out.set("enchantable", &rules.enchantable(id).to_variant());
    out
}

/// What `sheet`'s gear adds up to (see RealmSession.derived_stats).
fn derived_dict(rules: &Rules, sheet: &CharacterSheet) -> VarDictionary {
    let mut out = VarDictionary::new();
    let d = rules.derived(sheet);
    out.set("max_hp", &i64::from(d.max_hp).to_variant());
    out.set("max_mana", &i64::from(d.max_mana).to_variant());
    out.set("armor", &d.armor.to_variant());
    out.set("wand_tier", &i64::from(d.wand_tier).to_variant());
    out.set(
        "attack_value",
        &PackedFloat32Array::from(&[d.attack_value.0, d.attack_value.1][..]).to_variant(),
    );
    out.set(
        "magic_attack",
        &PackedFloat32Array::from(&[d.magic_attack.0, d.magic_attack.1][..]).to_variant(),
    );
    out.set("mount_speed", &d.mount_speed.to_variant());
    out.set("weapon_multiplier", &d.weapon_multiplier.to_variant());
    for (key, value) in &d.stats {
        out.set(key.as_str(), &value.to_variant());
    }
    out
}

fn json_to_variant(value: &serde_json::Value) -> Variant {
    use serde_json::Value;
    match value {
        Value::Null => Variant::nil(),
        Value::Bool(b) => b.to_variant(),
        Value::Number(n) => n.as_i64().map_or_else(
            || n.as_f64().unwrap_or(0.0).to_variant(),
            |i| i.to_variant(),
        ),
        Value::String(s) => GString::from(s.as_str()).to_variant(),
        Value::Array(items) => {
            let mut out = VarArray::new();
            for item in items {
                out.push(&json_to_variant(item));
            }
            out.to_variant()
        }
        Value::Object(map) => {
            let mut out = VarDictionary::new();
            for (k, v) in map {
                out.set(k.as_str(), &json_to_variant(v));
            }
            out.to_variant()
        }
    }
}

/// One game session: connection, rules, and what to draw.
#[derive(GodotClass)]
#[class(base = Node)]
struct RealmSession {
    base: Base<Node>,
    content: Option<Content>,
    rules: Option<Rules>,
    pack: Option<MapPack>,
    net: Option<NetHandle>,
    core: Option<ClientCore>,
    clock: FixedStep,
    started: Instant,
    intent: MoveInput,
    /// The next tick's cast: spell index + 1 (0 = none), target, aim.
    action: (u8, u32, realm_sim::Vec3),
    /// Combat events and skill answers not yet taken by the view.
    combat_events: Vec<realm_proto::control::CombatEvent>,
    /// Local clock (ticks) at which each spell (by index) is ready again, and
    /// at which the current cast's lock ends: the client sends no request the
    /// server would only refuse.
    ready_at: [f64; 16],
    busy_until: f64,
    skill_results: Vec<(String, bool, String)>,
    /// Creature answers to `inspect` and map notices, waiting to be taken.
    creature_info: Vec<ServerMsg>,
    notices: Vec<ServerMsg>,
    status: String,
    /// The player's character sheet as the server last sent it.
    sheet: Option<CharacterSheet>,
    /// Item answers not yet taken by the view.
    item_results: Vec<(u32, bool, String, i64)>,
    next_op: u32,
}

#[godot_api]
impl INode for RealmSession {
    fn init(base: Base<Node>) -> Self {
        Self {
            base,
            content: None,
            rules: None,
            pack: None,
            net: None,
            core: None,
            clock: FixedStep::default(),
            started: Instant::now(),
            intent: MoveInput::default(),
            action: (0, 0, realm_sim::Vec3::ZERO),
            combat_events: Vec::new(),
            ready_at: [0.0; 16],
            busy_until: 0.0,
            skill_results: Vec::new(),
            creature_info: Vec::new(),
            notices: Vec::new(),
            status: "idle".to_owned(),
            sheet: None,
            item_results: Vec::new(),
            next_op: 1,
        }
    }

    fn process(&mut self, delta: f64) {
        self.pump();
        let steps = self.clock.advance(delta as f32);
        for _ in 0..steps {
            let (Some(core), Some(net)) = (self.core.as_mut(), self.net.as_ref()) else {
                break;
            };
            let (action, target, aim) = self.action;
            net.send(core.step(self.intent, action, target, aim));
            self.action = (0, 0, realm_sim::Vec3::ZERO);
        }
    }
}

impl RealmSession {
    /// The player's own casts start their cooldowns here, with the same
    /// rules the server used.
    fn track_cooldowns(&mut self, events: &[realm_proto::control::CombatEvent]) {
        use realm_proto::control::CombatEvent;
        let now = self.local_ticks();
        let me = self.core.as_ref().map_or(0, ClientCore::me);
        for event in events {
            let CombatEvent::CastStarted { caster, spell, .. } = event else {
                continue;
            };
            if *caster != me {
                continue;
            }
            if let Some(cd) = self.cooldown_ticks(*spell) {
                self.ready_at[usize::from(*spell)] = now + cd.0;
                self.busy_until = now + cd.1;
            }
        }
    }

    /// (cooldown, cast lock) of a spell for this character, in ticks.
    fn cooldown_ticks(&self, index: u8) -> Option<(f64, f64)> {
        let (rules, sheet) = (self.rules.as_ref()?, self.sheet.as_ref()?);
        let spell = rules.combat.spell_by_index(index)?;
        let derived = rules.derived(sheet);
        let stat = |k: &str| derived.stats.get(k).copied().unwrap_or(0.0);
        let cd = rules.combat.cooldown(
            spell,
            &sheet.house,
            rules.combat.skill_level(sheet, &spell.id),
            stat("attack_speed"),
            stat("cast_speed"),
        );
        let hz = f64::from(realm_sim::SIM_HZ);
        Some((f64::from(cd) * hz, f64::from(spell.cast_lock) * hz))
    }

    fn local_ticks(&self) -> f64 {
        self.started.elapsed().as_secs_f64() * ClientCore::HZ
    }

    /// Handles everything the network thread has delivered.
    fn pump(&mut self) {
        let Some(net) = self.net.as_ref() else { return };
        let mut events = Vec::new();
        while let Some(event) = net.poll() {
            events.push(event);
        }
        for event in events {
            match event {
                NetEvent::Joined {
                    entity,
                    tick,
                    content_hash,
                } => {
                    let (Some(content), Some(pack)) = (self.content.as_ref(), self.pack.as_ref())
                    else {
                        continue;
                    };
                    let hash: String = content_hash.iter().map(|b| format!("{b:02x}")).collect();
                    if hash != content.hash() {
                        self.status = "refused: the server runs different content".to_owned();
                        self.net = None;
                        return;
                    }
                    match (pack.world(), realm_data::staircases(content, pack)) {
                        (Ok(world), Ok(stairs)) => {
                            self.core = Some(ClientCore::new(world, stairs, entity, tick));
                            self.status = "joined".to_owned();
                        }
                        (Err(e), _) | (_, Err(e)) => self.status = format!("closed: {e}"),
                    }
                }
                NetEvent::Refused(reason) => self.status = format!("refused: {reason}"),
                NetEvent::Datagram(bytes) => {
                    let now = self.local_ticks();
                    if let Some(core) = self.core.as_mut() {
                        core.on_datagram(&bytes, now);
                    }
                }
                NetEvent::Control(ServerMsg::Sheet(sheet)) => self.sheet = Some(*sheet),
                NetEvent::Control(ServerMsg::Combat(events)) => {
                    self.track_cooldowns(&events);
                    self.combat_events.extend(events);
                }
                NetEvent::Control(ServerMsg::SkillResult { spell, ok, reason }) => {
                    self.skill_results.push((spell, ok, reason));
                }
                NetEvent::Control(info @ ServerMsg::CreatureInfo { .. }) => {
                    self.creature_info.push(info);
                }
                NetEvent::Control(notice @ ServerMsg::Notice { .. }) => {
                    self.notices.push(notice);
                }
                NetEvent::Control(ServerMsg::ItemResult {
                    op_id,
                    ok,
                    reason,
                    amount,
                }) => self.item_results.push((op_id, ok, reason, amount)),
                NetEvent::Closed(reason) => {
                    self.status = format!("closed: {reason}");
                    self.core = None;
                }
            }
        }
    }

    fn load(&mut self, content_dir: &str, maps_dir: &str, map: &str) -> Result<(), String> {
        let content = Content::load(&PathBuf::from(content_dir))?;
        let pack =
            realm_data::maps::read_pack(&PathBuf::from(maps_dir).join(format!("{map}.realmmap")))?;
        self.rules = Some(Rules::from_content(&content)?);
        self.content = Some(content);
        self.pack = Some(pack);
        Ok(())
    }
}

#[godot_api]
impl RealmSession {
    /// Development join: loads content and the map pack, mints a ticket with
    /// the dev key in `keys_dir` and connects. Returns false (and sets
    /// `status`) when something is missing. Production clients get their
    /// ticket from the login service instead.
    #[func]
    fn start_dev(
        &mut self,
        server: GString,
        keys_dir: GString,
        content_dir: GString,
        maps_dir: GString,
        map: GString,
        character: i64,
    ) -> bool {
        let result = (|| -> Result<(), String> {
            self.load(
                &content_dir.to_string(),
                &maps_dir.to_string(),
                &map.to_string(),
            )?;
            let keys = PathBuf::from(keys_dir.to_string());
            let secret: [u8; 32] = std::fs::read(keys.join("ticket.key"))
                .map_err(|e| format!("ticket.key: {e}"))?
                .try_into()
                .map_err(|_| "ticket.key must be 32 bytes")?;
            let key = SigningKey::from_bytes(&secret);
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(|e| e.to_string())?
                .as_secs();
            // 0: a fresh character for this run (two windows on one PC).
            let character = if character > 0 {
                character as u64
            } else {
                u64::from(getrandom_u32())
            };
            let ticket = Ticket::new(character, character, now + 60)
                .map_err(|e| e.to_string())?
                .sign(&key);
            let cert =
                std::fs::read(keys.join("tls.crt.der")).map_err(|e| format!("tls.crt.der: {e}"))?;
            let addr: SocketAddr = server
                .to_string()
                .parse()
                .map_err(|e| format!("server address: {e}"))?;
            self.net = Some(NetHandle::connect(addr, "localhost", cert, ticket)?);
            self.status = "connecting".to_owned();
            Ok(())
        })();
        match result {
            Ok(()) => true,
            Err(e) => {
                self.status = format!("closed: {e}");
                false
            }
        }
    }

    /// "idle", "connecting", "joined", "refused: ..." or "closed: ...".
    #[func]
    fn status(&self) -> GString {
        GString::from(self.status.as_str())
    }

    /// Steering for the next ticks: `strafe` right and `forward` in -1..1,
    /// `yaw` the camera yaw in radians (0 looks along -Z).
    #[func]
    fn set_intent(&mut self, strafe: f32, forward: f32, yaw: f32, jump: bool, descend: bool) {
        let buttons = (if jump { MoveInput::JUMP } else { 0 })
            | (if descend { MoveInput::DESCEND } else { 0 });
        self.intent = MoveInput::from_intent(strafe, forward, yaw, buttons);
    }

    /// An action for the next tick (1 = basic attack) aimed at `target`.
    #[func]
    fn set_action(&mut self, slot: i64, target: i64) {
        self.action = (
            slot.clamp(0, 15) as u8,
            target.max(0) as u32,
            realm_sim::Vec3::ZERO,
        );
    }

    /// Casts `spell` on the next tick at `target` (entity id, 0 = none) and
    /// `aim` (a world point). False for a spell the content does not have.
    /// Not sent (false) while the spell is cooling down beyond the server's
    /// 250 ms queue.
    #[func]
    fn cast(&mut self, spell: GString, target: i64, aim: Vector3) -> bool {
        let Some(index) = self
            .rules
            .as_ref()
            .and_then(|r| r.combat.spell(&spell.to_string()))
            .map(|s| s.index)
        else {
            return false;
        };
        // A held body casts nothing; the server would refuse it.
        if self.core.as_ref().is_some_and(ClientCore::locked) {
            return false;
        }
        let now = self.local_ticks();
        let ready = self.ready_at[usize::from(index)].max(self.busy_until);
        if ready - now > 0.25 * f64::from(realm_sim::SIM_HZ) {
            return false;
        }
        self.action = (
            index + 1,
            target.max(0) as u32,
            realm_sim::Vec3::new(aim.x, aim.y, aim.z),
        );
        true
    }

    /// Seconds until `spell` can be cast again (0 = ready).
    #[func]
    fn cooldown_remaining(&self, spell: GString) -> f64 {
        let Some(index) = self
            .rules
            .as_ref()
            .and_then(|r| r.combat.spell(&spell.to_string()))
            .map(|s| s.index)
        else {
            return 0.0;
        };
        let left = self.ready_at[usize::from(index)] - self.local_ticks();
        (left / f64::from(realm_sim::SIM_HZ)).max(0.0)
    }

    /// The full cooldown of `spell` for this character, seconds.
    #[func]
    fn cooldown_total(&self, spell: GString) -> f64 {
        self.rules
            .as_ref()
            .and_then(|r| r.combat.spell(&spell.to_string()))
            .and_then(|s| self.cooldown_ticks(s.index))
            .map_or(0.0, |(cd, _)| cd / f64::from(realm_sim::SIM_HZ))
    }

    /// The character's level of `spell` (0 = not learned; spells that are
    /// not skills are 1), and the unspent skill points (`skill_points`).
    #[func]
    fn skill_level(&self, spell: GString) -> i64 {
        match (self.rules.as_ref(), self.sheet.as_ref()) {
            (Some(r), Some(sheet)) => i64::from(r.combat.skill_level(sheet, &spell.to_string())),
            _ => 0,
        }
    }

    #[func]
    fn skill_points(&self) -> i64 {
        match (self.rules.as_ref(), self.sheet.as_ref()) {
            (Some(r), Some(sheet)) => i64::from(r.combat.skill_points(sheet)),
            _ => 0,
        }
    }

    /// What a ray from `origin` along `dir` meets within `reach`: `entity`
    /// (the nearest creature or other player whose body it passes through, 0
    /// = none), `point` (where it meets that body or the world).
    #[func]
    fn pick(&self, origin: Vector3, dir: Vector3, reach: f32) -> VarDictionary {
        let mut out = VarDictionary::new();
        let Some(core) = self.core.as_ref() else {
            return out;
        };
        let o = realm_sim::Vec3::new(origin.x, origin.y, origin.z);
        let d = realm_sim::Vec3::new(dir.x, dir.y, dir.z).normalize_or_zero();
        let end = o + d * reach;
        let world_t = core.world().line_hit(o, end).unwrap_or(1.0) * reach;
        let mut best: Option<(f32, u32)> = None;
        for e in core.remote_entities(self.local_ticks()) {
            if e.state == 3 {
                continue;
            }
            // A body is an upright cylinder 0.6 m round, 2.2 m tall.
            let rel = e.pos - o;
            let flat = realm_sim::Vec3::new(d.x, 0.0, d.z);
            let flat_len2 = flat.length_squared();
            let t = if flat_len2 > 1.0e-6 {
                (realm_sim::Vec3::new(rel.x, 0.0, rel.z).dot(flat) / flat_len2).max(0.0)
            } else {
                0.0
            };
            // `d` is a unit vector: t is the distance along the ray.
            let at = o + d * t;
            let close = realm_sim::Vec3::new(at.x - e.pos.x, 0.0, at.z - e.pos.z).length();
            if t <= world_t
                && close <= 0.6
                && at.y >= e.pos.y - 0.2
                && at.y <= e.pos.y + 2.4
                && best.is_none_or(|(b, _)| t < b)
            {
                best = Some((t, e.id));
            }
        }
        let (t, entity) = best.unwrap_or((world_t, 0));
        let p = o + d * t;
        out.set("entity", &i64::from(entity).to_variant());
        out.set("point", &Vector3::new(p.x, p.y, p.z).to_variant());
        out
    }

    /// Spends a skill point on `spell`; the answer comes through
    /// `take_skill_results`, the new sheet after it.
    #[func]
    fn learn_skill(&mut self, spell: GString) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::LearnSkill(spell.to_string()));
        }
    }

    /// Asks what creature `entity` is; the answer comes through
    /// `take_creature_info`.
    #[func]
    fn inspect(&mut self, entity: i64) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::Inspect(entity.max(0) as u32));
        }
    }

    /// Answers to `inspect`: `entity`, `boss_key` (boss_overrides key, else
    /// empty), `name` (a boss's, a Dark Shard's or a dummy's own name; empty:
    /// the species' name), `level`, `elite`, `boss`.
    #[func]
    fn take_creature_info(&mut self) -> VarArray {
        let mut out = VarArray::new();
        for msg in self.creature_info.drain(..) {
            if let ServerMsg::CreatureInfo {
                entity,
                boss_key,
                name,
                level,
                elite,
                boss,
            } = msg
            {
                let mut d = VarDictionary::new();
                d.set("entity", &i64::from(entity).to_variant());
                d.set("boss_key", &GString::from(boss_key.as_str()).to_variant());
                d.set("name", &GString::from(name.as_str()).to_variant());
                d.set("level", &i64::from(level).to_variant());
                d.set("elite", &elite.to_variant());
                d.set("boss", &boss.to_variant());
                out.push(&d.to_variant());
            }
        }
        out
    }

    /// What the map announced since the last call: `kind` ("boss_soon",
    /// "boss_spawned", "boss_slain", "stone_wave", "stone_shattered"),
    /// `subject` (a name), `actor` (who felled it, may be empty), `value` and
    /// `of` (seconds to go, the boss's level, the wave of how many).
    #[func]
    fn take_notices(&mut self) -> VarArray {
        let mut out = VarArray::new();
        for msg in self.notices.drain(..) {
            if let ServerMsg::Notice {
                kind,
                subject,
                actor,
                value,
                of,
            } = msg
            {
                let mut d = VarDictionary::new();
                d.set("kind", &GString::from(kind.as_str()).to_variant());
                d.set("subject", &GString::from(subject.as_str()).to_variant());
                d.set("actor", &GString::from(actor.as_str()).to_variant());
                d.set("value", &i64::from(value).to_variant());
                d.set("of", &i64::from(of).to_variant());
                out.push(&d.to_variant());
            }
        }
        out
    }

    /// Answers to skill requests: `spell`, `ok`, `reason`.
    #[func]
    fn take_skill_results(&mut self) -> VarArray {
        let mut out = VarArray::new();
        for (spell, ok, reason) in self.skill_results.drain(..) {
            let mut d = VarDictionary::new();
            d.set("spell", &GString::from(spell.as_str()).to_variant());
            d.set("ok", &ok.to_variant());
            d.set("reason", &GString::from(reason.as_str()).to_variant());
            out.push(&d.to_variant());
        }
        out
    }

    /// Combat events since the last call, each a dictionary with `kind`
    /// ("cast_started", "cast_released", "burst", "hit", "cast_refused",
    /// "telegraph", "telegraph_cancelled") and its fields; spells are named
    /// by id. A telegraph carries its creature ability whole: `ability`
    /// (key), `clip`, `fx`, `flight`, `impact_fx`, `shape` ("area" or
    /// "cone"), `radius`, `range`, `half_angle`, `center`, `yaw`,
    /// `start_tick` (the windup's first tick), `release_tick`,
    /// `recovery_tick`.
    #[func]
    fn take_combat_events(&mut self) -> VarArray {
        use realm_proto::control::CombatEvent;
        let mut out = VarArray::new();
        let name = |index: u8| -> GString {
            self.rules
                .as_ref()
                .and_then(|r| r.combat.spell_by_index(index))
                .map_or_else(GString::new, |s| GString::from(s.id.as_str()))
        };
        let v3 = |a: [f32; 3]| Vector3::new(a[0], a[1], a[2]);
        for event in self.combat_events.drain(..) {
            let mut d = VarDictionary::new();
            match event {
                CombatEvent::CastStarted {
                    caster,
                    spell,
                    target,
                    aim,
                    release_tick,
                } => {
                    d.set("kind", "cast_started");
                    d.set("caster", &i64::from(caster).to_variant());
                    d.set("spell", &name(spell).to_variant());
                    d.set("target", &i64::from(target).to_variant());
                    d.set("aim", &v3(aim).to_variant());
                    d.set("release_tick", &i64::from(release_tick).to_variant());
                }
                CombatEvent::CastReleased {
                    caster,
                    spell,
                    from,
                    dir,
                } => {
                    d.set("kind", "cast_released");
                    d.set("caster", &i64::from(caster).to_variant());
                    d.set("spell", &name(spell).to_variant());
                    d.set("from", &v3(from).to_variant());
                    d.set("dir", &v3(dir).to_variant());
                }
                CombatEvent::Burst { caster, spell, at } => {
                    d.set("kind", "burst");
                    d.set("caster", &i64::from(caster).to_variant());
                    d.set("spell", &name(spell).to_variant());
                    d.set("at", &v3(at).to_variant());
                }
                CombatEvent::Hit {
                    target,
                    attacker,
                    spell,
                    amount,
                    flags,
                    hp,
                } => {
                    d.set("kind", "hit");
                    d.set("target", &i64::from(target).to_variant());
                    d.set("attacker", &i64::from(attacker).to_variant());
                    d.set("spell", &name(spell).to_variant());
                    d.set("amount", &i64::from(amount).to_variant());
                    d.set("flags", &i64::from(flags).to_variant());
                    d.set("hp", &i64::from(hp).to_variant());
                }
                CombatEvent::CastRefused { spell, reason } => {
                    d.set("kind", "cast_refused");
                    d.set("spell", &name(spell).to_variant());
                    d.set("reason", &GString::from(reason.as_str()).to_variant());
                }
                CombatEvent::Telegraph {
                    caster,
                    ability,
                    center,
                    yaw,
                    release_tick,
                    recovery_tick,
                } => {
                    let Some(ab) = self.rules.as_ref().and_then(|r| r.mobs.ability(ability)) else {
                        continue;
                    };
                    use realm_rules::creatures::Shape;
                    d.set("kind", "telegraph");
                    d.set("caster", &i64::from(caster).to_variant());
                    d.set("ability", &GString::from(ab.key.as_str()).to_variant());
                    d.set("clip", &GString::from(ab.clip.as_str()).to_variant());
                    d.set("fx", &GString::from(ab.fx.as_str()).to_variant());
                    d.set("flight", &GString::from(ab.flight.as_str()).to_variant());
                    d.set(
                        "impact_fx",
                        &GString::from(ab.impact_fx.as_str()).to_variant(),
                    );
                    match ab.shape {
                        Shape::Area { radius, .. } => {
                            d.set("shape", "area");
                            d.set("radius", &radius.to_variant());
                        }
                        Shape::Cone { range, half_angle } => {
                            d.set("shape", "cone");
                            d.set("range", &range.to_variant());
                            d.set("half_angle", &half_angle.to_variant());
                        }
                    }
                    d.set("center", &v3(center).to_variant());
                    d.set("yaw", &yaw.to_variant());
                    let windup = (ab.windup_ms * realm_sim::SIM_HZ).div_ceil(1000);
                    d.set(
                        "start_tick",
                        &i64::from(release_tick.saturating_sub(windup)).to_variant(),
                    );
                    d.set("release_tick", &i64::from(release_tick).to_variant());
                    d.set("recovery_tick", &i64::from(recovery_tick).to_variant());
                }
                CombatEvent::TelegraphCancelled { caster } => {
                    d.set("kind", "telegraph_cancelled");
                    d.set("caster", &i64::from(caster).to_variant());
                }
            }
            out.push(&d.to_variant());
        }
        out
    }

    /// The server's tick now, as estimated from snapshot arrivals (with a
    /// fraction; -1 before the first snapshot). Telegraphs and other
    /// server-timed events are drawn against it.
    #[func]
    fn server_tick(&self) -> f64 {
        self.core
            .as_ref()
            .and_then(|c| c.server_tick_at(self.local_ticks()))
            .unwrap_or(-1.0)
    }

    /// The player's health, maximum health, mana and maximum mana as the
    /// newest snapshot says.
    #[func]
    fn vitals(&self) -> PackedInt32Array {
        let v = self.core.as_ref().map_or([0; 4], |c| c.own_vitals());
        v.iter().map(|x| *x as i32).collect()
    }

    /// The player's body, drawn between the last two ticks.
    #[func]
    fn own_position(&self) -> Vector3 {
        let alpha = self.clock.alpha();
        self.core
            .as_ref()
            .and_then(|c| c.own_draw_position(alpha))
            .map_or(Vector3::ZERO, |p| Vector3::new(p.x, p.y, p.z))
    }

    /// What the view needs to pose the player's body: `position` (drawn
    /// between ticks), `velocity`, `on_floor`, `swimming`, `mounted`,
    /// `air_seconds`, `yaw` (the steering yaw, radians), `status` (STATUS_*
    /// bits) and `held` (stunned or thrown: no steering, no casts). Empty
    /// before the first snapshot.
    #[func]
    fn own_body(&self) -> VarDictionary {
        let mut out = VarDictionary::new();
        let Some(core) = self.core.as_ref() else {
            return out;
        };
        let Some(body) = core.body() else {
            return out;
        };
        let pos = core
            .own_draw_position(self.clock.alpha())
            .unwrap_or(body.pos);
        out.set("position", &Vector3::new(pos.x, pos.y, pos.z).to_variant());
        out.set(
            "velocity",
            &Vector3::new(body.vel.x, body.vel.y, body.vel.z).to_variant(),
        );
        out.set("on_floor", &body.on_floor.to_variant());
        out.set("swimming", &body.swimming.to_variant());
        out.set("mounted", &body.mounted.to_variant());
        out.set(
            "air_seconds",
            &(f32::from(body.air_ticks) / realm_sim::SIM_HZ as f32).to_variant(),
        );
        out.set("yaw", &self.intent.yaw_radians().to_variant());
        out.set("status", &i64::from(core.own_status()).to_variant());
        out.set("held", &core.locked().to_variant());
        out
    }

    #[func]
    fn own_entity(&self) -> i64 {
        self.core.as_ref().map_or(0, |c| i64::from(c.me()))
    }

    /// Everyone else, interpolated for this frame: parallel arrays `ids`,
    /// `kinds`, `positions`, `yaws`, `states`, `hp`, `statuses` (STATUS_* bits).
    #[func]
    fn remote(&self) -> VarDictionary {
        let mut ids = PackedInt32Array::new();
        let mut kinds = PackedInt32Array::new();
        let mut positions = PackedVector3Array::new();
        let mut yaws = PackedFloat32Array::new();
        let mut states = PackedInt32Array::new();
        let mut hp = PackedInt32Array::new();
        let mut statuses = PackedInt32Array::new();
        if let Some(core) = self.core.as_ref() {
            for e in core.remote_entities(self.local_ticks()) {
                ids.push(e.id as i32);
                kinds.push(i32::from(e.kind));
                positions.push(Vector3::new(e.pos.x, e.pos.y, e.pos.z));
                yaws.push(e.yaw);
                states.push(i32::from(e.state));
                hp.push(i32::from(e.hp));
                statuses.push(i32::from(e.status));
            }
        }
        let mut out = VarDictionary::new();
        out.set("ids", &ids.to_variant());
        out.set("kinds", &kinds.to_variant());
        out.set("positions", &positions.to_variant());
        out.set("yaws", &yaws.to_variant());
        out.set("states", &states.to_variant());
        out.set("hp", &hp.to_variant());
        out.set("statuses", &statuses.to_variant());
        out
    }

    /// The player's character sheet: `id`, `name`, `house`, `level`, `exp`,
    /// `hp`, `mana`, `max_hp`, `max_mana`, `oril`, `bag` (40 cells: an item
    /// dictionary or null), `equipment` (slot name -> item dictionary) and
    /// `look`. An item is `id`, `amount`, `tier`, `uid` and `bonuses`
    /// (stat -> value). Empty before the server has sent it.
    #[func]
    fn sheet(&self) -> VarDictionary {
        let mut out = VarDictionary::new();
        let Some(sheet) = self.sheet.as_ref() else {
            return out;
        };
        out.set("id", &(sheet.id as i64).to_variant());
        out.set("revision", &(sheet.revision as i64).to_variant());
        out.set("name", &GString::from(sheet.name.as_str()).to_variant());
        out.set("house", &GString::from(sheet.house.as_str()).to_variant());
        out.set("level", &i64::from(sheet.level).to_variant());
        out.set("exp", &(sheet.exp as i64).to_variant());
        out.set("hp", &i64::from(sheet.hp).to_variant());
        out.set("mana", &i64::from(sheet.mana).to_variant());
        // The maximums count what is worn.
        let (max_hp, max_mana) =
            self.rules
                .as_ref()
                .map_or((sheet.base_max_hp, sheet.base_max_mana), |r| {
                    let d = r.derived(sheet);
                    (d.max_hp, d.max_mana)
                });
        out.set("max_hp", &i64::from(max_hp).to_variant());
        out.set("max_mana", &i64::from(max_mana).to_variant());
        out.set("oril", &(sheet.oril as i64).to_variant());
        let mut bag = VarArray::new();
        for cell in &sheet.bag {
            bag.push(
                &cell
                    .as_ref()
                    .map_or_else(Variant::nil, |i| item_dict(i).to_variant()),
            );
        }
        out.set("bag", &bag.to_variant());
        let mut equipment = VarDictionary::new();
        for slot in Slot::ALL {
            if let Some(item) = sheet.equipped(slot) {
                equipment.set(slot.name(), &item_dict(item).to_variant());
            }
        }
        out.set("equipment", &equipment.to_variant());
        let mut look = VarDictionary::new();
        for (key, value) in &sheet.look {
            look.set(key.as_str(), &value.to_variant());
        }
        out.set("look", &look.to_variant());
        out
    }

    /// Asks the server to change the player's look (looks.json keys ->
    /// value); the new sheet comes back when it is accepted.
    #[func]
    fn set_look(&mut self, look: VarDictionary) {
        let Some(net) = self.net.as_ref() else {
            return;
        };
        let mut raw = Vec::new();
        for (key, value) in look.iter_shared() {
            if let Ok(v) = value.try_to::<f64>() {
                raw.push((key.to_string(), v as f32));
            }
        }
        net.send_control(&ClientMsg::Look(raw));
    }

    /// Sends an item request against the current sheet; returns its op id
    /// (0 when there is no sheet yet). The answer comes through
    /// `take_item_results`.
    fn item_request(&mut self, op: ItemOp) -> i64 {
        let (Some(net), Some(sheet)) = (self.net.as_ref(), self.sheet.as_ref()) else {
            return 0;
        };
        let op_id = self.next_op;
        self.next_op = self.next_op.wrapping_add(1).max(1);
        net.send_control(&ClientMsg::Item {
            op_id,
            revision: sheet.revision,
            op,
        });
        i64::from(op_id)
    }

    /// Moves an item: cells are 0..39 for the bag, 100 + slot index for
    /// equipment (`slot_names` order). Equip and unequip are moves.
    #[func]
    fn move_item(&mut self, from: i64, to: i64) -> i64 {
        match (cell(from), cell(to)) {
            (Some(from), Some(to)) => self.item_request(ItemOp::Move { from, to }),
            _ => 0,
        }
    }

    #[func]
    fn use_item(&mut self, bag_cell: i64) -> i64 {
        self.item_request(ItemOp::Use {
            cell: bag_cell.clamp(0, 255) as u8,
        })
    }

    #[func]
    fn sell_item(&mut self, bag_cell: i64) -> i64 {
        self.item_request(ItemOp::Sell {
            cell: bag_cell.clamp(0, 255) as u8,
        })
    }

    #[func]
    fn destroy_item(&mut self, bag_cell: i64) -> i64 {
        self.item_request(ItemOp::Destroy {
            cell: bag_cell.clamp(0, 255) as u8,
        })
    }

    #[func]
    fn buy_item(&mut self, item: GString, amount: i64) -> i64 {
        self.item_request(ItemOp::Buy {
            item: item.to_string(),
            amount: amount.clamp(1, 20) as u16,
        })
    }

    #[func]
    fn refine_item(&mut self, target: i64) -> i64 {
        cell(target).map_or(0, |target| self.item_request(ItemOp::Refine { target }))
    }

    #[func]
    fn enchant_item(&mut self, scroll_cell: i64, target: i64) -> i64 {
        cell(target).map_or(0, |target| {
            self.item_request(ItemOp::Enchant {
                scroll: scroll_cell.clamp(0, 255) as u8,
                target,
            })
        })
    }

    /// Answers to item requests since the last call: `op_id`, `ok`,
    /// `reason`, `amount`.
    #[func]
    fn take_item_results(&mut self) -> VarArray {
        let mut out = VarArray::new();
        for (op_id, ok, reason, amount) in self.item_results.drain(..) {
            let mut answer = VarDictionary::new();
            answer.set("op_id", &i64::from(op_id).to_variant());
            answer.set("ok", &ok.to_variant());
            answer.set("reason", &GString::from(reason.as_str()).to_variant());
            answer.set("amount", &amount.to_variant());
            out.push(&answer.to_variant());
        }
        out
    }

    /// Equipment slot names in index order (cell 100 + index).
    #[func]
    fn slot_names() -> PackedStringArray {
        Slot::ALL.iter().map(|s| GString::from(s.name())).collect()
    }

    /// What the player's gear adds up to: `max_hp`, `max_mana`, `armor`,
    /// `wand_tier`, `attack_value`, `magic_attack`, `mount_speed`,
    /// `weapon_multiplier` and every enchantment stat.
    #[func]
    fn derived_stats(&self) -> VarDictionary {
        match (self.rules.as_ref(), self.sheet.as_ref()) {
            (Some(rules), Some(sheet)) => derived_dict(rules, sheet),
            _ => VarDictionary::new(),
        }
    }

    /// `derived_stats` as they would be after moving `from` to `to` (the
    /// "what changes if you wear it" line); empty if the move is not
    /// possible.
    #[func]
    fn preview_move(&self, from: i64, to: i64) -> VarDictionary {
        struct NoDice;
        impl realm_rules::Dice for NoDice {
            fn unit(&mut self) -> f32 {
                0.0
            }
        }
        let (Some(rules), Some(sheet), Some(from), Some(to)) = (
            self.rules.as_ref(),
            self.sheet.as_ref(),
            cell(from),
            cell(to),
        ) else {
            return VarDictionary::new();
        };
        let mut after = sheet.clone();
        let moved = rules.apply_item_op(
            &mut after,
            &ItemOp::Move { from, to },
            realm_rules::ItemContext::default(),
            &mut NoDice,
        );
        if moved.is_err() {
            return VarDictionary::new();
        }
        derived_dict(rules, &after)
    }

    /// Connection and prediction counters for an on-screen readout.
    #[func]
    fn stats(&self) -> VarDictionary {
        let mut out = VarDictionary::new();
        if let Some(core) = self.core.as_ref() {
            let s = core.stats;
            out.set("snapshots", &(s.snapshots as i64).to_variant());
            out.set("corrections", &(s.corrections as i64).to_variant());
            out.set("max_correction", &s.max_correction.to_variant());
            out.set("server_moves", &(s.server_moves as i64).to_variant());
            out.set("tick", &i64::from(core.tick()).to_variant());
            out.set("hp", &i64::from(core.own_hp()).to_variant());
        }
        out
    }

    /// The map's terrain as a mesh, one vertex every `stride` samples.
    #[func]
    fn terrain_mesh(&self, stride: i64) -> Option<Gd<ArrayMesh>> {
        let pack = self.pack.as_ref()?;
        let stride = stride.max(1) as usize;
        let mut vertices = PackedVector3Array::new();
        let mut indices = PackedInt32Array::new();
        for grid in &pack.terrain {
            let (rows, cols) = (grid.rows as usize, grid.cols as usize);
            let (r_n, c_n) = ((rows - 1) / stride + 1, (cols - 1) / stride + 1);
            let base = vertices.len() as i32;
            let mut holes = Vec::with_capacity(r_n * c_n);
            for r in 0..r_n {
                for c in 0..c_n {
                    let (rr, cc) = ((r * stride).min(rows - 1), (c * stride).min(cols - 1));
                    let h = grid.heights[rr * cols + cc];
                    holes.push(h == HOLE);
                    vertices.push(Vector3::new(
                        grid.min_x + cc as f32 * grid.spacing_x,
                        if h == HOLE {
                            0.0
                        } else {
                            h as f32 / realm_sim::WIRE_GRID
                        },
                        grid.min_z + rr as f32 * grid.spacing_z,
                    ));
                }
            }
            for r in 0..r_n - 1 {
                for c in 0..c_n - 1 {
                    let i = base + (r * c_n + c) as i32;
                    let (right, down) = (i + 1, i + c_n as i32);
                    // No ground where any corner is a hole (caves, pits).
                    if [i, right, down, down + 1]
                        .iter()
                        .any(|&k| holes[(k - base) as usize])
                    {
                        continue;
                    }
                    // Counter-clockwise seen from above (Godot's front face).
                    for k in [i, right, down + 1, i, down + 1, down] {
                        indices.push(k);
                    }
                }
            }
        }
        if vertices.is_empty() {
            return None;
        }
        Some(mesh(vertices, indices))
    }

    /// Every static collider as one grey mesh (programmer art until the
    /// real scene is streamed in Phase 6).
    #[func]
    fn collider_mesh(&self) -> Option<Gd<ArrayMesh>> {
        let pack = self.pack.as_ref()?;
        let mut vertices = PackedVector3Array::new();
        let mut indices = PackedInt32Array::new();
        for part in pack.collider_meshes() {
            let base = vertices.len() as i32;
            for v in &part.vertices {
                vertices.push(Vector3::new(v[0], v[1], v[2]));
            }
            for t in &part.indices {
                // parry winds outward-facing triangles counter-clockwise;
                // Godot culls by clockwise front faces, so flip the order.
                indices.push(base + t[0] as i32);
                indices.push(base + t[2] as i32);
                indices.push(base + t[1] as i32);
            }
        }
        if vertices.is_empty() {
            return None;
        }
        Some(mesh(vertices, indices))
    }
}

fn mesh(vertices: PackedVector3Array, indices: PackedInt32Array) -> Gd<ArrayMesh> {
    let mut arrays = VarArray::new();
    arrays.resize(ArrayType::MAX.ord() as usize, &Variant::nil());
    arrays.set(ArrayType::VERTEX.ord() as usize, &vertices.to_variant());
    arrays.set(ArrayType::INDEX.ord() as usize, &indices.to_variant());
    let mut mesh = ArrayMesh::new_gd();
    mesh.add_surface_from_arrays(PrimitiveType::TRIANGLES, &arrays);
    mesh
}

fn getrandom_u32() -> u32 {
    // Dev characters only need to differ between two windows on one PC.
    (SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos())
        | 1)
        ^ std::process::id()
}
