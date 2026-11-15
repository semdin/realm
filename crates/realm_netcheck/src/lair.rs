//! `realm_netcheck --lair eggs|queen --characters <dir> [--server <caverns>]`:
//! the Web Mother's Lair. Needs the coordinator, spider_caverns and
//! dng_spider_lair (started with `--dev-dungeon-start <step>
//! --dev-dungeon-scale 0.05 --dev-cocoon-solo`) sharing `<dir>`.
//!
//! A level 30 character starts Normal at the camp's web gate and:
//! - eggs: walks into the egg cavern and leaves the sacs be: they must
//!   split open into weavers, which it then clears;
//! - queen: fights the Web Mother: she must spin it into a cocoon (it is
//!   held fast, then freed or hurt when the cocoon holds out) and well up
//!   venom pools, and fall.
//!
//! No prediction correction allowed.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use realm_netclient::ClientCore;
use realm_proto::SigningKey;
use realm_proto::control::{ClientMsg, DungeonMsg, ServerMsg};
use realm_rules::CharacterSheet;
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
    sheet.level = 30;
    sheet.exp = 0;
    sheet.place = Some(realm_rules::Place {
        map: "spider_caverns".to_owned(),
        pos: [-172.0, 1550.6, -164.0],
        yaw: 0.0,
    });
    sheet.revision += 10;
    std::fs::write(&path, serde_json::to_string_pretty(&sheet)?)?;
    Ok(())
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

fn running(s: &mut Session) -> bool {
    s.events.iter().rev().any(|m| match m {
        ServerMsg::Dungeon(d) => matches!(&**d, DungeonMsg::State(v) if v.phase == 2),
        _ => false,
    })
}

fn hazards(s: &Session, kind: &str) -> usize {
    s.events
        .iter()
        .filter(|m| match m {
            ServerMsg::Dungeon(d) => matches!(&**d, DungeonMsg::Hazard(h) if h.kind == kind),
            _ => false,
        })
        .count()
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

/// Walks the `tour` (local x, z) and shoots the nearest creature in sight
/// (not of species `spare`) until `done` holds or `seconds` pass. Notes
/// whether the player was ever held fast.
fn fight(
    d: &mut Session,
    origin: Vec3,
    tour: &[(f32, f32)],
    spare: Option<u16>,
    seconds: u64,
    mut done: impl FnMut(&Session) -> bool,
) -> AnyResult<(bool, bool, Option<String>)> {
    let started = Instant::now();
    // The lowest health each creature showed: one that climbs back far
    // (a boss walking home to heal) is a reset in the middle of the fight.
    let mut lowest: std::collections::HashMap<u32, u8> = std::collections::HashMap::new();
    let mut healed = None;
    let mut next_cast = 0_u32;
    let mut stop = 0;
    let mut held = false;
    while started.elapsed() < Duration::from_secs(seconds) {
        if done(d) {
            return Ok((true, held, healed));
        }
        if d.core.as_ref().is_some_and(ClientCore::locked) {
            held = true;
        }
        let me = d.pos();
        let local_ticks = d.started.elapsed().as_secs_f64() * ClientCore::HZ;
        if let Some(c) = d.core.as_ref() {
            for e in c.remote_entities(local_ticks) {
                if e.kind == 0 || e.state == 3 {
                    continue;
                }
                let low = lowest.entry(e.id).or_insert(e.hp);
                *low = (*low).min(e.hp);
                if e.hp > low.saturating_add(25) && healed.is_none() {
                    healed = Some(format!(
                        "creature {} (kind {}) climbed from {}% to {}%",
                        e.id, e.kind, low, e.hp
                    ));
                }
            }
        }
        let foe = d.core.as_ref().and_then(|c| {
            let eye = me + Vec3::new(0.0, 1.5, 0.0);
            c.remote_entities(local_ticks)
                .into_iter()
                .filter(|e| {
                    e.kind != 0
                        && e.kind & realm_proto::KIND_CHEST != realm_proto::KIND_CHEST
                        && e.state != 3
                        && spare.is_none_or(|k| e.kind & realm_proto::KIND_SPECIES != k)
                })
                .filter(|e| (e.pos - me).length() < 24.0)
                .filter(|e| {
                    c.world()
                        .line_hit(eye, e.pos + Vec3::new(0.0, 1.0, 0.0))
                        .is_none()
                })
                .min_by(|a, b| (a.pos - me).length().total_cmp(&(b.pos - me).length()))
        });
        let tick = d.core.as_ref().map_or(0, ClientCore::tick);
        let input = if let Some(f) = foe {
            if tick >= next_cast {
                next_cast = tick + 18;
                d.action = (1, f.id, f.pos + Vec3::new(0.0, 1.0, 0.0));
            }
            MoveInput::from_intent(0.0, 0.0, yaw_toward(me, f.pos), 0)
        } else {
            let (x, z) = tour[stop];
            let goal = origin + Vec3::new(x, me.y, z);
            if Vec3::new(goal.x - me.x, 0.0, goal.z - me.z).length() < 1.0 {
                stop = (stop + 1) % tour.len();
            }
            MoveInput::from_intent(0.0, 1.0, yaw_toward(me, goal), 0)
        };
        run_until(d, 1.0 / 30.0, |_| input, |_| false)?;
        if d.closed.is_some() {
            return fail(format!("the dungeon connection closed: {:?}", d.closed));
        }
    }
    Ok((false, held, healed))
}

fn said(s: &Session, what: &str) -> bool {
    messages(s).iter().any(|m| m.contains(what))
}

pub fn run(args: &[String]) -> AnyResult<()> {
    let which = arg(args, "--lair", "queen");
    let keys = PathBuf::from(arg(args, "--keys", "keys"));
    let secret: [u8; 32] = std::fs::read(keys.join("ticket.key"))?
        .try_into()
        .map_err(|_| "ticket.key must be 32 bytes")?;
    let key = SigningKey::from_bytes(&secret);
    let content =
        realm_data::Content::load(&PathBuf::from(arg(args, "--content", "content/data")))?;
    let rules = realm_rules::Rules::from_content(&content)?;
    let sac_kind = rules
        .mobs
        .species_order
        .iter()
        .position(|s| s == "egg_sac")
        .map_or(0, |i| i as u16 + 1);
    let dir = PathBuf::from(arg(args, "--characters", "build/laircheck"));
    let caverns = arg(args, "--server", "127.0.0.1:7781");
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let character: u64 =
        arg(args, "--character", &(500_000 + now % 100_000).to_string()).parse()?;
    {
        let mut s = Session::dev(&caverns, "spider_caverns", character, &key, args)?;
        joined(&mut s)?;
    }
    seed(&dir, character)?;
    let mut s = Session::dev(&caverns, "spider_caverns", character, &key, args)?;
    joined(&mut s)?;
    walk(
        &mut s,
        Vec3::new(-174.0, 1550.6, -159.0),
        0.8,
        "the camp's web gate",
    )?;
    s.net.send_control(&ClientMsg::DungeonStart {
        portal: "lair_entry_camp".to_owned(),
        difficulty: 1,
    });
    let mut d = follow(&mut s, args)?;
    let mut corrections = s.corrections;
    drop(s);
    if !run_until(&mut d, 30.0, idle, running)? {
        return fail("the run never started");
    }
    let o = realm_rules::dungeons::copy_offset(d.copy);
    let origin = Vec3::new(o[0], 0.0, o[2]);
    let deaths = |d: &Session| state(d).map_or(0, |v| v.deaths);
    if which == "eggs" {
        for z in [-20.0_f32, -45.0, -60.0] {
            walk(
                &mut d,
                origin + Vec3::new(0.0, 1700.5, z),
                1.2,
                "the egg cavern",
            )?;
        }
        // Fight the sacs' guards and leave the sacs be: they split open
        // in 45 s; then clear the brood until the gate parts.
        let room = [
            (0.0, -62.0),
            (-6.0, -72.0),
            (6.0, -84.0),
            (0.0, -92.0),
            (-6.0, -84.0),
            (6.0, -70.0),
        ];
        let (hatched, _, _) = fight(&mut d, origin, &room, Some(sac_kind), 70, |s| {
            said(s, "egg sac splits")
        })?;
        if !hatched {
            return fail(format!("no egg sac hatched: {:?}", messages(&d)));
        }
        let before = state(&d).map_or(0, |v| v.left);
        let (cleared, _, _) = fight(&mut d, origin, &room, None, 240, |s| {
            said(s, "last sac withers")
        })?;
        if !cleared {
            return fail(format!(
                "the egg cavern was never cleared ({} left): {:?}",
                state(&d).map_or(0, |v| v.left),
                messages(&d)
            ));
        }
        println!(
            "[lair] ok: the egg sacs hatched ({before} standing then), the brood fell, the gate parted"
        );
    } else {
        for z in [-20.0_f32, -60.0, -100.0, -140.0, -162.0] {
            walk(&mut d, origin + Vec3::new(0.0, 1700.5, z), 1.2, "the nest")?;
        }
        let nest = [
            (0.0, -166.0),
            (-8.0, -176.0),
            (8.0, -190.0),
            (0.0, -184.0),
            (-8.0, -190.0),
            (8.0, -176.0),
        ];
        let (down, held, healed) =
            fight(&mut d, origin, &nest, None, 300, |s| said(s, "curls up"))?;
        if !down {
            return fail(format!("the Web Mother still stands: {:?}", messages(&d)));
        }
        for w in ["into a cocoon", "Venom wells up"] {
            if !said(&d, w) {
                return fail(format!("never heard \"{w}\": {:?}", messages(&d)));
            }
        }
        if !held {
            return fail("the cocoon never held the player");
        }
        if let Some(h) = healed {
            return fail(format!("a reset mid-fight: {h}"));
        }
        // The cocoon's hold reached the player's bar of effects with its
        // time (12 s).
        let stun = d.events.iter().find_map(|m| match m {
            ServerMsg::Effects(list) => list.iter().find(|(k, _)| k == "stun").map(|(_, t)| *t),
            _ => None,
        });
        if stun.is_none() {
            return fail("the cocoon's hold never reached the bar of effects");
        }
        let pools = hazards(&d, "pool");
        if pools == 0 {
            return fail("no venom pool welled up");
        }
        println!(
            "[lair] ok: the Web Mother wrapped it in a cocoon, welled up {pools} pools and fell"
        );
    }
    println!("[lair] {:?}", messages(&d));
    if deaths(&d) > 0 {
        return fail(format!("the character died {} times", deaths(&d)));
    }
    corrections += d.corrections;
    if corrections > 0 {
        return fail(format!("{corrections} prediction corrections"));
    }
    println!("[lair] ok ({which}): no corrections");
    Ok(())
}
