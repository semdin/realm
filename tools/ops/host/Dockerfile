# A stand-in for the realm's Linux host (Ubuntu 24.04 with systemd as PID 1)
# for tools/ops/host_rehearsal.sh. PostgreSQL 18 is installed here only so
# the rehearsal does not download it every time; install.sh installs it the
# same way on a real host.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q \
 && apt-get install -yq systemd systemd-sysv dbus curl ca-certificates python3 postgresql-common procps \
 && /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y \
 && apt-get install -yq postgresql-18 \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl mask getty@tty1.service systemd-logind.service console-getty.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
