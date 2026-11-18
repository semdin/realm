//! How many players the realm and each map take, the line when they are full,
//! the realm's health and the alerts it writes to its log.
//!
//! The login service asks here before it signs a ticket (POST /admin/admit).
//! A player with a seat already (a reconnect, a trip) goes straight in. Anyone
//! else gets a held place for a short while, or a place in one first-come line
//! that it keeps by asking again every few seconds. A claim from a map is the
//! last gate: without a seat or a held place it must find room too.
//!
//! REALM_CAP is the realm's limit; REALM_MAP_CAPS (`grounds=150,castle=80`)
//! overrides the capacity a map server announced. The defaults come from
//! fighting bots on the grounds (release build, 16 threads): 150 players tick
//! at p99 4-6 ms and 300 at 7-10 ms of the 33 ms there are, so they leave
//! room for a smaller host that also runs the database and every other map.
//!
//! Alerts are single log lines, `[alert] FIRING key: what` when one starts,
//! again every 10 minutes while it lasts, and `[alert] resolved key`:
//! `journalctl -u realm-coord -g '\[alert\]'`.

use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::maint::State;
use crate::{Book, Seat};

pub const DEFAULT_REALM_CAP: usize = 300;
/// Where every new character starts; the other maps keep maps.json's number.
const DEFAULT_MAP_CAPS: &str = "grounds=150";
/// A place granted to a login lasts this long (its ticket lasts 60 s).
const HOLD_TTL: Duration = Duration::from_secs(75);
/// A place in line is lost after this long without asking again.
const WAITER_TTL: Duration = Duration::from_secs(20);
const QUEUE_MAX: usize = 2000;
/// How often a waiting client should ask again.
const RETRY_S: u64 = 5;
const ALERT_EVERY: Duration = Duration::from_secs(5);
const ALERT_REPEAT: Duration = Duration::from_secs(600);
/// A map gone this long is an alert (a restart is shorter).
const MAP_DOWN_AFTER: Duration = Duration::from_secs(20);
const SLOW_TICK_MS: f32 = 33.0;

struct Hold {
    map: String,
    expires: Instant,
}

struct Waiter {
    account: u64,
    character: u64,
    map: String,
    seen: Instant,
}

struct Firing {
    text: String,
    since: Instant,
    logged: Instant,
}

pub struct Capacity {
    pub realm_cap: usize,
    map_caps: HashMap<String, usize>,
    holds: HashMap<u64, Hold>,
    queue: VecDeque<Waiter>,
    /// Maps ever linked, and since when each has been gone.
    known_maps: BTreeMap<String, Option<Instant>>,
    firing: BTreeMap<String, Firing>,
    checked: Instant,
}

impl Default for Capacity {
    fn default() -> Self {
        let realm_cap = std::env::var("REALM_CAP")
            .ok()
            .and_then(|v| v.trim().parse().ok())
            .unwrap_or(DEFAULT_REALM_CAP);
        let map_caps = std::env::var("REALM_MAP_CAPS")
            .unwrap_or_else(|_| DEFAULT_MAP_CAPS.to_owned())
            .split(',')
            .filter_map(|pair| {
                let (map, cap) = pair.split_once('=')?;
                Some((map.trim().to_owned(), cap.trim().parse().ok()?))
            })
            .collect();
        Self {
            realm_cap,
            map_caps,
            holds: HashMap::new(),
            queue: VecDeque::new(),
            known_maps: BTreeMap::new(),
            firing: BTreeMap::new(),
            checked: Instant::now(),
        }
    }
}

impl Book {
    /// How many players `link`'s map takes.
    pub fn map_cap(&self, link: u64) -> usize {
        self.links.get(&link).map_or(0, |l| {
            self.capacity
                .map_caps
                .get(&l.map)
                .copied()
                .unwrap_or(usize::from(l.capacity))
        })
    }

    /// Places held for logins on `map` that have no seat there yet.
    pub fn holds_on(&self, map: &str) -> usize {
        self.capacity
            .holds
            .iter()
            .filter(|(c, h)| h.map == map && !self.seats.contains_key(c))
            .count()
    }

    /// Everyone with a seat or a held place.
    pub fn realm_used(&self) -> usize {
        let held = self
            .capacity
            .holds
            .keys()
            .filter(|c| !self.seats.contains_key(c))
            .count();
        self.seats.len() + held
    }

    fn map_link(&self, map: &str) -> Option<u64> {
        self.links
            .iter()
            .find(|(_, l)| l.map == map)
            .map(|(id, _)| *id)
    }

    /// The last gate: may this login take a seat on `link`? A character with
    /// a seat, a trip or a held place may; anyone else needs room.
    pub fn claim_has_room(&mut self, link: u64, character: u64) -> Result<(), &'static str> {
        let held = self.capacity.holds.remove(&character).is_some();
        if held || self.seats.contains_key(&character) || self.reservations.contains_key(&character)
        {
            return Ok(());
        }
        if self.realm_used() >= self.capacity.realm_cap {
            return Err("realm_full");
        }
        let map = self.map_of(link);
        if self.map_used(link, &map) >= self.map_cap(link) {
            return Err("map_full");
        }
        Ok(())
    }

    pub fn capacity_forget(&mut self, account: u64) {
        self.capacity.queue.retain(|w| w.account != account);
    }

    /// POST /admin/admit {account, character, map, start}: may this login have
    /// a ticket? Answers with the map and its address, or why not.
    pub fn admit_request(&mut self, body: &Value) -> Value {
        let account = body["account"].as_u64().unwrap_or(0);
        let character = body["character"].as_u64().unwrap_or(0);
        if let Some(ban) = self.ban_of(account) {
            return json!({"ok": false, "error": "banned", "reason": ban.reason, "until": ban.until});
        }
        if self.maint.state != State::Online {
            return json!({"ok": false, "error": "maintenance"});
        }
        // A map that is not open sends the character to the start map.
        let wanted = body["map"].as_str().unwrap_or("");
        let start = body["start"].as_str().unwrap_or("");
        let Some((map, link)) = [wanted, start]
            .iter()
            .find_map(|m| self.map_link(m).map(|l| ((*m).to_owned(), l)))
        else {
            return json!({"ok": false, "error": "unavailable"});
        };
        let address = self
            .links
            .get(&link)
            .map(|l| l.address.clone())
            .unwrap_or_default();
        let now = Instant::now();
        let granted = |b: &mut Self, map: String| {
            b.capacity.queue.retain(|w| w.account != account);
            b.capacity.holds.insert(
                character,
                Hold {
                    map: map.clone(),
                    expires: now + HOLD_TTL,
                },
            );
            json!({"ok": true, "map": map, "address": address})
        };
        // Coming back to a seat it has, or a place it was given, needs no room.
        if self.seats.contains_key(&character)
            || self.capacity.holds.contains_key(&character)
            || self.gas.contains(&account)
        {
            return granted(self, map);
        }
        match self
            .capacity
            .queue
            .iter_mut()
            .find(|w| w.account == account)
        {
            Some(w) => {
                w.character = character;
                w.map.clone_from(&map);
                w.seen = now;
            }
            None => {
                if self.capacity.queue.len() >= QUEUE_MAX {
                    return json!({"ok": false, "error": "realm_full", "position": 0,
                                  "queue": QUEUE_MAX, "retry_s": RETRY_S * 6});
                }
                self.capacity.queue.push_back(Waiter {
                    account,
                    character,
                    map: map.clone(),
                    seen: now,
                });
            }
        }
        // Whoever stands ahead takes their places first.
        let mut free = self.capacity.realm_cap.saturating_sub(self.realm_used());
        let mut map_free: HashMap<String, usize> = HashMap::new();
        let mut position = 0;
        let mut realm_blocked = false;
        let waiting: Vec<(u64, String)> = self
            .capacity
            .queue
            .iter()
            .map(|w| (w.account, w.map.clone()))
            .collect();
        for (who, on) in &waiting {
            position += 1;
            let room = match map_free.get(on) {
                Some(n) => *n,
                None => self
                    .map_link(on)
                    .map_or(0, |l| self.map_cap(l).saturating_sub(self.map_used(l, on))),
            };
            let can = free > 0 && room > 0;
            if *who == account {
                if can {
                    return granted(self, map);
                }
                realm_blocked = free == 0;
                break;
            }
            if can {
                free -= 1;
                map_free.insert(on.clone(), room - 1);
            } else {
                map_free.insert(on.clone(), room);
            }
        }
        json!({
            "ok": false,
            "error": "realm_full",
            "scope": if realm_blocked { "realm" } else { "map" },
            "map": map,
            "position": position,
            "queue": waiting.len(),
            "retry_s": RETRY_S,
        })
    }

    pub fn capacity_sweep(&mut self) {
        let now = Instant::now();
        self.capacity.holds.retain(|_, h| h.expires > now);
        self.capacity.queue.retain(|w| now - w.seen < WAITER_TTL);
        if now - self.capacity.checked >= ALERT_EVERY {
            self.capacity.checked = now;
            self.check_alerts(now);
        }
    }

    fn check_alerts(&mut self, now: Instant) {
        let up: BTreeSet<String> = self.links.values().map(|l| l.map.clone()).collect();
        for map in &up {
            self.capacity.known_maps.insert(map.clone(), None);
        }
        let mut found: Vec<(String, String)> = Vec::new();
        for (map, gone) in &mut self.capacity.known_maps {
            if up.contains(map) {
                continue;
            }
            let since = *gone.get_or_insert(now);
            if now - since >= MAP_DOWN_AFTER && self.maint.state == State::Online {
                found.push((format!("map_down:{map}"), format!("{map} is not linked")));
            }
        }
        for (map, p99, failed) in self.metrics.recent_maps() {
            if p99 > SLOW_TICK_MS {
                found.push((format!("map_slow:{map}"), format!("tick p99 {p99:.0} ms")));
            }
            if failed > 0 {
                found.push((
                    format!("saves_failing:{map}"),
                    format!("{failed} saves failed"),
                ));
            }
        }
        if let Some(why) = self.metrics.persist_problem() {
            found.push(("persist".to_owned(), why));
        }
        let used = self.realm_used();
        if used >= self.capacity.realm_cap {
            found.push((
                "realm_full".to_owned(),
                format!(
                    "{used}/{} players, {} waiting",
                    self.capacity.realm_cap,
                    self.capacity.queue.len()
                ),
            ));
        }
        let keys: BTreeSet<&String> = found.iter().map(|(k, _)| k).collect();
        let over: Vec<String> = self
            .capacity
            .firing
            .keys()
            .filter(|k| !keys.contains(k))
            .cloned()
            .collect();
        for key in over {
            self.capacity.firing.remove(&key);
            println!("[alert] resolved {key}");
        }
        for (key, text) in found {
            match self.capacity.firing.get_mut(&key) {
                Some(f) => {
                    f.text.clone_from(&text);
                    if now - f.logged >= ALERT_REPEAT {
                        f.logged = now;
                        println!("[alert] FIRING {key}: {text}");
                    }
                }
                None => {
                    println!("[alert] FIRING {key}: {text}");
                    self.capacity.firing.insert(
                        key,
                        Firing {
                            text,
                            since: now,
                            logged: now,
                        },
                    );
                }
            }
        }
    }

    /// GET /admin/health: what the login service and a monitor need.
    pub fn health_view(&self) -> Value {
        let now = Instant::now();
        let up: BTreeSet<&str> = self.links.values().map(|l| l.map.as_str()).collect();
        let down: Vec<&str> = self
            .capacity
            .known_maps
            .keys()
            .map(String::as_str)
            .filter(|m| !up.contains(m))
            .collect();
        let alerts: Vec<Value> = self
            .capacity
            .firing
            .iter()
            .map(|(k, f)| json!({"key": k, "text": f.text, "for_s": (now - f.since).as_secs()}))
            .collect();
        let seated = self
            .seats
            .values()
            .filter(|s| matches!(s, Seat::On { .. }))
            .count();
        json!({
            "ok": true,
            "state": self.maint.state.name(),
            "accepting": self.maint.state == State::Online,
            "reason": self.maint.reason(),
            "players": seated,
            "realm_cap": self.capacity.realm_cap,
            "queue": self.capacity.queue.len(),
            "maps_up": up,
            "maps_down": down,
            "persist_ok": self.metrics.persist_problem().is_none(),
            "alerts": alerts,
        })
    }
}
