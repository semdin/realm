//! `realm_netcheck --maintenance --admin <addr> --grounds <addr> --castle
//! <addr> --characters <dir>`: the realm's maintenance end to end. Needs
//! the coordinator (REALM_SERVICE_TOKEN set to `--token`, its admin surface
//! on `--admin`, short timings: `--drain-seconds 1 --save-min-ms 500
//! --announce-ms 1000`), grounds and castle_interior sharing `<dir>`, both
//! started with `--dev-fail-saves <dir>/FAIL_SAVES`.
//!
//! 1. the surface refuses a request without the token; the status says
//!    ONLINE with both maps;
//! 2. two players on the grounds and one in the castle; a lone save
//!    barrier confirms all three; `update_soon` reaches all three;
//! 3. a countdown: all three hear it, a new login is refused; aborted, all
//!    hear ONLINE and the login comes in;
//! 4. saves made to fail: the cycle stops in FAILED with everyone still
//!    connected and the world frozen (a player walking does not move as
//!    another sees it); aborted, the realm plays again, and the failed save
//!    lands once the store works (it is tried again);
//! 5. the full cycle: ANNOUNCING, DRAINING, SAVING, DISCONNECTING heard by
//!    everyone, every connection closed, MAINTENANCE with no player and the
//!    maps idle; each character's file holds where it stood; a login is
//!    refused, and abort and a new begin are refused too.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use realm_netclient::ClientCore;
use realm_proto::SigningKey;
use realm_proto::control::ServerMsg;
use realm_rules::CharacterSheet;
use realm_sim::Vec3;
use realm_sim::input::MoveInput;
use serde_json::{Value, json};

use crate::travel::{Session, fail, joined};
use crate::{AnyResult, arg};

/// One request to the admin surface: (status, body).
fn http(
    admin: &str,
    method: &str,
    path: &str,
    token: &str,
    body: &Value,
) -> AnyResult<(u16, Value)> {
    let mut stream = TcpStream::connect(admin)?;
    stream.set_read_timeout(Some(Duration::from_secs(30)))?;
    let payload = body.to_string();
    let auth = if token.is_empty() {
        String::new()
    } else {
        format!("x-service-token: {token}\r\n")
    };
    write!(
        stream,
        "{method} {path} HTTP/1.1\r\nHost: {admin}\r\n{auth}Content-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
        payload.len()
    )?;
    let mut text = String::new();
    stream.read_to_string(&mut text)?;
    let status: u16 = text
        .split(' ')
        .nth(1)
        .and_then(|s| s.parse().ok())
        .ok_or("no status line")?;
    let body = text.split("\r\n\r\n").nth(1).unwrap_or("{}");
    Ok((status, serde_json::from_str(body).unwrap_or(Value::Null)))
}

/// The states `s` heard, in order (repeats folded).
fn heard(s: &Session) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for m in &s.events {
        if let ServerMsg::Maintenance { state, .. } = m
            && out.last() != Some(state)
        {
            out.push(state.clone());
        }
    }
    out
}

fn heard_state(s: &Session, state: &str) -> bool {
    heard(s).iter().any(|h| h == state)
}

/// Pumps every session for `seconds` (idle) or until `done`.
fn pump_all(
    all: &mut [&mut Session],
    seconds: f32,
    mut done: impl FnMut(&[&mut Session]) -> bool,
) -> AnyResult<bool> {
    let end = Instant::now() + Duration::from_secs_f32(seconds);
    while Instant::now() < end {
        for s in all.iter_mut() {
            s.pump(MoveInput::default())?;
        }
        if done(all) {
            return Ok(true);
        }
        std::thread::sleep(Duration::from_millis(33));
    }
    Ok(false)
}

fn load(dir: &Path, character: u64) -> AnyResult<CharacterSheet> {
    let text = std::fs::read_to_string(dir.join(format!("{character}.json")))?;
    Ok(serde_json::from_str(&text)?)
}

fn modified(dir: &Path, character: u64) -> Option<SystemTime> {
    std::fs::metadata(dir.join(format!("{character}.json")))
        .and_then(|m| m.modified())
        .ok()
}

/// Logs in and waits for the join; Err(reason) when refused.
fn login(
    address: &str,
    map: &str,
    character: u64,
    key: &SigningKey,
    args: &[String],
) -> Result<Session, String> {
    let mut s = Session::dev(address, map, character, key, args).map_err(|e| e.to_string())?;
    joined(&mut s).map_err(|e| e.to_string())?;
    Ok(s)
}

fn expect(
    what: &str,
    got: (u16, Value),
    code: u16,
    check: impl Fn(&Value) -> bool,
) -> AnyResult<Value> {
    if got.0 != code || !check(&got.1) {
        return fail(format!("{what}: got {} {}", got.0, got.1));
    }
    println!("[maintenance] {what}: {} {}", got.0, got.1);
    Ok(got.1)
}

pub fn run(args: &[String]) -> AnyResult<()> {
    let admin = arg(args, "--admin", "127.0.0.1:8083");
    let token = arg(args, "--token", "check-token");
    let grounds = arg(args, "--grounds", "127.0.0.1:7777");
    let castle = arg(args, "--castle", "127.0.0.1:7778");
    let dir = PathBuf::from(arg(args, "--characters", "build/maintcheck"));
    let flag = dir.join("FAIL_SAVES");
    let _ = std::fs::remove_file(&flag);
    let keys = PathBuf::from(arg(args, "--keys", "keys"));
    let secret: [u8; 32] = std::fs::read(keys.join("ticket.key"))?
        .try_into()
        .map_err(|_| "ticket.key must be 32 bytes")?;
    let key = SigningKey::from_bytes(&secret);
    let base = 700_000 + SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() % 100_000 * 4;
    let none = json!({});

    // 1. The surface.
    expect(
        "no token",
        http(&admin, "GET", "/admin/status", "", &none)?,
        403,
        |_| true,
    )?;
    expect(
        "wrong token",
        http(&admin, "GET", "/admin/status", "not-the-token", &none)?,
        403,
        |_| true,
    )?;
    expect(
        "status",
        http(&admin, "GET", "/admin/status", &token, &none)?,
        200,
        |v| {
            v["state"] == "ONLINE"
                && v["maps"].as_array().is_some_and(|m| {
                    m.iter().any(|x| x == "grounds") && m.iter().any(|x| x == "castle_interior")
                })
        },
    )?;

    // 2. Three players, a lone barrier, a heads-up.
    let (ca, cb, cd) = (base, base + 1, base + 2);
    let mut a = login(&grounds, "grounds", ca, &key, args)?;
    let mut b = login(&grounds, "grounds", cb, &key, args)?;
    let mut d = login(&castle, "castle_interior", cd, &key, args)?;
    pump_all(&mut [&mut a, &mut b, &mut d], 1.5, |_| false)?;
    expect(
        "three online",
        http(&admin, "GET", "/admin/status", &token, &none)?,
        200,
        |v| v["players"] == 3,
    )?;
    expect(
        "lone save",
        http(&admin, "POST", "/admin/save", &token, &none)?,
        200,
        |v| v["ok"] == true && v["saved"] == 3 && v["failed"] == 0,
    )?;
    expect(
        "update_soon",
        http(
            &admin,
            "POST",
            "/admin/announce",
            &token,
            &json!({"kind": "update_soon", "minutes": 5}),
        )?,
        200,
        |v| v["minutes"] == 5,
    )?;
    let told = |s: &Session| {
        s.events
            .iter()
            .any(|m| matches!(m, ServerMsg::Notice { kind, value: 5, .. } if kind == "update_soon"))
    };
    if !pump_all(&mut [&mut a, &mut b, &mut d], 3.0, |all| {
        all.iter().all(|s| told(s))
    })? {
        return fail("update_soon did not reach everyone");
    }
    println!("[maintenance] 2 ok: three players, the lone barrier saved 3, update_soon heard");

    // 3. A countdown, refused login, abort.
    expect(
        "begin",
        http(
            &admin,
            "POST",
            "/admin/maintenance/begin",
            &token,
            &json!({"reason": "check", "countdown_seconds": 30}),
        )?,
        200,
        |v| v["state"] == "ANNOUNCING",
    )?;
    if !pump_all(&mut [&mut a, &mut b, &mut d], 3.0, |all| {
        all.iter().all(|s| heard_state(s, "ANNOUNCING"))
    })? {
        return fail("the countdown did not reach everyone");
    }
    let secs = d.events.iter().rev().find_map(|m| match m {
        ServerMsg::Maintenance { seconds, .. } => Some(*seconds),
        _ => None,
    });
    if !secs.is_some_and(|s| (25..=30).contains(&s)) {
        return fail(format!("the countdown said {secs:?} s"));
    }
    match login(&grounds, "grounds", base + 3, &key, args) {
        Err(e) if e.contains("maintenance") => {
            println!("[maintenance] a login during the countdown: {e}")
        }
        Err(e) => return fail(format!("login refused for the wrong reason: {e}")),
        Ok(_) => return fail("a login came in during the countdown"),
    }
    expect(
        "begin twice",
        http(&admin, "POST", "/admin/maintenance/begin", &token, &none)?,
        409,
        |v| v["error"] == "already_in_maintenance",
    )?;
    expect(
        "abort",
        http(&admin, "POST", "/admin/maintenance/abort", &token, &none)?,
        200,
        |v| v["state"] == "ONLINE" && v["previous_state"] == "ANNOUNCING",
    )?;
    if !pump_all(&mut [&mut a, &mut b, &mut d], 3.0, |all| {
        all.iter()
            .all(|s| heard(s).last().is_some_and(|h| h == "ONLINE"))
    })? {
        return fail("the abort did not reach everyone");
    }
    {
        let c = login(&grounds, "grounds", base + 3, &key, args)
            .map_err(|e| format!("a login after the abort: {e}"))?;
        drop(c);
    }
    expect(
        "aborted status",
        http(&admin, "GET", "/admin/status", &token, &none)?,
        200,
        |v| {
            v["state"] == "ONLINE"
                && v["history"]
                    .as_array()
                    .is_some_and(|h| h.iter().any(|x| x["state"] == "ABORTED"))
        },
    )?;
    println!("[maintenance] 3 ok: countdown heard (30 s), login refused, aborted, login again");

    // 4. Saves fail: the FAILED hold.
    std::fs::write(&flag, b"fail")?;
    let a_file_before = modified(&dir, ca);
    expect(
        "begin (failing store)",
        http(
            &admin,
            "POST",
            "/admin/maintenance/begin",
            &token,
            &json!({"reason": "check", "countdown_seconds": 1}),
        )?,
        200,
        |_| true,
    )?;
    if !pump_all(&mut [&mut a, &mut b, &mut d], 25.0, |all| {
        all.iter().all(|s| heard_state(s, "FAILED"))
    })? {
        return fail(format!(
            "no FAILED hold: {:?} {:?} {:?}",
            heard(&a),
            heard(&b),
            heard(&d)
        ));
    }
    let order = heard(&a);
    let want = ["ONLINE", "ANNOUNCING", "DRAINING", "SAVING", "FAILED"];
    if !order.ends_with(&want.map(str::to_owned)[1..]) {
        return fail(format!("the cycle went {order:?}"));
    }
    if a.closed.is_some() || b.closed.is_some() || d.closed.is_some() {
        return fail("a connection closed in the FAILED hold");
    }
    // Frozen: a walks; b sees it stand.
    let me = a.core.as_ref().map_or(0, ClientCore::me);
    let seen = |b: &Session| {
        let t = b.started.elapsed().as_secs_f64() * ClientCore::HZ;
        b.core
            .as_ref()
            .and_then(|c| c.remote_entities(t).into_iter().find(|e| e.id == me))
            .map(|e| e.pos)
    };
    let before = seen(&b).ok_or("b does not see a")?;
    let started = Instant::now();
    while started.elapsed() < Duration::from_secs(2) {
        a.pump(MoveInput::from_intent(0.0, 1.0, 0.0, 0))?;
        b.pump(MoveInput::default())?;
        d.pump(MoveInput::default())?;
        std::thread::sleep(Duration::from_millis(33));
    }
    let after = seen(&b).ok_or("b lost a")?;
    if (after - before).length() > 0.05 {
        return fail(format!(
            "a moved {:.2} m in a frozen world",
            (after - before).length()
        ));
    }
    expect(
        "failed status",
        http(&admin, "GET", "/admin/status", &token, &none)?,
        200,
        |v| v["state"] == "FAILED" && v["frozen"] == true && v["players"] == 3,
    )?;
    expect(
        "abort FAILED",
        http(&admin, "POST", "/admin/maintenance/abort", &token, &none)?,
        200,
        |v| v["previous_state"] == "FAILED",
    )?;
    if !pump_all(&mut [&mut a, &mut b, &mut d], 3.0, |all| {
        all.iter()
            .all(|s| heard(s).last().is_some_and(|h| h == "ONLINE"))
    })? {
        return fail("the FAILED abort did not reach everyone");
    }
    // Playing again: a walks and b sees it.
    let before = seen(&b).ok_or("b does not see a")?;
    let started = Instant::now();
    while started.elapsed() < Duration::from_secs(2) {
        a.pump(MoveInput::from_intent(0.0, 1.0, 0.0, 0))?;
        b.pump(MoveInput::default())?;
        d.pump(MoveInput::default())?;
        std::thread::sleep(Duration::from_millis(33));
    }
    let moved = (seen(&b).ok_or("b lost a")? - before).length();
    if moved < 1.0 {
        return fail(format!("a moved only {moved:.2} m after the abort"));
    }
    // The store works again: the failed save is tried again and lands.
    std::fs::remove_file(&flag)?;
    if !pump_all(&mut [&mut a, &mut b, &mut d], 10.0, |_| {
        modified(&dir, ca) != a_file_before
    })? {
        return fail("the failed save was never tried again");
    }
    println!(
        "[maintenance] 4 ok: FAILED hold (everyone connected, frozen), aborted, a walked {moved:.1} m, the failed save landed on retry"
    );

    // 5. The full cycle.
    pump_all(&mut [&mut a, &mut b, &mut d], 1.0, |_| false)?;
    let a_at = a.pos();
    let revisions = [
        load(&dir, ca)?.revision,
        load(&dir, cb)?.revision,
        load(&dir, cd)?.revision,
    ];
    for s in [&mut a, &mut b, &mut d] {
        s.events.clear();
    }
    expect(
        "begin (full)",
        http(
            &admin,
            "POST",
            "/admin/maintenance/begin",
            &token,
            &json!({"reason": "check", "countdown_seconds": 2}),
        )?,
        200,
        |_| true,
    )?;
    if !pump_all(&mut [&mut a, &mut b, &mut d], 25.0, |all| {
        all.iter().all(|s| s.closed.is_some())
    })? {
        return fail(format!(
            "not everyone was disconnected: {:?} {:?} {:?}",
            heard(&a),
            heard(&b),
            heard(&d)
        ));
    }
    for (name, s) in [("a", &a), ("b", &b), ("d", &d)] {
        let order = heard(s);
        if order != ["ANNOUNCING", "DRAINING", "SAVING", "DISCONNECTING"] {
            return fail(format!("{name} heard {order:?}"));
        }
    }
    let status = pump_until_status(&admin, &token, "MAINTENANCE")?;
    if status["players"] != 0 || status["simulation_paused"] != true {
        return fail(format!("MAINTENANCE status {status}"));
    }
    for (c, rev) in [ca, cb, cd].into_iter().zip(revisions) {
        let sheet = load(&dir, c)?;
        if sheet.revision < rev {
            return fail(format!(
                "character {c}: revision {} < {rev}",
                sheet.revision
            ));
        }
        if c == ca {
            let p = sheet.place.as_ref().ok_or("a has no place")?;
            let at = Vec3::new(p.pos[0], p.pos[1], p.pos[2]);
            if (at - a_at).length() > 0.5 {
                return fail(format!("a was saved at {at:?}, stood at {a_at:?}"));
            }
        }
    }
    match login(&grounds, "grounds", ca, &key, args) {
        Err(e) if e.contains("maintenance") => {
            println!("[maintenance] a login in MAINTENANCE: {e}")
        }
        Err(e) => {
            return fail(format!(
                "login in MAINTENANCE refused for the wrong reason: {e}"
            ));
        }
        Ok(_) => return fail("a login came in during MAINTENANCE"),
    }
    expect(
        "abort too late",
        http(&admin, "POST", "/admin/maintenance/abort", &token, &none)?,
        409,
        |v| v["error"] == "too_late",
    )?;
    expect(
        "begin in MAINTENANCE",
        http(&admin, "POST", "/admin/maintenance/begin", &token, &none)?,
        409,
        |v| v["error"] == "already_in_maintenance",
    )?;
    println!(
        "[maintenance] 5 ok: every player heard ANNOUNCING, DRAINING, SAVING, DISCONNECTING and was let go; MAINTENANCE with 0 players, maps idle, sheets saved where they stood"
    );
    println!("[maintenance] ok: surface, barrier, countdown, abort, FAILED hold, full cycle");
    Ok(())
}

fn pump_until_status(admin: &str, token: &str, state: &str) -> AnyResult<Value> {
    let started = Instant::now();
    loop {
        let (_, v) = http(admin, "GET", "/admin/status", token, &json!({}))?;
        if v["state"] == state {
            println!("[maintenance] status: {v}");
            return Ok(v);
        }
        if started.elapsed() > Duration::from_secs(20) {
            return fail(format!("status never reached {state}: {v}"));
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}
