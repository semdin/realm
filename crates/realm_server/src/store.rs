//! Character records: where the map server loads and saves them.
//!
//! The simulation thread never waits on a disk or a database. Loads and saves
//! are jobs for one store thread, done in the order they were queued; a load's
//! result comes back to the simulation as an event. The simulation keeps the
//! newest sheet of every character whose save is still on its way
//! (`Sim::unsaved`), so a player who leaves and joins again at once gets that,
//! never an older stored copy.
//!
//! `FileStore` (one JSON file per character) serves development and tests;
//! the persistence service of Phase 7 implements the same trait.

use std::path::PathBuf;

use crossbeam_channel::{Receiver, Sender};
use realm_rules::CharacterSheet;

use crate::sim::{ConnId, NetEvent};

pub trait CharacterStore: Send + Sync {
    /// The stored sheet, or None for a character that has never been saved.
    fn load(&self, id: u64) -> Result<Option<CharacterSheet>, String>;
    /// Stores `sheet` unless the stored copy is newer (a higher revision).
    fn save(&self, sheet: &CharacterSheet) -> Result<(), String>;
}

/// Nothing persists: every join starts a new character (load tests, CI).
pub struct NoStore;

impl CharacterStore for NoStore {
    fn load(&self, _id: u64) -> Result<Option<CharacterSheet>, String> {
        Ok(None)
    }

    fn save(&self, _sheet: &CharacterSheet) -> Result<(), String> {
        Ok(())
    }
}

/// One `<id>.json` per character in a folder.
pub struct FileStore {
    dir: PathBuf,
}

impl FileStore {
    pub fn new(dir: PathBuf) -> Result<Self, String> {
        std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        Ok(Self { dir })
    }

    fn path(&self, id: u64) -> PathBuf {
        self.dir.join(format!("{id}.json"))
    }
}

impl CharacterStore for FileStore {
    fn load(&self, id: u64) -> Result<Option<CharacterSheet>, String> {
        let path = self.path(id);
        match std::fs::read_to_string(&path) {
            Ok(text) => serde_json::from_str(&text)
                .map(Some)
                .map_err(|e| format!("{}: {e}", path.display())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(format!("{}: {e}", path.display())),
        }
    }

    fn save(&self, sheet: &CharacterSheet) -> Result<(), String> {
        if let Some(stored) = self.load(sheet.id)?
            && stored.revision > sheet.revision
        {
            return Err(format!(
                "character {}: stored revision {} is newer than {}",
                sheet.id, stored.revision, sheet.revision
            ));
        }
        let path = self.path(sheet.id);
        let temp = path.with_extension("json.tmp");
        let text = serde_json::to_string_pretty(sheet).map_err(|e| e.to_string())?;
        // Written whole, then renamed over the old file: a crash mid-write
        // leaves the previous save, never half of one.
        std::fs::write(&temp, text).map_err(|e| format!("{}: {e}", temp.display()))?;
        std::fs::rename(&temp, &path).map_err(|e| format!("{}: {e}", path.display()))
    }
}

pub enum StoreJob {
    Load { conn: ConnId, character: u64 },
    Save(Box<CharacterSheet>),
}

/// Starts the store thread; jobs go in, results come back as sim events.
pub fn start(
    store: Box<dyn CharacterStore>,
    events: Sender<NetEvent>,
) -> std::io::Result<Sender<StoreJob>> {
    let (jobs, queue): (Sender<StoreJob>, Receiver<StoreJob>) = crossbeam_channel::unbounded();
    std::thread::Builder::new()
        .name("store".to_owned())
        .spawn(move || {
            for job in queue {
                match job {
                    StoreJob::Load { conn, character } => {
                        let result = store.load(character);
                        if events.send(NetEvent::Loaded { conn, result }).is_err() {
                            return;
                        }
                    }
                    StoreJob::Save(sheet) => {
                        let result = store.save(&sheet);
                        if let Err(e) = &result {
                            eprintln!("[store] save failed: {e}");
                        }
                        let saved = NetEvent::Saved {
                            character: sheet.id,
                            revision: sheet.revision,
                        };
                        if events.send(saved).is_err() {
                            return;
                        }
                    }
                }
            }
        })?;
    Ok(jobs)
}
