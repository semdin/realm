//! `realm_netcheck --boss wheelwarden|snare --characters <dir>
//!  [--server <castle>]`: a multi-part boss of the Brine Vaults. Needs the
//! coordinator, castle_interior and dng_sealed_wing (started with
//! `--dev-dungeon-start <step> --dev-dungeon-scale 0.05`) sharing `<dir>`.
//!
//! A level 34 character starts Normal at the Brine Vaults' gate, walks down
//! to the boss and:
//! - wheelwarden: works the sluice wheel until the Wheelwarden is seized, then
//!   breaks its plates one by one; the body falls with its last plate;
//! - snare: the heart cannot be hurt while a stem stands; the stems fall,
//!   then the heart.
//!
//! No prediction correction allowed.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use realm_data::Content;
use realm_netclient::ClientCore;
use realm_proto::SigningKey;
use realm_proto::control::{ClientMsg, DungeonMsg, ServerMsg};
use realm_rules::{CharacterSheet, Rules};
use realm_sim::Vec3;
use realm_sim::input::MoveInput;

use crate::travel::{Session, fail, follow, idle, joined, run_until, walk, yaw_toward};
use crate::{AnyResult, arg};

fn seed(dir: &Path, character: u64) -> AnyResult<()> {
    let path = dir.join(format!("{character}.json"));
    let deadline = Instant::now() + Duration::from_secs(10);
    while !path.exists() {
        if Instant::now() > deadline {
            return fail(format!("{} was never saved", path.display()));
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    std::thread::sleep(Duration::from_millis(500));
    let mut sheet: CharacterSheet = serde_json::from_str(&std::fs::read_to_string(&path)?)?;
    sheet.level = 34;
    sheet.exp = 0;
    sheet.place = Some(realm_rules::Place {
        map: "castle_interior".to_owned(),
        pos: [65.1, 230.6, -7.0],
        yaw: 0.0,
    });
    sheet.revision += 10;
    std::fs::write(&path, serde_json::to_string_pretty(&sheet)?)?;
    Ok(())
}

fn state(s: &Session) -> Option<realm_proto::control::RunView> {
    s.events.iter().rev().find_map(|m| match m {
        ServerMsg::Dungeon(d) => match &**d {
            DungeonMsg::State(v) => Some(v.clone()),
            _ => None,
        },
        _ => None,
    })
}

fn messages(s: &Session) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for m in &s.events {
        if let ServerMsg::Dungeon(d) = m
            && let DungeonMsg::State(v) = &**d
            && out.last() != Some(&v.message)
            && !v.message.is_empty()
        {
            out.push(v.message.clone());
        }
    }
    out
}

pub fn run(args: &[String]) -> AnyResult<()> {
    let which = arg(args, "--boss", "wheelwarden");
    let keys = PathBuf::from(arg(args, "--keys", "keys"));
    let secret: [u8; 32] = std::fs::read(keys.join("ticket.key"))?
        .try_into()
        .map_err(|_| "ticket.key must be 32 bytes")?;
    let key = SigningKey::from_bytes(&secret);
    let content = Content::load(&PathBuf::from(arg(args, "--content", "content/data")))?;
    let rules = Rules::from_content(&content)?;
    let dir = PathBuf::from(arg(args, "--characters", "build/bosscheck"));
    let castle = arg(args, "--server", "127.0.0.1:7778");
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let character: u64 =
        arg(args, "--character", &(600_000 + now % 100_000).to_string()).parse()?;
    let kind_of = |species: &str| {
        rules
            .mobs
            .species_order
            .iter()
            .position(|s| s == species)
            .map_or(0, |i| i as u16 + 1)
    };
    let (body_kind, part_kind) = if which == "snare" {
        (kind_of("strangling_vine"), kind_of("snare_vine"))
    } else {
        (kind_of("wheelwarden"), kind_of("wheelwarden_plate"))
    };
    {
        let mut s = Session::dev(&castle, "castle_interior", character, &key, args)?;
        joined(&mut s)?;
    }
    seed(&dir, character)?;
    let mut s = Session::dev(&castle, "castle_interior", character, &key, args)?;
    joined(&mut s)?;
    walk(
        &mut s,
        Vec3::new(65.1, 230.5, -10.0),
        0.8,
        "the Brine Vaults' door",
    )?;
    s.net.send_control(&ClientMsg::DungeonStart {
        portal: "fc_entry".to_owned(),
        difficulty: 1,
    });
    let mut d = follow(&mut s, args)?;
    let mut corrections = s.corrections;
    drop(s);
    if !run_until(&mut d, 30.0, idle, |s| {
        state(s).is_some_and(|v| v.phase == 2)
    })? {
        return fail("the run never started");
    }
    let o = realm_rules::dungeons::copy_offset(d.copy);
    let origin = Vec3::new(o[0], 0.0, o[2]);
    // Down the corridor to the boss (the steps before it are done, their
    // gates open).
    let (line, stand) = if which == "snare" {
        (-70.0, Vec3::new(0.0, 1200.5, -70.0))
    } else {
        (-172.0, Vec3::new(18.0, 1200.5, -172.0))
    };
    let way: &[f32] = if which == "snare" {
        &[-20.0, -60.0]
    } else {
        &[-20.0, -60.0, -100.0]
    };
    for &z in way {
        walk(
            &mut d,
            origin + Vec3::new(0.0, 1200.5, z),
            1.2,
            "the corridor",
        )?;
    }
    // Wheelwarden's stair: stand in the breath's band until it pushes.
    if which != "snare" {
        walk(
            &mut d,
            origin + Vec3::new(0.0, 1200.5, -150.0),
            0.8,
            "the stair",
        )?;
        let before = d.pos();
        if !run_until(&mut d, 15.0, idle, |s| (s.pos() - before).length() > 1.5)? {
            return fail(format!("the breath never pushed: {:?}", messages(&d)));
        }
        if !messages(&d).iter().any(|m| m.contains("surge of brine")) {
            return fail("the surge came unannounced");
        }
        println!(
            "[boss] the breath pushed it {:.1} m",
            (d.pos() - before).length()
        );
    }
    walk(
        &mut d,
        origin + Vec3::new(0.0, 1200.5, line),
        1.2,
        "the corridor",
    )?;
    walk(&mut d, origin + stand, 0.8, "the boss's floor")?;
    println!("[boss] at the {which}");
    let local_ticks = |d: &Session| d.started.elapsed().as_secs_f64() * ClientCore::HZ;
    let find = |d: &Session, kind: u16| {
        d.core.as_ref().map_or(Vec::new(), |c| {
            c.remote_entities(local_ticks(d))
                .into_iter()
                .filter(|e| e.kind & realm_proto::KIND_SPECIES == kind)
                .collect::<Vec<_>>()
        })
    };
    // Wheelwarden: stand by the chime until it sleeps.
    if which != "snare" {
        let mut slept = false;
        run_until(&mut d, 40.0, idle, |s| {
            slept = find(s, body_kind)
                .iter()
                .any(|e| e.status & realm_proto::STATUS_STUN != 0);
            slept
        })?;
        if !slept {
            return fail(format!(
                "the Wheelwarden was never seized: {:?}",
                messages(&d)
            ));
        }
        println!("[boss] the sluice wheel seized it");
    }
    // Bring the parts down, then the body.
    let mut next_cast = 0_u32;
    let started = Instant::now();
    let mut parts_seen = 0;
    while started.elapsed() < Duration::from_secs(240) {
        let bodies = find(&d, body_kind);
        if bodies.first().is_some_and(|b| b.state == 3) {
            break;
        }
        let parts = find(&d, part_kind);
        parts_seen = parts_seen.max(parts.len());
        let standing: Vec<_> = parts.iter().filter(|e| e.state != 3).collect();
        let target = standing
            .first()
            .map(|e| (e.id, e.pos))
            .or_else(|| bodies.first().map(|b| (b.id, b.pos)));
        let tick = d.core.as_ref().map_or(0, ClientCore::tick);
        let me = d.pos();
        let input = if let Some((id, pos)) = target {
            if tick >= next_cast {
                next_cast = tick + 18;
                d.action = (1, id, pos + Vec3::new(0.0, 1.0, 0.0));
            }
            // Close enough for the basic cast from the wheel's side of the hall.
            let (dx, dz) = (pos.x - me.x, pos.z - me.z);
            let walk = if dx * dx + dz * dz > 20.0 * 20.0 {
                1.0
            } else {
                0.0
            };
            MoveInput::from_intent(0.0, walk, yaw_toward(me, pos), 0)
        } else {
            MoveInput::default()
        };
        run_until(&mut d, 1.0 / 30.0, |_| input, |_| false)?;
    }
    let said = messages(&d);
    let body_down = find(&d, body_kind).first().is_none_or(|b| b.state == 3);
    if !body_down || parts_seen < 3 {
        return fail(format!(
            "the {which} still stands ({parts_seen} parts seen): {said:?}"
        ));
    }
    let wanted: &[&str] = if which == "snare" {
        &["heart is exposed"]
    } else {
        &["plate cracks", "gears scream"]
    };
    for w in wanted {
        if !said.iter().any(|m| m.contains(w)) {
            return fail(format!("never heard \"{w}\": {said:?}"));
        }
    }
    corrections += d.corrections;
    if corrections > 0 {
        return fail(format!("{corrections} prediction corrections"));
    }
    println!(
        "[boss] ok: the {which} fell part by part ({parts_seen} parts); {said:?}; no corrections"
    );
    Ok(())
}
