//! Moderation on a map: who is muted, whose lines each player does not want,
//! the limits on what one player may say, the short chat memory reports draw
//! on, and the commands (`/ga kick|mute|unmute|ban|unban`, `/report`,
//! `/block`, `/unblock`). The coordinator keeps the lists; see
//! realm_coord/src/moderation.rs.
//!
//! Chat is kept in memory only, the last CHAT_LOG lines of this map for at most
//! CHAT_LOG_S seconds; a report stores the lines of the two players concerned.

use std::collections::{HashMap, HashSet, VecDeque};

use realm_proto::control::ServerMsg;
use realm_proto::coord::{CHAT_MAX, MapMsg, ModOrder, ReportNote, clean_chat};
use realm_sim::SIM_HZ;

use super::{ConnId, Entity, Player, Sim, now_unix};

const CHAT_LOG: usize = 400;
const CHAT_LOG_S: u64 = 15 * 60;
/// Lines of context a report carries.
const REPORT_LINES: usize = 40;
const REPORT_TEXT_MAX: usize = 300;
const CATEGORIES: [&str; 6] = ["harassment", "hate", "spam", "cheating", "name", "other"];

const WINDOW_TICKS: u32 = 10 * SIM_HZ;
const LOCAL_PER_WINDOW: usize = 8;
const PARTY_PER_WINDOW: usize = 12;
const COMMANDS_PER_WINDOW: usize = 15;
/// The same line this many times running, inside a window, is dropped.
const REPEATS_ALLOWED: u32 = 3;
const SLOW_DOWN_EVERY: u32 = 5 * SIM_HZ;
/// One duel challenge to the same player in this long; this many a minute.
const DUEL_SAME_TICKS: u32 = 30 * SIM_HZ;
const DUELS_PER_MINUTE: usize = 6;

#[derive(Clone, Copy)]
pub(super) enum Said {
    Local,
    Party,
    Command,
}

#[derive(Default)]
pub struct ChatLimits {
    local: VecDeque<u32>,
    party: VecDeque<u32>,
    commands: VecDeque<u32>,
    last: String,
    repeats: u32,
    last_at: u32,
    told_at: u32,
    duels: VecDeque<(u32, u64)>,
}

struct Logged {
    at: u64,
    channel: u8,
    from: String,
    text: String,
}

#[derive(Default)]
pub struct MapModeration {
    /// Muted accounts and when it ends (0: permanent).
    mutes: HashMap<u64, u64>,
    /// Account -> the accounts it blocked (accounts playing here).
    blocks: HashMap<u64, HashSet<u64>>,
    log: VecDeque<Logged>,
}

fn room(window: &mut VecDeque<u32>, tick: u32, limit: usize) -> bool {
    while window
        .front()
        .is_some_and(|t| tick.saturating_sub(*t) >= WINDOW_TICKS)
    {
        window.pop_front();
    }
    if window.len() >= limit {
        return false;
    }
    window.push_back(tick);
    true
}

/// `90`, `30m`, `2h`, `7d` in minutes; `perm` and `0` are 0 (permanent).
fn minutes_of(word: &str) -> Option<u32> {
    let w = word.to_lowercase();
    if matches!(w.as_str(), "perm" | "permanent" | "kalici" | "kalıcı" | "0") {
        return Some(0);
    }
    let (number, unit) = match w.char_indices().last()? {
        (i, c) if c.is_ascii_alphabetic() => (&w[..i], c),
        _ => (w.as_str(), 'm'),
    };
    let n: u32 = number.parse().ok().filter(|n| *n > 0)?;
    // Turkish too: saat (hours), gün (days).
    n.checked_mul(match unit {
        'm' => 1,
        'h' | 's' => 60,
        'd' | 'g' => 1440,
        _ => return None,
    })
}

/// A name from the front of `text`: `"Two Words"`, or one word with `_` for
/// its spaces. Returns it and the rest.
fn take_name(text: &str) -> (String, &str) {
    let text = text.trim_start();
    if let Some(rest) = text.strip_prefix('"')
        && let Some((name, after)) = rest.split_once('"')
    {
        return (name.trim().to_owned(), after.trim_start());
    }
    let (word, after) = text.split_once(' ').unwrap_or((text, ""));
    (word.replace('_', " "), after.trim_start())
}

impl Sim {
    pub(super) fn account_of(&self, conn: ConnId) -> u64 {
        self.clients.get(&conn).map_or(0, |c| c.account)
    }

    /// Whether `hearer`'s account has blocked `speaker`'s.
    pub(super) fn hears_not(&self, hearer: u64, speaker: u64) -> bool {
        self.moderation
            .blocks
            .get(&hearer)
            .is_some_and(|b| b.contains(&speaker))
    }

    /// Tells a muted player so; true when it is.
    pub(super) fn muted(&mut self, conn: ConnId) -> bool {
        let account = self.account_of(conn);
        let Some(until) = self.moderation.mutes.get(&account).copied() else {
            return false;
        };
        let now = now_unix();
        if until != 0 && until <= now {
            self.moderation.mutes.remove(&account);
            return false;
        }
        let line = if until == 0 {
            "You are muted.".to_owned()
        } else {
            format!("You are muted for {} more min.", (until - now).div_ceil(60))
        };
        self.system_line(conn, &line);
        true
    }

    /// May this player say this now? A flood is dropped, with one word now
    /// and then; everyone else never notices.
    pub(super) fn may_say(&mut self, conn: ConnId, player: Entity, kind: Said, text: &str) -> bool {
        let tick = self.tick;
        let Some(mut p) = self.world.get_mut::<Player>(player) else {
            return false;
        };
        let l = &mut p.chat_limits;
        let mut ok = match kind {
            Said::Local => room(&mut l.local, tick, LOCAL_PER_WINDOW),
            Said::Party => room(&mut l.party, tick, PARTY_PER_WINDOW),
            Said::Command => room(&mut l.commands, tick, COMMANDS_PER_WINDOW),
        };
        if !matches!(kind, Said::Command) {
            if l.last == text && tick.saturating_sub(l.last_at) < WINDOW_TICKS {
                l.repeats += 1;
                ok = ok && l.repeats < REPEATS_ALLOWED;
            } else {
                l.last = text.to_owned();
                l.repeats = 0;
            }
            l.last_at = tick;
        }
        let tell = !ok && tick.saturating_sub(l.told_at) >= SLOW_DOWN_EVERY;
        if tell {
            l.told_at = tick;
        }
        if tell {
            self.system_line(conn, "You are sending messages too quickly.");
        }
        ok
    }

    /// A line heard on this map, for reports.
    pub(super) fn remember_line(&mut self, channel: u8, from: &str, text: &str) {
        let now = now_unix();
        let log = &mut self.moderation.log;
        log.push_back(Logged {
            at: now,
            channel,
            from: from.to_owned(),
            text: text.to_owned(),
        });
        while log.len() > CHAT_LOG
            || log
                .front()
                .is_some_and(|l| now.saturating_sub(l.at) > CHAT_LOG_S)
        {
            log.pop_front();
        }
    }

    pub(super) fn mutes_told(&mut self, list: Vec<(u64, u64)>) {
        self.moderation.mutes = list.into_iter().collect();
    }

    pub(super) fn blocks_told(&mut self, account: u64, blocked: Vec<u64>, names: Vec<String>) {
        self.moderation
            .blocks
            .insert(account, blocked.into_iter().collect());
        let conns: Vec<ConnId> = self
            .clients
            .iter()
            .filter(|(_, c)| c.account == account)
            .map(|(conn, _)| *conn)
            .collect();
        for conn in conns {
            self.send_control(conn, &ServerMsg::Blocks(names.clone()));
        }
    }

    /// The coordinator's word on a character: told, and for a kick or a ban
    /// taken out of the world (saved and released as any logout).
    pub(super) fn sanctioned(&mut self, character: u64, kind: String, reason: String, until: u64) {
        let Some((conn, _)) = self.player_of(character) else {
            return;
        };
        let leaves = matches!(kind.as_str(), "kick" | "ban");
        self.send_control(
            conn,
            &ServerMsg::Sanction {
                kind,
                reason,
                until,
            },
        );
        if leaves {
            self.leave_world(conn, None);
        }
    }

    /// May this player challenge `target` (a character) to a duel now?
    pub(super) fn duel_allowed(
        &mut self,
        from: Entity,
        target: Entity,
    ) -> Result<(), &'static str> {
        let tick = self.tick;
        let account = |sim: &Self, e: Entity| {
            sim.clients
                .values()
                .find(|c| c.entity == e)
                .map_or(0, |c| c.account)
        };
        let (mine, theirs) = (account(self, from), account(self, target));
        if self.hears_not(theirs, mine) {
            return Err("That player is not accepting challenges.");
        }
        let Some(id) = self.world.get::<Player>(target).map(|p| p.sheet.id) else {
            return Ok(());
        };
        let Some(mut p) = self.world.get_mut::<Player>(from) else {
            return Ok(());
        };
        let asked = &mut p.chat_limits.duels;
        while asked
            .front()
            .is_some_and(|(t, _)| tick.saturating_sub(*t) >= 60 * SIM_HZ)
        {
            asked.pop_front();
        }
        let again = asked
            .iter()
            .any(|(t, c)| *c == id && tick.saturating_sub(*t) < DUEL_SAME_TICKS);
        if again || asked.len() >= DUELS_PER_MINUTE {
            return Err("Wait a moment before challenging again.");
        }
        asked.push_back((tick, id));
        Ok(())
    }

    /// `/ga kick|mute|unmute|ban|unban ...`; false when `verb` is none of them.
    pub(super) fn moderation_command(
        &mut self,
        conn: ConnId,
        character: u64,
        verb: &str,
        arg: &str,
    ) -> bool {
        let verb = match verb.to_lowercase().as_str() {
            "kick" | "at" => "kick",
            "mute" | "sustur" => "mute",
            "unmute" | "konustur" | "konuştur" => "unmute",
            "ban" | "yasakla" => "ban",
            "unban" | "yasakkaldir" | "yasakkaldır" => "unban",
            _ => return false,
        };
        let (target, rest) = take_name(arg);
        let timed = matches!(verb, "mute" | "ban");
        let (first, after) = rest.split_once(' ').unwrap_or((rest, ""));
        let (minutes, reason) = match (timed, minutes_of(first)) {
            (true, Some(m)) => (Some(m), after),
            (true, None) => (None, rest),
            (false, _) => (Some(0), rest),
        };
        let Some(minutes) = minutes.filter(|_| !target.is_empty()) else {
            let usage = match verb {
                "mute" => "Usage: /ga mute Name 30m|2h|7d|perm reason",
                "ban" => "Usage: /ga ban Name 30m|2h|7d|perm reason",
                "kick" => "Usage: /ga kick Name reason",
                "unmute" => "Usage: /ga unmute Name",
                _ => "Usage: /ga unban Name",
            };
            self.system_line(conn, usage);
            return true;
        };
        let order = ModOrder {
            verb: verb.to_owned(),
            target,
            minutes,
            reason: clean_chat(reason),
        };
        if !self.coord_send(MapMsg::Moderate {
            by: character,
            order,
        }) {
            self.system_line(conn, "GA commands are not available right now.");
        }
        true
    }

    fn social_result(&mut self, conn: ConnId, what: &str, reason: &str, name: &str) {
        self.send_control(
            conn,
            &ServerMsg::SocialResult {
                what: what.to_owned(),
                ok: false,
                reason: reason.to_owned(),
                name: name.to_owned(),
            },
        );
    }

    /// `ClientMsg::Block`, `/block`, `/unblock`.
    pub(super) fn block_request(&mut self, conn: ConnId, character: u64, name: &str, on: bool) {
        let name: String = name.trim().chars().take(32).collect();
        let what = if on { "block" } else { "unblock" };
        if name.is_empty() {
            return self.social_result(conn, what, "not_found", "");
        }
        let msg = MapMsg::Block {
            from: character,
            name: name.clone(),
            on,
        };
        if !self.coord_send(msg) {
            self.social_result(conn, what, "unavailable", &name);
        }
    }

    /// `ClientMsg::Report`, `/report Name [category] [text]`.
    pub(super) fn report_request(
        &mut self,
        conn: ConnId,
        player: Entity,
        target: u64,
        name: &str,
        category: &str,
        text: &str,
    ) {
        let name: String = name.trim().chars().take(32).collect();
        let Some((reporter, reporter_name)) = self
            .world
            .get::<Player>(player)
            .map(|p| (p.sheet.id, p.sheet.name.clone()))
        else {
            return;
        };
        if name.is_empty() || name.eq_ignore_ascii_case(&reporter_name) {
            return self.social_result(conn, "report", "not_found", &name);
        }
        let category = if CATEGORIES.contains(&category) {
            category
        } else {
            "other"
        };
        let mut body = clean_chat(text);
        body = body.chars().take(REPORT_TEXT_MAX.min(CHAT_MAX)).collect();
        let context: Vec<String> = {
            let lines: Vec<String> = self
                .moderation
                .log
                .iter()
                .rev()
                .filter(|l| {
                    l.from.eq_ignore_ascii_case(&name)
                        || l.from.eq_ignore_ascii_case(&reporter_name)
                })
                .take(REPORT_LINES)
                .map(|l| format!("{} [{}] {}: {}", l.at, l.channel, l.from, l.text))
                .collect();
            lines.into_iter().rev().collect()
        };
        let note = ReportNote {
            reporter,
            account: self.account_of(conn),
            target_character: target,
            target_name: name.clone(),
            category: category.to_owned(),
            text: body,
            map: self.game.map.clone(),
            context,
        };
        if !self.coord_send(MapMsg::Report(Box::new(note))) {
            self.social_result(conn, "report", "unavailable", &name);
        }
    }

    /// The player commands; false when `word` is none of them.
    pub(super) fn social_command(
        &mut self,
        conn: ConnId,
        player: Entity,
        character: u64,
        word: &str,
        rest: &str,
    ) -> bool {
        match word {
            "/block" | "/engelle" if !rest.is_empty() => {
                let (name, _) = take_name(rest);
                self.block_request(conn, character, &name, true);
            }
            "/unblock" | "/engelkaldir" | "/engelkaldır" if !rest.is_empty() => {
                let (name, _) = take_name(rest);
                self.block_request(conn, character, &name, false);
            }
            "/report" | "/sikayet" | "/şikayet" if !rest.is_empty() => {
                let (name, after) = take_name(rest);
                let (first, text) = after.split_once(' ').unwrap_or((after, ""));
                let first = first.to_lowercase();
                if CATEGORIES.contains(&first.as_str()) {
                    self.report_request(conn, player, 0, &name, &first, text);
                } else {
                    self.report_request(conn, player, 0, &name, "other", after);
                }
            }
            _ => return false,
        }
        true
    }
}
