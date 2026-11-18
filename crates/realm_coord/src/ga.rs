//! Game admins and the weather, realm-wide.
//!
//! A GA is an account, by its id, which never changes and cannot be taken by
//! creating a name. The list comes from the deployment's configuration:
//! REALM_GA_ACCOUNTS (comma separated ids) in /etc/realm/realm.env, read when
//! the coordinator starts. Nothing typed in chat changes it. POST /admin/ga
//! (the operator's service token) adds or removes an account until the next
//! restart. Every map hears the list and the weather when it links and
//! whenever they change.

use std::collections::BTreeSet;

use realm_proto::coord::CoordMsg;
use serde_json::{Value, json};

use crate::Book;

/// REALM_GA_ACCOUNTS: account ids, comma separated.
pub fn from_env() -> BTreeSet<u64> {
    let mut out = BTreeSet::new();
    let Ok(list) = std::env::var("REALM_GA_ACCOUNTS") else {
        return out;
    };
    for part in list.split(',').map(str::trim).filter(|p| !p.is_empty()) {
        match part.parse::<u64>() {
            Ok(id) if id > 0 => {
                out.insert(id);
            }
            _ => eprintln!("[ga] REALM_GA_ACCOUNTS: {part:?} is not an account id; ignored"),
        }
    }
    out
}

impl Book {
    pub fn gas_msg(&self) -> CoordMsg {
        CoordMsg::Gas(self.gas.iter().copied().collect())
    }

    /// A map that links hears the list and the weather.
    pub fn tell_ga(&self, link: u64) {
        self.to_link(link, self.gas_msg());
        self.to_link(link, CoordMsg::Weather { rain: self.rain });
    }

    pub fn is_ga(&self, character: u64) -> bool {
        self.online
            .get(&character)
            .is_some_and(|o| self.gas.contains(&o.account))
    }

    /// Makes `account` a GA (or takes it back) until the next restart; true
    /// when the list changed.
    fn set_ga(&mut self, account: u64, on: bool) -> bool {
        let changed = if on {
            self.gas.insert(account)
        } else {
            self.gas.remove(&account)
        };
        if changed {
            println!("[ga] {} account {account}", if on { "+" } else { "-" });
            let msg = self.gas_msg();
            for l in self.links.values() {
                let _ = l.tx.send(msg.clone());
            }
        }
        changed
    }

    /// A GA's `/ga rain` from a map.
    pub fn weather_from_map(&mut self, by: u64, rain: bool) {
        if !self.is_ga(by) || self.rain == rain {
            return;
        }
        self.rain = rain;
        println!("[weather] rain {}", if rain { "starts" } else { "stops" });
        for l in self.links.values() {
            let _ = l.tx.send(CoordMsg::Weather { rain });
        }
    }

    /// POST /admin/ga {"account": id, "on": true}, or {"name": "..."} for the
    /// account of a character online right now (a name nobody is playing
    /// grants nothing). Lasts until the next restart: the lasting list is
    /// REALM_GA_ACCOUNTS.
    pub fn admin_ga(&mut self, body: &Value) -> (u16, Value) {
        let account = match (body["account"].as_u64(), body["name"].as_str()) {
            (Some(id), _) if id > 0 => id,
            (_, Some(name)) => {
                let online = self
                    .named(name.trim())
                    .and_then(|c| self.online.get(&c))
                    .map(|o| o.account);
                let Some(account) = online else {
                    return (404, json!({"ok": false, "error": "no such player online"}));
                };
                account
            }
            _ => return (400, json!({"ok": false, "error": "account required"})),
        };
        let changed = self.set_ga(account, body["on"].as_bool().unwrap_or(true));
        let ga: Vec<u64> = self.gas.iter().copied().collect();
        (
            200,
            json!({"ok": true, "changed": changed, "account": account, "ga": ga}),
        )
    }
}
