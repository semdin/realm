#!/usr/bin/env python3
"""Builds the rods (the player's casting weapon): short carved shafts with a
wrapped grip, a metal cap and a crystal, one per weapon item.

    python tools/art/rod_art.py [rod ...]        every rod, or the named ones

Shares the mesh tools, material photographs and palettes of skiff_art.py. Output:
game/assets/models/props/wands/wand_<id>.gltf + .bin and its maps (the folder and
file names keep the items' saved ids). Built in metres along +Y with the grip at
the origin, then written in the prop's own units: HeroAppearance scales every
rod by WAND_SCALE and puts its muzzle on the RodTip node.
"""
import math
import sys

import numpy as np

import skiff_art as sk
from skiff_art import BAND, DARK, GLOW, METAL, RAIL, ROPE, WOOD, C, Mesh, curve

WAND_SCALE = 0.4
BUTT = -0.082
GRIP_TOP = 0.062
COLLAR = 0.168
TIP = 0.262

RODS = {
    "ashwood": dict(palette="ashwood", head="plain", gem=(0.021, 0.034), knots=2),
    "hawthorn": dict(palette="ashwood", head="plain", gem=(0.02, 0.032), thorns=9, knots=1,
                     trim=(C(24, 18, 14), C(70, 54, 42), C(116, 96, 78)),
                     rope=(C(120, 116, 104), C(190, 186, 172), C(236, 232, 222)),
                     metal=(C(44, 30, 20), C(120, 84, 52), C(186, 142, 96)),
                     glow=C(255, 196, 120)),
    "runebound": dict(palette="runebound", head="claw", gem=(0.022, 0.038), bands=(0.09, 0.128),
                      glow=C(96, 170, 255)),
    "silverthorn": dict(palette="silverthorn", head="thorn", gem=(0.02, 0.042), bands=(0.11,)),
    "emberwing": dict(palette="emberwing", head="flame", gem=(0.024, 0.04), bands=(0.1,)),
    "ithrel_replica": dict(palette="storm", head="block", gem=(0.024, 0.036), sides=4, bands=(0.085, 0.125),
                           glow=C(150, 210, 255)),
    "moonveil": dict(palette="moonveil", head="crescent", gem=(0.021, 0.046), bands=(0.115,)),
}


def lathe(m, stops, region, sides=8, uv_len=1.0):
    """A turned shape: (y, radius) stops."""
    ys = np.array([s[0] for s in stops], float)
    rs = np.array([s[1] for s in stops], float)
    m.tube(np.stack([np.zeros_like(ys), ys, np.zeros_like(ys)], 1), rs, region, sides=sides, uv_len=uv_len)


def around(count, phase=0.0):
    for i in range(count):
        a = phase + 2 * math.pi * i / count
        yield np.array([math.cos(a), 0.0, math.sin(a)])


def build_rod(r):
    m = Mesh()
    sides = r.get("sides", 8)
    # pommel
    lathe(m, [(BUTT, 0.004), (BUTT + 0.006, 0.019), (BUTT + 0.018, 0.021), (BUTT + 0.027, 0.0155)], METAL, sides=8, uv_len=0.3)
    # the wrapped grip
    grip = [(BUTT + 0.025, 0.0155)]
    for k, y in enumerate(np.linspace(BUTT + 0.03, GRIP_TOP, 13)):
        grip.append((float(y), 0.0165 if k % 2 else 0.0148))
    lathe(m, grip, ROPE, sides=7, uv_len=0.5)
    # the carved shaft: it swells toward the head, with cut rings
    stops = [(GRIP_TOP - 0.004, 0.0185), (GRIP_TOP + 0.006, 0.0205)]
    rings = r.get("knots", 3)
    for y in np.linspace(GRIP_TOP + 0.012, COLLAR - 0.006, 10):
        f = (y - GRIP_TOP) / (COLLAR - GRIP_TOP)
        radius = 0.0185 + 0.0065 * f + 0.0012 * math.sin(f * math.pi * (2 * rings + 1))
        stops.append((float(y), radius))
    lathe(m, stops, WOOD, sides=sides, uv_len=0.9)
    for y in r.get("bands", ()):
        f = (y - GRIP_TOP) / (COLLAR - GRIP_TOP)
        radius = 0.0205 + 0.0065 * f
        lathe(m, [(y - 0.006, radius), (y - 0.004, radius + 0.0022), (y + 0.004, radius + 0.0022), (y + 0.006, radius)], BAND, sides=sides, uv_len=0.2)
    for k, way in enumerate(around(r.get("thorns", 0), 0.4)):
        y = GRIP_TOP + 0.014 + (COLLAR - GRIP_TOP - 0.03) * ((k * 0.382) % 1.0)
        base = way * 0.018 + (0, y, 0)
        tip = way * 0.04 + (0, y + 0.012, 0)
        m.tube([base, (base + tip) / 2, tip], [0.0055, 0.0032, 0.0004], RAIL, sides=4, cap=False)
    # the metal cap the crystal sits in
    lathe(m, [(COLLAR - 0.008, 0.0235), (COLLAR - 0.002, 0.0295), (COLLAR + 0.008, 0.0275), (COLLAR + 0.02, 0.0215),
              (COLLAR + 0.03, 0.0255), (COLLAR + 0.034, 0.018)], METAL, sides=8, uv_len=0.5)
    gem_r, gem_h = r["gem"]
    gem_y = COLLAR + 0.034 + gem_h * 0.72
    m.gem((0, gem_y, 0), gem_r, gem_h, GLOW, sides=6)
    head = r["head"]
    y0 = COLLAR + 0.026
    if head in ("plain", "claw", "block"):
        count = 3 if head != "block" else 4
        reach = 1.25 if head != "plain" else 1.1
        for way in around(count, 0.5):
            path = curve([way * 0.021 + (0, y0, 0), way * (gem_r + 0.012) + (0, gem_y - gem_h * 0.2, 0),
                          way * (gem_r * 0.55) + (0, gem_y + gem_h * 0.42 * reach, 0)], 6)
            m.tube(path, np.linspace(0.0052, 0.0016, 6), METAL, sides=4, uv_len=0.3)
    elif head == "thorn":
        for way in around(5, 0.2):
            path = curve([way * 0.022 + (0, y0, 0), way * 0.036 + (0, gem_y - 0.008, 0), way * 0.024 + (0, gem_y + gem_h * 1.15, 0)], 6)
            m.tube(path, np.linspace(0.0062, 0.0006, 6), METAL, sides=4, squash=(1.0, 0.45), uv_len=0.3)
    elif head == "flame":
        for way, rise in zip(around(4, 0.8), (1.25, 0.9, 1.25, 0.9)):
            sideways = np.array([-way[2], 0.0, way[0]])
            path = curve([way * 0.022 + (0, y0, 0), way * 0.037 + sideways * 0.006 + (0, gem_y - 0.01, 0),
                          way * 0.016 + sideways * 0.014 + (0, gem_y + gem_h * rise, 0)], 7)
            m.tube(path, np.linspace(0.0068, 0.0005, 7), BAND, sides=4, squash=(1.0, 0.5), uv_len=0.3)
    elif head == "crescent":
        arc = [np.array([0.042 * math.sin(a), gem_y - 0.002 - 0.036 * math.cos(a), 0.0]) for a in np.linspace(-2.45, 2.45, 13)]
        widths = 0.0055 * np.sin(np.linspace(0.12, math.pi - 0.12, 13)) + 0.0008
        m.tube(arc, widths, BAND, sides=4, squash=(1.0, 0.55), uv_len=0.6)
    p, n, uv, tri = m.arrays()
    return (p / WAND_SCALE).astype(np.float32), n, uv, tri


def tip_y(r):
    return COLLAR + 0.034 + r["gem"][1] * 1.72 + 0.004


def build(name, src, seed):
    r = RODS[name]
    t = dict(sk.TIERS[r["palette"]])
    for key in ("trim", "rope", "metal", "glow"):
        if key in r:
            t[key] = r[key]
    t["glow_amt"] = max(t["glow_amt"], 2.6)
    stem = f"wand_{name}"
    atlas = sk.paint(t, src, seed)
    sk.write_maps(atlas, sk.OUT / stem, scale=0.5)
    parts = [("RodBody", build_rod(r), None)]
    sockets = {"RodTip": (0.0, tip_y(r) / WAND_SCALE, 0.0)}
    tris = sk.write_gltf(stem, parts, sockets, 3.4)
    sk.write_imports(stem)
    print(f"{stem}: {tris} triangles, muzzle {tip_y(r):.3f} m")


if __name__ == "__main__":
    wanted = sys.argv[1:] or list(RODS)
    sk.OUT = sk.REPO / "game" / "assets" / "models" / "props" / "wands"
    sk.OUT.mkdir(parents=True, exist_ok=True)
    sources = sk.load_sources()
    for number, name in enumerate(RODS):
        if name in wanted:
            build(name, sources, 300 + number)
