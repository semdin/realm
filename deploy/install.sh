#!/usr/bin/env bash
# install.sh <realm-<release>.tar.gz> --public-host <ip or name>
#
# Sets up a fresh Ubuntu 24.04+ / Debian 12+ host for the realm, as root,
# and starts it. Safe to run again: nothing that exists is regenerated
# (secrets, keys, the database), units and the map list are refreshed.
#
#   PostgreSQL 18 (apt.postgresql.org) with WAL archiving (deploy/postgres),
#   the realm user, /opt/realm (releases, current, bin), /etc/realm
#   (realm.env with generated secrets, one map-<map>.env per map server),
#   /var/lib/realm (keys from realm_server keygen, backup/), the systemd
#   units, the nightly backup timer, the first deploy and the first backup.
#
# The maps and their QUIC ports (UDP) are REALM_MAPS below; open them in the
# firewall (ufw is opened here when it is active). Caddy for the login
# service is separate: deploy/caddy/realm-login.caddy.
set -euo pipefail
tarball="$(realpath "$1")"; shift
public=""
while [ $# -gt 0 ]; do
    case "$1" in
        --public-host) public="$2"; shift 2 ;;
        *) echo "install.sh: unknown option $1" >&2; exit 2 ;;
    esac
done
[ -n "$public" ] || { echo "install.sh: --public-host is required" >&2; exit 2; }
REALM_MAPS="${REALM_MAPS:-grounds:7777 castle_interior:7778 dng_trial:7779 spider_caverns:7780 dng_sealed_wing:7781 dng_spider_lair:7782}"
PG=18
say() { echo "[install] $*"; }
export DEBIAN_FRONTEND=noninteractive

# PostgreSQL from its own repository (the distribution's is older).
if ! command -v "/usr/lib/postgresql/$PG/bin/postgres" >/dev/null; then
    say "PostgreSQL $PG"
    apt-get update -q
    apt-get install -yq curl ca-certificates python3 postgresql-common
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
    apt-get install -yq "postgresql-$PG"
fi
command -v python3 >/dev/null && command -v curl >/dev/null || apt-get install -yq curl python3

id realm >/dev/null 2>&1 || useradd --system --home-dir /var/lib/realm --shell /usr/sbin/nologin realm
install -d -m 0755 /opt/realm /opt/realm/releases /opt/realm/bin
install -d -m 0750 -o root -g realm /etc/realm
install -d -m 0755 -o realm -g realm /var/lib/realm
install -d -m 0700 -o realm -g realm /var/lib/realm/keys
install -d -m 0700 -o postgres -g postgres /var/lib/realm/backup

# Secrets, generated once.
if [ ! -f /etc/realm/realm.env ]; then
    say "secrets in /etc/realm/realm.env"
    dbpw="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    token="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    umask 027
    cat > /etc/realm/realm.env <<ENV
REALM_DATABASE_URL=postgres://realm:$dbpw@127.0.0.1:5432/realm
REALM_SERVICE_TOKEN=$token
REALM_PUBLIC_HOST=$public
ENV
    umask 022
    chgrp realm /etc/realm/realm.env
fi
sed -i "s/^REALM_PUBLIC_HOST=.*/REALM_PUBLIC_HOST=$public/" /etc/realm/realm.env
# shellcheck disable=SC1091
. /etc/realm/realm.env
dbpw="$(printf %s "$REALM_DATABASE_URL" | sed -n 's#^postgres://realm:\([^@]*\)@.*#\1#p')"

# The release's files (realm-deploy finds them unpacked).
release="$(tar -xzOf "$tarball" --wildcards '*/RELEASE' | head -n 1)"
if [ ! -d "/opt/realm/releases/$release" ]; then
    tar --no-same-owner -xzf "$tarball" -C /opt/realm/releases
    mv "/opt/realm/releases/realm-$release" "/opt/realm/releases/$release"
fi
rel="/opt/realm/releases/$release"
install -m 0755 "$rel"/bin/realm-wal-archive "$rel"/bin/realm-backup "$rel"/bin/realm-restore /opt/realm/bin/
install -m 0755 "$rel/deploy/realm-deploy" /opt/realm/bin/

# PostgreSQL: archiving on, the realm's role and database.
conf="/etc/postgresql/$PG/main/conf.d/realm-archive.conf"
if ! cmp -s "$rel/deploy/postgres/realm-archive.conf" "$conf"; then
    say "WAL archiving on"
    install -m 0644 "$rel/deploy/postgres/realm-archive.conf" "$conf"
    systemctl restart "postgresql@$PG-main"
fi
for _ in $(seq 1 30); do runuser -u postgres -- pg_isready -q && break; sleep 1; done
if ! runuser -u postgres -- psql -tAc "select 1 from pg_roles where rolname = 'realm'" | grep -q 1; then
    say "database realm"
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -v pw="$dbpw" <<'SQL'
CREATE ROLE realm LOGIN PASSWORD :'pw';
CREATE DATABASE realm OWNER realm;
SQL
fi

# Keys: the ticket signing pair, the QUIC certificate (clients pin it), the
# service key between map servers, coordinator, login and persistence.
if [ ! -f /var/lib/realm/keys/coord.key ]; then
    say "keys in /var/lib/realm/keys (ship tls.crt.der with the client)"
    runuser -u realm -- "$rel/bin/realm_server" keygen /var/lib/realm/keys
fi

# Units and the map list.
install -m 0644 "$rel"/deploy/systemd/*.service "$rel"/deploy/systemd/*.target "$rel"/deploy/systemd/*.timer /etc/systemd/system/
install -d -m 0755 /etc/systemd/journald.conf.d
install -m 0644 "$rel"/deploy/journald/realm.conf /etc/systemd/journald.conf.d/realm.conf
systemctl restart systemd-journald
systemctl daemon-reload
for old in /etc/systemd/system/realm.target.wants/realm-map@*.service; do
    [ -e "$old" ] || continue
    systemctl disable --quiet "$(basename "$old")"
done
ports=""
for entry in $REALM_MAPS; do
    map="${entry%%:*}"; port="${entry##*:}"
    printf 'REALM_MAP_PORT=%s\n' "$port" > "/etc/realm/map-$map.env"
    systemctl enable --quiet "realm-map@$map.service"
    ports="$ports $port"
done
systemctl enable --quiet realm.target realm-persist.service realm-coord.service realm-login.service
systemctl enable --quiet --now realm-backup.timer
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    for port in $ports; do ufw allow "$port/udp" >/dev/null; done
    say "ufw: opened$ports (udp)"
fi

if [ ! -e /opt/realm/current ]; then
    /opt/realm/bin/realm-deploy "$tarball" --no-maintenance
    say "first base backup"
    systemctl start realm-backup.service
else
    say "already deployed: /opt/realm/bin/realm-deploy <tarball> puts a release live"
fi
say "done"
