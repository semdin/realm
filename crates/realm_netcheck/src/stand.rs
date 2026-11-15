//! `realm_netcheck --stand --server <addr> [--map grounds] [--seconds 10]
//! [--character 900301]`: one player joins (the server started with
//! `--dev-spawn-at X,Z` puts it on the spot to test), settles for a second
//! and then stands still with no input. Its predicted body must not move at
//! all and the server must never correct it; fails on the first tick it
//! drifts. Under `seconds` + a few seconds.

use std::path::PathBuf;

use realm_proto::SigningKey;
use realm_sim::Vec3;

use crate::travel::{Session, idle, joined, run_until};
use crate::{AnyResult, arg};

pub fn run(args: &[String]) -> AnyResult<()> {
    let keys = PathBuf::from(arg(args, "--keys", "keys"));
    let secret: [u8; 32] = std::fs::read(keys.join("ticket.key"))?
        .try_into()
        .map_err(|_| "ticket.key must be 32 bytes")?;
    let key = SigningKey::from_bytes(&secret);
    let server = arg(args, "--server", "127.0.0.1:7777");
    let map = arg(args, "--map", "grounds");
    let character: u64 = arg(args, "--character", "900301").parse()?;
    let seconds: f32 = arg(args, "--seconds", "10").parse()?;
    let mut s = Session::dev(&server, &map, character, &key, args)?;
    joined(&mut s)?;
    // Landing from the spawn height takes a few ticks.
    run_until(&mut s, 1.0, idle, |_| false)?;
    let start = s.pos();
    let origin = map_origin(&s, &map);
    println!(
        "[stand] {map} at {:.0}, {:.0} (world {start:?}), on the floor {}",
        start.x - origin.0,
        start.z - origin.1,
        s.body().is_some_and(|b| b.on_floor)
    );
    let before = s.corrections;
    let mut moved: Option<Vec3> = None;
    run_until(&mut s, seconds, idle, |s| {
        let at = s.pos();
        if at != start || s.corrections != before || s.closed.is_some() {
            moved = Some(at);
            return true;
        }
        false
    })?;
    if let Some(why) = &s.closed {
        return fail(format!("{map} closed the session: {why}"));
    }
    if s.corrections != before {
        return fail(format!(
            "{} corrections standing still",
            s.corrections - before
        ));
    }
    if let Some(at) = moved {
        return fail(format!(
            "the body drifted standing still: {start:?} -> {at:?} after {:.1} s",
            s.started.elapsed().as_secs_f64()
        ));
    }
    println!(
        "[stand] ok: stood {seconds} s at {start:?}, no drift, no corrections, {} inputs replayed",
        s.core.as_ref().map_or(0, |c| c.stats.replayed)
    );
    Ok(())
}

fn fail<T>(what: impl Into<String>) -> AnyResult<T> {
    Err(format!("stand check failed: {}", what.into()).into())
}

/// The world point the map shows as 0, 0 (maps.json coord_origin).
fn map_origin(s: &Session, map: &str) -> (f32, f32) {
    let origin = s
        .content
        .file("maps.json")
        .map(|m| m["maps"][map]["coord_origin"].clone())
        .unwrap_or_default();
    (
        origin[0].as_f64().unwrap_or(0.0) as f32,
        origin[1].as_f64().unwrap_or(0.0) as f32,
    )
}
