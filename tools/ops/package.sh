#!/usr/bin/env bash
# tools/ops/package.sh [out_dir]: the realm's server release for its Linux
# host (x86_64, glibc 2.36+: Debian 12, Ubuntu 24.04 and newer), built in
# Docker with the pinned toolchain so it runs on the host whatever builds it.
#
#   <out_dir>/realm-<release>.tar.gz
#     bin/       realm_server realm_coord realm_login realm_persist realm_netcheck
#                and deploy/backup's scripts
#     content/data  world/maps  deploy/   RELEASE (the release id)
#
# The release id is the commit's date and short hash (a "-dirty" suffix when
# the tree has changes). The cargo cache stays in the Docker volume
# realm-cargo, the toolchain in realm-rustup, the build in build/linux_target.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
out="${1:-build/release}"
root="$(pwd -W 2>/dev/null || pwd)"
image="rust:1.100.0-slim-bookworm"
release="$(git log -1 --date=format:%Y%m%d --format=%cd)-$(git rev-parse --short=8 HEAD)"
[ -z "$(git status --porcelain -- crates content world deploy Cargo.toml Cargo.lock)" ] || release="$release-dirty"

# Built, staged and packed inside Linux so modes and owners are right
# whatever the build machine's file system keeps.
docker run --rm -v "$root:/src" -v realm-cargo:/usr/local/cargo/registry -v realm-rustup:/usr/local/rustup -w /src \
    -e CARGO_TARGET_DIR=/src/build/linux_target -e RELEASE="$release" -e OUT="$out" "$image" bash -euc '
cargo build --release --locked -p realm_server -p realm_coord -p realm_login -p realm_persist -p realm_netcheck
stage="/tmp/realm-$RELEASE"
mkdir -p "$stage/bin" "$stage/content" "$stage/world" "$OUT"
for b in realm_server realm_coord realm_login realm_persist realm_netcheck; do
    cp "build/linux_target/release/$b" "$stage/bin/"
    strip --strip-debug "$stage/bin/$b"
done
cp deploy/backup/* "$stage/bin/"
cp -r content/data "$stage/content/"
cp -r world/maps "$stage/world/"
cp -r deploy "$stage/"
echo "$RELEASE" > "$stage/RELEASE"
chmod -R u=rwX,go=rX "$stage"
chmod 0755 "$stage"/bin/* "$stage/deploy/install.sh" "$stage/deploy/realm-deploy" "$stage"/deploy/backup/*
tar --owner=0 --group=0 --numeric-owner -czf "$OUT/realm-$RELEASE.tar.gz" -C /tmp "realm-$RELEASE"
'
echo "[package] $out/realm-$release.tar.gz ($(du -h "$out/realm-$release.tar.gz" | cut -f1))"
