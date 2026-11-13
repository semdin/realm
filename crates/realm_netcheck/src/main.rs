//! realm_netcheck --server 127.0.0.1:7800 [--keys keys] [--map grounds]
//!                [--content content/data] [--maps world/maps] [--seconds 60]
//!
//! One player through the real client core, playing a scripted session
//! (running, turning, jumping, strafing, stopping) at 30 Hz against a server,
//! usually through `realm_netem`. Every snapshot is reconciled exactly as the
//! game client does it; a reconciliation that moves the player is a
//! correction the player would see as a snap back. Exits with an error if
//! there was any (Phase 4 exit: none at 200 ms and 2% loss).

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use realm_data::Content;
use realm_netclient::{ClientCore, NetEvent, NetHandle};
use realm_proto::SigningKey;
use realm_proto::ticket::Ticket;
use realm_sim::input::MoveInput;

type AnyResult<T> = Result<T, Box<dyn std::error::Error>>;

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
    let ticket = Ticket::new(900_001, 900_001, now + 60)?.sign(&key);
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
    while started.elapsed() < deadline {
        while let Some(event) = net.poll() {
            match event {
                NetEvent::Joined {
                    entity,
                    tick,
                    content_hash,
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
                    } else if !sheet.look.is_empty() {
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
                    sheets += 1;
                }
                NetEvent::Closed(why) => return Err(format!("connection closed: {why}").into()),
            }
        }
        if let Some(core) = core.as_mut() {
            let bytes = core.step(intent(core.tick()), 0, 0);
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
    Ok(())
}
