#!/usr/bin/env python3
"""Builds the windskiffs (the flying mounts): meshes, atlases and glTF files.

    python tools/art/skiff_art.py [tier ...]        every tier, or the named ones

Every skiff is one small open boat, written here as lofted sections, tubes and
plates, with one 1024 px atlas painted for it from four material photographs
(art/skiffs/src: wood, metal, canvas, reed; made with Seedream, kept out of the
repository). Output: game/assets/models/props/skiffs/skiff_<tier>.gltf + .bin
and its albedo, ORM, normal and emission maps.

Frame: +Z forward, +Y up, metres. The rider's hips sit on SeatSocket; the feet
go on FootL/RSocket and the hands on HandL/RSocket (BroomGripModifier). The two
wind vanes are their own nodes, hinged at their origin (BroomRig opens them).
"""
import json
import math
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

REPO = Path(__file__).resolve().parents[2]
SRC = REPO.parent / "art" / "skiffs" / "src"
OUT = REPO / "game" / "assets" / "models" / "props" / "skiffs"
SIZE = 1024

# atlas regions, pixels: x0, y0, x1, y1
HULL = (0, 0, 1024, 256)
DECK = (0, 256, 1024, 384)
WELL = (0, 384, 512, 512)
RAIL = (512, 384, 1024, 416)
BAND = (512, 416, 1024, 448)
ROPE = (512, 448, 1024, 480)
DARK = (512, 480, 1024, 512)
SAIL = (0, 512, 640, 832)
WOOD = (640, 512, 1024, 672)
METAL = (640, 672, 832, 832)
GLOW = (832, 672, 1024, 832)
FIN = (0, 832, 512, 1024)
CARVE = (512, 832, 1024, 1024)

SEAT = (0.0, 0.168, -0.32)
THWART_TOP = 0.05
FLOOR_Y = -0.35
COCKPIT = (-0.74, 0.44)
FOOT = (0.15, -0.235, 0.17)
HAND = (0.2, 0.3, 0.3)
HINGE = (0.27, 0.07, -0.62)

# ---------------------------------------------------------------- tiers
C = lambda r, g, b: np.array([r, g, b], float) / 255.0

TIERS = {
    "ashwood": dict(
        length=0.96, beam=0.31, bow=0.26, stern=0.15,
        hull=(C(84, 66, 48), C(178, 152, 120), C(232, 216, 188)),
        deck=(C(70, 56, 42), C(168, 146, 116), C(222, 206, 178)),
        trim=(C(48, 36, 26), C(122, 98, 72), C(176, 150, 118)),
        metal=(C(38, 36, 34), C(98, 92, 86), C(150, 144, 136)), metal_rough=0.62, metal_amt=0.75,
        rope=(C(70, 56, 36), C(160, 134, 92), C(214, 192, 148)),
        sail=(C(112, 98, 78), C(198, 184, 158), C(236, 226, 204)),
        strakes=5, patches=4, bands=[], rough=0.74,
        prow="post", stern_post="post", ribs=5, vane="square", vane_r=0.86, vane_arc=(-8, 90),
        glow=C(255, 158, 62), glow_amt=1.6, fins=0.75),
    "reed": dict(
        length=1.02, beam=0.3, bow=0.46, stern=0.34, reed=True,
        hull=(C(70, 60, 30), C(168, 150, 88), C(226, 208, 146)),
        deck=(C(64, 56, 30), C(150, 134, 80), C(214, 196, 136)),
        trim=(C(58, 46, 28), C(128, 106, 68), C(180, 156, 106)),
        metal=(C(50, 42, 30), C(112, 96, 70), C(160, 142, 108)), metal_rough=0.7, metal_amt=0.2,
        rope=(C(62, 44, 26), C(136, 102, 62), C(190, 156, 108)),
        sail=(C(92, 80, 44), C(176, 158, 100), C(222, 206, 150)), mat=True,
        strakes=1, patches=0, bands=[], rough=0.82,
        prow="reed", stern_post="reed", ribs=7, vane="fan", vane_r=0.82, vane_arc=(0, 92),
        glow=C(255, 176, 74), glow_amt=1.5, fins=0.5),
    "runebound": dict(
        length=1.0, beam=0.31, bow=0.3, stern=0.17,
        hull=(C(30, 18, 12), C(92, 58, 36), C(146, 100, 66)),
        deck=(C(44, 28, 18), C(116, 78, 50), C(166, 120, 84)),
        trim=(C(24, 15, 10), C(70, 44, 28), C(116, 78, 52)),
        metal=(C(70, 44, 16), C(176, 128, 58), C(240, 202, 122)), metal_rough=0.38, metal_amt=1.0,
        rope=(C(46, 34, 26), C(110, 86, 64), C(160, 134, 104)),
        sail=(C(20, 38, 58), C(44, 84, 120), C(112, 156, 184)), hem=C(214, 170, 92),
        strakes=6, patches=0, bands=[0.2, 0.36, 0.64, 0.8], rough=0.5,
        prow="scroll", stern_post="post", ribs=5, vane="lateen", vane_r=0.98, vane_arc=(-6, 90),
        glow=C(255, 170, 70), glow_amt=2.2, fins=0.9),
    "silverthorn": dict(
        length=1.08, beam=0.27, bow=0.16, stern=0.1,
        hull=(C(10, 11, 14), C(34, 36, 42), C(84, 88, 98)),
        deck=(C(14, 15, 18), C(44, 46, 52), C(92, 96, 104)),
        trim=(C(8, 8, 10), C(26, 27, 31), C(62, 64, 72)),
        metal=(C(92, 98, 108), C(182, 190, 200), C(244, 248, 252)), metal_rough=0.26, metal_amt=1.0,
        rope=(C(24, 26, 30), C(66, 72, 80), C(116, 124, 134)),
        sail=(C(10, 26, 26), C(24, 62, 58), C(70, 124, 112)), hem=C(206, 216, 224),
        strakes=4, patches=0, bands=[0.3, 0.72], rough=0.3, lacquer=True,
        prow="blade", stern_post="blade", ribs=4, vane="swept", vane_r=1.04, vane_arc=(-12, 58),
        glow=C(150, 255, 214), glow_amt=2.4, fins=1.35),
    "emberwing": dict(
        length=1.04, beam=0.32, bow=0.34, stern=0.24,
        hull=(C(40, 6, 6), C(128, 22, 16), C(196, 66, 36)),
        deck=(C(36, 14, 10), C(96, 42, 26), C(150, 84, 50)),
        trim=(C(26, 6, 6), C(84, 16, 12), C(142, 46, 28)),
        metal=(C(96, 58, 12), C(214, 158, 56), C(255, 226, 140)), metal_rough=0.3, metal_amt=1.0,
        rope=(C(70, 24, 14), C(150, 62, 30), C(206, 118, 60)),
        sail=(C(70, 10, 8), C(176, 40, 18), C(246, 128, 40)), hem=C(255, 190, 80), sail_fade=C(255, 150, 40),
        strakes=6, patches=0, bands=[0.24, 0.76], rough=0.34, lacquer=True, veins=True,
        prow="crest", stern_post="crest", ribs=7, vane="fan", vane_r=1.02, vane_arc=(-10, 92),
        glow=C(255, 104, 28), glow_amt=3.4, fins=1.1),
    "storm": dict(
        length=1.06, beam=0.33, bow=0.2, stern=0.12,
        hull=(C(22, 26, 30), C(66, 72, 78), C(120, 126, 130)),
        deck=(C(30, 30, 30), C(84, 80, 74), C(134, 128, 118)),
        trim=(C(16, 18, 20), C(44, 48, 52), C(84, 88, 92)),
        metal=(C(30, 36, 44), C(92, 104, 118), C(176, 190, 206)), metal_rough=0.42, metal_amt=1.0,
        rope=(C(26, 28, 30), C(70, 72, 74), C(120, 122, 122)),
        sail=(C(20, 26, 36), C(52, 64, 82), C(112, 128, 148)), hem=C(150, 196, 240),
        strakes=4, patches=0, bands=[0.14, 0.3, 0.46, 0.62, 0.78], rough=0.5, plates=True,
        prow="ram", stern_post="blade", ribs=6, vane="tatter", vane_r=1.0, vane_arc=(-12, 90),
        glow=C(120, 196, 255), glow_amt=3.0, fins=1.25),
    "moonveil": dict(
        length=1.1, beam=0.29, bow=0.42, stern=0.3,
        hull=(C(92, 100, 118), C(186, 194, 208), C(240, 243, 248)),
        deck=(C(104, 110, 124), C(194, 198, 208), C(242, 244, 248)),
        trim=(C(70, 78, 98), C(150, 160, 182), C(216, 222, 234)),
        metal=(C(110, 122, 150), C(198, 210, 232), C(250, 252, 255)), metal_rough=0.22, metal_amt=1.0,
        rope=(C(96, 108, 136), C(172, 184, 208), C(232, 238, 248)),
        sail=(C(112, 136, 176), C(182, 204, 232), C(240, 246, 255)), hem=C(226, 238, 255), sail_fade=C(168, 206, 255),
        strakes=7, patches=0, bands=[0.5], rough=0.28, lacquer=True, veins=True,
        prow="crescent", stern_post="crescent", ribs=6, vane="crescent", vane_r=1.02, vane_arc=(-10, 90),
        glow=C(170, 214, 255), glow_amt=3.2, fins=1.0),
}
ITEM_OF = {"ashwood": "broom_ashwood", "reed": "broom_windcutter_2000", "runebound": "broom_runebound",
           "silverthorn": "broom_silverthorn", "emberwing": "broom_emberwing", "storm": "broom_skysplitter",
           "moonveil": "broom_moonveil"}


# ---------------------------------------------------------------- mesh
def norm(v):
    v = np.asarray(v, float)
    length = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.maximum(length, 1e-9)


class Mesh:
    def __init__(self):
        self.p, self.n, self.uv, self.tri = [], [], [], []
        self.count = 0

    def _add(self, p, n, uv, tri):
        self.p.append(p); self.n.append(n); self.uv.append(uv)
        self.tri.append(tri + self.count)
        self.count += len(p)

    def grid(self, P, UV, region, facing=None, center=None, wrap=False):
        """A quad grid. `facing` (a direction) or `center` (a point it faces away from) sets the side."""
        P = np.asarray(P, float); UV = np.asarray(UV, float)
        ni, nj = P.shape[:2]
        idx = np.arange(ni * nj).reshape(ni, nj)
        quads = []
        for i in range(ni - 1):
            for j in range(nj - (0 if wrap else 1)):
                k = (j + 1) % nj
                quads.append((idx[i, j], idx[i + 1, j], idx[i + 1, k], idx[i, k]))
        q = np.array(quads)
        flat = P.reshape(-1, 3)
        tri = np.concatenate([q[:, [0, 1, 2]], q[:, [0, 2, 3]]])
        tri = self._orient(flat, tri, facing, center)
        self._finish(flat, tri, UV.reshape(-1, 2), region)

    @staticmethod
    def _orient(flat, tri, facing, center):
        a, b, c = flat[tri[:, 0]], flat[tri[:, 1]], flat[tri[:, 2]]
        fn = np.cross(b - a, c - a)
        if facing is not None:
            score = (fn @ np.asarray(facing, float)).sum()
        else:
            mid = (a + b + c) / 3 - np.asarray(center, float)
            score = (fn * mid).sum()
        return tri[:, [0, 2, 1]] if score < 0 else tri

    def _finish(self, flat, tri, uv, region):
        a, b, c = flat[tri[:, 0]], flat[tri[:, 1]], flat[tri[:, 2]]
        fn = np.cross(b - a, c - a)
        keep = np.linalg.norm(fn, axis=1) > 1e-9
        tri, fn = tri[keep], fn[keep]
        n = np.zeros_like(flat)
        for k in range(3):
            np.add.at(n, tri[:, k], fn)
        # coincident points (a pointed end, a seam) share one normal
        keys = np.round(flat * 2000).astype(np.int64)
        _, inverse = np.unique(keys, axis=0, return_inverse=True)
        inverse = inverse.reshape(-1)
        total = np.zeros((inverse.max() + 1, 3))
        np.add.at(total, inverse, n)
        n = norm(total[inverse])
        x0, y0, x1, y1 = region
        out = np.stack([(x0 + 0.5 + uv[:, 0] * (x1 - x0 - 1)) / SIZE, (y0 + 0.5 + uv[:, 1] * (y1 - y0 - 1)) / SIZE], 1)
        self._add(flat, n, out, tri)

    def tube(self, path, radius, region, sides=6, squash=(1.0, 1.0), cap=True, uv_len=1.0):
        path = np.asarray(path, float)
        count = len(path)
        r = np.broadcast_to(np.asarray(radius, float), (count,))
        tangent = norm(np.gradient(path, axis=0))
        ref = np.array([1.0, 0.0, 0.0])
        if abs(tangent[0] @ ref) > 0.9:
            ref = np.array([0.0, 1.0, 0.0])
        side = norm(np.cross(tangent[0], ref))
        rings = np.zeros((count, sides, 3)); uv = np.zeros((count, sides, 2))
        for i in range(count):
            side = norm(side - tangent[i] * (side @ tangent[i]))
            other = np.cross(tangent[i], side)
            for j in range(sides):
                a = 2 * math.pi * j / sides
                rings[i, j] = path[i] + r[i] * (math.cos(a) * side * squash[0] + math.sin(a) * other * squash[1])
                uv[i, j] = (i / max(1, count - 1) * uv_len % 1.0001, abs(j / sides * 2 - 1))
        flat = rings.reshape(-1, 3)
        idx = np.arange(count * sides).reshape(count, sides)
        q = []
        for i in range(count - 1):
            for j in range(sides):
                k = (j + 1) % sides
                q.append((idx[i, j], idx[i + 1, j], idx[i + 1, k], idx[i, k]))
        q = np.array(q)
        tri = np.concatenate([q[:, [0, 1, 2]], q[:, [0, 2, 3]]])
        tri = self._orient_tube(flat, tri, path, count, sides)
        uvs = uv.reshape(-1, 2)
        if cap:
            extra = []
            first = len(flat)
            flat = np.vstack([flat, path[0], path[-1]])
            uvs = np.vstack([uvs, [[0, 0.5]], [[min(uv_len, 1.0), 0.5]]])
            for j in range(sides):
                k = (j + 1) % sides
                extra.append((first, idx[0, k], idx[0, j]))
                extra.append((first + 1, idx[-1, j], idx[-1, k]))
            extra = np.array(extra)
            a, b, c = flat[extra[:, 0]], flat[extra[:, 1]], flat[extra[:, 2]]
            if (np.cross(b - a, c - a)[0] @ (a[0] - path[1])) < 0:
                extra = extra[:, [0, 2, 1]]
            tri = np.vstack([tri, extra])
        self._finish(flat, tri, uvs, region)

    @staticmethod
    def _orient_tube(flat, tri, path, count, sides):
        a, b, c = flat[tri[0, 0]], flat[tri[0, 1]], flat[tri[0, 2]]
        centre = path[0] * 0.5 + path[min(1, count - 1)] * 0.5
        if np.cross(b - a, c - a) @ ((a + b + c) / 3 - centre) < 0:
            return tri[:, [0, 2, 1]]
        return tri

    def plate(self, outline, origin, ex, ey, thick, region):
        """A flat plate: `outline` (u, v metres) in the plane origin + u ex + v ey."""
        o = np.asarray(outline, float); origin = np.asarray(origin, float)
        ex = np.asarray(ex, float); ey = np.asarray(ey, float)
        nz = norm(np.cross(ex, ey))
        mn, mx = o.min(0), o.max(0)
        uv = (o - mn) / np.maximum(mx - mn, 1e-6)
        centre = o.mean(0)
        pts = lambda off: origin + o[:, :1] * ex + o[:, 1:] * ey + nz * off
        mid = lambda off: origin + centre[0] * ex + centre[1] * ey + nz * off
        cuv = (centre - mn) / np.maximum(mx - mn, 1e-6)
        n = len(o)
        for sign in (1, -1):
            P = np.vstack([pts(sign * thick), mid(sign * thick)])
            UV = np.vstack([uv, cuv])
            tri = np.array([(n, i, (i + 1) % n) for i in range(n)])
            tri = self._orient(P, tri, nz * sign, None)
            self._flat(P, UV, tri, nz * sign, region)
        ring = np.stack([pts(thick), pts(-thick)])
        ring = np.concatenate([ring, ring[:, :1]], 1)
        ruv = np.stack([np.r_[uv[:, 0], uv[0, 0]], np.r_[uv[:, 1], uv[0, 1]]], 1)
        self.grid(ring, np.stack([ruv, ruv]), region, center=origin + centre[0] * ex + centre[1] * ey)

    def _flat(self, P, UV, tri, normal, region):
        x0, y0, x1, y1 = region
        out = np.stack([(x0 + 0.5 + UV[:, 0] * (x1 - x0 - 1)) / SIZE, (y0 + 0.5 + UV[:, 1] * (y1 - y0 - 1)) / SIZE], 1)
        self._add(P, np.tile(normal, (len(P), 1)), out, tri)

    def box(self, lo, hi, region):
        lo = np.asarray(lo, float); hi = np.asarray(hi, float)
        mid = (lo + hi) / 2
        for axis in range(3):
            for sign in (-1, 1):
                a, b = [(axis + 1) % 3, (axis + 2) % 3]
                c = np.array([[0, 0], [1, 0], [1, 1], [0, 1]], float)
                P = np.zeros((4, 3))
                P[:, axis] = hi[axis] if sign > 0 else lo[axis]
                P[:, a] = lo[a] + c[:, 0] * (hi[a] - lo[a])
                P[:, b] = lo[b] + c[:, 1] * (hi[b] - lo[b])
                n = np.zeros(3); n[axis] = sign
                tri = self._orient(P, np.array([(0, 1, 2), (0, 2, 3)]), n, None)
                self._flat(P, c if (hi[a] - lo[a]) >= (hi[b] - lo[b]) else c[:, ::-1], tri, n, region)

    def gem(self, centre, radius, height, region, sides=6):
        centre = np.asarray(centre, float)
        ring = [centre + radius * np.array([math.cos(a), 0, math.sin(a)]) for a in np.linspace(0, 2 * math.pi, sides, endpoint=False)]
        top = centre + [0, height, 0]; bottom = centre - [0, height, 0]
        for j in range(sides):
            a, b = ring[j], ring[(j + 1) % sides]
            for tip in (top, bottom):
                P = np.array([tip, a, b]); n = norm(np.cross(P[1] - P[0], P[2] - P[0]))
                if n @ ((P.sum(0) / 3) - centre) < 0:
                    n = -n
                tri = self._orient(P, np.array([(0, 1, 2)]), n, None)
                self._flat(P, np.array([[0.5, 0.1], [0.1, 0.9], [0.9, 0.9]]), tri, n, region)

    def arrays(self):
        return (np.vstack(self.p).astype(np.float32), np.vstack(self.n).astype(np.float32),
                np.vstack(self.uv).astype(np.float32), np.vstack(self.tri).astype(np.uint32))


def curve(points, count):
    """Catmull-Rom through `points`."""
    pts = np.asarray(points, float)
    pts = np.vstack([2 * pts[0] - pts[1], pts, 2 * pts[-1] - pts[-2]])
    out = []
    spans = len(pts) - 3
    for t in np.linspace(0, spans - 1e-6, count):
        i = int(t); f = t - i
        a, b, c, d = pts[i:i + 4]
        out.append(0.5 * (2 * b + (c - a) * f + (2 * a - 5 * b + 4 * c - d) * f * f + (3 * b - a - 3 * c + d) * f ** 3))
    return np.array(out)


# ---------------------------------------------------------------- the boat
class Hull:
    def __init__(self, t):
        self.t = t
        self.zs = -1.42 * t["length"]
        self.zb = 1.46 * t["length"]
        self.b = t["beam"]

    def s(self, z):
        return (z - self.zs) / (self.zb - self.zs)

    def half(self, z):
        s = np.clip(self.s(z), 0, 1)
        return self.b * np.sin(math.pi * s ** 0.86) ** 0.72

    def sheer(self, z):
        s = np.clip(self.s(z), 0, 1)
        fore = np.clip((s - 0.56) / 0.44, 0, 1)
        aft = np.clip((0.36 - s) / 0.36, 0, 1)
        return 0.035 + self.t["bow"] * fore ** 2.2 + self.t["stern"] * aft ** 2.2

    def keel(self, z):
        s = np.clip(self.s(z), 0, 1)
        return -0.45 + (self.sheer(z) + 0.45 - 0.015) * np.abs(2 * s - 1) ** 3.1

    def section(self, z, t):
        """Outer skin; t in -1..1, keel at 0."""
        a = np.abs(t) * math.pi / 2
        x = self.half(z) * np.sin(a) ** 0.72 * np.sign(t)
        k = self.keel(z)
        y = k + (self.sheer(z) - k) * (1 - np.cos(a)) ** 0.82
        return x, y

    def well(self, z):
        u = np.clip((z - COCKPIT[0]) / (COCKPIT[1] - COCKPIT[0]), 0, 1)
        inside = (z > COCKPIT[0]) & (z < COCKPIT[1])
        return np.where(inside, np.minimum(self.half(z) - 0.045, 0.27) * np.maximum(1 - np.abs(2 * u - 1) ** 4.0, 0) ** 0.5, 0.0)


def yoke_at(x):
    """The helm bar's centre line: it sweeps up and forward toward its ends."""
    hx, hy, hz = HAND
    return (x, hy + 0.05 * (x / (hx + 0.055)) ** 2, hz + 0.03 * (x / hx) ** 2)


def stations(h, count):
    zz = np.linspace(h.zs, h.zb, count)
    return np.unique(np.concatenate([zz, np.linspace(COCKPIT[0], COCKPIT[1], 13)]))


def build_hull(t):
    h = Hull(t)
    m = Mesh()
    zz = stations(h, 26)
    u = (zz - h.zs) / (h.zb - h.zs)
    # outer skin
    tt = np.linspace(-1, 1, 15)
    P = np.zeros((len(zz), len(tt), 3)); UV = np.zeros_like(P[..., :2])
    for i, z in enumerate(zz):
        x, y = h.section(z, tt)
        P[i, :, 0] = x; P[i, :, 1] = y; P[i, :, 2] = z
        UV[i, :, 0] = u[i]; UV[i, :, 1] = 1 - np.abs(tt)
    m.grid(P, UV, HULL, center=(0, 0.2, 0))
    # deck, both sides of the cockpit
    rows = np.linspace(0, 1, 4)
    for sign in (1, -1):
        D = np.zeros((len(zz), len(rows), 3)); DU = np.zeros_like(D[..., :2])
        for i, z in enumerate(zz):
            hb = float(h.half(z)); w = float(h.well(z)); sh = float(h.sheer(z))
            x = w + (hb - w) * rows
            crown = 0.03 * (1 - (x / max(hb, 1e-3)) ** 2) * min(1.0, hb / 0.12)
            D[i, :, 0] = sign * x; D[i, :, 1] = sh + crown; D[i, :, 2] = z
            DU[i, :, 0] = u[i]; DU[i, :, 1] = x / h.b
        m.grid(D, DU, DECK, facing=(0, 1, 0))
    # the well
    wz = zz[(zz >= COCKPIT[0]) & (zz <= COCKPIT[1])]
    tw = np.linspace(-1, 1, 11)
    W = np.zeros((len(wz), len(tw), 3)); WU = np.zeros_like(W[..., :2])
    for i, z in enumerate(wz):
        w = float(h.well(z)); hb = max(float(h.half(z)), 1e-3); sh = float(h.sheer(z))
        top = sh + 0.03 * (1 - (w / hb) ** 2)
        a = np.abs(tw) * math.pi / 2
        W[i, :, 0] = w * np.sin(a) ** 0.62 * np.sign(tw)
        W[i, :, 1] = FLOOR_Y + (top - FLOOR_Y) * (1 - np.cos(a)) ** 0.9
        W[i, :, 2] = z
        WU[i, :, 0] = (z - COCKPIT[0]) / (COCKPIT[1] - COCKPIT[0]); WU[i, :, 1] = np.abs(tw)
    m.grid(W, WU, WELL, facing=(0, 1, 0))
    # coaming round the well
    ring_z = np.r_[np.linspace(COCKPIT[0] + 1e-3, COCKPIT[1] - 1e-3, 15)]
    def lip(z, side):
        w = float(h.well(z)); hb = max(float(h.half(z)), 1e-3)
        return (side * w, float(h.sheer(z)) + 0.03 * (1 - (w / hb) ** 2) + 0.012, z)
    path = [lip(z, 1) for z in ring_z] + [lip(z, -1) for z in ring_z[::-1][1:]]
    path.append(path[0])
    m.tube(path, 0.017, DARK, sides=4, cap=False, uv_len=3.0)
    # rails along the sheer
    rz = np.linspace(h.zs + 0.03, h.zb - 0.03, 22)
    for sign in (1, -1):
        rail = [(sign * float(h.half(z)), float(h.sheer(z)) + 0.008, z) for z in rz]
        m.tube(rail, 0.019, RAIL, sides=4, uv_len=1.0)
    # thwart, floor slats
    w = float(h.well(np.array(SEAT[2]))) + 0.01
    m.box((-w, THWART_TOP - 0.035, SEAT[2] - 0.13), (w, THWART_TOP, SEAT[2] + 0.11), WOOD)
    for sign in (1, -1):
        m.box((sign * 0.15 - 0.02, FLOOR_Y, SEAT[2] - 0.02), (sign * 0.15 + 0.02, THWART_TOP - 0.03, SEAT[2] + 0.02), DARK)
    # the helm: post and yoke
    hx, hy, hz = HAND
    post = curve([(0, float(h.sheer(np.array(0.58))) + 0.02, 0.58), (0, hy - 0.12, hz + 0.11), (0, hy, hz)], 7)
    m.tube(post, np.linspace(0.034, 0.024, 7), WOOD, sides=6, uv_len=0.6)
    xs = np.linspace(-hx - 0.055, hx + 0.055, 13)
    yoke = np.array([yoke_at(x) for x in xs])
    m.tube(yoke, 0.021, RAIL, sides=6, uv_len=0.4)
    for sign in (1, -1):
        hand_at = np.array(yoke[np.argmin(np.abs(xs - sign * hx))])
        grip = curve([hand_at + (sign * d, 0, 0) for d in (-0.06, 0.0, 0.06)], 4)
        m.tube(grip, 0.027, ROPE, sides=6, uv_len=0.25)
        m.tube([yoke[0 if sign < 0 else -1] + (sign * 0.004, 0, 0), yoke[0 if sign < 0 else -1] + (sign * 0.03, 0, 0)], 0.03, METAL, sides=6)
    m.tube([(0, hy - 0.035, hz + 0.01), (0, hy + 0.035, hz + 0.0)], 0.037, METAL, sides=6)
    # keel timber, fin, rudder
    kz = np.linspace(h.zs + 0.04, h.zb - 0.04, 18)
    m.tube([(0, float(h.keel(z)) - 0.004, z) for z in kz], 0.018, DARK, sides=4, squash=(0.8, 1.2), uv_len=1.0)
    scale = t["fins"]
    fin_y = float(h.keel(np.array(-0.3)))
    m.plate([(-0.42, 0.03), (0.34, 0.03), (0.1, -0.11 * scale), (-0.28, -0.2 * scale), (-0.5, -0.16 * scale)],
            (0, fin_y, -0.3), (0, 0, 1), (0, 1, 0), 0.008, FIN)
    rz0 = h.zs + 0.09
    ry = float(h.keel(np.array(rz0)))
    m.plate([(0.03, 0.16), (0.03, -0.22 * scale), (-0.1, -0.28 * scale), (-0.2 * scale, -0.08), (-0.1, 0.1)],
            (0, ry, rz0), (0, 0, 1), (0, 1, 0), 0.008, FIN)
    # small running fins low on the sides, swept back
    for sign in (1, -1):
        z0 = 0.5
        x0, y0 = h.section(np.array(z0), np.array(sign * 0.45))
        ex = norm((sign * 0.82, -0.2, -0.54)); ey = norm((0, 0.15, 1.0))
        m.plate([(-0.01, -0.14), (-0.01, 0.13), (0.26 * scale, -0.12), (0.34 * scale, -0.26)],
                (float(x0) - sign * 0.01, float(y0), z0), ex, ey, 0.007, FIN)
    # wind-stone in its cradle under the keel
    gy = float(h.keel(np.array(0.02))) - 0.05
    m.gem((0, gy - 0.02, 0.02), 0.055, 0.085, GLOW, sides=6)
    arc = [(0.075 * math.sin(a), gy + 0.05 - 0.075 * math.cos(a) * 0.9 + 0.01, 0.02) for a in np.linspace(-1.9, 1.9, 9)]
    m.tube(arc, 0.009, METAL, sides=4, uv_len=0.5)
    prow(m, h, t["prow"], 1, t)
    prow(m, h, t["stern_post"], -1, t)
    hinge_mounts(m, h)
    return m, h


def hinge_mounts(m, h):
    for sign in (1, -1):
        hx, hy, hz = HINGE
        z = np.array(hz)
        edge = (sign * float(h.half(z)), float(h.sheer(z)) + 0.01, hz)
        tip = (sign * hx * 1.0, hy, hz) if abs(hx) > float(h.half(z)) else (sign * (float(h.half(z)) + 0.02), float(h.sheer(z)) + 0.05, hz)
        m.tube([edge, tip], 0.024, METAL, sides=6)


def prow(m, h, kind, end, t):
    z0 = (h.zb - 0.05) if end > 0 else (h.zs + 0.05)
    y0 = float(h.sheer(np.array(z0)))
    p0 = np.array([0, y0 - 0.05, z0])
    forward = np.array([0, 0, float(end)])
    up = np.array([0, 1.0, 0])
    def at(f, u):
        return p0 + forward * f + up * u
    if kind == "post":
        path = curve([at(-0.1, -0.12), at(0.02, 0.05), at(0.07, 0.2), at(0.06, 0.32)], 9)
        m.tube(path, np.linspace(0.04, 0.026, 9), WOOD, sides=6, uv_len=0.6)
        m.tube(curve([at(0.058, 0.2), at(0.066, 0.25)], 3), 0.034, ROPE, sides=6, uv_len=0.2)
        m.tube(curve([at(0.06, 0.315), at(0.058, 0.345)], 2), 0.034, METAL, sides=6)
    elif kind == "reed":
        path = curve([at(-0.34, -0.1), at(-0.1, 0.02), at(0.08, 0.2), at(0.1, 0.4), at(-0.02, 0.52), at(-0.1, 0.48)], 16)
        m.tube(path, np.interp(np.linspace(0, 1, 16), [0, 0.3, 0.8, 1], [0.1, 0.075, 0.042, 0.018]), DECK, sides=7, uv_len=0.7)
        for f in (0.14, 0.3, 0.46, 0.62):
            i = int(f * 15)
            m.tube(path[i:i + 2], 0.086 - f * 0.06, ROPE, sides=7, uv_len=0.1)
    elif kind == "scroll":
        a = np.linspace(0, 4.4, 15)
        r = 0.13 * np.exp(-a * 0.2)
        cx, cy = 0.1, 0.27
        spiral = [at(cx + r_i * math.sin(x + 3.5), cy + r_i * math.cos(x + 3.5)) for x, r_i in zip(a, r)]
        path = np.vstack([curve([at(-0.1, -0.1), at(0.02, 0.06)], 3), spiral])
        m.tube(path, np.linspace(0.042, 0.016, len(path)), WOOD, sides=6, uv_len=0.8)
        m.tube(curve([at(0.0, 0.03), at(0.03, 0.09)], 3), 0.05, BAND, sides=6, uv_len=0.3)
    elif kind == "blade":
        path = curve([at(-0.2, -0.06), at(0.08, 0.0), at(0.24, 0.07), at(0.36, 0.17)], 10)
        m.tube(path, np.linspace(0.06, 0.012, 10), METAL, sides=4, squash=(0.3, 1.0), uv_len=1.0)
        m.tube(curve([at(-0.06, -0.03), at(0.03, 0.0)], 3), 0.05, BAND, sides=6, uv_len=0.2)
    elif kind == "crest":
        for spread, rise in ((0.0, 0.48), (0.09, 0.36), (-0.09, 0.36)):
            base = at(-0.02, 0.0)
            tip = at(0.14 - abs(spread), rise) + np.array([spread * 1.3, 0, 0])
            mid = at(0.1, rise * 0.55) + np.array([spread * 0.6, 0, 0])
            path = curve([base, mid, tip], 8)
            m.tube(path, np.linspace(0.04, 0.003, 8), METAL if spread == 0 else RAIL, sides=4, squash=(0.42, 1.0))
        m.tube(curve([at(-0.12, -0.08), at(0.02, 0.02)], 3), 0.05, BAND, sides=6, uv_len=0.2)
    elif kind == "ram":
        path = curve([at(-0.26, -0.26), at(0.04, -0.15), at(0.22, -0.11), at(0.38, -0.07)], 9)
        m.tube(path, np.linspace(0.08, 0.018, 9), METAL, sides=5, squash=(0.6, 1.0))
        horn = curve([at(-0.02, -0.02), at(0.1, 0.14), at(0.12, 0.34)], 8)
        m.tube(horn, np.linspace(0.05, 0.005, 8), METAL, sides=5)
    elif kind == "crescent":
        back = curve([at(-0.1, -0.08), at(0.08, 0.1), at(0.2, 0.3), at(0.14, 0.52), at(-0.02, 0.64)], 14)
        m.tube(back, np.interp(np.linspace(0, 1, 14), [0, 0.4, 1], [0.045, 0.036, 0.003]), RAIL, sides=5, squash=(0.5, 1.0))
        m.gem(tuple(at(0.205, 0.31)), 0.042, 0.085, GLOW, sides=6)


def build_vane(t, sign):
    """One vane in hinge space: ribs fanning out of the hinge with cloth between."""
    m = Mesh()
    n = t["ribs"]
    a0, a1 = [math.radians(a) for a in t["vane_arc"]]
    R = t["vane_r"]
    e1 = norm((1.0, 0.06, -0.62)); e2 = norm((0.2, 1.0, -0.1))
    e2 = norm(e2 - e1 * (e2 @ e1))
    normal = np.cross(e1, e2)
    kind = t["vane"]
    rng = np.random.default_rng(11)
    jag = rng.uniform(0.87, 1.0, 40)

    def radius(f):
        if kind == "square":
            return R * (0.86 + 0.2 * math.sin(math.pi * f))
        if kind == "lateen":
            return R * (0.62 + 0.52 * f ** 1.2)
        if kind == "swept":
            return R * (1.16 - 0.34 * f)
        if kind == "crescent":
            return R * (0.74 + 0.34 * math.sin(math.pi * f) ** 0.7)
        return R * (0.92 + 0.1 * math.sin(math.pi * f))

    def point(f, rho, across=0.0):
        a = a0 + (a1 - a0) * f
        d = math.cos(a) * e1 + math.sin(a) * e2
        return d * rho + normal * across

    across, along = 5, 4
    scallop = {"tatter": 0.05, "fan": 0.035, "crescent": 0.02}.get(kind, 0.02)
    hub = 0.09
    for g in range(n - 1):
        P = np.zeros((along + 1, across, 3)); UV = np.zeros((along + 1, across, 2))
        for i in range(along + 1):
            v = i / along
            for j in range(across):
                w = j / (across - 1)
                f = (g + w) / (n - 1)
                edge = radius(f) * (1 - scallop * math.sin(math.pi * w))
                if kind == "tatter" and i == along:
                    edge *= jag[(g * (across - 1) + j) % 40]
                rho = hub + (edge - hub) * v
                billow = 0.035 * R * math.sin(math.pi * w) * math.sin(math.pi * min(1, v * 1.05))
                P[i, j] = point(f, rho, billow)
                UV[i, j] = (f, v)
        m.grid(P, UV, SAIL, facing=normal)
        m.grid(P - normal * 0.002, UV, SAIL, facing=-normal)
    for k in range(n):
        f = k / (n - 1)
        tip = radius(f) * 1.02
        path = [point(f, r) for r in np.linspace(0.02, tip, 4)]
        m.tube(path, np.linspace(0.016, 0.006, 4), RAIL, sides=4, uv_len=0.8)
    m.gem((0, 0, 0), 0.04, 0.04, METAL, sides=5)
    p, nn, uv, tri = m.arrays()
    if sign < 0:
        p = p * [-1, 1, 1]; nn = nn * [-1, 1, 1]
        tri = tri[:, [0, 2, 1]]
    return p.astype(np.float32), nn.astype(np.float32), uv, tri


# ---------------------------------------------------------------- painting
def load_sources():
    def gray(name):
        a = np.asarray(Image.open(SRC / f"{name}.png").convert("L"), float) / 255
        low = np.asarray(Image.fromarray((a * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(70)), float) / 255
        flat = a - low
        return np.clip(0.5 + flat * 1.25, 0, 1)
    reed = Image.open(SRC / "reed.png").convert("L").crop((0, 0, 2048, 500)).rotate(90, expand=True)
    reed = np.asarray(reed.resize((1024, 1024)), float) / 255
    return dict(wood=gray("wood"), metal=gray("metal"), canvas=gray("canvas"), reed=reed)


def blur(a, r):
    img = Image.fromarray(np.uint8(np.clip(a, 0, 1) * 255))
    return np.asarray(img.filter(ImageFilter.GaussianBlur(r)), float) / 255


def sample(src, w, h, rng, sx=1.0, sy=1.0):
    H, W = src.shape
    xs = (rng.integers(0, W) + np.arange(w) * sx).astype(int) % W
    ys = (rng.integers(0, H) + np.arange(h) * sy).astype(int) % H
    return src[np.ix_(ys, xs)]


def ramp(v, c):
    v = np.clip(v, 0, 1)[..., None]
    low = c[0] + (c[1] - c[0]) * np.clip(v * 2, 0, 1)
    return low + (c[2] - c[1]) * np.clip(v * 2 - 1, 0, 1)


def cloud(w, h, rng, scale):
    base = rng.random((max(2, int(h / scale)), max(2, int(w / scale))))
    img = Image.fromarray(np.uint8(base * 255)).resize((w, h), Image.BICUBIC)
    return np.asarray(img, float) / 255


class Atlas:
    def __init__(self):
        self.rgb = np.zeros((SIZE, SIZE, 3)); self.h = np.full((SIZE, SIZE), 0.5)
        self.r = np.full((SIZE, SIZE), 0.7); self.m = np.zeros((SIZE, SIZE)); self.e = np.zeros((SIZE, SIZE, 3))

    def put(self, region, rgb, h, rough, metal=0.0, emit=None):
        x0, y0, x1, y1 = region
        self.rgb[y0:y1, x0:x1] = rgb; self.h[y0:y1, x0:x1] = h
        self.r[y0:y1, x0:x1] = rough; self.m[y0:y1, x0:x1] = metal
        if emit is not None:
            self.e[y0:y1, x0:x1] = emit


def planks(src, w, h, count, rng, stretch=1.0, joints=2):
    L = np.zeros((h, w)); seam = np.zeros((h, w))
    rows = np.linspace(0, h, count + 1).astype(int)
    for k in range(count):
        a, b = rows[k], rows[k + 1]
        piece = sample(src["wood"], w, b - a, rng, sx=stretch, sy=0.8)
        L[a:b] = np.clip(piece * 0.8 + rng.uniform(0.04, 0.18), 0, 1)
        seam[max(0, a - 1):a + 2] = 1
        for joint in rng.integers(40, w - 40, joints):
            seam[a:b, joint - 1:joint + 1] = 1
            L[a:b, joint:] = np.clip(L[a:b, joint:] + rng.uniform(-0.05, 0.05), 0, 1)
    return L, blur(seam, 0.9) ** 0.7, rows


def rivets(mask_h, rows, spacing, rng, r=2.0):
    h, w = mask_h
    out = np.zeros(mask_h)
    for row in rows[1:-1]:
        for x in range(int(rng.integers(6, spacing)), w - 4, spacing):
            yy, xx = np.ogrid[-4:5, -4:5]
            spot = (xx * xx + yy * yy) <= r * r
            y0 = max(0, row + 3 - 4)
            patch = out[y0:y0 + 9, x - 4:x + 5]
            if patch.shape == spot.shape:
                patch[spot] = 1
    return out


def paint(t, src, seed):
    rng = np.random.default_rng(seed)
    A = Atlas()
    metal_tex = sample(src["metal"], 512, 160, rng)
    # ----- hull
    w, h = 1024, 256
    if t.get("reed"):
        L = sample(src["reed"], w, h, rng, sx=0.9, sy=0.42)
        seam = np.zeros((h, w))
        rows = np.array([0, h])
        H = L * 0.75 + 0.1
        for x in range(50, w, 118):
            band = np.exp(-((np.arange(w) - x) / 7.0) ** 2)
            seam += band[None, :] * 0
        col = ramp(L, t["hull"])
        for x in range(50, w, 118):
            x0, x1 = x - 9, x + 9
            rope = sample(src["canvas"], x1 - x0, h, rng)
            twist = 0.5 + 0.5 * np.sin((np.arange(h)[:, None] * 0.75 + np.arange(x1 - x0)[None, :] * 1.1))
            col[:, x0:x1] = ramp(rope * 0.45 + twist * 0.55, t["rope"])
            H[:, x0:x1] = 0.72 + 0.2 * twist
        rough = np.full((h, w), t["rough"]); metal = np.zeros((h, w))
    else:
        L, seam, rows = planks(src, w, h, t["strakes"], rng, joints=1 if t.get("lacquer") else 2)
        dots = rivets((h, w), rows, 34, rng)
        wear = cloud(w, h, rng, 34) * 0.6 + cloud(w, h, rng, 9) * 0.4
        col = ramp(L, t["hull"])
        rough = np.full((h, w), t["rough"]) + (L - 0.5) * 0.12
        metal = np.zeros((h, w))
        H = 0.5 + (L - 0.5) * (0.12 if t.get("lacquer") else 0.5) - seam * 0.42
        if t.get("lacquer"):
            # lacquer worn through to the wood on the edges of the strakes
            edge = np.clip(blur(seam, 4) * 2.4 + (wear - 0.62) * 1.5, 0, 1)[..., None]
            bare = ramp(L, (t["trim"][0], t["trim"][1] * 1.3, t["trim"][2] * 1.3))
            col = col * (1 - edge * 0.65) + bare * edge * 0.65
        col *= (1 - seam[..., None] * (0.42 if t.get("lacquer") else 0.72))
        col *= (0.86 + 0.2 * wear[..., None])
        keel_dark = np.linspace(0.8, 1.04, h)[:, None, None]
        col *= keel_dark
        col = col * (1 - dots[..., None]) + ramp(np.full((h, w), 0.72), t["metal"]) * dots[..., None] * 0.9
        H = H + dots * 0.25
        metal = np.maximum(metal, dots * t["metal_amt"])
    if t.get("plates"):
        for k in range(1, 4):
            y = int(h * k / 4)
            col[y - 1:y + 1] *= 0.5
    emit = np.zeros((h, w, 3))
    if t.get("veins"):
        v = np.abs(cloud(w, h, rng, 22) - 0.5) + (np.abs(cloud(w, h, rng, 7) - 0.5) * 0.3)
        veins = np.clip(1 - v / 0.03, 0, 1) * np.clip(1.15 - np.linspace(1.0, 0.0, h)[:, None], 0.0, 1.0)
        veins = blur(veins, 0.8)
        emit = veins[..., None] * t["glow"] * 0.9
        col = col * (1 - veins[..., None] * 0.55) + t["glow"] * veins[..., None] * 0.4
    for b in t["bands"]:
        x = int(b * w)
        half = 11
        band = sample(src["metal"], half * 2, h, rng)
        col[:, x - half:x + half] = ramp(band * 0.7 + 0.2, t["metal"])
        rough[:, x - half:x + half] = t["metal_rough"]
        metal[:, x - half:x + half] = t["metal_amt"]
        H[:, x - half:x + half] = 0.82 + (band - 0.5) * 0.15
        col[:, x - half - 2:x - half] *= 0.45; col[:, x + half:x + half + 2] *= 0.45
    A.put(HULL, col, H, rough, metal, emit)
    # ----- deck
    w, h = 1024, 128
    if t.get("reed"):
        L = sample(src["reed"], w, h, rng, sx=0.8, sy=0.5)
        A.put(DECK, ramp(L, t["deck"]), L * 0.8 + 0.1, t["rough"])
    else:
        L, seam, rows = planks(src, w, h, max(3, t["strakes"] - 1), rng)
        col = ramp(L, t["deck"]) * (1 - seam[..., None] * 0.7)
        col *= (0.9 + 0.16 * cloud(w, h, rng, 22)[..., None])
        A.put(DECK, col, 0.5 + (L - 0.5) * 0.4 - seam * 0.4, t["rough"] + 0.06)
    # ----- well
    w, h = 512, 128
    L, seam, rows = planks(src, w, h, 6, rng)
    col = ramp(L * 0.8, t["deck"]) * 0.62 * (1 - seam[..., None] * 0.7)
    A.put(WELL, col, 0.5 + (L - 0.5) * 0.3 - seam * 0.4, 0.86)
    # ----- trims
    w, h = 512, 32
    L = sample(src["wood"], w, h, rng, sx=0.8, sy=0.7)
    A.put(RAIL, ramp(L, t["trim"]) * (1.0 - np.abs(np.linspace(-1, 1, h))[:, None, None] ** 3 * 0.3), 0.5 + (L - 0.5) * 0.4, t["rough"] - 0.05)
    L = sample(src["metal"], w, h, rng, sy=0.8)
    A.put(BAND, ramp(L * 0.8 + 0.1, t["metal"]), 0.5 + (L - 0.5) * 0.3, t["metal_rough"], t["metal_amt"])
    twist = 0.5 + 0.5 * np.sin(np.arange(w)[None, :] * 0.42 + np.arange(h)[:, None] * 0.5)
    A.put(ROPE, ramp(twist * 0.75 + sample(src["canvas"], w, h, rng) * 0.25, t["rope"]), 0.35 + twist * 0.5, 0.92)
    L = sample(src["wood"], w, h, rng, sx=0.6)
    A.put(DARK, ramp(L * 0.6, t["trim"]) * 0.72, 0.5 + (L - 0.5) * 0.3, 0.7)
    # ----- sail
    w, h = 640, 320
    cloth = sample(src["canvas"], w, h, rng, sx=0.8, sy=0.8)
    if t.get("mat"):
        cloth = sample(src["reed"], w, h, rng, sx=0.7, sy=0.6) * 0.7
        cross = 0.5 + 0.5 * np.sin(np.arange(w)[None, :] * 0.34)
        cloth = cloth * 0.75 + cross * 0.3
    v = np.linspace(0, 1, h)[:, None]
    u = np.linspace(0, 1, w)[None, :]
    col = ramp(cloth, t["sail"])
    if "sail_fade" in t:
        k = np.clip((v - 0.45) / 0.55, 0, 1)[..., None] ** 1.5
        col = col * (1 - k) + (col * 0.45 + t["sail_fade"] * 0.75) * k
    col *= (0.88 + 0.18 * cloud(w, h, rng, 40)[..., None])
    H = 0.5 + (cloth - 0.5) * 0.1
    ribs = t["ribs"]
    gaps = (u * (ribs - 1)) % 1.0
    seam = np.exp(-(np.minimum(gaps, 1 - gaps) * (ribs - 1) * w / 640 * 40) ** 2)
    col *= (1 - seam[..., None] * 0.28)
    for k in range(t["patches"]):
        x = int(rng.integers(40, w - 110)); y = int(rng.integers(50, h - 90))
        pw, ph = int(rng.integers(50, 96)), int(rng.integers(40, 76))
        tone = float(rng.uniform(0.78, 0.92))
        col[y:y + ph, x:x + pw] *= tone
        col[y:y + ph, x:x + pw] *= np.array([1.0, 0.97, 0.9])
        H[y:y + ph, x:x + pw] += 0.06
        for edge in (col[y:y + 2, x:x + pw], col[y + ph - 2:y + ph, x:x + pw], col[y:y + ph, x:x + 2], col[y:y + ph, x + pw - 2:x + pw]):
            edge *= 0.72
    emit = np.zeros((h, w, 3))
    if "hem" in t:
        hem = np.clip((v - 0.93) / 0.03, 0, 1)
        col = col * (1 - hem[..., None]) + t["hem"] * hem[..., None]
        if t["glow_amt"] > 3:
            emit = (np.clip((v - 0.8) / 0.2, 0, 1) ** 3)[..., None] * t["glow"] * 0.55 * np.ones((h, w, 1))
    A.put(SAIL, col, H, 0.9 if not t.get("lacquer") else 0.72, 0, emit)
    # ----- blocks
    w, h = 384, 160
    L = sample(src["wood"], w, h, rng, sx=0.6, sy=0.6)
    A.put(WOOD, ramp(L, t["trim"]) * 1.05, 0.5 + (L - 0.5) * 0.45, t["rough"] - 0.04)
    w, h = 192, 160
    L = sample(src["metal"], w, h, rng)
    A.put(METAL, ramp(L * 0.75 + 0.15, t["metal"]), 0.5 + (L - 0.5) * 0.4, t["metal_rough"], t["metal_amt"])
    n = cloud(w, h, rng, 14)
    A.put(GLOW, t["glow"] * (0.6 + n[..., None] * 0.4), 0.5, 0.15, 0,
          t["glow"] * t["glow_amt"] * (0.55 + n[..., None] * 0.45))
    # ----- fins
    w, h = 512, 192
    L = sample(src["wood"], w, h, rng, sx=0.7, sy=0.7)
    col = ramp(L, t["hull"]) * 0.92
    edge = np.clip(np.linspace(1, -1, h)[:, None] * 5 - 3.5, 0, 1)
    col = col * (1 - edge[..., None]) + ramp(sample(src["metal"], w, h, rng), t["metal"]) * edge[..., None]
    A.put(FIN, col, 0.5 + (L - 0.5) * 0.35, t["rough"], edge * t["metal_amt"])
    L = sample(src["wood"], w, h, rng, sx=0.7, sy=0.7)
    A.put(CARVE, ramp(L, t["trim"]), 0.5 + (L - 0.5) * 0.4, t["rough"])
    return A


def write_maps(A, stem, scale=1.0):
    side = lambda px: (int(px * scale), int(px * scale))
    albedo = Image.fromarray(np.uint8(np.clip(A.rgb, 0, 1) * 255 + 0.5)).resize(side(SIZE), Image.LANCZOS)
    albedo.save(stem.with_name(stem.name + "_albedo.jpg"), quality=90, subsampling=0)
    occl = np.clip(0.55 + (blur(A.h, 1.5) - blur(A.h, 9)) * 3.0, 0.3, 1)
    orm = np.stack([occl, np.clip(A.r, 0.05, 1), np.clip(A.m, 0, 1)], 2)
    Image.fromarray(np.uint8(orm * 255 + 0.5)).resize(side(512), Image.LANCZOS).save(
        stem.with_name(stem.name + "_orm.jpg"), quality=92, subsampling=0)
    h = np.asarray(Image.fromarray(np.uint8(np.clip(A.h, 0, 1) * 255)).filter(ImageFilter.GaussianBlur(0.7)), float) / 255
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 3.2
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 3.2
    nrm = norm(np.stack([-dx, dy, np.ones_like(h)], 2))
    Image.fromarray(np.uint8((nrm * 0.5 + 0.5) * 255 + 0.5)).resize(side(512), Image.LANCZOS).save(
        stem.with_name(stem.name + "_normal.png"), optimize=True)
    emit = np.clip(A.e / 3.4, 0, 1)
    Image.fromarray(np.uint8(emit * 255 + 0.5)).resize(side(256), Image.LANCZOS).save(
        stem.with_name(stem.name + "_emit.jpg"), quality=88)


# ---------------------------------------------------------------- glTF
def write_gltf(name, parts, sockets, glow):
    stem = OUT / name
    blob = bytearray()
    views, accessors, meshes, nodes = [], [], [], []

    def add(data, ctype, kind, target, bounds=False):
        while len(blob) % 4:
            blob.append(0)
        raw = data.tobytes()
        views.append(dict(buffer=0, byteOffset=len(blob), byteLength=len(raw), target=target))
        blob.extend(raw)
        acc = dict(bufferView=len(views) - 1, componentType=ctype, count=len(data) if kind != "SCALAR" else int(data.size), type=kind)
        if bounds:
            acc["min"] = [float(x) for x in data.min(0)]; acc["max"] = [float(x) for x in data.max(0)]
        accessors.append(acc)
        return len(accessors) - 1

    children = []
    tris = 0
    for part, (p, n, uv, tri), at in parts:
        tris += len(tri)
        prim = dict(attributes=dict(POSITION=add(p, 5126, "VEC3", 34962, True), NORMAL=add(n, 5126, "VEC3", 34962),
                                    TEXCOORD_0=add(uv, 5126, "VEC2", 34962)),
                    indices=add(tri.reshape(-1).astype(np.uint16), 5123, "SCALAR", 34963), material=0)
        meshes.append(dict(name=part, primitives=[prim]))
        node = dict(name=part, mesh=len(meshes) - 1)
        if at is not None:
            node["translation"] = [float(x) for x in at]
        nodes.append(node); children.append(len(nodes) - 1)
    for sock, at in sockets.items():
        nodes.append(dict(name=sock, translation=[float(x) for x in at])); children.append(len(nodes) - 1)
    nodes.append(dict(name="SkiffRoot", children=children))
    images = [dict(uri=f"{name}_{s}") for s in ("albedo.jpg", "normal.png", "orm.jpg", "emit.jpg")]
    doc = dict(
        asset=dict(version="2.0", generator="tools/art/skiff_art.py"), scene=0,
        scenes=[dict(name="Scene", nodes=[len(nodes) - 1])], nodes=nodes, meshes=meshes,
        materials=[dict(name=f"{name}_mat",
                        pbrMetallicRoughness=dict(baseColorTexture=dict(index=0), metallicRoughnessTexture=dict(index=2),
                                                  metallicFactor=1.0, roughnessFactor=1.0),
                        normalTexture=dict(index=1), occlusionTexture=dict(index=2),
                        emissiveTexture=dict(index=3), emissiveFactor=[1.0, 1.0, 1.0],
                        extensions=dict(KHR_materials_emissive_strength=dict(emissiveStrength=float(glow))))],
        textures=[dict(source=i, sampler=0) for i in range(4)], images=images,
        samplers=[dict(magFilter=9729, minFilter=9987, wrapS=33071, wrapT=33071)],
        accessors=accessors, bufferViews=views, buffers=[dict(uri=f"{name}.bin", byteLength=len(blob))],
        extensionsUsed=["KHR_materials_emissive_strength"])
    stem.with_suffix(".bin").write_bytes(bytes(blob))
    stem.with_suffix(".gltf").write_text(json.dumps(doc, separators=(",", ":")), newline="\n")
    return tris


TEXTURE_IMPORT = """[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="res://assets/models/props/{folder}/{file}"

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map={normal}
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=0
"""


SCENE_IMPORT = """[remap]

importer="scene"
importer_version=1
type="PackedScene"

[deps]

source_file="res://assets/models/props/{folder}/{file}"

[params]

nodes/root_type=""
nodes/root_name=""
nodes/root_script=null
mesh_library/use_node_names_as_mesh_names=false
array_mesh/deduplicate_surfaces=true
nodes/apply_root_scale=true
nodes/root_scale=1.0
nodes/import_as_skeleton_bones=false
nodes/use_name_suffixes=true
nodes/use_node_type_suffixes=true
meshes/ensure_tangents=true
meshes/generate_lods=true
meshes/create_shadow_meshes=true
meshes/light_baking=1
meshes/lightmap_texel_size=0.2
meshes/force_disable_compression=false
skins/use_named_skins=true
animation/import=true
animation/fps=30
animation/trimming=false
animation/remove_immutable_tracks=true
animation/import_rest_as_RESET=false
import_script/path=""
materials/extract=0
materials/extract_format=0
materials/extract_path=""
_subresources={{}}
gltf/naming_version=2
gltf/embedded_image_handling=1
gltf/texture_map_mode=1
"""


def write_imports(name):
    scene = OUT / f"{name}.gltf.import"
    if not scene.exists():
        scene.write_text(SCENE_IMPORT.format(file=f"{name}.gltf", folder=OUT.name), newline="\n")
    for suffix, normal in (("albedo.jpg", 0), ("orm.jpg", 2), ("normal.png", 1), ("emit.jpg", 0)):
        path = OUT / f"{name}_{suffix}.import"
        if not path.exists():
            path.write_text(TEXTURE_IMPORT.format(file=f"{name}_{suffix}", normal=normal, folder=OUT.name), newline="\n")


def build(tier, src, seed):
    t = TIERS[tier]
    name = f"skiff_{tier}"
    hull, h = build_hull(t)
    hx, hy, hz = HINGE
    hb = float(h.half(np.array(hz)))
    x = hb + 0.02
    y = float(h.sheer(np.array(hz))) + 0.05
    parts = [("SkiffHull", hull.arrays(), None),
             ("VaneL", build_vane(t, 1), (x, y, hz)),
             ("VaneR", build_vane(t, -1), (-x, y, hz))]
    sockets = {
        "SeatSocket": SEAT, "GripSocket": (0, -0.045, 0.23), "MountRoot": (0, 0.05, -0.3),
        "TailSocket": (0, float(h.sheer(np.array(h.zs + 0.1))) + 0.06, h.zs + 0.06),
        "HandLSocket": yoke_at(HAND[0]), "HandRSocket": yoke_at(-HAND[0]),
        "FootLSocket": FOOT, "FootRSocket": (-FOOT[0], FOOT[1], FOOT[2]),
        "LiftSocket": (0, float(h.keel(np.array(0.02))) - 0.1, 0.02),
    }
    OUT.mkdir(parents=True, exist_ok=True)
    write_maps(paint(t, src, seed), OUT / name)
    tris = write_gltf(name, parts, sockets, 3.4)
    write_imports(name)
    print(f"{name}: {tris} triangles, {sum(len(a[1][0]) for a in parts)} vertices -> item {ITEM_OF[tier]}")


if __name__ == "__main__":
    wanted = sys.argv[1:] or list(TIERS)
    sources = load_sources()
    for number, tier in enumerate(TIERS):
        if tier in wanted:
            build(tier, sources, 100 + number)
