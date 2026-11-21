"""The interface's control kit: buttons, gauges, sliders, swatches, tabs and
checkboxes, drawn procedurally into game/assets/ui/kit/.

    python tools/art/ui_kit.py            # writes every PNG + kit.json
    python tools/art/ui_kit.py --sheet x.png   # also a contact sheet

Every piece is drawn at K pixels per interface unit (the 1280x720 canvas the
game lays out in) with analytic anti-aliasing: shapes are signed distance
fields in interface units, coverage is clip(0.5 - d * K). The game loads each
PNG as a texture whose reported size is the interface size (ImageTexture
size_override), so nine-slice margins are written in interface units and a 2x
screen still samples real detail (UIKit, scripts/ui/ui_kit.gd).

The look (2026-11-21, the owner: "AAA MMORPG, AION 2 / Lost Ark / FFXIV"):
chamfered plates of dark blued steel in a thin antique-gold bevel lit from
above; the main action in gilt bronze with a warm inner glow; inset grooves for
gauges with a glossy fill and a hot leading edge; diamond slider grips and
gem swatches. Metal and stone carry a fine grain so nothing reads as a flat
vector fill. `--spec` prints each piece's interface size and nine-slice margins for
UIKit.SPEC (scripts/ui/ui_kit.gd), which mirrors them.
"""
import json
import math
import os
import sys

import numpy as np
from PIL import Image

K = 4  # pixels per interface unit
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "game", "assets", "ui", "kit")
SQ2 = math.sqrt(2.0)


# ------------------------------------------------------------------ helpers

def hexc(s, a=1.0):
    s = s.lstrip("#")
    return np.array([int(s[0:2], 16) / 255.0, int(s[2:4], 16) / 255.0, int(s[4:6], 16) / 255.0, a], np.float32)


class Canvas:
    """Premultiplied RGBA, float32, with interface-unit pixel centres."""

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.W, self.H = int(round(w * K)), int(round(h * K))
        ys, xs = np.mgrid[0:self.H, 0:self.W].astype(np.float32)
        self.x = (xs + 0.5) / K
        self.y = (ys + 0.5) / K
        self.px = np.zeros((self.H, self.W, 4), np.float32)

    def over(self, rgb, alpha):
        """Composite colour `rgb` ((3,) or (H,W,3)) at coverage `alpha` (H,W)."""
        a = np.clip(alpha, 0.0, 1.0)[..., None]
        rgb = np.asarray(rgb, np.float32)
        if rgb.ndim == 1:
            rgb = rgb[:3][None, None, :]
        self.px[..., :3] = rgb * a + self.px[..., :3] * (1.0 - a)
        self.px[..., 3:4] = a + self.px[..., 3:4] * (1.0 - a)

    def add(self, rgb, alpha):
        """Additive light (keeps alpha where it already is, adds where not)."""
        a = np.clip(alpha, 0.0, 1.0)[..., None]
        rgb = np.asarray(rgb, np.float32)
        if rgb.ndim == 1:
            rgb = rgb[:3][None, None, :]
        self.px[..., :3] = np.minimum(self.px[..., :3] + rgb * a, 1.0)
        self.px[..., 3:4] = np.maximum(self.px[..., 3:4], np.minimum(self.px[..., 3:4] + a, 1.0))

    def image(self):
        p = self.px.copy()
        a = p[..., 3:4]
        rgb = np.where(a > 1e-5, p[..., :3] / np.maximum(a, 1e-5), 0.0)
        out = np.concatenate([np.clip(rgb, 0, 1), np.clip(a, 0, 1)], axis=-1)
        return Image.fromarray((out * 255.0 + 0.5).astype(np.uint8), "RGBA")


def cov(d):
    """Coverage of the inside (d <= 0) of a distance field, anti-aliased."""
    return np.clip(0.5 - d * K, 0.0, 1.0)


def band(d, inner, outer):
    """Coverage of the ring inner <= d <= outer (both negative = inset)."""
    return np.clip(cov(d - outer) - cov(d - inner), 0.0, 1.0)


def sd_chamfer(x, y, x0, y0, x1, y1, c):
    """Signed distance to a rectangle with its corners cut by `c` (exact inside)."""
    cx, cy = (x0 + x1) * 0.5, (y0 + y1) * 0.5
    hw, hh = (x1 - x0) * 0.5, (y1 - y0) * 0.5
    px, py = np.abs(x - cx), np.abs(y - cy)
    dx, dy = px - hw, py - hh
    ox, oy = np.maximum(dx, 0), np.maximum(dy, 0)
    box = np.sqrt(ox * ox + oy * oy) + np.minimum(np.maximum(dx, dy), 0)
    if c <= 0:
        return box
    cham = (px + py - (hw + hh - c)) / SQ2
    return np.maximum(box, cham)


def sd_round(x, y, x0, y0, x1, y1, r):
    cx, cy = (x0 + x1) * 0.5, (y0 + y1) * 0.5
    hw, hh = (x1 - x0) * 0.5 - r, (y1 - y0) * 0.5 - r
    dx, dy = np.abs(x - cx) - hw, np.abs(y - cy) - hh
    ox, oy = np.maximum(dx, 0), np.maximum(dy, 0)
    return np.sqrt(ox * ox + oy * oy) + np.minimum(np.maximum(dx, dy), 0) - r


def sd_diamond(x, y, cx, cy, rx, ry):
    m = min(rx, ry)
    return (np.abs(x - cx) / rx + np.abs(y - cy) / ry - 1.0) * m / SQ2 * 1.0


def sd_circle(x, y, cx, cy, r):
    return np.sqrt((x - cx) ** 2 + (y - cy) ** 2) - r


def ramp(t, stops):
    """Colour along t in [0,1] through (t, hex) stops; (H,W,3)."""
    t = np.clip(t, 0.0, 1.0)
    ts = [s[0] for s in stops]
    cs = [hexc(s[1])[:3] for s in stops]
    out = np.zeros(t.shape + (3,), np.float32)
    for ch in range(3):
        out[..., ch] = np.interp(t, ts, [c[ch] for c in cs])
    return out


_noise_cache = {}


def grain(cv, scale=1.2, seed=1, octaves=3):
    """Smooth value noise in [-1,1] over the canvas (interface-unit feature size)."""
    key = (cv.W, cv.H, scale, seed, octaves)
    if key in _noise_cache:
        return _noise_cache[key]
    rng = np.random.default_rng(seed)
    total = np.zeros((cv.H, cv.W), np.float32)
    amp, norm = 1.0, 0.0
    for o in range(octaves):
        cell = max(1.0, scale * K / (2 ** o))
        gw, gh = int(cv.W / cell) + 3, int(cv.H / cell) + 3
        g = rng.random((gh, gw)).astype(np.float32)
        img = Image.fromarray((g * 255).astype(np.uint8), "L").resize(
            (int(gw * cell), int(gh * cell)), Image.BICUBIC)
        a = np.asarray(img, np.float32)[:cv.H, :cv.W] / 255.0
        total += (a * 2.0 - 1.0) * amp
        norm += amp
        amp *= 0.5
    total /= norm
    _noise_cache[key] = total
    return total


def brushed(cv, seed=3):
    """Horizontal brushed-metal streaks in [-1,1]."""
    rng = np.random.default_rng(seed)
    rows = rng.random(cv.H).astype(np.float32)
    k = np.ones(5, np.float32) / 5.0
    rows = np.convolve(rows, k, mode="same")
    rows = (rows - rows.mean()) / (rows.std() + 1e-5)
    return np.clip(rows[:, None] * np.ones((1, cv.W), np.float32) * 0.5, -1, 1)


def shade(rgb, n, amount):
    """Multiply-brighten rgb (H,W,3) by noise n (H,W) * amount."""
    return np.clip(rgb * (1.0 + n[..., None] * amount), 0.0, 1.0)


def save(img, name):
    os.makedirs(OUT, exist_ok=True)
    img.save(os.path.join(OUT, name + ".png"), optimize=True)


KIT = {}


def record(name, size, margins=None, extra=None):
    entry = {"size": [size[0], size[1]]}
    if margins is not None:
        entry["margins"] = list(margins)  # left, top, right, bottom
    if extra:
        entry.update(extra)
    KIT[name] = entry


# ------------------------------------------------------------------ plates

# Palettes per plate kind and state: frame (top, mid, bottom), fill (top,
# bottom), the inner glow colour and strengths.
PLATES = {
    "steel": {
        "normal": dict(frame=("#e6c97f", "#a98536", "#5e451b"), fill=("#26324a", "#10161f"),
                       glow="#d9a64a", glow_a=0.0, halo=0.0, gloss=0.07, bright=0.0),
        "hover": dict(frame=("#fff0b8", "#d4aa50", "#7e5c22"), fill=("#2f3d58", "#151d2a"),
                      glow="#f0b552", glow_a=0.30, halo=0.40, gloss=0.10, bright=0.0),
        "pressed": dict(frame=("#b6964c", "#8a6a2c", "#5a4219"), fill=("#0d121a", "#1b2433"),
                        glow="#d9a64a", glow_a=0.12, halo=0.0, gloss=0.0, bright=0.0, sunk=True),
        "disabled": dict(frame=("#6d6555", "#4d473b", "#302c24"), fill=("#1a1c21", "#101114"),
                         glow="#000000", glow_a=0.0, halo=0.0, gloss=0.03, bright=0.0, dim=0.82),
    },
    "gold": {
        "normal": dict(frame=("#fff1bd", "#d8aa46", "#7c5413"), fill=("#47300d", "#1c1204"),
                       glow="#ff9d2e", glow_a=0.16, halo=0.08, gloss=0.07, bright=0.0),
        "hover": dict(frame=("#fffbe6", "#f0c45c", "#9a6a1a"), fill=("#5c3e12", "#271806"),
                      glow="#ffb54a", glow_a=0.30, halo=0.50, gloss=0.10, bright=0.0),
        "pressed": dict(frame=("#d9b464", "#a87e2c", "#6a4810"), fill=("#24170a", "#4a3110"),
                        glow="#ff9d2e", glow_a=0.30, halo=0.0, gloss=0.0, bright=0.0, sunk=True),
        "disabled": dict(frame=("#6d6555", "#4d473b", "#302c24"), fill=("#1d1b18", "#121110"),
                         glow="#000000", glow_a=0.0, halo=0.0, gloss=0.03, bright=0.0, dim=0.82),
    },
    "blood": {
        "normal": dict(frame=("#f2cf86", "#b4823a", "#6a4418"), fill=("#4a121a", "#1e0508"),
                       glow="#ff5a3c", glow_a=0.13, halo=0.0, gloss=0.07, bright=0.0),
        "hover": dict(frame=("#fff0c0", "#d8a352", "#86561e"), fill=("#5e1822", "#2a080c"),
                      glow="#ff6a48", glow_a=0.28, halo=0.45, gloss=0.10, bright=0.0),
        "pressed": dict(frame=("#c99e58", "#94682a", "#5a3a14"), fill=("#1e0609", "#46111a"),
                        glow="#ff5a3c", glow_a=0.2, halo=0.0, gloss=0.0, bright=0.0, sunk=True),
        "disabled": dict(frame=("#6d6555", "#4d473b", "#302c24"), fill=("#1d1a1b", "#121011"),
                         glow="#000000", glow_a=0.0, halo=0.0, gloss=0.03, bright=0.0, dim=0.82),
    },
}


def plate(kind, state, w, h, pad, cham, frame_w=1, name=None, studs=False):
    """A chamfered button plate `w` x `h` (interface units) with `pad` of
    room around it for the halo and the drop shadow. Every line is a whole
    unit wide on whole units (a black rim, `frame_w` of gold, a dark
    hairline, the fill), so at 1:1 (1080p) each lands on whole pixels."""
    p = PLATES[kind][state]
    cv = Canvas(w + pad * 2, h + pad * 2)
    x, y = cv.x, cv.y
    x0, y0, x1, y1 = pad, pad, pad + w, pad + h
    sunk = p.get("sunk", False)
    d = sd_chamfer(x, y, x0, y0, x1, y1, cham)
    # outer halo (hover) and the drop shadow under the plate
    if p["halo"] > 0:
        out = np.maximum(d, 0.0)
        cv.over(hexc(p["glow"]), np.exp(-out / 2.6) * p["halo"] * (d > -0.5) * 0.75)
    if not sunk:
        ds = sd_chamfer(x, y - 1.4, x0 + 0.5, y0, x1 - 0.5, y1, cham)
        cv.over(hexc("#000000"), np.clip(0.5 - ds / 2.2, 0, 1) * 0.55 * (1.0 - cov(d)))
    # the dark outer rim: the whole shape, so the frame sits on near-black
    cv.over(hexc("#04060a"), cov(d) * 0.96)
    # the metal frame, lit from above (vertical ramp) with a fine grain
    ty = (y - y0) / (y1 - y0)
    fr = ramp(ty, [(0.0, p["frame"][0]), (0.45, p["frame"][1]), (1.0, p["frame"][2])])
    fr = shade(fr, grain(cv, 0.9, 11), 0.10)
    fw = frame_w
    cv.over(fr, band(d, -1.0 - fw, -1.0))
    # the chamfers catch the light: their frame is brighter
    corner = np.clip(1.0 - np.abs((np.abs(x - (x0 + x1) / 2) + np.abs(y - (y0 + y1) / 2))
                                  - ((x1 - x0) / 2 + (y1 - y0) / 2 - cham * 0.5)) / (cham * 0.55), 0, 1)
    cv.add(hexc("#fff4cc")[:3] * 0.6, band(d, -1.0 - fw, -1.0) * corner * (0.6 if not sunk else 0.25))
    # a hairline of shadow inside the frame
    cv.over(hexc("#06080c"), band(d, -2.0 - fw, -1.0 - fw))
    # the fill: a vertical ramp, a little darker toward both ends, grain
    inner = -2.0 - fw
    fill = ramp(ty, [(0.0, p["fill"][0]), (1.0, p["fill"][1])])
    tx = (x - x0) / (x1 - x0)
    ends = 1.0 - 0.18 * (np.abs(tx - 0.5) * 2.0) ** 2
    fill = fill * ends[..., None]
    fill = shade(fill, grain(cv, 1.6, 5, 4), 0.06)
    fill = shade(fill, brushed(cv, 7), 0.03)
    cv.over(fill, cov(d - inner))
    di = -(d - inner)  # depth inside the fill (>0)
    if sunk:
        # pressed: shadow falls in from the top edge
        cv.over(hexc("#000000"), cov(d - inner) * np.exp(-np.maximum(y - y0 - 2.0, 0) / 3.0) * 0.45)
    # the warm inner glow rising from the bottom edge
    if p["glow_a"] > 0:
        rise = np.exp(-np.maximum(y1 - 2.0 - y, 0) / (h * 0.30))
        edge = np.exp(-np.maximum(di, 0) / 5.0)
        cv.add(hexc(p["glow"])[:3], cov(d - inner) * np.clip(rise * 0.85 + edge * 0.25 * rise, 0, 1) * p["glow_a"])
    # the gloss: the upper half catches a soft sheen, and a lit inner top line
    if p["gloss"] > 0:
        top = np.clip(1.0 - (y - (y0 + 2.5)) / (h * 0.42), 0, 1) ** 1.6
        cv.add(np.array([1.0, 0.97, 0.9], np.float32), cov(d - inner) * top * p["gloss"])
        cv.add(np.array([1.0, 0.95, 0.85], np.float32),
               band(d, inner - 1.0, inner) * (y < (y0 + y1) / 2) * p["gloss"] * 1.4)
    # a second, faint gold line inset from the frame: the classic double rule
    if not sunk:
        hair = 0.30 if kind != "steel" else 0.20
        cv.over(ramp(ty, [(0.0, p["frame"][0]), (1.0, p["frame"][2])]),
                band(d, inner - 3.0, inner - 2.0) * hair)
    if p.get("dim"):
        cv.px[..., :3] *= p["dim"]
    return cv


def write_plate(name, kind, w, h, pad, cham, frame_w=1, slice_lr=None, slice_tb=None):
    for state in ("normal", "hover", "pressed", "disabled"):
        cv = plate(kind, state, w, h, pad, cham, frame_w)
        save(cv.image(), "%s_%s" % (name, state))
    lr = slice_lr if slice_lr is not None else pad + cham + 6
    tb = slice_tb if slice_tb is not None else pad + cham + 2
    record(name, (w + pad * 2, h + pad * 2), (lr, tb, lr, tb), {"expand": pad})


def accent(name, w, h, pad, cham, frame_w=1):
    """White light inside a plate (tinted in the game by a house or a
    difficulty colour): a glow rising from the bottom and an inner rule."""
    cv = Canvas(w + pad * 2, h + pad * 2)
    x0, y0, x1, y1 = pad, pad, pad + w, pad + h
    d = sd_chamfer(cv.x, cv.y, x0, y0, x1, y1, cham)
    inner = -2.0 - frame_w
    rise = np.exp(-np.maximum(y1 - 2.0 - cv.y, 0) / (h * 0.42))
    cv.add(np.array([1, 1, 1], np.float32), cov(d - inner) * rise * 0.55)
    cv.add(np.array([1, 1, 1], np.float32), cov(d - inner) * 0.10)
    cv.add(np.array([1, 1, 1], np.float32), band(d, inner - 1.0, inner) * 0.65)
    save(cv.image(), name)
    record(name, (w + pad * 2, h + pad * 2), None, {"expand": pad})


# ------------------------------------------------------------------ ornaments

def stud(name, r=3.6, glow=False):
    """A small gold diamond stud sitting on a plate's side edge."""
    s = r * 2 + 4
    cv = Canvas(s, s)
    c = s / 2
    d = sd_diamond(cv.x, cv.y, c, c, r, r)
    if glow:
        cv.over(hexc("#ffc45a"), np.exp(-np.maximum(d, 0) / 1.4) * 0.55 * (d > -0.3))
    cv.over(hexc("#05070a"), cov(d) * 0.95)
    t = (cv.y - (c - r)) / (2 * r)
    gold = ramp(t, [(0.0, "#fff3c4"), (0.5, "#d4a64a"), (1.0, "#6e4c16")])
    cv.over(gold, cov(d + 0.8))
    # the facet: a light upper-left half
    facet = (cv.x - c) + (cv.y - c) < 0
    cv.add(np.array([1, 0.95, 0.8], np.float32), cov(d + 0.8) * facet * 0.25)
    save(cv.image(), name)
    record(name, (s, s))


def wing(name, length=40.0, height=18.0, mirror=False, lit=False):
    """A flourish for the main call to action's ends: a diamond on the plate's
    edge and a gold rule running outwards that thins and fades, with two small
    gems on it."""
    cv = Canvas(length, height)
    x = cv.x if not mirror else length - cv.x
    y = cv.y
    cy = height / 2
    t = np.clip((x - 6.0) / (length - 8.0), 0, 1)
    rule = np.abs(y - cy) - (0.85 * (1.0 - t) + 0.25)
    rule = np.maximum(rule, np.maximum(-x + 5.0, x - (length - 1.5)))
    gem = sd_diamond(x, y, length * 0.62, cy, 2.6, 2.6)
    root = sd_diamond(x, y, 5.0, cy, 4.4, 5.8)
    tip = sd_diamond(x, y, length * 0.86, cy, 1.5, 1.5)
    d = np.minimum(np.minimum(rule, tip), np.minimum(gem, root))
    fade = 1.0 - 0.75 * t ** 1.5
    if lit:
        cv.over(hexc("#ffb84a"), np.exp(-np.maximum(d, 0) / 2.0) * 0.45 * fade * (d > -0.2))
    cv.over(hexc("#05070a"), cov(d - 0.7) * 0.85 * fade)
    gold = ramp((y - (cy - 6)) / 12.0, [(0.0, "#fff4c8"), (0.5, "#dcae4e"), (1.0, "#6e4c16")])
    gold = shade(gold, grain(cv, 0.8, 21), 0.12)
    cv.over(gold, cov(d) * fade)
    inner = sd_diamond(x, y, 5.0, cy, 2.0, 2.8)
    cv.over(hexc("#0b0f17"), cov(inner))
    cv.add(hexc("#ffcf6a")[:3], cov(inner + 0.3) * (0.85 if lit else 0.45))
    save(cv.image(), name)
    record(name, (length, height))


def chevron(name, direction, size=20.0, colour=("#fff1c0", "#d2a246", "#7a5416")):
    cv = Canvas(size, size)
    c = size / 2
    x, y = cv.x - c, cv.y - c
    if direction == "left":
        x = -x
    elif direction == "up":
        x, y = -y, x
    elif direction == "down":
        x, y = y, x
    # a chevron ">" : two strokes meeting at the right
    a = 4.2
    # distance to the polyline (-a,-a)-(a*0.6,0)-(-a,a)
    def seg(px, py, ax, ay, bx, by):
        pax, pay = px - ax, py - ay
        bax, bay = bx - ax, by - ay
        h = np.clip((pax * bax + pay * bay) / (bax * bax + bay * bay), 0, 1)
        return np.sqrt((pax - bax * h) ** 2 + (pay - bay * h) ** 2)
    d = np.minimum(seg(x, y, -a * 0.5, -a, a * 0.5, 0), seg(x, y, a * 0.5, 0, -a * 0.5, a)) - 1.25
    cv.over(hexc("#04060a"), cov(d - 0.9) * 0.85)
    g = ramp((cv.y - (c - a)) / (2 * a), [(0.0, colour[0]), (0.5, colour[1]), (1.0, colour[2])])
    cv.over(g, cov(d))
    save(cv.image(), name)
    record(name, (size, size))


def cross(name, size=16.0):
    cv = Canvas(size, size)
    c = size / 2
    x, y = cv.x - c, cv.y - c
    a = 3.6
    d = np.minimum(np.abs(x - y) / SQ2, np.abs(x + y) / SQ2) - 1.0
    d = np.maximum(d, np.maximum(np.abs(x), np.abs(y)) - a)
    cv.over(hexc("#04060a"), cov(d - 0.9) * 0.85)
    g = ramp((cv.y - (c - a)) / (2 * a), [(0.0, "#fff1c0"), (0.5, "#d2a246"), (1.0, "#7a5416")])
    cv.over(g, cov(d))
    save(cv.image(), name)
    record(name, (size, size))


# ------------------------------------------------------------------ inset pieces

def plaque(name, w=96, h=30, focus=False):
    """The recessed value plate of a stepper (and the text field): a dark
    inset with gold hairlines top and bottom that fade out at the ends."""
    cv = Canvas(w, h)
    x, y = cv.x, cv.y
    d = sd_chamfer(x, y, 0.0, 0.0, w, h, 3.0)
    ty = y / h
    fill = ramp(ty, [(0.0, "#04060a"), (1.0, "#0e141d")])
    fill = shade(fill, grain(cv, 1.4, 31, 4), 0.10)
    cv.over(fill, cov(d) * 0.94)
    # inner shadow from the top lip
    cv.over(hexc("#000000"), cov(d) * np.exp(-np.maximum(y - 1.0, 0) / 2.5) * 0.55)
    fade = np.clip(np.minimum(x, w - x) / 22.0, 0, 1) ** 0.8
    line = hexc("#d6ac56" if focus else "#a07e3a")[:3]
    cv.over(line, band(d, -1.2, -0.2) * (y < h * 0.5) * fade * (0.95 if focus else 0.75))
    cv.over(line * 0.8, band(d, -1.2, -0.2) * (y >= h * 0.5) * fade * (0.8 if focus else 0.45))
    # the bottom lip catches the light
    cv.add(hexc("#ffe2a0")[:3], band(d, -0.9, 0.2) * (y > h - 2.5) * fade * 0.22)
    if focus:
        cv.add(hexc("#e9b452")[:3], cov(d) * np.exp(-np.maximum(np.minimum(y, h - y) - 1.0, 0) / 4.0) * fade * 0.16)
    save(cv.image(), name)
    record(name, (w, h), (24, 7, 24, 7))


def field(name, w=96, h=34, state="normal"):
    """A text field: a recessed well with a full thin frame."""
    cv = Canvas(w, h)
    x, y = cv.x, cv.y
    d = sd_chamfer(x, y, 0.0, 0.0, w, h, 3.0)
    fill = ramp(y / h, [(0.0, "#03050a"), (1.0, "#0c121b")])
    fill = shade(fill, grain(cv, 1.4, 41, 4), 0.08)
    cv.over(fill, cov(d) * 0.95)
    cv.over(hexc("#000000"), cov(d) * np.exp(-np.maximum(y - 1.0, 0) / 3.0) * 0.5)
    frame = {"normal": ("#7a6136", "#4a3a20"), "focus": ("#f1d084", "#a7812f"), "disabled": ("#3e3a33", "#2a2722")}[state]
    fr = ramp(y / h, [(0.0, frame[0]), (1.0, frame[1])])
    cv.over(fr, band(d, -1.1, 0.0))
    if state == "focus":
        cv.add(hexc("#f0b552")[:3], cov(d) * np.exp(-np.maximum(-d - 1.0, 0) / 3.5) * 0.22)
    save(cv.image(), name)
    record(name, (w, h), (8, 8, 8, 8))


def rail_row(name, hover=False, w=120.0, h=40.0):
    """A quest tracker card: dark glass fading out to the right, gold
    hairlines top and bottom fading with it (the game draws the state accent
    on its left edge)."""
    cv = Canvas(w, h)
    x, y = cv.x, cv.y
    fade = np.clip(1.0 - (x - 8.0) / (w - 8.0), 0, 1) ** 1.3
    body = ramp(y / h, [(0.0, "#0b1220"), (1.0, "#05080e")])
    body = shade(body, grain(cv, 1.4, 101, 4), 0.08)
    cv.over(body, fade * (0.86 if hover else 0.72))
    if hover:
        cv.add(hexc("#e8b652")[:3], fade ** 2 * np.exp(-x / 30.0) * 0.10)
    line = hexc("#d9b468" if hover else "#a8874a")[:3]
    edge = (np.exp(-((y - 0.6) / 0.45) ** 2) + np.exp(-((y - (h - 0.6)) / 0.45) ** 2))
    cv.over(line, edge * fade * (0.75 if hover else 0.5))
    save(cv.image(), name)
    record(name, (w, h), (10, 4, 70, 4))


# ------------------------------------------------------------------ gauges

def track(name, w=64, h=12, thin=False):
    """A gauge's groove, the Korean MMO way (AION 2, Lost Ark): dark glass
    letting the world show faintly through, a crisp black outline, the shade
    of its top lip inside and a faint lit line along its foot. No frame."""
    cv = Canvas(w, h)
    x, y = cv.x, cv.y
    d = sd_round(x, y, 0.0, 0.0, w, h, 1.0)
    glass = ramp(y / h, [(0.0, "#161b24"), (1.0, "#1d232d")] if thin else [(0.0, "#070a10"), (1.0, "#0d121a")])
    cv.over(glass, cov(d) * np.interp(y / h, [0, 1], [0.82, 0.70] if thin else [0.78, 0.62]).astype(np.float32))
    cv.over(hexc("#000000"), band(d, -1.0, 0.0) * 0.85)
    cv.over(hexc("#000000"), cov(d + 1.0) * np.exp(-np.maximum(y - 0.9, 0) / (0.9 if thin else 1.4)) * 0.45)
    if not thin:
        cv.add(np.array([1, 0.95, 0.85], np.float32), cov(d + 0.75) * np.exp(-((y - (h - 1.4)) / 0.35) ** 2) * 0.07)
    save(cv.image(), name)
    m = 1.5 if thin else 2.0
    record(name, (w, h), (m, m, m, m), {"inset": 1.0})


def fill_shade(name, w=32, h=12):
    """A gauge fill's light, white: the game multiplies it by the gauge's
    colour. Even and saturated (no plastic shine): the faintest fall from top
    to foot, a darker last line, a hairline grain along it."""
    cv = Canvas(w, h)
    x, y = cv.x, cv.y
    ty = y / h
    lum = np.interp(ty, [0.0, 0.15, 0.55, 0.9, 1.0], [1.0, 0.97, 0.88, 0.74, 0.58]).astype(np.float32)
    lum = lum * (1.0 + grain(cv, 0.6, 61, 2) * 0.025)
    rgb = np.repeat(np.clip(lum, 0, 1)[..., None], 3, axis=2)
    d = sd_round(x, y, 0, 0, w, h, 0.6)
    cv.over(rgb, cov(d))
    save(cv.image(), name)
    record(name, (w, h), (1, 0, 1, 0))


def fill_gloss(name, w=32, h=12):
    """White over the fill, unmultiplied: one crisp lit line along the top
    and a faint sheen under it - the edge of a liquid, not a plastic band."""
    cv = Canvas(w, h)
    x, y = cv.x, cv.y
    d = sd_round(x, y, 0, 0, w, h, 0.6)
    inside = cov(d)
    cv.add(np.array([1, 1, 1], np.float32), inside * np.exp(-((y - 0.55) / 0.42) ** 2) * 0.48)
    cv.add(np.array([1, 1, 1], np.float32), inside * np.clip(1.0 - y / (h * 0.45), 0, 1) ** 2 * 0.07)
    save(cv.image(), name)
    record(name, (w, h), (1, 0, 1, 0))


def fill_lead(name, w=64, h=12):
    """The light gathering toward a gauge's leading edge (the game lays it
    over the last stretch of the fill): clear at the left, brighter to the
    right, strongest through the middle of the bar."""
    cv = Canvas(w, h)
    x, y = cv.x, cv.y
    along = np.clip(x / w, 0, 1) ** 1.8
    across = 1.0 - 0.45 * np.abs(y / h - 0.45) * 2.0
    cv.add(np.array([1, 1, 1], np.float32), along * np.clip(across, 0, 1) * 0.30)
    save(cv.image(), name)
    record(name, (w, h))


def spark(name, w=16, h=24):
    """A gauge's leading edge: a soft glow, no hard line (the game tints it
    with the gauge's colour, lightened)."""
    cv = Canvas(w, h)
    x, y = cv.x - w / 2, cv.y - h / 2
    vy = np.clip(1.0 - (np.abs(y) / (h / 2)) ** 2, 0, 1)
    halo = np.exp(-(x / 3.2) ** 2) * vy ** 1.5
    core = np.exp(-(x / 1.1) ** 2) * vy ** 0.8
    cv.add(np.array([1, 1, 1], np.float32), halo * 0.38 + core * 0.55)
    save(cv.image(), name)
    record(name, (w, h))


def end_cap(name, w=26, h=12, mirror=False):
    """The loading bar's end: a small gold diamond on the groove's end and a
    hairline running out from it, fading."""
    cv = Canvas(w, h)
    x = cv.x if not mirror else w - cv.x
    y = cv.y
    cy = h / 2
    line = np.exp(-((y - cy) / 0.32) ** 2) * np.clip(1.0 - (x - 4.0) / (w - 4.0), 0, 1) ** 1.4 * (x > 3.0)
    cv.add(hexc("#e9c77a")[:3], line * 0.85)
    dd = sd_diamond(x, y, 3.6, cy, 3.0, 3.6)
    cv.over(hexc("#04060a"), cov(dd - 0.6) * 0.85)
    cv.over(ramp((y - (cy - 3.6)) / 7.2, [(0.0, "#fff1c2"), (0.5, "#d9ab4c"), (1.0, "#7c5616")]), cov(dd))
    save(cv.image(), name)
    record(name, (w, h))


def pips():
    """The skill window's progress steps (slanted slivers) and the master gem."""
    for state, (fill_a, fill_b, line, glow) in {
        "off": ("#0b1018", "#070a10", "#3a4352", 0.0),
        "on": ("#ffe6a2", "#c48a28", "#fff2c8", 0.0),
        "next": ("#3a2c12", "#22190a", "#f0c86a", 0.55),
    }.items():
        w, h = 14.0, 8.0
        cv = Canvas(w, h)
        # a parallelogram slanting forward
        sx = cv.x - (h - cv.y) * 0.45
        d = np.maximum(np.abs(sx - (w / 2 - 1.0)) - 4.6, np.abs(cv.y - h / 2) - 2.2)
        if glow:
            cv.over(hexc("#ffc45a"), np.exp(-np.maximum(d, 0) / 1.0) * glow * (d > -0.3))
        cv.over(hexc("#000000"), cov(d - 0.7) * 0.8)
        cv.over(ramp((cv.y - 1.8) / 4.4, [(0, fill_a), (1, fill_b)]), cov(d))
        cv.over(hexc(line), band(d, -0.55, 0.0) * (0.9 if state != "on" else 0.35))
        if state == "on":
            cv.add(np.array([1, 1, 0.92], np.float32), cov(d) * np.exp(-((cv.y - 2.3) / 0.5) ** 2) * 0.5)
        save(cv.image(), "pip_" + state)
        record("pip_" + state, (w, h))
        cv = Canvas(16, 16)
        dm = sd_diamond(cv.x, cv.y, 8, 8, 4.6, 5.6)
        if glow or state == "on":
            cv.over(hexc("#ffc45a"), np.exp(-np.maximum(dm, 0) / 1.5) * (0.5 if state == "on" else glow) * (dm > -0.3))
        cv.over(hexc("#000000"), cov(dm - 0.7) * 0.8)
        cv.over(ramp((cv.y - 2.4) / 11.2, [(0, fill_a), (1, fill_b)]), cov(dm))
        cv.over(hexc(line), band(dm, -0.6, 0.0) * (0.9 if state != "on" else 0.4))
        facet = (cv.x - 8) + (cv.y - 8) < 0
        cv.add(np.array([1, 0.97, 0.9], np.float32), cov(dm + 0.6) * facet * (0.3 if state == "on" else 0.06))
        save(cv.image(), "gem_" + state)
        record("gem_" + state, (16, 16))


def quest_marks():
    """The quest tracker's marks, small and flat like AION 2's and Lost Ark's:
    a cut diamond in the quest's colour with a dark glyph - a dot (in
    progress), "!" (new), a tick (finished, reward waiting)."""
    for name, (top, bottom, glyph) in {
        "quest_mark": ("#ffd98c", "#c3862a", "dot"),
        "quest_new": ("#ffe7a4", "#e09a2c", "bang"),
        "quest_ready": ("#d4f59a", "#5fa634", "tick"),
    }.items():
        s = 18.0
        cv = Canvas(s, s)
        x, y = cv.x, cv.y
        c = s / 2
        d = sd_diamond(x, y, c, c, 6.6, 7.6)
        cv.over(hexc("#000000"), np.clip(0.5 - sd_diamond(x, y - 0.8, c, c, 7.2, 8.2) / 1.2, 0, 1) * 0.5 * (1 - cov(d)))
        cv.over(hexc("#05070b"), cov(d - 0.8) * 0.9)
        cv.over(ramp((y - (c - 7.6)) / 15.2, [(0, top), (1, bottom)]), cov(d))
        facet = (x - c) * 0.6 + (y - c) < 0
        cv.add(np.array([1, 1, 0.95], np.float32), cov(d + 0.5) * facet * 0.18)
        ink = hexc("#1a1206")[:3]
        if glyph == "dot":
            cv.over(ink, cov(sd_diamond(x, y, c, c, 2.0, 2.3)) * 0.85)
        elif glyph == "bang":
            bar = np.maximum(np.abs(x - c) - 0.95, np.abs(y - (c - 1.6)) - 2.6)
            dot = sd_circle(x, y, c, c + 3.4, 1.05)
            cv.over(ink, cov(np.minimum(bar, dot)) * 0.9)
        else:
            def seg(px, py, ax, ay, bx, by):
                pax, pay = px - ax, py - ay
                bax, bay = bx - ax, by - ay
                hh = np.clip((pax * bax + pay * bay) / (bax * bax + bay * bay), 0, 1)
                return np.sqrt((pax - bax * hh) ** 2 + (pay - bay * hh) ** 2)
            tick = np.minimum(seg(x, y, c - 3.0, c + 0.2, c - 0.8, c + 2.6), seg(x, y, c - 0.8, c + 2.6, c + 3.2, c - 2.6)) - 0.95
            cv.over(ink, cov(tick) * 0.9)
        save(cv.image(), name)
        record(name, (s, s))


def rail_back(name, w=200.0, h=100.0):
    """The quest tracker's backdrop: a dark wash behind the text so it reads
    over bright ground, strongest at the left, gone by the right, soft at top
    and bottom - no box, no border."""
    cv = Canvas(w, h)
    x, y = cv.x, cv.y
    across = np.clip(1.0 - x / w, 0, 1) ** 1.25
    vert = np.clip(np.minimum(y, h - y) / 16.0, 0, 1) ** 1.2
    cv.over(hexc("#04060a"), across * vert * 0.55)
    save(cv.image(), name)
    record(name, (w, h), (4, 18, 120, 18))


# ------------------------------------------------------------------ slider

def slider_parts():
    # the groove
    cv = Canvas(40, 10)
    d = sd_round(cv.x, cv.y, 0.5, 1.0, 39.5, 9.0, 3.0)
    cv.over(hexc("#020305"), cov(d) * 0.96)
    cv.over(ramp(cv.y / 10, [(0, "#a8863f"), (1, "#3b2c14")]), band(d, -0.9, 0.0))
    cv.over(ramp(cv.y / 10, [(0, "#010203"), (1, "#0c1118")]), cov(d + 0.9))
    cv.over(hexc("#000000"), cov(d + 0.9) * np.exp(-np.maximum(cv.y - 2.0, 0) / 1.6) * 0.6)
    save(cv.image(), "slider_track")
    record("slider_track", (40, 10), (5, 4, 5, 4))
    # the gold run from the start to the grip
    cv = Canvas(40, 10)
    d = sd_round(cv.x, cv.y, 0.5, 2.0, 39.5, 8.0, 2.2)
    g = ramp((cv.y - 2) / 6, [(0, "#fff0b6"), (0.45, "#e0ae48"), (1, "#7a5212")])
    cv.over(hexc("#ffb94a"), np.exp(-np.maximum(d, 0) / 1.5) * 0.35 * (d > -0.2))
    cv.over(shade(g, grain(cv, 0.9, 81), 0.08), cov(d))
    cv.add(np.array([1, 1, 0.95], np.float32), cov(d) * (cv.y < 3.4) * 0.35)
    save(cv.image(), "slider_fill")
    record("slider_fill", (40, 10), (5, 4, 5, 4))
    # the diamond grip
    for state in ("normal", "hover", "disabled"):
        s = 26.0
        cv = Canvas(s, s)
        c = s / 2
        d = sd_diamond(cv.x, cv.y, c, c, 8.2, 8.2)
        if state == "hover":
            cv.over(hexc("#ffc45a"), np.exp(-np.maximum(d, 0) / 2.0) * 0.6 * (d > -0.3))
        cv.over(hexc("#000000"), np.clip(0.5 - sd_diamond(cv.x, cv.y - 1.2, c, c, 8.4, 8.4) / 1.6, 0, 1) * 0.6 * (1 - cov(d)))
        cv.over(hexc("#04060a"), cov(d) * 0.97)
        fr = ("#fff4c8", "#d6a84a", "#6a4814") if state != "disabled" else ("#8a8274", "#5a5448", "#34302a")
        if state == "hover":
            fr = ("#fffbe8", "#f0c460", "#8a6018")
        cv.over(shade(ramp((cv.y - (c - 8)) / 16, [(0, fr[0]), (0.5, fr[1]), (1, fr[2])]), grain(cv, 0.8, 91), 0.1),
                cov(d + 0.8))
        di = sd_diamond(cv.x, cv.y, c, c, 4.6, 4.6)
        core = ("#1d2a40", "#0b111c") if state != "disabled" else ("#26282c", "#16171a")
        cv.over(ramp((cv.y - (c - 4.6)) / 9.2, [(0, core[0]), (1, core[1])]), cov(di))
        if state != "disabled":
            cv.add(hexc("#ffd27a")[:3], cov(di) * np.exp(-((cv.x - c) ** 2 + (cv.y - c) ** 2) / 3.2) * (0.95 if state == "hover" else 0.7))
        facet = (cv.x - c) + (cv.y - c) < 0
        cv.add(np.array([1, 0.97, 0.88], np.float32), cov(d + 0.8) * (1 - cov(di)) * facet * 0.25)
        save(cv.image(), "slider_grip_" + state)
        record("slider_grip_" + state, (s, s))


# ------------------------------------------------------------------ swatches

def swatch_parts(s=30.0):
    c = s / 2
    r = 11.0
    # the colour disc (white: the game tints it)
    cv = Canvas(s, s)
    cv.over(np.array([1, 1, 1], np.float32), cov(sd_circle(cv.x, cv.y, c, c, r)))
    save(cv.image(), "swatch_disc")
    record("swatch_disc", (s, s))
    # glass shading over the colour
    cv = Canvas(s, s)
    d = sd_circle(cv.x, cv.y, c, c, r)
    inside = cov(d)
    hl = np.exp(-(((cv.x - (c - 3.5)) ** 2) / 18.0 + ((cv.y - (c - 4.5)) ** 2) / 9.0))
    cv.add(np.array([1, 1, 1], np.float32), inside * hl * 0.55)
    foot = np.clip((cv.y - c) / r, 0, 1) ** 1.5
    cv.over(np.array([0, 0, 0], np.float32), inside * foot * 0.35)
    rim = np.exp(-np.maximum(-d, 0) / 1.6)
    cv.over(np.array([0, 0, 0], np.float32), inside * rim * 0.45)
    save(cv.image(), "swatch_glass")
    record("swatch_glass", (s, s))
    for state, (w, cols, glow) in {
        "normal": (1.6, ("#8a7346", "#4a3a1e"), 0.0),
        "hover": (1.8, ("#f2d48a", "#9a7630"), 0.25),
        "selected": (2.4, ("#fff4c8", "#c99536"), 0.7),
    }.items():
        cv = Canvas(s, s)
        d = sd_circle(cv.x, cv.y, c, c, r + 0.2)
        if glow:
            cv.over(hexc("#ffc45a"), np.exp(-np.maximum(d - w, 0) / 2.0) * glow * (d > w - 0.4))
        cv.over(hexc("#04060a"), band(d, -0.2, w + 0.9) * 0.9)
        cv.over(ramp((cv.y - (c - r)) / (2 * r), [(0, cols[0]), (1, cols[1])]), band(d, 0.0, w))
        save(cv.image(), "swatch_ring_" + state)
        record("swatch_ring_" + state, (s, s))


# ------------------------------------------------------------------ tabs, checks

def tab_parts():
    for state, (alpha, glow) in {"selected": (1.0, 0.30), "hover": (0.45, 0.0)}.items():
        w, h = 64.0, 34.0
        cv = Canvas(w, h)
        x, y = cv.x, cv.y
        fade = np.clip(np.minimum(x, w - x) / 18.0, 0, 1) ** 0.9
        if glow:
            wash = np.clip((y - h * 0.25) / (h * 0.75), 0, 1) ** 2.2
            cv.add(hexc("#e8b652")[:3], wash * fade * glow * 0.5)
        line = np.exp(-((y - (h - 1.6)) / 0.75) ** 2)
        cv.add(hexc("#f6d98e")[:3], line * fade * alpha)
        if glow:
            cv.add(hexc("#ffbe55")[:3], np.exp(-((y - (h - 1.6)) / 2.6) ** 2) * fade * glow)
        save(cv.image(), "tab_" + state)
        record("tab_" + state, (w, h), (20, 4, 20, 4))
    stud("tab_mark", 3.0, glow=True)


def check_parts():
    for state in ("off", "on", "off_disabled", "on_disabled"):
        s = 22.0
        cv = Canvas(s, s)
        d = sd_chamfer(cv.x, cv.y, 3, 3, s - 3, s - 3, 3.0)
        dis = state.endswith("disabled")
        cv.over(hexc("#03050a"), cov(d) * 0.95)
        fr = ("#d9b768", "#6e5220") if not dis else ("#6a6458", "#3a3630")
        cv.over(ramp((cv.y - 3) / (s - 6), [(0, fr[0]), (1, fr[1])]), band(d, -1.2, -0.1))
        cv.over(ramp(cv.y / s, [(0, "#020306"), (1, "#0d131c")]), cov(d + 1.2))
        cv.over(hexc("#000000"), cov(d + 1.2) * np.exp(-np.maximum(cv.y - 4.2, 0) / 2.0) * 0.5)
        if state.startswith("on"):
            dd = sd_diamond(cv.x, cv.y, s / 2, s / 2, 4.6, 4.6)
            if not dis:
                cv.over(hexc("#ffc45a"), np.exp(-np.maximum(dd, 0) / 1.8) * 0.65 * (dd > -0.3))
            g = ("#fff4c8", "#d6a84a", "#7a5416") if not dis else ("#9a9384", "#6a6458", "#4a463e")
            cv.over(ramp((cv.y - 6.4) / 9.2, [(0, g[0]), (0.5, g[1]), (1, g[2])]), cov(dd))
        save(cv.image(), "check_" + state)
        record("check_" + state, (s, s))
    # the on/off switch
    for state in ("off", "on", "off_disabled", "on_disabled"):
        w, h = 40.0, 22.0
        cv = Canvas(w, h)
        on = state.startswith("on")
        dis = state.endswith("disabled")
        d = sd_round(cv.x, cv.y, 2, 5, w - 2, h - 5, 6.0)
        cv.over(hexc("#03050a"), cov(d) * 0.95)
        cv.over(ramp((cv.y - 5) / 12, [(0, "#9a7a3a" if not dis else "#5a554a"), (1, "#3b2c14" if not dis else "#2a2722")]), band(d, -1.0, 0.0))
        groove = ("#5a3c10", "#2a1a06") if on and not dis else ("#05070b", "#0d121a")
        cv.over(ramp((cv.y - 5) / 12, [(0, groove[0]), (1, groove[1])]), cov(d + 1.0))
        if on and not dis:
            cv.add(hexc("#ff9d2e")[:3], cov(d + 1.0) * 0.25)
        kx = w - 11.0 if on else 11.0
        dk = sd_circle(cv.x, cv.y, kx, h / 2, 7.2)
        cv.over(hexc("#000000"), np.clip(0.5 - sd_circle(cv.x, cv.y - 1.0, kx, h / 2, 7.4) / 1.4, 0, 1) * 0.6 * (1 - cov(dk)))
        kc = ("#fff4c8", "#d6a84a", "#6a4814") if on and not dis else ("#b9b4a8", "#7a7668", "#3e3b34")
        cv.over(ramp((cv.y - (h / 2 - 7)) / 14, [(0, kc[0]), (0.5, kc[1]), (1, kc[2])]), cov(dk))
        cv.add(np.array([1, 1, 1], np.float32), cov(dk) * np.exp(-((cv.x - kx + 2) ** 2 + (cv.y - h / 2 + 3) ** 2) / 6.0) * 0.4)
        save(cv.image(), "toggle_" + state)
        record("toggle_" + state, (w, h))


# ------------------------------------------------------------------ main

def build():
    write_plate("btn", "steel", 64, 30, 6, 4)
    write_plate("btn_gold", "gold", 64, 30, 6, 4, frame_w=2)
    write_plate("btn_blood", "blood", 64, 30, 6, 4, frame_w=2)
    write_plate("btn_icon", "steel", 28, 28, 5, 4)
    accent("btn_accent", 64, 30, 6, 4)
    stud("stud", 3.5)
    stud("stud_lit", 3.5, glow=True)
    wing("wing_l", mirror=True)
    wing("wing_r")
    wing("wing_l_lit", mirror=True, lit=True)
    wing("wing_r_lit", lit=True)
    for dname in ("left", "right", "up", "down"):
        chevron("ico_chevron_" + dname, dname)
    cross("ico_close")
    plaque("plaque")
    for st in ("normal", "focus", "disabled"):
        field("field_" + st, state=st)
    track("bar_track", 64, 12)
    track("bar_track_thin", 48, 6, thin=True)
    fill_shade("bar_fill")
    fill_gloss("bar_gloss")
    fill_lead("bar_lead")
    spark("bar_spark")
    end_cap("bar_cap_l", mirror=True)
    end_cap("bar_cap_r")
    pips()
    quest_marks()
    rail_back("rail_back")
    rail_row("rail_row")
    rail_row("rail_row_hover", hover=True)
    slider_parts()
    swatch_parts()
    tab_parts()
    check_parts()
    print("wrote %d pieces to %s" % (len(KIT), OUT))
    if "--spec" in sys.argv:
        # UIKit.SPEC in scripts/ui/ui_kit.gd: id -> [size, margins, expand]
        for name in sorted(KIT):
            e = KIT[name]
            m = e.get("margins")
            print('	"%s": [Vector2(%g, %g), %s, %g],' % (
                name, e["size"][0], e["size"][1],
                "[%g, %g, %g, %g]" % tuple(m) if m else "[]", e.get("expand", 0)))


def contact_sheet(path):
    files = sorted(n for n in os.listdir(OUT) if n.endswith(".png"))
    tiles = [Image.open(os.path.join(OUT, n)).convert("RGBA") for n in files]
    cols = 8
    cw = max(t.width for t in tiles) + 16
    ch = max(t.height for t in tiles) + 16
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * cw, rows * ch), (40, 46, 58, 255))
    for i, t in enumerate(tiles):
        sheet.alpha_composite(t, ((i % cols) * cw + 8, (i // cols) * ch + 8))
    sheet.save(path)
    print("sheet", path)


if __name__ == "__main__":
    build()
    if "--sheet" in sys.argv:
        contact_sheet(sys.argv[sys.argv.index("--sheet") + 1])
