//! realm_persist [--bind 127.0.0.1:7970] [--keys keys]
//!
//! The persistence service: the only thing that writes the realm's
//! PostgreSQL database (REALM_DATABASE_URL, e.g.
//! `postgres://realm:secret@127.0.0.1:5432/realm`). Map servers (character
//! sheets), the login service (accounts, new characters) and the
//! coordinator (weekly boards, game admins) reach it over one TCP stream
//! each and prove they hold keys/coord.key; players never do. At start it
//! brings the schema up to date (`migrations/`, recorded in
//! `schema_migrations`).
//!
//! A new character is made in one transaction: its account locked, the
//! characters counted, the name checked against every player's character
//! (whatever the case), a fresh id from `character_ids` (from 10 000 000;
//! an id already stored is skipped), the sheet stored under it.
//!
//! A character's sheet is one jsonb document with the fields the services
//! look things up by beside it. A save never goes back in time: a sheet
//! whose revision is older than the stored one is refused ("stale"), as the
//! file store did. A save is answered once it is committed, so a map
//! releases a leaving character only when its save is really on disk.
//!
//! Deleting a character or an account is one transaction too: the rows go,
//! the names leave the weekly boards, the old GA list and block lists, reports
//! and the moderation history lose what identifies the player, and one
//! anonymous `audit` row stays (what, when, how many characters). Player characters are only made by `CreateCharacter`,
//! so a save that arrives late cannot bring a deleted one back.
//!
//! It counts what it does (loads, saves, stale saves, failures, the last
//! minute's save latency) and answers `Stats` with those, its linked callers
//! and the database's size and rows; the coordinator asks every 5 s for its
//! metrics and operator panel.

use std::collections::VecDeque;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use realm_proto::control::FrameReader;
use realm_proto::coord::Board;
use realm_proto::persist::{
    AccountRow, CharacterSummary, DELETED_NAME, FIRST_PLAYER_CHARACTER, PersistMsg, PersistReply,
    PersistStats, decode_msg, encode_reply, forget_board_names,
};
use realm_rules::CharacterSheet;
use realm_rules::names::name_key;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_postgres::error::SqlState;
use tokio_postgres::types::Json;
use tokio_postgres::{Client, NoTls, Transaction};

mod moderation;

type AnyResult<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// The schema, in order; each runs once, in a transaction.
const MIGRATIONS: &[(i32, &str)] = &[
    (1, include_str!("../migrations/0001_realm.sql")),
    (2, include_str!("../migrations/0002_logins_boards_gas.sql")),
    (3, include_str!("../migrations/0003_account_rights.sql")),
    (5, include_str!("../migrations/0005_moderation.sql")),
];

async fn connect(url: &str) -> AnyResult<Client> {
    let (client, connection) = tokio_postgres::connect(url, NoTls).await?;
    tokio::spawn(async move {
        if let Err(e) = connection.await {
            eprintln!("[persist] database connection: {e}");
        }
    });
    Ok(client)
}

async fn migrate(client: &mut Client) -> AnyResult<()> {
    client
        .batch_execute(
            "CREATE TABLE IF NOT EXISTS schema_migrations (
                version integer PRIMARY KEY,
                applied_at timestamptz NOT NULL DEFAULT now())",
        )
        .await?;
    for (version, sql) in MIGRATIONS {
        let done = client
            .query_opt(
                "SELECT 1 FROM schema_migrations WHERE version = $1",
                &[version],
            )
            .await?
            .is_some();
        if done {
            continue;
        }
        let tx = client.transaction().await?;
        tx.batch_execute(sql).await?;
        tx.execute(
            "INSERT INTO schema_migrations (version) VALUES ($1)",
            &[version],
        )
        .await?;
        tx.commit().await?;
        println!("[persist] schema migration {version} applied");
    }
    Ok(())
}

async fn load(client: &Client, character: u64) -> Result<Option<Box<CharacterSheet>>, String> {
    let id = i64::try_from(character).map_err(|_| "character id out of range".to_owned())?;
    let row = client
        .query_opt("SELECT sheet FROM characters WHERE id = $1", &[&id])
        .await
        .map_err(|e| e.to_string())?;
    let Some(row) = row else {
        return Ok(None);
    };
    let Json(sheet): Json<CharacterSheet> = row.try_get(0).map_err(|e| e.to_string())?;
    Ok(Some(Box::new(sheet)))
}

/// What became of a save.
enum Saved {
    Stored,
    /// The stored revision is newer.
    Stale,
    /// A player's character with no row: it was deleted, and stays deleted.
    Deleted,
}

async fn save(client: &Client, sheet: &CharacterSheet) -> Result<Saved, String> {
    let id = i64::try_from(sheet.id).map_err(|_| "character id out of range".to_owned())?;
    let revision = i64::try_from(sheet.revision).map_err(|_| "revision out of range".to_owned())?;
    let name_key = name_key(&sheet.name);
    let map = sheet.place.as_ref().map(|p| p.map.clone());
    let level = i32::from(sheet.level);
    let doc = Json(sheet);
    if sheet.id >= FIRST_PLAYER_CHARACTER {
        let updated = client
            .execute(
                "UPDATE characters SET
                    name = $2, name_key = $3, house = $4, level = $5, map = $6,
                    revision = $7, sheet = $8, updated_at = now()
                 WHERE id = $1 AND revision <= $7",
                &[
                    &id,
                    &sheet.name,
                    &name_key,
                    &sheet.house,
                    &level,
                    &map,
                    &revision,
                    &doc,
                ],
            )
            .await
            .map_err(|e| e.to_string())?;
        if updated > 0 {
            return Ok(Saved::Stored);
        }
        let exists = client
            .query_opt("SELECT 1 FROM characters WHERE id = $1", &[&id])
            .await
            .map_err(|e| e.to_string())?
            .is_some();
        return Ok(if exists { Saved::Stale } else { Saved::Deleted });
    }
    let stored = client
        .query_opt(
            "INSERT INTO characters (id, name, name_key, house, level, map, revision, sheet)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
             ON CONFLICT (id) DO UPDATE SET
                name = EXCLUDED.name, name_key = EXCLUDED.name_key, house = EXCLUDED.house,
                level = EXCLUDED.level, map = EXCLUDED.map, revision = EXCLUDED.revision,
                sheet = EXCLUDED.sheet, updated_at = now()
             WHERE characters.revision <= EXCLUDED.revision
             RETURNING revision",
            &[
                &id,
                &sheet.name,
                &name_key,
                &sheet.house,
                &level,
                &map,
                &revision,
                &doc,
            ],
        )
        .await
        .map_err(|e| e.to_string())?;
    Ok(if stored.is_some() {
        Saved::Stored
    } else {
        Saved::Stale
    })
}

fn id_of(value: u64, what: &str) -> Result<i64, String> {
    i64::try_from(value).map_err(|_| format!("{what} id out of range"))
}

fn text(e: &tokio_postgres::Error) -> String {
    e.to_string()
}

async fn register(
    client: &Client,
    username: &str,
    hash: &str,
    recovery_hash: &str,
    terms_version: &str,
) -> Result<u64, String> {
    let row = client
        .query_opt(
            "INSERT INTO accounts (username, password_hash, recovery_hash, recovery_created_at,
                                   terms_version, terms_accepted_at, age_confirmed_at)
             VALUES ($1, $2, $3, now(), $4, now(), now())
             ON CONFLICT DO NOTHING RETURNING id",
            &[&username, &hash, &recovery_hash, &terms_version],
        )
        .await
        .map_err(|e| text(&e))?;
    let Some(row) = row else {
        return Err("taken".to_owned());
    };
    let id: i64 = row.try_get(0).map_err(|e| text(&e))?;
    u64::try_from(id).map_err(|_| "account id out of range".to_owned())
}

async fn find_account(client: &Client, username: &str) -> Result<Option<AccountRow>, String> {
    let row = client
        .query_opt(
            "SELECT id, username, password_hash, terms_version, recovery_hash
             FROM accounts WHERE lower(username) = lower($1)",
            &[&username],
        )
        .await
        .map_err(|e| text(&e))?;
    let Some(row) = row else {
        return Ok(None);
    };
    let id: i64 = row.try_get(0).map_err(|e| text(&e))?;
    Ok(Some(AccountRow {
        id: u64::try_from(id).map_err(|_| "account id out of range".to_owned())?,
        username: row.try_get(1).map_err(|e| text(&e))?,
        hash: row.try_get(2).map_err(|e| text(&e))?,
        terms_version: row.try_get(3).map_err(|e| text(&e))?,
        recovery_hash: row.try_get(4).map_err(|e| text(&e))?,
    }))
}

/// Runs an update of one account; no such row is Err("no account").
async fn update_account(
    client: &Client,
    sql: &str,
    params: &[&(dyn tokio_postgres::types::ToSql + Sync)],
) -> Result<(), String> {
    match client.execute(sql, params).await.map_err(|e| text(&e))? {
        0 => Err("no account".to_owned()),
        _ => Ok(()),
    }
}

async fn accept_terms(client: &Client, account: u64, version: &str) -> Result<(), String> {
    update_account(
        client,
        "UPDATE accounts SET terms_version = $2, terms_accepted_at = now(),
                             age_confirmed_at = now()
         WHERE id = $1",
        &[&id_of(account, "account")?, &version],
    )
    .await
}

async fn set_password(client: &Client, account: u64, hash: &str) -> Result<(), String> {
    update_account(
        client,
        "UPDATE accounts SET password_hash = $2, password_changed_at = now() WHERE id = $1",
        &[&id_of(account, "account")?, &hash],
    )
    .await
}

async fn set_recovery(client: &Client, account: u64, recovery_hash: &str) -> Result<(), String> {
    update_account(
        client,
        "UPDATE accounts SET recovery_hash = $2, recovery_created_at = now() WHERE id = $1",
        &[&id_of(account, "account")?, &recovery_hash],
    )
    .await
}

/// One statement, so two uses of one code cannot both win.
async fn recover(
    client: &Client,
    account: u64,
    used: &str,
    hash: &str,
    recovery_hash: &str,
) -> Result<(), String> {
    let changed = client
        .execute(
            "UPDATE accounts SET password_hash = $3, password_changed_at = now(),
                                 recovery_hash = $4, recovery_created_at = now()
             WHERE id = $1 AND recovery_hash = $2",
            &[&id_of(account, "account")?, &used, &hash, &recovery_hash],
        )
        .await
        .map_err(|e| text(&e))?;
    if changed == 0 {
        return Err("stale".to_owned());
    }
    Ok(())
}

/// A case-insensitive whole-word pattern for a character name.
fn name_pattern(name: &str) -> String {
    let mut out = String::from("\\m");
    for c in name.chars() {
        if !c.is_alphanumeric() && c != ' ' {
            out.push('\\');
        }
        out.push(c);
    }
    out.push_str("\\M");
    out
}

/// What stays of deleted characters elsewhere: their names leave the weekly
/// boards, the old GA list and other players' block lists; reports keep only
/// their category, map, time and status once they involve or mention one; the
/// moderation history keeps only what was done and when.
async fn forget_characters(
    tx: &Transaction<'_>,
    ids: &[i64],
    names: &[String],
    keys: &[String],
) -> Result<(), String> {
    if ids.is_empty() {
        return Ok(());
    }
    tx.execute("DELETE FROM gas WHERE name_key = ANY($1)", &[&keys])
        .await
        .map_err(|e| text(&e))?;
    let forgotten: std::collections::HashSet<String> = keys.iter().cloned().collect();
    let rows = tx
        .query("SELECT data FROM boards FOR UPDATE", &[])
        .await
        .map_err(|e| text(&e))?;
    for row in rows {
        let Json(mut board): Json<Board> = row.try_get(0).map_err(|e| text(&e))?;
        if forget_board_names(&mut board, &forgotten) {
            tx.execute(
                "UPDATE boards SET data = $3, updated_at = now()
                 WHERE dungeon = $1 AND difficulty = $2",
                &[&board.dungeon, &i32::from(board.difficulty), &Json(&board)],
            )
            .await
            .map_err(|e| text(&e))?;
        }
    }
    tx.execute(
        "UPDATE account_blocks SET name = $2 WHERE name = ANY($1)",
        &[&names, &DELETED_NAME],
    )
    .await
    .map_err(|e| text(&e))?;
    tx.execute(
        "UPDATE reports SET reporter_character = NULL, reporter_name = '',
                            body = '', context = '[]'::jsonb
         WHERE reporter_character = ANY($1) OR reporter_name = ANY($2)",
        &[&ids, &names],
    )
    .await
    .map_err(|e| text(&e))?;
    tx.execute(
        "UPDATE reports SET target_character = NULL, target_name = '',
                            body = '', context = '[]'::jsonb
         WHERE target_character = ANY($1) OR target_name = ANY($2)",
        &[&ids, &names],
    )
    .await
    .map_err(|e| text(&e))?;
    tx.execute(
        "UPDATE audit SET character_id = NULL, detail = '{}'::jsonb WHERE character_id = ANY($1)",
        &[&ids],
    )
    .await
    .map_err(|e| text(&e))?;
    for name in names {
        let pattern = name_pattern(name);
        tx.execute(
            "UPDATE reports SET body = '', context = '[]'::jsonb
             WHERE body ~* $1 OR context::text ~* $1",
            &[&pattern],
        )
        .await
        .map_err(|e| text(&e))?;
        tx.execute(
            "UPDATE audit SET detail = '{}'::jsonb WHERE detail::text ~* $1",
            &[&pattern],
        )
        .await
        .map_err(|e| text(&e))?;
    }
    Ok(())
}

/// The anonymous trace a deletion leaves: what, and how many characters.
async fn note_deletion(tx: &Transaction<'_>, kind: &str, characters: i64) -> Result<(), String> {
    tx.execute(
        "INSERT INTO audit (kind, detail) VALUES ($1, jsonb_build_object('characters', $2::bigint))",
        &[&kind, &characters],
    )
    .await
    .map_err(|e| text(&e))?;
    Ok(())
}

async fn delete_character(client: &mut Client, account: u64, character: u64) -> Result<(), String> {
    let (account, character) = (id_of(account, "account")?, id_of(character, "character")?);
    let tx = client.transaction().await.map_err(|e| text(&e))?;
    let row = tx
        .query_opt(
            "DELETE FROM characters WHERE id = $1 AND account_id = $2 RETURNING name_key, name",
            &[&character, &account],
        )
        .await
        .map_err(|e| text(&e))?;
    let Some(row) = row else {
        return Err("no character".to_owned());
    };
    let key: String = row.try_get(0).map_err(|e| text(&e))?;
    let name: String = row.try_get(1).map_err(|e| text(&e))?;
    forget_characters(&tx, &[character], &[name], &[key]).await?;
    note_deletion(&tx, "character_deleted", 1).await?;
    tx.commit().await.map_err(|e| text(&e))
}

async fn delete_account(client: &mut Client, account: u64) -> Result<(), String> {
    let account = id_of(account, "account")?;
    let tx = client.transaction().await.map_err(|e| text(&e))?;
    // Locked first: a character being made for it waits, then finds no account.
    if tx
        .query_opt(
            "SELECT 1 FROM accounts WHERE id = $1 FOR UPDATE",
            &[&account],
        )
        .await
        .map_err(|e| text(&e))?
        .is_none()
    {
        return Err("no account".to_owned());
    }
    let rows = tx
        .query(
            "DELETE FROM characters WHERE account_id = $1 RETURNING id, name_key, name",
            &[&account],
        )
        .await
        .map_err(|e| text(&e))?;
    let (mut ids, mut keys, mut names) = (Vec::new(), Vec::new(), Vec::new());
    for row in &rows {
        ids.push(row.try_get::<_, i64>(0).map_err(|e| text(&e))?);
        keys.push(row.try_get::<_, String>(1).map_err(|e| text(&e))?);
        names.push(row.try_get::<_, String>(2).map_err(|e| text(&e))?);
    }
    forget_characters(&tx, &ids, &names, &keys).await?;
    // Reports by or about the account, under names it no longer has too.
    tx.execute(
        "UPDATE reports SET reporter_character = NULL, reporter_name = '',
                            body = '', context = '[]'::jsonb
         WHERE reporter_account = $1",
        &[&account],
    )
    .await
    .map_err(|e| text(&e))?;
    tx.execute(
        "UPDATE reports SET target_character = NULL, target_name = '',
                            body = '', context = '[]'::jsonb
         WHERE target_account = $1",
        &[&account],
    )
    .await
    .map_err(|e| text(&e))?;
    // Its sanctions and block lists go with the row (ON DELETE CASCADE).
    tx.execute("DELETE FROM accounts WHERE id = $1", &[&account])
        .await
        .map_err(|e| text(&e))?;
    note_deletion(&tx, "account_deleted", ids.len() as i64).await?;
    tx.commit().await.map_err(|e| text(&e))
}

async fn touch_account(client: &Client, account: u64) -> Result<(), String> {
    client
        .execute(
            "UPDATE accounts SET last_login = now() WHERE id = $1",
            &[&id_of(account, "account")?],
        )
        .await
        .map_err(|e| text(&e))?;
    Ok(())
}

/// An account's roster, read from the sheets.
async fn characters(client: &Client, account: u64) -> Result<Vec<CharacterSummary>, String> {
    let rows = client
        .query(
            "SELECT id, sheet->>'name', sheet->>'house', (sheet->>'level')::integer,
                    sheet->'place'->>'map', COALESCE(sheet->'look', '[]'::jsonb)
             FROM characters WHERE account_id = $1 ORDER BY created_at, id",
            &[&id_of(account, "account")?],
        )
        .await
        .map_err(|e| text(&e))?;
    rows.iter()
        .map(|row| {
            let id: i64 = row.try_get(0).map_err(|e| text(&e))?;
            let name: Option<String> = row.try_get(1).map_err(|e| text(&e))?;
            let house: Option<String> = row.try_get(2).map_err(|e| text(&e))?;
            let level: Option<i32> = row.try_get(3).map_err(|e| text(&e))?;
            let Json(look): Json<Vec<(String, f32)>> = row.try_get(5).map_err(|e| text(&e))?;
            Ok(CharacterSummary {
                id: u64::try_from(id).map_err(|_| "character id out of range".to_owned())?,
                name: name.unwrap_or_default(),
                house: house.unwrap_or_default(),
                level: level.and_then(|l| u16::try_from(l).ok()).unwrap_or(1),
                map: row.try_get(4).map_err(|e| text(&e))?,
                look,
            })
        })
        .collect()
}

/// One transaction: the account locked, counted, the name checked, a fresh
/// id, the sheet stored. Err("full"), Err("taken"), Err("no account").
async fn create_character(
    client: &mut Client,
    account: u64,
    mut sheet: CharacterSheet,
    max: u8,
) -> Result<u64, String> {
    let account = id_of(account, "account")?;
    let tx = client.transaction().await.map_err(|e| text(&e))?;
    if tx
        .query_opt(
            "SELECT 1 FROM accounts WHERE id = $1 FOR UPDATE",
            &[&account],
        )
        .await
        .map_err(|e| text(&e))?
        .is_none()
    {
        return Err("no account".to_owned());
    }
    let count: i64 = tx
        .query_one(
            "SELECT count(*) FROM characters WHERE account_id = $1",
            &[&account],
        )
        .await
        .map_err(|e| text(&e))?
        .try_get(0)
        .map_err(|e| text(&e))?;
    if count >= i64::from(max) {
        return Err("full".to_owned());
    }
    moderation::hold_name(&tx, &sheet.name).await?;
    let key = name_key(&sheet.name);
    if tx
        .query_opt(
            "SELECT 1 FROM characters WHERE name_key = $1 AND account_id IS NOT NULL",
            &[&key],
        )
        .await
        .map_err(|e| text(&e))?
        .is_some()
    {
        return Err("taken".to_owned());
    }
    // Never over a character that is already stored (a development one).
    let id: i64 = loop {
        let id: i64 = tx
            .query_one("SELECT nextval('character_ids')", &[])
            .await
            .map_err(|e| text(&e))?
            .try_get(0)
            .map_err(|e| text(&e))?;
        if tx
            .query_opt("SELECT 1 FROM characters WHERE id = $1", &[&id])
            .await
            .map_err(|e| text(&e))?
            .is_none()
        {
            break id;
        }
    };
    sheet.id = u64::try_from(id).map_err(|_| "character id out of range".to_owned())?;
    let revision = id_of(sheet.revision, "revision")?;
    let map = sheet.place.as_ref().map(|p| p.map.clone());
    let level = i32::from(sheet.level);
    let inserted = tx
        .execute(
            "INSERT INTO characters
                (id, account_id, name, name_key, house, level, map, revision, sheet)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
            &[
                &id,
                &account,
                &sheet.name,
                &key,
                &sheet.house,
                &level,
                &map,
                &revision,
                &Json(&sheet),
            ],
        )
        .await;
    if let Err(e) = inserted {
        // Another account took the name a moment ago.
        if e.code() == Some(&SqlState::UNIQUE_VIOLATION)
            && e.as_db_error()
                .and_then(|d| d.constraint())
                .is_some_and(|c| c == "characters_name_key")
        {
            return Err("taken".to_owned());
        }
        return Err(text(&e));
    }
    moderation::keep_skeleton(&tx, id, &sheet.name).await?;
    tx.commit().await.map_err(|e| text(&e))?;
    Ok(sheet.id)
}

async fn owner(client: &Client, character: u64) -> Result<Option<u64>, String> {
    let row = client
        .query_opt(
            "SELECT account_id FROM characters WHERE id = $1",
            &[&id_of(character, "character")?],
        )
        .await
        .map_err(|e| text(&e))?;
    let account: Option<i64> = match row {
        Some(row) => row.try_get(0).map_err(|e| text(&e))?,
        None => None,
    };
    Ok(account.and_then(|a| u64::try_from(a).ok()))
}

async fn load_boards(client: &Client) -> Result<Vec<Board>, String> {
    let rows = client
        .query("SELECT data FROM boards ORDER BY dungeon, difficulty", &[])
        .await
        .map_err(|e| text(&e))?;
    rows.iter()
        .map(|row| {
            let Json(board): Json<Board> = row.try_get(0).map_err(|e| text(&e))?;
            Ok(board)
        })
        .collect()
}

async fn save_board(client: &Client, board: &Board) -> Result<(), String> {
    let week = i32::try_from(board.week).map_err(|_| "week out of range".to_owned())?;
    let difficulty = i32::from(board.difficulty);
    client
        .execute(
            "INSERT INTO boards (dungeon, difficulty, week, data) VALUES ($1, $2, $3, $4)
             ON CONFLICT (dungeon, difficulty) DO UPDATE SET
                week = EXCLUDED.week, data = EXCLUDED.data, updated_at = now()",
            &[&board.dungeon, &difficulty, &week, &Json(board)],
        )
        .await
        .map_err(|e| text(&e))?;
    Ok(())
}

async fn load_gas(client: &Client) -> Result<Vec<String>, String> {
    let rows = client
        .query("SELECT name_key FROM gas ORDER BY name_key", &[])
        .await
        .map_err(|e| text(&e))?;
    rows.iter()
        .map(|row| row.try_get(0).map_err(|e| text(&e)))
        .collect()
}

async fn set_ga(client: &Client, name: &str, on: bool) -> Result<(), String> {
    let key = name_key(name);
    if key.is_empty() {
        return Err("no name".to_owned());
    }
    let sql = if on {
        "INSERT INTO gas (name_key) VALUES ($1) ON CONFLICT DO NOTHING"
    } else {
        "DELETE FROM gas WHERE name_key = $1"
    };
    client.execute(sql, &[&key]).await.map_err(|e| text(&e))?;
    Ok(())
}

/// Reports are kept this long (the Privacy Policy says so).
const REPORT_DAYS: i32 = 180;

/// Removes reports past their time, at start and then every hour.
fn start_report_expiry(url: Arc<String>) {
    tokio::spawn(async move {
        let mut every = tokio::time::interval(Duration::from_secs(3600));
        loop {
            every.tick().await;
            let done = match connect(&url).await {
                Ok(client) => client
                    .execute(
                        "DELETE FROM reports WHERE at < now() - make_interval(days => $1)",
                        &[&REPORT_DAYS],
                    )
                    .await
                    .map_err(|e| text(&e)),
                Err(e) => Err(e.to_string()),
            };
            match done {
                Ok(0) => {}
                Ok(n) => println!("[persist] {n} expired report(s) removed"),
                Err(e) => eprintln!("[persist] expiring reports: {e}"),
            }
        }
    });
}

/// Save latencies are kept this long for the service's numbers.
const LATENCY_WINDOW: Duration = Duration::from_secs(60);
/// At most this many latencies are kept (a burst of saves cannot grow the
/// window without bound).
const LATENCY_MAX: usize = 100_000;

/// What the service counted since it started (`PersistMsg::Stats`).
struct Metrics {
    started: Instant,
    callers: AtomicU32,
    loads: AtomicU64,
    saves: AtomicU64,
    stale: AtomicU64,
    failures: AtomicU64,
    /// When each committed save of the last minute landed and how long it
    /// took (ms).
    latencies: std::sync::Mutex<VecDeque<(Instant, f32)>>,
}

impl Metrics {
    fn new() -> Self {
        Self {
            started: Instant::now(),
            callers: AtomicU32::new(0),
            loads: AtomicU64::new(0),
            saves: AtomicU64::new(0),
            stale: AtomicU64::new(0),
            failures: AtomicU64::new(0),
            latencies: std::sync::Mutex::new(VecDeque::new()),
        }
    }

    fn saved(&self, took: Duration) {
        self.saves.fetch_add(1, Ordering::Relaxed);
        let now = Instant::now();
        if let Ok(mut l) = self.latencies.lock() {
            l.push_back((now, took.as_secs_f32() * 1000.0));
            while l.len() > LATENCY_MAX
                || l.front().is_some_and(|(at, _)| now - *at > LATENCY_WINDOW)
            {
                l.pop_front();
            }
        }
    }

    /// The counters and the last minute's save latencies; the database
    /// figures are filled in by the caller.
    fn snapshot(&self) -> PersistStats {
        let now = Instant::now();
        let mut ms: Vec<f32> = self.latencies.lock().map_or_else(
            |_| Vec::new(),
            |l| {
                l.iter()
                    .filter(|(at, _)| now - *at <= LATENCY_WINDOW)
                    .map(|(_, ms)| *ms)
                    .collect()
            },
        );
        ms.sort_by(f32::total_cmp);
        let pick = |q: f32| {
            if ms.is_empty() {
                0.0
            } else {
                ms[((ms.len() - 1) as f32 * q) as usize]
            }
        };
        PersistStats {
            uptime_s: self.started.elapsed().as_secs(),
            callers: self.callers.load(Ordering::Relaxed),
            loads: self.loads.load(Ordering::Relaxed),
            saves: self.saves.load(Ordering::Relaxed),
            stale: self.stale.load(Ordering::Relaxed),
            failures: self.failures.load(Ordering::Relaxed),
            saves_last_minute: ms.len() as u32,
            save_p50_ms: pick(0.5),
            save_p99_ms: pick(0.99),
            save_max_ms: pick(1.0),
            ..PersistStats::default()
        }
    }
}

/// A linked caller, counted while its stream is open.
struct Caller<'a>(&'a Metrics);

impl<'a> Caller<'a> {
    fn new(metrics: &'a Metrics) -> Self {
        metrics.callers.fetch_add(1, Ordering::Relaxed);
        Self(metrics)
    }
}

impl Drop for Caller<'_> {
    fn drop(&mut self) {
        self.0.callers.fetch_sub(1, Ordering::Relaxed);
    }
}

/// The service's numbers with the database's size and rows; a database
/// that does not answer leaves them 0 and says why.
async fn stats(client: &Client, metrics: &Metrics) -> PersistStats {
    let mut out = metrics.snapshot();
    let row = client
        .query_one(
            "SELECT pg_database_size(current_database()),
                    (SELECT count(*) FROM characters),
                    (SELECT count(*) FROM accounts)",
            &[],
        )
        .await;
    let figures = row.and_then(|r| {
        Ok((
            r.try_get::<_, i64>(0)?,
            r.try_get::<_, i64>(1)?,
            r.try_get::<_, i64>(2)?,
        ))
    });
    match figures {
        Ok((size, characters, accounts)) => {
            out.database_bytes = u64::try_from(size).unwrap_or(0);
            out.characters = u64::try_from(characters).unwrap_or(0);
            out.accounts = u64::try_from(accounts).unwrap_or(0);
        }
        Err(e) => {
            metrics.failures.fetch_add(1, Ordering::Relaxed);
            out.database_error = text(&e);
        }
    }
    out
}

async fn answer(client: &mut Client, msg: PersistMsg, metrics: &Metrics) -> Option<PersistReply> {
    let reply = match msg {
        PersistMsg::Hello { .. } => return None,
        msg @ (PersistMsg::LoadModeration { .. }
        | PersistMsg::SetSanction { .. }
        | PersistMsg::ClearSanction { .. }
        | PersistMsg::SetBlock { .. }
        | PersistMsg::AddReport { .. }
        | PersistMsg::LoadReports { .. }
        | PersistMsg::CloseReport { .. }
        | PersistMsg::Audit { .. }
        | PersistMsg::FindCharacter { .. }) => moderation::answer(client, msg).await?,
        PersistMsg::Stats { req } => PersistReply::Stats {
            req,
            result: Ok(stats(client, metrics).await),
        },
        PersistMsg::Load { req, character } => {
            metrics.loads.fetch_add(1, Ordering::Relaxed);
            PersistReply::Loaded {
                req,
                result: load(client, character).await,
            }
        }
        PersistMsg::Save { req, sheet } => {
            let (character, revision) = (sheet.id, sheet.revision);
            let began = Instant::now();
            let (ok, error) = match save(client, &sheet).await {
                Ok(Saved::Stored) => {
                    metrics.saved(began.elapsed());
                    (true, String::new())
                }
                Ok(Saved::Stale) => {
                    metrics.stale.fetch_add(1, Ordering::Relaxed);
                    (false, "stale".to_owned())
                }
                // Nothing to keep, and nothing for the map to try again.
                Ok(Saved::Deleted) => {
                    println!("[persist] a save for deleted character {character} was dropped");
                    (true, String::new())
                }
                Err(e) => (false, e),
            };
            PersistReply::Saved {
                req,
                character,
                revision,
                ok,
                error,
            }
        }
        PersistMsg::Register {
            req,
            username,
            hash,
            recovery_hash,
            terms_version,
        } => PersistReply::Registered {
            req,
            result: register(client, &username, &hash, &recovery_hash, &terms_version).await,
        },
        PersistMsg::FindAccount { req, username } => PersistReply::Account {
            req,
            result: find_account(client, &username).await,
        },
        PersistMsg::TouchAccount { req, account } => PersistReply::Done {
            req,
            result: touch_account(client, account).await,
        },
        PersistMsg::Characters { req, account } => PersistReply::Characters {
            req,
            result: characters(client, account).await,
        },
        PersistMsg::CreateCharacter {
            req,
            account,
            sheet,
            max,
        } => PersistReply::Created {
            req,
            result: create_character(client, account, *sheet, max).await,
        },
        PersistMsg::Owner { req, character } => PersistReply::Owner {
            req,
            result: owner(client, character).await,
        },
        PersistMsg::LoadBoards { req } => PersistReply::Boards {
            req,
            result: load_boards(client).await,
        },
        PersistMsg::SaveBoard { req, board } => PersistReply::Done {
            req,
            result: save_board(client, &board).await,
        },
        PersistMsg::LoadGas { req } => PersistReply::Gas {
            req,
            result: load_gas(client).await,
        },
        PersistMsg::SetGa { req, name, on } => PersistReply::Done {
            req,
            result: set_ga(client, &name, on).await,
        },
        PersistMsg::AcceptTerms {
            req,
            account,
            version,
        } => PersistReply::Done {
            req,
            result: accept_terms(client, account, &version).await,
        },
        PersistMsg::SetPassword { req, account, hash } => PersistReply::Done {
            req,
            result: set_password(client, account, &hash).await,
        },
        PersistMsg::SetRecovery {
            req,
            account,
            recovery_hash,
        } => PersistReply::Done {
            req,
            result: set_recovery(client, account, &recovery_hash).await,
        },
        PersistMsg::Recover {
            req,
            account,
            used,
            hash,
            recovery_hash,
        } => PersistReply::Done {
            req,
            result: recover(client, account, &used, &hash, &recovery_hash).await,
        },
        PersistMsg::DeleteCharacter {
            req,
            account,
            character,
        } => PersistReply::Done {
            req,
            result: delete_character(client, account, character).await,
        },
        PersistMsg::DeleteAccount { req, account } => PersistReply::Done {
            req,
            result: delete_account(client, account).await,
        },
    };
    // Refusals are answers; anything else is the store failing.
    if let Some(e) = reply.error()
        && !matches!(
            e,
            "stale" | "taken" | "full" | "no account" | "no character"
        )
    {
        metrics.failures.fetch_add(1, Ordering::Relaxed);
        eprintln!("[persist] request {}: {e}", reply.req());
    }
    Some(reply)
}

async fn serve(
    mut stream: TcpStream,
    from: SocketAddr,
    key: Arc<[u8; 32]>,
    url: Arc<String>,
    metrics: Arc<Metrics>,
) -> AnyResult<()> {
    stream.set_nodelay(true)?;
    let mut reader = FrameReader::default();
    let mut chunk = vec![0_u8; 64 * 1024];
    // The hello first.
    let hello = loop {
        if let Some(frame) = reader.next_frame()? {
            break decode_msg(&frame)?;
        }
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            return Ok(());
        }
        reader.push(&chunk[..n]);
    };
    match hello {
        PersistMsg::Hello { key: theirs } if theirs == *key => {}
        _ => return Err("no hello with the service key".into()),
    }
    // One database connection per caller: its requests run in order.
    let mut client = connect(&url).await?;
    println!("[persist] {from} linked");
    let _caller = Caller::new(&metrics);
    loop {
        while let Some(frame) = reader.next_frame()? {
            let msg = decode_msg(&frame)?;
            if let Some(reply) = answer(&mut client, msg, &metrics).await {
                stream.write_all(&encode_reply(&reply)).await?;
            }
        }
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            println!("[persist] {from} left");
            return Ok(());
        }
        reader.push(&chunk[..n]);
    }
}

struct Options {
    bind: SocketAddr,
    keys: PathBuf,
}

fn options() -> AnyResult<Options> {
    let mut o = Options {
        bind: "127.0.0.1:7970".parse()?,
        keys: PathBuf::from("keys"),
    };
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        let value = it.next().ok_or_else(|| format!("{arg} needs a value"))?;
        match arg.as_str() {
            "--bind" => o.bind = value.parse()?,
            "--keys" => o.keys = PathBuf::from(value),
            other => return Err(format!("unknown option {other}").into()),
        }
    }
    Ok(o)
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> AnyResult<()> {
    let o = options()?;
    let key: [u8; 32] = std::fs::read(o.keys.join("coord.key"))?
        .try_into()
        .map_err(|_| "coord.key must be 32 bytes")?;
    let url = std::env::var("REALM_DATABASE_URL")
        .map_err(|_| "REALM_DATABASE_URL is not set (postgres://user:password@host:port/db)")?;
    let mut client = connect(&url).await?;
    migrate(&mut client).await?;
    let named = moderation::backfill_skeletons(&client).await?;
    if named > 0 {
        println!("[persist] look-alike keys made for {named} character(s)");
    }
    drop(client);
    let listener = TcpListener::bind(o.bind).await?;
    println!("[persist] listening on {}", o.bind);
    let (key, url) = (Arc::new(key), Arc::new(url));
    start_report_expiry(url.clone());
    let metrics = Arc::new(Metrics::new());
    loop {
        let (stream, from) = listener.accept().await?;
        let (key, url, metrics) = (key.clone(), url.clone(), metrics.clone());
        tokio::spawn(async move {
            if let Err(e) = serve(stream, from, key, url, metrics).await {
                eprintln!("[persist] {from}: {e}");
            }
        });
    }
}
