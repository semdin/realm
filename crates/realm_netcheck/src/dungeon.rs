//! `realm_netcheck --dungeon --characters <dir> [--server 127.0.0.1:7777]`:
//! a solo run of the Trial Hall. Needs the coordinator, the grounds and
//! dng_trial map servers sharing the character store `<dir>`, and the
//! dungeon server started with `--dev-dungeon-scale 0.05` (the run's
//! creatures one hit each, so a level 12 character clears it in minutes).
//!
//! A new character joins and leaves; its record is raised to level 12 at the
//! Trial Hall gate. Then it must:
//! 1. ask the gate: alone, nothing in its way, Normal open and Hard locked;
//! 2. start Normal: launched at once (alone), carried into a copy, gather,
//!    count down, the start gate opens;
//! 3. clear the hall: each gate opens behind the creatures it kept, the
//!    Warden falls, the run completes with a medal rank recorded;
//! 4. be paid: experience and oril, and its own chest at the end (Dungeon
//!    Seals in it);
//! 5. leave by the reward exit back onto the grounds, where the gate now
//!    shows Hard open.
//!
//! The prediction must never be corrected (gates included).
//!
//! `--quick` (about 40 s, for working on dungeons): the gate, the launch, the
//! countdown, the first wave down and the second gate opening behind it, then
//! out by the plain exit back onto the grounds.

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

const PORTAL: &str = "trial_entry";

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
    sheet.level = 12;
    sheet.exp = 0;
    let rules = Rules::from_content(&Content::load(&PathBuf::from("content/data"))?)?;
    realm_rules::items::add_item(&mut sheet, rules.new_item("dungeon_seal", 20), &rules)?;
    sheet.place = Some(realm_rules::Place {
        map: "grounds".to_owned(),
        pos: [70.0, 58.3, 63.0],
        yaw: 0.0,
    });
    sheet.revision += 10;
    std::fs::write(&path, serde_json::to_string_pretty(&sheet)?)?;
    Ok(())
}

/// The gate's answer for this session.
fn ask(s: &mut Session) -> AnyResult<(Vec<bool>, String)> {
    s.net
        .send_control(&ClientMsg::DungeonInfo(PORTAL.to_owned()));
    let mut info = None;
    run_until(s, 5.0, idle, |s| {
        info = s
            .take(|m| matches!(m, ServerMsg::Dungeon(d) if matches!(**d, DungeonMsg::Info { .. })));
        info.is_some()
    })?;
    let Some(ServerMsg::Dungeon(d)) = info else {
        return fail("the gate never answered");
    };
    let DungeonMsg::Info { members, .. } = *d else {
        return fail("the gate never answered");
    };
    let me = members.first().cloned().unwrap_or_default();
    Ok((me.unlocked, me.status))
}

/// The newest run view heard.
fn state(s: &Session) -> Option<realm_proto::control::RunView> {
    s.events.iter().rev().find_map(|m| match m {
        ServerMsg::Dungeon(d) => match &**d {
            DungeonMsg::State(v) => Some(v.clone()),
            _ => None,
        },
        _ => None,
    })
}

pub fn run(args: &[String]) -> AnyResult<()> {
    let keys = PathBuf::from(arg(args, "--keys", "keys"));
    let secret: [u8; 32] = std::fs::read(keys.join("ticket.key"))?
        .try_into()
        .map_err(|_| "ticket.key must be 32 bytes")?;
    let key = SigningKey::from_bytes(&secret);
    let content = Content::load(&PathBuf::from(arg(args, "--content", "content/data")))?;
    let rules = Rules::from_content(&content)?;
    let dir = PathBuf::from(arg(args, "--characters", "build/dungeoncheck"));
    let grounds = arg(args, "--server", "127.0.0.1:7777");
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let character: u64 =
        arg(args, "--character", &(700_000 + now % 100_000).to_string()).parse()?;
    let quick = args.iter().any(|a| a == "--quick");
    let mut corrections = 0;
    {
        let mut s = Session::dev(&grounds, "grounds", character, &key, args)?;
        joined(&mut s)?;
    }
    seed(&dir, character)?;
    let mut s = Session::dev(&grounds, "grounds", character, &key, args)?;
    joined(&mut s)?;

    // 1. The gate.
    let portal = rules
        .travel
        .portals
        .iter()
        .find(|p| p.id == PORTAL)
        .cloned()
        .ok_or("no trial gate")?;
    walk(
        &mut s,
        Vec3::new(portal.center[0], portal.center[1], portal.center[2]),
        1.2,
        "the Trial Hall gate",
    )?;
    let (unlocked, status) = ask(&mut s)?;
    if !status.is_empty() || unlocked.get(1) != Some(&true) || unlocked.get(2) != Some(&false) {
        return fail(format!(
            "the gate says status '{status}', unlocked {unlocked:?}"
        ));
    }
    println!("[dungeon] 1 ok: the gate lets it in, Normal open, Hard locked");
    // The seal shop at the gate: a Trial key for its seals.
    let price = rules.dungeons.rewards.shop.first().map_or(0, |r| r.2);
    let revision = s.sheet.as_ref().map_or(0, |x| x.revision);
    s.net.send_control(&ClientMsg::Item {
        op_id: 501,
        revision,
        op: realm_rules::ItemOp::SealBuy { index: 0 },
    });
    let mut answer = None;
    run_until(&mut s, 5.0, idle, |s| {
        answer = s.take(|m| matches!(m, ServerMsg::ItemResult { op_id: 501, .. }));
        answer.is_some()
    })?;
    run_until(&mut s, 0.5, idle, |_| false)?;
    if !matches!(&answer, Some(ServerMsg::ItemResult { ok: true, .. }))
        || s.count("key_trial") != 1
        || s.count("dungeon_seal") != 20 - price
    {
        return fail(format!(
            "the seal shop: {answer:?}, keys {}, seals {}",
            s.count("key_trial"),
            s.count("dungeon_seal")
        ));
    }
    println!("[dungeon] 1b ok: a Trial key for {price} seals at the gate");

    // 2. Start Normal.
    s.net.send_control(&ClientMsg::DungeonStart {
        portal: PORTAL.to_owned(),
        difficulty: 1,
    });
    let before = s.sheet.clone().unwrap_or_default();
    let mut d = follow(&mut s, args)?;
    corrections += s.corrections;
    drop(s);
    if d.copy == 0 {
        return fail("joined the dungeon map outside any copy");
    }
    if !run_until(&mut d, 30.0, idle, |s| {
        state(s).is_some_and(|v| v.phase == 2)
    })? {
        return fail(format!("the run never started: {:?}", state(&d)));
    }
    let o = realm_rules::dungeons::copy_offset(d.copy);
    let origin = Vec3::new(o[0], 0.0, o[2]);
    println!(
        "[dungeon] 2 ok: launched alone into copy {}, gathered, counted down, started",
        d.copy
    );

    // 3. Clear it: a tour of the Trial Hall (the corridor, both side rooms
    // through their doors, the hall and both ossuaries, the arena), shooting
    // whatever it can see at each stop; again until the run is complete.
    let def = rules.dungeons.dungeons["trial"].clone();
    let tour: [(f32, f32); 22] = [
        (0.0, -8.0),
        (0.0, -24.0),
        (-9.0, -24.0),
        (-15.0, -24.0),
        (-9.0, -24.0),
        (9.0, -24.0),
        (15.0, -24.0),
        (9.0, -24.0),
        (0.0, -30.0),
        (0.0, -42.0),
        (0.0, -58.0),
        (-16.0, -58.0),
        (-25.0, -58.0),
        (-16.0, -58.0),
        (16.0, -58.0),
        (25.0, -58.0),
        (16.0, -58.0),
        (0.0, -72.0),
        (0.0, -88.0),
        (0.0, -104.0),
        (0.0, -118.0),
        (0.0, -132.0),
    ];
    let mut stop = 0;
    let mut next_cast = 0_u32;
    let started = Instant::now();
    let mut casts = 0_u32;
    let mut last_fixes = 0;
    while started.elapsed() < Duration::from_secs(900) {
        let view = state(&d);
        if view.as_ref().is_some_and(|v| v.complete) {
            break;
        }
        let tick_now = d.core.as_ref().map_or(0, ClientCore::tick);
        if quick
            && d.core
                .as_ref()
                .is_some_and(|c| c.gate_open("gate_h", tick_now))
        {
            break;
        }
        let me = d.pos();
        let local_ticks = d.started.elapsed().as_secs_f64() * ClientCore::HZ;
        let visible = d.core.as_ref().and_then(|c| {
            let eye = me + Vec3::new(0.0, 1.5, 0.0);
            c.remote_entities(local_ticks)
                .into_iter()
                .filter(|e| {
                    e.kind != 0
                        && e.kind & realm_proto::KIND_CHEST != realm_proto::KIND_CHEST
                        && e.state != 3
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
        let input = if let Some(f) = visible {
            if tick >= next_cast {
                next_cast = tick + 18;
                casts += 1;
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
        let fixes = d.core.as_ref().map_or(0, |c| c.stats.corrections);
        if fixes != last_fixes {
            let c = d.core.as_ref().map(|c| c.stats).unwrap_or_default();
            println!(
                "[dungeon] correction #{fixes} at local ({:.2}, {:.2}, {:.2}), {:.3} m (max {:.3}), sees {:?}",
                me.x - origin.x,
                me.y,
                me.z - origin.z,
                c.max_correction,
                c.max_correction,
                visible.map(|f| (f.kind, f.pos - me))
            );
            last_fixes = fixes;
        }
        if tick.is_multiple_of(450) {
            println!(
                "[dungeon] stop {stop} at local ({:.1}, {:.1}), step {}, forces {}/{}",
                me.x - origin.x,
                me.z - origin.z,
                view.as_ref().map_or("", |v| v.step.as_str()),
                view.as_ref().map_or(0, |v| v.forces),
                view.as_ref().map_or(0, |v| v.forces_total)
            );
        }
        run_until(&mut d, 1.0 / 30.0, |_| input, |_| false)?;
        if d.closed.is_some() {
            return fail(format!("the dungeon connection closed: {:?}", d.closed));
        }
    }
    if quick {
        return quick_out(d, origin, &rules, args, corrections);
    }
    let Some(view) = state(&d) else {
        return fail("no run state");
    };
    let result = view.result.clone().unwrap_or_default();
    if !view.complete || result.timeout || result.clear < 1000 {
        // Where the creatures still standing are (local x, y, z).
        let local_ticks = d.started.elapsed().as_secs_f64() * ClientCore::HZ;
        let standing: Vec<(i32, i32, i32)> = d.core.as_ref().map_or(Vec::new(), |c| {
            c.remote_entities(local_ticks)
                .into_iter()
                .filter(|e| {
                    e.kind != 0
                        && e.kind & realm_proto::KIND_CHEST != realm_proto::KIND_CHEST
                        && e.state != 3
                })
                .map(|e| {
                    (
                        (e.pos.x - origin.x) as i32,
                        e.pos.y as i32,
                        (e.pos.z - origin.z) as i32,
                    )
                })
                .collect()
        });
        println!("[dungeon] still standing: {standing:?}");
        return fail(format!(
            "the run did not finish clean after {casts} casts: step {}, {} / {} forces, result {result:?}, left {}",
            view.step, view.forces, view.forces_total, view.left
        ));
    }
    println!(
        "[dungeon] 3 ok: cleared in {:.0} s (par {:.0}), rank {}, {casts} casts, deaths {}",
        f64::from(result.time_ms) / 1000.0,
        view.par_s,
        result.rank,
        result.deaths
    );

    // 4. The rewards and the chest.
    let mut rewards = None;
    run_until(&mut d, 3.0, idle, |s| {
        rewards = s
            .events
            .iter()
            .find(
                |m| matches!(m, ServerMsg::Dungeon(d) if matches!(**d, DungeonMsg::Rewards { .. })),
            )
            .cloned();
        rewards.is_some()
    })?;
    let Some(ServerMsg::Dungeon(paid)) = rewards else {
        return fail("no rewards");
    };
    let DungeonMsg::Rewards {
        helper,
        exp,
        oril,
        items,
        ..
    } = *paid
    else {
        return fail("no rewards");
    };
    if helper || exp == 0 || oril == 0 || !items.iter().any(|i| i.0 == "dungeon_seal") {
        return fail(format!(
            "rewards: helper {helper}, exp {exp}, oril {oril}, items {items:?}"
        ));
    }
    let chest_local = def
        .steps
        .iter()
        .find_map(|s| s.chest.as_ref().map(|c| c.1))
        .unwrap_or([0.0, 1000.5, -128.0]);
    let chest_at = origin + Vec3::new(chest_local[0], chest_local[1], chest_local[2]);
    walk(&mut d, chest_at, 2.5, "the chest")?;
    let local_ticks = d.started.elapsed().as_secs_f64() * ClientCore::HZ;
    let chest = d.core.as_ref().and_then(|c| {
        c.remote_entities(local_ticks)
            .into_iter()
            .filter(|e| e.kind & realm_proto::KIND_CHEST == realm_proto::KIND_CHEST)
            .min_by(|a, b| {
                (a.pos - chest_at)
                    .length()
                    .total_cmp(&(b.pos - chest_at).length())
            })
            .map(|e| e.id)
    });
    let Some(chest) = chest else {
        return fail("no chest at the end");
    };
    d.net
        .send_control(&ClientMsg::TakeLoot { chest, slot: None });
    if !run_until(&mut d, 5.0, idle, |s| {
        s.count("dungeon_seal") > before_count(&before)
    })? {
        return fail("the chest's seals never reached the bag");
    }
    let record = d
        .sheet
        .as_ref()
        .map(|s| (s.dungeons.rank("trial", 1), s.dungeons.best_ms("trial", 1)))
        .unwrap_or_default();
    if record.0.is_none() || record.1 == 0 {
        return fail(format!("no clear recorded: {record:?}"));
    }
    println!(
        "[dungeon] 4 ok: +{exp} exp, +{oril} oril, the chest's {} items taken, clear recorded {record:?}",
        items.len()
    );

    // With --replay: another run from the finished copy (the result
    // window's "run it again") instead of going out: a fresh copy on the
    // same map, the run gathering there.
    if args.iter().any(|a| a == "--replay") {
        let old_copy = d.copy;
        // The gate's rule: nobody fighting in the last 5 s.
        run_until(&mut d, 6.0, idle, |_| false)?;
        d.events.clear();
        d.net.send_control(&ClientMsg::DungeonStart {
            portal: PORTAL.to_owned(),
            difficulty: 1,
        });
        let mut again = match follow(&mut d, args) {
            Ok(s) => s,
            Err(e) => {
                let refused: Vec<String> = d
                    .events
                    .iter()
                    .filter_map(|m| match m {
                        ServerMsg::Dungeon(x) => match &**x {
                            DungeonMsg::Refused { reason, who, .. } => {
                                Some(format!("{reason} {who}"))
                            }
                            _ => None,
                        },
                        _ => None,
                    })
                    .collect();
                return fail(format!("the replay never left: {e}; refused {refused:?}"));
            }
        };
        corrections += d.corrections;
        drop(d);
        if again.copy == 0 || again.copy == old_copy {
            return fail(format!(
                "the replay landed in copy {} (was {old_copy})",
                again.copy
            ));
        }
        if !run_until(&mut again, 15.0, idle, |s| {
            state(s).is_some_and(|v| v.phase <= 2 && v.forces == 0 && !v.complete)
        })? {
            return fail(format!("no fresh run in copy {}", again.copy));
        }
        corrections += again.corrections;
        if corrections > 0 {
            return fail(format!("{corrections} prediction corrections"));
        }
        println!(
            "[dungeon] ok (replay): from the finished copy {old_copy} into a fresh copy {} on the same map; no corrections",
            again.copy
        );
        return Ok(());
    }

    // 5. Out by the reward exit; Hard is open now.
    let exit = rules
        .travel
        .portals
        .iter()
        .find(|p| p.id == "trial_reward_exit")
        .cloned()
        .ok_or("no reward exit")?;
    walk(
        &mut d,
        origin + Vec3::new(exit.center[0], exit.center[1], exit.center[2]),
        1.0,
        "the reward exit",
    )?;
    d.net
        .send_control(&ClientMsg::Door("trial_reward_exit".to_owned()));
    let mut back = follow(&mut d, args)?;
    corrections += d.corrections;
    drop(d);
    walk(
        &mut back,
        Vec3::new(portal.center[0], portal.center[1], portal.center[2]),
        1.2,
        "the gate again",
    )?;
    let (unlocked, _) = ask(&mut back)?;
    corrections += back.corrections;
    if unlocked.get(2) != Some(&true) {
        return fail(format!("Hard did not open: {unlocked:?}"));
    }
    println!("[dungeon] 5 ok: out by the reward exit, Hard now open");

    // 6. The guide: the clear, the week's board, the record title.
    back.net.send_control(&ClientMsg::DungeonGuide);
    let mut guide = None;
    run_until(&mut back, 5.0, idle, |s| {
        guide = s.take(
            |m| matches!(m, ServerMsg::Dungeon(x) if matches!(**x, DungeonMsg::Guide { .. })),
        );
        guide.is_some()
    })?;
    let Some(ServerMsg::Dungeon(page)) = guide else {
        return fail("the guide never answered");
    };
    let DungeonMsg::Guide {
        records,
        boards,
        titles,
        ..
    } = *page
    else {
        return fail("the guide never answered");
    };
    let cleared = records
        .iter()
        .any(|r| r.0 == "trial" && r.1 == 1 && r.2 >= 0 && r.3 > 0);
    let on_board = boards
        .iter()
        .any(|b| b.dungeon == "trial" && b.difficulty == 1 && !b.runs.is_empty());
    if !cleared || !on_board || !titles.iter().any(|t| t == "dungeon_record") {
        return fail(format!(
            "the guide: cleared {cleared}, on the board {on_board}, titles {titles:?}"
        ));
    }
    println!(
        "[dungeon] 6 ok: the guide shows the clear, the week's board and the Record Breaker title"
    );
    if corrections > 0 {
        return fail(format!("{corrections} prediction corrections"));
    }
    println!("[dungeon] ok: gate, launch, a full run, rewards, chest, record, out; no corrections");
    Ok(())
}

fn before_count(sheet: &CharacterSheet) -> u32 {
    realm_rules::items::count_items(sheet, "dungeon_seal")
}

/// `--quick`: the second gate stands open; the wave paid; out by the plain
/// exit (its door back onto the grounds).
fn quick_out(
    mut d: Session,
    origin: Vec3,
    rules: &Rules,
    args: &[String],
    corrections: u64,
) -> AnyResult<()> {
    let tick = d.core.as_ref().map_or(0, ClientCore::tick);
    if !d.core.as_ref().is_some_and(|c| c.gate_open("gate_h", tick)) {
        return fail(format!("the second gate never opened: {:?}", state(&d)));
    }
    let view = state(&d).unwrap_or_default();
    let exp = d.sheet.as_ref().map_or(0, |s| s.exp);
    if view.forces == 0 || exp == 0 {
        return fail(format!(
            "no forces ({}) or no kill experience ({exp})",
            view.forces
        ));
    }
    println!(
        "[dungeon] 3 ok (quick): the first wave down, {} / {} forces, {exp} exp, gate_h open",
        view.forces, view.forces_total
    );
    // Curses (a server run with --dev-dungeon-affixes): their marks.
    let marks: Vec<String> = d
        .events
        .iter()
        .filter_map(|m| match m {
            ServerMsg::Dungeon(x) => match &**x {
                DungeonMsg::Hazard(h) => Some(h.kind.clone()),
                _ => None,
            },
            _ => None,
        })
        .collect();
    if !view.affixes.is_empty() {
        println!(
            "[dungeon] curses {:?}: {} marks {:?}",
            view.affixes,
            marks.len(),
            marks
        );
        if view.affixes.iter().any(|a| a == "burst") && !marks.iter().any(|k| k == "burst") {
            return fail("the bursting dead left no ring");
        }
    }
    let exit = rules
        .travel
        .portals
        .iter()
        .find(|p| p.id == "trial_exit")
        .cloned()
        .ok_or("no trial exit")?;
    walk(
        &mut d,
        origin + Vec3::new(0.0, 1000.5, -8.0),
        1.0,
        "the entry hall",
    )?;
    walk(
        &mut d,
        origin + Vec3::new(exit.center[0], exit.center[1], exit.center[2]),
        1.0,
        "the exit",
    )?;
    d.net
        .send_control(&ClientMsg::Door("trial_exit".to_owned()));
    let mut back = follow(&mut d, args)?;
    let corrections = corrections + d.corrections;
    drop(d);
    run_until(&mut back, 0.5, idle, |_| false)?;
    let corrections = corrections + back.corrections;
    if corrections > 0 {
        return fail(format!("{corrections} prediction corrections"));
    }
    println!(
        "[dungeon] ok (quick): gate, launch, countdown, first wave, gate_h, out; no corrections"
    );
    Ok(())
}
