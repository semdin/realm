//! realm_server: the map server.
//!
//!   realm_server keygen <keys_dir>
//!       Writes a development ticket signing key (ticket.key / ticket.pub) and
//!       a TLS certificate for the server (tls.crt.der / tls.key.der). The
//!       login service holds ticket.key in production; map servers only read
//!       ticket.pub.
//!   realm_server serve [--map grounds] [--bind 0.0.0.0:7777] [--keys keys]
//!                      [--content content/data] [--maps world/maps]
//!                      [--characters <dir> | --persist <addr>] [--coord <addr>] [--public <addr>]
//!                      [--dev-spawn-near-packs | --dev-spawn-near <species>]
//!       Runs one map at 30 Hz and prints a status line every 5 seconds
//!       (its numbers also go to the coordinator's metrics when linked). The
//!       dev options spawn players next to a creature pack (of one species).
//!       `--characters` keeps character records as JSON files there,
//!       `--persist` in the persistence service (realm_persist); without
//!       it nothing persists (every join is a new character). Ctrl+C,
//!       SIGTERM or Ctrl+Break saves everyone and stops. `--coord` links
//!       it to the coordinator (travel, chat and parties across maps);
//!       `--public` is the address clients reach it at (default: the bind
//!       address, 0.0.0.0 read as 127.0.0.1). `--dev-dungeon-scale F`
//!       (checks only) multiplies dungeon creatures' health and damage;
//!       `--dev-dungeon-affixes a,b` gives every run those curses;
//!       `--dev-dungeon-start <step>` starts every run at that step;
//!       `--dev-cocoon-solo` lets the Web Mother's cocoon wrap a lone player;
//!       `--dev-fail-saves <file>` makes every save fail while that file
//!       exists (with `--characters`); `--dev-ga Name,Name` makes those
//!       characters GAs on a map without a coordinator; `--dev-boss-respawn S`
//!       raises the map's world bosses S seconds after boot (not at boot).
//!   realm_server selfcheck
//!       QUIC loopback check used by CI.

mod coord;
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

/// A private key file: readable by its owner only (Unix 0600) from the
/// moment it exists, whatever the umask; the public halves stay 0644.
fn write_secret(path: &Path, bytes: &[u8]) -> AnyResult<()> {
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        options.mode(0o600);
        // An existing file keeps its mode through open(); set it as well.
        if path.exists() {
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        }
    }
    options.open(path)?.write_all(bytes)?;
    Ok(())
}

fn keygen(dir: &Path) -> AnyResult<()> {
    std::fs::create_dir_all(dir)?;
    let key = realm_proto::ticket::generate_key()?;
    write_secret(&dir.join("ticket.key"), &key.to_bytes())?;
    std::fs::write(dir.join("ticket.pub"), key.verifying_key().to_bytes())?;
    let cert =
        rcgen::generate_simple_self_signed(vec!["localhost".to_owned(), "realm-dev".to_owned()])?;
    std::fs::write(dir.join("tls.crt.der"), cert.cert.der())?;
    write_secret(&dir.join("tls.key.der"), &cert.signing_key.serialize_der())?;
    // The key map servers prove to the coordinator.
    let mut coord = [0_u8; 32];
    getrandom::fill(&mut coord).map_err(|e| format!("random: {e}"))?;
    write_secret(&dir.join("coord.key"), &coord)?;
    println!(
        "wrote ticket.key, ticket.pub, tls.crt.der, tls.key.der, coord.key to {}",
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
    /// The persistence service (realm_persist) instead of character files.
    persist: Option<String>,
    /// The coordinator's address (None: run alone).
    coord: Option<String>,
    /// Where clients reach this server (told to travellers).
    public: Option<String>,
    /// Development: dungeon creatures' health and damage x this.
    dev_dungeon_scale: f32,
    /// Development: every run's curses.
    dev_dungeon_affixes: Option<Vec<String>>,
    /// Development: a run starts at this step.
    dev_dungeon_start: Option<String>,
    /// Development: the cocoon wraps a lone player too.
    dev_cocoon_solo: bool,
    /// Development: saves fail while this file exists.
    dev_fail_saves: Option<PathBuf>,
    /// Development: GAs of a map without a coordinator.
    dev_ga: Vec<String>,
    /// Development: world bosses rise this many seconds after boot.
    dev_boss_respawn: Option<u32>,
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
        persist: None,
        coord: None,
        public: None,
        dev_dungeon_scale: 1.0,
        dev_dungeon_affixes: None,
        dev_dungeon_start: None,
        dev_cocoon_solo: false,
        dev_fail_saves: None,
        dev_ga: Vec::new(),
        dev_boss_respawn: None,
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
            "--persist" => o.persist = Some(value()?),
            "--coord" => o.coord = Some(value()?),
            "--public" => o.public = Some(value()?),
            "--dev-dungeon-scale" => o.dev_dungeon_scale = value()?.parse()?,
            "--dev-dungeon-start" => o.dev_dungeon_start = Some(value()?),
            "--dev-cocoon-solo" => o.dev_cocoon_solo = true,
            "--dev-fail-saves" => o.dev_fail_saves = Some(PathBuf::from(value()?)),
            "--dev-boss-respawn" => o.dev_boss_respawn = Some(value()?.parse()?),
            "--dev-ga" => {
                o.dev_ga = value()?
                    .split(',')
                    .map(|n| n.trim().to_lowercase())
                    .filter(|n| !n.is_empty())
                    .collect();
            }
            "--dev-dungeon-affixes" => {
                o.dev_dungeon_affixes = Some(
                    value()?
                        .split(',')
                        .filter(|s| !s.is_empty())
                        .map(str::to_owned)
                        .collect(),
                );
            }
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
    // A dungeon map holds its copies side by side.
    let instanced = content
        .file("maps.json")
        .and_then(|m| m["maps"][o.map.as_str()]["instanced"].as_bool())
        .unwrap_or(false);
    let offsets: Vec<realm_sim::Vec3> = (1..=realm_rules::dungeons::COPIES)
        .map(|c| {
            let o = realm_rules::dungeons::copy_offset(c);
            realm_sim::Vec3::new(o[0], o[1], o[2])
        })
        .collect();
    let (terrain, nav) = if instanced {
        (
            pack.world_copies(&offsets)?,
            realm_sim::nav::NavQuery::new(&pack.nav_copies(&offsets)),
        )
    } else {
        (pack.world()?, realm_sim::nav::NavQuery::new(&pack.nav))
    };
    let stairs = realm_data::staircases(&content, &pack)?;
    let pub_bytes: [u8; 32] = std::fs::read(o.keys.join("ticket.pub"))?
        .try_into()
        .map_err(|_| "ticket.pub must be 32 bytes")?;
    let key = VerifyingKey::from_bytes(&pub_bytes)?;
    let cert = std::fs::read(o.keys.join("tls.crt.der"))?;
    let tls_key = std::fs::read(o.keys.join("tls.key.der"))?;

    let (tx, rx) = crossbeam_channel::unbounded();
    let character_store: Box<dyn store::CharacterStore> = if let Some(addr) = &o.persist {
        let key: [u8; 32] = std::fs::read(o.keys.join("coord.key"))?
            .try_into()
            .map_err(|_| "coord.key must be 32 bytes")?;
        println!("[store] characters in the persistence service at {addr}");
        Box::new(store::PersistStore::new(addr.clone(), key))
    } else {
        match &o.characters {
            Some(dir) => match &o.dev_fail_saves {
                Some(flag) => Box::new(store::FlakyStore {
                    inner: store::FileStore::new(dir.clone())?,
                    flag: flag.clone(),
                }),
                None => Box::new(store::FileStore::new(dir.clone())?),
            },
            None => Box::new(store::NoStore),
        }
    };
    let store_jobs = store::start(character_store, tx.clone())?;
    let staircase_count = stairs.flights.len();
    let gates = if instanced {
        Some(pack.gates(&offsets)?)
    } else {
        None
    };
    let mut sim = Sim::new(
        game,
        terrain,
        nav,
        stairs,
        content_hash,
        o.dev_spawn_near.as_deref(),
        store_jobs.clone(),
    )?;
    sim.dev_dungeon_scale = o.dev_dungeon_scale;
    sim.dev_dungeon_affixes = o.dev_dungeon_affixes.clone();
    sim.dev_dungeon_start = o.dev_dungeon_start.clone();
    sim.dev_cocoon_solo = o.dev_cocoon_solo;
    sim.admins.dev = o.dev_ga.iter().cloned().collect();
    if let Some(s) = o.dev_boss_respawn {
        sim.dev_boss_respawn(s);
    }
    if let Some(gates) = gates {
        println!(
            "[server] {} copies, {} gates",
            offsets.len(),
            gates.gates.len()
        );
        sim.set_copies(gates);
    }
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
    if let Some(addr) = o.coord.clone() {
        let coord_key: [u8; 32] = std::fs::read(o.keys.join("coord.key"))?
            .try_into()
            .map_err(|_| "coord.key must be 32 bytes")?;
        let (coord_tx, coord_rx) = tokio::sync::mpsc::unbounded_channel();
        sim.set_coord(coord_tx);
        let public = o
            .public
            .clone()
            .unwrap_or_else(|| o.bind.replace("0.0.0.0", "127.0.0.1"));
        let capacity = content_capacity(&content, &o.map);
        runtime.spawn(coord::link(
            addr,
            coord_key,
            o.map.clone(),
            public,
            capacity,
            coord_rx,
            tx.clone(),
        ));
    }
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

/// How many players `map` holds at most (maps.json `capacity`).
fn content_capacity(content: &Content, map: &str) -> u16 {
    content
        .file("maps.json")
        .and_then(|m| m["maps"][map]["capacity"].as_u64())
        .map_or(64, |c| c.min(u64::from(u16::MAX)) as u16)
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
        "[tick {}] players={} creatures={} awake={} think/s={:.0} | casts/s={:.0} hits/s={:.0} kills={} deaths={} cc holds={} procs={} dots/s={:.0} | creature abilities={} player holds={} | refused={:?} paths/s={:.0} ({:.2} ms/tick) ground {:.2} ms/tick | fallen={} (last stood at {:?}) roamed={:.0}m | tick ms p50={:.2} p99={:.2} max={:.2} late={} | {} | out {:.2} KB/s per player, {:.1} snapshots/s per player",
        tick,
        players,
        creatures,
        stats.awake_mobs,
        stats.thinking_mobs as f64 / seconds,
        stats.casts as f64 / seconds,
        stats.hits as f64 / seconds,
        stats.kills,
        stats.player_deaths,
        stats.holds,
        stats.procs,
        stats.dot_ticks as f64 / seconds,
        stats.telegraphs,
        stats.player_holds,
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
    // The same window to the coordinator, for its metrics and panel.
    let numbers = realm_proto::coord::MapStats {
        map: String::new(),
        window_ms: window.as_millis().min(u128::from(u32::MAX)) as u32,
        players: players as u32,
        creatures: creatures as u32,
        entities: 0,
        tick_p50_ms: pick(0.5),
        tick_p99_ms: pick(0.99),
        tick_max_ms: pick(1.0),
        late_ticks: late,
        saves_in_flight: stats.saves_queued.saturating_sub(stats.saves_done) as u32,
        saves_done: stats.saves_done,
        saves_failed: stats.saves_failed,
        bytes_out_per_s: (stats.bytes_out as f64 / seconds) as u64,
        rss_bytes: rss_bytes(),
    };
    stats.sections = [0.0; 5];
    stats.bytes_out = 0;
    stats.snapshots = 0;
    stats.thinking_mobs = 0;
    stats.casts = 0;
    stats.hits = 0;
    stats.kills = 0;
    stats.player_deaths = 0;
    stats.holds = 0;
    stats.procs = 0;
    stats.dot_ticks = 0;
    stats.telegraphs = 0;
    stats.player_holds = 0;
    stats.refused = [0; 3];
    stats.paths = 0;
    stats.path_ms = 0.0;
    stats.ground_ms = 0.0;
    stats.fallen = 0;
    stats.fell_at = None;
    stats.roamed = 0.0;
    sim.send_stats(realm_proto::coord::MapStats {
        map: sim.map_name().to_owned(),
        entities: sim.entity_count() as u32,
        ..numbers
    });
}

/// The process's resident memory: VmRSS of /proc/self/status on Linux (in
/// kB there), 0 elsewhere.
fn rss_bytes() -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|status| {
            status
                .lines()
                .find_map(|l| l.strip_prefix("VmRSS:"))
                .and_then(|v| v.trim().trim_end_matches("kB").trim().parse::<u64>().ok())
        })
        .map_or(0, |kb| kb * 1024)
}
