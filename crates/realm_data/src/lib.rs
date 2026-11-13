//! Content tables. Phase 1 adds the converter from the old game's JSON; for
//! now this holds the rename map every converted id goes through.

use std::collections::BTreeMap;

use serde::Deserialize;

/// `content/rename_map.toml`: old game id -> new id, grouped by kind.
#[derive(Debug, Deserialize)]
pub struct RenameMap {
    #[serde(flatten)]
    pub kinds: BTreeMap<String, BTreeMap<String, String>>,
}

impl RenameMap {
    /// Parses the map and rejects two old ids mapping to one new id.
    pub fn parse(text: &str) -> Result<Self, String> {
        let map: Self = toml::from_str(text).map_err(|e| e.to_string())?;
        for (kind, entries) in &map.kinds {
            let mut seen = BTreeMap::new();
            for (old, new) in entries {
                if let Some(other) = seen.insert(new.as_str(), old.as_str()) {
                    return Err(format!("{kind}: '{other}' and '{old}' both map to '{new}'"));
                }
            }
        }
        Ok(map)
    }

    /// New id for `old` of `kind`, or `old` itself when it needs no rename.
    #[must_use]
    pub fn rename<'a>(&'a self, kind: &str, old: &'a str) -> &'a str {
        self.kinds
            .get(kind)
            .and_then(|entries| entries.get(old))
            .map_or(old, String::as_str)
    }
}
