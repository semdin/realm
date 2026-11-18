#!/bin/bash
# Builds the macOS launcher on a macOS host (GitHub-hosted runner):
#   build_app.sh <launcher dir> <launcher version> <out dir>
# Produces in <out dir>:
#   ThousandRealms.dmg                  drag-to-Applications disk image for new players
#   ThousandRealms_Launcher-macos.zip   the complete app: what installed launchers update to
#   ThousandRealms_Launcher-macos       the bare universal Mach-O, for launchers older than
#                                       whole-app updates
#   ThousandRealms_UpdaterCLI-macos     headless updater for the tests
#   signing.txt                         "developer-id" or "adhoc"
#
# Universal (x86_64 + arm64). Signing turns on by itself when these repository
# secrets reach the environment (all five, or the build stops):
#   APPLE_DEVELOPER_ID_P12_BASE64    Developer ID Application certificate + key, base64
#   APPLE_DEVELOPER_ID_P12_PASSWORD  its export password
#   APPLE_NOTARY_KEY_BASE64          App Store Connect API key (.p8), base64
#   APPLE_NOTARY_KEY_ID              its key id
#   APPLE_NOTARY_ISSUER_ID           its issuer id
# With them the app and the disk image are signed, notarized and stapled.
# Without them the app is signed ad hoc: macOS then blocks the first open until
# the player allows it (FIRST_OPEN.txt says how).
set -euo pipefail
src="$(cd "$1" && pwd)"
version="$2"
mkdir -p "$3"
out="$(cd "$3" && pwd)"
work="$(mktemp -d)"
build="$work/build"
keychain="$work/signing.keychain-db"

cleanup() { security delete-keychain "$keychain" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

identity=""
secrets_set=0
for name in APPLE_DEVELOPER_ID_P12_BASE64 APPLE_DEVELOPER_ID_P12_PASSWORD APPLE_NOTARY_KEY_BASE64 \
            APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID; do
    [ -n "${!name:-}" ] && secrets_set=$((secrets_set + 1))
done
if [ "$secrets_set" -ne 0 ] && [ "$secrets_set" -ne 5 ]; then
    echo "::error::only $secrets_set of the 5 Apple signing secrets are set" >&2
    exit 1
fi
if [ "$secrets_set" -eq 5 ]; then
    keychain_pass="$(uuidgen)"
    security create-keychain -p "$keychain_pass" "$keychain"
    security set-keychain-settings -lut 21600 "$keychain"
    security unlock-keychain -p "$keychain_pass" "$keychain"
    printf '%s' "$APPLE_DEVELOPER_ID_P12_BASE64" | base64 --decode > "$work/cert.p12"
    security import "$work/cert.p12" -k "$keychain" -P "$APPLE_DEVELOPER_ID_P12_PASSWORD" \
        -T /usr/bin/codesign >/dev/null
    rm -f "$work/cert.p12"
    security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_pass" "$keychain" >/dev/null
    # shellcheck disable=SC2046
    security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
    identity="$(security find-identity -v -p codesigning "$keychain" \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
    [ -n "$identity" ] || { echo "::error::no Developer ID Application identity in the certificate" >&2; exit 1; }
    printf '%s' "$APPLE_NOTARY_KEY_BASE64" | base64 --decode > "$work/notary.p8"
fi

notarize() {
    local result id
    result="$(xcrun notarytool submit "$1" --key "$work/notary.p8" --key-id "$APPLE_NOTARY_KEY_ID" \
        --issuer "$APPLE_NOTARY_ISSUER_ID" --wait --timeout 30m --output-format json)"
    echo "$result"
    id="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
    if ! printf '%s' "$result" | grep -q '"status" *: *"Accepted"'; then
        xcrun notarytool log "$id" --key "$work/notary.p8" --key-id "$APPLE_NOTARY_KEY_ID" \
            --issuer "$APPLE_NOTARY_ISSUER_ID" || true
        echo "::error::Apple did not accept $1" >&2
        exit 1
    fi
}

cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
    -DREALM_LAUNCHER_VERSION="$version" >/dev/null
ninja -C "$build" ThousandRealms_Launcher ThousandRealms_UpdaterCLI >/dev/null
lipo -info "$build/ThousandRealms_Launcher"
otool -L "$build/ThousandRealms_Launcher"

app="$work/Thousand Realms Launcher.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$build/ThousandRealms_Launcher" "$app/Contents/MacOS/ThousandRealms_Launcher"
sed "s/@VERSION@/$version/g" "$src/packaging/macos/Info.plist.in" > "$app/Contents/Info.plist"
cp "$src/THIRD_PARTY_NOTICES.txt" "$app/Contents/Resources/"

iconset="$work/ThousandRealms.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$src/assets/thousand_realms_1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$src/assets/thousand_realms_1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/ThousandRealms.icns"

if [ -n "$identity" ]; then
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
    codesign --verify --deep --strict "$app"
    ditto -c -k --keepParent "$app" "$work/notarize.zip"
    notarize "$work/notarize.zip"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    echo developer-id > "$out/signing.txt"
else
    codesign --force --deep --sign - "$app"
    codesign --verify --deep --strict "$app"
    echo adhoc > "$out/signing.txt"
fi

rm -f "$out/ThousandRealms_Launcher-macos.zip" "$out/ThousandRealms.dmg"
ditto -c -k --keepParent "$app" "$out/ThousandRealms_Launcher-macos.zip"
cp "$app/Contents/MacOS/ThousandRealms_Launcher" "$out/ThousandRealms_Launcher-macos"
cp "$build/ThousandRealms_UpdaterCLI" "$out/ThousandRealms_UpdaterCLI-macos"

# The disk image. dmgbuild writes the Finder layout itself, so no Finder (and
# no GUI session) is needed on the build machine.
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install --quiet --disable-pip-version-check \
    dmgbuild==2.0.0 ds_store==1.3.4 mac_alias==2.2.4
readme=""
[ -z "$identity" ] && readme="$src/packaging/macos/FIRST_OPEN.txt"
"$work/venv/bin/dmgbuild" -s "$src/packaging/macos/dmg_settings.py" \
    -D app="$app" -D icon="$app/Contents/Resources/ThousandRealms.icns" \
    -D background="$src/packaging/macos/dmg_background.png" -D readme="$readme" \
    "Thousand Realms" "$out/ThousandRealms.dmg"
if [ -n "$identity" ]; then
    codesign --force --timestamp --sign "$identity" "$out/ThousandRealms.dmg"
    notarize "$out/ThousandRealms.dmg"
    xcrun stapler staple "$out/ThousandRealms.dmg"
    xcrun stapler validate "$out/ThousandRealms.dmg"
    spctl --assess --type open --context context:primary-signature -vv "$out/ThousandRealms.dmg"
fi
hdiutil verify "$out/ThousandRealms.dmg" >/dev/null
ls -la "$out"
