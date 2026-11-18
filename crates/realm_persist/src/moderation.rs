//! Sanctions, block lists, reports, the audit trail and look-alike names.
//!
//! A write for an account that is not in `accounts` (a development ticket) is
//! dropped rather than refused: these go through `PersistClient::keep`, which
//! retries a failure for ever.

use realm_proto::persist::{
    BlockRow, CharacterRef, PersistMsg, PersistReply, ReportRow, SanctionRow,
};
use realm_rules::names::name_skeleton;
use serde_json::{Value, json};
use tokio_postgres::types::Json;
use tokio_postgres::{Client, Transaction};

fn text(e: &tokio_postgres::Error) -> String {
    e.to_string()
}

fn id(value: u64) -> Result<i64, String> {
    i64::try_from(value).map_err(|_| "id out of range".to_owned())
}

fn unsigned(value: i64) -> u64 {
    u64::try_from(value).unwrap_or(0)
}

async fn load(client: &Client) -> Result<(Vec<SanctionRow>, Vec<BlockRow>), String> {
    let rows = client
        .query(
            "SELECT account_id, kind, until_unix, reason, by_name,
                    extract(epoch FROM at)::bigint
             FROM sanctions
             WHERE until_unix = 0 OR until_unix > extract(epoch FROM now())::bigint",
            &[],
        )
        .await
        .map_err(|e| text(&e))?;
    let mut sanctions = Vec::with_capacity(rows.len());
    for r in &rows {
        sanctions.push(SanctionRow {
            account: unsigned(r.try_get(0).map_err(|e| text(&e))?),
            kind: r.try_get(1).map_err(|e| text(&e))?,
            until: unsigned(r.try_get(2).map_err(|e| text(&e))?),
            reason: r.try_get(3).map_err(|e| text(&e))?,
            by: r.try_get(4).map_err(|e| text(&e))?,
            at: unsigned(r.try_get(5).map_err(|e| text(&e))?),
        });
    }
    let rows = client
        .query(
            "SELECT account_id, blocked_id, name FROM account_blocks",
            &[],
        )
        .await
        .map_err(|e| text(&e))?;
    let mut blocks = Vec::with_capacity(rows.len());
    for r in &rows {
        blocks.push(BlockRow {
            account: unsigned(r.try_get(0).map_err(|e| text(&e))?),
            blocked: unsigned(r.try_get(1).map_err(|e| text(&e))?),
            name: r.try_get(2).map_err(|e| text(&e))?,
        });
    }
    Ok((sanctions, blocks))
}

async fn set_sanction(client: &Client, row: &SanctionRow) -> Result<(), String> {
    client
        .execute(
            "INSERT INTO sanctions (account_id, kind, until_unix, reason, by_name)
             SELECT $1, $2, $3, $4, $5 WHERE EXISTS (SELECT 1 FROM accounts WHERE id = $1)
             ON CONFLICT (account_id, kind) DO UPDATE SET
                until_unix = EXCLUDED.until_unix, reason = EXCLUDED.reason,
                by_name = EXCLUDED.by_name, at = now()",
            &[
                &id(row.account)?,
                &row.kind,
                &id(row.until)?,
                &row.reason,
                &row.by,
            ],
        )
        .await
        .map_err(|e| text(&e))?;
    Ok(())
}

async fn clear_sanction(client: &Client, account: u64, kind: &str) -> Result<(), String> {
    client
        .execute(
            "DELETE FROM sanctions WHERE account_id = $1 AND kind = $2",
            &[&id(account)?, &kind],
        )
        .await
        .map_err(|e| text(&e))?;
    Ok(())
}

async fn set_block(client: &Client, row: &BlockRow, on: bool) -> Result<(), String> {
    let (account, blocked) = (id(row.account)?, id(row.blocked)?);
    if on {
        client
            .execute(
                "INSERT INTO account_blocks (account_id, blocked_id, name)
                 SELECT $1, $2, $3
                 WHERE EXISTS (SELECT 1 FROM accounts WHERE id = $1)
                   AND EXISTS (SELECT 1 FROM accounts WHERE id = $2)
                 ON CONFLICT (account_id, blocked_id) DO UPDATE SET name = EXCLUDED.name",
                &[&account, &blocked, &row.name],
            )
            .await
    } else {
        client
            .execute(
                "DELETE FROM account_blocks WHERE account_id = $1 AND blocked_id = $2",
                &[&account, &blocked],
            )
            .await
    }
    .map_err(|e| text(&e))?;
    Ok(())
}

async fn add_report(client: &Client, row: &ReportRow) -> Result<(), String> {
    let context: Value = serde_json::from_str(&row.context).unwrap_or_else(|_| json!([]));
    client
        .execute(
            "INSERT INTO reports (reporter_account, reporter_character, reporter_name,
                                  target_account, target_character, target_name,
                                  category, body, map, context)
             VALUES ((SELECT id FROM accounts WHERE id = $1), $2, $3,
                     (SELECT id FROM accounts WHERE id = $4), $5, $6, $7, $8, $9, $10)",
            &[
                &id(row.reporter_account)?,
                &id(row.reporter_character)?,
                &row.reporter_name,
                &id(row.target_account)?,
                &id(row.target_character)?,
                &row.target_name,
                &row.category,
                &row.text,
                &row.map,
                &Json(&context),
            ],
        )
        .await
        .map_err(|e| text(&e))?;
    Ok(())
}

async fn load_reports(
    client: &Client,
    limit: u32,
    open_only: bool,
) -> Result<Vec<ReportRow>, String> {
    let rows = client
        .query(
            "SELECT id, extract(epoch FROM at)::bigint, COALESCE(reporter_account, 0),
                    COALESCE(reporter_character, 0), reporter_name, COALESCE(target_account, 0),
                    COALESCE(target_character, 0), target_name, category, body, map,
                    context::text, status
             FROM reports WHERE NOT $1 OR status = 'open' ORDER BY at DESC LIMIT $2",
            &[&open_only, &i64::from(limit.min(500))],
        )
        .await
        .map_err(|e| text(&e))?;
    rows.iter()
        .map(|r| {
            Ok(ReportRow {
                id: unsigned(r.try_get(0).map_err(|e| text(&e))?),
                at: unsigned(r.try_get(1).map_err(|e| text(&e))?),
                reporter_account: unsigned(r.try_get(2).map_err(|e| text(&e))?),
                reporter_character: unsigned(r.try_get(3).map_err(|e| text(&e))?),
                reporter_name: r.try_get(4).map_err(|e| text(&e))?,
                target_account: unsigned(r.try_get(5).map_err(|e| text(&e))?),
                target_character: unsigned(r.try_get(6).map_err(|e| text(&e))?),
                target_name: r.try_get(7).map_err(|e| text(&e))?,
                category: r.try_get(8).map_err(|e| text(&e))?,
                text: r.try_get(9).map_err(|e| text(&e))?,
                map: r.try_get(10).map_err(|e| text(&e))?,
                context: r.try_get(11).map_err(|e| text(&e))?,
                status: r.try_get(12).map_err(|e| text(&e))?,
            })
        })
        .collect()
}

async fn close_report(client: &Client, report: u64, status: &str) -> Result<(), String> {
    client
        .execute(
            "UPDATE reports SET status = $2 WHERE id = $1",
            &[&id(report)?, &status],
        )
        .await
        .map_err(|e| text(&e))?;
    Ok(())
}

async fn audit(
    client: &Client,
    character: Option<u64>,
    kind: &str,
    detail: &str,
) -> Result<(), String> {
    let character = character.map(id).transpose()?;
    let detail: Value = serde_json::from_str(detail).unwrap_or_else(|_| json!({"text": detail}));
    client
        .execute(
            "INSERT INTO audit (character_id, kind, detail) VALUES ($1, $2, $3)",
            &[&character, &kind, &Json(&detail)],
        )
        .await
        .map_err(|e| text(&e))?;
    Ok(())
}

/// The character named `name` (whatever the case) and its account.
async fn find_character(client: &Client, name: &str) -> Result<Option<CharacterRef>, String> {
    let key = realm_rules::names::name_key(name);
    let row = client
        .query_opt(
            "SELECT id, account_id, name FROM characters
             WHERE name_key = $1 AND account_id IS NOT NULL",
            &[&key],
        )
        .await
        .map_err(|e| text(&e))?;
    let Some(row) = row else {
        return Ok(None);
    };
    Ok(Some(CharacterRef {
        character: unsigned(row.try_get(0).map_err(|e| text(&e))?),
        account: unsigned(row.try_get(1).map_err(|e| text(&e))?),
        name: row.try_get(2).map_err(|e| text(&e))?,
    }))
}

/// Answers the moderation requests; anything else is not for here.
pub async fn answer(client: &Client, msg: PersistMsg) -> Option<PersistReply> {
    Some(match msg {
        PersistMsg::LoadModeration { req } => PersistReply::Moderation {
            req,
            result: load(client).await,
        },
        PersistMsg::SetSanction { req, row } => PersistReply::Done {
            req,
            result: set_sanction(client, &row).await,
        },
        PersistMsg::ClearSanction { req, account, kind } => PersistReply::Done {
            req,
            result: clear_sanction(client, account, &kind).await,
        },
        PersistMsg::SetBlock { req, row, on } => PersistReply::Done {
            req,
            result: set_block(client, &row, on).await,
        },
        PersistMsg::AddReport { req, row } => PersistReply::Done {
            req,
            result: add_report(client, &row).await,
        },
        PersistMsg::LoadReports {
            req,
            limit,
            open_only,
        } => PersistReply::Reports {
            req,
            result: load_reports(client, limit, open_only).await,
        },
        PersistMsg::CloseReport { req, id, status } => PersistReply::Done {
            req,
            result: close_report(client, id, &status).await,
        },
        PersistMsg::Audit {
            req,
            character,
            kind,
            detail,
        } => PersistReply::Done {
            req,
            result: audit(client, character, &kind, &detail).await,
        },
        PersistMsg::FindCharacter { req, name } => PersistReply::Character {
            req,
            result: find_character(client, &name).await,
        },
        _ => return None,
    })
}

/// In a character's creation: its look-alike key is free, and stays free
/// for this transaction. Err("taken") when a player's character has it.
pub async fn hold_name(tx: &Transaction<'_>, name: &str) -> Result<(), String> {
    let skeleton = name_skeleton(name);
    tx.execute(
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 7))",
        &[&skeleton],
    )
    .await
    .map_err(|e| text(&e))?;
    let taken = tx
        .query_opt(
            "SELECT 1 FROM characters WHERE name_skeleton = $1 AND account_id IS NOT NULL",
            &[&skeleton],
        )
        .await
        .map_err(|e| text(&e))?
        .is_some();
    if taken {
        return Err("taken".to_owned());
    }
    Ok(())
}

pub async fn keep_skeleton(tx: &Transaction<'_>, character: i64, name: &str) -> Result<(), String> {
    tx.execute(
        "UPDATE characters SET name_skeleton = $2 WHERE id = $1",
        &[&character, &name_skeleton(name)],
    )
    .await
    .map_err(|e| text(&e))?;
    Ok(())
}

/// Characters made before the column existed get theirs at start.
pub async fn backfill_skeletons(client: &Client) -> Result<u64, String> {
    let rows = client
        .query(
            "SELECT id, name FROM characters WHERE name_skeleton IS NULL",
            &[],
        )
        .await
        .map_err(|e| text(&e))?;
    let mut done = 0;
    for r in &rows {
        let character: i64 = r.try_get(0).map_err(|e| text(&e))?;
        let name: String = r.try_get(1).map_err(|e| text(&e))?;
        done += client
            .execute(
                "UPDATE characters SET name_skeleton = $2 WHERE id = $1",
                &[&character, &name_skeleton(&name)],
            )
            .await
            .map_err(|e| text(&e))?;
    }
    Ok(done)
}
