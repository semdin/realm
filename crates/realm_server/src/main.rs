//! realm_server: the map server.
//!
//!   realm_server keygen <keys_dir>
//!       Writes a development ticket signing key (ticket.key / ticket.pub) and
//!       a TLS certificate for the server (tls.crt.der / tls.key.der). The
//!       login service holds ticket.key in production; map servers only read
//!       ticket.pub.
//!   realm_server serve [--map grounds] [--bind 0.0.0.0:7777] [--keys keys]
//!                      [--content content/data] [--maps world/maps]
//!                      [--characters <dir>]
//!                      [--dev-spawn-near-packs | --dev-spawn-near <species>]
//!       Runs one map at 30 Hz and prints a status line every 5 seconds. The
//!       dev options spawn players next to a creature pack (of one species).
//!       `--characters` keeps character records as JSON files there; without
//!       it nothing persists (every join is a new character). Ctrl+C,
//!       SIGTERM or Ctrl+Break saves everyone and stops.
//!   realm_server selfcheck
//!       QUIC loopback check used by CI.

mod game;
mod net;
mod selfcheck;
mod sim;
mod store;

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use realm_data::Content;
use realm_proto::VerifyingKey;

use selfcheck::AnyResult;
use sim::{SECTION_NAMES, Sim};

fn main() {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("the ring crypto provider installs once at start-up");
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("keygen") => keygen(Path::new(args.get(1).map_or("keys", String::as_str))),
        Some("serve") => serve(&args[1..]),
        Some("selfcheck") => tokio::runtime::Runtime::new()
            .map_err(Into::into)
            .and_then(|rt| rt.block_on(selfcheck::run())),
        _ => {
            eprintln!("usage: realm_server keygen <keys_dir> | serve [options] | selfcheck");
            std::process::exit(2);
        }
    };
    if let Err(error) = result {
        eprintln!("realm_server: {error}");
        std::process::exit(1);
    }
}

fn keygen(dir: &Path) -> AnyResult<()> {
    std::fs::create_dir_all(dir)?;
    let key = realm_proto::ticket::generate_key()?;
    std::fs::write(dir.join("ticket.key"), key.to_bytes())?;
    std::fs::write(dir.join("ticket.pub"), key.verifying_key().to_bytes())?;
    let cert =
        rcgen::generate_simple_self_signed(vec!["localhost".to_owned(), "realm-dev".to_owned()])?;
    std::fs::write(dir.join("tls.crt.der"), cert.cert.der())?;
    std::fs::write(dir.join("tls.key.der"), cert.signing_key.serialize_der())?;
    println!(
        "wrote ticket.key, ticket.pub, tls.crt.der, tls.key.der to {}",
        dir.display()
    );
    Ok(())
}

struct Options {
    map: String,
    maps: PathBuf,
    bind: String,
    keys: PathBuf,
    content: PathBuf,
    /// Spawn players next to packs: `Some("")` any pack, `Some(id)` packs
    /// of that species.
    dev_spawn_near: Option<String>,
    characters: Option<PathBuf>,
}

fn options(args: &[String]) -> AnyResult<Options> {
    let mut o = Options {
        map: "grounds".to_owned(),
        maps: PathBuf::from("world/maps"),
        bind: "0.0.0.0:7777".to_owned(),
        keys: PathBuf::from("keys"),
        content: PathBuf::from("content/data"),
        dev_spawn_near: None,
        characters: None,
    };
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        let mut value = || {
            it.next()
                .cloned()
                .ok_or_else(|| format!("{arg} needs a value"))
        };
        match arg.as_str() {
            "--map" => o.map = value()?,
            "--maps" => o.maps = PathBuf::from(value()?),
            "--bind" => o.bind = value()?,
            "--keys" => o.keys = PathBuf::from(value()?),
            "--content" => o.content = PathBuf::from(value()?),
            "--dev-spawn-near-packs" => o.dev_spawn_near = Some(String::new()),
            "--dev-spawn-near" => o.dev_spawn_near = Some(value()?),
            "--characters" => o.characters = Some(PathBuf::from(value()?)),
            other => return Err(format!("unknown option {other}").into()),
        }
    }
    Ok(o)
}

fn serve(args: &[String]) -> AnyResult<()> {
    let o = options(args)?;
    let content = Content::load(&o.content)?;
    let hash_hex = content.hash();
    let mut content_hash = [0_u8; 32];
    for (i, byte) in content_hash.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&hash_hex[i * 2..i * 2 + 2], 16)?;
    }
    let game = game::Game::from_content(&content, &o.map)?;
    let pack = realm_data::maps::read_pack(&o.maps.join(format!("{}.realmmap", o.map)))?;
    let terrain = pack.world()?;
    let nav = realm_sim::nav::NavQuery::new(&pack.nav);
    let stairs = realm_data::staircases(&content, &pack)?;
    let pub_bytes: [u8; 32] = std::fs::read(o.keys.join("ticket.pub"))?
        .try_into()
        .map_err(|_| "ticket.pub must be 32 bytes")?;
    let key = VerifyingKey::from_bytes(&pub_bytes)?;
    let cert = std::fs::read(o.keys.join("tls.crt.der"))?;
    let tls_key = std::fs::read(o.keys.join("tls.key.der"))?;

    let (tx, rx) = crossbeam_channel::unbounded();
    let character_store: Box<dyn store::CharacterStore> = match &o.characters {
        Some(dir) => Box::new(store::FileStore::new(dir.clone())?),
        None => Box::new(store::NoStore),
    };
    let store_jobs = store::start(character_store, tx.clone())?;
    let staircase_count = stairs.flights.len();
    let mut sim = Sim::new(
        game,
        terrain,
        nav,
        stairs,
        content_hash,
        o.dev_spawn_near.as_deref(),
        store_jobs.clone(),
    )?;
    println!(
        "[server] map {} ({} colliders, {} nav polygons, {} staircases), content {}..., {} creatures, listening on {}{}",
        o.map,
        pack.colliders.len(),
        pack.nav.polygons.len(),
        staircase_count,
        &hash_hex[..12],
        sim.creature_count(),
        o.bind,
        match o.dev_spawn_near.as_deref() {
            Some("") => " (dev: players spawn next to packs)".to_owned(),
            Some(id) => format!(" (dev: players spawn next to {id} packs)"),
            None => String::new(),
        }
    );

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .enable_all()
        .build()?;
    let endpoint = {
        let _guard = runtime.enter();
        net::endpoint(&o.bind, cert, tls_key)?
    };
    runtime.spawn(net::accept_loop(endpoint, tx, key));
    let stopping = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    {
        let stopping = stopping.clone();
        runtime.spawn(async move {
            stop_signal().await;
            stopping.store(true, std::sync::atomic::Ordering::Relaxed);
        });
    }

    // The simulation thread: fixed 30 Hz, never waits on the network.
    let period = Duration::from_secs_f64(1.0 / f64::from(realm_sim::SIM_HZ));
    let mut deadline = Instant::now() + period;
    let mut report_at = Instant::now() + Duration::from_secs(5);
    let mut window_start = Instant::now();
    let mut late = 0_u32;
    loop {
        if stopping.load(std::sync::atomic::Ordering::Relaxed) {
            sim.save_all();
            // The store thread finishes the queued saves before the jobs
            // channel closes; wait for it to drain.
            while !store_jobs.is_empty() {
                std::thread::sleep(Duration::from_millis(20));
            }
            std::thread::sleep(Duration::from_millis(100));
            println!("[server] stopped, every character saved");
            return Ok(());
        }
        sim.step(rx.try_iter());
        let now = Instant::now();
        if now >= report_at {
            report(&mut sim, now - window_start, late);
            window_start = now;
            report_at = now + Duration::from_secs(5);
            late = 0;
        }
        if now < deadline {
            std::thread::sleep(deadline - now);
            deadline += period;
        } else {
            late += 1;
            // Never try to catch up a backlog: start a fresh schedule.
            deadline = now + period;
        }
    }
}

/// Resolves when the server is asked to stop: Ctrl+C anywhere, SIGTERM on
/// Linux (systemd), Ctrl+Break on Windows.
async fn stop_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        if let Ok(mut term) = signal(SignalKind::terminate()) {
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {}
                _ = term.recv() => {}
            }
            return;
        }
    }
    #[cfg(windows)]
    {
        if let Ok(mut brk) = tokio::signal::windows::ctrl_break() {
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {}
                _ = brk.recv() => {}
            }
            return;
        }
    }
    let _ = tokio::signal::ctrl_c().await;
}

fn report(sim: &mut Sim, window: Duration, late: u32) {
    let (tick, players, creatures) = (sim.tick, sim.player_count(), sim.creature_count());
    let stats = &mut sim.stats;
    let mut ticks = std::mem::take(&mut stats.ticks);
    if ticks.is_empty() {
        return;
    }
    ticks.sort_by(f32::total_cmp);
    let pick = |q: f32| ticks[((ticks.len() - 1) as f32 * q) as usize];
    let n = ticks.len() as f64;
    let sections: Vec<String> = SECTION_NAMES
        .iter()
        .zip(stats.sections.iter())
        .map(|(name, ms)| format!("{name}={:.2}", ms / n))
        .collect();
    let seconds = window.as_secs_f64();
    let per_client = if players > 0 {
        stats.bytes_out as f64 / seconds / players as f64 / 1024.0
    } else {
        0.0
    };
    println!(
        "[tick {}] players={} creatures={} awake={} think/s={:.0} | casts/s={:.0} hits/s={:.0} kills={} deaths={} refused={:?} paths/s={:.0} ({:.2} ms/tick) ground {:.2} ms/tick | fallen={} (last stood at {:?}) roamed={:.0}m | tick ms p50={:.2} p99={:.2} max={:.2} late={} | {} | out {:.2} KB/s per player, {:.1} snapshots/s per player",
        tick,
        players,
        creatures,
        stats.awake_mobs,
        stats.thinking_mobs as f64 / seconds,
        stats.casts as f64 / seconds,
        stats.hits as f64 / seconds,
        stats.kills,
        stats.player_deaths,
        stats.refused,
        stats.paths as f64 / seconds,
        stats.path_ms / n,
        stats.ground_ms / n,
        stats.fallen,
        stats
            .fell_at
            .map(|p| (p.x.round(), p.y.round(), p.z.round())),
        stats.roamed,
        pick(0.5),
        pick(0.99),
        pick(1.0),
        late,
        sections.join(" "),
        per_client,
        if players > 0 {
            stats.snapshots as f64 / seconds / players as f64
        } else {
            0.0
        },
    );
    stats.sections = [0.0; 5];
    stats.bytes_out = 0;
    stats.snapshots = 0;
    stats.thinking_mobs = 0;
    stats.casts = 0;
    stats.hits = 0;
    stats.kills = 0;
    stats.player_deaths = 0;
    stats.refused = [0; 3];
    stats.paths = 0;
    stats.path_ms = 0.0;
    stats.ground_ms = 0.0;
    stats.fallen = 0;
    stats.fell_at = None;
    stats.roamed = 0.0;
}
