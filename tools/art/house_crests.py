"""The four house crests and the house banners, drawn procedurally.

    python tools/art/house_crests.py [--sheet build/captures/w9/crests_sheet.png]

Writes game/assets/ui/icons/icon_house_<house>.png (512 px, RGBA: an enamelled
heater shield in the house colour, a raised metal rim and the house animal in
relief) and game/assets/castle/textures/banner_<slot>.png (512 x 2064, RGB: the
woven house cloth with a metal border, the animal and a fringe). The colours
come from content/data/houses.json (`primary_color` the field, `secondary_color`
the metal), so a palette change is one edit there and one run of this script.

  Velkar  phoenix   ember field, steel-iron metal
  Nisera  scorpion  obsidian-violet field, desert-ochre metal
  Ilvane  swift     azure field, sky-white metal
  Torvan  boar      moss field, bronze metal

The animals are drawn as plain silhouettes in a 100 x 100 frame (y down) and
shaded from a height field (distance-transform bevels, Blinn-Phong over a
studio gradient for the metal), at 4x and filtered down, so they keep a clean,
dark-outlined read down to the 20 px nameplate crest.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[2]
HOUSES = ROOT / "content" / "data" / "houses.json"
ICONS = ROOT / "game" / "assets" / "ui" / "icons"
BANNERS = ROOT / "game" / "assets" / "castle" / "textures"
## Painted crests (fal bytedance/seedream/v5.5/text-to-image, 2048 px RGBA, the
## prompts in art/crests_seedream/README.md); raw art stays out of the repo.
## With --painted the icons are these, and the banners carry them instead of
## the embroidered animal.
PAINTED = ROOT.parent / "art" / "crests_seedream"
## The castle kit's banner slots (castle_interior.glb `kit_banner_<colour>`)
## stand for one house each (house_colors.gd SLOT_HOUSE).
BANNER_SLOT = {"velkar": "red", "nisera": "green", "ilvane": "blue", "torvan": "yellow"}

# ----------------------------------------------------------------- geometry


def _bez(p0, p1, p2, p3, n=24):
    out = []
    for i in range(1, n + 1):
        t = i / n
        a = (1 - t) ** 3
        b = 3 * (1 - t) ** 2 * t
        c = 3 * (1 - t) * t * t
        d = t ** 3
        out.append((a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]))
    return out


def path(spec: str) -> list[tuple[float, float]]:
    """An absolute SVG-like path (M, L, C, Q, Z) as one polygon."""
    toks = spec.replace(",", " ").split()
    pts: list[tuple[float, float]] = []
    i = 0
    cmd = "M"
    while i < len(toks):
        if toks[i].isalpha():
            cmd = toks[i]
            i += 1
            if cmd == "Z":
                continue
        if cmd in "ML":
            pts.append((float(toks[i]), float(toks[i + 1])))
            i += 2
        elif cmd == "C":
            p = [float(t) for t in toks[i:i + 6]]
            pts.extend(_bez(pts[-1], (p[0], p[1]), (p[2], p[3]), (p[4], p[5])))
            i += 6
        elif cmd == "Q":
            p = [float(t) for t in toks[i:i + 4]]
            q0 = pts[-1]
            c1 = (q0[0] + 2 / 3 * (p[0] - q0[0]), q0[1] + 2 / 3 * (p[1] - q0[1]))
            c2 = (p[2] + 2 / 3 * (p[0] - p[2]), p[3] + 2 / 3 * (p[1] - p[3]))
            pts.extend(_bez(q0, c1, c2, (p[2], p[3])))
            i += 4
        else:
            raise ValueError(cmd)
    return pts


def mirror(pts, axis=50.0):
    return [(2 * axis - x, y) for x, y in pts]


class Shape:
    """Adds and cuts polygons, circles and strokes in the 100 x 100 frame."""

    def __init__(self):
        self.ops: list[tuple] = []

    def poly(self, pts, cut=False):
        self.ops.append(("poly", pts, cut))
        return self

    def circle(self, cx, cy, r, cut=False):
        self.ops.append(("circle", (cx, cy, r), cut))
        return self

    def stroke(self, pts, w, cut=False):
        self.ops.append(("stroke", (pts, w), cut))
        return self

    def mask(self, size: int, box=(0.0, 0.0, 100.0, 100.0)) -> np.ndarray:
        x0, y0, x1, y1 = box
        sx = size / (x1 - x0)
        sy = size / (y1 - y0)
        tr = lambda p: ((p[0] - x0) * sx, (p[1] - y0) * sy)  # noqa: E731
        img = Image.new("L", (size, size), 0)
        d = ImageDraw.Draw(img)
        for kind, data, cut in self.ops:
            fill = 0 if cut else 255
            if kind == "poly":
                d.polygon([tr(p) for p in data], fill=fill)
            elif kind == "circle":
                cx, cy, r = data
                a = tr((cx - r, cy - r))
                b = tr((cx + r, cy + r))
                d.ellipse([a, b], fill=fill)
            else:
                pts, w = data
                q = [tr(p) for p in pts]
                width = max(1, int(round(w * sx)))
                d.line(q, fill=fill, width=width, joint="curve")
                for p in (q[0], q[-1]):
                    d.ellipse([p[0] - width / 2, p[1] - width / 2, p[0] + width / 2, p[1] + width / 2], fill=fill)
        return np.asarray(img, dtype=np.float32) / 255.0


# ----------------------------------------------------------------- animals


def phoenix() -> Shape:
    """Displayed: wings raised with flame-tipped feathers, head turned to
    dexter under a crest of flame, a tail of three flame tongues - rising."""
    s = Shape()
    wing = path(
        "M 47 41 C 42 31, 30 18, 13 9 "                        # leading edge, up and out
        "L 20 17.5 L 10 20 L 19.5 26 L 11 31 L 21 34 L 14 40 L 25 41.5 L 20 47 "   # flame feathers
        "L 32 47.5 C 38 50, 43 51.5, 47 50.5 Z"
    )
    s.poly(wing).poly(mirror(wing))
    # body: broad breast tapering to the tail
    s.poly(path("M 50 31 C 59 34, 60 45, 57 54 C 55 60, 52 63, 50 64 C 48 63, 45 60, 43 54 "
                "C 40 45, 41 34, 50 31 Z"))
    # neck and head turned to dexter, hooked beak
    s.poly(path("M 45 39 C 44 31, 46 24, 52 20 C 56 17.5, 61 18, 63.5 21.5 L 69 24.5 L 64 25.5 "
                "C 63 28.5, 60 30, 57 30.5 C 55 33, 55 36, 56 40 Z"))
    s.circle(58.3, 22.6, 1.25, cut=True)  # eye
    # crest: three flame plumes swept back from the crown
    s.poly(path("M 53 20.5 C 49 16, 45 14, 42 7 C 48 10, 53 13, 56 19 Z"))
    s.poly(path("M 56 19 C 55 14, 55 9, 52.5 3 C 58.5 7, 61 13, 59.5 19.5 Z"))
    s.poly(path("M 59.5 19.5 C 61 15, 63.5 12, 65 6 C 67.5 12, 66 17, 62 21 Z"))
    # tail: a long middle flame and two that curl outwards
    s.poly(path("M 47 58 C 44 66, 50 72, 46.5 80 C 45 84, 46.5 88, 50 93 C 49.5 87, 54.5 83, 54 76 "
                "C 53.5 70, 51 66, 53 58 Z"))
    side = path("M 46.5 58 C 43 64, 40 68, 37.5 74 C 36 78, 36.5 82, 38.5 86 C 39 81, 42 78, 44 75 "
                "C 47 70, 48.5 66, 49.5 61 Z")
    s.poly(side).poly(mirror(side))
    return s


def scorpion() -> Shape:
    """Seen from above, claws raised to the chief, the tail curled to sinister
    and the sting cocked."""
    s = Shape()
    # carapace and abdomen
    s.poly(path("M 50 30 C 56 30, 58 36, 58 42 C 58 50, 56 56, 50 59 C 44 56, 42 50, 42 42 C 42 36, 44 30, 50 30 Z"))
    for k in range(4):   # abdomen plates, slightly flared
        y = 44 + k * 4.0
        s.stroke([(43.4 + k * 0.4, y), (56.6 - k * 0.4, y)], 0.9, cut=True)
    s.stroke([(43.6, 38.5), (56.4, 38.5)], 0.9, cut=True)
    # arms and claws (mirrored)
    arm = [(45, 34), (40, 31), (35, 30), (31, 25)]
    claw = path("M 30 27 C 25 25, 22 20, 23 13 C 25 16, 27 18, 30 18 C 28 15, 28 12, 30 9 "
                "C 33 13, 35 18, 34 24 Z")
    s.stroke(arm, 3.2).poly(claw)
    s.stroke(mirror(arm), 3.2).poly(mirror(claw))
    # eight legs, jointed, splayed back
    for k, (y, reach, drop) in enumerate([(39, 31, -4), (43, 29, 0), (47, 29, 4), (51, 31, 8)]):
        leg = [(44, y), (38 - k * 0.5, y - 2.5 + k * 1.2), (reach, y + drop)]
        s.stroke(leg, 1.7)
        s.stroke(mirror(leg), 1.7)
    # tail: five segments down, curling up to sinister, then the sting
    seg = [(50, 61, 3.3), (50.5, 66, 3.1), (52.5, 70.5, 2.9), (56, 74, 2.7), (60.5, 75.5, 2.6),
           (65, 74, 2.5), (68, 70, 2.4)]
    for x, y, r in seg:
        s.circle(x, y, r)
    s.poly(path("M 66 68 C 69 64, 70 61, 69 57 C 72 59, 74 63, 73 67 C 72 69, 70 70, 68 71 Z"))  # bulb
    s.poly(path("M 69.3 57.8 C 68 55, 66 53.5, 63 53 C 66 52, 69 53, 71 56 Z"))                 # barb
    return s


def swift() -> Shape:
    """In flight, seen from below: long scythe wings swept back, forked tail."""
    s = Shape()
    wing = path(
        "M 46.5 37 C 38 30.5, 25 30, 16 39 C 10.5 45, 7.5 55, 7 67 "   # leading edge, the scythe
        "C 12 58, 18 51.5, 26 48.5 C 34 46, 41 46.5, 46.5 49.5 Z"      # trailing edge
    )
    s.poly(wing).poly(mirror(wing))
    s.poly(path("M 50 26 C 54.5 26, 56.5 30, 56.5 35 C 56.5 45, 54.5 53, 52.5 59 L 47.5 59 "
                "C 45.5 53, 43.5 45, 43.5 35 C 43.5 30, 45.5 26, 50 26 Z"))
    s.poly(path("M 48 57 C 46 65, 42.5 73, 38 81 C 43.5 76, 47.5 70.5, 50 65 C 52.5 70.5, 56.5 76, 62 81 "
                "C 57.5 73, 54 65, 52 57 Z"))                             # forked tail
    return s


def boar() -> Shape:
    """Passant to dexter: tusked head low, bristled ridge, four legs."""
    s = Shape()
    s.poly(path(
        "M 16 55 C 16 52, 17 50, 19 49 "                    # snout disc
        "C 23 47, 26 44, 29 40 C 31 37, 33 35, 36 34 "      # brow
        "L 36 27 L 41 33 "                                  # ear
        "L 43 31 L 45 33 L 47 29.5 L 49 32 L 51 28.5 L 53 31.5 L 55 28 L 57 31.5 L 59 28.5 L 61 32 "
        "L 63 29.5 L 65 33 L 67 31 "                        # bristled ridge
        "C 74 33, 80 37, 83 43 "                            # back to rump
        "C 86 41, 88 40, 89 37 C 89 41, 87 44, 84 46 "      # tail flick
        "C 85 50, 84 54, 81 57 "                            # haunch
        "L 82 66 L 83.5 72 L 78.5 72 L 77 66 L 75 60 "      # near hind leg
        "C 66 62, 55 62, 47 60 "                            # belly
        "L 45 66 L 45.5 72 L 40.5 72 L 40 66 L 39.5 60 "    # near foreleg
        "C 34 60, 30 59, 27 58 C 24 59, 21 59, 19 58 "      # chest and jaw
        "C 17 58, 16 57, 16 55 Z"))
    # far legs, a step behind
    s.poly(path("M 49 59 L 51 66 L 52.5 71 L 48.5 71 L 47 66 L 45 60 Z"))
    s.poly(path("M 72 58 L 72.5 65 L 72 71 L 68 71 L 68.5 65 L 67 59 Z"))
    s.circle(31.2, 43.0, 1.4, cut=True)                        # eye
    s.stroke([(18.2, 52), (18.6, 54.5)], 0.9, cut=True)        # nostril
    s.stroke([(37, 45), (39.5, 51), (39, 56)], 0.8, cut=True)  # jowl line
    s.stroke([(64, 47), (70, 53), (74, 58)], 0.8, cut=True)    # haunch line
    return s


def tusk() -> Shape:
    """The boar's tusk, ivory over the metal."""
    s = Shape()
    s.poly(path("M 22 57 C 21 53, 21.5 50, 24 47 C 24 50, 25 53, 26 56 Z"))
    return s


def fit_box(shape: Shape, margin: float) -> tuple[float, float, float, float]:
    """The square frame that just holds `shape` (plus `margin`), centred on it."""
    m = shape.mask(400)
    ys, xs = np.nonzero(m > 0.5)
    x0, x1, y0, y1 = xs.min() / 4, xs.max() / 4, ys.min() / 4, ys.max() / 4
    half = max(x1 - x0, y1 - y0) / 2 + margin
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    return (cx - half, cy - half, cx + half, cy + half)


ANIMALS = {"velkar": phoenix, "nisera": scorpion, "ilvane": swift, "torvan": boar}

# ----------------------------------------------------------------- shading


def hexrgb(h: str) -> np.ndarray:
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)], dtype=np.float32)


def srgb_to_lin(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def lin_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def bevel(mask: np.ndarray, width: float, power=0.6) -> np.ndarray:
    d = ndimage.distance_transform_edt(mask > 0.5)
    return np.clip(d / width, 0.0, 1.0) ** power


def normals(h: np.ndarray, strength: float) -> np.ndarray:
    gy, gx = np.gradient(h)
    n = np.dstack([-gx * strength, -gy * strength, np.ones_like(h)])
    return n / np.linalg.norm(n, axis=2, keepdims=True)


LIGHT = np.array([-0.45, -0.6, 0.66], dtype=np.float32)
LIGHT /= np.linalg.norm(LIGHT)
VIEW = np.array([0.0, 0.0, 1.0], dtype=np.float32)
HALF = (LIGHT + VIEW) / np.linalg.norm(LIGHT + VIEW)


def metal(n: np.ndarray, base: np.ndarray, gloss=40.0) -> np.ndarray:
    """Polished metal: a studio gradient reflected by the normal plus a
    highlight; `base` (linear) tints both."""
    ndl = np.clip(np.einsum("ijk,k->ij", n, LIGHT), 0.0, 1.0)
    ndh = np.clip(np.einsum("ijk,k->ij", n, HALF), 0.0, 1.0)
    # reflected up-vector: bright above, a dark horizon band, warm floor
    ry = -n[..., 1] * 2 * n[..., 2]
    env = 0.5 + 0.7 * np.clip(ry, -1, 1)
    env = env - 0.55 * np.exp(-((ry + 0.12) ** 2) / 0.03)
    col = base[None, None, :] * (0.08 + 0.55 * ndl[..., None] + 0.6 * np.clip(env, 0, None)[..., None])
    spec = (ndh ** gloss)[..., None] * (0.55 + 0.45 * base[None, None, :])
    return col + spec


def enamel(n: np.ndarray, base: np.ndarray) -> np.ndarray:
    ndl = np.clip(np.einsum("ijk,k->ij", n, LIGHT), 0.0, 1.0)
    ndh = np.clip(np.einsum("ijk,k->ij", n, HALF), 0.0, 1.0)
    return base[None, None, :] * (0.32 + 0.75 * ndl[..., None]) + 0.25 * (ndh ** 60)[..., None]


def noise(size: int, scale: float, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    small = rng.random((max(2, int(size / scale)),) * 2).astype(np.float32)
    img = Image.fromarray((small * 255).astype(np.uint8)).resize((size, size), Image.BICUBIC)
    return np.asarray(img, dtype=np.float32) / 255.0


## The animals' frame inside the shield: a little smaller than the field.
CREST_BOX = (-11.0, -7.0, 111.0, 115.0)
## Wider animals sit a little smaller.
ANIMAL_BOX = {"ilvane": (-15.0, -9.0, 115.0, 121.0), "torvan": (-18.0, -16.0, 118.0, 120.0)}

SHIELD = path("M 13 9 C 30 12, 70 12, 87 9 C 88 30, 88 50, 83 63 C 77 79, 64 88, 50 95 "
              "C 36 88, 23 79, 17 63 C 12 50, 12 30, 13 9 Z")


def crest(house: str, field_hex: str, metal_hex: str, size=2048) -> Image.Image:
    shield = Shape().poly(SHIELD).mask(size)
    # the field sits inside the rim
    rim_w = size * 0.045
    d_out = ndimage.distance_transform_edt(shield > 0.5)
    field = (d_out > rim_w).astype(np.float32)
    # the animal, a little smaller than the field and centred in it
    box = ANIMAL_BOX.get(house, CREST_BOX)
    animal = ANIMALS[house]().mask(size, box)
    animal *= field
    tusk_m = tusk().mask(size, box) * field if house == "torvan" else np.zeros_like(animal)

    # heights
    rim_t = np.clip(d_out / rim_w, 0, 1)
    rim_h = np.where(field > 0.5, 0.0, np.sin(np.pi * np.clip(rim_t, 0, 1)) ** 0.7) * shield
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) / size
    dome = (1.0 - ((xx - 0.5) ** 2 + (yy - 0.45) ** 2) * 1.6) * 0.15
    an_h = bevel(animal, size * 0.012, 0.55) * 0.75 + bevel(animal, size * 0.05, 1.0) * 0.35
    h = rim_h * 0.9 + field * dome + an_h * field
    soft = size * 0.0015
    rim_h = ndimage.gaussian_filter(rim_h, soft * 2)
    an_h = ndimage.gaussian_filter(an_h, soft)
    n_rim = normals(rim_h, size * 0.05)
    n_an = normals(an_h + dome * field, size * 0.05)
    n_field = normals(dome + noise(size, 6, 7) * 0.004, size * 0.05)

    f_lin = srgb_to_lin(hexrgb(field_hex))
    m_lin = srgb_to_lin(hexrgb(metal_hex))
    # field: enamel with a soft vignette and a fine grain
    grain = noise(size, 3, 11) * 0.08 + noise(size, 40, 12) * 0.12
    col = enamel(n_field, f_lin) * (0.9 + grain[..., None])
    vign = np.clip(1.0 - (((xx - 0.5) / 0.55) ** 2 + ((yy - 0.42) / 0.6) ** 2), 0, 1) ** 0.5
    col *= (0.55 + 0.45 * vign)[..., None]
    # a fine engraved diaper (lozenges) in the enamel
    u, v = (xx + yy) / 0.075, (xx - yy) / 0.075
    lines = np.minimum(np.abs(u - np.round(u)), np.abs(v - np.round(v)))
    col *= (1.0 - 0.13 * np.clip(1.0 - lines / 0.06, 0, 1))[..., None]
    # the rim's inner shadow on the field
    inner = np.clip((d_out - rim_w) / (size * 0.03), 0, 1)
    col *= (0.55 + 0.45 * inner)[..., None]
    # the animal's cast shadow and a dark keyline around it (small-size read)
    sh = ndimage.gaussian_filter(np.roll(np.roll(animal, int(size * 0.008), 0), int(size * 0.006), 1), size * 0.006)
    col *= (1.0 - 0.55 * sh)[..., None]
    key = ndimage.binary_dilation(animal > 0.5, iterations=int(size * 0.007)) & ~(animal > 0.5)
    keyline = ndimage.gaussian_filter(key.astype(np.float32), 1.5)
    col = col * (1.0 - 0.75 * keyline[..., None])
    # metal: rim and animal
    rim_col = metal(n_rim, m_lin)
    an_col = metal(n_an, m_lin, gloss=28.0)
    rim_mask = np.clip(shield - field, 0, 1)
    col = col * (1 - rim_mask[..., None]) + rim_col * rim_mask[..., None]
    col = col * (1 - animal[..., None]) + an_col * animal[..., None]
    if tusk_m.any():
        ivory = srgb_to_lin(hexrgb("#efe6cf"))
        col = col * (1 - tusk_m[..., None]) + metal(normals(bevel(tusk_m, size * 0.006) * 0.5, size * 0.05),
                                                     ivory, 30.0) * tusk_m[..., None]
    # rim edges: a dark line on the outside and at the field
    edge = np.clip(1.0 - np.abs(d_out - rim_w) / (size * 0.0025), 0, 1) * shield
    col *= (1.0 - 0.6 * edge)[..., None]
    out_edge = np.clip(1.0 - d_out / (size * 0.004), 0, 1) * shield
    col *= (1.0 - 0.7 * out_edge)[..., None]

    rgb = lin_to_srgb(col)
    # a soft dark halo under the shield, so it reads on any background
    halo = ndimage.gaussian_filter(shield, size * 0.01) * 0.55
    alpha = np.maximum(shield, halo)
    rgb = rgb * (shield / np.maximum(alpha, 1e-4))[..., None]   # halo is black
    img = np.dstack([rgb, alpha])
    big = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8), "RGBA")
    return big


def premul_resize(img: Image.Image, size) -> Image.Image:
    a = np.asarray(img, dtype=np.float32) / 255.0
    pm = a.copy()
    pm[..., :3] *= pm[..., 3:4]
    small = np.dstack([
        np.asarray(Image.fromarray(pm[..., c]).resize(size, Image.LANCZOS)) for c in range(4)
    ])
    small = np.clip(small, 0, 1)
    rgb = small[..., :3] / np.maximum(small[..., 3:4], 1e-4)
    out = np.dstack([np.clip(rgb, 0, 1), small[..., 3:4]])
    return Image.fromarray((out * 255 + 0.5).astype(np.uint8), "RGBA")


# ----------------------------------------------------------------- banners


def banner(house: str, field_hex: str, metal_hex: str, w=512, h=2064, emblem: Image.Image | None = None) -> Image.Image:
    """The woven house banner: cloth in the house colour with vertical folds,
    a metal-thread border, the animal embroidered in metal, a fringe."""
    S = 2
    W, H = w * S, h * S
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    f_lin = srgb_to_lin(hexrgb(field_hex))
    m_lin = srgb_to_lin(hexrgb(metal_hex))
    fringe_h = 150 * S
    cloth_h = H - fringe_h
    # weave: fine threads both ways plus slub noise
    weave = 0.5 + 0.25 * np.sin(xx * 2.1) * np.sin(yy * 2.1) + 0.25 * np.sin(yy * 1.05 + np.sin(xx * 0.3))
    slub = np.asarray(Image.fromarray((np.random.default_rng(3).random((H // 24, W // 6)) * 255).astype(np.uint8))
                      .resize((W, H), Image.BICUBIC), dtype=np.float32) / 255.0
    folds = 0.82 + 0.18 * np.sin(xx / W * math.tau * 2.0 + 0.6) * np.clip(yy / H * 1.5, 0.2, 1.0)
    shade = folds * (0.88 + 0.08 * weave + 0.08 * slub)
    col = f_lin[None, None, :] * shade[..., None]
    # border: two metal-thread bands
    def band(inset, width):
        d = np.minimum(np.minimum(xx - inset, W - 1 - inset - xx), np.minimum(yy - inset, cloth_h - 1 - inset - yy))
        return ((d >= 0) & (d < width)).astype(np.float32)
    thread = metal(np.dstack([np.zeros((H, W)), -0.25 * np.sin(yy * 1.2)[..., None][..., 0], np.ones((H, W))])
                   / 1.03, m_lin, 18.0)
    for inset, width in ((14 * S, 10 * S), (34 * S, 3 * S)):
        b = band(inset, width)
        col = col * (1 - b[..., None]) + thread * shade[..., None] * b[..., None]
    if emblem is None:
        # the emblem: the crest's animal, embroidered in metal
        side = int(W * 0.8)
        box = fit_box(ANIMALS[house](), 3.0)
        m = ANIMALS[house]().mask(side, box)
        ox, oy = (W - side) // 2, int(cloth_h * 0.36) - side // 2
        an = np.zeros((H, W), np.float32)
        an[oy:oy + side, ox:ox + side] = m
        if house == "torvan":
            tm = np.zeros((H, W), np.float32)
            tm[oy:oy + side, ox:ox + side] = tusk().mask(side, box)
        an_h = ndimage.gaussian_filter(bevel(an, side * 0.02, 0.6) * 0.6, 1.5)
        n_an = normals(an_h, side * 0.06)
        an_col = metal(n_an, m_lin, 22.0) * folds[..., None]
        sh = ndimage.gaussian_filter(np.roll(an, 5 * S, 0), 5 * S)
        col *= (1 - 0.45 * sh)[..., None]
        col = col * (1 - an[..., None]) + an_col * an[..., None]
        if house == "torvan":
            col = col * (1 - tm[..., None]) + srgb_to_lin(hexrgb("#e9dfc6"))[None, None, :] * folds[..., None] * tm[..., None]
    else:
        # the painted crest, sewn on: shaded by the cloth's folds
        side = int(W * 0.78)
        e = np.asarray(emblem.convert("RGBA").resize((side, side), Image.LANCZOS), dtype=np.float32) / 255.0
        ox, oy = (W - side) // 2, int(cloth_h * 0.36) - side // 2
        a_ = e[..., 3:4]
        e_lin = srgb_to_lin(e[..., :3]) * folds[oy:oy + side, ox:ox + side, None]
        sh = ndimage.gaussian_filter(np.roll(np.pad(e[..., 3], ((oy, H - oy - side), (ox, W - ox - side))), 6 * S, 0), 6 * S)
        col *= (1 - 0.5 * sh)[..., None]
        reg = col[oy:oy + side, ox:ox + side]
        col[oy:oy + side, ox:ox + side] = reg * (1 - a_) + e_lin * a_
    # fringe: metal threads hanging below the hem on a dark ground
    fr = np.zeros((H, W, 3), np.float32) + 0.02
    strands = (np.sin(xx * math.tau / (9.0 * S)) > -0.2).astype(np.float32)
    length = fringe_h * (0.78 + 0.22 * np.asarray(Image.fromarray(
        (np.random.default_rng(5).random((1, W // (9 * S) + 1)) * 255).astype(np.uint8)).resize((W, 1), Image.NEAREST),
        dtype=np.float32)[0] / 255.0)
    below = (yy >= cloth_h) & (yy - cloth_h < length[None, :])
    fr_col = metal(np.dstack([np.cos(xx * math.tau / (9.0 * S)) * 0.6, np.zeros((H, W)), np.ones((H, W))])
                   / 1.17, m_lin, 12.0)
    fmask = (below * strands)[..., None]
    col = np.where(yy[..., None] >= cloth_h, fr * (1 - fmask) + fr_col * fmask, col)
    # the hem
    hem = ((yy >= cloth_h - 8 * S) & (yy < cloth_h + 6 * S)).astype(np.float32)[..., None]
    col = col * (1 - hem) + thread * 0.7 * hem
    img = Image.fromarray((lin_to_srgb(col) * 255 + 0.5).astype(np.uint8), "RGB")
    return img.resize((w, h), Image.LANCZOS)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sheet", default="")
    ap.add_argument("--only", default="")
    ap.add_argument("--no-banners", action="store_true")
    ap.add_argument("--out", default="", help="write here instead of the game's folders (a preview)")
    ap.add_argument("--painted", action="store_true", help="use the painted crests in art/crests_seedream")
    args = ap.parse_args()
    icons, banners = (Path(args.out), Path(args.out)) if args.out else (ICONS, BANNERS)
    houses = json.loads(HOUSES.read_text(encoding="utf-8"))
    names = [k for k in ("velkar", "nisera", "ilvane", "torvan") if not args.only or k == args.only]
    crests = {}
    for key in names:
        hd = houses[key]
        painted = Image.open(PAINTED / f"{key}.png").convert("RGBA") if args.painted else None
        big = painted if painted is not None else crest(key, hd["primary_color"], hd["secondary_color"])
        icon = premul_resize(big, (512, 512))
        icon.save(icons / f"icon_house_{key}.png", optimize=True)
        crests[key] = icon
        if not args.no_banners:
            banner(key, hd["primary_color"], hd["secondary_color"], emblem=painted).save(
                banners / f"banner_{BANNER_SLOT[key]}.png", optimize=True)
        print("made", key)
    if args.sheet:
        # each crest at the sizes the UI draws it: 256, 58 (windows), 44, 20 (nameplate)
        sizes = [256, 96, 58, 44, 28, 20]
        cell = 266
        sheet = Image.new("RGBA", (cell * len(names), 256 + 110), (24, 24, 32, 255))
        for i, key in enumerate(names):
            sheet.alpha_composite(crests[key].resize((256, 256), Image.LANCZOS), (i * cell, 0))
            x = i * cell
            for s in sizes[1:]:
                sheet.alpha_composite(premul_resize(crests[key], (s, s)), (x, 260 + (96 - s) // 2))
                x += s + 4
        sheet.save(args.sheet)


if __name__ == "__main__":
    main()
