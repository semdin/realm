//! `realm_content art`: copies art from the old Godot client into the new one
//! (`game/`) through the rename map.
//!
//! Starting from the given `res://` paths (a path ending in `/` is a whole
//! folder), it follows every reference the copied files make: `res://` paths
//! in scenes, resources, shaders and import files, and `uri`s in glTF files.
//! Each file keeps its `.import` and `.uid` companions, so import settings and
//! resource ids carry over. On the way every path, every reference and every
//! name inside a model (nodes, clips, materials, images) passes through the
//! rename map; a franchise-derived word left anywhere fails the run.

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::path::Path;

use realm_data::rename::Renamer;
use serde_json::Value;

/// Files read as text: references are followed and renamed.
const TEXT: &[&str] = &[
    "tscn",
    "tres",
    "gdshader",
    "gdshaderinc",
    "import",
    "gltf",
    "material",
    "cfg",
];

/// Pipeline notes and scripts found in art folders; not copied.
const DOCS: &[&str] = &[".md", ".txt", ".py", ".blend", ".blend1"];

#[derive(Default)]
struct Run {
    /// Old `res://` path (without the prefix) -> new one.
    copied: BTreeMap<String, String>,
    bytes: u64,
    renamed: usize,
    models_renamed: usize,
    problems: Vec<String>,
}

pub fn art(
    renamer: &Renamer,
    old_root: &Path,
    new_root: &Path,
    entries: &[String],
) -> Result<(), Vec<String>> {
    let mut run = Run::default();
    let mut queue: VecDeque<String> = entries
        .iter()
        .map(|e| e.trim_start_matches("res://").to_owned())
        .collect();
    let mut seen = BTreeSet::new();
    while let Some(rel) = queue.pop_front() {
        if !seen.insert(rel.clone()) {
            continue;
        }
        let old = old_root.join(&rel);
        if rel.ends_with('/') || old.is_dir() {
            match list_dir(&old) {
                Ok(files) => {
                    let base = rel.trim_end_matches('/');
                    queue.extend(files.into_iter().map(|f| format!("{base}/{f}")));
                }
                Err(e) => run.problems.push(format!("{rel}: {e}")),
            }
            continue;
        }
        if rel.ends_with(".import") || rel.ends_with(".uid") {
            // Companions travel with their file.
            continue;
        }
        if DOCS.iter().any(|d| rel.to_ascii_lowercase().ends_with(d)) {
            // Notes of the old art pipeline stay with it.
            continue;
        }
        if !old.is_file() {
            run.problems
                .push(format!("{rel}: referenced but not in the old project"));
            continue;
        }
        copy_one(renamer, old_root, new_root, &rel, &mut run, &mut queue);
        for companion in ["import", "uid"] {
            let side = format!("{rel}.{companion}");
            if old_root.join(&side).is_file() {
                copy_one(renamer, old_root, new_root, &side, &mut run, &mut queue);
            }
        }
    }
    println!(
        "art: {} files ({:.1} MB) into {}, {} paths renamed, {} models with renamed names",
        run.copied.len(),
        run.bytes as f64 / 1_048_576.0,
        new_root.display(),
        run.renamed,
        run.models_renamed
    );
    if run.problems.is_empty() {
        Ok(())
    } else {
        Err(run.problems)
    }
}

/// Files under `dir`, relative, recursively; companions included (they are
/// skipped by the caller and copied with their file).
fn list_dir(dir: &Path) -> std::io::Result<Vec<String>> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if entry.file_type()?.is_dir() {
            out.extend(
                list_dir(&entry.path())?
                    .into_iter()
                    .map(|f| format!("{name}/{f}")),
            );
        } else {
            out.push(name);
        }
    }
    out.sort();
    Ok(out)
}

fn copy_one(
    renamer: &Renamer,
    old_root: &Path,
    new_root: &Path,
    rel: &str,
    run: &mut Run,
    queue: &mut VecDeque<String>,
) {
    let new_rel = renamer.rename_path(rel);
    if new_rel != rel {
        run.renamed += 1;
    }
    let bytes = match std::fs::read(old_root.join(rel)) {
        Ok(b) => b,
        Err(e) => {
            run.problems.push(format!("{rel}: {e}"));
            return;
        }
    };
    let ext = rel.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    let out = if TEXT.contains(&ext.as_str()) {
        match String::from_utf8(bytes) {
            Ok(text) => {
                let text = follow_text(renamer, rel, &text, &ext, queue);
                check_words(renamer, &new_rel, &text, run);
                text.into_bytes()
            }
            Err(_) => {
                run.problems.push(format!("{rel}: not UTF-8"));
                return;
            }
        }
    } else if ext == "glb" {
        match rename_glb(renamer, &bytes) {
            Ok(Some(renamed)) => {
                run.models_renamed += 1;
                renamed
            }
            Ok(None) => bytes,
            Err(e) => {
                run.problems.push(format!("{rel}: {e}"));
                return;
            }
        }
    } else {
        bytes
    };
    let dest = new_root.join(&new_rel);
    if let Some(parent) = dest.parent()
        && let Err(e) = std::fs::create_dir_all(parent)
    {
        run.problems.push(format!("{}: {e}", parent.display()));
        return;
    }
    if let Err(e) = std::fs::write(&dest, &out) {
        run.problems.push(format!("{}: {e}", dest.display()));
        return;
    }
    run.bytes += out.len() as u64;
    run.copied.insert(rel.to_owned(), new_rel);
}

/// Queues every file a text file refers to and returns it with those
/// references renamed.
fn follow_text(
    renamer: &Renamer,
    rel: &str,
    text: &str,
    ext: &str,
    queue: &mut VecDeque<String>,
) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find("res://") {
        out.push_str(&rest[..at]);
        let tail = &rest[at + 6..];
        let end = tail
            .find(['"', '\'', ')', ']', ',', '\n', '\r', ' ', '\t'])
            .unwrap_or(tail.len());
        let path = &tail[..end];
        if !path.starts_with(".godot/") && !path.is_empty() {
            queue.push_back(path.to_owned());
        }
        out.push_str("res://");
        out.push_str(&renamer.rename_path(path));
        rest = &tail[end..];
    }
    out.push_str(rest);
    if ext == "gltf" {
        let dir = rel.rsplit_once('/').map_or("", |(d, _)| d);
        if let Ok(mut json) = serde_json::from_str::<Value>(&out) {
            for list in ["buffers", "images"] {
                if let Some(items) = json.get(list).and_then(Value::as_array) {
                    for uri in items
                        .iter()
                        .filter_map(|i| i.get("uri").and_then(Value::as_str))
                    {
                        if !uri.starts_with("data:") {
                            queue.push_back(format!("{dir}/{uri}"));
                        }
                    }
                }
            }
            rename_strings(renamer, &mut json);
            if let Ok(text) = serde_json::to_string_pretty(&json) {
                return text;
            }
        }
    }
    out
}

/// Every franchise-derived word left in a copied text file.
fn check_words(renamer: &Renamer, new_rel: &str, text: &str, run: &mut Run) {
    let mut found = BTreeSet::new();
    for word in text.split(|c: char| !(c.is_ascii_alphanumeric() || c == '_')) {
        if !word.is_empty()
            && let Some(w) = renamer.path_leftover(word)
        {
            found.insert(w);
        }
    }
    if let Some(w) = renamer.path_leftover(new_rel) {
        found.insert(w);
    }
    for w in found {
        run.problems.push(format!("{new_rel}: still says '{w}'"));
    }
}

/// Renames every string value (names, uris) in a glTF document.
fn rename_strings(renamer: &Renamer, value: &mut Value) -> bool {
    match value {
        Value::String(s) => {
            let renamed = renamer.rename_path(s);
            if renamed == *s {
                false
            } else {
                *s = renamed;
                true
            }
        }
        Value::Array(items) => items
            .iter_mut()
            .fold(false, |any, v| rename_strings(renamer, v) | any),
        Value::Object(map) => map
            .values_mut()
            .fold(false, |any, v| rename_strings(renamer, v) | any),
        _ => false,
    }
}

/// A binary glTF with its JSON chunk renamed, or None when nothing changed.
fn rename_glb(renamer: &Renamer, bytes: &[u8]) -> Result<Option<Vec<u8>>, String> {
    let u32_at = |i: usize| -> Result<u32, String> {
        bytes
            .get(i..i + 4)
            .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .ok_or_else(|| "truncated glb".to_owned())
    };
    if bytes.get(0..4) != Some(b"glTF") {
        return Err("not a glb".to_owned());
    }
    let json_len = u32_at(12)? as usize;
    if u32_at(16)? != 0x4E4F_534A {
        return Err("glb without a JSON chunk first".to_owned());
    }
    let json_bytes = bytes
        .get(20..20 + json_len)
        .ok_or_else(|| "truncated glb".to_owned())?;
    let mut json: Value = serde_json::from_slice(json_bytes).map_err(|e| e.to_string())?;
    if !rename_strings(renamer, &mut json) {
        return Ok(None);
    }
    let mut chunk = serde_json::to_vec(&json).map_err(|e| e.to_string())?;
    while chunk.len() % 4 != 0 {
        chunk.push(b' ');
    }
    let rest = &bytes[20 + json_len..];
    let total = 12 + 8 + chunk.len() + rest.len();
    let mut out = Vec::with_capacity(total);
    out.extend_from_slice(b"glTF");
    out.extend_from_slice(&bytes[4..8]);
    out.extend_from_slice(
        &u32::try_from(total)
            .map_err(|e| e.to_string())?
            .to_le_bytes(),
    );
    out.extend_from_slice(
        &u32::try_from(chunk.len())
            .map_err(|e| e.to_string())?
            .to_le_bytes(),
    );
    out.extend_from_slice(b"JSON");
    out.extend_from_slice(&chunk);
    out.extend_from_slice(rest);
    Ok(Some(out))
}

/// Files never read as text by `scan`.
const BINARY: &[&str] = &[
    "png", "jpg", "jpeg", "webp", "exr", "hdr", "glb", "bin", "ogg", "wav", "mp3", "ttf", "otf",
    "res", "scn", "realmmap", "ctex", "dll", "so", "dylib", "exe",
];

/// `realm_content scan`: every franchise-derived word, phrase or file name
/// left in text files (scripts, scenes, shaders, catalogues), with where it
/// is. For files moved by hand, which `art` does not see.
pub fn scan(renamer: &Renamer, paths: &[String]) -> Result<(), Vec<String>> {
    let mut problems = Vec::new();
    let mut files = 0_usize;
    let mut stack: Vec<std::path::PathBuf> = paths.iter().map(std::path::PathBuf::from).collect();
    while let Some(path) = stack.pop() {
        if path.is_dir() {
            if path.file_name().is_some_and(|n| n == ".godot") {
                continue;
            }
            match std::fs::read_dir(&path) {
                Ok(entries) => stack.extend(entries.flatten().map(|e| e.path())),
                Err(e) => problems.push(format!("{}: {e}", path.display())),
            }
            continue;
        }
        let name = path
            .to_string_lossy()
            .replace(std::path::MAIN_SEPARATOR, "/");
        if let Some(w) = renamer.path_leftover(&name) {
            problems.push(format!("{name}: file name says '{w}'"));
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
        // A gettext catalogue: only the source text (msgid) is ours to check;
        // translations are other languages' words (a Turkish word can spell
        // an old English token).
        let catalogue = ext == "po";
        let mut in_translation = false;
        for (n, line) in text.lines().enumerate() {
            if catalogue {
                if line.starts_with("msgstr") {
                    in_translation = true;
                } else if line.starts_with("msgid")
                    || line.starts_with("msgctxt")
                    || line.is_empty()
                {
                    in_translation = false;
                }
                if in_translation {
                    continue;
                }
            }
            let mut found = BTreeSet::new();
            for word in line.split(|c: char| !(c.is_ascii_alphanumeric() || c == '_')) {
                if !word.is_empty()
                    && let Some(w) = renamer.path_leftover(word)
                {
                    found.insert(w);
                }
            }
            if let Some(phrase) = renamer.text_leftover(line) {
                found.insert(phrase);
            }
            for w in found {
                problems.push(format!("{name}:{}: '{w}'", n + 1));
            }
        }
    }
    println!(
        "scan: {files} text files, {} franchise-derived leftovers",
        problems.len()
    );
    if problems.is_empty() {
        Ok(())
    } else {
        Err(problems)
    }
}
