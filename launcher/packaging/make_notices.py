#!/usr/bin/env python3
"""Writes launcher/THIRD_PARTY_NOTICES.txt from the licence texts of what the
launcher ships. The result is committed, embedded in the executable (the
"Licenses" link) and placed beside the launcher in every package.

    make_notices.py <unpacked SDL3 source dir>

The SDL version is the one pinned in launcher/CMakeLists.txt.
"""

import pathlib
import re
import sys

LAUNCHER = pathlib.Path(__file__).resolve().parents[1]


def text(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n").strip()


def stb_license() -> str:
    source = text(LAUNCHER / "vendor/stb/stb_truetype.h")
    start = source.rindex("This software is available under 2 licenses")
    block = source[start:]
    return re.sub(r"\n-{20,}\s*\*/\s*$", "", block).strip()


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    sdl = pathlib.Path(argv[1])
    sun = ("Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.\n\n"
           "Developed at SunPro, a Sun Microsystems, Inc. business.\n"
           "Permission to use, copy, modify, and distribute this\n"
           "software is freely granted, provided that this notice\n"
           "is preserved.")
    sections = [
        ("Literata (fonts, all platforms)", text(LAUNCHER / "assets/OFL-Literata.txt")),
        ("ed25519 by Orson Peters (update signature checks, all platforms)",
         text(LAUNCHER / "vendor/ed25519/LICENSE")),
        ("libdeflate (update decompression, all platforms)", text(LAUNCHER / "vendor/libdeflate/COPYING")),
        ("stb_image, stb_image_write, stb_truetype (Linux and macOS window)", stb_license()),
        ("SDL 3 (Linux and macOS window)", text(sdl / "LICENSE.txt")),
        ("yuv2rgb, part of SDL 3 (Linux and macOS window)", text(sdl / "src/video/yuv2rgb/LICENSE")),
        ("fdlibm math functions, part of SDL 3 (Linux and macOS window)", sun),
    ]
    out = ["Thousand Realms Launcher: third-party notices", "",
           "The launcher contains the following third-party software and fonts.",
           "The Windows setup program is built with Inno Setup (https://jrsoftware.org/isinfo.php),",
           "copyright Jordan Russell and Martijn Laan.",
           "On Linux and macOS the launcher uses the system's libcurl (https://curl.se/) for downloads.",
           ""]
    for title, body in sections:
        out += ["=" * 78, title, "=" * 78, "", body, ""]
    (LAUNCHER / "THIRD_PARTY_NOTICES.txt").write_text("\n".join(out), encoding="utf-8", newline="\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
