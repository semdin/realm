//! Moderation, realm-wide: bans and mutes by account, kicks, block lists,
//! players' reports, the audit trail, and the limits on what reaches every
//! player (shouts, invitations).
//!
//! Sanctions and blocks live in the persistence service (loaded at start, each
//! change kept as it happens); without it they last as long as the
//! coordinator. A GA acts in chat (`/ga ban ...`, sim/moderation.rs), the
//! operator on the admin surface (POST /admin/sanction). Every action goes to
//! the `audit` table.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use realm_proto::coord::{CoordMsg, ModOrder, ReportNote};
use realm_proto::persist::{
    BlockRow, CharacterRef, PersistMsg, PersistReply, ReportRow, SanctionRow,
};
use serde_json::{Value, json};
use tokio::sync::Mutex;

use crate::Book;

const REASON_MAX: usize = 200;
const BLOCKS_MAX: usize = 200;
/// Reports kept in memory (all of them, without a persistence service).
const REPORTS_KEPT: usize = 200;
const REPORT_GAP: Duration = Duration::from_secs(30);
const REPORT_SAME_TARGET: Duration = Duration::from_secs(600);
const REPORT_WINDOW: Duration = Duration::from_secs(24 * 3600);
const REPORTS_PER_WINDOW: usize = 10;
/// One invitation to the same player in this long; this many a minute in all.
const INVITE_SAME_TARGET: Duration = Duration::from_secs(30);
const INVITES_PER_MINUTE: usize = 8;
/// The same shout again waits this long.
const SHOUT_REPEAT: Duration = Duration::from_secs(120);
/// Shouts the whole realm carries: per second, and in a burst.
const REALM_SHOUTS_PER_S: f64 = 1.0;
const REALM_SHOUT_BURST: f64 = 5.0;

fn env_number(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(default)
}

pub fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn live(row: &SanctionRow, now: u64) -> bool {
    row.until == 0 || row.until > now
}

pub struct Moderation {
    bans: HashMap<u64, SanctionRow>,
    mutes: HashMap<u64, SanctionRow>,
    /// Account -> the accounts it blocked, with the name it knew them by.
    blocks: HashMap<u64, BTreeMap<u64, String>>,
    reports: VecDeque<ReportRow>,
    next_report: u64,
    /// Each account's reports of the last day: when, and of whom.
    reported: HashMap<u64, VecDeque<(Instant, String)>>,
    /// Each account's last shout and its text.
    shouted: HashMap<u64, (Instant, String)>,
    shout_tokens: f64,
    shout_at: Instant,
    shout_cooldown: Duration,
    shout_min_level: u16,
    /// Invitations sent lately: inviter -> (when, to whom).
    invited: HashMap<u64, VecDeque<(Instant, u64)>>,
    swept: Instant,
    /// The book itself, for answers that wait on the persistence service.
    pub me: Weak<Mutex<Book>>,
}

impl Default for Moderation {
    fn default() -> Self {
        Self {
            bans: HashMap::new(),
            mutes: HashMap::new(),
            blocks: HashMap::new(),
            reports: VecDeque::new(),
            next_report: 0,
            reported: HashMap::new(),
            shouted: HashMap::new(),
            shout_tokens: REALM_SHOUT_BURST,
            shout_at: Instant::now(),
            shout_cooldown: Duration::from_secs(env_number("REALM_SHOUT_COOLDOWN_S", 30)),
            shout_min_level: env_number("REALM_SHOUT_MIN_LEVEL", 5).min(u64::from(u16::MAX)) as u16,
            invited: HashMap::new(),
            swept: Instant::now(),
            me: Weak::new(),
        }
    }
}

impl Book {
    pub fn load_moderation(&mut self, sanctions: Vec<SanctionRow>, blocks: Vec<BlockRow>) {
        for row in sanctions {
            let list = if row.kind == "ban" {
                &mut self.moderation.bans
            } else {
                &mut self.moderation.mutes
            };
            list.insert(row.account, row);
        }
        for b in blocks {
            self.moderation
                .blocks
                .entry(b.account)
                .or_default()
                .insert(b.blocked, b.name);
        }
    }

    /// The ban standing against `account`.
    pub fn ban_of(&self, account: u64) -> Option<&SanctionRow> {
        self.moderation
            .bans
            .get(&account)
            .filter(|r| live(r, unix_now()))
    }

    /// One line of the audit trail (also in the service's log).
    pub fn audit(&self, character: Option<u64>, kind: &str, detail: Value) {
        let detail = detail.to_string();
        println!("[audit] {kind} character={character:?} {detail}");
        if let Some(persist) = &self.persist {
            let kind = kind.to_owned();
            persist.keep(|req| PersistMsg::Audit {
                req,
                character,
                kind,
                detail,
            });
        }
    }

    fn mutes_msg(&self) -> CoordMsg {
        let now = unix_now();
        CoordMsg::Mutes(
            self.moderation
                .mutes
                .values()
                .filter(|r| live(r, now))
                .map(|r| (r.account, r.until))
                .collect(),
        )
    }

    fn mutes_changed(&self) {
        let msg = self.mutes_msg();
        for l in self.links.values() {
            let _ = l.tx.send(msg.clone());
        }
    }

    /// A map that links hears who is muted.
    pub fn tell_moderation(&self, link: u64) {
        self.to_link(link, self.mutes_msg());
    }

    fn blocks_msg(&self, account: u64) -> CoordMsg {
        let list = self.moderation.blocks.get(&account);
        CoordMsg::Blocks {
            account,
            blocked: list.map_or_else(Vec::new, |l| l.keys().copied().collect()),
            names: list.map_or_else(Vec::new, |l| l.values().cloned().collect()),
        }
    }

    /// A character came onto a map: the map hears its account's block list.
    pub fn tell_blocks(&self, link: u64, account: u64) {
        self.to_link(link, self.blocks_msg(account));
    }

    /// Whether `hearer`'s account has blocked `speaker`'s.
    pub fn blocks(&self, hearer: u64, speaker: u64) -> bool {
        let account = |c: &u64| self.online.get(c).map(|o| o.account);
        match (account(&hearer), account(&speaker)) {
            (Some(h), Some(s)) => self
                .moderation
                .blocks
                .get(&h)
                .is_some_and(|l| l.contains_key(&s)),
            _ => false,
        }
    }

    fn characters_of(&self, account: u64) -> Vec<u64> {
        self.online
            .iter()
            .filter(|(_, o)| o.account == account)
            .map(|(c, _)| *c)
            .collect()
    }

    fn tell_account(&self, account: u64, kind: &str, reason: &str, until: u64) {
        for character in self.characters_of(account) {
            self.send(
                character,
                CoordMsg::Sanctioned {
                    character,
                    kind: kind.to_owned(),
                    reason: reason.to_owned(),
                    until,
                },
            );
        }
    }

    /// Does `verb` to `account`. `minutes` 0 is permanent. Returns what stands
    /// now, or why it was not done (not_online, not_sanctioned, bad_action).
    pub fn sanction(
        &mut self,
        by: &str,
        account: u64,
        target: &str,
        verb: &str,
        minutes: u32,
        reason: &str,
    ) -> Result<Value, &'static str> {
        let reason: String = reason.trim().chars().take(REASON_MAX).collect();
        let now = unix_now();
        let until = if minutes == 0 {
            0
        } else {
            now + u64::from(minutes) * 60
        };
        let online = self.characters_of(account);
        match verb {
            "kick" => {
                if online.is_empty() {
                    return Err("not_online");
                }
                self.tell_account(account, "kick", &reason, 0);
            }
            "ban" | "mute" => {
                let row = SanctionRow {
                    account,
                    kind: verb.to_owned(),
                    until,
                    reason: reason.clone(),
                    by: by.to_owned(),
                    at: now,
                };
                if let Some(persist) = &self.persist {
                    let row = row.clone();
                    persist.keep(|req| PersistMsg::SetSanction { req, row });
                }
                if verb == "ban" {
                    self.moderation.bans.insert(account, row);
                    // A login still waiting in line goes too.
                    self.capacity_forget(account);
                } else {
                    self.moderation.mutes.insert(account, row);
                    self.mutes_changed();
                }
                self.tell_account(account, verb, &reason, until);
            }
            "unban" | "unmute" => {
                let kind = &verb[2..];
                let list = if kind == "ban" {
                    &mut self.moderation.bans
                } else {
                    &mut self.moderation.mutes
                };
                if list.remove(&account).is_none() {
                    return Err("not_sanctioned");
                }
                if let Some(persist) = &self.persist {
                    let kind = kind.to_owned();
                    persist.keep(|req| PersistMsg::ClearSanction { req, account, kind });
                }
                if kind == "mute" {
                    self.mutes_changed();
                    self.tell_account(account, "unmute", "", 0);
                }
            }
            _ => return Err("bad_action"),
        }
        let detail = json!({
            "action": verb,
            "account": account,
            "target": target,
            "by": by,
            "reason": reason,
            "minutes": minutes,
            "until": until,
            "online": online.len(),
        });
        self.audit(online.first().copied(), "moderation", detail.clone());
        Ok(detail)
    }

    /// Looks `name` up in the store when nobody online has it, then goes on.
    fn find_then(
        &self,
        name: String,
        then: impl FnOnce(&mut Book, Option<CharacterRef>) + Send + 'static,
    ) {
        let (Some(persist), Some(book)) = (self.persist.clone(), self.moderation.me.upgrade())
        else {
            return;
        };
        tokio::spawn(async move {
            let found = match persist
                .call(|req| PersistMsg::FindCharacter { req, name })
                .await
            {
                Ok(PersistReply::Character { result: Ok(c), .. }) => c,
                _ => None,
            };
            then(&mut *book.lock().await, found);
        });
    }

    /// A GA's `/ga kick|mute|unmute|ban|unban` from a map.
    pub fn moderate_from_map(&mut self, by: u64, order: ModOrder) {
        if !self.is_ga(by) {
            return;
        }
        match self.named(&order.target) {
            Some(c) => {
                let (account, name) = self
                    .online
                    .get(&c)
                    .map_or((0, String::new()), |o| (o.account, o.name.clone()));
                self.moderate_found(by, account, &name, &order);
            }
            None if self.persist.is_some() => {
                let name = order.target.clone();
                self.find_then(name, move |b, found| match found {
                    Some(f) => b.moderate_found(by, f.account, &f.name, &order),
                    None => b.tell(by, format!("No character is called {}.", order.target)),
                });
            }
            None => self.tell(by, format!("{} is not online.", order.target)),
        }
    }

    fn moderate_found(&mut self, by: u64, account: u64, name: &str, order: &ModOrder) {
        if self.gas.contains(&account) {
            return self.tell(by, "A GA cannot act on another GA.");
        }
        let actor = self.name(by);
        let done = self.sanction(
            &actor,
            account,
            name,
            &order.verb,
            order.minutes,
            &order.reason,
        );
        let line = match done {
            Ok(_) => {
                let span = match (order.verb.as_str(), order.minutes) {
                    ("ban" | "mute", 0) => " permanently".to_owned(),
                    ("ban" | "mute", m) => format!(" for {m} min"),
                    _ => String::new(),
                };
                format!("Done: {} {name}{span}.", order.verb)
            }
            Err("not_online") => format!("{name} is not online."),
            Err("not_sanctioned") => format!("{name} has no such sanction."),
            Err(_) => "That action is not known.".to_owned(),
        };
        self.tell(by, line);
    }

    fn social(&self, to: u64, what: &str, ok: bool, reason: &str, name: &str) {
        self.send(
            to,
            CoordMsg::Social {
                to,
                what: what.to_owned(),
                ok,
                reason: reason.to_owned(),
                name: name.to_owned(),
            },
        );
    }

    /// `/block`, `/unblock` or the player menu.
    pub fn block_from_map(&mut self, from: u64, name: String, on: bool) {
        let what = if on { "block" } else { "unblock" };
        let Some(account) = self.online.get(&from).map(|o| o.account) else {
            return;
        };
        if !on {
            let key = name.to_lowercase();
            let listed = self.moderation.blocks.get(&account).and_then(|l| {
                l.iter()
                    .find(|(_, n)| n.to_lowercase() == key)
                    .map(|(id, n)| (*id, n.clone()))
            });
            if let Some((target, shown)) = listed {
                return self.set_block(from, account, target, &shown, false);
            }
        }
        if let Some(c) = self.named(&name)
            && let Some(o) = self.online.get(&c)
        {
            let (target, shown) = (o.account, o.name.clone());
            return self.set_block(from, account, target, &shown, on);
        }
        if self.persist.is_none() {
            return self.social(from, what, false, "not_found", &name);
        }
        let asked = name.clone();
        self.find_then(name, move |b, found| match found {
            Some(f) => b.set_block(from, account, f.account, &f.name, on),
            None => b.social(from, what, false, "not_found", &asked),
        });
    }

    fn set_block(&mut self, from: u64, account: u64, target: u64, name: &str, on: bool) {
        let what = if on { "block" } else { "unblock" };
        if target == account {
            return self.social(from, what, false, "self", name);
        }
        let list = self.moderation.blocks.entry(account).or_default();
        if on && list.len() >= BLOCKS_MAX && !list.contains_key(&target) {
            return self.social(from, what, false, "full", name);
        }
        if on {
            list.insert(target, name.to_owned());
        } else {
            list.remove(&target);
        }
        if let Some(persist) = &self.persist {
            let row = BlockRow {
                account,
                blocked: target,
                name: name.to_owned(),
            };
            persist.keep(|req| PersistMsg::SetBlock { req, row, on });
        }
        let links: Vec<u64> = self
            .characters_of(account)
            .iter()
            .filter_map(|c| self.online.get(c).map(|o| o.link))
            .collect();
        for link in links {
            self.tell_blocks(link, account);
        }
        self.social(from, what, true, "done", name);
    }

    /// A player's report, with the chat its map kept around it.
    pub fn report_from_map(&mut self, note: ReportNote) {
        let now = Instant::now();
        let target_key = note.target_name.to_lowercase();
        let log = self.moderation.reported.entry(note.account).or_default();
        while log.front().is_some_and(|(at, _)| now - *at > REPORT_WINDOW) {
            log.pop_front();
        }
        let refused = if log.back().is_some_and(|(at, _)| now - *at < REPORT_GAP) {
            Some("too_soon")
        } else if log.len() >= REPORTS_PER_WINDOW {
            Some("daily_limit")
        } else if log
            .iter()
            .any(|(at, t)| *t == target_key && now - *at < REPORT_SAME_TARGET)
        {
            Some("duplicate")
        } else {
            None
        };
        if let Some(reason) = refused {
            return self.social(note.reporter, "report", false, reason, &note.target_name);
        }
        log.push_back((now, target_key));
        let target = self.named(&note.target_name);
        let target_account = target
            .and_then(|c| self.online.get(&c))
            .map_or(0, |o| o.account);
        self.moderation.next_report += 1;
        let row = ReportRow {
            id: self.moderation.next_report,
            at: unix_now(),
            reporter_account: note.account,
            reporter_character: note.reporter,
            reporter_name: self.name(note.reporter),
            target_account,
            target_character: target.unwrap_or(note.target_character),
            target_name: note.target_name.clone(),
            category: note.category.clone(),
            text: note.text.clone(),
            map: note.map.clone(),
            context: serde_json::to_string(&note.context).unwrap_or_else(|_| "[]".to_owned()),
            status: "open".to_owned(),
        };
        if let Some(persist) = &self.persist {
            let row = row.clone();
            persist.keep(|req| PersistMsg::AddReport { req, row });
        }
        self.audit(
            Some(note.reporter),
            "report",
            json!({"target": row.target_name, "category": row.category, "map": row.map}),
        );
        self.moderation.reports.push_back(row);
        while self.moderation.reports.len() > REPORTS_KEPT {
            self.moderation.reports.pop_front();
        }
        self.social(note.reporter, "report", true, "sent", &note.target_name);
    }

    /// May `from` shout `text` now? Tells it why not.
    pub fn shout_allowed(&mut self, from: u64, text: &str) -> bool {
        let Some((account, level)) = self.online.get(&from).map(|o| (o.account, o.level)) else {
            return false;
        };
        if level < self.moderation.shout_min_level {
            let need = self.moderation.shout_min_level;
            self.tell(from, format!("You can shout from level {need}."));
            return false;
        }
        let now = Instant::now();
        let cooldown = self.moderation.shout_cooldown;
        if let Some((at, last)) = self.moderation.shouted.get(&account) {
            let since = now - *at;
            if since < cooldown {
                let left = (cooldown - since).as_secs() + 1;
                self.tell(from, format!("You can shout again in {left} s."));
                return false;
            }
            if since < SHOUT_REPEAT && last.eq_ignore_ascii_case(text) {
                self.tell(from, "You just shouted that.");
                return false;
            }
        }
        let m = &mut self.moderation;
        m.shout_tokens = (m.shout_tokens + (now - m.shout_at).as_secs_f64() * REALM_SHOUTS_PER_S)
            .min(REALM_SHOUT_BURST);
        m.shout_at = now;
        if m.shout_tokens < 1.0 {
            self.tell(from, "The realm is loud right now. Try again in a moment.");
            return false;
        }
        m.shout_tokens -= 1.0;
        m.shouted.insert(account, (now, text.to_owned()));
        true
    }

    /// May `from` invite `target` now? Tells it why not.
    pub fn invite_allowed(&mut self, from: u64, target: u64) -> bool {
        if self.blocks(target, from) {
            let name = self.name(target);
            self.tell(from, format!("{name} is not accepting invitations."));
            return false;
        }
        let Some(account) = self.online.get(&from).map(|o| o.account) else {
            return false;
        };
        let now = Instant::now();
        let sent = self.moderation.invited.entry(account).or_default();
        while sent
            .front()
            .is_some_and(|(at, _)| now - *at > Duration::from_secs(60))
        {
            sent.pop_front();
        }
        let again = sent
            .iter()
            .any(|(at, t)| *t == target && now - *at < INVITE_SAME_TARGET);
        if again || sent.len() >= INVITES_PER_MINUTE {
            self.tell(from, "Wait a moment before inviting again.");
            return false;
        }
        sent.push_back((now, target));
        true
    }

    /// Sanctions that ran out, and what the limits no longer need.
    pub fn moderation_sweep(&mut self) {
        let now = Instant::now();
        if now - self.moderation.swept < Duration::from_secs(5) {
            return;
        }
        self.moderation.swept = now;
        let t = unix_now();
        self.moderation.bans.retain(|_, r| live(r, t));
        let before = self.moderation.mutes.len();
        let ended: Vec<u64> = self
            .moderation
            .mutes
            .values()
            .filter(|r| !live(r, t))
            .map(|r| r.account)
            .collect();
        self.moderation.mutes.retain(|_, r| live(r, t));
        if self.moderation.mutes.len() != before {
            self.mutes_changed();
            for account in ended {
                self.tell_account(account, "unmute", "", 0);
            }
        }
        let cooldown = SHOUT_REPEAT.max(self.moderation.shout_cooldown);
        self.moderation
            .shouted
            .retain(|_, (at, _)| now - *at < cooldown);
        self.moderation.invited.retain(|_, l| {
            l.back()
                .is_some_and(|(at, _)| now - *at < Duration::from_secs(60))
        });
        self.moderation
            .reported
            .retain(|_, l| l.back().is_some_and(|(at, _)| now - *at < REPORT_WINDOW));
    }

    /// GET /admin/sanctions.
    pub fn sanctions_view(&self) -> Value {
        let now = unix_now();
        let row = |r: &SanctionRow| {
            json!({"account": r.account, "kind": r.kind, "until": r.until,
                   "reason": r.reason, "by": r.by, "at": r.at})
        };
        let list: Vec<Value> = self
            .moderation
            .bans
            .values()
            .chain(self.moderation.mutes.values())
            .filter(|r| live(r, now))
            .map(row)
            .collect();
        json!({"ok": true, "sanctions": list})
    }

    /// POST /admin/access: what stands against an account (login and play).
    pub fn access_view(&self, account: u64) -> Value {
        match self.ban_of(account) {
            Some(r) => json!({"ok": true, "banned": true, "reason": r.reason, "until": r.until}),
            None => json!({"ok": true, "banned": false}),
        }
    }
}

/// Gives the book its own handle and loads what the store keeps. A coordinator
/// that came up without the bans would let the banned back in.
pub async fn start(
    book: &Arc<Mutex<Book>>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let persist = {
        let mut b = book.lock().await;
        b.moderation.me = Arc::downgrade(book);
        b.persist.clone()
    };
    let Some(persist) = persist else {
        return Ok(());
    };
    let answer = tokio::time::timeout(
        Duration::from_secs(30),
        persist.call_until_answered(|req| PersistMsg::LoadModeration { req }),
    )
    .await;
    match answer {
        Ok(Ok(PersistReply::Moderation {
            result: Ok((sanctions, blocks)),
            ..
        })) => {
            println!(
                "[moderation] {} sanction(s), {} block(s) from the persistence service",
                sanctions.len(),
                blocks.len()
            );
            book.lock().await.load_moderation(sanctions, blocks);
            Ok(())
        }
        Ok(other) => Err(format!("loading sanctions: {other:?}").into()),
        Err(_) => Err("the persistence service never gave the sanctions".into()),
    }
}

fn report_json(r: &ReportRow) -> Value {
    let context: Value = serde_json::from_str(&r.context).unwrap_or_else(|_| json!([]));
    json!({
        "id": r.id, "at": r.at, "status": r.status, "category": r.category, "text": r.text,
        "map": r.map, "context": context,
        "reporter": {"account": r.reporter_account, "character": r.reporter_character, "name": r.reporter_name},
        "target": {"account": r.target_account, "character": r.target_character, "name": r.target_name},
    })
}

/// POST /admin/sanction {action, name | character | account, minutes, reason, by}.
pub async fn admin_sanction(book: &Arc<Mutex<Book>>, body: &Value) -> (u16, Value) {
    let action = body["action"].as_str().unwrap_or("");
    if !matches!(action, "kick" | "mute" | "unmute" | "ban" | "unban") {
        return (400, json!({"ok": false, "error": "bad_action"}));
    }
    if matches!(action, "ban" | "mute") && !body["minutes"].is_u64() {
        return (
            400,
            json!({"ok": false, "error": "minutes_required", "message": "minutes: a number, 0 for permanent"}),
        );
    }
    let minutes = body["minutes"]
        .as_u64()
        .unwrap_or(0)
        .min(u64::from(u32::MAX)) as u32;
    let reason = body["reason"].as_str().unwrap_or("");
    let by = body["by"].as_str().unwrap_or("operator");
    let name = body["name"].as_str().unwrap_or("").trim();
    let character = body["character"].as_u64();
    let (mut target, persist) = {
        let b = book.lock().await;
        let online = character
            .filter(|c| b.online.contains_key(c))
            .or_else(|| b.named(name));
        let found = online.and_then(|c| b.online.get(&c).map(|o| (o.account, o.name.clone())));
        (found, b.persist.clone())
    };
    if let Some(account) = body["account"].as_u64().filter(|a| *a > 0) {
        target = Some((account, name.to_owned()));
    }
    if target.is_none()
        && let Some(persist) = persist
    {
        if !name.is_empty() {
            let name = name.to_owned();
            if let Ok(PersistReply::Character {
                result: Ok(Some(c)),
                ..
            }) = persist
                .call(|req| PersistMsg::FindCharacter { req, name })
                .await
            {
                target = Some((c.account, c.name));
            }
        } else if let Some(character) = character
            && let Ok(PersistReply::Owner {
                result: Ok(Some(account)),
                ..
            }) = persist
                .call(|req| PersistMsg::Owner { req, character })
                .await
        {
            target = Some((account, String::new()));
        }
    }
    let Some((account, shown)) = target else {
        return (404, json!({"ok": false, "error": "not_found"}));
    };
    match book
        .lock()
        .await
        .sanction(by, account, &shown, action, minutes, reason)
    {
        Ok(detail) => (200, json!({"ok": true, "done": detail})),
        Err(e) => (409, json!({"ok": false, "error": e})),
    }
}

/// GET /admin/reports: the newest, from the store when there is one.
pub async fn admin_reports(book: &Arc<Mutex<Book>>) -> (u16, Value) {
    let (persist, kept) = {
        let b = book.lock().await;
        let kept: Vec<Value> = b.moderation.reports.iter().rev().map(report_json).collect();
        (b.persist.clone(), kept)
    };
    let Some(persist) = persist else {
        return (200, json!({"ok": true, "reports": kept}));
    };
    match persist
        .call(|req| PersistMsg::LoadReports {
            req,
            limit: 100,
            open_only: false,
        })
        .await
    {
        Ok(PersistReply::Reports { result: Ok(r), .. }) => {
            let list: Vec<Value> = r.iter().map(report_json).collect();
            (200, json!({"ok": true, "reports": list}))
        }
        _ => (503, json!({"ok": false, "error": "store_unavailable"})),
    }
}

/// POST /admin/reports/close {id, status}.
pub async fn admin_close_report(book: &Arc<Mutex<Book>>, body: &Value) -> (u16, Value) {
    let Some(id) = body["id"].as_u64() else {
        return (400, json!({"ok": false, "error": "id required"}));
    };
    let status = body["status"].as_str().unwrap_or("closed").to_owned();
    let mut b = book.lock().await;
    if let Some(r) = b.moderation.reports.iter_mut().find(|r| r.id == id) {
        r.status.clone_from(&status);
    }
    if let Some(persist) = &b.persist {
        let status = status.clone();
        persist.keep(|req| PersistMsg::CloseReport { req, id, status });
    }
    b.audit(None, "report_closed", json!({"id": id, "status": status}));
    (200, json!({"ok": true}))
}
