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
//! `PersistStore` talks to the persistence service (realm_persist, PostgreSQL).

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

/// Development (the maintenance check): a store whose saves fail while
/// the `flag` file exists.
pub struct FlakyStore {
    pub inner: FileStore,
    pub flag: PathBuf,
}

impl CharacterStore for FlakyStore {
    fn load(&self, id: u64) -> Result<Option<CharacterSheet>, String> {
        self.inner.load(id)
    }

    fn save(&self, sheet: &CharacterSheet) -> Result<(), String> {
        if self.flag.exists() {
            return Err(format!(
                "character {}: saves fail while {} exists",
                sheet.id,
                self.flag.display()
            ));
        }
        self.inner.save(sheet)
    }
}

/// The persistence service (`realm_persist`): one TCP stream, opened on
/// first use and again after any failure (a failed call is an error the
/// caller already handles: a refused join, a save tried again).
pub struct PersistStore {
    addr: String,
    key: [u8; 32],
    link: std::sync::Mutex<Option<(std::net::TcpStream, realm_proto::control::FrameReader)>>,
    next: std::sync::atomic::AtomicU64,
}

impl PersistStore {
    pub fn new(addr: String, key: [u8; 32]) -> Self {
        Self {
            addr,
            key,
            link: std::sync::Mutex::new(None),
            next: std::sync::atomic::AtomicU64::new(1),
        }
    }

    fn call(
        &self,
        msg: &realm_proto::persist::PersistMsg,
    ) -> Result<realm_proto::persist::PersistReply, String> {
        use std::io::{Read, Write};
        let mut guard = self
            .link
            .lock()
            .map_err(|_| "store link poisoned".to_owned())?;
        if guard.is_none() {
            let addr: std::net::SocketAddr = self
                .addr
                .parse()
                .map_err(|e| format!("persist address {}: {e}", self.addr))?;
            let mut stream =
                std::net::TcpStream::connect_timeout(&addr, std::time::Duration::from_secs(3))
                    .map_err(|e| format!("persist {}: {e}", self.addr))?;
            stream.set_nodelay(true).ok();
            stream
                .set_read_timeout(Some(std::time::Duration::from_secs(15)))
                .ok();
            stream
                .write_all(&realm_proto::persist::encode_msg(
                    &realm_proto::persist::PersistMsg::Hello { key: self.key },
                ))
                .map_err(|e| format!("persist hello: {e}"))?;
            *guard = Some((stream, realm_proto::control::FrameReader::default()));
        }
        let result = (|| {
            let (stream, reader) = guard.as_mut().ok_or("no link")?;
            stream
                .write_all(&realm_proto::persist::encode_msg(msg))
                .map_err(|e| e.to_string())?;
            let mut chunk = [0_u8; 64 * 1024];
            loop {
                if let Some(frame) = reader.next_frame().map_err(|e| format!("{e:?}"))? {
                    return realm_proto::persist::decode_reply(&frame)
                        .map_err(|e| format!("{e:?}"));
                }
                let n = stream.read(&mut chunk).map_err(|e| e.to_string())?;
                if n == 0 {
                    return Err("persistence service closed the link".to_owned());
                }
                reader.push(&chunk[..n]);
            }
        })();
        if result.is_err() {
            // Open a fresh link next time.
            *guard = None;
        }
        result
    }

    fn req(&self) -> u64 {
        self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    }
}

impl CharacterStore for PersistStore {
    fn load(&self, id: u64) -> Result<Option<CharacterSheet>, String> {
        let req = self.req();
        match self.call(&realm_proto::persist::PersistMsg::Load { req, character: id })? {
            realm_proto::persist::PersistReply::Loaded { req: r, result } if r == req => {
                result.map(|s| s.map(|b| *b))
            }
            other => Err(format!("persist answered {other:?} to load {req}")),
        }
    }

    fn save(&self, sheet: &CharacterSheet) -> Result<(), String> {
        let req = self.req();
        match self.call(&realm_proto::persist::PersistMsg::Save {
            req,
            sheet: Box::new(sheet.clone()),
        })? {
            realm_proto::persist::PersistReply::Saved {
                req: r, ok, error, ..
            } if r == req => {
                if ok {
                    Ok(())
                } else {
                    Err(format!("character {}: {error}", sheet.id))
                }
            }
            other => Err(format!("persist answered {other:?} to save {req}")),
        }
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
                        let result = store.load(character).map(|s| s.map(Box::new));
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
                            ok: result.is_ok(),
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
