#!/bin/bash
# Builds the Linux launcher packages inside the packaging/linux/Dockerfile image:
#   build_appimage.sh <launcher source dir> <launcher version> <out dir>
# Produces in <out dir>:
#   ThousandRealms_Launcher-x86_64.AppImage  also the self-update payload
#   ThousandRealms-linux-x86_64.tar.gz       folder with the launcher, keeps the execute bit
#   ThousandRealms_UpdaterCLI-linux          headless updater for the tests
#
# The AppImage needs no FUSE: its "runtime" is the launcher itself. The launcher
# is one self-contained program, so nothing has to be mounted; the ELF file only
# gets the AppImage marker (type 2, bytes 8-10) and the usual image with the
# desktop file and icon appended, which is what desktop tools read.
set -euo pipefail
src="$1"
version="$2"
out="$3"
build=/tmp/launcher-build
appdir=/tmp/AppDir
stage=/tmp/launcher-tar

rm -rf "$build" "$appdir" "$stage"
cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DREALM_LAUNCHER_VERSION="$version" -DFETCHCONTENT_SOURCE_DIR_SDL3=/opt/sdl3 >/dev/null
ninja -C "$build" ThousandRealms_Launcher ThousandRealms_UpdaterCLI >/dev/null

bin="$build/ThousandRealms_Launcher"
strip "$bin"
# glibc is the only dynamic dependency besides libdl/libm/libpthread/libc.
needed="$(objdump -p "$bin" | awk '/NEEDED/ {print $2}' | sort | tr '\n' ' ')"
echo "NEEDED: $needed"
for lib in $needed; do
    case "$lib" in
        libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|ld-linux-x86-64.so.2) ;;
        *) echo "unexpected dynamic dependency: $lib" >&2; exit 1 ;;
    esac
done
max_glibc="$(objdump -T "$bin" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"
echo "requires $max_glibc"

mkdir -p "$appdir/usr/bin" "$out"
cp "$bin" "$appdir/usr/bin/ThousandRealms_Launcher"
cp "$src/assets/thousand_realms_256.png" "$appdir/thousand-realms.png"
cp "$src/packaging/linux/thousand-realms.desktop" "$appdir/thousand-realms.desktop"
ln -s usr/bin/ThousandRealms_Launcher "$appdir/AppRun"
ln -s thousand-realms.png "$appdir/.DirIcon"
mksquashfs "$appdir" /tmp/appdir.squashfs -root-owned -noappend -comp gzip -no-progress -quiet

image="$out/ThousandRealms_Launcher-x86_64.AppImage"
elf_size="$(stat -c %s "$bin")"
cp "$bin" "$image"
printf 'AI\002' | dd of="$image" bs=1 seek=8 conv=notrunc status=none
cat /tmp/appdir.squashfs >> "$image"
chmod 755 "$image"
# The image must start exactly where the ELF file ends, and the file must run.
offset="$("$image" --appimage-offset)"
[ "$offset" = "$elf_size" ] || { echo "image offset $offset, ELF size $elf_size" >&2; exit 1; }
unsquashfs -q -o "$offset" -l "$image" | grep -q thousand-realms.desktop

folder="$stage/ThousandRealms"
mkdir -p "$folder"
cp "$image" "$folder/ThousandRealms_Launcher"
cp "$src/assets/thousand_realms_256.png" "$folder/thousand-realms.png"
cp "$src/packaging/linux/Thousand Realms.desktop" "$folder/Thousand Realms.desktop"
cp "$src/packaging/linux/README.txt" "$src/THIRD_PARTY_NOTICES.txt" "$folder/"
chmod 755 "$folder/ThousandRealms_Launcher" "$folder/Thousand Realms.desktop"
chmod 644 "$folder/thousand-realms.png" "$folder/README.txt" "$folder/THIRD_PARTY_NOTICES.txt"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@${version##*.}" -C "$stage" -cf - ThousandRealms \
    | gzip -9n > "$out/ThousandRealms-linux-x86_64.tar.gz"

cp "$build/ThousandRealms_UpdaterCLI" "$out/ThousandRealms_UpdaterCLI-linux"
ls -la "$out"
