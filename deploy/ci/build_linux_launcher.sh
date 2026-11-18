#!/bin/bash
# Root wrapper the self-hosted runner calls through sudo (Docker needs root):
#   sudo <ci-dir>/build_linux_launcher.sh <launcher_cpp dir> <version> <out dir>
# Installed on the host in the CI tools directory (root-owned, see
# deploy/ci/README.md in semdin/realm). It builds the pinned image from the
# checked-out Dockerfile and runs build_appimage.sh in a throwaway container
# that sees the sources read-only and only writes to the output directory.
set -euo pipefail
src="$(realpath "$1")"
version="$2"
out="$(realpath -m "$3")"
case "$version" in *[!0-9.]*|'') echo "bad version '$version'" >&2; exit 2 ;; esac
case "$src" in /opt/actions-runner-realm/_work/*|/tmp/*) ;; *) echo "refusing source outside the runner workspace: $src" >&2; exit 2 ;; esac
case "$out" in /opt/actions-runner-realm/_work/*|/tmp/*) ;; *) echo "refusing output outside the runner workspace: $out" >&2; exit 2 ;; esac
test -f "$src/packaging/linux/Dockerfile"

docker build -q -t thousandrealms-launcher-build:22.04 "$src/packaging/linux" >/dev/null
mkdir -p "$out"
# The output belongs to the user who called sudo (the runner), not root.
chown "${SUDO_UID:-0}:${SUDO_GID:-0}" "$out"
docker run --rm --user "${SUDO_UID:-0}:${SUDO_GID:-0}" \
    -v "$src:/src:ro" -v "$out:/out" \
    thousandrealms-launcher-build:22.04 bash /src/packaging/linux/build_appimage.sh /src "$version" /out
