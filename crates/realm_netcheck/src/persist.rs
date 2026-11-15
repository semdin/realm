//! `realm_netcheck --persist --persist-addr <addr> --server <grounds>
//! [--restart-cmd <file>]`: characters kept in the persistence service
//! (realm_persist on PostgreSQL). Needs realm_persist and a grounds server
//! started with `--persist <addr>`.
//!
//! 1. a new character joins, walks a few metres, leaves: its save lands;
//! 2. after the map server was restarted (the check waits for the file
//!    `--restarted` to appear, written by the script that restarts it), it
//!    joins again where it left and with the same sheet;
//! 3. straight to the service: a sheet older than the stored one is refused
//!    ("stale"), a character never saved loads as none.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use realm_proto::SigningKey;
use realm_proto::control::FrameReader;
use realm_proto::persist::{PersistMsg, PersistReply, decode_reply, encode_msg};
use realm_sim::Vec3;
use realm_sim::input::MoveInput;

use crate::travel::{Session, fail, idle, joined, run_until};
use crate::{AnyResult, arg};

fn ask(addr: &str, key: [u8; 32], msg: &PersistMsg) -> AnyResult<PersistReply> {
    let mut stream = TcpStream::connect(addr)?;
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    stream.write_all(&encode_msg(&PersistMsg::Hello { key }))?;
    stream.write_all(&encode_msg(msg))?;
    let mut reader = FrameReader::default();
    let mut chunk = [0_u8; 65536];
    loop {
        if let Some(frame) = reader.next_frame()? {
            return Ok(decode_reply(&frame)?);
        }
        let n = stream.read(&mut chunk)?;
        if n == 0 {
            return fail("the persistence service closed the link");
        }
        reader.push(&chunk[..n]);
    }
}

pub fn run(args: &[String]) -> AnyResult<()> {
    let keys = PathBuf::from(arg(args, "--keys", "keys"));
    let secret: [u8; 32] = std::fs::read(keys.join("ticket.key"))?
        .try_into()
        .map_err(|_| "ticket.key must be 32 bytes")?;
    let key = SigningKey::from_bytes(&secret);
    let service: [u8; 32] = std::fs::read(keys.join("coord.key"))?
        .try_into()
        .map_err(|_| "coord.key must be 32 bytes")?;
    let persist = arg(args, "--persist-addr", "127.0.0.1:7970");
    let grounds = arg(args, "--server", "127.0.0.1:7777");
    let restarted = PathBuf::from(arg(args, "--restarted", "build/persistcheck/restarted"));
    let character =
        30_000_000 + SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() % 1_000_000;

    // 1. Join, walk, leave.
    let left_at = {
        let mut s = Session::dev(&grounds, "grounds", character, &key, args)?;
        joined(&mut s)?;
        let start = s.pos();
        run_until(
            &mut s,
            1.5,
            |_| MoveInput::from_intent(0.0, 1.0, 0.0, 0),
            |_| false,
        )?;
        run_until(&mut s, 0.6, idle, |_| false)?;
        let at = s.pos();
        if (at - start).length() < 1.0 {
            return fail(format!("the character did not walk ({start:?} -> {at:?})"));
        }
        at
    };
    // The leave's save has landed when the service has the sheet there.
    let started = Instant::now();
    let stored = loop {
        if let PersistReply::Loaded {
            result: Ok(Some(sheet)),
            ..
        } = ask(&persist, service, &PersistMsg::Load { req: 1, character })?
            && let Some(place) = sheet.place.as_ref()
            && (Vec3::new(place.pos[0], place.pos[1], place.pos[2]) - left_at).length() < 0.5
        {
            break sheet;
        }
        if started.elapsed() > Duration::from_secs(10) {
            return fail("the leave's save never reached the persistence service");
        }
        std::thread::sleep(Duration::from_millis(200));
    };
    println!(
        "[persist] 1 ok: character {character} saved where it left ({:?}), revision {}",
        left_at, stored.revision
    );

    // 2. After a restart of the map server.
    let _ = std::fs::write(restarted.with_extension("wanted"), b"restart");
    let started = Instant::now();
    while !restarted.exists() {
        if started.elapsed() > Duration::from_secs(60) {
            return fail(format!(
                "{} never appeared (the map server restart)",
                restarted.display()
            ));
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    {
        let mut s = Session::dev(&grounds, "grounds", character, &key, args)?;
        joined(&mut s)?;
        let at = s.pos();
        let sheet = s.sheet.clone().ok_or("no sheet")?;
        if (at - left_at).length() > 0.5
            || sheet.name != stored.name
            || sheet.revision < stored.revision
        {
            return fail(format!(
                "after the restart: at {at:?} (left at {left_at:?}), {} rev {} (stored {} rev {})",
                sheet.name, sheet.revision, stored.name, stored.revision
            ));
        }
        println!(
            "[persist] 2 ok: after the map server's restart it stood where it left, same sheet"
        );
    }

    // 3. Straight to the service.
    let mut older = (*stored).clone();
    older.revision = 0;
    match ask(
        &persist,
        service,
        &PersistMsg::Save {
            req: 2,
            sheet: Box::new(older),
        },
    )? {
        PersistReply::Saved {
            ok: false, error, ..
        } if error == "stale" => {}
        other => return fail(format!("an older sheet was not refused: {other:?}")),
    }
    match ask(
        &persist,
        service,
        &PersistMsg::Load {
            req: 3,
            character: u64::MAX >> 2,
        },
    )? {
        PersistReply::Loaded {
            result: Ok(None), ..
        } => {}
        other => return fail(format!("a character never saved: {other:?}")),
    }
    let mut bad = service;
    bad[0] ^= 1;
    if ask(&persist, bad, &PersistMsg::Load { req: 4, character }).is_ok() {
        return fail("the service answered a caller without the key");
    }
    println!(
        "[persist] 3 ok: an older sheet refused (stale), an unknown character loads as none, a wrong key is closed"
    );
    println!(
        "[persist] ok: saves land in PostgreSQL, survive a map restart, never go back in time"
    );
    Ok(())
}
