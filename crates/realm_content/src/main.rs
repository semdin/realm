//! realm_content import <rename_map.toml> <out_dir> <old_data_dir>...
//! realm_content check <rename_map.toml> <content_dir>
//!
//! `import` reads every `*.json` of the old game's data folders, passes every
//! key and string through the rename map, writes the result to `out_dir` and
//! then runs `check` on it. `check` loads a content folder, verifies every
//! cross reference, fails on any franchise-derived name still present, and
//! prints the content hash client and server compare at login.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use realm_data::Content;
use realm_data::catalog::Catalog;
use realm_data::rename::{RenameMap, RenameReport, Renamer};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.as_slice() {
        [cmd, map, out, inputs @ ..] if cmd == "import" && !inputs.is_empty() => import(
            Path::new(map),
            Path::new(out),
            &inputs.iter().map(PathBuf::from).collect::<Vec<_>>(),
        ),
        [cmd, map, dir] if cmd == "check" => check(Path::new(map), Path::new(dir)),
        _ => {
            eprintln!(
                "usage:\n  realm_content import <rename_map.toml> <out_dir> <old_data_dir>...\n  realm_content check <rename_map.toml> <content_dir>"
            );
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(problems) => {
            for p in &problems {
                eprintln!("  {p}");
            }
            eprintln!("content: {} problem(s)", problems.len());
            ExitCode::FAILURE
        }
    }
}

fn renamer(map: &Path) -> Result<Renamer, Vec<String>> {
    let text = std::fs::read_to_string(map).map_err(|e| vec![format!("{}: {e}", map.display())])?;
    RenameMap::parse(&text)
        .and_then(|m| m.compile())
        .map_err(|e| vec![format!("{}: {e}", map.display())])
}

fn import(map: &Path, out: &Path, inputs: &[PathBuf]) -> Result<(), Vec<String>> {
    let renamer = renamer(map)?;
    let mut merged = Content::default();
    for dir in inputs {
        let content = Content::load(dir).map_err(|e| vec![e])?;
        for (name, value) in content.files {
            if merged.files.contains_key(&name) {
                return Err(vec![format!("{name} exists in more than one input folder")]);
            }
            merged.files.insert(name, value);
        }
    }
    let mut report = RenameReport::default();
    let renamed = Content {
        files: merged
            .files
            .iter()
            .map(|(name, value)| (name.clone(), renamer.rename_json(value, &mut report)))
            .collect(),
    };
    renamed.save(out).map_err(|e| vec![e])?;
    println!(
        "imported {} files into {}: {} exact id renames, {} derived id/path renames, {} text renames, {} notes reworded",
        renamed.files.len(),
        out.display(),
        report.exact,
        report.token,
        report.text,
        report.notes
    );
    check(map, out)
}

fn check(map: &Path, dir: &Path) -> Result<(), Vec<String>> {
    let renamer = renamer(map)?;
    let content = Content::load(dir).map_err(|e| vec![e])?;
    let mut problems: Vec<String> = content
        .files
        .iter()
        .flat_map(|(name, value)| renamer.leftovers(value, name))
        .map(|leftover| format!("franchise name left: {leftover}"))
        .collect();
    match Catalog::build(&content) {
        Ok(cat) => {
            if problems.is_empty() {
                println!(
                    "content ok: {} items, {} spells, {} creatures, {} maps, {} houses, {} loot tables, {} spawn packs, {} travel nodes, {} dungeons, {} quests",
                    cat.items.len(),
                    cat.spells.len(),
                    cat.creatures.len(),
                    cat.maps.len(),
                    cat.houses.len(),
                    cat.loot_tables.len(),
                    cat.spawn_packs,
                    cat.travel_nodes.len(),
                    cat.dungeons.len(),
                    cat.quests.len()
                );
                println!("content hash {}", content.hash());
            }
        }
        Err(errors) => problems.extend(errors),
    }
    if problems.is_empty() {
        Ok(())
    } else {
        Err(problems)
    }
}
