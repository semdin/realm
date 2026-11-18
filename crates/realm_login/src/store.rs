//! Accounts and characters where they are kept: the persistence service
//! (`--persist`) or, for development and CI, a JSON ledger with one sheet file
//! per character. The service's handlers only see these calls.

use std::path::Path;

use realm_proto::persist::{PersistMsg, PersistReply};
use realm_rules::CharacterSheet;
use realm_rules::names::name_skeleton;
use serde::{Deserialize, Serialize};

use crate::App;

#[derive(Clone, Serialize, Deserialize)]
pub struct Account {
    pub id: u64,
    pub name: String,
    pub hash: String,
    /// Its characters: (id, name).
    pub characters: Vec<(u64, String)>,
    #[serde(default)]
    pub terms_version: Option<String>,
    #[serde(default)]
    pub recovery_hash: Option<String>,
}

#[derive(Default, Serialize, Deserialize)]
pub struct Ledger {
    pub next_account: u64,
    pub next_character: u64,
    pub accounts: Vec<Account>,
}

/// An account as a request needs it.
#[derive(Clone)]
pub struct Found {
    pub id: u64,
    pub username: String,
    pub hash: String,
    pub terms_version: Option<String>,
    pub recovery_hash: Option<String>,
}

/// Why a store call did not land.
#[derive(Debug)]
pub enum Failure {
    /// A refusal the handler answers: "taken", "stale", "no account",
    /// "no character".
    Refused(String),
    /// The store itself failed (the player is told to try later).
    Down(String),
}

impl From<&Account> for Found {
    fn from(a: &Account) -> Self {
        Self {
            id: a.id,
            username: a.name.clone(),
            hash: a.hash.clone(),
            terms_version: a.terms_version.clone(),
            recovery_hash: a.recovery_hash.clone(),
        }
    }
}

const REFUSALS: [&str; 4] = ["taken", "stale", "no account", "no character"];

fn failure(e: String) -> Failure {
    if REFUSALS.contains(&e.as_str()) {
        Failure::Refused(e)
    } else {
        Failure::Down(e)
    }
}

pub fn write_atomic(path: &Path, text: &str) -> std::io::Result<()> {
    let temp = path.with_extension("json.tmp");
    std::fs::write(&temp, text)?;
    std::fs::rename(&temp, path)
}

impl crate::State {
    pub fn save(&self) {
        match serde_json::to_string_pretty(&self.ledger) {
            Ok(text) => {
                if let Err(e) = write_atomic(&self.ledger_file, &text) {
                    eprintln!(
                        "[login] cannot keep the accounts in {}: {e}",
                        self.ledger_file.display()
                    );
                }
            }
            Err(e) => eprintln!("[login] accounts: {e}"),
        }
    }

    fn ledger_account(&mut self, id: u64) -> Result<&mut Account, Failure> {
        self.ledger
            .accounts
            .iter_mut()
            .find(|a| a.id == id)
            .ok_or_else(|| Failure::Refused("no account".to_owned()))
    }

    pub fn sheet_path(&self, id: u64) -> std::path::PathBuf {
        self.characters.join(format!("{id}.json"))
    }

    pub fn load_sheet(&self, id: u64) -> Option<CharacterSheet> {
        let text = std::fs::read_to_string(self.sheet_path(id)).ok()?;
        serde_json::from_str(&text).ok()
    }

    pub fn name_taken(&self, name: &str) -> bool {
        let key = name_skeleton(name);
        self.ledger
            .accounts
            .iter()
            .flat_map(|a| a.characters.iter())
            .any(|(_, n)| name_skeleton(n) == key)
    }
}

impl App {
    async fn persist(&self) -> Option<std::sync::Arc<realm_proto::persist::client::PersistClient>> {
        self.state.lock().await.persist.clone()
    }

    /// A request that only has to land.
    async fn done(&self, make: impl FnOnce(u64) -> PersistMsg) -> Result<(), Failure> {
        let Some(client) = self.persist().await else {
            return Err(Failure::Down("no persistence service".to_owned()));
        };
        match client.call(make).await {
            Ok(PersistReply::Done { result: Ok(()), .. }) => Ok(()),
            Ok(PersistReply::Done { result: Err(e), .. }) => Err(failure(e)),
            Ok(other) => Err(Failure::Down(format!("{other:?}"))),
            Err(e) => Err(Failure::Down(e)),
        }
    }

    pub async fn find_account(&self, name: &str) -> Result<Option<Found>, Failure> {
        if let Some(client) = self.persist().await {
            let username = name.to_owned();
            return match client
                .call(|req| PersistMsg::FindAccount { req, username })
                .await
            {
                Ok(PersistReply::Account {
                    result: Ok(row), ..
                }) => Ok(row.map(|a| Found {
                    id: a.id,
                    username: a.username,
                    hash: a.hash,
                    terms_version: a.terms_version,
                    recovery_hash: a.recovery_hash,
                })),
                Ok(other) => Err(Failure::Down(format!("{other:?}"))),
                Err(e) => Err(Failure::Down(e)),
            };
        }
        let s = self.state.lock().await;
        Ok(s.ledger
            .accounts
            .iter()
            .find(|a| a.name.eq_ignore_ascii_case(name))
            .map(Found::from))
    }

    pub async fn create_account(
        &self,
        name: &str,
        hash: String,
        recovery_hash: String,
        terms_version: &str,
    ) -> Result<u64, Failure> {
        if let Some(client) = self.persist().await {
            let (username, terms_version) = (name.to_owned(), terms_version.to_owned());
            return match client
                .call(|req| PersistMsg::Register {
                    req,
                    username,
                    hash,
                    recovery_hash,
                    terms_version,
                })
                .await
            {
                Ok(PersistReply::Registered { result: Ok(id), .. }) => Ok(id),
                Ok(PersistReply::Registered { result: Err(e), .. }) => Err(failure(e)),
                Ok(other) => Err(Failure::Down(format!("{other:?}"))),
                Err(e) => Err(Failure::Down(e)),
            };
        }
        let mut s = self.state.lock().await;
        if s.ledger
            .accounts
            .iter()
            .any(|a| a.name.eq_ignore_ascii_case(name))
        {
            return Err(Failure::Refused("taken".to_owned()));
        }
        s.ledger.next_account = s.ledger.next_account.max(1);
        let id = s.ledger.next_account;
        s.ledger.next_account += 1;
        s.ledger.accounts.push(Account {
            id,
            name: name.to_owned(),
            hash,
            characters: Vec::new(),
            terms_version: Some(terms_version.to_owned()),
            recovery_hash: Some(recovery_hash),
        });
        s.save();
        Ok(id)
    }

    pub async fn touch_account(&self, account: u64) {
        if self.persist().await.is_some()
            && let Err(e) = self
                .done(|req| PersistMsg::TouchAccount { req, account })
                .await
        {
            eprintln!("[login] last login of {account}: {e:?}");
        }
    }

    pub async fn accept_terms(&self, account: u64, version: &str) -> Result<(), Failure> {
        if self.persist().await.is_some() {
            let version = version.to_owned();
            return self
                .done(|req| PersistMsg::AcceptTerms {
                    req,
                    account,
                    version,
                })
                .await;
        }
        let mut s = self.state.lock().await;
        s.ledger_account(account)?.terms_version = Some(version.to_owned());
        s.save();
        Ok(())
    }

    pub async fn set_password(&self, account: u64, hash: String) -> Result<(), Failure> {
        if self.persist().await.is_some() {
            return self
                .done(|req| PersistMsg::SetPassword { req, account, hash })
                .await;
        }
        let mut s = self.state.lock().await;
        s.ledger_account(account)?.hash = hash;
        s.save();
        Ok(())
    }

    pub async fn set_recovery(&self, account: u64, recovery_hash: String) -> Result<(), Failure> {
        if self.persist().await.is_some() {
            return self
                .done(|req| PersistMsg::SetRecovery {
                    req,
                    account,
                    recovery_hash,
                })
                .await;
        }
        let mut s = self.state.lock().await;
        s.ledger_account(account)?.recovery_hash = Some(recovery_hash);
        s.save();
        Ok(())
    }

    /// The code `used` buys a new password and is replaced; a code spent a
    /// moment ago is Refused("stale").
    pub async fn recover(
        &self,
        account: u64,
        used: String,
        hash: String,
        recovery_hash: String,
    ) -> Result<(), Failure> {
        if self.persist().await.is_some() {
            return self
                .done(|req| PersistMsg::Recover {
                    req,
                    account,
                    used,
                    hash,
                    recovery_hash,
                })
                .await;
        }
        let mut s = self.state.lock().await;
        let a = s.ledger_account(account)?;
        if a.recovery_hash.as_deref() != Some(used.as_str()) {
            return Err(Failure::Refused("stale".to_owned()));
        }
        a.hash = hash;
        a.recovery_hash = Some(recovery_hash);
        s.save();
        Ok(())
    }

    /// The account's characters: (id, name).
    pub async fn roster(&self, account: u64) -> Result<Vec<(u64, String)>, Failure> {
        if let Some(client) = self.persist().await {
            return match client
                .call(|req| PersistMsg::Characters { req, account })
                .await
            {
                Ok(PersistReply::Characters { result: Ok(r), .. }) => {
                    Ok(r.into_iter().map(|c| (c.id, c.name)).collect())
                }
                Ok(other) => Err(Failure::Down(format!("{other:?}"))),
                Err(e) => Err(Failure::Down(e)),
            };
        }
        let mut s = self.state.lock().await;
        Ok(s.ledger_account(account)?.characters.clone())
    }

    pub async fn delete_character(&self, account: u64, character: u64) -> Result<(), Failure> {
        if self.persist().await.is_some() {
            return self
                .done(|req| PersistMsg::DeleteCharacter {
                    req,
                    account,
                    character,
                })
                .await;
        }
        let mut s = self.state.lock().await;
        let a = s.ledger_account(account)?;
        let before = a.characters.len();
        a.characters.retain(|(id, _)| *id != character);
        if a.characters.len() == before {
            return Err(Failure::Refused("no character".to_owned()));
        }
        let path = s.sheet_path(character);
        if let Err(e) = std::fs::remove_file(&path) {
            eprintln!("[login] character {character}: {e}");
        }
        s.save();
        Ok(())
    }

    pub async fn delete_account(&self, account: u64) -> Result<(), Failure> {
        if self.persist().await.is_some() {
            return self
                .done(|req| PersistMsg::DeleteAccount { req, account })
                .await;
        }
        let mut s = self.state.lock().await;
        let characters = s.ledger_account(account)?.characters.clone();
        for (id, _) in characters {
            let path = s.sheet_path(id);
            if let Err(e) = std::fs::remove_file(&path) {
                eprintln!("[login] character {id}: {e}");
            }
        }
        s.ledger.accounts.retain(|a| a.id != account);
        s.save();
        Ok(())
    }
}
