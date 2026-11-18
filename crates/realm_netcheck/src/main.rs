//! realm_netcheck --server 127.0.0.1:7800 [--keys keys] [--map grounds]
//!                [--content content/data] [--maps world/maps] [--seconds 60]
//!                [--character 900001]
//! realm_netcheck --social [--server A --map A --server-b B --map-b B]   (see social.rs)
//! realm_netcheck --travel --characters <dir>                           (see travel.rs)
//! realm_netcheck --dungeon --characters <dir>                          (see dungeon.rs)
//! realm_netcheck --boss threehead|snare --characters <dir>             (see boss.rs)
//! realm_netcheck --lair eggs|queen --characters <dir>                  (see lair.rs)
//! realm_netcheck --maintenance --admin <addr> --token <t> ...          (see maintenance.rs)
//! realm_netcheck --ga --admin <addr> --token <t> [--config-ga <id>] ...  (see ga.rs)
//! realm_netcheck --login --login-addr <addr> [--persist-addr <addr>]    (see login.rs)
//! realm_netcheck --persist --persist-addr <addr> --server <grounds>     (see persist.rs)
//! realm_netcheck --smoke --server <addr> [--map grounds]               (see smoke.rs)
//! realm_netcheck --stand --server <addr> [--map grounds] [--seconds 10] (see stand.rs)
//! realm_netcheck --ground --server <addr> [--map grounds] [--seconds 20] (see ground.rs)
//! realm_netcheck --metrics --admin <addr> --token <t> --server <grounds> [--persist-addr <addr>]
//!                                                                      (see metrics.rs)
//!
//! One player through the real client core, playing a scripted session
//! (running, turning, jumping, strafing, stopping) at 30 Hz against a server,
//! usually through `realm_netem`. Every snapshot is reconciled exactly as the
//! game client does it; a reconciliation that moves the player is a
//! correction the player would see as a snap back. Exits with an error if
//! there was any (Phase 4 exit: none at 200 ms and 2% loss).

mod boss;
mod dungeon;
mod ga;
mod ground;
mod lair;
mod login;
mod maintenance;
mod metrics;
mod persist;
mod smoke;
mod social;
mod stand;
mod travel;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use realm_data::Content;
use realm_netclient::{ClientCore, NetEvent, NetHandle};
use realm_proto::SigningKey;
use realm_proto::ticket::Ticket;
use realm_rules::{Cell, ItemOp};
use realm_sim::input::MoveInput;

type AnyResult<T> = Result<T, Box<dyn std::error::Error>>;

/// Item requests made one after another, each with the answer the server
/// must give. A new character (the starter kit: health potions in bag cell
/// 0, mana potions in cell 1, the wand worn) runs the refusals and the bag
/// moves; a prepared character (hurt, at a hearth, with Velkar Ash and
/// scrolls in cells 2-4; tools/fixtures) runs the paid paths.
fn item_script(prepared: bool) -> Vec<(ItemOp, bool, &'static str)> {
    use realm_rules::Slot::MainHand;
    if prepared {
        return vec![
            (ItemOp::Use { cell: 0 }, true, "consumed"),
            (
                ItemOp::Refine {
                    target: Cell::Worn(MainHand),
                },
                true,
                "refined",
            ),
            (
                ItemOp::Refine {
                    target: Cell::Worn(MainHand),
                },
                true,
                "refined",
            ),
            (
                ItemOp::Enchant {
                    scroll: 3,
                    target: Cell::Worn(MainHand),
                },
                true,
                "enchanted",
            ),
            (
                ItemOp::Enchant {
                    scroll: 4,
                    target: Cell::Worn(MainHand),
                },
                true,
                "enchanted",
            ),
            (
                ItemOp::Buy {
                    item: "hearth_dust".to_owned(),
                    amount: 1,
                },
                true,
                "bought",
            ),
        ];
    }
    vec![
        (
            ItemOp::Move {
                from: Cell::Worn(MainHand),
                to: Cell::Bag(5),
            },
            true,
            "unequipped",
        ),
        (
            ItemOp::Move {
                from: Cell::Bag(5),
                to: Cell::Worn(MainHand),
            },
            true,
            "equipped",
        ),
        (
            ItemOp::Move {
                from: Cell::Bag(0),
                to: Cell::Worn(MainHand),
            },
            false,
            "wrong_slot",
        ),
        (ItemOp::Use { cell: 0 }, false, "resource_full"),
        (
            ItemOp::Move {
                from: Cell::Bag(0),
                to: Cell::Bag(10),
            },
            true,
            "moved",
        ),
        (
            ItemOp::Move {
                from: Cell::Bag(1),
                to: Cell::Bag(10),
            },
            true,
            "moved",
        ),
        (ItemOp::Sell { cell: 1 }, true, "sold"),
        (
            ItemOp::Buy {
                item: "hearth_dust".to_owned(),
                amount: 1,
            },
            false,
            "not_at_shop",
        ),
        (
            ItemOp::Refine {
                target: Cell::Worn(MainHand),
            },
            false,
            "no_material",
        ),
        (ItemOp::Destroy { cell: 10 }, true, "destroyed"),
        (ItemOp::Destroy { cell: 10 }, false, "item_missing"),
    ]
}

fn arg(args: &[String], name: &str, default: &str) -> String {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .cloned()
        .unwrap_or_else(|| default.to_owned())
}

/// The scripted intent for a tick: a few seconds of each kind of movement.
fn intent(tick: u32) -> MoveInput {
    let t = tick % 600;
    let yaw = ((tick.wrapping_mul(37)) & 0xFFFF) as u16;
    let jump = if (t / 45).is_multiple_of(4) && t % 45 < 3 {
        MoveInput::JUMP
    } else {
        0
    };
    match t / 100 {
        0 | 1 => MoveInput {
            strafe: 0,
            forward: 127,
            yaw,
            buttons: jump,
        },
        2 => MoveInput {
            strafe: 127,
            forward: 64,
            yaw: yaw.wrapping_add(16_384),
            buttons: 0,
        },
        3 => MoveInput {
            strafe: 0,
            forward: 0,
            yaw,
            buttons: jump,
        },
        4 => MoveInput {
            strafe: -100,
            forward: 100,
            yaw: yaw.wrapping_mul(3),
            buttons: jump,
        },
        _ => MoveInput {
            strafe: 0,
            forward: -127,
            yaw,
            buttons: 0,
        },
    }
}

fn main() -> AnyResult<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "--social") {
        return social::run(&args);
    }
    if args.iter().any(|a| a == "--social-partner") {
        return social::partner(&args);
    }
    if args.iter().any(|a| a == "--duel") {
        return social::duel(&args);
    }
    if args.iter().any(|a| a == "--travel") {
        return travel::run(&args);
    }
    if args.iter().any(|a| a == "--boss") {
        return boss::run(&args);
    }
    if args.iter().any(|a| a == "--lair") {
        return lair::run(&args);
    }
    if args.iter().any(|a| a == "--maintenance") {
        return maintenance::run(&args);
    }
    if args.iter().any(|a| a == "--ga") {
        return ga::run(&args);
    }
    if args.iter().any(|a| a == "--login") {
        return login::run(&args);
    }
    if args.iter().any(|a| a == "--metrics") {
        return metrics::run(&args);
    }
    if args.iter().any(|a| a == "--persist") {
        return persist::run(&args);
    }
    if args.iter().any(|a| a == "--dungeon") {
        return dungeon::run(&args);
    }
    if args.iter().any(|a| a == "--smoke") {
        return smoke::run(&args);
    }
    if args.iter().any(|a| a == "--stand") {
        return stand::run(&args);
    }
    if args.iter().any(|a| a == "--ground") {
        return ground::run(&args);
    }
    let server: SocketAddr = arg(&args, "--server", "127.0.0.1:7800").parse()?;
    let keys = PathBuf::from(arg(&args, "--keys", "keys"));
    let map = arg(&args, "--map", "grounds");
    let content = Content::load(&PathBuf::from(arg(&args, "--content", "content/data")))?;
    let pack = realm_data::maps::read_pack(
        &PathBuf::from(arg(&args, "--maps", "world/maps")).join(format!("{map}.realmmap")),
    )?;
    let seconds: u64 = arg(&args, "--seconds", "60").parse()?;

    let secret: [u8; 32] = std::fs::read(keys.join("ticket.key"))?
        .try_into()
        .map_err(|_| "ticket.key must be 32 bytes")?;
    let key = SigningKey::from_bytes(&secret);
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let character: u64 = arg(&args, "--character", "900001").parse()?;
    let ticket = Ticket::new(character, character, now + 60)?.sign(&key);
    let net = NetHandle::connect(
        server,
        "localhost",
        std::fs::read(keys.join("tls.crt.der"))?,
        ticket,
    )?;

    let started = Instant::now();
    let local_ticks = |at: Instant| at.duration_since(started).as_secs_f64() * ClientCore::HZ;
    let mut core: Option<ClientCore> = None;
    let deadline = Duration::from_secs(seconds);
    let period = Duration::from_secs_f64(1.0 / ClientCore::HZ);
    let mut next = Instant::now();
    let mut report = Instant::now() + Duration::from_secs(5);
    let mut last = (0_u64, 0_u64);
    let mut deaths = 0;
    let mut sheets = 0_u32;
    // The control channel both ways: after the first sheet the check asks for
    // a look with an unknown key, an out-of-range pick and an unrounded
    // slider; the server must answer with the cleaned look.
    let asked_look: Vec<(String, f32)> = vec![
        ("hair".to_owned(), 2.0),
        ("hair_color".to_owned(), 99.0),
        ("jaw".to_owned(), 0.555),
        ("not_a_look_key".to_owned(), 1.0),
    ];
    let mut look_answered = false;
    // Then the item requests, each waiting for the answer to the one before.
    let mut script = item_script(false);
    let mut step = 0_usize;
    let mut revision = 0_u64;
    let mut awaiting_sheet = false;
    let mut items_done = false;
    let mut stale_checked = false;
    // Then combat: a spell not learned is refused, learning it is answered,
    // the learned spell starts (and costs its mana), an immediate second cast
    // is refused for its cooldown.
    let rules = realm_rules::Rules::from_content(&content)?;
    let stun = rules
        .combat
        .spell("stun_bolt")
        .ok_or("content has no stun_bolt")?
        .clone();
    let mut combat_phase = 0_u8;
    let mut cast_now = false;
    let mut mana_before = 0_u32;
    let mut combat_done = false;
    let mut me = 0_u32;
    while started.elapsed() < deadline {
        while let Some(event) = net.poll() {
            match event {
                NetEvent::Joined {
                    entity,
                    tick,
                    content_hash,
                    ..
                } => {
                    if content_hash
                        .iter()
                        .map(|b| format!("{b:02x}"))
                        .collect::<String>()
                        != content.hash()
                    {
                        return Err("the server runs different content".into());
                    }
                    let world = pack.world()?;
                    let stairs = realm_data::staircases(&content, &pack)?;
                    println!("[netcheck] joined as {entity} at server tick {tick} on {map}");
                    me = entity;
                    core = Some(ClientCore::new(world, stairs, entity, tick));
                }
                NetEvent::Refused(reason) => return Err(format!("refused: {reason}").into()),
                NetEvent::Datagram(bytes) => {
                    if let Some(core) = core.as_mut() {
                        let hp_before = core.own_hp();
                        core.on_datagram(&bytes, local_ticks(Instant::now()));
                        if hp_before > 0 && core.own_hp() == 0 {
                            deaths += 1;
                        }
                    }
                }
                NetEvent::Control(realm_proto::control::ServerMsg::Sheet(sheet)) => {
                    if sheets == 0 {
                        println!(
                            "[netcheck] character {} '{}' level {}, {} oril, {} items in the bag, saved at {:?}",
                            sheet.id,
                            sheet.name,
                            sheet.level,
                            sheet.oril,
                            sheet.bag.iter().flatten().count(),
                            sheet.place.as_ref().map(|p| (p.map.as_str(), p.pos))
                        );
                    }
                    if sheets == 0 {
                        net.send_control(&realm_proto::control::ClientMsg::Look(
                            asked_look.clone(),
                        ));
                    } else if !look_answered && !sheet.look.is_empty() {
                        let get =
                            |k: &str| sheet.look.iter().find(|(key, _)| key == k).map(|(_, v)| *v);
                        println!("[netcheck] look came back cleaned: {:?}", sheet.look);
                        if get("hair") != Some(2.0)
                            || get("hair_color").is_none_or(|v| v >= 99.0)
                            || get("jaw") != Some(0.56)
                            || get("not_a_look_key").is_some()
                        {
                            return Err(
                                format!("look not cleaned as expected: {:?}", sheet.look).into()
                            );
                        }
                        look_answered = true;
                    }
                    revision = sheet.revision;
                    if look_answered && !items_done && (awaiting_sheet || step == 0) {
                        awaiting_sheet = false;
                        let holds = |cell: usize, id: &str| {
                            sheet.bag[cell].as_ref().is_some_and(|i| i.id == id)
                        };
                        if step == 0 && holds(2, "mat_phoenix_ash") {
                            script = item_script(true);
                        } else if step == 0
                            && !(holds(0, "potion_health") && holds(1, "potion_mana"))
                        {
                            return Err("the item check needs a new character (run the server without --characters) or the prepared one".into());
                        }
                        if let Some((op, _, _)) = script.get(step) {
                            net.send_control(&realm_proto::control::ClientMsg::Item {
                                op_id: step as u32,
                                revision,
                                op: op.clone(),
                            });
                        }
                    }
                    sheets += 1;
                }
                NetEvent::Control(realm_proto::control::ServerMsg::ItemResult {
                    op_id,
                    ok,
                    reason,
                    amount,
                }) => {
                    if op_id == u32::MAX {
                        // the deliberately stale request
                        if ok || reason != "stale" {
                            return Err(
                                format!("a stale request was answered {ok} {reason}").into()
                            );
                        }
                        stale_checked = true;
                        continue;
                    }
                    let (_, want_ok, want) = &script[op_id as usize];
                    println!(
                        "[netcheck] item step {op_id}: {} {reason} ({amount})",
                        if ok { "ok" } else { "refused" }
                    );
                    if ok != *want_ok || reason != *want {
                        return Err(
                            format!("item step {op_id}: expected {want}, got {reason}").into()
                        );
                    }
                    step += 1;
                    if step == script.len() {
                        items_done = true;
                        // One request made against an old sheet must be refused.
                        net.send_control(&realm_proto::control::ClientMsg::Item {
                            op_id: u32::MAX,
                            revision: revision.saturating_sub(1),
                            op: ItemOp::Destroy { cell: 0 },
                        });
                    } else if ok {
                        awaiting_sheet = true;
                    } else if let Some((op, _, _)) = script.get(step) {
                        net.send_control(&realm_proto::control::ClientMsg::Item {
                            op_id: step as u32,
                            revision,
                            op: op.clone(),
                        });
                    }
                }
                NetEvent::Control(realm_proto::control::ServerMsg::SkillResult {
                    spell,
                    ok,
                    reason,
                }) => {
                    println!("[netcheck] skill {spell}: {reason}");
                    if combat_phase == 2 {
                        if !ok {
                            return Err(format!("learning {spell} was refused: {reason}").into());
                        }
                        combat_phase = 3;
                        cast_now = true;
                    }
                }
                NetEvent::Control(realm_proto::control::ServerMsg::Combat(events)) => {
                    use realm_proto::control::CombatEvent;
                    for event in events {
                        match event {
                            CombatEvent::CastRefused { spell, reason } if spell == stun.index => {
                                println!("[netcheck] cast refused: {reason}");
                                match (combat_phase, reason.as_str()) {
                                    (1, "skill_locked") => {
                                        combat_phase = 2;
                                        net.send_control(
                                            &realm_proto::control::ClientMsg::LearnSkill(
                                                stun.id.clone(),
                                            ),
                                        );
                                    }
                                    (4, "cooldown") => {
                                        combat_phase = 5;
                                        combat_done = true;
                                        let mana = core.as_ref().map_or(0, |c| c.own_vitals()[2]);
                                        println!(
                                            "[netcheck] mana now {mana} (stun bolt costs {})",
                                            stun.mana_cost
                                        );
                                    }
                                    _ => {
                                        return Err(format!("unexpected refusal in combat step {combat_phase}: {reason}").into());
                                    }
                                }
                            }
                            CombatEvent::CastStarted { caster, spell, .. }
                                if caster == me && spell == stun.index =>
                            {
                                if combat_phase != 3 {
                                    return Err(format!(
                                        "a cast started in combat step {combat_phase}"
                                    )
                                    .into());
                                }
                                // the spell left; its mana shows in the next snapshots
                                println!(
                                    "[netcheck] stun bolt started (mana {mana_before} before)"
                                );
                                combat_phase = 4;
                                cast_now = true;
                            }
                            _ => {}
                        }
                    }
                }
                // Creature answers, map notices and the kill loop: the castle
                // has none of them.
                NetEvent::Control(
                    realm_proto::control::ServerMsg::CreatureInfo { .. }
                    | realm_proto::control::ServerMsg::Notice { .. }
                    | realm_proto::control::ServerMsg::Maintenance { .. }
                    | realm_proto::control::ServerMsg::Weather { .. }
                    | realm_proto::control::ServerMsg::Effects(_)
                    | realm_proto::control::ServerMsg::Reward { .. }
                    | realm_proto::control::ServerMsg::Chest { .. }
                    | realm_proto::control::ServerMsg::LootResult { .. }
                    | realm_proto::control::ServerMsg::Death { .. }
                    | realm_proto::control::ServerMsg::AttributeResult { .. }
                    | realm_proto::control::ServerMsg::QuestResult { .. }
                    | realm_proto::control::ServerMsg::Chat { .. }
                    | realm_proto::control::ServerMsg::PartyInvite { .. }
                    | realm_proto::control::ServerMsg::Party(_)
                    | realm_proto::control::ServerMsg::PlayerInfo { .. }
                    | realm_proto::control::ServerMsg::DuelInvite { .. }
                    | realm_proto::control::ServerMsg::Duel(_)
                    | realm_proto::control::ServerMsg::TravelResult { .. }
                    | realm_proto::control::ServerMsg::Departing { .. }
                    | realm_proto::control::ServerMsg::Travel { .. }
                    | realm_proto::control::ServerMsg::Arrived { .. }
                    | realm_proto::control::ServerMsg::Waylink(_)
                    | realm_proto::control::ServerMsg::Dungeon(_)
                    | realm_proto::control::ServerMsg::Gate { .. },
                ) => {}
                NetEvent::Closed(why) => return Err(format!("connection closed: {why}").into()),
            }
        }
        if let Some(core) = core.as_mut() {
            if items_done && stale_checked && combat_phase == 0 {
                combat_phase = 1;
                cast_now = true;
            }
            let action = if cast_now {
                cast_now = false;
                if combat_phase == 3 {
                    mana_before = core.own_vitals()[2];
                }
                stun.index + 1
            } else {
                0
            };
            let ahead = core.body().map_or(realm_sim::Vec3::ZERO, |b| {
                b.pos + realm_sim::Vec3::new(0.0, 1.0, -8.0)
            });
            let bytes = core.step(intent(core.tick()), action, 0, ahead);
            net.send(bytes);
            if Instant::now() >= report {
                let s = core.stats;
                let pos = core.body().map(|b| b.pos);
                println!(
                    "[netcheck {:>3.0}s] snapshots {:.1}/s, corrections {} (max {:.3} m), replayed {}, deaths {deaths}, at {pos:?}",
                    started.elapsed().as_secs_f64(),
                    (s.snapshots - last.0) as f64 / 5.0,
                    s.corrections,
                    s.max_correction,
                    s.replayed,
                );
                last = (s.snapshots, s.corrections);
                report += Duration::from_secs(5);
            }
        }
        next += period;
        let now = Instant::now();
        if next > now {
            std::thread::sleep(next - now);
        } else {
            next = now;
        }
    }
    let Some(core) = core else {
        return Err("never joined".into());
    };
    let s = core.stats;
    println!(
        "[netcheck] {} snapshots, {} decode errors, {} corrections (max {:.3} m), {} inputs replayed, {deaths} deaths, {} server moves (death/respawn)",
        s.snapshots, s.decode_errors, s.corrections, s.max_correction, s.replayed, s.server_moves
    );
    if s.corrections > 0 || s.decode_errors > 0 || s.snapshots < seconds * 10 {
        return Err("the player was corrected, or snapshots went missing".into());
    }
    if sheets == 0 {
        return Err("no character sheet arrived on the control channel".into());
    }
    if !look_answered {
        return Err("the look request was never answered".into());
    }
    if !combat_done {
        return Err(format!("the combat check stopped at step {combat_phase} of 5").into());
    }
    if !items_done || !stale_checked {
        return Err(format!("item requests stopped at step {step} of {}", script.len()).into());
    }
    Ok(())
}
