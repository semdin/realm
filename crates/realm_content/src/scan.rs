//! `scan` and `hash-list`: keeps the project's reserved terms out of text files
//! and file names.
//!
//! A list file holds one salted SHA-256 per line. Text is cut into lower-cased
//! alphanumeric words (`_`, `-` and punctuation separate them, and so does a
//! camelCase boundary), and each word is compared whole, so a reserved word
//! inside a longer one never matches. A term of several words matches those
//! words next to each other, with any separator, or written as one word.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

const SALT: &[u8] = b"realm-content-reserved-1\0";
/// The longest reserved term, in words.
const MAX_TERM_WORDS: usize = 4;
/// Longer runs are data (hashes, base64), not words.
const MAX_WORD_LEN: usize = 48;
/// The lookup cache is dropped at this size (a few very large data files).
const MAX_CACHE: usize = 2_000_000;

/// Hash domain of a single word, compared with every word in the text.
const WORD: u8 = b'w';
/// Hash domain of several adjacent words, joined.
const JOINED: u8 = b'j';

/// Files never read as text.
const BINARY: &[&str] = &[
    "png", "jpg", "jpeg", "webp", "exr", "hdr", "glb", "bin", "ogg", "wav", "mp3", "ttf", "otf",
    "res", "scn", "realmmap", "ctex", "dll", "so", "dylib", "exe", "ico", "icns", "pck", "zip",
];
/// Folders of generated files.
const SKIPPED_DIRS: &[&str] = &[".godot", ".git", "target", "build"];

const HEADER: &str = "# Reserved terms for `realm_content scan`: salted SHA-256, one per line.\n\
# Generated: realm_content hash-list <words.txt> <this file>\n";

fn digest(domain: u8, term: &str) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(SALT);
    hasher.update([domain]);
    hasher.update(term.as_bytes());
    hasher.finalize().into()
}

fn to_hex(bytes: &[u8; 32]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn from_hex(text: &str) -> Option<[u8; 32]> {
    if text.len() != 64 || !text.is_ascii() {
        return None;
    }
    let mut out = [0_u8; 32];
    for (slot, pair) in out.iter_mut().zip(text.as_bytes().as_chunks::<2>().0) {
        let pair = std::str::from_utf8(pair).ok()?;
        *slot = u8::from_str_radix(pair, 16).ok()?;
    }
    Some(out)
}

/// The alphanumeric runs of `text`.
fn runs(text: &str) -> impl Iterator<Item = &str> {
    text.split(|c: char| !c.is_alphanumeric())
        .filter(|run| !run.is_empty())
}

/// `run` cut at its camelCase boundaries: `GateKeeper` and `HTTPServer` give
/// two parts each, `nimbus` and `ABC` one.
fn camel_parts(run: &str) -> Vec<&str> {
    let chars: Vec<(usize, char)> = run.char_indices().collect();
    let mut parts = Vec::new();
    let mut start = 0;
    for i in 1..chars.len() {
        let (at, c) = chars[i];
        let prev = chars[i - 1].1;
        let next_lower = chars.get(i + 1).is_some_and(|(_, n)| n.is_lowercase());
        let boundary = c.is_uppercase()
            && (prev.is_lowercase() || prev.is_numeric() || (prev.is_uppercase() && next_lower));
        if boundary {
            parts.push(&run[start..at]);
            start = at;
        }
    }
    parts.push(&run[start..]);
    parts
}

/// The reserved terms, as hashes.
struct Reserved {
    hashes: HashSet<[u8; 32]>,
    cache: HashMap<(u8, String), bool>,
}

impl Reserved {
    fn load(path: &Path) -> Result<Self, String> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        let mut hashes = HashSet::new();
        for (n, line) in text.lines().enumerate() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let hash = from_hex(line)
                .ok_or_else(|| format!("{}:{}: not a SHA-256", path.display(), n + 1))?;
            hashes.insert(hash);
        }
        Ok(Self {
            hashes,
            cache: HashMap::new(),
        })
    }

    fn has(&mut self, domain: u8, term: &str) -> bool {
        if let Some(&known) = self.cache.get(&(domain, term.to_owned())) {
            return known;
        }
        let found = self.hashes.contains(&digest(domain, term));
        if self.cache.len() >= MAX_CACHE {
            self.cache.clear();
        }
        self.cache.insert((domain, term.to_owned()), found);
        found
    }

    /// Every reserved term in `text`, as `(line, the words found)`.
    fn find(&mut self, text: &str) -> BTreeSet<(usize, String)> {
        let mut found = BTreeSet::new();
        let mut stream: Vec<(String, usize)> = Vec::new();
        for (n, line) in text.lines().enumerate() {
            for run in runs(line) {
                if run.chars().count() > MAX_WORD_LEN {
                    // Data: it also ends any phrase running through it.
                    stream.push((String::new(), n + 1));
                    continue;
                }
                let whole = run.to_lowercase();
                if self.has(WORD, &whole) {
                    found.insert((n + 1, whole.clone()));
                }
                let parts = camel_parts(run);
                if parts.len() == 1 {
                    stream.push((whole, n + 1));
                    continue;
                }
                for part in parts {
                    let part = part.to_lowercase();
                    if self.has(WORD, &part) {
                        found.insert((n + 1, part.clone()));
                    }
                    stream.push((part, n + 1));
                }
            }
        }
        for start in 0..stream.len() {
            let (first, line) = &stream[start];
            if first.is_empty() || first.chars().all(|c| c.is_numeric()) {
                continue;
            }
            let mut joined = first.clone();
            let mut shown = first.clone();
            for (next, _) in stream.iter().skip(start + 1).take(MAX_TERM_WORDS - 1) {
                if next.is_empty() {
                    break;
                }
                joined.push_str(next);
                shown.push(' ');
                shown.push_str(next);
                if self.has(JOINED, &joined) {
                    found.insert((*line, shown.clone()));
                }
            }
        }
        found
    }
}

/// True when `path` (forward slashes) is `exclude` or lies inside it.
fn is_excluded(path: &str, excludes: &[String]) -> bool {
    excludes.iter().any(|ex| {
        path == ex
            || path.starts_with(&format!("{ex}/"))
            || path.ends_with(&format!("/{ex}"))
            || path.contains(&format!("/{ex}/"))
    })
}

fn normalized(path: &str) -> String {
    let path = path.replace('\\', "/");
    let path = path.strip_prefix("./").unwrap_or(&path);
    path.trim_end_matches('/').to_owned()
}

/// `realm_content scan`: fails on any reserved term in the text or the names
/// of the files under `paths`.
pub fn scan(list: &Path, excludes: &[String], paths: &[String]) -> Result<(), Vec<String>> {
    let mut reserved = Reserved::load(list).map_err(|e| vec![e])?;
    let excludes: Vec<String> = excludes.iter().map(|e| normalized(e)).collect();
    let mut problems = Vec::new();
    let mut files = 0_usize;
    let mut stack: Vec<PathBuf> = paths.iter().map(PathBuf::from).collect();
    while let Some(path) = stack.pop() {
        let name = normalized(&path.to_string_lossy());
        if is_excluded(&name, &excludes) {
            continue;
        }
        if path.is_dir() {
            if path
                .file_name()
                .is_some_and(|n| SKIPPED_DIRS.iter().any(|s| n == *s))
            {
                continue;
            }
            match std::fs::read_dir(&path) {
                Ok(entries) => stack.extend(entries.flatten().map(|e| e.path())),
                Err(e) => problems.push(format!("{name}: {e}")),
            }
            continue;
        }
        for (_, term) in reserved.find(&name) {
            problems.push(format!("{name}: file name has '{term}'"));
        }
        let ext = path
            .extension()
            .map(|e| e.to_string_lossy().to_ascii_lowercase())
            .unwrap_or_default();
        if BINARY.contains(&ext.as_str()) {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        files += 1;
        for (line, term) in reserved.find(&text) {
            problems.push(format!("{name}:{line}: '{term}'"));
        }
    }
    problems.sort();
    println!("scan: {files} text files, {} hits", problems.len());
    if problems.is_empty() {
        Ok(())
    } else {
        Err(problems)
    }
}

/// `realm_content hash-list`: one term per line of `words` (blank lines and
/// `#` comments are skipped) into the list file `out`.
pub fn hash_list(words: &Path, out: &Path) -> Result<(), Vec<String>> {
    let fail = |path: &Path, e: &dyn std::fmt::Display| vec![format!("{}: {e}", path.display())];
    let text = std::fs::read_to_string(words).map_err(|e| fail(words, &e))?;
    let mut hashes = BTreeSet::new();
    let mut terms = 0_usize;
    for (n, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let parts: Vec<String> = runs(line).map(str::to_lowercase).collect();
        if parts.is_empty() || parts.len() > MAX_TERM_WORDS {
            return Err(vec![format!(
                "{}:{}: a term has 1 to {MAX_TERM_WORDS} words",
                words.display(),
                n + 1
            )]);
        }
        let joined = parts.concat();
        hashes.insert(to_hex(&digest(WORD, &joined)));
        if parts.len() > 1 {
            hashes.insert(to_hex(&digest(JOINED, &joined)));
        }
        terms += 1;
    }
    let mut body = String::from(HEADER);
    for hash in &hashes {
        body.push_str(hash);
        body.push('\n');
    }
    if let Some(dir) = out.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir).map_err(|e| fail(dir, &e))?;
    }
    std::fs::write(out, body).map_err(|e| fail(out, &e))?;
    println!(
        "{terms} terms, {} hashes in {}",
        hashes.len(),
        out.display()
    );
    Ok(())
}
