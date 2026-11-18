//! `realm_netcheck --travel --characters <dir> [--server 127.0.0.1:7777]`:
//! travel between two map servers (grounds, castle_interior) linked by the
//! coordinator, sharing the character store `<dir>`.
//!
//! A new character joins the grounds and leaves; its record then gets a
//! broom, Waycoal and a Waystake boot (as play would give them). Then it
//! must:
//! 1. walk into the castle door and arrive in the castle, through a ticket
//!    the coordinator signed, with the same bag, oril, level and health;
//! 2. walk out of the castle back onto the grounds;
//! 3. be refused a hearth trip above its level, then hearth from the
//!    Pavilion to Orvell Square on the same map (one dust spent);
//! 4. mount the broom, climb, be refused a landing in the air, descend and
//!    get off;
//! 5. set a Waystake boot down and be carried by it when it fires;
//! 6. hearth from the Pavilion to the Long Table in the castle;
//! 7. log in again on the grounds while it plays in the castle: the castle
//!    must let it go (its connection ends) and the grounds login must get
//!    the newest sheet.
//!
//! Through all of it the client's prediction must never be corrected.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use realm_data::Content;
use realm_netclient::{ClientCore, NetEvent, NetHandle};
use realm_proto::SigningKey;
use realm_proto::control::{ClientMsg, ServerMsg};
use realm_proto::ticket::Ticket;
use realm_rules::{CharacterSheet, Rules, Slot};
use realm_sim::Vec3;
use realm_sim::input::MoveInput;

use crate::{AnyResult, arg};

pub(crate) struct Session {
    pub(crate) net: NetHandle,
    pub(crate) core: Option<ClientCore>,
    pub(crate) map: String,
    pub(crate) content: Content,
    pub(crate) pack: realm_sim::pack::MapPack,
    pub(crate) sheet: Option<CharacterSheet>,
    pub(crate) events: Vec<ServerMsg>,
    pub(crate) closed: Option<String>,
    pub(crate) started: Instant,
    pub(crate) corrections: u64,
    pub(crate) copy: u8,
    /// Casts fired at (target, local tick).
    pub(crate) action: (u8, u32, Vec3),
}

impl Session {
    pub(crate) fn open(
        address: &str,
        map: &str,
        ticket: Vec<u8>,
        args: &[String],
    ) -> AnyResult<Self> {
        let keys = PathBuf::from(arg(args, "--keys", "keys"));
        let content = Content::load(&PathBuf::from(arg(args, "--content", "content/data")))?;
        let pack = realm_data::maps::read_pack(
            &PathBuf::from(arg(args, "--maps", "world/maps")).join(format!("{map}.realmmap")),
        )?;
        let net = NetHandle::connect(
            address.parse()?,
            "localhost",
            std::fs::read(keys.join("tls.crt.der"))?,
            ticket,
        )?;
        Ok(Self {
            net,
            core: None,
            map: map.to_owned(),
            content,
            pack,
            sheet: None,
            events: Vec::new(),
            closed: None,
            started: Instant::now(),
            corrections: 0,
            copy: 0,
            action: (0, 0, Vec3::ZERO),
        })
    }

    pub(crate) fn dev(
        address: &str,
        map: &str,
        character: u64,
        key: &SigningKey,
        args: &[String],
    ) -> AnyResult<Self> {
        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        let ticket = Ticket::new(character, character, now + 60)?.sign(key);
        Self::open(address, map, ticket, args)
    }

    /// Takes what arrived and runs one input tick with `input`.
    pub(crate) fn pump(&mut self, input: MoveInput) -> AnyResult<()> {
        let ticks = self.started.elapsed().as_secs_f64() * ClientCore::HZ;
        while let Some(event) = self.net.poll() {
            match event {
                NetEvent::Joined {
                    entity, tick, copy, ..
                } => {
                    let o = realm_rules::dungeons::copy_offset(copy);
                    let offset = Vec3::new(o[0], o[1], o[2]);
                    let world = if copy == 0 {
                        self.pack.world()?
                    } else {
                        self.pack.world_copies(&[offset])?
                    };
                    let stairs = realm_data::staircases(&self.content, &self.pack)?;
                    let mut core = ClientCore::new(world, stairs, entity, tick);
                    if copy != 0 {
                        core.set_gates(self.pack.gates(&[offset])?);
                    }
                    self.core = Some(core);
                    self.copy = copy;
                }
                NetEvent::Control(ServerMsg::Gate { id, tick, open }) => {
                    if let Some(core) = self.core.as_mut() {
                        core.schedule_gate(&id, tick, open);
                    }
                }
                NetEvent::Refused(r) => return Err(format!("{} refused: {r}", self.map).into()),
                NetEvent::Closed(r) => self.closed = Some(r),
                NetEvent::Datagram(bytes) => {
                    if let Some(core) = self.core.as_mut() {
                        core.on_datagram(&bytes, ticks);
                    }
                }
                NetEvent::Control(ServerMsg::Sheet(sheet)) => self.sheet = Some(*sheet),
                NetEvent::Control(
                    m @ (ServerMsg::TravelResult { .. }
                    | ServerMsg::Departing { .. }
                    | ServerMsg::Travel { .. }
                    | ServerMsg::Arrived { .. }
                    | ServerMsg::Waystake(_)
                    | ServerMsg::Dungeon(_)
                    | ServerMsg::Chest { .. }
                    | ServerMsg::LootResult { .. }
                    | ServerMsg::ItemResult { .. }
                    | ServerMsg::Maintenance { .. }
                    | ServerMsg::Notice { .. }
                    | ServerMsg::Weather { .. }
                    | ServerMsg::Effects(_)
                    | ServerMsg::PlayerInfo { .. }
                    | ServerMsg::Chat { .. }),
                ) => {
                    println!("[travel] {} hears {m:?}", self.map);
                    self.events.push(m);
                }
                NetEvent::Control(_) => {}
            }
        }
        if let Some(core) = self.core.as_mut() {
            let (action, target, aim) = std::mem::take(&mut self.action);
            let bytes = core.step(input, action, target, aim);
            self.net.send(bytes);
            self.corrections = core.stats.corrections;
        }
        Ok(())
    }

    pub(crate) fn body(&self) -> Option<realm_sim::movement::Body> {
        self.core.as_ref().and_then(|c| c.body()).copied()
    }

    pub(crate) fn pos(&self) -> Vec3 {
        self.body().map_or(Vec3::ZERO, |b| b.pos)
    }

    pub(crate) fn count(&self, item: &str) -> u32 {
        self.sheet
            .as_ref()
            .map_or(0, |s| realm_rules::items::count_items(s, item))
    }

    pub(crate) fn take(&mut self, f: impl Fn(&ServerMsg) -> bool) -> Option<ServerMsg> {
        let i = self.events.iter().position(f)?;
        Some(self.events.remove(i))
    }
}

pub(crate) fn fail<T>(what: impl Into<String>) -> AnyResult<T> {
    Err(format!("travel check failed: {}", what.into()).into())
}

pub(crate) fn yaw_toward(from: Vec3, to: Vec3) -> f32 {
    // Yaw 0 looks along -Z.
    (-(to.x - from.x)).atan2(-(to.z - from.z))
}

/// Runs ticks at 30 Hz until `done` holds (or `seconds` pass).
pub(crate) fn run_until(
    s: &mut Session,
    seconds: f32,
    mut input: impl FnMut(&Session) -> MoveInput,
    mut done: impl FnMut(&mut Session) -> bool,
) -> AnyResult<bool> {
    let period = Duration::from_secs_f64(1.0 / ClientCore::HZ);
    let end = Instant::now() + Duration::from_secs_f32(seconds);
    let mut next = Instant::now();
    while Instant::now() < end {
        let i = input(s);
        s.pump(i)?;
        if done(s) {
            return Ok(true);
        }
        next += period;
        let now = Instant::now();
        if next > now {
            std::thread::sleep(next - now);
        } else {
            next = now;
        }
    }
    Ok(false)
}

pub(crate) fn idle(_: &Session) -> MoveInput {
    MoveInput::default()
}

/// Walks to `to` along the map's walkable mesh until within `reach`
/// (planar).
pub(crate) fn walk(s: &mut Session, to: Vec3, reach: f32, what: &str) -> AnyResult<()> {
    // A point given on the ground (y 0) stands on the terrain there.
    let mut to = to;
    let world = s.pack.world()?;
    if to.y == 0.0
        && let Some((h, _)) = world.terrain_at(to.x, to.z)
    {
        to.y = h;
    }
    let nav = realm_sim::nav::NavQuery::for_world(&s.pack.nav, &world);
    let mut scratch = realm_sim::nav::NavScratch::default();
    let corners = nav
        .path(s.pos(), to, 20_000, &mut scratch)
        .unwrap_or_else(|| vec![to]);
    let last = corners.len() - 1;
    for (i, corner) in corners.into_iter().enumerate() {
        let r = if i == last { reach } else { 0.9 };
        // A body that stops making way (a lip, a step too high) hops.
        let mut last_pos = s.pos();
        let mut still = 0_u32;
        let ok = run_until(
            s,
            40.0,
            |s| {
                let p = s.pos();
                still = if (p - last_pos).length() < 0.03 {
                    still + 1
                } else {
                    0
                };
                last_pos = p;
                let hop = if still > 10 { MoveInput::JUMP } else { 0 };
                MoveInput::from_intent(0.0, 1.0, yaw_toward(p, corner), hop)
            },
            |s| {
                let p = s.pos();
                s.core.is_some() && Vec3::new(p.x - corner.x, 0.0, p.z - corner.z).length() <= r
            },
        )?;
        if !ok {
            return fail(format!(
                "could not walk to {what}: stuck at {:?} on the way to {corner:?}",
                s.pos()
            ));
        }
    }
    // Stand still a moment so the server's body is there too.
    run_until(s, 0.4, idle, |_| false)?;
    Ok(())
}

pub(crate) fn joined(s: &mut Session) -> AnyResult<()> {
    if !run_until(s, 10.0, idle, |s| {
        s.core.is_some() && s.sheet.is_some() && s.body().is_some()
    })? {
        return fail(format!("never joined {}", s.map));
    }
    Ok(())
}

/// Waits for the trip's ticket and joins the destination with it.
pub(crate) fn follow(s: &mut Session, args: &[String]) -> AnyResult<Session> {
    let mut ticket = None;
    run_until(s, 10.0, idle, |s| {
        if let Some(ServerMsg::Travel {
            map,
            address,
            ticket: t,
        }) = s.take(|m| matches!(m, ServerMsg::Travel { .. }))
        {
            ticket = Some((map, address, t));
        }
        ticket.is_some()
    })?;
    let Some((map, address, ticket)) = ticket else {
        return fail(format!("no ticket on {}", s.map));
    };
    println!("[travel] ticket for {map} at {address}");
    let mut next = Session::open(&address, &map, ticket, args)?;
    joined(&mut next)?;
    if !run_until(&mut next, 5.0, idle, |s| {
        s.events
            .iter()
            .any(|m| matches!(m, ServerMsg::Arrived { .. }))
    })? {
        return fail(format!("no arrival on {map}"));
    }
    Ok(next)
}

/// What travelling must not change.
fn same_goods(
    before: &CharacterSheet,
    after: &CharacterSheet,
    spent: &[(&str, u32)],
) -> AnyResult<()> {
    let mut expected = before.clone();
    for (item, n) in spent {
        realm_rules::items::take_items(&mut expected, item, *n)
            .map_err(|e| format!("{item}: {e}"))?;
    }
    let goods = |s: &CharacterSheet| {
        (
            s.bag
                .iter()
                .map(|c| c.as_ref().map(|i| (i.id.clone(), i.amount, i.uid)))
                .collect::<Vec<_>>(),
            s.equipment.clone(),
            s.oril,
            s.level,
            s.exp,
        )
    };
    if goods(&expected) != goods(after) {
        return fail(format!(
            "the sheet changed on the way: before {:?} after {:?}",
            goods(&expected),
            goods(after)
        ));
    }
    if after.revision < before.revision {
        return fail("an older sheet arrived");
    }
    Ok(())
}

pub(crate) fn near(a: Vec3, b: Vec3, planar: f32) -> bool {
    Vec3::new(a.x - b.x, 0.0, a.z - b.z).length() <= planar
}

fn seed_record(dir: &Path, character: u64, rules: &Rules) -> AnyResult<()> {
    let path = dir.join(format!("{character}.json"));
    let deadline = Instant::now() + Duration::from_secs(10);
    while !path.exists() {
        if Instant::now() > deadline {
            return fail(format!("{} was never saved", path.display()));
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    // Its release follows the save; let both land.
    std::thread::sleep(Duration::from_millis(500));
    let mut sheet: CharacterSheet = serde_json::from_str(&std::fs::read_to_string(&path)?)?;
    sheet.normalize();
    for (item, n) in [("hearth_dust", 5), ("waylink_boot", 1)] {
        realm_rules::items::add_item(&mut sheet, rules.new_item(item, n), rules)?;
    }
    sheet.equipment[Slot::Broom as usize] = Some(rules.new_item("broom_ashwood", 1));
    sheet.revision += 10;
    std::fs::write(&path, serde_json::to_string_pretty(&sheet)?)?;
    Ok(())
}

pub fn run(args: &[String]) -> AnyResult<()> {
    let keys = PathBuf::from(arg(args, "--keys", "keys"));
    let secret: [u8; 32] = std::fs::read(keys.join("ticket.key"))?
        .try_into()
        .map_err(|_| "ticket.key must be 32 bytes")?;
    let key = SigningKey::from_bytes(&secret);
    let content = Content::load(&PathBuf::from(arg(args, "--content", "content/data")))?;
    let rules = Rules::from_content(&content)?;
    let dir = PathBuf::from(arg(args, "--characters", "build/travelcheck"));
    let grounds = arg(args, "--server", "127.0.0.1:7777");
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let character: u64 =
        arg(args, "--character", &(800_000 + now % 100_000).to_string()).parse()?;
    let node = |id: &str| {
        let n = &rules.travel.nodes[id];
        Vec3::new(n.pos[0], n.pos[1], n.pos[2])
    };
    let portal = |id: &str| {
        let p = rules
            .travel
            .portals
            .iter()
            .find(|p| p.id == id)
            .expect("portal");
        Vec3::new(p.center[0], p.center[1], p.center[2])
    };
    let spawn = |map: &str, id: &str| {
        let p = rules.travel.maps[map].spawns[id];
        Vec3::new(p[0], p[1], p[2])
    };
    let mut corrections = 0;

    // A new character, then its travel kit.
    {
        let mut s = Session::dev(&grounds, "grounds", character, &key, args)?;
        joined(&mut s)?;
        println!("[travel] character {character} made on the grounds");
    }
    seed_record(&dir, character, &rules)?;
    let mut s = Session::dev(&grounds, "grounds", character, &key, args)?;
    joined(&mut s)?;
    if s.count("hearth_dust") != 5 || s.count("waylink_boot") != 1 {
        return fail("the seeded record did not load");
    }

    // 1. The castle door.
    walk(
        &mut s,
        spawn("grounds", "castle_approach"),
        1.0,
        "the castle approach",
    )?;
    walk(&mut s, portal("castle_door"), 1.2, "the castle door")?;
    let before = s.sheet.clone().unwrap_or_default();
    s.net
        .send_control(&ClientMsg::Door("castle_door".to_owned()));
    let mut castle = follow(&mut s, args)?;
    corrections += s.corrections;
    drop(s);
    same_goods(&before, castle.sheet.as_ref().unwrap_or(&before), &[])?;
    if !near(castle.pos(), spawn("castle_interior", "vestibule"), 3.0) {
        return fail(format!("castle arrival at {:?}", castle.pos()));
    }
    println!("[travel] 1 ok: through the castle door, the sheet whole");

    // 2. Out again.
    walk(
        &mut castle,
        portal("vestibule_exit"),
        1.2,
        "the vestibule exit",
    )?;
    let before = castle.sheet.clone().unwrap_or_default();
    castle
        .net
        .send_control(&ClientMsg::Door("vestibule_exit".to_owned()));
    let mut s = follow(&mut castle, args)?;
    corrections += castle.corrections;
    drop(castle);
    same_goods(&before, s.sheet.as_ref().unwrap_or(&before), &[])?;
    if !near(s.pos(), spawn("grounds", "castle_approach"), 3.0) {
        return fail(format!("grounds arrival at {:?}", s.pos()));
    }
    println!("[travel] 2 ok: back on the grounds at the castle approach");

    // 3. Hearths: a refusal by level, a trip on this map.
    walk(&mut s, node("hearth_pavilion"), 3.0, "the Ember Pavilion")?;
    s.net.send_control(&ClientMsg::Travel {
        from: "hearth_pavilion".to_owned(),
        to: "hearth_blackweb_camp".to_owned(),
    });
    let mut refused = None;
    run_until(&mut s, 3.0, idle, |s| {
        refused = s.take(|m| matches!(m, ServerMsg::TravelResult { .. }));
        refused.is_some()
    })?;
    if !matches!(&refused, Some(ServerMsg::TravelResult { ok: false, reason, .. }) if reason == "level_too_low")
    {
        return fail(format!("a level 1 hearth trip to the caverns: {refused:?}"));
    }
    let before = s.sheet.clone().unwrap_or_default();
    s.net.send_control(&ClientMsg::Travel {
        from: "hearth_pavilion".to_owned(),
        to: "hearth_orvell_square".to_owned(),
    });
    let orvell = node("hearth_orvell_square");
    if !run_until(&mut s, 5.0, idle, |s| {
        s.events
            .iter()
            .any(|m| matches!(m, ServerMsg::Arrived { .. }))
            && near(s.pos(), orvell, 6.0)
    })? {
        return fail(format!(
            "the hearth trip to Orvell Square ended at {:?}",
            s.pos()
        ));
    }
    s.events.clear();
    run_until(&mut s, 1.0, idle, |s| s.count("hearth_dust") == 4)?;
    same_goods(
        &before,
        s.sheet.as_ref().unwrap_or(&before),
        &[("hearth_dust", 1)],
    )?;
    println!("[travel] 3 ok: refused by level, then Pavilion -> Orvell Square for one dust");

    // 4. The broom.
    s.net.send_control(&ClientMsg::Ride(true));
    if !run_until(&mut s, 3.0, idle, |s| s.body().is_some_and(|b| b.mounted))? {
        return fail(format!("never mounted: {:?}", s.events));
    }
    let ground = s.pos().y;
    run_until(
        &mut s,
        2.0,
        |_| MoveInput {
            buttons: MoveInput::JUMP,
            ..MoveInput::default()
        },
        |_| false,
    )?;
    if s.pos().y < ground + 6.0 {
        return fail(format!(
            "the broom did not climb: {} -> {}",
            ground,
            s.pos().y
        ));
    }
    s.events.clear();
    s.net.send_control(&ClientMsg::Ride(false));
    let mut answer = None;
    run_until(&mut s, 2.0, idle, |s| {
        answer = s.take(|m| matches!(m, ServerMsg::TravelResult { .. }));
        answer.is_some()
    })?;
    if !matches!(&answer, Some(ServerMsg::TravelResult { ok: false, reason, .. }) if reason == "no_landing")
    {
        return fail(format!("getting off in the air: {answer:?}"));
    }
    run_until(
        &mut s,
        4.0,
        |_| MoveInput {
            buttons: MoveInput::DESCEND,
            ..MoveInput::default()
        },
        |_| false,
    )?;
    s.net.send_control(&ClientMsg::Ride(false));
    if !run_until(&mut s, 3.0, idle, |s| {
        s.body().is_some_and(|b| !b.mounted && b.on_floor)
    })? {
        return fail(format!("never got off the broom: {:?}", s.events));
    }
    s.events.clear();
    println!("[travel] 4 ok: mounted, climbed, refused a landing in the air, came down, got off");

    // 5. A Waystake, alone: it fires after its countdown.
    s.net
        .send_control(&ClientMsg::WaylinkPlace("hearth_pavilion".to_owned()));
    let pavilion = node("hearth_pavilion");
    if !run_until(&mut s, 14.0, idle, |s| {
        s.events
            .iter()
            .any(|m| matches!(m, ServerMsg::Arrived { kind } if kind == "waylink"))
    })? {
        return fail(format!("the Waystake never carried: {:?}", s.events));
    }
    run_until(&mut s, 0.5, idle, |_| false)?;
    if !near(s.pos(), pavilion, 33.0) || s.count("waylink_boot") != 0 {
        return fail(format!(
            "the Waystake set down at {:?} (boots left {})",
            s.pos(),
            s.count("waylink_boot")
        ));
    }
    s.events.clear();
    println!(
        "[travel] 5 ok: the Waystake carried it near the Pavilion ({:?})",
        s.pos()
    );

    // 6. A hearth to another map.
    walk(&mut s, pavilion, 3.0, "the Ember Pavilion again")?;
    let before = s.sheet.clone().unwrap_or_default();
    s.net.send_control(&ClientMsg::Travel {
        from: "hearth_pavilion".to_owned(),
        to: "hearth_feast_hall".to_owned(),
    });
    let mut castle = follow(&mut s, args)?;
    corrections += s.corrections;
    drop(s);
    same_goods(
        &before,
        castle.sheet.as_ref().unwrap_or(&before),
        &[("hearth_dust", 1)],
    )?;
    if !near(castle.pos(), node("hearth_feast_hall"), 5.0) {
        return fail(format!("the Long Table arrival at {:?}", castle.pos()));
    }
    println!("[travel] 6 ok: Pavilion -> Long Table across maps");

    // 7. A second login elsewhere takes the character over.
    run_until(&mut castle, 0.5, idle, |_| false)?;
    let newest = castle.sheet.clone().unwrap_or_default();
    let mut again = Session::dev(&grounds, "grounds", character, &key, args)?;
    joined(&mut again)?;
    if !run_until(&mut castle, 5.0, idle, |s| s.closed.is_some())? {
        return fail("the castle kept its session after a login elsewhere");
    }
    same_goods(&newest, again.sheet.as_ref().unwrap_or(&newest), &[])?;
    corrections += castle.corrections;
    run_until(&mut again, 1.0, idle, |_| false)?;
    corrections += again.corrections;
    println!("[travel] 7 ok: a login on the grounds took it from the castle with the newest sheet");

    if corrections > 0 {
        return fail(format!("{corrections} prediction corrections"));
    }
    println!("[travel] ok: doors, hearths, broom, Waystake, a handover; no corrections");
    Ok(())
}
