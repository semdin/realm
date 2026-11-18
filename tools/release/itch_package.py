#!/usr/bin/env python3
"""Prepares the itch.io builds of the launcher and optionally pushes them.

One folder per channel, each with its .itch.toml. On itch.io the itch app
installs and updates the launcher (which switches its own self-update off under
ITCHIO_APP=1); the launcher stays the only updater of the game.

    itch_package.py --dist DIR --out DIR [--butler PATH --validate]
    itch_package.py --dist DIR --out DIR --butler PATH --push USER/GAME --userversion V

--dist holds ThousandRealms_Launcher.exe, ThousandRealms_Launcher-x86_64.AppImage
and ThousandRealms_Launcher-macos.zip. --push needs BUTLER_API_KEY in the
environment; nothing is uploaded without it.
"""

import argparse
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import zipfile

REPO = pathlib.Path(__file__).resolve().parents[2]
TEMPLATES = REPO / "launcher" / "packaging" / "itch"
NOTICES = REPO / "launcher" / "THIRD_PARTY_NOTICES.txt"
CHANNELS = ("windows-launcher", "linux-launcher", "macos-launcher")


def extract_app(archive: pathlib.Path, target: pathlib.Path) -> None:
    """Unpacks the macOS zip keeping the permission bits zipfile would drop."""
    with zipfile.ZipFile(archive) as zf:
        for info in zf.infolist():
            path = pathlib.Path(zf.extract(info, target))
            mode = info.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise SystemExit("unexpected symlink in %s: %s" % (archive, info.filename))
            if mode and not info.is_dir():
                path.chmod(stat.S_IMODE(mode))


def prepare(dist: pathlib.Path, out: pathlib.Path) -> None:
    for channel in CHANNELS:
        folder = out / channel
        shutil.rmtree(folder, ignore_errors=True)
        folder.mkdir(parents=True)
        shutil.copy(TEMPLATES / channel / ".itch.toml", folder / ".itch.toml")
    shutil.copy(dist / "ThousandRealms_Launcher.exe", out / "windows-launcher")
    shutil.copy(NOTICES, out / "windows-launcher")
    linux = out / "linux-launcher" / "ThousandRealms_Launcher"
    shutil.copy(dist / "ThousandRealms_Launcher-x86_64.AppImage", linux)
    linux.chmod(0o755)
    shutil.copy(NOTICES, out / "linux-launcher")
    extract_app(dist / "ThousandRealms_Launcher-macos.zip", out / "macos-launcher")
    binary = out / "macos-launcher" / "Thousand Realms Launcher.app" / "Contents" / "MacOS" / "ThousandRealms_Launcher"
    if not binary.is_file() or (os.name != "nt" and not os.access(binary, os.X_OK)):
        raise SystemExit("the macOS app did not unpack with an executable launcher")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dist", required=True, type=pathlib.Path)
    parser.add_argument("--out", required=True, type=pathlib.Path)
    parser.add_argument("--butler", default="butler")
    parser.add_argument("--validate", action="store_true", help="run butler validate on every folder")
    parser.add_argument("--push", default="", metavar="USER/GAME")
    parser.add_argument("--userversion", default="")
    args = parser.parse_args()

    prepare(args.dist, args.out)
    for channel in CHANNELS:
        folder = args.out / channel
        if args.validate or args.push:
            subprocess.check_call([args.butler, "validate", str(folder)])
        if args.push:
            if not os.environ.get("BUTLER_API_KEY"):
                raise SystemExit("--push needs BUTLER_API_KEY")
            command = [args.butler, "push", str(folder), "%s:%s" % (args.push, channel), "--if-changed"]
            if args.userversion:
                command += ["--userversion", args.userversion]
            # butler's permission fixing can invalidate a signed app; the
            # bundle already has the right bits.
            if channel == "macos-launcher":
                command.append("--fix-permissions=false")
            subprocess.check_call(command)
        print("[itch] %s ready: %s" % (channel, folder))
    return 0


if __name__ == "__main__":
    sys.exit(main())
