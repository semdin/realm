//! Travel on the map server: doors, the Hearthway, the Twinned Cabinets
//! and secret passages, the Waylink, the broom, and handing a character to
//! another map server.
//!
//! A trip that stays on this map moves the body at once (a new `life`, so
//! the owner's prediction takes the new place as the server's doing). A
//! trip to another map first reserves a seat there through the coordinator
//! while the traveller still stands here; then the body leaves the world,
//! its sheet is saved with the destination as its place, and only once
//! that save has landed is the sheet released to the coordinator, which
//! signs the client a ticket for the destination. The destination admits
//! the traveller with that sheet and sets it down on its own ground.
//!
//! Every login is claimed from the coordinator first (when this server has
//! one), and a character this server is still letting go is refused until
//! it is gone, so a character is never in two worlds and its items never
//! in two bags.
//!
//! The old game's `request_transfer`, `request_travel`, its boot travel and
//! `submit_mount`, with what the old code left to the client moved here:
//! the broom's 2 s lock after being hurt, its landing check, the level of
//! every Waylink rider.

use bytes::Bytes;
use realm_proto::control::{self, ServerMsg, WaylinkView};
use realm_proto::coord::MapMsg;
use realm_rules::CharacterSheet;
use realm_rules::travel::{Arrival, Landing, Node, Trip, TripKind};
use realm_sim::movement::Body;
use realm_sim::{SIM_HZ, Vec3};

use super::{ConnId, Entity, PendingJoin, Player, Sim, planar_distance, unit, xorshift};
use realm_proto::JoinReply;

/// Being hurt this recently keeps the broom away (old client COMBAT_WINDOW).
const MOUNT_HURT_TICKS: u32 = 2 * SIM_HZ;
/// A reservation the coordinator never answered is given up after this.
const RESERVE_WAIT_TICKS: u32 = 5 * SIM_HZ;
/// A traveller's connection is kept this long after its ticket went out
/// (the client closes it itself once it has read the ticket).
const DELIVERED_KEEP_TICKS: u32 = 10 * SIM_HZ;
/// A departure still not released after this is dropped (its save stands).
const DEPART_GIVE_UP_TICKS: u32 = 60 * SIM_HZ;
/// A login's claim the coordinator has not answered after this is refused
/// (the client tries again with a fresh ticket): without it the join waited
/// as long as the client kept its connection open, the loading screen with it.
/// Longer than a seat taken from another map takes (its save, its release).
const CLAIM_WAIT_TICKS: u32 = 20 * SIM_HZ;

fn ms_ticks(ms: u32) -> u32 {
    (ms * SIM_HZ).div_ceil(1000)
}

/// A trip to another map waiting for its seat.
pub(super) struct PendingTrip {
    pub trip: Trip,
    pub since: u32,
}

/// A character leaving this server: saved, then released.
pub(super) struct Departing {
    pub account: u64,
    pub sheet: CharacterSheet,
    pub arrival: Option<Arrival>,
    /// Its save has landed / it was handed to the coordinator.
    pub saved: bool,
    pub released: bool,
    /// A traveller's open connection (for its ticket) until delivered.
    pub conn: Option<ConnId>,
    pub channels: Option<(
        tokio::sync::mpsc::Sender<Bytes>,
        tokio::sync::mpsc::Sender<Bytes>,
    )>,
    pub delivered_at: Option<u32>,
    pub since: u32,
}

/// A Waylink boot set down on this map.
pub(super) struct Waylink {
    pub id: u32,
    pub owner: Entity,
    pub owner_name: String,
    pub party: u64,
    pub pos: Vec3,
    pub dest: String,
    pub fires: u32,
    pub holders: Vec<Entity>,
}

impl Sim {
    fn travel_refused(&mut self, conn: ConnId, what: &str, reason: &str) {
        self.send_control(
            conn,
            &ServerMsg::TravelResult {
                what: what.to_owned(),
                ok: false,
                reason: reason.to_owned(),
            },
        );
    }

    pub(super) fn feet(&self, entity: Entity) -> Option<[f32; 3]> {
        self.world
            .get::<Player>(entity)
            .map(|p| [p.body.pos.x, p.body.pos.y, p.body.pos.z])
    }

    /// `ClientMsg::Door`.
    pub(super) fn request_door(&mut self, conn: ConnId, entity: Entity, id: &str) {
        let Some(mut pos) = self.feet(entity) else {
            return;
        };
        // Inside a dungeon copy the doors stand at the copy's offset.
        if self.instanced {
            pos[0] -= super::dungeon::offset_of(realm_rules::dungeons::copy_at(pos[0])).x;
        }
        let rules = self.rules();
        let trip = rules.travel.door_trip(&self.game.map, id, pos);
        match trip {
            Ok(mut trip) => {
                // A dungeon is entered through its gate; its door only takes
                // a member of a run still standing back in.
                if rules
                    .travel
                    .maps
                    .get(&trip.arrival.map)
                    .is_some_and(|m| m.instanced)
                {
                    let me = self.world.get::<Player>(entity).map_or(0, |p| p.sheet.id);
                    trip.arrival.copy = self.run_copy_of(&trip.arrival.map, me);
                    if trip.arrival.copy == 0 {
                        return self.travel_refused(conn, "door", "use_gate");
                    }
                }
                self.start_trip(conn, entity, trip, true);
            }
            Err(reason) => self.travel_refused(conn, "door", reason),
        }
    }

    /// `ClientMsg::Travel`.
    pub(super) fn request_node_trip(&mut self, conn: ConnId, entity: Entity, from: &str, to: &str) {
        let Some(p) = self.world.get::<Player>(entity) else {
            return;
        };
        let (pos, level) = ([p.body.pos.x, p.body.pos.y, p.body.pos.z], p.sheet.level);
        let rules = self.rules();
        let what = rules
            .travel
            .nodes
            .get(from)
            .map_or("hearthway", |n| match n.kind {
                realm_rules::travel::NodeKind::Hearthway => "hearthway",
                realm_rules::travel::NodeKind::Cabinet => "cabinet",
                realm_rules::travel::NodeKind::Passage => "passage",
            });
        match rules.travel.node_trip(&self.game.map, pos, from, to, level) {
            Ok(trip) => self.start_trip(conn, entity, trip, true),
            Err(reason) => self.travel_refused(conn, what, reason),
        }
    }

    /// Starts `trip` for a player: here at once, or a seat reserved on the
    /// destination first. `checked`: the player's own checks still apply
    /// (a Waylink checked its riders when it fired).
    pub(super) fn start_trip(&mut self, conn: ConnId, entity: Entity, trip: Trip, checked: bool) {
        let tick = self.tick;
        let what = trip.arrival.kind.name();
        let Some(p) = self.world.get::<Player>(entity) else {
            return;
        };
        let held = trip.cost.as_ref().map_or(0, |(item, _)| {
            realm_rules::items::count_items(&p.sheet, item)
        });
        let reason = if p.dead_until != 0 {
            Some("dead")
        } else if p.trip.is_some() {
            Some("transfer_pending")
        } else if checked && (p.body.mounted || p.restraint.riding(p.last_input_tick + 1)) {
            Some("mounted")
        } else if checked
            && trip.combat_lock_ms > 0
            && p.last_combat != 0
            && tick < p.last_combat + ms_ticks(trip.combat_lock_ms)
        {
            Some("in_combat")
        } else if trip.cost.as_ref().is_some_and(|(_, n)| held < *n) {
            Some("no_item")
        } else {
            None
        };
        if let Some(reason) = reason {
            return self.travel_refused(conn, what, reason);
        }
        let character = p.sheet.id;
        // On this map and in this copy: a step. Into another copy the
        // player leaves and joins again, so its client builds that copy.
        let here = self.copy_of(p.body.pos);
        if trip.arrival.map == self.game.map && (!self.instanced || trip.arrival.copy == here) {
            self.pay_trip(conn, entity, &trip);
            self.send_control(
                conn,
                &ServerMsg::Departing {
                    map: trip.arrival.map.clone(),
                    label: trip.label.clone(),
                    kind: what.to_owned(),
                },
            );
            let to = self.land(&trip.arrival.landing);
            self.teleport(entity, to);
            self.send_control(
                conn,
                &ServerMsg::Arrived {
                    kind: what.to_owned(),
                },
            );
            return;
        }
        if self.coord_tx.is_none() || !self.coord_up || !self.open_maps.contains(&trip.arrival.map)
        {
            return self.travel_refused(conn, what, "map_unavailable");
        }
        let map = trip.arrival.map.clone();
        if let Some(mut p) = self.world.get_mut::<Player>(entity) {
            p.trip = Some(PendingTrip { trip, since: tick });
        }
        self.coord_send(MapMsg::Reserve { character, map });
    }

    /// Takes a trip's price from the bag.
    fn pay_trip(&mut self, conn: ConnId, entity: Entity, trip: &Trip) {
        let Some((item, n)) = &trip.cost else { return };
        let tick = self.tick;
        if let Some(mut p) = self.world.get_mut::<Player>(entity)
            && realm_rules::items::take_items(&mut p.sheet, item, *n).is_ok()
        {
            p.sheet.revision += 1;
            p.dirty_since.get_or_insert(tick);
        }
        self.send_sheet(conn);
    }

    /// Moves a body on this map: a new life for its owner's prediction,
    /// off the broom.
    fn teleport(&mut self, entity: Entity, to: Vec3) {
        if let Some(mut p) = self.world.get_mut::<Player>(entity) {
            let next = p.last_input_tick + 1;
            p.body = Body::at(to);
            p.last_ground = to;
            p.restraint.dismount(next);
            p.life = p.life.wrapping_add(1);
        }
    }

    /// The coordinator answered a reservation.
    pub(super) fn reserved(&mut self, character: u64, ok: bool, reason: &str) {
        let Some((conn, entity)) = self.player_of(character) else {
            return;
        };
        let Some(pending) = self
            .world
            .get_mut::<Player>(entity)
            .and_then(|mut p| p.trip.take())
        else {
            return;
        };
        let trip = pending.trip;
        let what = trip.arrival.kind.name();
        if !ok {
            return self.travel_refused(conn, what, reason);
        }
        let still = self.world.get::<Player>(entity).is_some_and(|p| {
            p.dead_until == 0
                && trip
                    .cost
                    .as_ref()
                    .is_none_or(|(item, n)| realm_rules::items::count_items(&p.sheet, item) >= *n)
        });
        if !still {
            return self.travel_refused(conn, what, "aborted");
        }
        self.pay_trip(conn, entity, &trip);
        self.send_control(
            conn,
            &ServerMsg::Departing {
                map: trip.arrival.map.clone(),
                label: trip.label.clone(),
                kind: what.to_owned(),
            },
        );
        self.leave_world(conn, Some(trip.arrival));
    }

    /// Reservations the coordinator never answered.
    pub(super) fn expire_trips(&mut self) {
        let tick = self.tick;
        let stale: Vec<(ConnId, Entity, &'static str)> = self
            .clients
            .iter()
            .filter_map(|(conn, c)| {
                let p = self.world.get::<Player>(c.entity)?;
                let t = p.trip.as_ref()?;
                (tick > t.since + RESERVE_WAIT_TICKS)
                    .then(|| (*conn, c.entity, t.trip.arrival.kind.name()))
            })
            .collect();
        for (conn, entity, what) in stale {
            if let Some(mut p) = self.world.get_mut::<Player>(entity) {
                p.trip = None;
            }
            self.travel_refused(conn, what, "map_unavailable");
        }
    }

    /// Takes a player out of this world for good (a logout, an eviction or
    /// a trip to `arrival`): saved now, released to the coordinator once
    /// the save has landed. A traveller keeps its connection to hear its
    /// ticket.
    pub(super) fn leave_world(&mut self, conn: ConnId, arrival: Option<Arrival>) {
        let Some(entity) = self.clients.get(&conn).map(|c| c.entity) else {
            return;
        };
        self.flee_duel(entity);
        let place = arrival.as_ref().map(|a| {
            let pos = self.arrival_guess(a);
            realm_rules::Place {
                map: a.map.clone(),
                pos: [pos.x, pos.y, pos.z],
                yaw: 0.0,
            }
        });
        let Some((client, sheet)) = self.take_out(conn, place) else {
            return;
        };
        if self.coord_tx.is_none() {
            return;
        }
        let travelling = arrival.is_some();
        let character = sheet.id;
        self.departing.insert(
            character,
            Departing {
                account: client.account,
                sheet,
                arrival,
                saved: false,
                released: false,
                conn: travelling.then_some(conn),
                channels: travelling.then_some((client.outbox, client.control)),
                delivered_at: None,
                since: self.tick,
            },
        );
    }

    /// Where a traveller will roughly stand, for its saved place (the
    /// destination settles it on its own ground; y 0 means the ground).
    fn arrival_guess(&self, a: &Arrival) -> Vec3 {
        let rules = self.rules();
        let node = |id: &str| {
            rules
                .travel
                .nodes
                .get(id)
                .map_or(Vec3::ZERO, |n| Vec3::new(n.pos[0], n.pos[1], n.pos[2]))
        };
        match &a.landing {
            Landing::Spawn(name) => rules
                .travel
                .maps
                .get(&a.map)
                .and_then(|m| m.spawns.get(name))
                .map_or(Vec3::ZERO, |p| Vec3::new(p[0], p[1], p[2])),
            Landing::Node { node: id, .. } | Landing::Scatter { node: id, .. } => node(id),
            Landing::Ring { spawn: name, .. } => {
                rules
                    .travel
                    .maps
                    .get(&a.map)
                    .and_then(|m| m.spawns.get(name))
                    .map_or(Vec3::ZERO, |p| Vec3::new(p[0], p[1], p[2]))
                    + super::dungeon::offset_of(a.copy)
            }
        }
    }

    /// A save landed: a departing character's sheet goes to the coordinator.
    pub(super) fn departure_saved(&mut self, character: u64, revision: u64) {
        let Some(d) = self.departing.get_mut(&character) else {
            return;
        };
        if revision < d.sheet.revision {
            return;
        }
        d.saved = true;
        self.release_departed(character);
    }

    fn release_departed(&mut self, character: u64) {
        let Some(d) = self.departing.get(&character) else {
            return;
        };
        if !d.saved || d.released {
            return;
        }
        let msg = MapMsg::Release {
            character,
            account: d.account,
            sheet: Box::new(d.sheet.clone()),
            arrival: d.arrival.clone(),
        };
        if !self.coord_send(msg) {
            return;
        }
        let travelling = d.arrival.is_some();
        if travelling {
            if let Some(d) = self.departing.get_mut(&character) {
                d.released = true;
            }
        } else {
            self.departing.remove(&character);
        }
    }

    /// The coordinator's ticket for a traveller: to its client.
    pub(super) fn deliver_ticket(
        &mut self,
        character: u64,
        map: String,
        address: String,
        ticket: Vec<u8>,
    ) {
        let tick = self.tick;
        let Some(d) = self.departing.get_mut(&character) else {
            return;
        };
        if let Some((_, control)) = &d.channels {
            let msg = ServerMsg::Travel {
                map,
                address,
                ticket,
            };
            let _ = control.try_send(Bytes::from(control::encode_server(&msg)));
        }
        d.delivered_at = Some(tick);
    }

    /// A connection closed: a traveller's record lets its channels go.
    pub(super) fn departed_conn_closed(&mut self, conn: ConnId) {
        for d in self.departing.values_mut() {
            if d.conn == Some(conn) {
                d.conn = None;
                d.channels = None;
            }
        }
    }

    /// Departures done (ticket delivered and read, or given up on).
    pub(super) fn sweep_departing(&mut self) {
        let tick = self.tick;
        if !tick.is_multiple_of(SIM_HZ) {
            return;
        }
        self.departing.retain(|character, d| {
            let delivered = d
                .delivered_at
                .is_some_and(|at| d.conn.is_none() || tick > at + DELIVERED_KEEP_TICKS);
            if delivered {
                return false;
            }
            if tick > d.since + DEPART_GIVE_UP_TICKS {
                eprintln!("[travel] character {character}: never released; its save stands");
                return false;
            }
            true
        });
    }

    /// The coordinator link came back: departures it missed go now.
    pub(super) fn resend_departures(&mut self) {
        let waiting: Vec<u64> = self.departing.keys().copied().collect();
        for c in waiting {
            self.release_departed(c);
        }
    }

    /// Whether a join for `character` must wait: it is still leaving here
    /// (its save or its release has not gone yet). Once released, the
    /// coordinator holds it and answers the claim.
    pub(super) fn still_leaving(&self, character: u64) -> bool {
        self.departing.get(&character).is_some_and(|d| !d.released)
    }

    /// The coordinator wants `character` elsewhere.
    pub(super) fn evict(&mut self, character: u64) {
        if let Some((conn, _)) = self.player_of(character) {
            self.leave_world(conn, None);
            if self.coord_tx.is_some() && !self.departing.contains_key(&character) {
                // Nothing to release (no sheet): say so.
                self.coord_send(MapMsg::Gone { character });
            }
            return;
        }
        if self.departing.contains_key(&character) {
            return;
        }
        let waiting: Vec<ConnId> = self
            .pending
            .iter()
            .filter(|(_, j)| j.ticket.character == character)
            .map(|(c, _)| *c)
            .collect();
        for conn in waiting {
            if let Some(join) = self.pending.remove(&conn) {
                let _ = join
                    .reply
                    .send(JoinReply::Refused("logged in elsewhere".to_owned()));
            }
        }
        self.coord_send(MapMsg::Gone { character });
    }

    /// The coordinator's answer to a login's claim.
    pub(super) fn claim_answered(
        &mut self,
        conn: ConnId,
        character: u64,
        sheet: Option<Box<CharacterSheet>>,
        arrival: Option<Arrival>,
    ) {
        let Some(mut join) = self.pending.remove(&conn) else {
            eprintln!(
                "[claim] connection {conn} character {character}: seat granted after the login left; given back"
            );
            // The login left before its answer: the seat goes back.
            match sheet {
                Some(sheet) => {
                    self.coord_send(MapMsg::Release {
                        character,
                        account: 0,
                        sheet,
                        arrival,
                    });
                }
                None => {
                    self.coord_send(MapMsg::Gone { character });
                }
            }
            return;
        };
        eprintln!(
            "[claim] connection {conn} character {character}: seat granted ({}, {} ms)",
            if sheet.is_some() {
                "sheet from the coordinator"
            } else {
                "loads from the store"
            },
            self.tick.saturating_sub(join.since) * 1000 / SIM_HZ,
        );
        join.arrival = arrival;
        self.join_here(conn, join, sheet.map(|s| *s));
    }

    pub(super) fn claim_refused(&mut self, conn: ConnId, reason: String) {
        if let Some(join) = self.pending.remove(&conn) {
            eprintln!(
                "[claim] connection {conn} character {}: refused ({reason})",
                join.ticket.character
            );
            let _ = join.reply.send(JoinReply::Refused(reason));
        }
    }

    /// Claims the coordinator has left unanswered too long are refused.
    pub(super) fn sweep_claims(&mut self) {
        let tick = self.tick;
        if !tick.is_multiple_of(SIM_HZ) {
            return;
        }
        let stale: Vec<ConnId> = self
            .pending
            .iter()
            .filter(|(_, j)| !j.loading && tick > j.since + CLAIM_WAIT_TICKS)
            .map(|(c, _)| *c)
            .collect();
        for conn in stale {
            eprintln!(
                "[claim] connection {conn}: no answer from the coordinator in {} s",
                CLAIM_WAIT_TICKS / SIM_HZ
            );
            self.claim_refused(conn, "the realm is not ready; try again".to_owned());
        }
    }

    /// The coordinator went away: logins waiting on it and seats being
    /// reserved are refused (they try again).
    pub(super) fn coord_lost(&mut self) {
        let waiting: Vec<ConnId> = self
            .pending
            .iter()
            .filter(|(_, j)| !j.loading)
            .map(|(c, _)| *c)
            .collect();
        for conn in waiting {
            self.claim_refused(conn, "the realm is restarting; try again".to_owned());
        }
        let travellers: Vec<(ConnId, Entity, &'static str)> = self
            .clients
            .iter()
            .filter_map(|(conn, c)| {
                let p = self.world.get::<Player>(c.entity)?;
                Some((*conn, c.entity, p.trip.as_ref()?.trip.arrival.kind.name()))
            })
            .collect();
        for (conn, entity, what) in travellers {
            if let Some(mut p) = self.world.get_mut::<Player>(entity) {
                p.trip = None;
            }
            self.travel_refused(conn, what, "map_unavailable");
        }
    }

    /// Where a landing puts a body in dungeon copy `copy` (0: the map).
    pub(super) fn land_in(&self, copy: u8, landing: &Landing) -> Vec3 {
        if copy == 0 {
            return self.land(landing);
        }
        let shift = super::dungeon::offset_of(copy);
        let rules = self.rules();
        let spawn = |name: &str| {
            rules
                .travel
                .maps
                .get(&self.game.map)
                .and_then(|m| m.spawns.get(name))
                .map_or(self.game.spawn_point, |p| Vec3::new(p[0], p[1], p[2]))
        };
        match landing {
            Landing::Spawn(name) => self.settle(spawn(name) + shift),
            Landing::Ring {
                spawn: name,
                slot,
                of,
            } => self.settle(Self::ring_point(spawn(name), *slot, *of) + shift),
            other => self.land(other) + shift,
        }
    }

    /// Where a landing puts a body on this map.
    pub(super) fn land(&self, landing: &Landing) -> Vec3 {
        let rules = self.rules();
        let spawn = |name: &str| {
            rules
                .travel
                .maps
                .get(&self.game.map)
                .and_then(|m| m.spawns.get(name))
                .map_or(self.game.spawn_point, |p| Vec3::new(p[0], p[1], p[2]))
        };
        match landing {
            Landing::Spawn(name) => self.settle(spawn(name)),
            Landing::Ring {
                spawn: name,
                slot,
                of,
            } => self.settle(Self::ring_point(spawn(name), *slot, *of)),
            Landing::Node { node, arrive } => {
                let Some(n) = rules.travel.nodes.get(node) else {
                    return self.settle(self.game.spawn_point);
                };
                let at = self.node_point(n);
                let (fx, fz) = n.facing();
                self.settle(at + Vec3::new(fx, 0.0, fz) * *arrive)
            }
            Landing::Scatter {
                node,
                seed,
                slot,
                riders,
            } => {
                let Some(n) = rules.travel.nodes.get(node) else {
                    return self.settle(self.game.spawn_point);
                };
                let center = self.scatter_spot(n, *seed);
                let ring = if *riders > 1 {
                    let a = core::f32::consts::TAU * f32::from(*slot) / f32::from(*riders);
                    Vec3::new(libm::cosf(a), 0.0, libm::sinf(a)) * 1.6
                } else {
                    Vec3::ZERO
                };
                self.settle(center + ring)
            }
        }
    }

    /// A node's foot point (y 0 on terrain: the ground there).
    fn node_point(&self, n: &Node) -> Vec3 {
        let mut at = Vec3::new(n.pos[0], n.pos[1], n.pos[2]);
        if n.pos[1] == 0.0 {
            at.y = self
                .terrain
                .terrain_at(at.x, at.z)
                .map_or_else(|| self.ground(at.x, at.z), |t| t.0);
        }
        at
    }

    /// Feet put on the floor just under `at` (indoors not on the roof
    /// above), else on the terrain, else where they are.
    pub(super) fn settle(&self, at: Vec3) -> Vec3 {
        if let Some(hit) = self.terrain.ray_down(at + Vec3::new(0.0, 1.5, 0.0), 8.0) {
            return Vec3::new(at.x, hit.point.y + 0.05, at.z);
        }
        if let Some((h, _)) = self.terrain.terrain_at(at.x, at.z) {
            return Vec3::new(at.x, h + 0.05, at.z);
        }
        at
    }

    /// A Waylink's landing: an open spot `scatter` metres from the node,
    /// found with `seed` (every rider finds the same one). Ground under all
    /// of it near the node's height, no water, nothing standing over it,
    /// gentle enough for a ring of riders; in front of the node otherwise.
    fn scatter_spot(&self, n: &Node, seed: u32) -> Vec3 {
        let rules = self.rules();
        let w = &rules.travel.waylink;
        let at = self.node_point(n);
        let (fx, fz) = n.facing();
        let fallback = at + Vec3::new(fx, 0.0, fz) * w.arrive;
        let on_terrain = self.terrain.terrain_at(at.x, at.z).is_some();
        let mut rng = seed | 1;
        for _ in 0..24 {
            let angle = unit(&mut rng) * core::f32::consts::TAU;
            let dist = w.scatter.0 + unit(&mut rng) * (w.scatter.1 - w.scatter.0);
            let spot = at + Vec3::new(libm::cosf(angle), 0.0, libm::sinf(angle)) * dist;
            let mut heights = Vec::with_capacity(5);
            for (dx, dz) in [(0.0, 0.0), (1.8, 0.0), (-1.8, 0.0), (0.0, 1.8), (0.0, -1.8)] {
                let (x, z) = (spot.x + dx, spot.z + dz);
                let hit = self
                    .terrain
                    .ray_down(Vec3::new(x, at.y + 14.0, z), 24.0)
                    .map(|h| h.point.y);
                let y = if on_terrain {
                    let Some((g, _)) = self.terrain.terrain_at(x, z) else {
                        break;
                    };
                    let wet = self.terrain.water_surface_at(x, z).is_some_and(|s| s > g);
                    if wet || hit.is_some_and(|y| y > g + 0.6) {
                        break;
                    }
                    g
                } else {
                    let Some(y) = hit else { break };
                    y
                };
                if (y - at.y).abs() > 6.0 {
                    break;
                }
                heights.push(y);
            }
            if heights.len() == 5 {
                let (lo, hi) = heights
                    .iter()
                    .fold((f32::MAX, f32::MIN), |(lo, hi), y| (lo.min(*y), hi.max(*y)));
                if hi - lo < 1.4 {
                    return Vec3::new(spot.x, heights[0], spot.z);
                }
            }
        }
        fallback
    }

    /// Admitted with `arrival`: set down on this map, told, the quest event.
    pub(super) fn arrived(&mut self, conn: ConnId, entity: Entity, arrival: &Arrival) {
        self.send_control(
            conn,
            &ServerMsg::Arrived {
                kind: arrival.kind.name().to_owned(),
            },
        );
        let map = self.game.map.clone();
        self.quest_event(entity, "enter_map", &map, false);
    }

    /// `ClientMsg::Ride`.
    pub(super) fn request_ride(&mut self, conn: ConnId, entity: Entity, on: bool) {
        let tick = self.tick;
        let flight = self.rules().travel.flight_allowed(&self.game.map);
        let Some(p) = self.world.get::<Player>(entity) else {
            return;
        };
        let next = p.last_input_tick + 1;
        let riding = p.restraint.riding(next);
        let pos = p.body.pos;
        let reason = if on {
            let near_ground = || {
                p.body.vel.y > -4.0
                    && self
                        .terrain
                        .ray_down(pos + Vec3::new(0.0, 0.1, 0.0), 1.3)
                        .is_some_and(|h| h.normal.y > 0.7)
            };
            if riding {
                None
            } else if p.dead_until != 0 {
                Some("dead")
            } else if p.trip.is_some() {
                Some("transfer_pending")
            } else if !flight {
                Some("no_flight")
            } else if p.caster.derived.mount_speed <= 0.0 {
                Some("no_broom")
            } else if p.caster.cast.is_some() {
                Some("casting")
            } else if p.last_hurt != 0 && tick < p.last_hurt + MOUNT_HURT_TICKS {
                Some("in_combat")
            } else if p.restraint.locked(next) {
                Some("stunned")
            } else if !(p.body.on_floor || near_ground()) {
                Some("not_grounded")
            } else {
                None
            }
        } else if !riding {
            None
        } else if !self
            .terrain
            .ray_down(pos + Vec3::new(0.0, 0.1, 0.0), 3.1)
            .is_some_and(|h| h.normal.y > 0.7)
        {
            Some("no_landing")
        } else {
            None
        };
        if let Some(reason) = reason {
            return self.travel_refused(conn, "ride", reason);
        }
        if let Some(mut p) = self.world.get_mut::<Player>(entity) {
            if on && !riding {
                let speed = p.caster.derived.mount_speed;
                p.restraint.mount(next, speed);
            } else if !on {
                p.restraint.dismount(next);
            }
        }
        self.send_control(
            conn,
            &ServerMsg::TravelResult {
                what: "ride".to_owned(),
                ok: true,
                reason: if on { "mounted" } else { "dismounted" }.to_owned(),
            },
        );
    }

    /// `ClientMsg::WaylinkPlace`.
    pub(super) fn place_waylink(&mut self, conn: ConnId, entity: Entity, dest: &str) {
        let tick = self.tick;
        let rules = self.rules();
        let w = &rules.travel.waylink;
        let instanced = rules
            .travel
            .maps
            .get(&self.game.map)
            .is_some_and(|m| m.instanced);
        let Some(p) = self.world.get::<Player>(entity) else {
            return;
        };
        let level_min = rules.travel.nodes.get(dest).map_or(0, |n| n.level_min);
        let reason = if p.dead_until != 0 {
            Some("dead")
        } else if p.trip.is_some() {
            Some("transfer_pending")
        } else if p.body.mounted || p.restraint.riding(p.last_input_tick + 1) {
            Some("mounted")
        } else if instanced {
            Some("in_dungeon")
        } else if p.last_combat != 0 && tick < p.last_combat + ms_ticks(w.combat_lock_ms) {
            Some("in_combat")
        } else if !w.destinations.iter().any(|d| d == dest) {
            Some("no_portal")
        } else if p.sheet.level < level_min {
            Some("level_too_low")
        } else if self.waylinks.iter().any(|l| l.owner == entity) {
            Some("waylink_active")
        } else if realm_rules::items::count_items(&p.sheet, &w.item) == 0 {
            Some("no_item")
        } else {
            None
        };
        if let Some(reason) = reason {
            return self.travel_refused(conn, "waylink", reason);
        }
        let yaw = p.last_frame.movement.yaw_radians();
        // Yaw 0 looks along -Z.
        let ahead = Vec3::new(-libm::sinf(yaw), 0.0, -libm::cosf(yaw)) * w.place_ahead;
        let at = p.body.pos + ahead;
        let at = self
            .terrain
            .ray_down(at + Vec3::new(0.0, 1.0, 0.0), 4.0)
            .map_or(at, |h| Vec3::new(at.x, h.point.y, at.z));
        let (owner_name, party) = (p.sheet.name.clone(), p.party.party);
        let fires = tick + ms_ticks(w.countdown_ms);
        let item = w.item.clone();
        if let Some(mut p) = self.world.get_mut::<Player>(entity)
            && realm_rules::items::take_items(&mut p.sheet, &item, 1).is_ok()
        {
            p.sheet.revision += 1;
            p.dirty_since.get_or_insert(tick);
        }
        self.send_sheet(conn);
        self.next_waylink += 1;
        self.waylinks.push(Waylink {
            id: self.next_waylink,
            owner: entity,
            owner_name,
            party,
            pos: at,
            dest: dest.to_owned(),
            fires,
            holders: vec![entity],
        });
        let i = self.waylinks.len() - 1;
        self.show_waylink(i, 0);
    }

    /// Whether `player` may ride Waylink `i` right now (`slack` metres
    /// beyond its reach).
    fn may_ride(&self, i: usize, player: Entity, slack: f32) -> Result<(), &'static str> {
        let wl = &self.waylinks[i];
        let rules = self.rules();
        let level_min = rules.travel.nodes.get(&wl.dest).map_or(0, |n| n.level_min);
        let p = self.world.get::<Player>(player).ok_or("gone")?;
        if player != wl.owner && (wl.party == 0 || p.party.party != wl.party) {
            return Err("not_in_party");
        }
        if p.dead_until != 0 || p.trip.is_some() {
            return Err("out_of_range");
        }
        if planar_distance(p.body.pos, wl.pos) > rules.travel.waylink.grab_radius + slack
            || (p.body.pos.y - wl.pos.y).abs() >= 3.0
        {
            return Err("out_of_range");
        }
        if p.body.mounted || p.restraint.riding(p.last_input_tick + 1) {
            return Err("mounted");
        }
        if p.sheet.level < level_min {
            return Err("level_too_low");
        }
        Ok(())
    }

    /// `ClientMsg::WaylinkHold`.
    pub(super) fn hold_waylink(&mut self, conn: ConnId, entity: Entity, id: u32, hold: bool) {
        let Some(i) = self.waylinks.iter().position(|l| l.id == id) else {
            return self.travel_refused(conn, "waylink", "waylink_gone");
        };
        if hold {
            if let Err(reason) = self.may_ride(i, entity, 0.0) {
                return self.travel_refused(conn, "waylink", reason);
            }
            if !self.waylinks[i].holders.contains(&entity) {
                self.waylinks[i].holders.push(entity);
            }
        } else {
            self.waylinks[i].holders.retain(|h| *h != entity);
        }
        self.show_waylink(i, 0);
    }

    /// Tells Waylink `i`'s party (and its holders) how it stands.
    fn show_waylink(&mut self, i: usize, phase: u8) {
        let rules = self.rules();
        let wl = &self.waylinks[i];
        let view = WaylinkView {
            id: wl.id,
            phase,
            pos: [wl.pos.x, wl.pos.y, wl.pos.z],
            dest: wl.dest.clone(),
            label: rules
                .travel
                .nodes
                .get(&wl.dest)
                .map(|n| n.label.clone())
                .unwrap_or_default(),
            owner: self.net_id_of(wl.owner),
            owner_name: wl.owner_name.clone(),
            fires_tick: wl.fires,
            holders: wl.holders.iter().map(|h| self.net_id_of(*h)).collect(),
            radius: rules.travel.waylink.grab_radius,
        };
        let party = wl.party;
        let mut to: Vec<ConnId> = self
            .clients
            .iter()
            .filter(|(_, c)| {
                c.entity == wl.owner
                    || wl.holders.contains(&c.entity)
                    || (party != 0
                        && self
                            .world
                            .get::<Player>(c.entity)
                            .is_some_and(|p| p.party.party == party))
            })
            .map(|(conn, _)| *conn)
            .collect();
        to.sort_unstable();
        for conn in to {
            self.send_control(conn, &ServerMsg::Waylink(view.clone()));
        }
    }

    /// Waylinks whose countdown ran out fire; an owner who left takes its
    /// boot's chance with it.
    pub(super) fn advance_waylinks(&mut self) {
        let tick = self.tick;
        let mut i = 0;
        while i < self.waylinks.len() {
            let owner_here = self.world.get::<Player>(self.waylinks[i].owner).is_some();
            if !owner_here {
                self.waylinks[i].holders.clear();
                self.show_waylink(i, 2);
                self.waylinks.remove(i);
                continue;
            }
            if tick >= self.waylinks[i].fires {
                self.fire_waylink(i);
                self.waylinks.remove(i);
                continue;
            }
            i += 1;
        }
    }

    /// Carries everyone still holding on and allowed to go; nobody: the
    /// boot comes back to its owner (or lies in a chest at its feet).
    fn fire_waylink(&mut self, i: usize) {
        let rules = self.rules();
        let holders = self.waylinks[i].holders.clone();
        let riders: Vec<Entity> = holders
            .into_iter()
            .filter(|h| self.may_ride(i, *h, 1.0).is_ok())
            .collect();
        let Some(dest) = rules.travel.nodes.get(&self.waylinks[i].dest) else {
            return;
        };
        if riders.is_empty() {
            let owner = self.waylinks[i].owner;
            let item = rules.new_item(&rules.travel.waylink.item, 1);
            let tick = self.tick;
            let mut full = None;
            if let Some(mut p) = self.world.get_mut::<Player>(owner) {
                if realm_rules::items::add_item(&mut p.sheet, item.clone(), &rules).is_ok() {
                    p.sheet.revision += 1;
                    p.dirty_since.get_or_insert(tick);
                } else {
                    full = Some(p.body.pos);
                }
            }
            if let Some(at) = full {
                self.drop_chest(at, vec![item]);
            }
            if let Some(conn) = self.conn_of(owner) {
                self.send_sheet(conn);
            }
            self.waylinks[i].holders.clear();
            self.show_waylink(i, 2);
            return;
        }
        let seed = xorshift(&mut self.dice_state);
        let n = riders.len().min(usize::from(u8::MAX)) as u8;
        self.waylinks[i].holders.clone_from(&riders);
        self.show_waylink(i, 1);
        for (slot, rider) in riders.into_iter().enumerate() {
            let Some(conn) = self.conn_of(rider) else {
                continue;
            };
            let trip = Trip {
                arrival: Arrival {
                    map: dest.map.clone(),
                    landing: Landing::Scatter {
                        node: dest.id.clone(),
                        seed,
                        slot: slot as u8,
                        riders: n,
                    },
                    kind: TripKind::Waylink,
                    copy: 0,
                },
                label: dest.label.clone(),
                cost: None,
                combat_lock_ms: 0,
            };
            self.start_trip(conn, rider, trip, false);
        }
    }

    /// Joins arriving here: the coordinator first when there is one.
    pub(super) fn join(&mut self, conn: ConnId, join: PendingJoin) {
        let character = join.ticket.character;
        if self.still_leaving(character) {
            let _ = join
                .reply
                .send(JoinReply::Refused("still travelling; try again".to_owned()));
            return;
        }
        if self.coord_tx.is_some() {
            if !self.coord_up {
                let _ = join.reply.send(JoinReply::Refused(
                    "the realm is not ready; try again".to_owned(),
                ));
                return;
            }
            eprintln!("[claim] connection {conn} character {character}: asking the coordinator");
            self.pending.insert(conn, join);
            self.coord_send(MapMsg::Claim { conn, character });
            return;
        }
        self.join_here(conn, join, None);
    }
}
