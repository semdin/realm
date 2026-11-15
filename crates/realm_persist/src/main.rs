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

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use realm_proto::control::FrameReader;
use realm_proto::coord::Board;
use realm_proto::persist::{
    AccountRow, CharacterSummary, PersistMsg, PersistReply, decode_msg, encode_reply,
};
use realm_rules::CharacterSheet;
use realm_rules::names::name_key;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_postgres::error::SqlState;
use tokio_postgres::types::Json;
use tokio_postgres::{Client, NoTls};

type AnyResult<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// The schema, in order; each runs once, in a transaction.
const MIGRATIONS: &[(i32, &str)] = &[
    (1, include_str!("../migrations/0001_realm.sql")),
    (2, include_str!("../migrations/0002_logins_boards_gas.sql")),
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

/// Ok(true): stored; Ok(false): the stored revision is newer.
async fn save(client: &Client, sheet: &CharacterSheet) -> Result<bool, String> {
    let id = i64::try_from(sheet.id).map_err(|_| "character id out of range".to_owned())?;
    let revision = i64::try_from(sheet.revision).map_err(|_| "revision out of range".to_owned())?;
    let name_key = name_key(&sheet.name);
    let map = sheet.place.as_ref().map(|p| p.map.clone());
    let level = i32::from(sheet.level);
    let doc = Json(sheet);
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
    Ok(stored.is_some())
}

fn id_of(value: u64, what: &str) -> Result<i64, String> {
    i64::try_from(value).map_err(|_| format!("{what} id out of range"))
}

fn text(e: &tokio_postgres::Error) -> String {
    e.to_string()
}

async fn register(client: &Client, username: &str, hash: &str) -> Result<u64, String> {
    let row = client
        .query_opt(
            "INSERT INTO accounts (username, password_hash) VALUES ($1, $2)
             ON CONFLICT DO NOTHING RETURNING id",
            &[&username, &hash],
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
            "SELECT id, username, password_hash FROM accounts WHERE lower(username) = lower($1)",
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
    }))
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

async fn answer(client: &mut Client, msg: PersistMsg) -> Option<PersistReply> {
    let reply = match msg {
        PersistMsg::Hello { .. } => return None,
        PersistMsg::Load { req, character } => PersistReply::Loaded {
            req,
            result: load(client, character).await,
        },
        PersistMsg::Save { req, sheet } => {
            let (character, revision) = (sheet.id, sheet.revision);
            let (ok, error) = match save(client, &sheet).await {
                Ok(true) => (true, String::new()),
                Ok(false) => (false, "stale".to_owned()),
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
        } => PersistReply::Registered {
            req,
            result: register(client, &username, &hash).await,
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
    };
    // Refusals are answers; anything else is the store failing.
    if let Some(e) = reply.error()
        && !matches!(e, "stale" | "taken" | "full")
    {
        eprintln!("[persist] request {}: {e}", reply.req());
    }
    Some(reply)
}

async fn serve(
    mut stream: TcpStream,
    from: SocketAddr,
    key: Arc<[u8; 32]>,
    url: Arc<String>,
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
    loop {
        while let Some(frame) = reader.next_frame()? {
            let msg = decode_msg(&frame)?;
            if let Some(reply) = answer(&mut client, msg).await {
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
    drop(client);
    let listener = TcpListener::bind(o.bind).await?;
    println!("[persist] listening on {}", o.bind);
    let (key, url) = (Arc::new(key), Arc::new(url));
    loop {
        let (stream, from) = listener.accept().await?;
        let (key, url) = (key.clone(), url.clone());
        tokio::spawn(async move {
            if let Err(e) = serve(stream, from, key, url).await {
                eprintln!("[persist] {from}: {e}");
            }
        });
    }
}
