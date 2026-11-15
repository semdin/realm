//! Game admins and the weather on a map. The coordinator keeps both for
//! the realm; a map alone (no coordinator) keeps its own weather and the
//! GAs named by `--dev-ga`.
//!
//!   /ga rain on|off   (/ga yağmur aç|kapat; no word: the other way)
//!   /ga add <Name>    (/ga ekle)
//!   /ga remove <Name> (/ga sil, /ga kaldır)
//!   /ga list          (/ga liste)

use std::collections::HashSet;

use realm_proto::control::ServerMsg;
use realm_proto::coord::MapMsg;

use super::{ConnId, Entity, Player, Sim};

#[derive(Default)]
pub struct Admins {
    /// The realm's GAs (lowercase names), as the coordinator told.
    pub realm: HashSet<String>,
    /// Development: GAs on a map without a coordinator.
    pub dev: HashSet<String>,
    pub rain: bool,
}

fn key(name: &str) -> String {
    name.trim().to_lowercase()
}

impl Sim {
    pub(super) fn is_ga(&self, player: Entity) -> bool {
        self.world.get::<Player>(player).is_some_and(|p| {
            let k = key(&p.sheet.name);
            self.admins.realm.contains(&k) || self.admins.dev.contains(&k)
        })
    }

    pub(super) fn player_info(&self, entity: Entity) -> Option<ServerMsg> {
        let p = self.world.get::<Player>(entity)?;
        Some(ServerMsg::PlayerInfo {
            entity: self.net_id_of(entity),
            character: p.sheet.id,
            name: p.sheet.name.clone(),
            house: p.sheet.house.clone(),
            level: p.sheet.level,
            ga: self.is_ga(entity),
        })
    }

    /// The realm's GAs changed: everyone here sees the players whose
    /// emblem came or went.
    pub(super) fn gas_told(&mut self, names: Vec<String>) {
        let before: Vec<(Entity, bool)> = self
            .clients
            .values()
            .map(|c| (c.entity, self.is_ga(c.entity)))
            .collect();
        self.admins.realm = names.into_iter().collect();
        let changed: Vec<Entity> = before
            .into_iter()
            .filter(|(e, was)| self.is_ga(*e) != *was)
            .map(|(e, _)| e)
            .collect();
        let conns: Vec<ConnId> = self.clients.keys().copied().collect();
        for e in changed {
            if let Some(info) = self.player_info(e) {
                for c in &conns {
                    self.send_control(*c, &info);
                }
            }
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
                let on = matches!(verb.to_lowercase().as_str(), "add" | "ekle");
                if arg.is_empty() {
                    let usage = if on {
                        "Usage: /ga add Name"
                    } else {
                        "Usage: /ga remove Name"
                    };
                    return self.system_line(conn, usage);
                }
                if linked {
                    if !self.coord_send(MapMsg::Ga {
                        by: character,
                        name: arg.to_owned(),
                        on,
                    }) {
                        return self.system_line(conn, "GA commands are not available right now.");
                    }
                } else {
                    let mut names: Vec<String> = self.admins.realm.iter().cloned().collect();
                    if on {
                        names.push(key(arg));
                    } else {
                        names.retain(|n| *n != key(arg));
                    }
                    self.gas_told(names);
                }
                let line = if on {
                    format!("{arg} is now a GA.")
                } else {
                    format!("{arg} is no longer a GA.")
                };
                self.system_line(conn, &line);
            }
            "list" | "liste" => {
                let mut names: Vec<String> =
                    self.admins.realm.union(&self.admins.dev).cloned().collect();
                names.sort();
                let line = format!("GAs: {}", names.join(", "));
                self.system_line(conn, &line);
            }
            _ => self.system_line(
                conn,
                "GA: /ga rain on|off, /ga add Name, /ga remove Name, /ga list",
            ),
        }
    }
}
