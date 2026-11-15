//! realm_persist [--bind 127.0.0.1:7970] [--keys keys]
//!
//! The persistence service: the only thing that writes the realm's
//! PostgreSQL database (REALM_DATABASE_URL, e.g.
//! `postgres://realm:secret@127.0.0.1:5432/realm`). Map servers (and, from
//! 7.0b, the login service and the coordinator) reach it over one TCP stream
//! each and prove they hold keys/coord.key; players never do. At start it
//! brings the schema up to date (`migrations/`, recorded in
//! `schema_migrations`).
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
use realm_proto::persist::{PersistMsg, PersistReply, decode_msg, encode_reply};
use realm_rules::CharacterSheet;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_postgres::types::Json;
use tokio_postgres::{Client, NoTls};

type AnyResult<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// The schema, in order; each runs once, in a transaction.
const MIGRATIONS: &[(i32, &str)] = &[(1, include_str!("../migrations/0001_realm.sql"))];

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
    let name_key = sheet.name.trim().to_lowercase();
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

async fn answer(client: &Client, msg: PersistMsg) -> Option<PersistReply> {
    match msg {
        PersistMsg::Hello { .. } => None,
        PersistMsg::Load { req, character } => Some(PersistReply::Loaded {
            req,
            result: load(client, character).await,
        }),
        PersistMsg::Save { req, sheet } => {
            let (character, revision) = (sheet.id, sheet.revision);
            let (ok, error) = match save(client, &sheet).await {
                Ok(true) => (true, String::new()),
                Ok(false) => (false, "stale".to_owned()),
                Err(e) => {
                    eprintln!("[persist] save of {character}: {e}");
                    (false, e)
                }
            };
            Some(PersistReply::Saved {
                req,
                character,
                revision,
                ok,
                error,
            })
        }
    }
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
    let client = connect(&url).await?;
    println!("[persist] {from} linked");
    loop {
        while let Some(frame) = reader.next_frame()? {
            let msg = decode_msg(&frame)?;
            if let Some(reply) = answer(&client, msg).await {
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
