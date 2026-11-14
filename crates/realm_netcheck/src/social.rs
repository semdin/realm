//! `realm_netcheck --social`: two players on two map servers, linked by the
//! coordinator. A invites B (B sees the invitation), B accepts (both see a
//! party of two on two maps), A speaks to the party and shouts (B hears
//! both), A says a plain line (B, on another map, must not hear it), B
//! leaves (A's party of one dissolves). Fails on anything else.

use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use realm_data::Content;
use realm_netclient::{ClientCore, NetEvent, NetHandle};
use realm_proto::SigningKey;
use realm_proto::control::{ClientMsg, ServerMsg};
use realm_proto::coord::{CHANNEL_LOCAL, CHANNEL_PARTY, CHANNEL_SHOUT};
use realm_proto::ticket::Ticket;
use realm_sim::input::MoveInput;

use crate::{AnyResult, arg};

struct Side {
    net: NetHandle,
    core: Option<ClientCore>,
    name: String,
    map: String,
    content: Content,
    pack: realm_sim::pack::MapPack,
    lines: Vec<(u8, String, String)>,
    invites: Vec<String>,
    party: Option<realm_proto::coord::PartyView>,
    /// When it last spoke (the server takes one line per 250 ms).
    said: Instant,
}

impl Side {
    fn connect(
        server: &str,
        map: &str,
        character: u64,
        args: &[String],
        key: &SigningKey,
    ) -> AnyResult<Self> {
        let keys = PathBuf::from(arg(args, "--keys", "keys"));
        let content = Content::load(&PathBuf::from(arg(args, "--content", "content/data")))?;
        let pack = realm_data::maps::read_pack(
            &PathBuf::from(arg(args, "--maps", "world/maps")).join(format!("{map}.realmmap")),
        )?;
        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        let ticket = Ticket::new(character, character, now + 60)?.sign(key);
        let net = NetHandle::connect(
            server.parse()?,
            "localhost",
            std::fs::read(keys.join("tls.crt.der"))?,
            ticket,
        )?;
        Ok(Self {
            net,
            core: None,
            name: String::new(),
            map: map.to_owned(),
            content,
            pack,
            lines: Vec::new(),
            invites: Vec::new(),
            party: None,
            said: Instant::now(),
        })
    }

    /// Takes what arrived and runs one input tick.
    fn pump(&mut self, local_ticks: f64) -> AnyResult<()> {
        while let Some(event) = self.net.poll() {
            match event {
                NetEvent::Joined { entity, tick, .. } => {
                    let world = self.pack.world()?;
                    let stairs = realm_data::staircases(&self.content, &self.pack)?;
                    self.core = Some(ClientCore::new(world, stairs, entity, tick));
                }
                NetEvent::Refused(r) => return Err(format!("{} refused: {r}", self.map).into()),
                NetEvent::Closed(r) => return Err(format!("{} closed: {r}", self.map).into()),
                NetEvent::Datagram(bytes) => {
                    if let Some(core) = self.core.as_mut() {
                        core.on_datagram(&bytes, local_ticks);
                    }
                }
                NetEvent::Control(ServerMsg::Sheet(sheet)) => self.name = sheet.name.clone(),
                NetEvent::Control(ServerMsg::Chat {
                    channel,
                    from,
                    text,
                    ..
                }) => {
                    println!("[social] {} hears [{channel}] {from}: {text}", self.map);
                    self.lines.push((channel, from, text));
                }
                NetEvent::Control(ServerMsg::PartyInvite { from }) => self.invites.push(from),
                NetEvent::Control(ServerMsg::Party(view)) => self.party = Some(view),
                NetEvent::Control(_) => {}
            }
        }
        if let Some(core) = self.core.as_mut() {
            let bytes = core.step(MoveInput::default(), 0, 0, realm_sim::Vec3::ZERO);
            self.net.send(bytes);
        }
        Ok(())
    }

    fn say(&mut self, text: &str) {
        self.net.send_control(&ClientMsg::Chat(text.to_owned()));
        self.said = Instant::now();
    }

    /// Past the server's chat gap since its last line.
    fn may_speak(&self) -> bool {
        self.said.elapsed() > Duration::from_millis(300)
    }

    fn heard(&self, channel: u8, from: &str, text: &str) -> bool {
        self.lines
            .iter()
            .any(|(c, f, t)| *c == channel && f == from && t == text)
    }
}

pub fn run(args: &[String]) -> AnyResult<()> {
    let keys = PathBuf::from(arg(args, "--keys", "keys"));
    let secret: [u8; 32] = std::fs::read(keys.join("ticket.key"))?
        .try_into()
        .map_err(|_| "ticket.key must be 32 bytes")?;
    let key = SigningKey::from_bytes(&secret);
    let mut a = Side::connect(
        &arg(args, "--server", "127.0.0.1:7777"),
        &arg(args, "--map", "grounds"),
        arg(args, "--character", "900101").parse()?,
        args,
        &key,
    )?;
    let mut b = Side::connect(
        &arg(args, "--server-b", "127.0.0.1:7778"),
        &arg(args, "--map-b", "castle_interior"),
        arg(args, "--character-b", "900102").parse()?,
        args,
        &key,
    )?;
    let started = Instant::now();
    let period = Duration::from_secs_f64(1.0 / ClientCore::HZ);
    let mut step = 0_u32;
    let mut step_at = Instant::now();
    let mut next = Instant::now();
    let fail = |what: &str| -> AnyResult<()> { Err(format!("social check failed: {what}").into()) };
    while started.elapsed() < Duration::from_secs(40) {
        let ticks = started.elapsed().as_secs_f64() * ClientCore::HZ;
        a.pump(ticks)?;
        b.pump(ticks)?;
        let waited = step_at.elapsed();
        let ready = !a.name.is_empty() && !b.name.is_empty();
        match step {
            0 if ready && waited > Duration::from_secs(1) => {
                a.say(&format!("/invite {}", b.name));
                step = 1;
                step_at = Instant::now();
            }
            1 if b.invites.contains(&a.name) => {
                println!("[social] {} invited {}", a.name, b.name);
                b.say("/accept");
                step = 2;
                step_at = Instant::now();
            }
            2 => {
                let two = |s: &Side| {
                    s.party
                        .as_ref()
                        .is_some_and(|p| p.party != 0 && p.members.len() == 2)
                };
                if two(&a) && two(&b) && a.may_speak() {
                    let maps: Vec<String> = a
                        .party
                        .as_ref()
                        .map(|p| p.members.iter().map(|m| m.map.clone()).collect())
                        .unwrap_or_default();
                    println!("[social] party of two across {maps:?}");
                    a.say("/p hello party");
                    step = 3;
                    step_at = Instant::now();
                }
            }
            3 if b.heard(CHANNEL_PARTY, &a.name, "hello party") && a.may_speak() => {
                a.say("!hello realm");
                step = 4;
                step_at = Instant::now();
            }
            4 if b.heard(CHANNEL_SHOUT, &a.name, "hello realm") && a.may_speak() => {
                a.say("only near me");
                step = 5;
                step_at = Instant::now();
            }
            5 if waited > Duration::from_secs(1) => {
                if !a.heard(CHANNEL_LOCAL, &a.name, "only near me") {
                    return fail("the speaker did not hear its own plain line");
                }
                if b.heard(CHANNEL_LOCAL, &a.name, "only near me") {
                    return fail("a plain line crossed maps");
                }
                b.say("/leave");
                step = 6;
                step_at = Instant::now();
            }
            6 if a.party.as_ref().is_some_and(|p| p.party == 0)
                && b.party.as_ref().is_some_and(|p| p.party == 0) =>
            {
                println!("[social] B left; the party of one dissolved for both");
                println!(
                    "[social] ok: invite, accept, party view across maps, party line, shout, local stays local, leave"
                );
                return Ok(());
            }
            _ => {}
        }
        if waited > Duration::from_secs(8) && step > 0 {
            return fail(&format!("stuck at step {step}"));
        }
        next += period;
        let now = Instant::now();
        if next > now {
            std::thread::sleep(next - now);
        } else {
            next = now;
        }
    }
    fail(&format!("timed out at step {step}"))
}

/// `realm_netcheck --social-partner [--server S --map M --character C
/// --seconds N]`: a second player for a client check. It accepts the first
/// party invitation, then says a party line and shouts once, prints what it
/// hears, and stays for the given seconds.
pub fn partner(args: &[String]) -> AnyResult<()> {
    let keys = PathBuf::from(arg(args, "--keys", "keys"));
    let secret: [u8; 32] = std::fs::read(keys.join("ticket.key"))?
        .try_into()
        .map_err(|_| "ticket.key must be 32 bytes")?;
    let key = SigningKey::from_bytes(&secret);
    let mut me = Side::connect(
        &arg(args, "--server", "127.0.0.1:7777"),
        &arg(args, "--map", "grounds"),
        arg(args, "--character", "900103").parse()?,
        args,
        &key,
    )?;
    let seconds: u64 = arg(args, "--seconds", "60").parse()?;
    let started = Instant::now();
    let period = Duration::from_secs_f64(1.0 / ClientCore::HZ);
    let mut next = Instant::now();
    let (mut accepted, mut spoke, mut shouted) = (false, false, false);
    while started.elapsed() < Duration::from_secs(seconds) {
        me.pump(started.elapsed().as_secs_f64() * ClientCore::HZ)?;
        if !accepted && !me.invites.is_empty() && me.may_speak() {
            println!(
                "[partner] {} accepts {}'s invitation",
                me.name, me.invites[0]
            );
            me.say("/accept");
            accepted = true;
        } else if accepted
            && !spoke
            && me.party.as_ref().is_some_and(|p| p.party != 0)
            && me.may_speak()
        {
            me.say("/p hello from the partner");
            spoke = true;
        } else if spoke && !shouted && me.may_speak() {
            me.say("!the partner shouts");
            shouted = true;
        }
        next += period;
        let now = Instant::now();
        if next > now {
            std::thread::sleep(next - now);
        } else {
            next = now;
        }
    }
    Ok(())
}
