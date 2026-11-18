//! Chat and parties on the map server. A plain line is heard within 40 m on
//! this map; a line starting with `!` is a shout to the whole realm; `/p`
//! speaks to the party; `/invite`, `/accept`, `/decline`, `/leave`,
//! `/kick` and `/promote` manage it. Shouts, party lines and the party book
//! live in the coordinator; this server forwards them, tells it who is on
//! the map and how party members fare, and hands players what comes back.
//! Without a coordinator, local chat still works and the rest says so.
//!
//! The old game's `net.route_chat` and `authority.party_command`.

use realm_proto::control::ServerMsg;
use realm_proto::coord::{
    CHANNEL_LOCAL, CHANNEL_SYSTEM, CoordMsg, MapMsg, PartyCmd, PartyView, clean_chat,
};
use realm_sim::SIM_HZ;

use super::{ConnId, Entity, Player, Sim};

/// A plain line carries this far (3D).
const LOCAL_RADIUS: f32 = 40.0;
/// One line per this many ticks per player (old: 250 ms); faster lines are
/// dropped.
const CHAT_GAP_TICKS: u32 = 8;
/// Party members' frames are refreshed this often.
const VITALS_TICKS: u32 = SIM_HZ;

impl Sim {
    /// Sends to the coordinator; false when there is none.
    pub(super) fn coord_send(&self, msg: MapMsg) -> bool {
        self.coord_up
            && self
                .coord_tx
                .as_ref()
                .is_some_and(|tx| tx.send(msg).is_ok())
    }

    pub(super) fn system_line(&mut self, conn: ConnId, text: &str) {
        self.send_control(
            conn,
            &ServerMsg::Chat {
                channel: CHANNEL_SYSTEM,
                from: String::new(),
                text: text.to_owned(),
                speaker: 0,
            },
        );
    }

    /// A line or a /command from a player.
    pub(super) fn chat(&mut self, conn: ConnId, player: Entity, raw: &str) {
        let tick = self.tick;
        let Some(mut p) = self.world.get_mut::<Player>(player) else {
            return;
        };
        if tick < p.chat_ready {
            return;
        }
        p.chat_ready = tick + CHAT_GAP_TICKS;
        let (character, name, pos) = (p.sheet.id, p.sheet.name.clone(), p.body.pos);
        let text = clean_chat(raw);
        if text.is_empty() {
            return;
        }
        if text.starts_with('/') {
            return self.command(conn, player, character, &text);
        }
        if let Some(rest) = text.strip_prefix('!') {
            let rest = clean_chat(rest);
            if !rest.is_empty()
                && !self.coord_send(MapMsg::Shout {
                    from: character,
                    text: rest,
                })
            {
                self.system_line(conn, "Shouting reaches no one right now.");
            }
            return;
        }
        let speaker = self.net_id_of(player);
        let hearers: Vec<ConnId> = self
            .clients
            .iter()
            .filter(|(_, c)| {
                self.world
                    .get::<Player>(c.entity)
                    .is_some_and(|q| (q.body.pos - pos).length() <= LOCAL_RADIUS)
            })
            .map(|(conn, _)| *conn)
            .collect();
        let msg = ServerMsg::Chat {
            channel: CHANNEL_LOCAL,
            from: name,
            text,
            speaker,
        };
        for c in hearers {
            self.send_control(c, &msg);
        }
    }

    fn command(&mut self, conn: ConnId, player: Entity, character: u64, text: &str) {
        let (word, rest) = text.split_once(' ').unwrap_or((text, ""));
        let rest = rest.trim();
        if self.duel_command(conn, player, &word.to_lowercase(), rest) {
            return;
        }
        if word.eq_ignore_ascii_case("/ga") {
            return self.ga_command(conn, player, character, rest);
        }
        let party = |cmd: PartyCmd| MapMsg::Party {
            from: character,
            cmd,
        };
        let msg = match word.to_lowercase().as_str() {
            "/p" | "/party" => {
                if rest.is_empty() {
                    return;
                }
                MapMsg::PartyChat {
                    from: character,
                    text: rest.to_owned(),
                }
            }
            "/invite" if !rest.is_empty() => party(PartyCmd::Invite(rest.to_owned())),
            "/accept" => party(PartyCmd::Accept),
            "/decline" => party(PartyCmd::Decline),
            "/leave" => party(PartyCmd::Leave),
            "/kick" if !rest.is_empty() => party(PartyCmd::Kick(rest.to_owned())),
            "/promote" if !rest.is_empty() => party(PartyCmd::Promote(rest.to_owned())),
            _ => {
                return self.system_line(
                    conn,
                    "Unknown command. Try: /p, /invite <name>, /accept, /decline, /leave, /kick <name>, /promote <name>, /duel <name>, /gduel <name>, /daccept, /ddecline, /yield, !shout",
                );
            }
        };
        if !self.coord_send(msg) {
            self.system_line(conn, "Parties are not available right now.");
        }
    }

    /// The character's entity on this map.
    pub(super) fn player_of(&self, character: u64) -> Option<(ConnId, Entity)> {
        self.clients
            .iter()
            .find(|(_, c)| c.character == character)
            .map(|(conn, c)| (*conn, c.entity))
    }

    /// What the coordinator sent.
    pub(super) fn coord_event(&mut self, msg: CoordMsg) {
        match msg {
            CoordMsg::Line {
                to,
                channel,
                from,
                text,
            } => {
                if let Some((conn, _)) = self.player_of(to) {
                    self.send_control(
                        conn,
                        &ServerMsg::Chat {
                            channel,
                            from,
                            text,
                            speaker: 0,
                        },
                    );
                }
            }
            CoordMsg::Broadcast {
                channel,
                from,
                text,
            } => {
                let msg = ServerMsg::Chat {
                    channel,
                    from,
                    text,
                    speaker: 0,
                };
                let conns: Vec<ConnId> = self.clients.keys().copied().collect();
                for conn in conns {
                    self.send_control(conn, &msg);
                }
            }
            CoordMsg::Invite { to, from } => {
                if let Some((conn, _)) = self.player_of(to) {
                    self.send_control(conn, &ServerMsg::PartyInvite { from });
                }
            }
            CoordMsg::Party { to, view } => {
                if let Some((conn, entity)) = self.player_of(to) {
                    if let Some(mut p) = self.world.get_mut::<Player>(entity) {
                        p.party = view.clone();
                    }
                    self.send_control(conn, &ServerMsg::Party(view));
                }
            }
            CoordMsg::Admit {
                conn,
                character,
                sheet,
                arrival,
            } => self.claim_answered(conn, character, sheet, arrival),
            CoordMsg::Refuse { conn, reason } => self.claim_refused(conn, reason),
            CoordMsg::Evict { character } => self.evict(character),
            CoordMsg::Reserved {
                character,
                ok,
                reason,
            } => self.reserved(character, ok, &reason),
            CoordMsg::Travel {
                character,
                map,
                address,
                ticket,
            } => self.deliver_ticket(character, map, address, ticket),
            CoordMsg::Maps(maps) => self.open_maps = maps,
            CoordMsg::OpenCopy { req, spec } => self.open_copy(req, &spec),
            CoordMsg::CopyOpened { req, copy, reason } => self.copy_opened(req, copy, &reason),
            CoordMsg::Runs(runs) => self.dungeon_runs = runs,
            CoordMsg::Boards(boards) => self.boards = boards,
            CoordMsg::RecordSet {
                dungeon,
                difficulty,
                ms,
                names,
                characters,
            } => self.record_set(&dungeon, difficulty, ms, &names, &characters),
            CoordMsg::Maintenance {
                state,
                reason,
                seconds,
            } => self.maintenance_told(state, reason, seconds),
            CoordMsg::SaveAll { barrier } => self.save_barrier(barrier),
            CoordMsg::Gas(names) => self.gas_told(names),
            CoordMsg::Weather { rain } => self.weather_told(rain),
            CoordMsg::DisconnectAll { barrier } => self.disconnect_all(barrier),
            CoordMsg::Notice(msg) => {
                let conns: Vec<ConnId> = self.clients.keys().copied().collect();
                for conn in conns {
                    self.send_control(conn, &msg);
                }
            }
        }
    }

    /// The coordinator is (back): tell it who is here.
    pub(super) fn coord_link_up(&mut self) {
        self.coord_up = true;
        let entities: Vec<Entity> = self.clients.values().map(|c| c.entity).collect();
        for e in entities {
            self.announce(e);
        }
        self.resend_departures();
    }

    /// The coordinator went away: parties are unknown until it is back.
    pub(super) fn coord_link_down(&mut self) {
        self.coord_up = false;
        self.open_maps.clear();
        self.coord_lost();
        let conns: Vec<(ConnId, Entity)> =
            self.clients.iter().map(|(k, c)| (*k, c.entity)).collect();
        for (conn, e) in conns {
            let had = self
                .world
                .get_mut::<Player>(e)
                .map(|mut p| std::mem::take(&mut p.party).party != 0)
                .unwrap_or(false);
            if had {
                self.send_control(conn, &ServerMsg::Party(PartyView::default()));
            }
        }
    }

    /// Tells the coordinator a player is on this map.
    pub(super) fn announce(&self, player: Entity) {
        if let Some(p) = self.world.get::<Player>(player) {
            self.coord_send(MapMsg::Online {
                character: p.sheet.id,
                account: p.account,
                name: p.sheet.name.clone(),
                house: p.sheet.house.clone(),
                level: p.sheet.level,
            });
        }
    }

    /// Party members' frames: health, mana, level, death, once a second.
    pub(super) fn party_vitals(&mut self) {
        if !self.coord_up || !self.tick.is_multiple_of(VITALS_TICKS) {
            return;
        }
        let mut q = self.world.query::<&Player>();
        let msgs: Vec<MapMsg> = q
            .iter(&self.world)
            .filter(|p| p.party.party != 0)
            .map(|p| MapMsg::Vitals {
                character: p.sheet.id,
                level: p.sheet.level,
                hp: libm::ceilf(p.hp.max(0.0)) as u32,
                max_hp: p.max_hp as u32,
                mana: libm::ceilf(p.caster.mana.max(0.0)) as u32,
                max_mana: p.caster.max_mana as u32,
                dead: p.dead_until != 0,
            })
            .collect();
        for m in msgs {
            self.coord_send(m);
        }
    }
}
