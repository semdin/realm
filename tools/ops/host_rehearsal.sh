#!/usr/bin/env bash
# tools/ops/host_rehearsal.sh [realm-<release>.tar.gz]: the realm's host,
# rehearsed on an empty database in a systemd container (tools/ops/host,
# Ubuntu 24.04), about 3 minutes, each stage failing fast:
#
# 1. deploy/install.sh from the package: PostgreSQL archiving, secrets,
#    keys, units, the first deploy (verified: maps linked, login healthy, a
#    player joins) and the first base backup; the coordinator's
#    /admin/metrics lists the maps;
# 2. an account registered, a character made and played through the login
#    service (realm_netcheck --login), its rows in PostgreSQL;
# 3. release B put live with a player on the grounds: the maintenance
#    announces, saves and empties the realm, B verifies; the player's save
#    is in the database;
# 4. release C with a coordinator that cannot start: verify fails and the
#    realm goes back to B by itself;
# 5. a base backup and the WAL archive on disk.
#
# Without an argument it packages the tree first (tools/ops/package.sh).
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
fail() { echo "[host] FAIL: $*" >&2; exit 1; }
say() { echo "[host $((SECONDS - t0))s] $*"; }
t0=$SECONDS
if [ $# -ge 1 ]; then tarball="$1"; else
    bash tools/ops/package.sh build/release >/dev/null
    tarball="$(ls -t build/release/realm-*.tar.gz | head -n 1)"
fi
name=realm-host-rehearsal
docker build -q -t realm-host:24.04 tools/ops/host >/dev/null
docker rm -f "$name" >/dev/null 2>&1 || true
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$name" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock realm-host:24.04 >/dev/null
on() { docker exec "$name" bash -c "$1"; }
timeout 30 docker exec "$name" systemctl is-system-running --wait >/dev/null || true
docker cp "$tarball" "$name:/root/a.tar.gz"
# Releases B and C: the same build under other ids; C's coordinator exits at once.
on 'set -e; cd /root; mkdir x; tar -xzf a.tar.gz -C x; a=$(ls x); r=$(cat x/$a/RELEASE)
    for v in b c; do
        rm -rf y; mkdir y; cp -a x/$a y/realm-$r-$v; echo $r-$v > y/realm-$r-$v/RELEASE
        if [ $v = c ]; then printf "#!/bin/sh\necho broken >&2\nexit 1\n" > y/realm-$r-$v/bin/realm_coord; fi
        tar -czf $v.tar.gz -C y realm-$r-$v
    done
    cp x/$a/deploy/install.sh /root/install.sh'
say "container up, releases a/b/c ready"

# 1. Install.
on 'timeout 240 bash /root/install.sh /root/a.tar.gz --public-host 127.0.0.1' > build/logs/host_install.log 2>&1 \
    || { tail -20 build/logs/host_install.log; fail "install.sh"; }
grep "verify ok" build/logs/host_install.log || fail "the first deploy did not verify"
bad="$(on 'systemctl list-units "realm*" --no-legend --all --state=failed' || true)"
[ -z "$bad" ] || fail "failed units: $bad"
on '. /etc/realm/realm.env && curl -sf -m 5 -H "x-service-token: $REALM_SERVICE_TOKEN" http://127.0.0.1:8082/admin/metrics | python3 -c "import json, sys; sys.exit(0 if json.load(sys.stdin).get(\"maps\") else 1)"' \
    || fail "/admin/metrics answered no maps"
say "1 ok: installed, every service up, first backup taken, metrics list the maps"

# 2. Login service end to end.
on 'cd /opt/realm/current && timeout 40 ./bin/realm_netcheck --login --login-addr 127.0.0.1:7950 --keys /var/lib/realm/keys' \
    > build/logs/host_login.log 2>&1 || { tail -8 build/logs/host_login.log; fail "the login check"; }
rows="$(on 'runuser -u postgres -- psql -d realm -tAc "select count(*) from characters where account_id is not null"')"
[ "$rows" -ge 1 ] || fail "no account-owned character rows"
say "2 ok: register, login, characters, play, join through the login service; $rows character row(s) owned"

# 3. Release B with a player online.
on 'cd /opt/realm/current && exec timeout 60 ./bin/realm_netcheck --server 127.0.0.1:7777 --map grounds --keys /var/lib/realm/keys --character 900500 --seconds 50' \
    > build/logs/host_player.log 2>&1 &
player=$!
for _ in $(seq 1 40); do grep -q "joined as" build/logs/host_player.log && break; sleep 0.5; done
grep -q "joined as" build/logs/host_player.log || fail "the player never joined"
on 'REALM_VERIFY_SECONDS=60 timeout 120 /opt/realm/bin/realm-deploy /root/b.tar.gz --countdown 5 --reason rehearsal' \
    > build/logs/host_deploy_b.log 2>&1 || { tail -12 build/logs/host_deploy_b.log; fail "deploy of B"; }
wait $player 2>/dev/null || true
grep -q "everyone saved and out" build/logs/host_deploy_b.log || fail "B went live without the maintenance"
grep -qi "maintenance\|closed" build/logs/host_player.log || fail "the player was never told of the maintenance"
saved="$(on 'runuser -u postgres -- psql -d realm -tAc "select map from characters where id = 900500"')"
[ "$saved" = grounds ] || fail "the player's save is not in the database ($saved)"
live="$(on 'basename $(readlink /opt/realm/current)')"
case "$live" in *-b) ;; *) fail "live is $live, not B" ;; esac
say "3 ok: B live after maintenance with a player online; the player's save landed"

# 4. Release C fails verify and rolls back.
if on 'REALM_VERIFY_SECONDS=15 timeout 150 /opt/realm/bin/realm-deploy /root/c.tar.gz --countdown 0' > build/logs/host_deploy_c.log 2>&1; then
    fail "the broken release C was accepted"
fi
grep -q "rolling back" build/logs/host_deploy_c.log || { tail -8 build/logs/host_deploy_c.log; fail "no rollback"; }
live="$(on 'basename $(readlink /opt/realm/current)')"
case "$live" in *-b) ;; *) fail "after the rollback live is $live, not B" ;; esac
grep -q "verify ok" <(sed -n '/rolling back/,$p' build/logs/host_deploy_c.log) || fail "B did not verify after the rollback"
say "4 ok: C refused at verify, back on B and verified"

# 5. Backups.
on 'systemctl is-active --quiet realm-backup.timer' || fail "the backup timer is not active"
bases="$(on 'ls /var/lib/realm/backup/base | wc -l')"
on 'runuser -u postgres -- psql -tAc "select pg_switch_wal()"' >/dev/null
sleep 2
wal="$(on 'ls /var/lib/realm/backup/wal 2>/dev/null | wc -l')"
[ "$bases" -ge 1 ] && [ "$wal" -ge 1 ] || fail "backups: $bases base(s), $wal WAL file(s)"
say "5 ok: $bases base backup(s), $wal archived WAL file(s), nightly timer active"
say "ok: install, login, drain deploy, rollback and backups on an empty database"
