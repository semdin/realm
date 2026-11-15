# deploy

What runs the realm on its Linux host. Installed under `/opt/realm`
(binaries and these scripts in `/opt/realm/bin`), secrets in `/etc/realm`.

## Database backups

The realm's PostgreSQL archives every finished WAL segment and takes a base
backup every night; together they restore the database to any moment since
the oldest kept base backup.

| File | Installed as | Does |
| --- | --- | --- |
| `postgres/realm-archive.conf` | `/etc/postgresql/18/main/conf.d/` | `archive_mode` on through `realm-wal-archive`, at least once a minute |
| `backup/realm-wal-archive` | `/opt/realm/bin/` | PostgreSQL's `archive_command`: one segment into `/var/lib/realm/backup/wal`, whole or not at all, never overwritten |
| `backup/realm-backup` | `/opt/realm/bin/` | a base backup into `/var/lib/realm/backup/base/<finished UTC>`, keeps `REALM_BACKUP_KEEP` (7) and the WAL they need; `REALM_BACKUP_SYNC` copies the folder off the host |
| `systemd/realm-backup.service`, `.timer` | `/etc/systemd/system/` | `realm-backup` as postgres, nightly 05:00 UTC (`/etc/realm/backup.env` for the settings above) |
| `backup/realm-restore` | `/opt/realm/bin/` | `realm-restore <backup dir> <latest \| 'YYYY-MM-DD HH:MM:SS+00'> <new data dir>`: a data folder that replays to the target and opens; start PostgreSQL on it |

Restoring the live database: stop the realm's services (the maintenance flow
saves everyone first), stop PostgreSQL, move its data folder aside (never
delete it), `realm-restore` into the old path as postgres, start PostgreSQL,
watch it replay and promote (`select pg_is_in_recovery()` turns false), then
start the services.

`bash tools/ops/backup_check.sh` rehearses all of it in Docker (~20 s, CI).
