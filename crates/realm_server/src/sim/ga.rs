//! Game admins and the weather on a map. The coordinator keeps both for
//! the realm; GA rights belong to account ids from the deployment's
//! configuration (REALM_GA_ACCOUNTS), so nothing typed here grants them. A
//! map alone (no coordinator) keeps its own weather and, for development, the
//! GAs named by `--dev-ga`.
//!
//!   /ga rain on|off   (/ga yağmur aç|kapat; no word: the other way)
//!   /ga list          (/ga liste): the GAs on this map

use std::collections::HashSet;

use realm_proto::control::ServerMsg;
use realm_proto::coord::MapMsg;

use super::{ConnId, Entity, Player, Sim};

#[derive(Default)]
pub struct Admins {
    /// The realm's GAs (account ids), as the coordinator told.
    pub realm: HashSet<u64>,
    /// Development: GAs by name on a map started with `--dev-ga`.
    pub dev: HashSet<String>,
    pub rain: bool,
}

fn key(name: &str) -> String {
    name.trim().to_lowercase()
}

impl Sim {
    pub(super) fn is_ga(&self, player: Entity) -> bool {
        self.world.get::<Player>(player).is_some_and(|p| {
            self.admins.realm.contains(&p.account) || self.admins.dev.contains(&key(&p.sheet.name))
        })
    }

    pub(super) fn player_info(&self, entity: Entity) -> Option<ServerMsg> {
        let p = self.world.get::<Player>(entity)?;
        let gear = p
            .sheet
            .equipment
            .iter()
            .enumerate()
            .filter_map(|(i, item)| item.as_ref().map(|it| (i as u8, it.id.clone(), it.tier)))
            .collect();
        Some(ServerMsg::PlayerInfo {
            entity: self.net_id_of(entity),
            character: p.sheet.id,
            name: p.sheet.name.clone(),
            house: p.sheet.house.clone(),
            level: p.sheet.level,
            ga: self.is_ga(entity),
            look: p.sheet.look.clone(),
            gear,
            rank: self.game.rules.combat.house_rank(p.sheet.house_rep),
            titles: p.sheet.dungeons.titles.clone(),
        })
    }

    /// When what others see of a player changed (look, gear, level, rank,
    /// titles, GA), the players near it (and it) are told again.
    pub(super) fn refresh_info(&mut self, entity: Entity) {
        let Some(info) = self.player_info(entity) else {
            return;
        };
        let key = {
            use std::hash::{Hash, Hasher};
            let mut h = std::collections::hash_map::DefaultHasher::new();
            format!("{info:?}").hash(&mut h);
            h.finish()
        };
        let Some(pos) = self.world.get_mut::<Player>(entity).and_then(|mut p| {
            if p.info_key == key {
                return None;
            }
            let first = p.info_key == 0;
            p.info_key = key;
            // The first time is the join: those near ask for it themselves.
            (!first).then_some(p.body.pos)
        }) else {
            return;
        };
        let near: Vec<ConnId> = self
            .clients
            .iter()
            .filter(|(_, c)| {
                self.world
                    .get::<Player>(c.entity)
                    .is_some_and(|q| (q.body.pos - pos).length() <= super::INTEREST_RADIUS)
            })
            .map(|(conn, _)| *conn)
            .collect();
        for conn in near {
            self.send_control(conn, &info);
        }
    }

    /// The realm's GAs changed: everyone here sees the players whose
    /// emblem came or went.
    pub(super) fn gas_told(&mut self, accounts: Vec<u64>) {
        let before: Vec<(Entity, bool)> = self
            .clients
            .values()
            .map(|c| (c.entity, self.is_ga(c.entity)))
            .collect();
        self.admins.realm = accounts.into_iter().collect();
        let changed: Vec<Entity> = before
            .into_iter()
            .filter(|(e, was)| self.is_ga(*e) != *was)
            .map(|(e, _)| e)
            .collect();
        for e in changed {
            self.refresh_info(e);
        }
    }

    pub(super) fn weather_told(&mut self, rain: bool) {
        self.admins.rain = rain;
        let conns: Vec<ConnId> = self.clients.keys().copied().collect();
        for c in conns {
            self.send_control(c, &ServerMsg::Weather { rain });
        }
    }

    /// A joining player hears the weather.
    pub(super) fn tell_weather(&mut self, conn: ConnId) {
        let rain = self.admins.rain;
        self.send_control(conn, &ServerMsg::Weather { rain });
    }

    pub(super) fn ga_command(&mut self, conn: ConnId, player: Entity, character: u64, rest: &str) {
        if !self.is_ga(player) {
            return self.system_line(conn, "Only a GA can use /ga.");
        }
        let (verb, arg) = rest.split_once(' ').unwrap_or((rest, ""));
        let arg = arg.trim();
        let linked = self.coord_tx.is_some();
        match verb.to_lowercase().as_str() {
            "rain" | "yağmur" | "yagmur" => {
                let on = if arg.is_empty() {
                    !self.admins.rain
                } else {
                    matches!(
                        arg.to_lowercase().as_str(),
                        "on" | "aç" | "ac" | "1" | "start" | "başlat" | "baslat"
                    )
                };
                if linked {
                    if !self.coord_send(MapMsg::Weather {
                        by: character,
                        rain: on,
                    }) {
                        return self.system_line(conn, "GA commands are not available right now.");
                    }
                } else {
                    self.weather_told(on);
                }
                self.system_line(conn, if on { "Rain started." } else { "Rain stopped." });
            }
            "add" | "ekle" | "remove" | "sil" | "kaldır" | "kaldir" => {
                self.system_line(conn, "GA rights are set in the server configuration.");
            }
            "list" | "liste" => {
                let mut names: Vec<String> = self
                    .clients
                    .values()
                    .filter(|c| self.is_ga(c.entity))
                    .filter_map(|c| self.world.get::<Player>(c.entity))
                    .map(|p| p.sheet.name.clone())
                    .collect();
                names.sort();
                let line = format!("GAs: {}", names.join(", "));
                self.system_line(conn, &line);
            }
            _ => self.system_line(conn, "GA: /ga rain on|off, /ga list"),
        }
    }
}
