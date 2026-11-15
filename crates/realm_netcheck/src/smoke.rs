//! `realm_netcheck --smoke --server <addr> [--map grounds] [--keys keys]
//! [--character 9]`: the deploy's last word (deploy/realm-deploy). One
//! player joins the map with a ticket signed by keys/ticket.key, stands on
//! the ground with its sheet, takes a second of snapshots and leaves; done
//! in a few seconds or it fails within 10. Character 9 is reserved for it:
//! the login service numbers characters from 10,000,000, so the smoke
//! character never meets a player's.

use std::path::PathBuf;
use std::time::Instant;

use realm_proto::SigningKey;

use crate::travel::{Session, fail, idle, joined, run_until};
use crate::{AnyResult, arg};

pub fn run(args: &[String]) -> AnyResult<()> {
    let started = Instant::now();
    let keys = PathBuf::from(arg(args, "--keys", "keys"));
    let secret: [u8; 32] = std::fs::read(keys.join("ticket.key"))?
        .try_into()
        .map_err(|_| "ticket.key must be 32 bytes")?;
    let key = SigningKey::from_bytes(&secret);
    let server = arg(args, "--server", "127.0.0.1:7777");
    let map = arg(args, "--map", "grounds");
    let character: u64 = arg(args, "--character", "9").parse()?;
    let mut s = Session::dev(&server, &map, character, &key, args)?;
    joined(&mut s)?;
    let at = s.pos();
    let before = s.corrections;
    run_until(&mut s, 1.0, idle, |_| false)?;
    if let Some(why) = &s.closed {
        return fail(format!("{map} closed the session: {why}"));
    }
    if s.corrections != before {
        return fail(format!(
            "{} corrections standing still",
            s.corrections - before
        ));
    }
    println!(
        "[smoke] ok in {:.1} s: character {character} joined {map} at {at:?} and stood a second",
        started.elapsed().as_secs_f64()
    );
    Ok(())
}
