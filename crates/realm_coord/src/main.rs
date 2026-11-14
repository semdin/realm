//! realm_coord --bind 127.0.0.1:7900 --keys keys
//!
//! The coordinator: who is online on which map, the parties, and what
//! crosses maps (shouts, party lines, invitations, party views). Map servers
//! connect to it and prove they hold keys/coord.key; players never do. A map
//! server that reconnects tells it again who is on its map.
//!
//! It owns every character's seat: on one map, or in transit with its
//! sheet. A map admits nobody it has not claimed; a character playing
//! elsewhere is evicted there first, and the newest sheet always goes with
//! the seat, so one character is never in two worlds and nothing it carries
//! can be in two places. A traveller's map saves it, releases it with the
//! save landed, and the coordinator signs it a ticket (keys/ticket.key) for
//! the destination, where a seat was reserved before it left.
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

use realm_proto::SigningKey;
use realm_proto::control::FrameReader;
use realm_proto::coord::{
    CHANNEL_PARTY, CHANNEL_SHOUT, CHANNEL_SYSTEM, CoordMsg, MapMsg, PARTY_MAX, PartyCmd,
    PartyMember, PartyView, decode_map, encode_coord,
};
use realm_proto::ticket::Ticket;
use realm_rules::CharacterSheet;
use realm_rules::travel::Arrival;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, mpsc};

type AnyResult<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// An invitation stays open this long.
const INVITE_TTL: Duration = Duration::from_secs(30);
/// A reserved seat waits this long for its traveller to leave.
const RESERVE_TTL: Duration = Duration::from_secs(20);
/// A traveller's sheet is held this long for it to arrive (or log in again
/// anywhere); after that the stored copy serves.
const TRANSIT_TTL: Duration = Duration::from_secs(15 * 60);
/// A travel ticket is good this long.
const TICKET_SECONDS: u64 = 60;

/// One map server.
struct Link {
    map: String,
    address: String,
    capacity: u16,
    tx: mpsc::UnboundedSender<CoordMsg>,
}

/// Where a character is.
enum Seat {
    /// In the world of `link` (or being admitted there). `claim`: a login
    /// on another map waiting for this one to let it go.
    On {
        link: u64,
        claim: Option<(u64, u64)>,
    },
    /// Released to travel: its sheet waits for the destination's claim.
    Transit {
        sheet: Box<CharacterSheet>,
        arrival: Arrival,
        since: Instant,
    },
}

/// A seat held on `map` for a traveller.
struct Reservation {
    map: String,
    address: String,
    expires: Instant,
}

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
    links: HashMap<u64, Link>,
    seats: HashMap<u64, Seat>,
    reservations: HashMap<u64, Reservation>,
    /// Signs travel tickets (None: nobody may travel between maps).
    ticket_key: Option<SigningKey>,
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
        if let Some(link) = self.online.get(&character).map(|o| o.link) {
            self.to_link(link, msg);
        }
    }

    fn to_link(&self, link: u64, msg: CoordMsg) {
        if let Some(l) = self.links.get(&link) {
            let _ = l.tx.send(msg);
        }
    }

    fn map_of(&self, link: u64) -> String {
        self.links
            .get(&link)
            .map(|l| l.map.clone())
            .unwrap_or_default()
    }

    /// Tells every map which maps are open.
    fn maps_changed(&self) {
        let mut maps: Vec<String> = self.links.values().map(|l| l.map.clone()).collect();
        maps.sort();
        maps.dedup();
        for l in self.links.values() {
            let _ = l.tx.send(CoordMsg::Maps(maps.clone()));
        }
    }

    /// Lets `conn` on `link` bring `character` in, with the newest sheet
    /// when there is one; the seat moves there.
    fn admit(
        &mut self,
        link: u64,
        conn: u64,
        character: u64,
        sheet: Option<Box<CharacterSheet>>,
        arrival: Option<Arrival>,
    ) {
        self.reservations.remove(&character);
        self.seats.insert(character, Seat::On { link, claim: None });
        let map = self.map_of(link);
        let arrival = arrival.filter(|a| a.map == map);
        self.to_link(
            link,
            CoordMsg::Admit {
                conn,
                character,
                sheet,
                arrival,
            },
        );
    }

    fn refuse(&self, (link, conn): (u64, u64)) {
        self.to_link(
            link,
            CoordMsg::Refuse {
                conn,
                reason: "logged in elsewhere".to_owned(),
            },
        );
    }

    /// A login for `character` on `link`.
    fn claim(&mut self, link: u64, conn: u64, character: u64) {
        match self.seats.remove(&character) {
            None => self.admit(link, conn, character, None, None),
            Some(Seat::Transit { sheet, arrival, .. }) => {
                self.admit(link, conn, character, Some(sheet), Some(arrival));
            }
            Some(Seat::On { link: here, claim })
                if here == link || !self.links.contains_key(&here) =>
            {
                if let Some(waiting) = claim {
                    self.refuse(waiting);
                }
                // The same map takes over its own player (or the old map is
                // gone and holds nothing).
                self.admit(link, conn, character, None, None);
            }
            Some(Seat::On { link: here, claim }) => {
                if let Some(waiting) = claim {
                    self.refuse(waiting);
                }
                self.seats.insert(
                    character,
                    Seat::On {
                        link: here,
                        claim: Some((link, conn)),
                    },
                );
                self.to_link(here, CoordMsg::Evict { character });
            }
        }
    }

    /// `link` let `character` go with its save landed.
    fn release(
        &mut self,
        link: u64,
        account: u64,
        character: u64,
        sheet: Box<CharacterSheet>,
        arrival: Option<Arrival>,
    ) {
        let claim = match self.seats.get(&character) {
            Some(Seat::On { link: here, claim }) if *here == link => *claim,
            // Not this map's to give (a newer seat exists).
            _ => return,
        };
        if let Some((l, c)) = claim {
            // A waiting login gets it, wherever it was going.
            self.admit(l, c, character, Some(sheet), arrival);
            return;
        }
        let Some(arrival) = arrival else {
            self.seats.remove(&character);
            self.offline(character);
            return;
        };
        let address = self
            .reservations
            .get(&character)
            .map(|r| r.address.clone())
            .or_else(|| {
                self.links
                    .values()
                    .find(|l| l.map == arrival.map)
                    .map(|l| l.address.clone())
            });
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        let ticket = match (&self.ticket_key, &address) {
            (Some(key), Some(_)) => Ticket::new(account, character, now + TICKET_SECONDS)
                .ok()
                .map(|t| t.sign(key)),
            _ => None,
        };
        let map = arrival.map.clone();
        self.seats.insert(
            character,
            Seat::Transit {
                sheet,
                arrival,
                since: Instant::now(),
            },
        );
        match (ticket, address) {
            (Some(ticket), Some(address)) => self.to_link(
                link,
                CoordMsg::Travel {
                    character,
                    map,
                    address,
                    ticket,
                },
            ),
            _ => eprintln!(
                "[coord] character {character} cannot travel to {map}: no ticket key or no such map"
            ),
        }
    }

    /// A seat on `map` for `character`, if it is open and has room.
    fn reserve(&mut self, character: u64, map: &str) -> Result<(), &'static str> {
        if self.ticket_key.is_none() {
            return Err("map_unavailable");
        }
        let Some((&target, link)) = self.links.iter().find(|(_, l)| l.map == map) else {
            return Err("map_unavailable");
        };
        let seated = self
            .seats
            .values()
            .filter(|s| matches!(s, Seat::On { link, .. } if *link == target))
            .count();
        let held = self
            .reservations
            .iter()
            .filter(|(c, r)| **c != character && r.map == map)
            .count();
        if seated + held >= usize::from(link.capacity) {
            return Err("map_full");
        }
        let address = link.address.clone();
        self.reservations.insert(
            character,
            Reservation {
                map: map.to_owned(),
                address,
                expires: Instant::now() + RESERVE_TTL,
            },
        );
        Ok(())
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
            MapMsg::Claim { conn, character } => self.claim(link, conn, character),
            MapMsg::Release {
                character,
                account,
                sheet,
                arrival,
            } => self.release(link, account, character, sheet, arrival),
            MapMsg::Gone { character } => {
                if let Some(Seat::On { link: here, claim }) = self.seats.get(&character)
                    && *here == link
                {
                    match *claim {
                        Some((l, c)) => self.admit(l, c, character, None, None),
                        None => {
                            self.seats.remove(&character);
                        }
                    }
                }
            }
            MapMsg::Reserve { character, map } => {
                let answer = self.reserve(character, &map);
                self.to_link(
                    link,
                    CoordMsg::Reserved {
                        character,
                        ok: answer.is_ok(),
                        reason: answer.err().unwrap_or("").to_owned(),
                    },
                );
            }
            MapMsg::Online {
                character,
                name,
                house,
                level,
            } => {
                // A map that reconnected says again who it holds.
                self.seats
                    .entry(character)
                    .or_insert(Seat::On { link, claim: None });
                let map = self.map_of(link);
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
                for l in self.links.values() {
                    let _ = l.tx.send(CoordMsg::Broadcast {
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

    /// A map server went away: everyone it held goes offline (its saves
    /// are what they stored); a login waiting on it gets its seat.
    /// Travellers in transit keep their party.
    fn drop_link(&mut self, link: u64) {
        self.links.remove(&link);
        let seated: Vec<(u64, Option<(u64, u64)>)> = self
            .seats
            .iter()
            .filter_map(|(c, s)| match s {
                Seat::On { link: l, claim } if *l == link => Some((*c, *claim)),
                _ => None,
            })
            .collect();
        for (c, claim) in seated {
            self.seats.remove(&c);
            if let Some((l, conn)) = claim {
                self.admit(l, conn, c, None, None);
            }
        }
        let gone: Vec<u64> = self
            .online
            .iter()
            .filter(|(c, o)| o.link == link && !self.seats.contains_key(c))
            .map(|(c, _)| *c)
            .collect();
        for c in gone {
            self.offline(c);
        }
        self.maps_changed();
    }

    fn sweep(&mut self) {
        let now = Instant::now();
        self.reservations.retain(|_, r| now < r.expires);
        let stale: Vec<u64> = self
            .seats
            .iter()
            .filter(|(_, s)| {
                matches!(s, Seat::Transit { since, .. } if now.duration_since(*since) > TRANSIT_TTL)
            })
            .map(|(c, _)| *c)
            .collect();
        for c in stale {
            self.seats.remove(&c);
            self.offline(c);
        }
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
    let MapMsg::Hello {
        key: theirs,
        map,
        address,
        capacity,
    } = hello
    else {
        return Err("first frame is not a hello".into());
    };
    if theirs != key {
        return Err("wrong coordinator key".into());
    }
    println!("[coord] map server {id} holds {map} at {address}");
    let (tx, mut rx) = mpsc::unbounded_channel::<CoordMsg>();
    {
        let mut b = book.lock().await;
        b.links.insert(
            id,
            Link {
                map: map.clone(),
                address,
                capacity,
                tx,
            },
        );
        b.maps_changed();
    }
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
    // The login service's key: travellers get their next ticket here.
    let ticket_key = std::fs::read(o.keys.join("ticket.key"))
        .ok()
        .and_then(|b| <[u8; 32]>::try_from(b).ok())
        .map(|b| SigningKey::from_bytes(&b));
    println!(
        "[coord] listening on {}{}",
        o.bind,
        if ticket_key.is_some() {
            ""
        } else {
            " (no ticket.key: travel between maps is closed)"
        }
    );
    let book = Arc::new(Mutex::new(Book {
        ticket_key,
        ..Book::default()
    }));
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
