#!/usr/bin/env bash
# tools/ops/backup_check.sh: the realm's database backups, end to end, in
# Docker (postgres:18.7), about a minute. Uses deploy/backup as installed.
#
# 1. a PostgreSQL archiving through realm-wal-archive; a row before the base
#    backup (realm-backup), one after it, a moment noted, one more after;
# 2. realm-restore to that moment: the first two rows, not the third;
# 3. realm-restore "latest": all three;
# 4. a second realm-backup with REALM_BACKUP_KEEP=1 prunes the first base and
#    the WAL only it needed, and "latest" still restores all three.
set -euo pipefail
export MSYS_NO_PATHCONV=1
image="${REALM_PG_IMAGE:-postgres:18.7}"
root="$(cd "$(dirname "$0")/../.." && (pwd -W 2>/dev/null || pwd))"
id="rbk$$"
vol="$id-backup"
cleanup() {
    docker rm -f "$id-src" "$id-a" "$id-b" "$id-c" >/dev/null 2>&1 || true
    docker volume rm "$vol" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "[backup] FAIL: $*" >&2; exit 1; }
started=$SECONDS

docker volume create "$vol" >/dev/null
docker run -d --name "$id-src" -e POSTGRES_PASSWORD=check \
    -e REALM_WAL_ARCHIVE=/backup/wal \
    -v "$vol:/backup" -v "$root/deploy/backup:/opt/realm/bin:ro" "$image" \
    -c wal_level=replica -c archive_mode=on \
    -c "archive_command=/opt/realm/bin/realm-wal-archive %p %f" >/dev/null
docker exec -u root "$id-src" chown postgres /backup
ready() {
    for _ in $(seq 1 60); do
        if docker exec "$1" psql -U postgres -tAc "select not pg_is_in_recovery()" 2>/dev/null | grep -q t; then
            return 0
        fi
        sleep 0.5
    done
    docker logs "$1" 2>&1 | tail -20
    fail "$1 never opened"
}
sql() { docker exec "$1" psql -U postgres -v ON_ERROR_STOP=1 -tAc "$2"; }
ready "$id-src"
# The image's first start restarts the server once; wait for the final one.
sleep 1
ready "$id-src"

sql "$id-src" "create table probe (n int); insert into probe values (1)" >/dev/null
docker exec -u postgres -e REALM_BACKUP_DIR=/backup "$id-src" /opt/realm/bin/realm-backup
sleep 1.1
sql "$id-src" "insert into probe values (2)" >/dev/null
moment="$(sql "$id-src" "select to_char(clock_timestamp() at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.US+00')")"
sleep 1.1
sql "$id-src" "insert into probe values (3)" >/dev/null
sql "$id-src" "select pg_switch_wal()" >/dev/null
# Wait until the segment holding row 3 is archived.
for _ in $(seq 1 40); do
    [ "$(sql "$id-src" "select last_archived_wal = pg_walfile_name(pg_current_wal_lsn() - 1) from pg_stat_archiver")" = t ] && break
    sleep 0.25
done
echo "[backup] 1 ok: archiving, a base backup, rows 1 | backup | 2 | $moment | 3"

restore() { # name target -> the rows it serves
    docker run -d --name "$1" -u postgres -v "$vol:/backup" -v "$root/deploy/backup:/opt/realm/bin:ro" \
        --entrypoint bash "$image" -c "/opt/realm/bin/realm-restore /backup '$2' /tmp/data && exec postgres -D /tmp/data" >/dev/null
    ready "$1"
    sql "$1" "select string_agg(n::text, ',' order by n) from probe"
}
got="$(restore "$id-a" "$moment")"
[ "$got" = "1,2" ] || fail "restored to $moment: rows $got (want 1,2)"
echo "[backup] 2 ok: restored to the moment: rows $got"
got="$(restore "$id-b" latest)"
[ "$got" = "1,2,3" ] || fail "restored latest: rows $got (want 1,2,3)"
echo "[backup] 3 ok: restored latest: rows $got"

first_start="$(docker exec "$id-src" sh -c 'cat /backup/base/*/start_wal')"
sleep 1.1
docker exec -u postgres -e REALM_BACKUP_DIR=/backup -e REALM_BACKUP_KEEP=1 "$id-src" /opt/realm/bin/realm-backup
bases="$(docker exec "$id-src" sh -c 'ls /backup/base | wc -l')"
wal="$(docker exec "$id-src" sh -c 'ls /backup/wal | tr "
" " "')"
[ "$bases" = 1 ] || fail "$bases base backups kept (want 1)"
case "$wal" in
    *"$first_start"*) fail "the WAL archive was not pruned: $first_start (the first base's start) still in: $wal" ;;
esac
docker rm -f "$id-b" >/dev/null
got="$(restore "$id-c" latest)"
[ "$got" = "1,2,3" ] || fail "after pruning, latest: rows $got (want 1,2,3)"
echo "[backup] 4 ok: kept 1 base, WAL before $first_start pruned (left: $wal), latest still rows $got"
echo "[backup] ok in $((SECONDS - started)) s: point-in-time restore from base backups and the WAL archive"
