//! The realm's numbers for its operators: what every map server sends with
//! its status line (`MapMsg::Stats`, every 5 s) and what the persistence
//! service answers to `PersistMsg::Stats` (asked every 5 s when the
//! coordinator runs with `--persist`), kept with a short history for the
//! panel's sparklines.
//!
//! The admin surface (maint.rs) serves them three ways: `GET /admin/metrics`
//! (JSON), `GET /admin/metrics.prom` (Prometheus text, the same numbers, for
//! a scraper later) and `GET /panel`, a static page compiled in that holds
//! no data itself: it reads the token from its address (`/panel#token=...`,
//! the part after `#` never leaves the browser) and polls the JSON with it.

use std::collections::{BTreeMap, VecDeque};
use std::fmt::Write as _;
use std::sync::Arc;
use std::time::{Duration, Instant};

use realm_proto::coord::MapStats;
use realm_proto::persist::client::PersistClient;
use realm_proto::persist::{PersistMsg, PersistReply, PersistStats};
use serde_json::{Value, json};
use tokio::sync::Mutex;

use crate::{Book, Seat};

/// The operator panel (no data in it; see the module comment).
pub const PANEL_HTML: &str = include_str!("panel.html");

/// The persistence service is asked this often (the map servers' window).
const PERSIST_EVERY: Duration = Duration::from_secs(5);
/// Samples kept per map: 60 x 5 s = the last five minutes.
const HISTORY: usize = 60;

/// One map's numbers as they came, and its recent history.
#[derive(Default)]
struct MapSeries {
    stats: Option<MapStats>,
    at: Option<Instant>,
    /// (players, tick p99 ms), oldest first.
    history: VecDeque<(u32, f32)>,
}

#[derive(Default)]
pub struct Metrics {
    /// Every map that sent numbers since the coordinator started, by name
    /// (a map that left stays, unlinked, with the age of its last numbers).
    maps: BTreeMap<String, MapSeries>,
    /// Whether the persistence service is asked at all (`--persist`).
    persist_on: bool,
    /// Its last answer and when it came; the last failure to ask (cleared
    /// by an answer).
    persist: Option<(Instant, PersistStats)>,
    persist_error: Option<String>,
}

/// Fractions to three places: the timings travel as f32, and widened to
/// JSON's f64 they would read 1.3646000623703003.
fn tidy(v: Value) -> Value {
    match v {
        Value::Number(n) if n.is_f64() => {
            json!((n.as_f64().unwrap_or(0.0) * 1000.0).round() / 1000.0)
        }
        Value::Array(a) => Value::Array(a.into_iter().map(tidy).collect()),
        Value::Object(o) => Value::Object(o.into_iter().map(|(k, v)| (k, tidy(v))).collect()),
        other => other,
    }
}

fn age_s(at: Option<Instant>) -> Value {
    at.map_or(Value::Null, |at| {
        json!((at.elapsed().as_secs_f64() * 10.0).round() / 10.0)
    })
}

impl Book {
    /// A linked map's numbers (named by its link, which proved the map at
    /// hello, not by what the message says).
    pub fn map_stats(&mut self, link: u64, mut stats: MapStats) {
        let Some(map) = self.links.get(&link).map(|l| l.map.clone()) else {
            return;
        };
        stats.map.clone_from(&map);
        let series = self.metrics.maps.entry(map).or_default();
        series.history.push_back((stats.players, stats.tick_p99_ms));
        while series.history.len() > HISTORY {
            series.history.pop_front();
        }
        series.stats = Some(stats);
        series.at = Some(Instant::now());
    }

    /// `GET /admin/metrics`: the realm's state, players, every map and the
    /// persistence service.
    pub fn metrics_view(&self) -> Value {
        let mut names: Vec<&str> = self.metrics.maps.keys().map(String::as_str).collect();
        for l in self.links.values() {
            if !names.contains(&l.map.as_str()) {
                names.push(&l.map);
            }
        }
        names.sort_unstable();
        let maps: Vec<Value> = names
            .iter()
            .map(|name| {
                let link = self.links.iter().find(|(_, l)| l.map == *name);
                let seated = link.map_or(0, |(id, _)| {
                    self.seats
                        .values()
                        .filter(|s| matches!(s, Seat::On { link, .. } if link == id))
                        .count()
                });
                let series = self.metrics.maps.get(*name);
                let (players, tick_p99): (Vec<u32>, Vec<f32>) = series
                    .map(|s| s.history.iter().copied().unzip())
                    .unwrap_or_default();
                json!({
                    "map": name,
                    "linked": link.is_some(),
                    "address": link.map(|(_, l)| l.address.clone()),
                    "capacity": link.map(|(_, l)| l.capacity),
                    "seated": seated,
                    "age_s": age_s(series.and_then(|s| s.at)),
                    "stats": series.and_then(|s| s.stats.as_ref()),
                    "history": {"players": players, "tick_p99_ms": tick_p99},
                })
            })
            .collect();
        let in_transit = self
            .seats
            .values()
            .filter(|s| matches!(s, Seat::Transit { .. }))
            .count();
        let persistence = if self.metrics.persist_on {
            let mut block = self
                .metrics
                .persist
                .as_ref()
                .and_then(|(_, s)| serde_json::to_value(s).ok())
                .unwrap_or_else(|| json!({}));
            block["ok"] =
                json!(self.metrics.persist.is_some() && self.metrics.persist_error.is_none());
            block["error"] = json!(self.metrics.persist_error);
            block["age_s"] = age_s(self.metrics.persist.as_ref().map(|(at, _)| *at));
            block
        } else {
            Value::Null
        };
        tidy(json!({
            "ok": true,
            "state": self.maint.state.name(),
            "reason": self.maint.reason(),
            "frozen": self.maint.state.frozen(),
            "release": self.maint.settings.release,
            "protocol": realm_proto::PROTOCOL_VERSION,
            "uptime_s": self.maint.uptime().as_secs(),
            "players": self.online.len(),
            "in_transit": in_transit,
            "parties": self.parties.len(),
            "history_every_s": 5,
            "maps": maps,
            "persistence": persistence,
        }))
    }
}

/// Prometheus text exposition (version 0.0.4): one family at a time, each
/// with its HELP and TYPE.
#[derive(Default)]
struct Prom {
    out: String,
}

fn label_value(v: &str) -> String {
    v.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
}

impl Prom {
    fn family(&mut self, name: &str, kind: &str, help: &str, samples: &[(String, f64)]) {
        if samples.is_empty() {
            return;
        }
        let _ = writeln!(self.out, "# HELP {name} {help}");
        let _ = writeln!(self.out, "# TYPE {name} {kind}");
        for (labels, value) in samples {
            if labels.is_empty() {
                let _ = writeln!(self.out, "{name} {value}");
            } else {
                let _ = writeln!(self.out, "{name}{{{labels}}} {value}");
            }
        }
    }

    fn one(&mut self, name: &str, kind: &str, help: &str, value: Option<f64>) {
        if let Some(v) = value {
            self.family(name, kind, help, &[(String::new(), v)]);
        }
    }
}

/// Reads one number of a map's entry in the JSON view.
type Pick = Box<dyn Fn(&Value) -> Option<f64>>;

/// `GET /admin/metrics.prom`: the numbers of `metrics_view`, rendered from
/// that same JSON so the two never disagree.
pub fn prometheus(view: &Value) -> String {
    let mut p = Prom::default();
    let num = |v: &Value| v.as_f64();
    p.one("realm_up", "gauge", "The coordinator answers.", Some(1.0));
    p.one(
        "realm_uptime_seconds",
        "gauge",
        "Seconds since the coordinator started.",
        num(&view["uptime_s"]),
    );
    if let Some(state) = view["state"].as_str() {
        p.family(
            "realm_maintenance_state",
            "gauge",
            "The realm's maintenance state (1 on the current one).",
            &[(format!("state=\"{}\"", label_value(state)), 1.0)],
        );
    }
    p.one(
        "realm_players_online",
        "gauge",
        "Characters online on any map.",
        num(&view["players"]),
    );
    p.one(
        "realm_seats_in_transit",
        "gauge",
        "Characters travelling between maps.",
        num(&view["in_transit"]),
    );
    p.one(
        "realm_parties",
        "gauge",
        "Parties in the realm.",
        num(&view["parties"]),
    );
    let maps: &[Value] = view["maps"].as_array().map_or(&[], Vec::as_slice);
    let per_map = |pick: &dyn Fn(&Value) -> Option<f64>| -> Vec<(String, f64)> {
        maps.iter()
            .filter_map(|m| {
                let name = m["map"].as_str()?;
                Some((format!("map=\"{}\"", label_value(name)), pick(m)?))
            })
            .collect()
    };
    let stat = |field: &'static str| move |m: &Value| m["stats"][field].as_f64();
    let families: [(&str, &str, &str, Pick); 13] = [
        (
            "realm_map_linked",
            "gauge",
            "1 while the map server is linked to the coordinator.",
            Box::new(|m: &Value| m["linked"].as_bool().map(|b| f64::from(u8::from(b)))),
        ),
        (
            "realm_map_seated",
            "gauge",
            "Characters the coordinator seats on the map.",
            Box::new(|m: &Value| m["seated"].as_f64()),
        ),
        (
            "realm_map_stats_age_seconds",
            "gauge",
            "Seconds since the map's last numbers.",
            Box::new(|m: &Value| m["age_s"].as_f64()),
        ),
        (
            "realm_map_players",
            "gauge",
            "Players on the map.",
            Box::new(stat("players")),
        ),
        (
            "realm_map_creatures",
            "gauge",
            "Creatures on the map.",
            Box::new(stat("creatures")),
        ),
        (
            "realm_map_entities",
            "gauge",
            "Replicated entities on the map.",
            Box::new(stat("entities")),
        ),
        (
            "realm_map_late_ticks",
            "gauge",
            "Ticks over their slot in the last window.",
            Box::new(stat("late_ticks")),
        ),
        (
            "realm_map_saves_in_flight",
            "gauge",
            "Saves handed to the store and not yet answered.",
            Box::new(stat("saves_in_flight")),
        ),
        (
            "realm_map_saves_total",
            "counter",
            "Saves answered since the map server started.",
            Box::new(stat("saves_done")),
        ),
        (
            "realm_map_saves_failed_total",
            "counter",
            "Saves that did not land since the map server started.",
            Box::new(stat("saves_failed")),
        ),
        (
            "realm_map_bytes_out_per_second",
            "gauge",
            "Snapshot bytes sent per second over the last window.",
            Box::new(stat("bytes_out_per_s")),
        ),
        (
            "realm_map_rss_bytes",
            "gauge",
            "Resident memory of the map server (0 off Linux).",
            Box::new(stat("rss_bytes")),
        ),
        (
            "realm_map_window_seconds",
            "gauge",
            "Length of the window the numbers cover.",
            Box::new(|m: &Value| m["stats"]["window_ms"].as_f64().map(|ms| ms / 1000.0)),
        ),
    ];
    for (name, kind, help, pick) in &families {
        p.family(name, kind, help, &per_map(pick.as_ref()));
    }
    let mut ticks = Vec::new();
    for (q, field) in [
        ("0.5", "tick_p50_ms"),
        ("0.99", "tick_p99_ms"),
        ("1", "tick_max_ms"),
    ] {
        for (labels, v) in per_map(&|m: &Value| m["stats"][field].as_f64()) {
            ticks.push((format!("{labels},quantile=\"{q}\""), v));
        }
    }
    p.family(
        "realm_map_tick_ms",
        "gauge",
        "Tick time in the last window (quantile 1 = max).",
        &ticks,
    );
    let ps = &view["persistence"];
    if ps.is_object() {
        p.one(
            "realm_persist_up",
            "gauge",
            "1 when the persistence service answered the last ask.",
            ps["ok"].as_bool().map(|b| f64::from(u8::from(b))),
        );
        let plain: [(&str, &str, &str, &str); 12] = [
            (
                "realm_persist_stats_age_seconds",
                "gauge",
                "Seconds since its last answer.",
                "age_s",
            ),
            (
                "realm_persist_uptime_seconds",
                "gauge",
                "Seconds since the persistence service started.",
                "uptime_s",
            ),
            (
                "realm_persist_callers",
                "gauge",
                "Callers linked to the persistence service.",
                "callers",
            ),
            (
                "realm_persist_loads_total",
                "counter",
                "Character loads since start.",
                "loads",
            ),
            (
                "realm_persist_saves_total",
                "counter",
                "Saves committed since start.",
                "saves",
            ),
            (
                "realm_persist_stale_total",
                "counter",
                "Saves refused as older than the stored sheet.",
                "stale",
            ),
            (
                "realm_persist_failures_total",
                "counter",
                "Requests the store failed since start.",
                "failures",
            ),
            (
                "realm_persist_saves_last_minute",
                "gauge",
                "Saves committed in the last minute.",
                "saves_last_minute",
            ),
            (
                "realm_persist_database_bytes",
                "gauge",
                "Size of the realm's database.",
                "database_bytes",
            ),
            (
                "realm_persist_characters",
                "gauge",
                "Characters stored.",
                "characters",
            ),
            (
                "realm_persist_accounts",
                "gauge",
                "Accounts stored.",
                "accounts",
            ),
            (
                "realm_persist_database_error",
                "gauge",
                "1 when the database figures could not be read.",
                "database_error",
            ),
        ];
        for (name, kind, help, field) in plain {
            let value = if field == "database_error" {
                ps[field]
                    .as_str()
                    .map(|e| f64::from(u8::from(!e.is_empty())))
            } else {
                ps[field].as_f64()
            };
            p.one(name, kind, help, value);
        }
        let lat: Vec<(String, f64)> = [
            ("0.5", "save_p50_ms"),
            ("0.99", "save_p99_ms"),
            ("1", "save_max_ms"),
        ]
        .iter()
        .filter_map(|(q, f)| Some((format!("quantile=\"{q}\""), ps[*f].as_f64()?)))
        .collect();
        p.family(
            "realm_persist_save_ms",
            "gauge",
            "Save commit time over the last minute (quantile 1 = max).",
            &lat,
        );
    }
    p.out
}

/// Asks the persistence service for its numbers every 5 s on a link of its
/// own, so the ask never waits behind the coordinator's queued changes (a
/// board, a GA tried until it lands). One ask at a time: the next starts
/// only when the last was answered or failed (the client's own timeouts).
pub fn start_persist_poll(book: Arc<Mutex<Book>>, client: Arc<PersistClient>) {
    tokio::spawn(async move {
        book.lock().await.metrics.persist_on = true;
        let mut every = tokio::time::interval(PERSIST_EVERY);
        every.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            every.tick().await;
            let answer = match client.call(|req| PersistMsg::Stats { req }).await {
                Ok(PersistReply::Stats { result, .. }) => result,
                Ok(_) => Err("the persistence service answered something else".to_owned()),
                Err(e) => Err(e),
            };
            let mut b = book.lock().await;
            match answer {
                Ok(stats) => {
                    b.metrics.persist = Some((Instant::now(), stats));
                    b.metrics.persist_error = None;
                }
                Err(e) => b.metrics.persist_error = Some(e),
            }
        }
    });
}
