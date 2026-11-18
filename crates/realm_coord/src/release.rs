//! Taking characters out of the world for the login service: before a
//! character or an account is deleted, and when a new password ends an
//! account's other sessions (POST /admin/characters/release).
//!
//! A character in the world is asked to leave as for a newer login: its map
//! takes it out the way any logout does (a duel forfeited, a dungeon run and
//! its party left, the save written) and releases it. With `bar_seconds` the
//! character is then refused new seats for that long, longer than any ticket
//! already handed out, and the answer waits until it is really out. The names
//! given also leave the weekly boards held here, so the next board write
//! cannot bring them back.

use std::collections::HashSet;
use std::time::{Duration, Instant};

use realm_proto::coord::CoordMsg;
use realm_proto::persist::{PersistMsg, forget_board_names};
use realm_rules::names::name_key;
use serde_json::{Value, json};
use tokio::sync::oneshot;

use crate::{Book, Seat};

/// How long a release may take before the login service is told to try again.
const RELEASE_WAIT: Duration = Duration::from_secs(8);

/// A release waiting for its characters to be out.
pub struct Pending {
    waiting: HashSet<u64>,
    answer: oneshot::Sender<Value>,
    deadline: Instant,
}

impl Book {
    pub fn is_barred(&self, character: u64) -> bool {
        self.barred
            .get(&character)
            .is_some_and(|until| Instant::now() < *until)
    }

    pub fn release_characters(
        &mut self,
        characters: &[u64],
        names: &[String],
        bar: Duration,
        answer: oneshot::Sender<Value>,
    ) {
        let now = Instant::now();
        let mut waiting = HashSet::new();
        for &c in characters {
            if !bar.is_zero() {
                self.barred.insert(c, now + bar);
            }
            self.reservations.remove(&c);
            match self.seats.remove(&c) {
                Some(Seat::On { link, claim }) => {
                    if let Some(login) = claim {
                        self.refuse(login);
                    }
                    if self.links.contains_key(&link) {
                        self.seats.insert(c, Seat::On { link, claim: None });
                        self.to_link(link, CoordMsg::Evict { character: c });
                        waiting.insert(c);
                    } else {
                        self.offline(c);
                    }
                }
                // Between maps, or nowhere: nothing has to answer.
                Some(Seat::Transit { .. }) | None => self.offline(c),
            }
        }
        self.forget_names(names);
        println!(
            "[seat] release of {} character(s), {} in the world, barred {} s",
            characters.len(),
            waiting.len(),
            bar.as_secs()
        );
        // A kick (no bar) is not waited for.
        if waiting.is_empty() || bar.is_zero() {
            let _ = answer.send(json!({"ok": true}));
            return;
        }
        self.pending_releases.push(Pending {
            waiting,
            answer,
            deadline: now + RELEASE_WAIT,
        });
    }

    /// `character` has left its map.
    pub fn character_released(&mut self, character: u64) {
        let mut i = 0;
        while i < self.pending_releases.len() {
            self.pending_releases[i].waiting.remove(&character);
            if self.pending_releases[i].waiting.is_empty() {
                let done = self.pending_releases.swap_remove(i);
                let _ = done.answer.send(json!({"ok": true}));
            } else {
                i += 1;
            }
        }
    }

    pub fn sweep_releases(&mut self) {
        let now = Instant::now();
        self.barred.retain(|_, until| now < *until);
        let mut i = 0;
        while i < self.pending_releases.len() {
            if now >= self.pending_releases[i].deadline {
                let late = self.pending_releases.swap_remove(i);
                eprintln!("[seat] release timed out waiting for {:?}", late.waiting);
                let _ = late.answer.send(json!({"ok": false, "error": "timeout"}));
            } else {
                i += 1;
            }
        }
    }

    /// These names off the week's boards, here and in the store.
    fn forget_names(&mut self, names: &[String]) {
        let keys: HashSet<String> = names.iter().map(|n| name_key(n)).collect();
        if keys.is_empty() {
            return;
        }
        let mut changed = false;
        for board in self.boards.values_mut() {
            if forget_board_names(board, &keys) {
                changed = true;
                if let Some(persist) = &self.persist {
                    let board = board.clone();
                    persist.keep(|req| PersistMsg::SaveBoard { req, board });
                }
            }
        }
        if changed {
            self.boards_changed();
        }
    }
}
