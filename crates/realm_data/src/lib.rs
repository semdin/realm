//! Content: the game's data files (items, skills, creatures, quests, maps,
//! spawns, loot, travel), shared by the servers, the client and the bots.
//!
//! Files are JSON under `content/data/`, authored by tools and by hand. Keys
//! starting with `_` are notes for authors and are ignored by every reader.
//! [`Content::load`] reads them, [`catalog::Catalog`] gives typed access to the
//! ids and checks every cross reference, and [`Content::hash`] is the
//! fingerprint client and server compare at login so both sides run the same
//! data.

pub mod catalog;
pub mod maps;
pub mod rename;

use std::collections::BTreeMap;
use std::path::Path;

use serde_json::Value;
use sha2::{Digest, Sha256};

/// Every content file by name (`items.json` -> its JSON).
#[derive(Clone, Debug, Default)]
pub struct Content {
    pub files: BTreeMap<String, Value>,
}

impl Content {
    /// Reads every `*.json` in `dir`.
    pub fn load(dir: &Path) -> Result<Self, String> {
        let mut files = BTreeMap::new();
        let entries = std::fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        for entry in entries {
            let path = entry.map_err(|e| e.to_string())?.path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let name = path
                .file_name()
                .and_then(|n| n.to_str())
                .ok_or("file name")?
                .to_owned();
            let text =
                std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
            let value: Value =
                serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
            files.insert(name, value);
        }
        if files.is_empty() {
            return Err(format!("{}: no content files", dir.display()));
        }
        Ok(Self { files })
    }

    /// Writes every file, pretty-printed, keys in authored order.
    pub fn save(&self, dir: &Path) -> Result<(), String> {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        for (name, value) in &self.files {
            let mut text = serde_json::to_string_pretty(value).map_err(|e| e.to_string())?;
            text.push('\n');
            let path = dir.join(name);
            std::fs::write(&path, text).map_err(|e| format!("{}: {e}", path.display()))?;
        }
        Ok(())
    }

    #[must_use]
    pub fn file(&self, name: &str) -> Option<&Value> {
        self.files.get(name)
    }

    /// SHA-256 over every file's data without author notes, in file-name
    /// order. Notes and formatting can change without changing the hash.
    #[must_use]
    pub fn hash(&self) -> String {
        let mut hasher = Sha256::new();
        for (name, value) in &self.files {
            hasher.update(name.as_bytes());
            hasher.update([0]);
            let data = without_notes(value);
            hasher.update(serde_json::to_vec(&data).unwrap_or_default());
            hasher.update([0]);
        }
        hasher
            .finalize()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }
}

/// The moving staircases a map's pack anchors, built from the content's
/// `staircases` specs.
pub fn staircases(
    content: &Content,
    pack: &realm_sim::pack::MapPack,
) -> Result<realm_sim::staircase::Staircases, String> {
    use realm_sim::staircase::{Staircase, StaircaseSpec, Staircases};
    let list = content
        .file("maps.json")
        .and_then(|m| m["staircases"].as_array())
        .cloned()
        .unwrap_or_default();
    let mut flights = Vec::new();
    for anchor in &pack.staircases {
        let raw = list
            .get(anchor.spec_index as usize)
            .ok_or_else(|| format!("{}: staircase {} has no spec", pack.map, anchor.spec_index))?;
        let spec: StaircaseSpec = serde_json::from_value(without_notes(raw))
            .map_err(|e| format!("staircase {}: {e}", anchor.spec_index))?;
        if spec.id != anchor.id {
            return Err(format!(
                "{}: staircase spec {} has id {}, the map expects {}",
                pack.map, anchor.spec_index, spec.id, anchor.id
            ));
        }
        flights.push(Staircase::new(
            spec,
            realm_sim::pack::v3(anchor.translation),
            anchor.yaw,
        ));
    }
    Ok(Staircases::new(flights))
}

/// A copy of `value` with every `_`-prefixed key removed, at any depth.
#[must_use]
pub fn without_notes(value: &Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.iter()
                .filter(|(k, _)| !k.starts_with('_'))
                .map(|(k, v)| (k.clone(), without_notes(v)))
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.iter().map(without_notes).collect()),
        other => other.clone(),
    }
}
