//! The map's side of the realm's maintenance (the coordinator runs the
//! state machine): every player hears the state; from SAVING on the world
//! stands still (no input, no creature, no command); in MAINTENANCE it is
//! idle. The save barrier saves everyone now and answers when the store
//! confirmed each save (or said it failed); the empty-out takes everyone
//! out as a logout and answers when the last seat was released.
//!
//! A save the store could not make is tried again every 5 s; a leaver is
//! released only once its save landed, so a failing store never loses a
//! character's progress to an older stored copy.

use std::collections::HashMap;

use realm_proto::JoinReply;
use realm_proto::control::ServerMsg;
use realm_proto::coord::MapMsg;

use realm_sim::SIM_HZ;

use super::{ConnId, Sim};

/// A failed save is tried again this long after.
const SAVE_RETRY_TICKS: u32 = 5 * SIM_HZ;

#[derive(Default)]
pub struct Maintenance {
    /// The last state the coordinator told (empty: ONLINE), why, the
    /// seconds then left and the tick it came.
    pub state: String,
    pub reason: String,
    pub seconds: u32,
    pub told_at: u32,
    /// From SAVING on: nothing moves, nothing is done.
    pub frozen: bool,
    /// MAINTENANCE: the simulation does no work at all.
    pub idle: bool,
    /// A save barrier: its id, the saves it waits for (character ->
    /// revision), and how many landed or failed.
    pub barrier: Option<(u64, HashMap<u64, u64>, u32, u32)>,
    /// An empty-out: its id and how many it took out.
    pub emptying: Option<(u64, u32)>,
    /// Saves to try again: (tick due, character).
    pub retries: Vec<(u32, u64)>,
}

impl Sim {
    /// The coordinator's state: to every player, and what it means here.
    pub(super) fn maintenance_told(&mut self, state: String, reason: String, seconds: u32) {
        let tick = self.tick;
        let m = &mut self.maintenance;
        // Every link hears the state; nothing to do or tell when it is no news.
        if state == "ONLINE" && m.state.is_empty() {
            return;
        }
        m.frozen = matches!(
            state.as_str(),
            "SAVING" | "DISCONNECTING" | "MAINTENANCE" | "FAILED"
        );
        m.idle = state == "MAINTENANCE";
        m.state = if state == "ONLINE" {
            String::new()
        } else {
            state.clone()
        };
        m.reason = reason.clone();
        m.seconds = seconds;
        m.told_at = tick;
        println!(
            "[maintenance] {state}{}{}",
            if seconds > 0 {
                format!(" ({seconds} s)")
            } else {
                String::new()
            },
            if self.maintenance.frozen {
                ", world frozen"
            } else {
                ""
            }
        );
        let msg = ServerMsg::Maintenance {
            state,
            reason,
            seconds,
        };
        let conns: Vec<ConnId> = self.clients.keys().copied().collect();
        for conn in conns {
            self.send_control(conn, &msg);
        }
    }

    /// A player who comes in while a countdown runs (a traveller) hears it
    /// with the seconds that are left.
    pub(super) fn tell_maintenance(&mut self, conn: ConnId) {
        if self.maintenance.state.is_empty() {
            return;
        }
        let gone = (self.tick - self.maintenance.told_at) / SIM_HZ;
        let msg = ServerMsg::Maintenance {
            state: self.maintenance.state.clone(),
            reason: self.maintenance.reason.clone(),
            seconds: self.maintenance.seconds.saturating_sub(gone),
        };
        self.send_control(conn, &msg);
    }

    /// Saves every player now, and waits for those leaving too.
    pub(super) fn save_barrier(&mut self, barrier: u64) {
        let mut waiting = HashMap::new();
        let entities: Vec<_> = self.clients.values().map(|c| c.entity).collect();
        for entity in entities {
            if let Some(sheet) = self.sheet_of(entity) {
                waiting.insert(sheet.id, sheet.revision);
                self.save(sheet);
            }
        }
        for (character, d) in &self.departing {
            if !d.saved {
                waiting.insert(*character, d.sheet.revision);
            }
        }
        println!(
            "[maintenance] save barrier {barrier}: {} save(s)",
            waiting.len()
        );
        self.maintenance.barrier = Some((barrier, waiting, 0, 0));
        self.barrier_check();
    }

    /// Takes everyone out (told first, saved and released as a logout);
    /// joins still loading are refused.
    pub(super) fn disconnect_all(&mut self, barrier: u64) {
        let msg = ServerMsg::Maintenance {
            state: "DISCONNECTING".to_owned(),
            reason: self.maintenance.reason.clone(),
            seconds: 0,
        };
        let conns: Vec<ConnId> = self.clients.keys().copied().collect();
        let removed = conns.len() as u32;
        for conn in conns {
            self.send_control(conn, &msg);
            self.leave_world(conn, None);
        }
        // Travellers still holding their connection for a ticket hear it
        // too and are let go.
        let bytes = bytes::Bytes::from(realm_proto::control::encode_server(&msg));
        for d in self.departing.values_mut() {
            if let Some((_, control)) = d.channels.take() {
                let _ = control.try_send(bytes.clone());
            }
            d.conn = None;
        }
        for (_, join) in self.pending.drain() {
            let _ = join
                .reply
                .send(JoinReply::Refused("maintenance".to_owned()));
        }
        println!("[maintenance] empty-out {barrier}: {removed} player(s) taken out");
        self.maintenance.emptying = Some((barrier, removed));
        self.empty_check();
    }

    /// The store answered a save.
    pub(super) fn save_answered(&mut self, character: u64, revision: u64, ok: bool) {
        self.stats.saves_done += 1;
        if !ok {
            self.stats.saves_failed += 1;
        }
        if ok {
            if self
                .unsaved
                .get(&character)
                .is_some_and(|s| s.revision <= revision)
            {
                self.unsaved.remove(&character);
            }
            self.departure_saved(character, revision);
        } else {
            self.maintenance
                .retries
                .push((self.tick + SAVE_RETRY_TICKS, character));
        }
        if let Some((_, waiting, saved, failed)) = self.maintenance.barrier.as_mut()
            && waiting.get(&character).is_some_and(|r| *r <= revision)
        {
            waiting.remove(&character);
            if ok {
                *saved += 1;
            } else {
                *failed += 1;
            }
        }
        self.barrier_check();
    }

    /// Every tick, frozen or not: saves to try again, barriers to answer.
    pub(super) fn maintenance_tick(&mut self) {
        let tick = self.tick;
        let due: Vec<u64> = self
            .maintenance
            .retries
            .iter()
            .filter(|(at, _)| tick >= *at)
            .map(|(_, c)| *c)
            .collect();
        self.maintenance.retries.retain(|(at, _)| tick < *at);
        for character in due {
            if let Some(sheet) = self.unsaved.get(&character).cloned() {
                self.save(sheet);
            }
        }
        self.empty_check();
    }

    fn barrier_check(&mut self) {
        let Some((barrier, waiting, saved, failed)) = &self.maintenance.barrier else {
            return;
        };
        if !waiting.is_empty() {
            return;
        }
        let msg = MapMsg::Saved {
            barrier: *barrier,
            saved: *saved,
            failed: *failed,
        };
        println!("[maintenance] save barrier {barrier}: saved {saved}, failed {failed}");
        self.maintenance.barrier = None;
        self.coord_send(msg);
    }

    fn empty_check(&mut self) {
        let Some((barrier, removed)) = self.maintenance.emptying else {
            return;
        };
        // A released traveller is the coordinator's now.
        if !self.clients.is_empty() || self.departing.values().any(|d| !d.released) {
            return;
        }
        println!("[maintenance] empty-out {barrier}: nobody left");
        self.maintenance.emptying = None;
        self.coord_send(MapMsg::Emptied { barrier, removed });
    }
}
