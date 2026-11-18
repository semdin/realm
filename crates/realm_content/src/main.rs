//! realm_content check <content_dir>
//! realm_content scan --list <hashes> [--exclude <path>]... <file_or_dir>...
//! realm_content hash-list <words.txt> <out>
//!
//! `check` loads a content folder, verifies every cross reference and prints
//! the content hash client and server compare at login. `scan` fails on any
//! reserved term in text files or file names, and `hash-list` writes the list
//! it reads (see `scan.rs`).

mod scan;

use std::path::Path;
use std::process::ExitCode;

use realm_data::Content;
use realm_data::catalog::Catalog;

const USAGE: &str = "usage:
  realm_content check <content_dir>
  realm_content scan --list <hashes> [--exclude <path>]... <file_or_dir>...
  realm_content hash-list <words.txt> <out>";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.as_slice() {
        [cmd, dir] if cmd == "check" => check(Path::new(dir)),
        [cmd, words, out] if cmd == "hash-list" => {
            scan::hash_list(Path::new(words), Path::new(out))
        }
        [cmd, rest @ ..] if cmd == "scan" => match ScanArgs::parse(rest) {
            Some(a) => scan::scan(Path::new(&a.list), &a.excludes, &a.paths),
            None => return usage(),
        },
        _ => return usage(),
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

fn usage() -> ExitCode {
    eprintln!("{USAGE}");
    ExitCode::from(2)
}

struct ScanArgs {
    list: String,
    excludes: Vec<String>,
    paths: Vec<String>,
}

impl ScanArgs {
    fn parse(args: &[String]) -> Option<Self> {
        let mut list = None;
        let mut excludes = Vec::new();
        let mut paths = Vec::new();
        let mut args = args.iter();
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--list" => list = Some(args.next()?.clone()),
                "--exclude" => excludes.push(args.next()?.clone()),
                _ => paths.push(arg.clone()),
            }
        }
        if paths.is_empty() {
            return None;
        }
        Some(Self {
            list: list?,
            excludes,
            paths,
        })
    }
}

fn check(dir: &Path) -> Result<(), Vec<String>> {
    let content = Content::load(dir).map_err(|e| vec![e])?;
    let cat = Catalog::build(&content)?;
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
    Ok(())
}
