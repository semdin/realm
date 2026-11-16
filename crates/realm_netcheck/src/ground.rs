//! `realm_netcheck --ground --server <addr> [--map grounds] [--seconds 20]
//! [--character 900401]`: creatures stand and fight on the ground. One
//! player joins (the server started with `--dev-spawn-at X,Z` beside a
//! building, e.g. `835,910`: the greenhouses), looks at every creature it is
//! sent for two seconds and then provokes the nearest one and runs a loop
//! round the building for `seconds`. Every creature seen must rest on the
//! surface under it, on walkable ground (`NavQuery::on_ground`), never on a
//! roof or a prop; on the move (the provoked one must chase at least 10 m)
//! they must stay on the ground all the way, never above it and never inside
//! the building. Fails on the first creature off the ground; under
//! `seconds` + about 5 s.

use std::collections::HashMap;
use std::path::PathBuf;

use realm_netclient::ClientCore;
use realm_proto::SigningKey;
use realm_sim::Vec3;
use realm_sim::input::MoveInput;
use realm_sim::nav::NavQuery;
use realm_sim::world::World;

use crate::travel::{Session, idle, joined, run_until, yaw_toward};
use crate::{AnyResult, arg};

/// A creature this far over the surface under it is in the air (snapshot
/// heights are quantised; a walker re-finds the ground every third tick).
const HOVER: f32 = 0.6;

pub fn run(args: &[String]) -> AnyResult<()> {
    let keys = PathBuf::from(arg(args, "--keys", "keys"));
    let secret: [u8; 32] = std::fs::read(keys.join("ticket.key"))?
        .try_into()
        .map_err(|_| "ticket.key must be 32 bytes")?;
    let key = SigningKey::from_bytes(&secret);
    let server = arg(args, "--server", "127.0.0.1:7777");
    let map = arg(args, "--map", "grounds");
    let character: u64 = arg(args, "--character", "900401").parse()?;
    let seconds: f32 = arg(args, "--seconds", "20").parse()?;
    let mut s = Session::dev(&server, &map, character, &key, args)?;
    let world = s.pack.world()?;
    let nav = NavQuery::for_world(&s.pack.nav, &world);
    joined(&mut s)?;
    run_until(&mut s, 2.0, idle, |_| false)?;
    let home = s.pos();

    // At rest: every creature in sight.
    let mut seen: HashMap<u32, Vec3> = HashMap::new();
    let mut problem: Option<String> = None;
    run_until(&mut s, 2.0, idle, |s| {
        for e in creatures(s) {
            if let Some(why) = off_ground(&world, &nav, e.pos) {
                problem = Some(format!("creature {} at rest {why} at {:?}", e.id, e.pos));
                return true;
            }
            seen.insert(e.id, e.pos);
        }
        false
    })?;
    if let Some(p) = problem {
        return fail(p);
    }
    if seen.is_empty() {
        return fail("no creature in sight of the spawn");
    }
    println!(
        "[ground] {} creatures in sight of {home:?} all rest on the ground",
        seen.len()
    );

    // The chase: provoke the nearest, then run a square round the building.
    let target = creatures(&s)
        .into_iter()
        .min_by(|a, b| (a.pos - home).length().total_cmp(&(b.pos - home).length()))
        .ok_or("no creature to provoke")?;
    let start = target.pos;
    let loop_points: Vec<Vec3> = [(25.0, 0.0), (25.0, -40.0), (-25.0, -40.0), (-25.0, 0.0)]
        .iter()
        .map(|(dx, dz)| home + Vec3::new(*dx, 0.0, *dz))
        .collect();
    let leg = std::cell::Cell::new(0_usize);
    let mut casts = 0;
    let mut next_cast = 0_u32;
    let mut samples = 0_u32;
    // How far the provoked creature got from where it stood, and how many
    // others walked a few metres (its mates, strollers).
    let mut chase = 0.0_f32;
    let mut problem: Option<String> = None;
    let mut walked: HashMap<u32, Vec3> = HashMap::new();
    run_until(
        &mut s,
        seconds,
        |s| {
            let me = s.pos();
            let goal = loop_points[leg.get()];
            MoveInput::from_intent(0.0, 1.0, yaw_toward(me, goal), 0)
        },
        |s| {
            let me = s.pos();
            let goal = loop_points[leg.get()];
            if Vec3::new(goal.x - me.x, 0.0, goal.z - me.z).length() < 2.0 {
                leg.set((leg.get() + 1) % loop_points.len());
            }
            let tick = s.core.as_ref().map_or(0, ClientCore::tick);
            let all = creatures(s);
            if let Some(t) = all.iter().find(|e| e.id == target.id)
                && casts < 3
                && tick >= next_cast
            {
                next_cast = tick + 20;
                casts += 1;
                s.action = (1, t.id, t.pos + Vec3::new(0.0, 1.0, 0.0));
            }
            if let Some(t) = all.iter().find(|e| e.id == target.id) {
                chase = chase.max(planar(t.pos - start));
                if tick.is_multiple_of(60) {
                    println!(
                        "[ground] creature {} at {:.1?} (state {}, hp {}), player at {:.1?}",
                        t.id, t.pos, t.state, t.hp, me
                    );
                }
            }
            for e in &all {
                samples += 1;
                walked.entry(e.id).or_insert(e.pos);
                if let Some(why) = off_ground(&world, &nav, e.pos) {
                    problem = Some(format!(
                        "creature {} on the move {why} at {:?} (player at {me:?})",
                        e.id, e.pos
                    ));
                    return true;
                }
            }
            s.closed.is_some()
        },
    )?;
    if let Some(p) = problem {
        return fail(p);
    }
    if let Some(why) = &s.closed {
        return fail(format!("the server closed the session: {why}"));
    }
    if chase < 10.0 {
        return fail(format!(
            "creature {} did not chase the player ({casts} casts; {chase:.1} m from {start:?})",
            target.id
        ));
    }
    let moved = all_moved(&s, &walked);
    println!(
        "[ground] ok: creature {} chased the player round the building ({chase:.0} m from where it stood), {moved} creatures walked; {samples} samples over {seconds} s, all on the ground",
        target.id
    );
    Ok(())
}

fn planar(v: Vec3) -> f32 {
    Vec3::new(v.x, 0.0, v.z).length()
}

/// Creatures still in sight that stand over a metre from where first seen.
fn all_moved(s: &Session, first: &HashMap<u32, Vec3>) -> usize {
    creatures(s)
        .iter()
        .filter(|e| first.get(&e.id).is_some_and(|p| planar(e.pos - *p) > 1.0))
        .count()
}

/// Creatures (not players, chests or the dead) the client is sent.
fn creatures(s: &Session) -> Vec<realm_netclient::RemoteEntity> {
    let local = s.started.elapsed().as_secs_f64() * ClientCore::HZ;
    s.core.as_ref().map_or_else(Vec::new, |c| {
        c.remote_entities(local)
            .into_iter()
            .filter(|e| {
                e.kind != 0
                    && e.kind & realm_proto::KIND_CHEST != realm_proto::KIND_CHEST
                    && e.state != 3
            })
            .collect()
    })
}

/// Why a creature at `pos` is not on the ground, if it is not.
fn off_ground(world: &World, nav: &NavQuery, pos: Vec3) -> Option<&'static str> {
    let terrain = world.terrain_at(pos.x, pos.z).map(|t| t.0);
    if terrain.is_some_and(|t| (pos.y - t).abs() < 0.3) {
        // On the terrain; under a roof (the highest surface well over it)
        // it is inside a building.
        if world
            .ground_height(pos.x, pos.z)
            .is_some_and(|top| top - pos.y > 2.0)
        {
            return Some("stands inside a building");
        }
        return None;
    }
    // On something built: the surface under its feet, which must be
    // walkable ground the mesh knows (a floor, a bridge), not a roof or a
    // prop.
    let Some(under) = world
        .ray_down(pos + Vec3::new(0.0, 0.3, 0.0), 0.3 + 80.0)
        .map(|g| g.point.y)
    else {
        return Some("stands over nothing");
    };
    if pos.y - under > HOVER {
        return Some("hovers over the ground");
    }
    if !nav.on_ground(world, Vec3::new(pos.x, under, pos.z)) {
        return Some("stands on no walkable ground (a roof or a prop)");
    }
    None
}

fn fail<T>(what: impl Into<String>) -> AnyResult<T> {
    Err(format!("ground check failed: {}", what.into()).into())
}
