#!/usr/bin/env python3
"""Writes game/assets/credits/THIRD_PARTY_NOTICES.txt, the notices every client
package carries (stage_client.sh copies it beside the game) and the Credits page
shows, and game/assets/credits/rust_crates.json.

    python tools/release/gen_notices.py [--godot <godot executable>]

Run it after a dependency, the engine, Terrain3D or game/assets/credits/credits.json
changes, and commit the result. It reads:

  * credits.json          who made what (kept by hand);
  * cargo metadata/tree   the Rust libraries compiled into the client extension,
                          with the licence files from each crate's own source;
  * the engine            its licence, component copyrights and licence texts
                          (tools/release/engine_notices.gd; without --godot the
                          engine section of the existing file is kept);
  * licence files in the repository (Terrain3D, Pretendard, Literata, KayKit, Kenney, launcher).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CREDITS = ROOT / "game/assets/credits"
OUT = CREDITS / "THIRD_PARTY_NOTICES.txt"
CRATES = CREDITS / "rust_crates.json"
RULE = "=" * 78
ENGINE_BEGIN = "[engine notices begin]"
ENGINE_END = "[engine notices end]"
GODOT_CPP_MIT = """MIT License

Copyright (c) 2017-present Godot Engine contributors.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE."""


def heading(title: str) -> str:
    return "\n%s\n%s\n%s\n\n" % (RULE, title, RULE)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n").strip()


def cargo(*args: str) -> str:
    exe = os.environ.get("CARGO") or "cargo"
    home_cargo = Path.home() / ".cargo/bin/cargo.exe"
    if exe == "cargo" and home_cargo.exists():
        exe = str(home_cargo)
    return subprocess.run([exe, *args], cwd=ROOT, capture_output=True, text=True, encoding="utf-8", check=True).stdout


def client_crates() -> list[dict]:
    """The crates linked into realm_client (normal dependencies), with their
    licence and source directory; the workspace's own crates are left out."""
    meta = json.loads(cargo("metadata", "--format-version", "1", "--locked"))
    workspace = set(meta["workspace_members"])
    tree = cargo("tree", "-p", "realm_client", "-e", "normal", "--prefix", "none", "--target", "all", "--locked", "-f", "{p}")
    wanted = set()
    for line in tree.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            wanted.add((parts[0], parts[1].lstrip("v")))
    out = []
    for pkg in meta["packages"]:
        if pkg["id"] in workspace or (pkg["name"], pkg["version"]) not in wanted:
            continue
        out.append({
            "name": pkg["name"], "version": pkg["version"],
            "licence": pkg.get("license") or "see licence file",
            "authors": [re.sub(r"\s*<[^>]*>", "", a) for a in pkg.get("authors", [])],
            "repository": pkg.get("repository") or "",
            "dir": str(Path(pkg["manifest_path"]).parent),
        })
    return sorted(out, key=lambda c: (c["name"], c["version"]))


LICENCE_FILE = re.compile(r"^(licen[cs]e|copying|notice|copyright)", re.I)


def crate_texts(crate: dict) -> dict[str, str]:
    """{file name: text} of a crate's licence files; of a dual MIT/Apache crate
    the MIT text is enough (the choice is the recipient's)."""
    folder = Path(crate["dir"])
    found = {}
    for path in sorted(folder.iterdir()) if folder.is_dir() else []:
        if path.is_file() and LICENCE_FILE.match(path.name):
            found[path.name] = read(path)
    spdx = crate["licence"].upper()
    if "MIT" in spdx and " OR " in spdx.replace("/", " OR "):
        mit = {k: v for k, v in found.items() if "MIT" in k.upper()}
        if mit:
            return mit
    return found


def rust_section(crates: list[dict]) -> str:
    out = [heading("Rust libraries in the game's client extension")]
    groups: dict[str, list[str]] = {}
    missing = []
    for crate in crates:
        label = "%s %s" % (crate["name"], crate["version"])
        out.append("%s  %s%s\n" % (label, crate["licence"], "  (c) " + ", ".join(crate["authors"]) if crate["authors"] else ""))
        texts = crate_texts(crate)
        if not texts:
            missing.append("%s (%s, source: %s)" % (label, crate["licence"], crate["repository"] or "crates.io"))
        for text in texts.values():
            groups.setdefault(text, []).append(label)
    out.append("\nLicence texts as the libraries ship them:\n")
    for text, users in sorted(groups.items(), key=lambda kv: kv[1][0]):
        out.append("\n--- %s\n\n%s\n" % (", ".join(users), text))
    if missing:
        out.append("\nThese packages carry no licence file; the licence is the one they declare. "
                   "Apache-2.0: https://www.apache.org/licenses/LICENSE-2.0  MPL-2.0: https://mozilla.org/MPL/2.0/\n%s\n"
                   % "\n".join(missing))
    return "".join(out)


def engine_section(godot: str | None) -> str:
    if godot:
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "engine.json"
            subprocess.run([str(Path(godot).resolve()), "--headless", "--path", str(ROOT / "game"), "--script",
                            str(ROOT / "tools/release/engine_notices.gd"), "--", str(target)],
                           check=True, capture_output=True, timeout=120)
            data = json.loads(target.read_text(encoding="utf-8"))
        out = [heading("Godot Engine %s" % data["version"]), data["license"].strip(), "\n"]
        out.append(heading("Third-party components of Godot Engine"))
        for part in data["copyright"]:
            out.append("%s\n" % part["name"])
            for piece in part["parts"]:
                for line in piece["copyright"]:
                    out.append("  (c) %s\n" % line)
                out.append("  License: %s\n" % piece["license"])
        out.append(heading("Licence texts used by Godot Engine's components"))
        for key, text in data["licenses"].items():
            out.append("--- %s\n\n%s\n\n" % (key, text.strip()))
        return "".join(out)
    if OUT.exists():
        old = OUT.read_text(encoding="utf-8")
        if ENGINE_BEGIN in old and ENGINE_END in old:
            return old.split(ENGINE_BEGIN, 1)[1].split(ENGINE_END, 1)[0].strip("\n") + "\n"
    sys.exit("gen_notices: no engine section yet; pass --godot <godot executable>")


def credits_section(credits: dict) -> str:
    out = [credits["ai_notice"], "\n"]
    for section in credits["sections"]:
        out.append(heading(section["title"]))
        for entry in section["entries"]:
            out.append(entry["name"] + ("  [%s]" % entry["licence"] if entry.get("licence") else "") + "\n")
            if entry.get("by"):
                out.append("  %s\n" % entry["by"])
            out.append("  %s\n" % entry["what"])
            if entry.get("url"):
                out.append("  %s\n" % entry["url"])
            if entry.get("licence_url"):
                out.append("  Licence: %s\n" % entry["licence_url"])
            out.append("\n")
    out.append(heading("NVIDIA SimReady packages used (CC BY 4.0, changed as described above)"))
    out.append(", ".join(credits["simready_packages"]) + "\n")
    return "".join(out)


def file_section(title: str, path: Path) -> str:
    return heading(title) + read(path) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", help="Godot executable, to refresh the engine's notices")
    args = parser.parse_args()
    credits = json.loads((CREDITS / "credits.json").read_text(encoding="utf-8"))
    crates = client_crates()
    CRATES.write_text(json.dumps([{k: c[k] for k in ("name", "version", "licence", "authors", "repository")} for c in crates],
                                 indent=1, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
    parts = ["Thousand Realms: third-party notices\n\nGenerated by tools/release/gen_notices.py. "
             "The same text is in the game under Settings > Credits.\n\n", credits_section(credits)]
    parts.append(file_section("Terrain3D (MIT)", ROOT / "game/addons/terrain_3d/LICENSE.txt"))
    parts.append(heading("godot-cpp (MIT), built into the Terrain3D library") + GODOT_CPP_MIT + "\n")
    parts.append(file_section("Pretendard (SIL Open Font License 1.1)", ROOT / "game/assets/fonts/OFL-Pretendard.txt"))
    parts.append(file_section("Literata (SIL Open Font License 1.1)", ROOT / "game/assets/fonts/OFL-Literata.txt"))
    parts.append(file_section("NVIDIA SimReady Assets", ROOT / "game/assets/models/feast/LICENSE.txt"))
    parts.append(file_section("KayKit", ROOT / "game/assets/models/KayKit-LICENSE.txt"))
    parts.append(file_section("Kenney Particle Pack", ROOT / "game/assets/vfx/Kenney-License.txt"))
    parts.append(rust_section(crates))
    launcher = ROOT / "launcher/THIRD_PARTY_NOTICES.txt"
    if launcher.exists():
        parts.append(file_section("The launcher", launcher))
    parts.append("\n%s\n%s%s\n" % (ENGINE_BEGIN, engine_section(args.godot), ENGINE_END))
    OUT.write_text("".join(parts), encoding="utf-8", newline="\n")
    print("gen_notices: %s, %.0f KB, %d Rust libraries" % (OUT.relative_to(ROOT), OUT.stat().st_size / 1024, len(crates)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
