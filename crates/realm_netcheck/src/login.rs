//! `realm_netcheck --login --login-addr <addr>`: the login service end to
//! end. Needs realm_login (its --characters the map servers' folder), the
//! coordinator (REALM_SERVICE_TOKEN, admin surface) and the grounds server.
//!
//! 1. account rules: bad names and passwords refused, a name taken
//!    (whatever the case) refused;
//! 2. a wrong password refused, the right one gives a session;
//! 3. character rules: bad names, an unknown house, a name taken by
//!    another account (whatever the case), a third character all refused;
//!    two made, the roster lists them (level 1, the start map, the look);
//! 4. play: a ticket for the grounds; joining with it brings the character
//!    in with its name, house and look; another account's character is
//!    not playable;
//! 5. logout ends the session; ten failed logins make the next one wait.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use crate::travel::{Session, fail, joined};
use crate::{AnyResult, arg};

fn call(addr: &str, path: &str, bearer: &str, body: &Value) -> AnyResult<(u16, Value)> {
    let mut stream = TcpStream::connect(addr)?;
    stream.set_read_timeout(Some(Duration::from_secs(30)))?;
    let payload = body.to_string();
    let auth = if bearer.is_empty() {
        String::new()
    } else {
        format!("Authorization: Bearer {bearer}\r\n")
    };
    let method = if path == "/api/health" { "GET" } else { "POST" };
    write!(
        stream,
        "{method} {path} HTTP/1.1\r\nHost: {addr}\r\n{auth}Content-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
        payload.len()
    )?;
    let mut text = String::new();
    stream.read_to_string(&mut text)?;
    let status: u16 = text
        .split(' ')
        .nth(1)
        .and_then(|s| s.parse().ok())
        .ok_or("no status line")?;
    let body = text.split_once("\r\n\r\n").map_or("{}", |(_, b)| b);
    Ok((status, serde_json::from_str(body).unwrap_or(Value::Null)))
}

fn want(what: &str, got: (u16, Value), code: u16) -> AnyResult<Value> {
    if got.0 != code {
        return fail(format!("{what}: wanted {code}, got {} {}", got.0, got.1));
    }
    Ok(got.1)
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok())
        .collect()
}

pub fn run(args: &[String]) -> AnyResult<()> {
    let login = arg(args, "--login-addr", "127.0.0.1:7950");
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() % 1_000_000;
    let (user_a, user_b) = (format!("check_a{stamp}"), format!("check_b{stamp}"));
    let pass = "riverstone42";
    want("health", call(&login, "/api/health", "", &json!({}))?, 200)?;

    // 1. Accounts.
    for (name, password) in [
        ("ab", pass),
        ("bad name!", pass),
        (&user_a[..], "short1"),
        (&user_a[..], "nodigitshere"),
    ] {
        want(
            &format!("register {name:?}/{password:?}"),
            call(
                &login,
                "/api/register",
                "",
                &json!({"username": name, "password": password}),
            )?,
            400,
        )?;
    }
    want(
        "register a",
        call(
            &login,
            "/api/register",
            "",
            &json!({"username": user_a, "password": pass}),
        )?,
        200,
    )?;
    want(
        "register a again (case)",
        call(
            &login,
            "/api/register",
            "",
            &json!({"username": user_a.to_uppercase(), "password": pass}),
        )?,
        409,
    )?;
    want(
        "register b",
        call(
            &login,
            "/api/register",
            "",
            &json!({"username": user_b, "password": pass}),
        )?,
        200,
    )?;
    println!("[login] 1 ok: account names and passwords checked, a taken name refused");

    // 2. Sessions.
    want(
        "wrong password",
        call(
            &login,
            "/api/login",
            "",
            &json!({"username": user_a, "password": "riverstone43"}),
        )?,
        401,
    )?;
    let a = want(
        "login a",
        call(
            &login,
            "/api/login",
            "",
            &json!({"username": user_a, "password": pass}),
        )?,
        200,
    )?;
    let b = want(
        "login b",
        call(
            &login,
            "/api/login",
            "",
            &json!({"username": user_b, "password": pass}),
        )?,
        200,
    )?;
    let (ta, tb) = (
        a["token"].as_str().unwrap_or("").to_owned(),
        b["token"].as_str().unwrap_or("").to_owned(),
    );
    if ta.len() != 64 || tb.len() != 64 || ta == tb {
        return fail(format!("tokens {ta:?} {tb:?}"));
    }
    println!("[login] 2 ok: a wrong password refused, sessions given");

    // 3. Characters.
    let first = format!("Lirael V{}", (b'a' + (stamp % 26) as u8) as char);
    let first = format!(
        "{first}{}",
        ["ey", "an", "ol", "ir"][(stamp / 26 % 4) as usize]
    );
    for (name, house) in [
        ("A", "velkar"),
        ("-Lead", "velkar"),
        ("Bad!Name", "velkar"),
        ("1234", "velkar"),
        ("Two  Spaces", "velkar"),
        (&first[..], "no_such_house"),
    ] {
        want(
            &format!("create {name:?} {house}"),
            call(
                &login,
                "/api/characters/create",
                &ta,
                &json!({"name": name, "house": house}),
            )?,
            400,
        )?;
    }
    let look = json!([["hair", 2.0], ["no_such_key", 1.0]]);
    let made = want(
        "create first",
        call(
            &login,
            "/api/characters/create",
            &ta,
            &json!({"name": first, "house": "velkar", "look": look}),
        )?,
        200,
    )?;
    let id = made["character"]["id"].as_u64().ok_or("no id")?;
    want(
        "same name, other account, other case",
        call(
            &login,
            "/api/characters/create",
            &tb,
            &json!({"name": first.to_lowercase(), "house": "nisera"}),
        )?,
        409,
    )?;
    want(
        "second",
        call(
            &login,
            "/api/characters/create",
            &ta,
            &json!({"name": format!("{first} Two"), "house": "torvan"}),
        )?,
        200,
    )?;
    want(
        "third",
        call(
            &login,
            "/api/characters/create",
            &ta,
            &json!({"name": format!("{first} Tre"), "house": "ilvane"}),
        )?,
        400,
    )?;
    let roster = want(
        "list",
        call(&login, "/api/characters/list", &ta, &json!({}))?,
        200,
    )?;
    let list = roster["characters"].as_array().ok_or("no list")?;
    if list.len() != 2
        || list[0]["name"] != first
        || list[0]["house"] != "velkar"
        || list[0]["level"] != 1
        || list[0]["map"] != "grounds"
    {
        return fail(format!("roster {roster}"));
    }
    println!(
        "[login] 3 ok: name and house rules, a taken name refused across accounts, 2 made, a third refused; {} ",
        list[0]
    );

    // 4. Play.
    want(
        "play another's",
        call(&login, "/api/play", &tb, &json!({"character_id": id}))?,
        404,
    )?;
    let play = want(
        "play",
        call(&login, "/api/play", &ta, &json!({"character_id": id}))?,
        200,
    )?;
    let address = play["address"].as_str().ok_or("no address")?.to_owned();
    let ticket = unhex(play["ticket"].as_str().unwrap_or("")).ok_or("bad ticket")?;
    let mut s = Session::open(&address, "grounds", ticket, args)?;
    joined(&mut s)?;
    let sheet = s.sheet.clone().ok_or("no sheet")?;
    if sheet.id != id
        || sheet.name != first
        || sheet.house != "velkar"
        || sheet.look != [("hair".to_owned(), 2.0)]
    {
        return fail(format!(
            "joined as {} {} {} {:?}",
            sheet.id, sheet.name, sheet.house, sheet.look
        ));
    }
    println!(
        "[login] 4 ok: the ticket brought {} ({}) onto {} at {address}, look {:?}",
        sheet.name, sheet.house, play["map"], sheet.look
    );
    drop(s);

    // 5. Logout and throttling.
    want("logout", call(&login, "/api/logout", &ta, &json!({}))?, 200)?;
    want(
        "list after logout",
        call(&login, "/api/characters/list", &ta, &json!({}))?,
        401,
    )?;
    for _ in 0..10 {
        let _ = call(
            &login,
            "/api/login",
            "",
            &json!({"username": user_b, "password": "wrongpass1"}),
        )?;
    }
    want(
        "after ten failures",
        call(
            &login,
            "/api/login",
            "",
            &json!({"username": user_b, "password": pass}),
        )?,
        429,
    )?;
    println!("[login] 5 ok: logout ends the session; ten failures make the next login wait");
    println!("[login] ok: accounts, sessions, characters, play ticket, join, logout, throttle");
    Ok(())
}
