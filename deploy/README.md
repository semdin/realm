# deploy

What runs the realm on its Linux host (Ubuntu 24.04+ / Debian 12+, x86_64).

## Layout

| Path | Holds |
| --- | --- |
| `/opt/realm/releases/<release>` | one unpacked release: `bin/`, `content/data`, `world/maps`, `deploy/`, `RELEASE` |
| `/opt/realm/current` | the live release (a symlink; the units run through it) |
| `/opt/realm/bin` | `realm-deploy` and the backup scripts (stable paths for PostgreSQL and systemd) |
| `/etc/realm/realm.env` | `REALM_DATABASE_URL`, `REALM_SERVICE_TOKEN`, `REALM_PUBLIC_HOST` (generated, root:realm 0640) |
| `/etc/realm/map-<map>.env` | `REALM_MAP_PORT` of each map server |
| `/var/lib/realm/keys` | `ticket.key/.pub`, `tls.crt.der/.key.der` (clients pin the certificate), `coord.key` |
| `/var/lib/realm/backup` | base backups and the WAL archive (postgres) |

Services (`systemd/`), all as the unprivileged `realm` user, sandboxed, under
`realm.target`: `realm-persist` (127.0.0.1:7970, the only database writer,
applies schema migrations at start), `realm-coord` (127.0.0.1:7900, admin
surface 127.0.0.1:8082), `realm-map@<map>` (QUIC on `0.0.0.0:<port>/udp`,
SIGTERM saves everyone), `realm-login` (127.0.0.1:7950, public through
`caddy/realm-login.caddy` with TLS). Logs: `journalctl -u 'realm-*'`.

## A release

`bash tools/ops/package.sh` builds the services in Docker with the pinned
toolchain (glibc 2.36, so any supported host runs them) and writes
`build/release/realm-<date>-<commit>.tar.gz` (~14 MB).

- First time, on a fresh host as root: `tar -xzOf realm-*.tar.gz --wildcards
  '*/deploy/install.sh' > install.sh && bash install.sh realm-*.tar.gz
  --public-host <ip>`. It installs PostgreSQL 18 (apt.postgresql.org),
  generates the secrets and keys, sets up archiving, the units and the map
  list (`REALM_MAPS`, ports 7777-7782/udp, opened in ufw when it is active),
  deploys and takes the first base backup. Running it again changes nothing
  that exists.
- Every release after: `/opt/realm/bin/realm-deploy realm-*.tar.gz
  [--countdown 300] [--reason text]`. The realm's maintenance announces it,
  closes logins, freezes and saves every map and empties it; then the
  services restart on the new release and are verified (every map linked,
  login healthy, `realm_netcheck --smoke` joins the grounds). A release that
  does not verify is rolled back to the previous one by itself. The newest
  three releases are kept.

`bash tools/ops/host_rehearsal.sh` rehearses all of it on an empty database
in a systemd container (`tools/ops/host`, ~3 min): install, the login service
end to end, a deploy with a player online (its save lands), a broken release
rolled back, backups.

## Metrics and the panel

Every map server sends the coordinator its status window every 5 s
(players, creatures, tick p50/p99/max, saves in flight and failed, bytes
out, memory), and the coordinator asks the persistence service for its
numbers as often (uptime, linked callers, loads, saves, stale saves,
failures, the last minute's save latency, database size, characters,
accounts). The admin surface (loopback, `x-service-token` =
`REALM_SERVICE_TOKEN`) serves them:

| Endpoint | Gives |
| --- | --- |
| `GET /admin/metrics` | JSON: state, release, uptime, players, seats in transit, parties, every map (linked or not, age of its last numbers, the numbers, 5 min of players and tick p99), the persistence block |
| `GET /admin/metrics.prom` | the same numbers as Prometheus text (`realm_*`), for a scraper later |
| `GET /panel` | the operator panel (no token: the page holds no data) |

From your machine, tunnel the admin port and open the panel with the token
in the address after `#` (the browser keeps that part to itself; the page
sends it as the header):

```bash
ssh -L 8082:127.0.0.1:8082 root@<host>
# then, in a browser on your machine:
#   http://127.0.0.1:8082/panel#token=<REALM_SERVICE_TOKEN from /etc/realm/realm.env>
```

It refreshes every 5 s. On the host itself: `curl -s -H "x-service-token:
$REALM_SERVICE_TOKEN" 127.0.0.1:8082/admin/metrics`.

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
