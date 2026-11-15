#!/usr/bin/env bash
# tools/release/stage_client.sh <export dir> <windows|linux|macos> <cert.der> [realm_client library]
#
# Makes a Godot export of the client (game/export_presets.cfg) a complete
# game: the files the Rust core reads with std::fs go into the release root
# (game/scripts/systems/realm_paths.gd):
#
#   windows, linux   the export dir (beside ThousandRealms.exe / .x86_64)
#   macos            the folder holding "Thousand Realms.app" (the export dir
#                    is that folder, or the .app itself)
#
#   <root>/content/data/*.json      the game's content (content/data)
#   <root>/world/maps/*.realmmap    the map packs (world/maps)
#   <root>/keys/tls.crt.der         <cert.der>: the realm's public QUIC
#                                   certificate the client pins; nothing else
#                                   from keys/ ever ships
#
# The export already put the GDExtension libraries beside the executable
# (macOS: Contents/Frameworks), realm_client's from ../target/release; the
# optional 4th argument replaces it with that build (a CI artifact, another
# target dir; not on macOS, where the library is part of the bundle the
# export signed). Both extensions' libraries must be there or this fails.
# Nothing inside a macOS bundle is touched, so it never needs signing again.
#
# Works in Linux bash and Git Bash; run it from anywhere.
set -euo pipefail

usage() {
  echo "usage: $0 <export dir> <windows|linux|macos> <cert.der> [realm_client library]" >&2
  exit 2
}
[ $# -ge 3 ] && [ $# -le 4 ] || usage
export_dir="$1"
platform="$2"
cert="$3"
lib="${4:-}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "stage_client: $*" >&2; exit 1; }

[ -d "$export_dir" ] || fail "no export dir $export_dir"
[ -f "$cert" ] || fail "no certificate $cert"
# a DER certificate: an ASN.1 SEQUENCE (0x30), a few hundred bytes - never a
# private key or the ticket key handed over by mistake
cert_size=$(wc -c < "$cert" | tr -d ' ')
first=$(od -An -tx1 -N1 "$cert" | tr -d ' \n')
[ "$first" = "30" ] && [ "$cert_size" -gt 200 ] && [ "$cert_size" -lt 8192 ] \
  || fail "$cert is not a DER certificate (first byte $first, $cert_size bytes)"
case "$(basename "$cert")" in
  *key*) fail "$cert looks like a key, not the certificate" ;;
esac
[ -z "$lib" ] || [ -f "$lib" ] || fail "no library $lib"

app=""
case "$platform" in
  windows)
    [ -f "$export_dir/ThousandRealms.exe" ] || fail "no ThousandRealms.exe in $export_dir"
    root="$export_dir"
    lib_dir="$export_dir"
    lib_name="realm_client.dll"
    terrain="$export_dir/libterrain.windows.release.x86_64.dll"
    ;;
  linux)
    [ -f "$export_dir/ThousandRealms.x86_64" ] || fail "no ThousandRealms.x86_64 in $export_dir"
    root="$export_dir"
    lib_dir="$export_dir"
    lib_name="librealm_client.so"
    terrain="$export_dir/libterrain.linux.release.x86_64.so"
    ;;
  macos)
    # The launcher starts "Thousand Realms.app/Contents/MacOS/Thousand Realms"
    # (Godot names the bundle and its binary after application/config/name).
    case "$export_dir" in
      *.app|*.app/) app="${export_dir%/}" ;;
      *) app="$export_dir/Thousand Realms.app" ;;
    esac
    [ -x "$app/Contents/MacOS/Thousand Realms" ] || fail "no Thousand Realms.app bundle at $app"
    # The data sits beside the bundle, never in it: the bundle stays exactly
    # as Godot exported and signed it (the extension library included, put
    # into Contents/Frameworks by the export itself).
    root="$(dirname "$app")"
    lib_dir="$app/Contents/Frameworks"
    lib_name="librealm_client.dylib"
    terrain="$app/Contents/Frameworks/libterrain.macos.release.framework"
    ;;
  *) usage ;;
esac
if [ "$platform" = macos ]; then
  ls "$app/Contents/Resources"/*.pck > /dev/null 2>&1 || fail "no .pck in $app/Contents/Resources"
else
  ls "$root"/*.pck > /dev/null 2>&1 || fail "no .pck in $root"
fi

# the extension libraries
if [ -n "$lib" ] && [ "$platform" = macos ]; then
  fail "on macOS the export puts the library into the signed bundle: place it at target/release/librealm_client.dylib before exporting"
fi
if [ -n "$lib" ]; then
  mkdir -p "$lib_dir"
  cp -f "$lib" "$lib_dir/$lib_name"
fi
[ -f "$lib_dir/$lib_name" ] || fail "$lib_dir/$lib_name is missing (build realm_client, or pass it as the 4th argument)"
[ -e "$terrain" ] || fail "$terrain is missing (git lfs pull, then export again)"
if [ "$(wc -c < "$lib_dir/$lib_name" | tr -d ' ')" -lt 100000 ]; then
  fail "$lib_dir/$lib_name is too small (a Git LFS pointer?)"
fi

# the release root, fresh each time: nothing stale and no other key
rm -rf "$root/content" "$root/world" "$root/keys"
mkdir -p "$root/content/data" "$root/world/maps" "$root/keys"
cp "$repo"/content/data/*.json "$root/content/data/"
cp "$repo"/world/maps/*.realmmap "$root/world/maps/"
cp "$cert" "$root/keys/tls.crt.der"

size() { du -sk "$1" | awk '{printf "%.1f MB", $1 / 1024}'; }
echo "stage_client: $platform release root $root"
echo "  content/data  $(ls "$root/content/data" | wc -l | tr -d ' ') files, $(size "$root/content/data")"
echo "  world/maps    $(ls "$root/world/maps" | wc -l | tr -d ' ') packs, $(size "$root/world/maps")"
echo "  keys          tls.crt.der ($cert_size bytes)"
echo "  $lib_name  $(size "$lib_dir/$lib_name")"
echo "  total         $(size "$export_dir")"
