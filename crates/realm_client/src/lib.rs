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

/// The watch over stalls and the engine's shutdown, from its own thread.
mod guard;
mod guard_sys;
/// Way-finding: paths, the nearest walkable point and the painted map sheet.
mod way;

struct RealmExtension;

#[gdextension]
unsafe impl ExtensionLibrary for RealmExtension {
    fn on_stage_init(stage: InitStage) {
        if stage == InitStage::MainLoop {
            guard::main_loop_started();
        }
    }

    fn on_main_loop_frame() {
        guard::frame_finished();
    }

    fn on_stage_deinit(stage: InitStage) {
        if stage == InitStage::MainLoop {
            guard::begin_exit();
        }
    }
}

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
/// A trip to another map: (map, address, ticket), kept while the scene is
/// rebuilt for it (`RealmSession.start_travel` takes it).
static PENDING_TRAVEL: Mutex<Option<(String, String, Vec<u8>)>> = Mutex::new(None);

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
    /// The realm's weather as the map last told it.
    rain: bool,
    /// The player's lasting effects and the server tick each ends.
    effects: Vec<(String, u32)>,
    /// Rewards, chests, loot answers, deaths, attribute answers.
    game_events: Vec<ServerMsg>,
    /// Chat lines waiting to be taken.
    chat: Vec<ServerMsg>,
    /// The party as the server last said.
    party: realm_proto::coord::PartyView,
    /// The dungeon copy this connection plays in (0: none).
    copy: u8,
    status: String,
    /// The player's character sheet as the server last sent it.
    sheet: Option<CharacterSheet>,
    /// Item answers not yet taken by the view.
    item_results: Vec<(u32, bool, String, i64)>,
    next_op: u32,
    /// Way-finding's view of the loaded map (way.rs), built on first use.
    way: way::WayCache,
    /// The map's moving staircases for drawing: the same pure function of
    /// the tick the core collides with (a second copy, so drawing never
    /// touches the prediction's).
    stair_view: realm_sim::staircase::Staircases,
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
            rain: false,
            effects: Vec::new(),
            game_events: Vec::new(),
            chat: Vec::new(),
            party: realm_proto::coord::PartyView::default(),
            copy: 0,
            status: "idle".to_owned(),
            sheet: None,
            item_results: Vec::new(),
            next_op: 1,
            way: way::WayCache::default(),
            stair_view: realm_sim::staircase::Staircases::default(),
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
                    copy,
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
                    // A dungeon copy stands at its own offset, with its gates.
                    let offset = realm_rules::dungeons::copy_offset(copy);
                    let offset = realm_sim::Vec3::new(offset[0], offset[1], offset[2]);
                    let world = if copy == 0 {
                        pack.world()
                    } else {
                        pack.world_copies(&[offset])
                    };
                    let gates = pack.gates(&[offset]);
                    let stair_view = realm_data::staircases(content, pack).unwrap_or_default();
                    match (world, realm_data::staircases(content, pack), gates) {
                        (Ok(world), Ok(stairs), Ok(gates)) => {
                            self.stair_view = stair_view;
                            let mut core = ClientCore::new(world, stairs, entity, tick);
                            if copy != 0 {
                                core.set_gates(gates);
                            }
                            self.core = Some(core);
                            self.copy = copy;
                            self.status = "joined".to_owned();
                        }
                        (_, _, Err(e)) | (Err(e), _, _) | (_, Err(e), _) => {
                            self.status = format!("closed: {e}");
                        }
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
                NetEvent::Control(
                    info @ (ServerMsg::CreatureInfo { .. } | ServerMsg::PlayerInfo { .. }),
                ) => {
                    self.creature_info.push(info);
                }
                NetEvent::Control(
                    notice @ (ServerMsg::Notice { .. }
                    | ServerMsg::Maintenance { .. }
                    | ServerMsg::Sanction { .. }
                    | ServerMsg::Blocks(_)
                    | ServerMsg::SocialResult { .. }),
                ) => {
                    self.notices.push(notice);
                }
                NetEvent::Control(ServerMsg::Weather { rain }) => self.rain = rain,
                NetEvent::Control(ServerMsg::Effects(list)) => self.effects = list,
                NetEvent::Control(
                    event @ (ServerMsg::Reward { .. }
                    | ServerMsg::Chest { .. }
                    | ServerMsg::LootResult { .. }
                    | ServerMsg::Death { .. }
                    | ServerMsg::AttributeResult { .. }
                    | ServerMsg::QuestResult { .. }
                    | ServerMsg::PartyInvite { .. }
                    | ServerMsg::DuelInvite { .. }
                    | ServerMsg::Duel(_)),
                ) => self.game_events.push(event),
                NetEvent::Control(
                    event @ (ServerMsg::TravelResult { .. }
                    | ServerMsg::Departing { .. }
                    | ServerMsg::Arrived { .. }
                    | ServerMsg::Waylink(_)
                    | ServerMsg::Dungeon(_)),
                ) => self.game_events.push(event),
                NetEvent::Control(ServerMsg::Gate { id, tick, open }) => {
                    if let Some(core) = self.core.as_mut() {
                        core.schedule_gate(&id, tick, open);
                    }
                }
                NetEvent::Control(ServerMsg::Travel {
                    map,
                    address,
                    ticket,
                }) => {
                    *PENDING_TRAVEL
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner) =
                        Some((map.clone(), address, ticket));
                    self.game_events.push(ServerMsg::Travel {
                        map,
                        address: String::new(),
                        ticket: Vec::new(),
                    });
                }
                NetEvent::Control(line @ ServerMsg::Chat { .. }) => {
                    self.chat.push(line);
                    // A client that never takes its chat keeps the newest.
                    if self.chat.len() > 300 {
                        self.chat.remove(0);
                    }
                }
                NetEvent::Control(ServerMsg::Party(view)) => {
                    self.party = view;
                    self.game_events.push(ServerMsg::Party(self.party.clone()));
                }
                NetEvent::Control(ServerMsg::ItemResult {
                    op_id,
                    ok,
                    reason,
                    amount,
                }) => self.item_results.push((op_id, ok, reason, amount)),
                NetEvent::Closed(reason) => {
                    // A refused join ends its connection too, in the same
                    // pump: the refusal (why the player is not in, such as
                    // "maintenance") is what the status keeps saying.
                    if !self.status.starts_with("refused") {
                        self.status = format!("closed: {reason}");
                    }
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

    /// The map a trip is taking the player to, once its ticket came; empty
    /// when none. The scene is rebuilt for it, then `start_travel` joins.
    #[func]
    fn pending_travel_map() -> GString {
        PENDING_TRAVEL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .map_or_else(GString::new, |(map, _, _)| GString::from(map.as_str()))
    }

    /// The login service's answer to /api/play (`map`, the map server's
    /// `address`, the signed `ticket` in hex) becomes the pending join: the
    /// scene is rebuilt and `start_travel` connects with it, as after a trip.
    /// False when the ticket is not hex or the address is empty.
    #[func]
    fn join_ticket(map: GString, address: GString, ticket_hex: GString) -> bool {
        let hex = ticket_hex.to_string();
        let ticket: Option<Vec<u8>> = hex
            .len()
            .is_multiple_of(2)
            .then(|| {
                (0..hex.len())
                    .step_by(2)
                    .map(|i| u8::from_str_radix(hex.get(i..i + 2)?, 16).ok())
                    .collect()
            })
            .flatten();
        let (map, address) = (map.to_string(), address.to_string());
        match ticket {
            Some(ticket) if !ticket.is_empty() && !map.is_empty() && !address.is_empty() => {
                *PENDING_TRAVEL
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner) =
                    Some((map, address, ticket));
                true
            }
            _ => false,
        }
    }

    /// Joins the map of the pending trip with its ticket (the trusted
    /// certificate from `keys_dir`, content and the map pack loaded as for
    /// `start_dev`). False (and `status`) when there is none or it fails.
    #[func]
    fn start_travel(&mut self, keys_dir: GString, content_dir: GString, maps_dir: GString) -> bool {
        let pending = PENDING_TRAVEL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        let result = (|| -> Result<(), String> {
            let (map, address, ticket) = pending.ok_or("no trip is pending")?;
            self.load(&content_dir.to_string(), &maps_dir.to_string(), &map)?;
            let keys = PathBuf::from(keys_dir.to_string());
            let cert =
                std::fs::read(keys.join("tls.crt.der")).map_err(|e| format!("tls.crt.der: {e}"))?;
            let addr: SocketAddr = address
                .parse()
                .map_err(|e| format!("server address {address}: {e}"))?;
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

    /// The dungeon copy this connection plays in (0: none).
    #[func]
    fn copy(&self) -> i64 {
        i64::from(self.copy)
    }

    /// Where this connection's dungeon copy stands (add it to the map's own
    /// coordinates: the pack's meshes, spawn points, doors, nodes).
    #[func]
    fn copy_offset(&self) -> Vector3 {
        let o = realm_rules::dungeons::copy_offset(self.copy);
        Vector3::new(o[0], o[1], o[2])
    }

    /// The copy's gates: [{id, center, size, open}] (world space; `open` at
    /// the predicted tick, so a portcullis lifts with the prediction).
    #[func]
    fn gates(&self) -> VarArray {
        let mut out = VarArray::new();
        let (Some(core), Some(pack)) = (self.core.as_ref(), self.pack.as_ref()) else {
            return out;
        };
        let o = realm_rules::dungeons::copy_offset(self.copy);
        for d in &pack.dynamic {
            let Some(id) = d.source.strip_prefix("gate:") else {
                continue;
            };
            let mut g = VarDictionary::new();
            let t = d.collider.translation;
            g.set("id", &GString::from(id).to_variant());
            g.set(
                "center",
                &Vector3::new(t[0] + o[0], t[1] + o[1], t[2] + o[2]).to_variant(),
            );
            if let realm_sim::pack::PackShape::Box { half } = &d.collider.shape {
                g.set(
                    "size",
                    &Vector3::new(half[0] * 2.0, half[1] * 2.0, half[2] * 2.0).to_variant(),
                );
            }
            g.set("open", &core.gate_open(id, core.tick()).to_variant());
            out.push(&g.to_variant());
        }
        out
    }

    /// Asks what the dungeon behind gate `portal` asks of the party (the
    /// answer: a "dungeon" game event, `event` "info").
    #[func]
    fn dungeon_info(&mut self, portal: GString) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::DungeonInfo(portal.to_string()));
        }
    }

    /// The party leader starts the dungeon behind `portal` at `difficulty`
    /// (0 easy .. 4 legendary).
    #[func]
    fn dungeon_start(&mut self, portal: GString, difficulty: i64) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::DungeonStart {
                portal: portal.to_string(),
                difficulty: difficulty.clamp(0, 4) as u8,
            });
        }
    }

    /// Answers ready check `id`.
    #[func]
    fn dungeon_ready(&mut self, id: i64, yes: bool) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::DungeonReady { id: id as u32, yes });
        }
    }

    /// Go through the door `id` (maps.json portals) the player stands in.
    #[func]
    fn door(&mut self, id: GString) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::Door(id.to_string()));
        }
    }

    /// Travel from node `from` (where the player stands): a hearth to the
    /// hearth `to`; a cabinet or passage to its twin (`to` empty).
    #[func]
    fn travel(&mut self, from: GString, to: GString) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::Travel {
                from: from.to_string(),
                to: to.to_string(),
            });
        }
    }

    /// Mount (true) or get off (false) the broom; the answer comes as a
    /// "travel_result" game event (what "ride").
    #[func]
    fn ride(&mut self, on: bool) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::Ride(on));
        }
    }

    /// Set a Waylink boot down for destination node `dest`.
    #[func]
    fn waylink_place(&mut self, dest: GString) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::WaylinkPlace(dest.to_string()));
        }
    }

    /// Hold on to (or let go of) Waylink `id`.
    #[func]
    fn waylink_hold(&mut self, id: i64, hold: bool) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::WaylinkHold {
                id: id as u32,
                hold,
            });
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

    /// How far along the line from `from` to `to` the map's solids let it
    /// run: 1 when nothing is in the way (the camera's walls).
    #[func]
    fn line_free(&self, from: Vector3, to: Vector3) -> f32 {
        let Some(core) = self.core.as_ref() else {
            return 1.0;
        };
        let a = realm_sim::Vec3::new(from.x, from.y, from.z);
        let b = realm_sim::Vec3::new(to.x, to.y, to.z);
        core.world().line_hit(a, b).unwrap_or(1.0)
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

    /// Shows a chest's cells (within reach); they come back as a "chest"
    /// game event.
    #[func]
    fn open_chest(&mut self, chest: i64) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::OpenChest(chest.max(0) as u32));
        }
    }

    /// Takes cell `slot` of a chest, or everything that fits (`slot` -1).
    #[func]
    fn take_loot(&mut self, chest: i64, slot: i64) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::TakeLoot {
                chest: chest.max(0) as u32,
                slot: u8::try_from(slot).ok(),
            });
        }
    }

    /// Rises after death: where the body fell (`here`) or in town.
    #[func]
    fn respawn(&mut self, here: bool) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::Respawn { here });
        }
    }

    /// Tells the server the player talked to NPC `name` (npcs.json); talk
    /// quests naming it count when the player stands within reach.
    #[func]
    fn talk(&mut self, name: GString) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::Talk(name.to_string()));
        }
    }

    /// Sends a chat line or a /command as typed (`!` shouts, `/p` speaks to
    /// the party, `/invite <name>`, `/accept`, `/decline`, `/leave`,
    /// `/kick <name>`, `/promote <name>`).
    #[func]
    fn send_chat(&mut self, text: GString) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::Chat(text.to_string()));
        }
    }

    /// Reports a player: `category` is harassment, hate, spam, cheating, name
    /// or other; the answer comes as a `social` notice.
    #[func]
    fn report_player(&mut self, character: i64, name: GString, category: GString, text: GString) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::Report {
                character: u64::try_from(character).unwrap_or(0),
                name: name.to_string(),
                category: category.to_string(),
                text: text.to_string(),
            });
        }
    }

    /// Blocks a player's account, or stops blocking it.
    #[func]
    fn block_player(&mut self, name: GString, on: bool) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::Block {
                name: name.to_string(),
                on,
            });
        }
    }

    /// Chat lines since the last call: `channel` (0 local, 1 shout, 2 party,
    /// 3 system), `from` (the speaker's name; empty for a system line),
    /// `text`, `speaker` (its entity when it stands on this map, for a
    /// speech bubble; else 0). System lines are English source strings.
    #[func]
    fn take_chat(&mut self) -> VarArray {
        let mut out = VarArray::new();
        for msg in self.chat.drain(..) {
            if let ServerMsg::Chat {
                channel,
                from,
                text,
                speaker,
            } = msg
            {
                let mut d = VarDictionary::new();
                d.set("channel", &i64::from(channel).to_variant());
                d.set("from", &GString::from(from.as_str()).to_variant());
                d.set("text", &GString::from(text.as_str()).to_variant());
                d.set("speaker", &i64::from(speaker).to_variant());
                out.push(&d.to_variant());
            }
        }
        out
    }

    /// The player's party: `party` (0: none), `leader` (character id), `me`
    /// (the player's character id) and `members`, each {`character`,
    /// `name`, `house`, `level`, `hp`, `max_hp`, `mana`, `max_mana`, `map`,
    /// `dead`}.
    #[func]
    fn party(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        let v = &self.party;
        d.set("party", &(v.party as i64).to_variant());
        d.set("leader", &(v.leader as i64).to_variant());
        d.set(
            "me",
            &self.sheet.as_ref().map_or(0, |s| s.id as i64).to_variant(),
        );
        let mut members = VarArray::new();
        for m in &v.members {
            let mut e = VarDictionary::new();
            e.set("character", &(m.character as i64).to_variant());
            e.set("name", &GString::from(m.name.as_str()).to_variant());
            e.set("house", &GString::from(m.house.as_str()).to_variant());
            e.set("level", &i64::from(m.level).to_variant());
            e.set("hp", &i64::from(m.hp).to_variant());
            e.set("max_hp", &i64::from(m.max_hp).to_variant());
            e.set("mana", &i64::from(m.mana).to_variant());
            e.set("max_mana", &i64::from(m.max_mana).to_variant());
            e.set("map", &GString::from(m.map.as_str()).to_variant());
            e.set("dead", &m.dead.to_variant());
            members.push(&e.to_variant());
        }
        d.set("members", &members.to_variant());
        d
    }

    /// Claims a ready quest; the answer is a "quest_result" game event.
    #[func]
    fn claim_quest(&mut self, id: GString) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::ClaimQuest(id.to_string()));
        }
    }

    /// Spends an attribute point (vit, int, str, dex).
    #[func]
    fn spend_attribute(&mut self, stat: GString) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::SpendAttribute(stat.to_string()));
        }
    }

    /// The kill loop's messages since the last call, each with `kind`:
    /// - "reward": `exp`, `oril`, `items` ([{id, amount}]), `levels`, `rep`
    /// - "chest": `chest`, `slots` (item dictionaries, null for an empty cell)
    /// - "loot_result": `chest`, `ok`, `reason`
    /// - "death": `ready_tick`, `auto_tick` (server ticks), `killer`
    /// - "attribute_result": `stat`, `ok`, `reason`
    /// - "quest_result": `quest`, `ok`, `reason` ("claimed", "not_ready",
    ///   "bag_full")
    /// - "party_invite": `from` (answer with `/accept` or `/decline`)
    /// - "party": the party changed (read it with `party()`)
    /// - "dungeon": `event` (info, ready, cancelled, refused, launch, state,
    ///   rewards) and that message's fields (ready / state carry `view`)
    /// - "travel_result", "departing", "travel", "arrived", "waylink": trips
    /// - "duel_invite": `from`, `group`, `size` (answer `/daccept`,
    ///   `/ddecline`)
    /// - "duel": `duel` (0 when it ended), `group`, `phase` (0 countdown, 1
    ///   fight), `fight_tick`, `end_tick` (server ticks), `center`, `radius`,
    ///   `allies` / `foes` ([{entity, name}]), `out` (entities), and when it
    ///   ended `result` (won, lost, draw), `reason`, `last`, `by`; a declined
    ///   challenge carries `declined_by`
    #[func]
    fn take_game_events(&mut self) -> VarArray {
        let mut out = VarArray::new();
        for msg in self.game_events.drain(..) {
            let mut d = VarDictionary::new();
            match msg {
                ServerMsg::Reward {
                    exp,
                    oril,
                    items,
                    levels,
                    rep,
                } => {
                    d.set("rep", &i64::from(rep).to_variant());
                    d.set("kind", "reward");
                    d.set("exp", &(exp as i64).to_variant());
                    d.set("oril", &(oril as i64).to_variant());
                    let mut list = VarArray::new();
                    for (id, amount) in items {
                        let mut i = VarDictionary::new();
                        i.set("id", &GString::from(id.as_str()).to_variant());
                        i.set("amount", &i64::from(amount).to_variant());
                        list.push(&i.to_variant());
                    }
                    d.set("items", &list.to_variant());
                    d.set("levels", &i64::from(levels).to_variant());
                }
                ServerMsg::Chest { chest, slots } => {
                    d.set("kind", "chest");
                    d.set("chest", &i64::from(chest).to_variant());
                    let mut list = VarArray::new();
                    for cell in &slots {
                        list.push(
                            &cell
                                .as_ref()
                                .map_or_else(Variant::nil, |i| item_dict(i).to_variant()),
                        );
                    }
                    d.set("slots", &list.to_variant());
                }
                ServerMsg::LootResult { chest, ok, reason } => {
                    d.set("kind", "loot_result");
                    d.set("chest", &i64::from(chest).to_variant());
                    d.set("ok", &ok.to_variant());
                    d.set("reason", &GString::from(reason.as_str()).to_variant());
                }
                ServerMsg::Death {
                    ready_tick,
                    auto_tick,
                    killer,
                } => {
                    d.set("kind", "death");
                    d.set("ready_tick", &i64::from(ready_tick).to_variant());
                    d.set("auto_tick", &i64::from(auto_tick).to_variant());
                    d.set("killer", &i64::from(killer).to_variant());
                }
                ServerMsg::PartyInvite { from } => {
                    d.set("kind", "party_invite");
                    d.set("from", &GString::from(from.as_str()).to_variant());
                }
                ServerMsg::Party(_) => {
                    d.set("kind", "party");
                }
                ServerMsg::DuelInvite { from, group, size } => {
                    d.set("kind", "duel_invite");
                    d.set("from", &GString::from(from.as_str()).to_variant());
                    d.set("group", &group.to_variant());
                    d.set("size", &i64::from(size).to_variant());
                }
                ServerMsg::TravelResult { what, ok, reason } => {
                    d.set("kind", "travel_result");
                    d.set("what", &GString::from(what.as_str()).to_variant());
                    d.set("ok", &ok.to_variant());
                    d.set("reason", &GString::from(reason.as_str()).to_variant());
                }
                ServerMsg::Departing { map, label, kind } => {
                    d.set("kind", "departing");
                    d.set("map", &GString::from(map.as_str()).to_variant());
                    d.set("label", &GString::from(label.as_str()).to_variant());
                    d.set("trip", &GString::from(kind.as_str()).to_variant());
                }
                ServerMsg::Travel { map, .. } => {
                    d.set("kind", "travel");
                    d.set("map", &GString::from(map.as_str()).to_variant());
                }
                ServerMsg::Arrived { kind } => {
                    d.set("kind", "arrived");
                    d.set("trip", &GString::from(kind.as_str()).to_variant());
                }
                ServerMsg::Dungeon(m) => {
                    // `event`: info, ready, cancelled, refused, launch, state,
                    // hazard, rewards; the message's fields alongside (tuples
                    // come as arrays), and the whole of a struct's as `view`
                    // too (a hazard's own `kind` stays there: the event's
                    // `kind` is "dungeon").
                    d.set("kind", "dungeon");
                    if let Ok(serde_json::Value::Object(o)) = serde_json::to_value(&m) {
                        for (name, inner) in o {
                            d.set(
                                "event",
                                &GString::from(name.to_lowercase().as_str()).to_variant(),
                            );
                            match inner {
                                serde_json::Value::Object(fields) => {
                                    d.set(
                                        "view",
                                        &json_to_variant(&serde_json::Value::Object(
                                            fields.clone(),
                                        )),
                                    );
                                    for (k, v) in fields {
                                        if k != "kind" {
                                            d.set(k.as_str(), &json_to_variant(&v));
                                        }
                                    }
                                }
                                other => d.set("view", &json_to_variant(&other)),
                            }
                        }
                    }
                }
                ServerMsg::Waylink(w) => {
                    d.set("kind", "waylink");
                    d.set("id", &i64::from(w.id).to_variant());
                    d.set("phase", &i64::from(w.phase).to_variant());
                    d.set(
                        "pos",
                        &Vector3::new(w.pos[0], w.pos[1], w.pos[2]).to_variant(),
                    );
                    d.set("dest", &GString::from(w.dest.as_str()).to_variant());
                    d.set("label", &GString::from(w.label.as_str()).to_variant());
                    d.set("owner", &i64::from(w.owner).to_variant());
                    d.set(
                        "owner_name",
                        &GString::from(w.owner_name.as_str()).to_variant(),
                    );
                    d.set("fires_tick", &i64::from(w.fires_tick).to_variant());
                    let holders: PackedInt32Array = w.holders.iter().map(|e| *e as i32).collect();
                    d.set("holders", &holders.to_variant());
                    d.set("radius", &w.radius.to_variant());
                }
                ServerMsg::Duel(v) => {
                    d.set("kind", "duel");
                    d.set("duel", &i64::from(v.duel).to_variant());
                    d.set("group", &v.group.to_variant());
                    d.set("phase", &i64::from(v.phase).to_variant());
                    d.set("fight_tick", &i64::from(v.fight_tick).to_variant());
                    d.set("end_tick", &i64::from(v.end_tick).to_variant());
                    d.set(
                        "center",
                        &Vector3::new(v.center[0], v.center[1], v.center[2]).to_variant(),
                    );
                    d.set("radius", &v.radius.to_variant());
                    let side = |list: &Vec<(u32, String)>| {
                        let mut a = VarArray::new();
                        for (id, name) in list {
                            let mut e = VarDictionary::new();
                            e.set("entity", &i64::from(*id).to_variant());
                            e.set("name", &GString::from(name.as_str()).to_variant());
                            a.push(&e.to_variant());
                        }
                        a
                    };
                    d.set("allies", &side(&v.allies).to_variant());
                    d.set("foes", &side(&v.foes).to_variant());
                    let out: PackedInt32Array = v.out.iter().map(|e| *e as i32).collect();
                    d.set("out", &out.to_variant());
                    for (key, value) in [
                        ("result", &v.result),
                        ("reason", &v.reason),
                        ("last", &v.last),
                        ("by", &v.by),
                        ("declined_by", &v.declined_by),
                    ] {
                        d.set(key, &GString::from(value.as_str()).to_variant());
                    }
                }
                ServerMsg::QuestResult { quest, ok, reason } => {
                    d.set("kind", "quest_result");
                    d.set("quest", &GString::from(quest.as_str()).to_variant());
                    d.set("ok", &ok.to_variant());
                    d.set("reason", &GString::from(reason.as_str()).to_variant());
                }
                ServerMsg::AttributeResult { stat, ok, reason } => {
                    d.set("kind", "attribute_result");
                    d.set("stat", &GString::from(stat.as_str()).to_variant());
                    d.set("ok", &ok.to_variant());
                    d.set("reason", &GString::from(reason.as_str()).to_variant());
                }
                _ => continue,
            }
            out.push(&d.to_variant());
        }
        out
    }

    /// Asks what creature `entity` is; the answer comes through
    /// `take_creature_info`.
    #[func]
    fn inspect(&mut self, entity: i64) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::Inspect(entity.max(0) as u32));
        }
    }

    /// Whether it rains in the realm (the view shows it outdoors).
    #[func]
    fn raining(&self) -> bool {
        self.rain
    }

    /// What lasts on the player now: [{`kind` (stun, knock, web, despair,
    /// venom, freeze, burn, bleed, weak, root, ward), `seconds`
    /// left}], the ended ones left out.
    #[func]
    fn effects(&self) -> VarArray {
        let mut out = VarArray::new();
        let now = self.core.as_ref().map_or(0, ClientCore::tick);
        for (kind, until) in &self.effects {
            if *until <= now {
                continue;
            }
            let mut d = VarDictionary::new();
            d.set("kind", &GString::from(kind.as_str()).to_variant());
            d.set(
                "seconds",
                &(f64::from(until - now) / ClientCore::HZ).to_variant(),
            );
            out.push(&d.to_variant());
        }
        out
    }

    /// Answers to `inspect` (and a player's info again when its GA emblem
    /// came or went). A player: `entity`, `player` (true), `character`,
    /// `name`, `house`, `level`, `ga`, `look` ([[key, value]...]), `gear`
    /// ([{`slot`, `id`, `tier`}]), `rank` (house rank) and `titles`; sent
    /// again unasked when any of it changes. A creature: `entity`, `boss_key` (boss_overrides key, else
    /// empty), `name` (a boss's, a Dark Shard's or a dummy's own name; empty:
    /// the species' name), `level`, `elite`, `boss`, `parts` ([{`entity`,
    /// `name`: bone key L / M / R / T}] on a multi-part boss) and `part_of`
    /// (a part's boss entity, 0: none).
    #[func]
    fn take_creature_info(&mut self) -> VarArray {
        let mut out = VarArray::new();
        for msg in self.creature_info.drain(..) {
            if let ServerMsg::PlayerInfo {
                entity,
                character,
                name,
                house,
                level,
                ga,
                look,
                gear,
                rank,
                titles,
            } = &msg
            {
                let mut d = VarDictionary::new();
                d.set("entity", &i64::from(*entity).to_variant());
                d.set("player", &true.to_variant());
                d.set("ga", &ga.to_variant());
                let mut l = VarArray::new();
                for (k, v) in look {
                    let mut pair = VarArray::new();
                    pair.push(&GString::from(k.as_str()).to_variant());
                    pair.push(&f64::from(*v).to_variant());
                    l.push(&pair.to_variant());
                }
                d.set("look", &l.to_variant());
                let mut g = VarArray::new();
                for (slot, id, tier) in gear {
                    let mut item = VarDictionary::new();
                    item.set("slot", &i64::from(*slot).to_variant());
                    item.set("id", &GString::from(id.as_str()).to_variant());
                    item.set("tier", &i64::from(*tier).to_variant());
                    g.push(&item.to_variant());
                }
                d.set("gear", &g.to_variant());
                d.set("rank", &i64::from(*rank).to_variant());
                let mut t = VarArray::new();
                for title in titles {
                    t.push(&GString::from(title.as_str()).to_variant());
                }
                d.set("titles", &t.to_variant());
                d.set("character", &(*character as i64).to_variant());
                d.set("name", &GString::from(name.as_str()).to_variant());
                d.set("house", &GString::from(house.as_str()).to_variant());
                d.set("level", &i64::from(*level).to_variant());
                out.push(&d.to_variant());
                continue;
            }
            if let ServerMsg::CreatureInfo {
                entity,
                boss_key,
                name,
                level,
                elite,
                boss,
                parts,
                part_of,
                max_hp,
            } = msg
            {
                let mut d = VarDictionary::new();
                d.set("entity", &i64::from(entity).to_variant());
                d.set("boss_key", &GString::from(boss_key.as_str()).to_variant());
                d.set("name", &GString::from(name.as_str()).to_variant());
                d.set("level", &i64::from(level).to_variant());
                d.set("elite", &elite.to_variant());
                d.set("boss", &boss.to_variant());
                let mut list = VarArray::new();
                for (part, bone) in &parts {
                    let mut p = VarDictionary::new();
                    p.set("entity", &i64::from(*part).to_variant());
                    p.set("name", &GString::from(bone.as_str()).to_variant());
                    list.push(&p.to_variant());
                }
                d.set("parts", &list.to_variant());
                d.set("part_of", &i64::from(part_of).to_variant());
                d.set("max_hp", &i64::from(max_hp).to_variant());
                out.push(&d.to_variant());
            }
        }
        out
    }

    /// What the map announced since the last call: `kind` ("boss_soon",
    /// "boss_spawned", "boss_slain", "stone_wave", "stone_shattered"),
    /// `subject` (a name), `actor` (who felled it, may be empty), `value` and
    /// `of` (seconds to go, the boss's level, the wave of how many);
    /// `update_soon` (`value` minutes to a restart). The realm's
    /// maintenance comes as `kind` "maintenance" with `state` (ONLINE: a
    /// countdown called off, ANNOUNCING, DRAINING, SAVING, DISCONNECTING,
    /// MAINTENANCE, FAILED), `reason` and `seconds` left.
    #[func]
    fn take_notices(&mut self) -> VarArray {
        let mut out = VarArray::new();
        for msg in self.notices.drain(..) {
            if let ServerMsg::Maintenance {
                state,
                reason,
                seconds,
            } = &msg
            {
                let mut d = VarDictionary::new();
                d.set("kind", &GString::from("maintenance").to_variant());
                d.set("state", &GString::from(state.as_str()).to_variant());
                d.set("reason", &GString::from(reason.as_str()).to_variant());
                d.set("seconds", &i64::from(*seconds).to_variant());
                out.push(&d.to_variant());
                continue;
            }
            // What moderation says to this player: `sanction` {state: kick, ban,
            // mute, unmute; reason; until}, `social` {what, ok, reason, name}
            // and `blocks` {names}.
            if let ServerMsg::Sanction {
                kind,
                reason,
                until,
            } = &msg
            {
                let mut d = VarDictionary::new();
                d.set("kind", &GString::from("sanction").to_variant());
                d.set("state", &GString::from(kind.as_str()).to_variant());
                d.set("reason", &GString::from(reason.as_str()).to_variant());
                d.set("until", &i64::try_from(*until).unwrap_or(0).to_variant());
                out.push(&d.to_variant());
                continue;
            }
            if let ServerMsg::SocialResult {
                what,
                ok,
                reason,
                name,
            } = &msg
            {
                let mut d = VarDictionary::new();
                d.set("kind", &GString::from("social").to_variant());
                d.set("what", &GString::from(what.as_str()).to_variant());
                d.set("ok", &ok.to_variant());
                d.set("reason", &GString::from(reason.as_str()).to_variant());
                d.set("name", &GString::from(name.as_str()).to_variant());
                out.push(&d.to_variant());
                continue;
            }
            if let ServerMsg::Blocks(names) = &msg {
                let mut list = VarArray::new();
                for n in names {
                    list.push(&GString::from(n.as_str()).to_variant());
                }
                let mut d = VarDictionary::new();
                d.set("kind", &GString::from("blocks").to_variant());
                d.set("names", &list.to_variant());
                out.push(&d.to_variant());
                continue;
            }
            if let ServerMsg::Notice {
                kind,
                subject,
                actor,
                value,
                of,
                place,
            } = msg
            {
                let mut d = VarDictionary::new();
                // `place`: the map of a realm-wide notice (empty: this map's
                // own or update_soon) - the client writes those as [World].
                d.set("place", &GString::from(place.as_str()).to_variant());
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

    /// The sheet's revision (bumped by every change the server makes), or -1
    /// before the server has sent it: what a reader polls each frame instead
    /// of building the whole `sheet()` dictionary.
    #[func]
    fn sheet_revision(&self) -> i64 {
        self.sheet
            .as_ref()
            .map_or(-1, |sheet| sheet.revision as i64)
    }

    /// The player's character sheet: `id`, `name`, `house`, `level`, `exp`,
    /// `hp`, `mana`, `max_hp`, `max_mana`, `oril`, `bag` (40 cells: an item
    /// dictionary or null), `equipment` (slot name -> item dictionary),
    /// `look`, `exp_next` (experience the level takes), `attributes` (stat
    /// -> points spent), `attribute_points` and `skill_points` (unspent),
    /// `house_rep`, `house_rank`, `house_title`, `rank_from` / `rank_to` (the
    /// rank's reputation span; `rank_to` -1 at the top) and `quests`: the log
    /// in chain order, ready first, each {`id`, `state` ("ready" or "open"),
    /// `progress`, `count`} (the quest's text is in quests.json).
    /// An item is `id`, `amount`, `tier`, `uid` and `bonuses` (stat ->
    /// value). Empty before the server has sent it.
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
        if let Some(r) = self.rules.as_ref() {
            out.set(
                "exp_next",
                &(r.progress.exp_threshold(sheet.level) as i64).to_variant(),
            );
            out.set(
                "attribute_points",
                &i64::from(r.progress.attribute_points(sheet)).to_variant(),
            );
            out.set(
                "skill_points",
                &i64::from(r.combat.skill_points(sheet)).to_variant(),
            );
        }
        let mut attributes = VarDictionary::new();
        for (stat, points) in &sheet.attributes {
            attributes.set(stat.as_str(), &i64::from(*points).to_variant());
        }
        out.set("attributes", &attributes.to_variant());
        if let Some(r) = self.rules.as_ref() {
            let q = &r.quests;
            let rank = q.rank(sheet.house_rep);
            out.set("house_rep", &i64::from(sheet.house_rep).to_variant());
            out.set("house_rank", &i64::from(rank).to_variant());
            out.set(
                "house_title",
                &GString::from(
                    q.rank_titles
                        .get(usize::from(rank).saturating_sub(1))
                        .map_or("", String::as_str),
                )
                .to_variant(),
            );
            let from = q
                .rank_thresholds
                .get(usize::from(rank).saturating_sub(1))
                .copied()
                .unwrap_or(0);
            let to = q
                .rank_thresholds
                .get(usize::from(rank))
                .map_or(-1, |t| i64::from(*t));
            out.set("rank_from", &i64::from(from).to_variant());
            out.set("rank_to", &to.to_variant());
            let mut log = VarArray::new();
            let mut entry = |id: &str, state: &str, progress: u32, count: u32| {
                let mut d = VarDictionary::new();
                d.set("id", &GString::from(id).to_variant());
                d.set("state", &GString::from(state).to_variant());
                d.set("progress", &i64::from(progress).to_variant());
                d.set("count", &i64::from(count).to_variant());
                log.push(&d.to_variant());
            };
            for quest in &q.chain {
                if sheet.quests.ready.contains(&quest.id) {
                    entry(&quest.id, "ready", quest.count, quest.count);
                }
            }
            for quest in &q.chain {
                if q.is_open(sheet, quest) {
                    let n = sheet
                        .quests
                        .progress
                        .iter()
                        .find(|(id, _)| *id == quest.id)
                        .map_or(0, |(_, n)| *n);
                    entry(&quest.id, "open", n, quest.count);
                }
            }
            out.set("quests", &log.to_variant());
            let done: VarArray = sheet
                .quests
                .done
                .iter()
                .map(|id| GString::from(id.as_str()).to_variant())
                .collect();
            out.set("quests_done", &done.to_variant());
        }
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

    /// Buys row `index` of the seal shop (dungeons.json rewards.shop) with
    /// Dungeon Seals; the player must stand near a dungeon gate.
    #[func]
    fn seal_buy(&mut self, index: i64) -> i64 {
        self.item_request(ItemOp::SealBuy {
            index: index.clamp(0, 255) as u8,
        })
    }

    /// Asks for the dungeon guide (a "dungeon" game event, `event` guide).
    #[func]
    fn dungeon_guide(&mut self) {
        if let Some(net) = self.net.as_ref() {
            net.send_control(&ClientMsg::DungeonGuide);
        }
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
        // The connection's round trip (ms; 0 until known): the ping readout.
        if let Some(net) = self.net.as_ref() {
            out.set("rtt_ms", &i64::from(net.rtt_ms()).to_variant());
        }
        out
    }

    /// Where the player's body could land its broom: `ok` (the server's own
    /// dismount rule: level ground within 3.1 m under the feet, so a
    /// dismount now would not be refused "no_landing") and `height` (metres
    /// down to the ground under the feet, -1 when none within 500 m). Empty
    /// before the first snapshot.
    #[func]
    fn landing(&self) -> VarDictionary {
        let mut out = VarDictionary::new();
        let Some(core) = self.core.as_ref() else {
            return out;
        };
        let Some(body) = core.body() else {
            return out;
        };
        let from = body.pos + realm_sim::Vec3::new(0.0, 0.1, 0.0);
        let world = core.world();
        let ok = world.ray_down(from, 3.1).is_some_and(|h| h.normal.y > 0.7);
        let height = world
            .ray_down(from, 500.0)
            .map_or(-1.0, |h| (body.pos.y - h.point.y).max(0.0));
        out.set("ok", &ok.to_variant());
        out.set("height", &height.to_variant());
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

    /// The moving staircases' solid boxes as they stand now, drawn where the
    /// player's own body is (the core's predicted tick less the part of a
    /// tick not yet run): [{`kind` ("deck", "rail", "gate"), `flight` (its
    /// index), `transform` (centre and rotation), `size` (full extents)};
    /// the deck also carries `phase` ("docked", "warning", "moving",
    /// "docking")].
    /// The deck carries the body; the gates are the shut ones only.
    #[func]
    fn stair_parts(&self) -> VarArray {
        let mut out = VarArray::new();
        let Some(core) = self.core.as_ref() else {
            return out;
        };
        let tick = f64::from(core.tick()) - 1.0 + f64::from(self.clock.alpha());
        let mut boxes = Vec::new();
        for (flight, stair) in self.stair_view.flights.iter().enumerate() {
            boxes.clear();
            stair.solid_at(tick, &mut boxes);
            let phase = match stair.state_at(tick).phase {
                realm_sim::staircase::Phase::Docked => "docked",
                realm_sim::staircase::Phase::Warning => "warning",
                realm_sim::staircase::Phase::Moving => "moving",
                realm_sim::staircase::Phase::Docking => "docking",
            };
            for (i, (pose, shape)) in boxes.iter().enumerate() {
                let Some(cuboid) = shape.as_cuboid() else {
                    continue;
                };
                let (t, r, h) = (pose.translation, pose.rotation, cuboid.half_extents);
                let basis = Basis::from_quaternion(Quaternion::new(r.x, r.y, r.z, r.w));
                let mut d = VarDictionary::new();
                let kind = match i {
                    0 => "deck",
                    1 | 2 => "rail",
                    _ => "gate",
                };
                d.set("kind", &GString::from(kind).to_variant());
                d.set("flight", &(flight as i64).to_variant());
                if i == 0 {
                    d.set("phase", &GString::from(phase).to_variant());
                }
                d.set(
                    "transform",
                    &Transform3D::new(basis, Vector3::new(t.x, t.y, t.z)).to_variant(),
                );
                d.set(
                    "size",
                    &Vector3::new(h.x * 2.0, h.y * 2.0, h.z * 2.0).to_variant(),
                );
                out.push(&d.to_variant());
            }
        }
        out
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
    // Normals from the triangles (area-weighted per vertex, the winding
    // Godot draws as front): without them every face was lit with an
    // undefined normal and some (a dome, a sliver) came out black. A
    // vertex only on slivers points up.
    let v = vertices.as_slice();
    let mut sums = vec![Vector3::ZERO; v.len()];
    for t in indices.as_slice().as_chunks::<3>().0 {
        let (a, b, c) = (t[0] as usize, t[1] as usize, t[2] as usize);
        if a >= v.len() || b >= v.len() || c >= v.len() {
            continue;
        }
        let n = (v[c] - v[a]).cross(v[b] - v[a]);
        for i in [a, b, c] {
            sums[i] += n;
        }
    }
    let mut normals = PackedVector3Array::new();
    for n in sums {
        let len = n.length();
        normals.push(if len > 1e-9 && len.is_finite() {
            n / len
        } else {
            Vector3::UP
        });
    }
    let mut arrays = VarArray::new();
    arrays.resize(ArrayType::MAX.ord() as usize, &Variant::nil());
    arrays.set(ArrayType::VERTEX.ord() as usize, &vertices.to_variant());
    arrays.set(ArrayType::NORMAL.ord() as usize, &normals.to_variant());
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
