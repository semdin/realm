//! Game admins and the weather, realm-wide.
//!
//! GAs are characters, by name (case does not matter): the list is kept by
//! the persistence service (`--persist`) or in `--ga <file.json>` (an array
//! of names), and seeded from REALM_GA (comma separated). The first GA is made through POST /admin/ga; a GA makes
//! others in game with `/ga add Name`. Every map hears the list and the
//! weather when it links and whenever they change.

use std::path::Path;

use realm_proto::coord::CoordMsg;
use realm_proto::persist::PersistMsg;
use serde_json::{Value, json};

use crate::Book;

pub fn clean(name: &str) -> String {
    name.trim().to_lowercase()
}

/// The names kept in the file.
pub fn from_file(file: Option<&Path>) -> Vec<String> {
    file.and_then(|path| std::fs::read_to_string(path).ok())
        .map(|text| serde_json::from_str(&text).unwrap_or_default())
        .unwrap_or_default()
}

/// The kept names and REALM_GA.
pub fn with_seed(kept: Vec<String>) -> std::collections::BTreeSet<String> {
    let mut out = std::collections::BTreeSet::new();
    out.extend(kept.iter().map(|n| clean(n)).filter(|n| !n.is_empty()));
    if let Ok(seed) = std::env::var("REALM_GA") {
        out.extend(seed.split(',').map(clean).filter(|n| !n.is_empty()));
    }
    out
}

impl Book {
    pub fn gas_msg(&self) -> CoordMsg {
        CoordMsg::Gas(self.gas.iter().cloned().collect())
    }

    /// A map that links hears the list and the weather.
    pub fn tell_ga(&self, link: u64) {
        self.to_link(link, self.gas_msg());
        self.to_link(link, CoordMsg::Weather { rain: self.rain });
    }

    fn is_ga(&self, character: u64) -> bool {
        self.online
            .get(&character)
            .is_some_and(|o| self.gas.contains(&clean(&o.name)))
    }

    /// Makes `name` a GA (or takes it back); true when the list changed.
    pub fn set_ga(&mut self, name: &str, on: bool) -> bool {
        let key = clean(name);
        if key.is_empty() || key.chars().count() > 32 {
            return false;
        }
        let changed = if on {
            self.gas.insert(key)
        } else {
            self.gas.remove(&key)
        };
        if !changed {
            return false;
        }
        if let Some(persist) = &self.persist {
            let name = clean(name);
            persist.keep(|req| PersistMsg::SetGa { req, name, on });
        }
        if let Some(path) = &self.ga_file {
            let names: Vec<&String> = self.gas.iter().collect();
            if let Ok(text) = serde_json::to_string_pretty(&names)
                && let Err(e) = std::fs::write(path, text)
            {
                eprintln!("[ga] cannot keep the list in {}: {e}", path.display());
            }
        }
        println!("[ga] {} {}", if on { "+" } else { "-" }, clean(name));
        let msg = self.gas_msg();
        for l in self.links.values() {
            let _ = l.tx.send(msg.clone());
        }
        true
    }

    /// A GA's `/ga add|remove` from a map.
    pub fn ga_from_map(&mut self, by: u64, name: &str, on: bool) {
        if self.is_ga(by) {
            self.set_ga(name, on);
        }
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

    /// POST /admin/ga {"name": "...", "on": true}.
    pub fn admin_ga(&mut self, body: &Value) -> (u16, Value) {
        let name = body["name"].as_str().unwrap_or("").trim();
        if name.is_empty() || name.chars().count() > 32 {
            return (400, json!({"ok": false, "error": "name required"}));
        }
        let changed = self.set_ga(name, body["on"].as_bool().unwrap_or(true));
        let ga: Vec<&String> = self.gas.iter().collect();
        (200, json!({"ok": true, "changed": changed, "ga": ga}))
    }
}
