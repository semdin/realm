//! realm_coord --bind 127.0.0.1:7900 --keys keys
//!
//! The coordinator: who is online on which map, the parties, and what
//! crosses maps (shouts, party lines, invitations, party views). Map servers
//! connect to it and prove they hold keys/coord.key; players never do. A map
//! server that reconnects tells it again who is on its map.
//!
//! Parties follow the old game's PartyBook (five at most, an invitation
//! lasts 30 s, the first member leads when the leader leaves, a party of one
//! dissolves) with its three faults fixed: a kick tells everyone, the
//! leader included; an invitation from a player who went offline or changed
//! party no longer founds or joins a party; a departing player's own
//! invitations go with them.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use realm_proto::control::FrameReader;
use realm_proto::coord::{
    CHANNEL_PARTY, CHANNEL_SHOUT, CHANNEL_SYSTEM, CoordMsg, MapMsg, PARTY_MAX, PartyCmd,
    PartyMember, PartyView, decode_map, encode_coord,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, mpsc};

type AnyResult<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// An invitation stays open this long.
const INVITE_TTL: Duration = Duration::from_secs(30);

struct Online {
    name: String,
    house: String,
    level: u16,
    link: u64,
    map: String,
    hp: u32,
    max_hp: u32,
    mana: u32,
    max_mana: u32,
    dead: bool,
}

struct Party {
    leader: u64,
    members: Vec<u64>,
}

struct Invite {
    from: u64,
    /// The inviter's party when it invited (None: it had none).
    party: Option<u64>,
    expires: Instant,
}

#[derive(Default)]
struct Book {
    links: HashMap<u64, (String, mpsc::UnboundedSender<CoordMsg>)>,
    online: HashMap<u64, Online>,
    by_name: HashMap<String, u64>,
    parties: HashMap<u64, Party>,
    party_of: HashMap<u64, u64>,
    invites: HashMap<u64, Invite>,
    next_party: u64,
    /// The view each member was last sent (only changes go out).
    sent: HashMap<u64, PartyView>,
}

impl Book {
    fn send(&self, character: u64, msg: CoordMsg) {
        if let Some(link) = self.online.get(&character).map(|o| o.link)
            && let Some((_, tx)) = self.links.get(&link)
        {
            let _ = tx.send(msg);
        }
    }

    fn tell(&self, character: u64, text: impl Into<String>) {
        self.send(
            character,
            CoordMsg::Line {
                to: character,
                channel: CHANNEL_SYSTEM,
                from: String::new(),
                text: text.into(),
            },
        );
    }

    fn named(&self, name: &str) -> Option<u64> {
        self.by_name.get(&name.to_lowercase()).copied()
    }

    fn name(&self, character: u64) -> String {
        self.online
            .get(&character)
            .map(|o| o.name.clone())
            .unwrap_or_default()
    }

    fn view(&self, party: u64) -> PartyView {
        let Some(p) = self.parties.get(&party) else {
            return PartyView::default();
        };
        PartyView {
            party,
            leader: p.leader,
            members: p
                .members
                .iter()
                .map(|c| {
                    let o = self.online.get(c);
                    PartyMember {
                        character: *c,
                        name: o.map(|o| o.name.clone()).unwrap_or_default(),
                        house: o.map(|o| o.house.clone()).unwrap_or_default(),
                        level: o.map_or(1, |o| o.level),
                        hp: o.map_or(0, |o| o.hp),
                        max_hp: o.map_or(0, |o| o.max_hp),
                        mana: o.map_or(0, |o| o.mana),
                        max_mana: o.map_or(0, |o| o.max_mana),
                        map: o.map(|o| o.map.clone()).unwrap_or_default(),
                        dead: o.is_some_and(|o| o.dead),
                    }
                })
                .collect(),
        }
    }

    /// Sends `character` its party view if it changed.
    fn refresh(&mut self, character: u64) {
        let view = self
            .party_of
            .get(&character)
            .map_or_else(PartyView::default, |p| self.view(*p));
        if self.sent.get(&character) == Some(&view) {
            return;
        }
        self.sent.insert(character, view.clone());
        self.send(
            character,
            CoordMsg::Party {
                to: character,
                view,
            },
        );
    }

    fn refresh_party(&mut self, party: u64) {
        let members = self
            .parties
            .get(&party)
            .map(|p| p.members.clone())
            .unwrap_or_default();
        for m in members {
            self.refresh(m);
        }
    }

    /// Takes `character` out of its party: the first member leads if the
    /// leader went, a party of one dissolves. Everyone concerned is told.
    fn remove_from_party(&mut self, character: u64) {
        let Some(party) = self.party_of.remove(&character) else {
            return;
        };
        let mut left = Vec::new();
        if let Some(p) = self.parties.get_mut(&party) {
            p.members.retain(|m| *m != character);
            if p.leader == character
                && let Some(first) = p.members.first()
            {
                p.leader = *first;
            }
            left = p.members.clone();
        }
        if left.len() <= 1 {
            self.parties.remove(&party);
            for m in &left {
                self.party_of.remove(m);
            }
        }
        self.refresh(character);
        for m in left {
            self.refresh(m);
        }
    }

    fn party_cmd(&mut self, from: u64, cmd: PartyCmd) {
        match cmd {
            PartyCmd::Invite(name) => self.invite(from, &name),
            PartyCmd::Accept => self.accept(from),
            PartyCmd::Decline => match self.invites.remove(&from) {
                Some(inv) => {
                    let name = self.name(from);
                    self.tell(from, "You declined the party invitation.");
                    self.tell(inv.from, format!("{name} declined your party invitation."));
                }
                None => self.tell(from, "You have no party invitation."),
            },
            PartyCmd::Leave => {
                if self.party_of.contains_key(&from) {
                    self.remove_from_party(from);
                    self.tell(from, "You left the party.");
                } else {
                    self.tell(from, "You are not in a party.");
                }
            }
            PartyCmd::Kick(name) => self.leader_act(from, &name, true),
            PartyCmd::Promote(name) => self.leader_act(from, &name, false),
        }
    }

    fn invite(&mut self, from: u64, name: &str) {
        let Some(target) = self.named(name) else {
            return self.tell(from, format!("{name} is not online."));
        };
        if target == from {
            return self.tell(from, "You cannot invite yourself.");
        }
        if self.party_of.contains_key(&target) {
            return self.tell(
                from,
                format!("{} is already in a party.", self.name(target)),
            );
        }
        let party = self.party_of.get(&from).copied();
        if let Some(p) = party.and_then(|p| self.parties.get(&p)) {
            if p.leader != from {
                return self.tell(from, "Only the party leader can invite.");
            }
            if p.members.len() >= PARTY_MAX {
                return self.tell(from, "Your party is full.");
            }
        }
        self.invites.insert(
            target,
            Invite {
                from,
                party,
                expires: Instant::now() + INVITE_TTL,
            },
        );
        let from_name = self.name(from);
        self.send(
            target,
            CoordMsg::Invite {
                to: target,
                from: from_name,
            },
        );
        self.tell(
            from,
            format!("Party invitation sent to {}.", self.name(target)),
        );
    }

    fn accept(&mut self, character: u64) {
        let Some(inv) = self.invites.remove(&character) else {
            return self.tell(character, "You have no party invitation.");
        };
        if Instant::now() > inv.expires || !self.online.contains_key(&inv.from) {
            return self.tell(character, "The invitation is no longer valid.");
        }
        if self.party_of.contains_key(&character) {
            return self.tell(character, "You are already in a party.");
        }
        // The inviter must still be where it invited from: solo, or leading
        // the same party.
        let now_party = self.party_of.get(&inv.from).copied();
        if now_party != inv.party
            || now_party.is_some_and(|p| self.parties.get(&p).is_none_or(|p| p.leader != inv.from))
        {
            return self.tell(character, "The invitation is no longer valid.");
        }
        let party = match now_party {
            Some(p) => {
                let full = self
                    .parties
                    .get(&p)
                    .is_none_or(|p| p.members.len() >= PARTY_MAX);
                if full {
                    return self.tell(character, "That party is full.");
                }
                p
            }
            None => {
                self.next_party += 1;
                let p = self.next_party;
                self.parties.insert(
                    p,
                    Party {
                        leader: inv.from,
                        members: vec![inv.from],
                    },
                );
                self.party_of.insert(inv.from, p);
                p
            }
        };
        if let Some(p) = self.parties.get_mut(&party) {
            p.members.push(character);
        }
        self.party_of.insert(character, party);
        let name = self.name(character);
        let members = self
            .parties
            .get(&party)
            .map(|p| p.members.clone())
            .unwrap_or_default();
        for m in &members {
            if *m != character {
                self.tell(*m, format!("{name} joined the party."));
            }
        }
        self.tell(character, "You joined the party.");
        self.refresh_party(party);
    }

    fn leader_act(&mut self, from: u64, name: &str, kick: bool) {
        let Some(party) = self.party_of.get(&from).copied() else {
            return self.tell(from, "You are not in a party.");
        };
        if self.parties.get(&party).is_none_or(|p| p.leader != from) {
            return self.tell(from, "Only the party leader can do that.");
        }
        let Some(target) = self
            .named(name)
            .filter(|t| self.party_of.get(t) == Some(&party) && *t != from)
        else {
            return self.tell(from, format!("{name} is not in your party."));
        };
        let target_name = self.name(target);
        if kick {
            let members = self
                .parties
                .get(&party)
                .map(|p| p.members.clone())
                .unwrap_or_default();
            self.remove_from_party(target);
            self.tell(target, "You were removed from the party.");
            for m in members.into_iter().filter(|m| *m != target) {
                self.tell(m, format!("{target_name} was removed from the party."));
            }
        } else {
            if let Some(p) = self.parties.get_mut(&party) {
                p.leader = target;
            }
            let members = self
                .parties
                .get(&party)
                .map(|p| p.members.clone())
                .unwrap_or_default();
            for m in members {
                self.tell(m, format!("{target_name} now leads the party."));
            }
            self.refresh_party(party);
        }
    }

    fn offline(&mut self, character: u64) {
        self.remove_from_party(character);
        self.invites.remove(&character);
        self.invites.retain(|_, inv| inv.from != character);
        self.sent.remove(&character);
        if let Some(o) = self.online.remove(&character) {
            self.by_name.remove(&o.name.to_lowercase());
        }
    }

    fn handle(&mut self, link: u64, msg: MapMsg) {
        match msg {
            MapMsg::Hello { .. } => {}
            MapMsg::Online {
                character,
                name,
                house,
                level,
            } => {
                let map = self
                    .links
                    .get(&link)
                    .map(|(m, _)| m.clone())
                    .unwrap_or_default();
                // A character known on another map is moving: keep its party.
                let prev = self.online.remove(&character);
                self.by_name.insert(name.to_lowercase(), character);
                self.online.insert(
                    character,
                    Online {
                        name,
                        house,
                        level,
                        link,
                        map,
                        hp: prev.as_ref().map_or(0, |p| p.hp),
                        max_hp: prev.as_ref().map_or(0, |p| p.max_hp),
                        mana: prev.as_ref().map_or(0, |p| p.mana),
                        max_mana: prev.as_ref().map_or(0, |p| p.max_mana),
                        dead: false,
                    },
                );
                self.sent.remove(&character);
                self.refresh(character);
                if let Some(p) = self.party_of.get(&character).copied() {
                    self.refresh_party(p);
                }
            }
            MapMsg::Offline { character } => {
                // Only the map that holds it may take it offline (a move
                // to another map came first).
                if self.online.get(&character).is_some_and(|o| o.link == link) {
                    self.offline(character);
                }
            }
            MapMsg::Vitals {
                character,
                level,
                hp,
                max_hp,
                mana,
                max_mana,
                dead,
            } => {
                if let Some(o) = self.online.get_mut(&character) {
                    (o.level, o.hp, o.max_hp, o.mana, o.max_mana, o.dead) =
                        (level, hp, max_hp, mana, max_mana, dead);
                }
                if let Some(p) = self.party_of.get(&character).copied() {
                    self.refresh_party(p);
                }
            }
            MapMsg::Shout { from, text } => {
                let name = self.name(from);
                for (_, tx) in self.links.values() {
                    let _ = tx.send(CoordMsg::Broadcast {
                        channel: CHANNEL_SHOUT,
                        from: name.clone(),
                        text: text.clone(),
                    });
                }
            }
            MapMsg::PartyChat { from, text } => {
                let Some(party) = self.party_of.get(&from).copied() else {
                    return self.tell(from, "You are not in a party.");
                };
                let name = self.name(from);
                let members = self
                    .parties
                    .get(&party)
                    .map(|p| p.members.clone())
                    .unwrap_or_default();
                for m in members {
                    self.send(
                        m,
                        CoordMsg::Line {
                            to: m,
                            channel: CHANNEL_PARTY,
                            from: name.clone(),
                            text: text.clone(),
                        },
                    );
                }
            }
            MapMsg::Party { from, cmd } => self.party_cmd(from, cmd),
        }
    }

    /// A map server went away: everyone it held goes offline.
    fn drop_link(&mut self, link: u64) {
        self.links.remove(&link);
        let gone: Vec<u64> = self
            .online
            .iter()
            .filter(|(_, o)| o.link == link)
            .map(|(c, _)| *c)
            .collect();
        for c in gone {
            self.offline(c);
        }
    }

    fn sweep(&mut self) {
        let now = Instant::now();
        let expired: Vec<(u64, u64)> = self
            .invites
            .iter()
            .filter(|(_, i)| now > i.expires)
            .map(|(to, i)| (*to, i.from))
            .collect();
        for (to, from) in expired {
            self.invites.remove(&to);
            let name = self.name(to);
            self.tell(from, format!("Your party invitation to {name} expired."));
        }
    }
}

struct Options {
    bind: SocketAddr,
    keys: PathBuf,
}

fn options() -> AnyResult<Options> {
    let mut o = Options {
        bind: "127.0.0.1:7900".parse()?,
        keys: PathBuf::from("keys"),
    };
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        let value = it.next().ok_or_else(|| format!("{arg} needs a value"))?;
        match arg.as_str() {
            "--bind" => o.bind = value.parse()?,
            "--keys" => o.keys = PathBuf::from(value),
            other => return Err(format!("unknown option {other}").into()),
        }
    }
    Ok(o)
}

async fn link(stream: TcpStream, id: u64, key: [u8; 32], book: Arc<Mutex<Book>>) -> AnyResult<()> {
    stream.set_nodelay(true)?;
    let (mut read, mut write) = stream.into_split();
    let mut reader = FrameReader::default();
    let mut chunk = vec![0_u8; 16 * 1024];
    let hello = loop {
        if let Some(frame) = reader.next_frame()? {
            break decode_map(&frame)?;
        }
        let n = read.read(&mut chunk).await?;
        if n == 0 {
            return Err("closed before hello".into());
        }
        reader.push(&chunk[..n]);
    };
    let MapMsg::Hello { key: theirs, map } = hello else {
        return Err("first frame is not a hello".into());
    };
    if theirs != key {
        return Err("wrong coordinator key".into());
    }
    println!("[coord] map server {id} holds {map}");
    let (tx, mut rx) = mpsc::unbounded_channel::<CoordMsg>();
    book.lock().await.links.insert(id, (map.clone(), tx));
    let writer = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if write.write_all(&encode_coord(&msg)).await.is_err() {
                break;
            }
        }
    });
    let result: AnyResult<()> = async {
        loop {
            while let Some(frame) = reader.next_frame()? {
                let msg = decode_map(&frame)?;
                book.lock().await.handle(id, msg);
            }
            let n = read.read(&mut chunk).await?;
            if n == 0 {
                return Ok(());
            }
            reader.push(&chunk[..n]);
        }
    }
    .await;
    book.lock().await.drop_link(id);
    writer.abort();
    println!("[coord] map server {id} ({map}) left");
    result
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> AnyResult<()> {
    let o = options()?;
    let key: [u8; 32] = std::fs::read(o.keys.join("coord.key"))?
        .try_into()
        .map_err(|_| "coord.key must be 32 bytes")?;
    let listener = TcpListener::bind(o.bind).await?;
    println!("[coord] listening on {}", o.bind);
    let book = Arc::new(Mutex::new(Book::default()));
    {
        let book = book.clone();
        tokio::spawn(async move {
            let mut every = tokio::time::interval(Duration::from_secs(1));
            loop {
                every.tick().await;
                book.lock().await.sweep();
            }
        });
    }
    let mut next = 0_u64;
    loop {
        let (stream, from) = listener.accept().await?;
        next += 1;
        let book = book.clone();
        tokio::spawn(async move {
            if let Err(e) = link(stream, next, key, book).await {
                eprintln!("[coord] link from {from}: {e}");
            }
        });
    }
}
