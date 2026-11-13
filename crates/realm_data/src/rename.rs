//! Moves old game ids to realm ids (`content/rename_map.toml`) and finds any
//! franchise-derived name that is left.

use std::collections::BTreeMap;

use serde::Deserialize;
use serde_json::Value;

/// `content/rename_map.toml`: old id -> new id, grouped by kind.
#[derive(Debug, Deserialize)]
pub struct RenameMap {
    #[serde(flatten)]
    pub kinds: BTreeMap<String, BTreeMap<String, String>>,
}

/// What a rename pass changed, for the import report.
#[derive(Debug, Default)]
pub struct RenameReport {
    pub exact: usize,
    pub token: usize,
    pub text: usize,
    pub notes: usize,
}

/// A compiled rename map: exact ids, `_`-segment tokens and visible phrases.
pub struct Renamer {
    exact: BTreeMap<String, String>,
    /// Token segments and replacement, longest token first.
    tokens: Vec<(Vec<String>, String)>,
    /// Phrases, longest first.
    text: Vec<(String, String)>,
    /// Tokens and exact ids as lower-case `_` segments, longest first: the
    /// words looked for in file paths and asset names.
    words: Vec<(Vec<String>, String)>,
}

impl RenameMap {
    pub fn parse(text: &str) -> Result<Self, String> {
        let map: Self = toml::from_str(text).map_err(|e| e.to_string())?;
        for (kind, entries) in &map.kinds {
            // Tokens may alias: a singular and its plural are one name.
            if kind == "token" {
                continue;
            }
            let mut seen = BTreeMap::new();
            for (old, new) in entries {
                if let Some(other) = seen.insert(new.as_str(), old.as_str()) {
                    return Err(format!("{kind}: '{other}' and '{old}' both map to '{new}'"));
                }
            }
        }
        Ok(map)
    }

    /// Builds the renamer; fails when two exact kinds disagree on one old id.
    pub fn compile(&self) -> Result<Renamer, String> {
        let mut exact: BTreeMap<String, String> = BTreeMap::new();
        for (kind, entries) in &self.kinds {
            if kind == "token" || kind == "text" {
                continue;
            }
            for (old, new) in entries {
                if let Some(previous) = exact.insert(old.clone(), new.clone())
                    && previous != *new
                {
                    return Err(format!("'{old}' maps to both '{previous}' and '{new}'"));
                }
            }
        }
        let mut tokens: Vec<(Vec<String>, String)> = self
            .kinds
            .get("token")
            .into_iter()
            .flatten()
            .map(|(old, new)| {
                (
                    old.to_lowercase().split('_').map(str::to_owned).collect(),
                    new.clone(),
                )
            })
            .collect();
        tokens.sort_by(|a, b| b.0.len().cmp(&a.0.len()).then_with(|| a.0.cmp(&b.0)));
        let mut text: Vec<(String, String)> = self
            .kinds
            .get("text")
            .into_iter()
            .flatten()
            .map(|(a, b)| (a.clone(), b.clone()))
            .collect();
        text.sort_by(|a, b| b.0.len().cmp(&a.0.len()).then_with(|| a.0.cmp(&b.0)));
        let mut words: Vec<(Vec<String>, String)> = tokens.clone();
        for (old, new) in &exact {
            let key: Vec<String> = old.to_lowercase().split('_').map(str::to_owned).collect();
            if !words.iter().any(|(k, _)| *k == key) {
                words.push((key, new.clone()));
            }
        }
        words.sort_by(|a, b| b.0.len().cmp(&a.0.len()).then_with(|| a.0.cmp(&b.0)));
        Ok(Renamer {
            exact,
            tokens,
            text,
            words,
        })
    }
}

impl Renamer {
    /// Renames every key and string value in `value`.
    pub fn rename_json(&self, value: &Value, report: &mut RenameReport) -> Value {
        match value {
            Value::Object(map) => Value::Object(
                map.iter()
                    .map(|(k, v)| {
                        if k.starts_with('_') {
                            (k.clone(), self.rename_notes(v, report))
                        } else {
                            (self.rename_str(k, report), self.rename_json(v, report))
                        }
                    })
                    .collect(),
            ),
            Value::Array(items) => {
                Value::Array(items.iter().map(|v| self.rename_json(v, report)).collect())
            }
            Value::String(s) => Value::String(self.rename_str(s, report)),
            other => other.clone(),
        }
    }

    /// Author notes are prose: franchise words in them are replaced word by
    /// word (an old place name -> its new one, a plural creature name ->
    /// the new plural), keeping case.
    fn rename_notes(&self, value: &Value, report: &mut RenameReport) -> Value {
        match value {
            Value::String(s) => {
                let renamed = self.rename_prose(s);
                if renamed != *s {
                    report.notes += 1;
                }
                Value::String(renamed)
            }
            Value::Array(items) => {
                Value::Array(items.iter().map(|v| self.rename_notes(v, report)).collect())
            }
            Value::Object(_) => self.rename_json(value, report),
            other => other.clone(),
        }
    }

    fn rename_prose(&self, s: &str) -> String {
        let mut text = s.to_owned();
        for (old, new) in &self.text {
            text = text.replace(old.as_str(), new);
        }
        let mut out = String::with_capacity(text.len());
        let mut word = String::new();
        for ch in text.chars().chain(core::iter::once('\0')) {
            if ch.is_alphanumeric() {
                word.push(ch);
                continue;
            }
            if !word.is_empty() {
                out.push_str(&self.prose_word(&word));
                word.clear();
            }
            if ch != '\0' {
                out.push(ch);
            }
        }
        out
    }

    /// One prose word: a single-segment token, its plural, or the word itself.
    fn prose_word(&self, word: &str) -> String {
        let lower = word.to_lowercase();
        for (token, new) in &self.tokens {
            if token.len() != 1 {
                continue;
            }
            let plural = lower.strip_suffix('s') == Some(token[0].as_str());
            if lower != token[0] && !plural {
                continue;
            }
            let mut replacement = new.replace('_', " ");
            if plural {
                replacement.push('s');
            }
            if word.chars().next().is_some_and(char::is_uppercase) {
                replacement = replacement
                    .split(' ')
                    .map(|w| {
                        let mut c = w.chars();
                        c.next()
                            .map(|f| f.to_uppercase().collect::<String>() + c.as_str())
                            .unwrap_or_default()
                    })
                    .collect::<Vec<_>>()
                    .join(" ");
            }
            return replacement;
        }
        word.to_owned()
    }

    /// Renames one string: an exact id, an id or path made of `_` segments,
    /// or a visible phrase.
    pub fn rename_str(&self, s: &str, report: &mut RenameReport) -> String {
        if let Some(new) = self.exact.get(s) {
            report.exact += 1;
            return new.clone();
        }
        if is_identifier_like(s) {
            let renamed = self.rename_segments(s);
            if renamed != s {
                report.token += 1;
            }
            return renamed;
        }
        let mut out = s.to_owned();
        for (old, new) in &self.text {
            if out.contains(old.as_str()) {
                out = out.replace(old.as_str(), new);
                report.text += 1;
            }
        }
        out
    }

    /// Replaces token runs of `_` segments; `/` and `.` split paths, which
    /// keep their separators.
    fn rename_segments(&self, s: &str) -> String {
        let mut out = String::with_capacity(s.len());
        let mut part = String::new();
        for ch in s.chars() {
            if ch == '/' || ch == '.' || ch == ':' {
                out.push_str(&self.rename_part(&part));
                out.push(ch);
                part.clear();
            } else {
                part.push(ch);
            }
        }
        out.push_str(&self.rename_part(&part));
        out
    }

    fn rename_part(&self, part: &str) -> String {
        if let Some(new) = self.exact.get(part) {
            return new.clone();
        }
        let segments: Vec<&str> = part.split('_').collect();
        let lower: Vec<String> = segments.iter().map(|s| s.to_lowercase()).collect();
        let mut out: Vec<String> = Vec::new();
        let mut i = 0;
        'outer: while i < segments.len() {
            for (token, new) in &self.tokens {
                if i + token.len() <= lower.len() && lower[i..i + token.len()] == token[..] {
                    out.push(new.clone());
                    i += token.len();
                    continue 'outer;
                }
            }
            out.push(segments[i].to_owned());
            i += 1;
        }
        out.join("_")
    }

    /// Renames a file path or an asset name (a node, clip or material in a
    /// model, a word in a text): every run of `_` segments between characters
    /// that cannot be part of a name, when it spells a token or an exact id,
    /// is replaced. A capitalised run stays capitalised (`Cast_Old_Spell` ->
    /// `Cast_New_Name`) and an upper-case one upper-case.
    #[must_use]
    pub fn rename_path(&self, s: &str) -> String {
        let mut out = String::with_capacity(s.len());
        for (part, separator) in path_parts(s) {
            out.push_str(&self.rename_path_part(part).0);
            if let Some(c) = separator {
                out.push(c);
            }
        }
        out
    }

    /// The first visible phrase of the `text` table found in `s`.
    #[must_use]
    pub fn text_leftover(&self, s: &str) -> Option<String> {
        self.text
            .iter()
            .find(|(old, _)| s.contains(old.as_str()))
            .map(|(old, _)| old.clone())
    }

    /// The first franchise-derived word in a path or asset name.
    #[must_use]
    pub fn path_leftover(&self, s: &str) -> Option<String> {
        path_parts(s)
            .into_iter()
            .find_map(|(part, _)| self.rename_path_part(part).1)
    }

    fn rename_path_part(&self, part: &str) -> (String, Option<String>) {
        let segments: Vec<&str> = part.split('_').collect();
        let lower: Vec<String> = segments.iter().map(|s| s.to_lowercase()).collect();
        let mut out: Vec<String> = Vec::new();
        let mut found = None;
        let mut i = 0;
        'outer: while i < segments.len() {
            for (word, new) in &self.words {
                if i + word.len() <= lower.len() && lower[i..i + word.len()] == word[..] {
                    let first = segments[i];
                    let shout = first.len() > 1 && !first.chars().any(|c| c.is_ascii_lowercase());
                    let capital = first.starts_with(|c: char| c.is_ascii_uppercase());
                    out.extend(new.split('_').map(|w| {
                        if shout {
                            w.to_ascii_uppercase()
                        } else if capital {
                            let mut c = w.chars();
                            c.next()
                                .map(|f| f.to_ascii_uppercase().to_string() + c.as_str())
                                .unwrap_or_default()
                        } else {
                            w.to_owned()
                        }
                    }));
                    found.get_or_insert_with(|| word.join("_"));
                    i += word.len();
                    continue 'outer;
                }
            }
            out.push(segments[i].to_owned());
            i += 1;
        }
        (out.join("_"), found)
    }

    /// Every franchise-derived word still present in `value` (ids by whole
    /// `_` segment, text by whole word), with where it was found.
    #[must_use]
    pub fn leftovers(&self, value: &Value, path: &str) -> Vec<String> {
        let mut found = Vec::new();
        self.scan(value, path, &mut found);
        found
    }

    fn scan(&self, value: &Value, path: &str, found: &mut Vec<String>) {
        match value {
            Value::Object(map) => {
                for (k, v) in map {
                    if k.starts_with('_') {
                        self.scan_notes(v, &format!("{path}.{k}"), found);
                        continue;
                    }
                    let here = format!("{path}.{k}");
                    if let Some(word) = self.franchise_word(k) {
                        found.push(format!("{here} (key): {word}"));
                    }
                    self.scan(v, &here, found);
                }
            }
            Value::Array(items) => {
                for (i, v) in items.iter().enumerate() {
                    self.scan(v, &format!("{path}[{i}]"), found);
                }
            }
            Value::String(s) => {
                if let Some(word) = self.franchise_word(s) {
                    found.push(format!("{path}: {word} in \"{s}\""));
                }
            }
            _ => {}
        }
    }

    fn scan_notes(&self, value: &Value, path: &str, found: &mut Vec<String>) {
        match value {
            Value::String(s) => {
                let words = s
                    .split(|c: char| !c.is_alphanumeric())
                    .filter(|w| !w.is_empty());
                for word in words {
                    if self.prose_word(word) != word {
                        found.push(format!("{path} (note): {word}"));
                    }
                }
            }
            Value::Array(items) => items.iter().for_each(|v| self.scan_notes(v, path, found)),
            Value::Object(_) => self.scan(value, path, found),
            _ => {}
        }
    }

    fn franchise_word(&self, s: &str) -> Option<String> {
        if self.exact.contains_key(s) {
            return Some(s.to_owned());
        }
        let identifier = is_identifier_like(s);
        let words: Vec<String> = s
            .split(|c: char| !c.is_alphanumeric())
            .filter(|w| !w.is_empty())
            .map(str::to_lowercase)
            .collect();
        for (token, _) in &self.tokens {
            // In prose only single-word tokens are names (an old creature
            // name); a lower-case two-word token can be ordinary English.
            // Capitalised proper phrases are covered by the `text` table
            // below.
            if !identifier && token.len() > 1 {
                continue;
            }
            if token.len() <= words.len() && words.windows(token.len()).any(|w| w == &token[..]) {
                return Some(token.join("_"));
            }
        }
        // Single-word exact ids (spell and creature names) in prose too.
        for key in self.exact.keys() {
            if !key.contains('_') && words.iter().any(|w| *w == key.to_lowercase()) {
                return Some(key.clone());
            }
        }
        for (phrase, _) in &self.text {
            if s.contains(phrase.as_str()) {
                return Some(phrase.clone());
            }
        }
        None
    }
}

/// Splits at every character that cannot be part of a name (anything but
/// letters, digits and `_`), keeping each separator with the part before it.
fn path_parts(s: &str) -> Vec<(&str, Option<char>)> {
    let mut parts = Vec::new();
    let mut start = 0;
    for (i, c) in s.char_indices() {
        if !(c.is_alphanumeric() || c == '_') {
            parts.push((&s[start..i], Some(c)));
            start = i + c.len_utf8();
        }
    }
    parts.push((&s[start..], None));
    parts
}

fn is_identifier_like(s: &str) -> bool {
    !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '/' | '.' | ':' | '-'))
}
