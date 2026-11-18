//! `realm_netcheck --metrics --admin <addr> --token <t> --server <grounds>
//! [--persist-addr <addr>]`: the coordinator's metrics and operator panel.
//! Needs the coordinator (REALM_SERVICE_TOKEN set to `--token`, its admin
//! surface on `--admin`; with `--persist-addr`, run with `--persist` on that
//! service) and a grounds map server linked to it (with `--persist` too
//! when `--persist-addr` is given). Under a minute, every wait short:
//!
//! 1. `/panel` is an HTML page without the token; `/admin/metrics` without
//!    it is refused;
//! 2. the grounds' numbers appear within ~7 s;
//! 3. a player joins and the grounds counts one more player;
//! 4. it leaves; with the persistence service, its save lands there and
//!    the persistence block counts one more save;
//! 5. `/admin/metrics.prom` is Prometheus text: every line a comment or a
//!    name with a value, the grounds' players and (on persist) the saves
//!    among them.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use realm_proto::SigningKey;
use realm_proto::persist::{PersistMsg, PersistReply};
use serde_json::{Value, json};

use crate::maintenance::http;
use crate::travel::{Session, idle, joined, run_until};
use crate::{AnyResult, arg};

fn fail<T>(what: impl Into<String>) -> AnyResult<T> {
    Err(format!("metrics check failed: {}", what.into()).into())
}

/// One GET that is not JSON: (status, content type, body).
fn get_text(admin: &str, path: &str, token: &str) -> AnyResult<(u16, String, String)> {
    let mut stream = TcpStream::connect(admin)?;
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    let auth = if token.is_empty() {
        String::new()
    } else {
        format!("x-service-token: {token}\r\n")
    };
    write!(
        stream,
        "GET {path} HTTP/1.1\r\nHost: {admin}\r\n{auth}Connection: close\r\n\r\n"
    )?;
    let mut text = String::new();
    stream.read_to_string(&mut text)?;
    let (head, body) = text.split_once("\r\n\r\n").ok_or("no header end")?;
    let status: u16 = head
        .split(' ')
        .nth(1)
        .and_then(|s| s.parse().ok())
        .ok_or("no status line")?;
    let kind = head
        .lines()
        .find_map(|l| {
            let (name, value) = l.split_once(':')?;
            name.eq_ignore_ascii_case("content-type")
                .then(|| value.trim().to_owned())
        })
        .unwrap_or_default();
    Ok((status, kind, body.to_owned()))
}

fn metrics(admin: &str, token: &str) -> AnyResult<Value> {
    let (code, body) = http(admin, "GET", "/admin/metrics", token, &json!({}))?;
    if code != 200 {
        return fail(format!("/admin/metrics answered {code}: {body}"));
    }
    Ok(body)
}

fn grounds(m: &Value) -> Option<&Value> {
    m["maps"].as_array()?.iter().find(|x| x["map"] == "grounds")
}

/// The grounds' numbers once they are no older than `fresh_s`.
fn grounds_stats(m: &Value, fresh_s: f64) -> Option<&Value> {
    let g = grounds(m)?;
    (g["linked"] == true && g["age_s"].as_f64()? <= fresh_s && g["stats"].is_object())
        .then(|| &g["stats"])
}

/// Polls `/admin/metrics` every 300 ms for `seconds` until `want` finds
/// what it waits for.
fn wait_for<T>(
    admin: &str,
    token: &str,
    seconds: f32,
    mut want: impl FnMut(&Value) -> Option<T>,
) -> AnyResult<Option<T>> {
    let end = Instant::now() + Duration::from_secs_f32(seconds);
    while Instant::now() < end {
        if let Some(found) = want(&metrics(admin, token)?) {
            return Ok(Some(found));
        }
        std::thread::sleep(Duration::from_millis(300));
    }
    Ok(None)
}

pub fn run(args: &[String]) -> AnyResult<()> {
    let started = Instant::now();
    let admin = arg(args, "--admin", "127.0.0.1:8082");
    let token = arg(args, "--token", "check-token");
    let server = arg(args, "--server", "127.0.0.1:7777");
    let persist = args
        .iter()
        .position(|a| a == "--persist-addr")
        .and_then(|i| args.get(i + 1))
        .cloned();
    let keys = PathBuf::from(arg(args, "--keys", "keys"));
    let secret: [u8; 32] = std::fs::read(keys.join("ticket.key"))?
        .try_into()
        .map_err(|_| "ticket.key must be 32 bytes")?;
    let key = SigningKey::from_bytes(&secret);

    // 1. The panel is open, the numbers are not.
    let (code, kind, body) = get_text(&admin, "/panel", "")?;
    if code != 200 || !kind.starts_with("text/html") || !body.contains("/admin/metrics") {
        return fail(format!(
            "/panel without a token: {code} {kind}, {} bytes",
            body.len()
        ));
    }
    let (code, _) = http(&admin, "GET", "/admin/metrics", "", &json!({}))?;
    if code != 403 {
        return fail(format!("/admin/metrics without a token answered {code}"));
    }
    let (code, _) = http(&admin, "GET", "/admin/metrics", "wrong-token", &json!({}))?;
    if code != 403 {
        return fail(format!("/admin/metrics with a wrong token answered {code}"));
    }
    println!(
        "[metrics] 1 ok: /panel is HTML without a token ({} bytes); /admin/metrics refuses none or a wrong one",
        body.len()
    );

    // 2. The grounds' numbers.
    let Some(before) = wait_for(&admin, &token, 7.5, |m| {
        grounds_stats(m, 7.0).map(|s| s["players"].as_u64().unwrap_or(0))
    })?
    else {
        let m = metrics(&admin, &token)?;
        return fail(format!(
            "no fresh grounds numbers within 7.5 s: {}",
            grounds(&m).map_or_else(|| "no grounds".to_owned(), Value::to_string)
        ));
    };
    let m = metrics(&admin, &token)?;
    let stats = grounds_stats(&m, 7.0).ok_or("the grounds' numbers went stale")?;
    if stats["tick_p99_ms"].as_f64().is_none_or(|t| t <= 0.0)
        || stats["creatures"].as_u64().is_none_or(|c| c == 0)
    {
        return fail(format!("implausible grounds numbers: {stats}"));
    }
    if persist.is_some() && !m["persistence"].is_object() {
        return fail("the coordinator reports no persistence block (is it on --persist?)");
    }
    println!(
        "[metrics] 2 ok: grounds numbers {:.1} s old: players={before} creatures={} tick p99={:.2} ms, {} map(s), state {}",
        grounds(&m).and_then(|g| g["age_s"].as_f64()).unwrap_or(0.0),
        stats["creatures"],
        stats["tick_p99_ms"].as_f64().unwrap_or(0.0),
        m["maps"].as_array().map_or(0, Vec::len),
        m["state"],
    );
    // The service's save count before the player (once it has answered).
    let saves_before = if persist.is_some() {
        let found = wait_for(&admin, &token, 7.0, |m| {
            let p = &m["persistence"];
            (p["ok"] == true).then(|| p["saves"].as_u64())?
        })?;
        let Some(saves) = found else {
            return fail(format!(
                "the persistence block never answered: {}",
                metrics(&admin, &token)?["persistence"]
            ));
        };
        Some(saves)
    } else {
        None
    };

    // 3. A player joins.
    // Below the players' ids (see the persistence check).
    let character = 4_000_000 + SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() % 1_000_000;
    {
        let mut s = Session::dev(&server, "grounds", character, &key, args)?;
        joined(&mut s)?;
        let want = before + 1;
        let mut last_ask = Instant::now() - Duration::from_secs(1);
        let mut seen = None;
        let mut error = None;
        run_until(&mut s, 12.0, idle, |_| {
            if last_ask.elapsed() < Duration::from_millis(300) {
                return false;
            }
            last_ask = Instant::now();
            match metrics(&admin, &token) {
                Ok(m) => {
                    seen = grounds_stats(&m, 7.0).and_then(|s| s["players"].as_u64());
                    seen == Some(want)
                }
                Err(e) => {
                    error = Some(e.to_string());
                    true
                }
            }
        })?;
        if let Some(e) = error {
            return fail(e);
        }
        if seen != Some(want) {
            return fail(format!(
                "the grounds never showed {want} player(s) (last {seen:?})"
            ));
        }
        if let Some(why) = &s.closed {
            return fail(format!("the grounds closed the session: {why}"));
        }
        println!(
            "[metrics] 3 ok: character {character} joined; the grounds shows {want} player(s)"
        );
    }

    // 4. It left; its save lands and the service counts it.
    if let (Some(addr), Some(before_saves)) = (&persist, saves_before) {
        let service: [u8; 32] = std::fs::read(keys.join("coord.key"))?
            .try_into()
            .map_err(|_| "coord.key must be 32 bytes")?;
        let end = Instant::now() + Duration::from_secs(10);
        loop {
            if let PersistReply::Loaded {
                result: Ok(Some(_)),
                ..
            } = crate::persist::ask(addr, service, &PersistMsg::Load { req: 1, character })?
            {
                break;
            }
            if Instant::now() > end {
                return fail("the leave's save never reached the persistence service");
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        let counted = wait_for(&admin, &token, 12.0, |m| {
            let p = &m["persistence"];
            let saves = p["saves"].as_u64()?;
            (p["ok"] == true && saves > before_saves).then(|| (saves, p.clone()))
        })?;
        let Some((saves, block)) = counted else {
            return fail(format!(
                "the persistence block never counted the save (before {before_saves}): {}",
                metrics(&admin, &token)?["persistence"]
            ));
        };
        println!(
            "[metrics] 4 ok: the leave's save landed; persistence saves {before_saves} -> {saves}, save p99 {:.1} ms, {} character(s), {} account(s), database {} bytes, {} caller(s)",
            block["save_p99_ms"].as_f64().unwrap_or(0.0),
            block["characters"],
            block["accounts"],
            block["database_bytes"],
            block["callers"],
        );
    } else {
        println!("[metrics] 4 skipped: no --persist-addr");
    }
    let m = metrics(&admin, &token)?;
    if let Some(stats) = grounds_stats(&m, 12.0)
        && stats["saves_failed"].as_u64().unwrap_or(0) > 0
    {
        return fail(format!("the grounds counts failed saves: {stats}"));
    }

    // 5. The same numbers for a scraper.
    let (code, kind, prom) = get_text(&admin, "/admin/metrics.prom", &token)?;
    if code != 200 || !kind.starts_with("text/plain") {
        return fail(format!("/admin/metrics.prom: {code} {kind}"));
    }
    let (status, _, _) = get_text(&admin, "/admin/metrics.prom", "")?;
    if status != 403 {
        return fail(format!(
            "/admin/metrics.prom without a token answered {status}"
        ));
    }
    let mut samples = 0;
    let mut grounds_players = None;
    let mut persist_saves = None;
    for line in prom.lines() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((series, value)) = line.rsplit_once(' ') else {
            return fail(format!("not a sample: {line}"));
        };
        let Ok(value) = value.parse::<f64>() else {
            return fail(format!("not a number: {line}"));
        };
        let name = series.split('{').next().unwrap_or("");
        let valid = name
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphabetic() || c == '_' || c == ':')
            && name
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == ':')
            && (series == name || (series.ends_with('}') && series.len() > name.len() + 2));
        if !valid {
            return fail(format!("not a metric name: {line}"));
        }
        samples += 1;
        if series == "realm_map_players{map=\"grounds\"}" {
            grounds_players = Some(value);
        }
        if series == "realm_persist_saves_total" {
            persist_saves = Some(value);
        }
    }
    if grounds_players.is_none() {
        return fail("the Prometheus text has no realm_map_players for the grounds");
    }
    if persist.is_some() && persist_saves.is_none_or(|s| s < 1.0) {
        return fail("the Prometheus text has no realm_persist_saves_total");
    }
    println!(
        "[metrics] 5 ok: /admin/metrics.prom is {samples} samples ({} bytes), grounds players {}, persist saves {}",
        prom.len(),
        grounds_players.unwrap_or(0.0),
        persist_saves.map_or_else(|| "-".to_owned(), |s| s.to_string()),
    );
    println!(
        "[metrics] ok in {:.1} s: panel, metrics JSON and Prometheus text carry the maps{}",
        started.elapsed().as_secs_f64(),
        if persist.is_some() {
            " and the persistence service"
        } else {
            ""
        }
    );
    Ok(())
}
