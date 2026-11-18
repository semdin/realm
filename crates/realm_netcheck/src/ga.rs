//! `realm_netcheck --ga --admin <addr> --token <t> --grounds <addr>
//! --castle <addr> [--config-ga <account>]`: game admins and the weather
//! across the realm. Needs the coordinator (REALM_SERVICE_TOKEN, its admin
//! surface on `--admin`, REALM_GA_ACCOUNTS holding `--config-ga` when given),
//! grounds and castle_interior. A dev ticket's account is its character id.
//!
//! 1. a player who is no GA is refused `/ga`; the account from the
//!    configuration is one;
//! 2. the admin surface makes A's account a GA: a player beside A sees its
//!    info change (the emblem) without asking; a name nobody plays gets nothing;
//! 3. A's `/ga rain on` reaches everyone on both maps, and a login after it
//!    hears the rain on joining;
//! 4. `/ga add` in chat grants nothing; the surface makes B's account a GA;
//!    B lists the GAs and stops the rain for all;
//! 5. the surface takes it back and B is refused again;
//! 6. A's new look and its wand taken off reach B unasked;
//! 7. a world boss rising on the grounds (started with --dev-boss-respawn)
//!    is heard in the castle too.

use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use realm_proto::SigningKey;
use realm_proto::control::{ClientMsg, ServerMsg};
use realm_sim::input::MoveInput;
use serde_json::json;

use crate::maintenance::{expect, http, login};
use crate::travel::{Session, fail};
use crate::{AnyResult, arg};

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

fn said(s: &Session, what: &str) -> bool {
    s.events
        .iter()
        .any(|m| matches!(m, ServerMsg::Chat { text, .. } if text.contains(what)))
}

fn rain(s: &Session) -> Option<bool> {
    s.events.iter().rev().find_map(|m| match m {
        ServerMsg::Weather { rain } => Some(*rain),
        _ => None,
    })
}

fn name_of(s: &Session) -> String {
    s.sheet.as_ref().map(|x| x.name.clone()).unwrap_or_default()
}

fn command(s: &mut Session, text: &str) -> AnyResult<()> {
    // Chat is paced (8 ticks a line).
    std::thread::sleep(Duration::from_millis(400));
    s.net.send_control(&ClientMsg::Chat(text.to_owned()));
    Ok(())
}

pub fn run(args: &[String]) -> AnyResult<()> {
    let admin = arg(args, "--admin", "127.0.0.1:8083");
    let token = arg(args, "--token", "check-token");
    let grounds = arg(args, "--grounds", "127.0.0.1:7777");
    let castle = arg(args, "--castle", "127.0.0.1:7778");
    let keys = PathBuf::from(arg(args, "--keys", "keys"));
    let secret: [u8; 32] = std::fs::read(keys.join("ticket.key"))?
        .try_into()
        .map_err(|_| "ticket.key must be 32 bytes")?;
    let key = SigningKey::from_bytes(&secret);
    let base = 620_000 + SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() % 1000 * 4;

    let mut a = login(&grounds, "grounds", base, &key, args)?;
    let mut b = login(&grounds, "grounds", base + 1, &key, args)?;
    let mut d = login(&castle, "castle_interior", base + 2, &key, args)?;
    pump_all(&mut [&mut a, &mut b, &mut d], 1.5, |_| false)?;
    let (an, bn) = (name_of(&a), name_of(&b));
    if an.is_empty() || bn.is_empty() || an == bn {
        return fail(format!("names {an:?} {bn:?}"));
    }

    // 1. No GA.
    command(&mut b, "/ga rain on")?;
    if !pump_all(&mut [&mut a, &mut b, &mut d], 3.0, |all| {
        said(all[1], "Only a GA")
    })? {
        return fail("B's /ga was not refused");
    }
    if args.iter().any(|a| a == "--config-ga") {
        let account: u64 = arg(args, "--config-ga", "").parse()?;
        let mut c = login(&castle, "castle_interior", account, &key, args)?;
        command(&mut c, "/ga list")?;
        if !pump_all(&mut [&mut c], 3.0, |all| said(all[0], "GAs:"))? {
            return fail("the configured account is not a GA");
        }
    }
    println!("[ga] 1 ok: /ga refused to a player who is no GA, open to the configured account");

    // 2. The surface makes A's account a GA; B sees the emblem come.
    expect(
        "a name nobody plays",
        http(
            &admin,
            "POST",
            "/admin/ga",
            &token,
            &json!({"name": "NobodyPlaysThis", "on": true}),
        )?,
        404,
        |_| true,
    )?;
    expect(
        "make A a GA",
        http(
            &admin,
            "POST",
            "/admin/ga",
            &token,
            &json!({"name": an, "on": true}),
        )?,
        200,
        |v| v["changed"] == true,
    )?;
    let a_id = a.core.as_ref().map_or(0, realm_netclient::ClientCore::me);
    let emblem = |s: &Session, on: bool| {
        s.events.iter().any(|m| {
            matches!(m, ServerMsg::PlayerInfo { entity, ga, .. } if *entity == a_id && *ga == on)
        })
    };
    if !pump_all(&mut [&mut a, &mut b, &mut d], 3.0, |all| {
        emblem(all[1], true)
    })? {
        return fail("B never saw A's emblem come");
    }
    b.net.send_control(&ClientMsg::Inspect(a_id));
    println!("[ga] 2 ok: A is a GA; B saw it at once");

    // 3. Rain for the realm.
    command(&mut a, "/ga rain on")?;
    if !pump_all(&mut [&mut a, &mut b, &mut d], 4.0, |all| {
        said(all[0], "Rain started.") && all.iter().all(|s| rain(s) == Some(true))
    })? {
        return fail(format!(
            "the rain did not reach everyone: {:?} {:?} {:?}",
            rain(&a),
            rain(&b),
            rain(&d)
        ));
    }
    {
        let mut e = login(&castle, "castle_interior", base + 3, &key, args)?;
        pump_all(&mut [&mut e], 1.0, |all| rain(all[0]).is_some())?;
        if rain(&e) != Some(true) {
            return fail(format!("a login after the rain heard {:?}", rain(&e)));
        }
    }
    println!("[ga] 3 ok: A's rain reached both maps and a later login");

    // 4. Chat grants nothing; the surface makes B's account a GA.
    command(&mut a, &format!("/ga add {bn}"))?;
    if !pump_all(&mut [&mut a, &mut b, &mut d], 3.0, |all| {
        said(all[0], "server configuration")
    })? {
        return fail("A's /ga add was not turned down");
    }
    let b_account = base + 1;
    expect(
        "make B a GA",
        http(
            &admin,
            "POST",
            "/admin/ga",
            &token,
            &json!({"account": b_account, "on": true}),
        )?,
        200,
        |v| v["changed"] == true,
    )?;
    pump_all(&mut [&mut a, &mut b, &mut d], 1.0, |_| false)?;
    command(&mut b, "/ga list")?;
    if !pump_all(&mut [&mut a, &mut b, &mut d], 3.0, |all| {
        all[1].events.iter().any(|m| {
            matches!(m, ServerMsg::Chat { text, .. }
                if text.starts_with("GAs:") && text.contains(&an) && text.contains(&bn))
        })
    })? {
        return fail("B's /ga list did not name both");
    }
    command(&mut b, "/ga yağmur kapat")?;
    if !pump_all(&mut [&mut a, &mut b, &mut d], 4.0, |all| {
        all.iter().all(|s| rain(s) == Some(false))
    })? {
        return fail("B's rain off did not reach everyone");
    }
    println!(
        "[ga] 4 ok: chat granted nothing; B's account made a GA, B listed both and stopped the rain (in Turkish)"
    );

    // 5. Taken back.
    expect(
        "take B back",
        http(
            &admin,
            "POST",
            "/admin/ga",
            &token,
            &json!({"account": b_account, "on": false}),
        )?,
        200,
        |v| v["changed"] == true,
    )?;
    pump_all(&mut [&mut a, &mut b, &mut d], 1.0, |_| false)?;
    b.events.clear();
    command(&mut b, "/ga rain on")?;
    if !pump_all(&mut [&mut a, &mut b, &mut d], 3.0, |all| {
        said(all[1], "Only a GA")
    })? {
        return fail("B's /ga was not refused after removal");
    }
    println!("[ga] 5 ok: B's account taken back and refused");

    // 6. What others see of A, pushed when it changes. The look change and
    // the wand taken off go out together, the item request on the sheet
    // from before the look: a look is no reason to call it stale.
    b.events.clear();
    let wand = realm_rules::Slot::MainHand as u8;
    let revision = a.sheet.as_ref().map_or(0, |x| x.revision);
    let free = a
        .sheet
        .as_ref()
        .and_then(|x| x.bag.iter().position(Option::is_none))
        .ok_or("no free bag cell")? as u8;
    a.net
        .send_control(&ClientMsg::Look(vec![("hair".to_owned(), 3.0)]));
    a.net.send_control(&ClientMsg::Item {
        op_id: 1,
        revision,
        op: realm_rules::ItemOp::Move {
            from: realm_rules::Cell::Worn(realm_rules::Slot::MainHand),
            to: realm_rules::Cell::Bag(free),
        },
    });
    let looked = |s: &Session| {
        s.events.iter().any(|m| {
            matches!(m, ServerMsg::PlayerInfo { entity, look, .. }
                if *entity == a_id && look.iter().any(|(k, v)| k == "hair" && *v == 3.0))
        })
    };
    let unarmed = |s: &Session| {
        s.events.iter().any(|m| {
            matches!(m, ServerMsg::PlayerInfo { entity, gear, .. }
                if *entity == a_id && !gear.iter().any(|(slot, _, _)| *slot == wand))
        })
    };
    if !pump_all(&mut [&mut a, &mut b, &mut d], 4.0, |all| {
        looked(all[1]) && unarmed(all[1])
    })? {
        let answers: Vec<String> = a
            .events
            .iter()
            .filter_map(|m| match m {
                ServerMsg::ItemResult { ok, reason, .. } => Some(format!("{ok} {reason}")),
                _ => None,
            })
            .collect();
        return fail(format!(
            "B did not see both A's look ({}) and its wand off ({}); A's item answers {answers:?}",
            looked(&b),
            unarmed(&b)
        ));
    }
    println!("[ga] 6 ok: A's new look and its wand taken off reached B unasked");

    // 7. A world boss rising on the grounds (--dev-boss-respawn) is heard
    // in the castle too, as the realm's.
    let risen = |s: &Session| {
        s.events.iter().any(|m| {
            matches!(m, ServerMsg::Notice { kind, place, .. }
                if kind == "boss_spawned" && place == "grounds")
        })
    };
    if !pump_all(&mut [&mut a, &mut b, &mut d], 70.0, |all| {
        risen(all[0]) && risen(all[2])
    })? {
        return fail("the world boss rising on the grounds was not heard on both maps");
    }
    println!("[ga] 7 ok: a world boss rising on the grounds was heard in the castle too");
    println!("[ga] ok: refusal, configured account, surface grant, emblem, realm rain, list");
    Ok(())
}
