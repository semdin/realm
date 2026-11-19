"""The Feast Hall's west window and the upper corridor's tapestry, drawn
procedurally for the realm (they replaced old-world heraldry and a borrowed
scene).

    python tools/art/castle_art.py [--out DIR]

Writes game/assets/castle/textures/stained_west.png (1856 x 2304, RGB) and
tapestry.jpg (1264 x 848), the sizes the castle glb's UVs were made for:

  stained_west  the window's 12 x 15 m opening (u along it, v down from the
                apex; the pointed head springs at v = 0.45). Leaded glass in
                the four house colours: a rose of four lobes in the head, each
                lobe a house animal in pale glass on its house's field, and four
                lancets below, one per house, each beside its house's banner
                (Torvan, Nisera, Ilvane, Velkar from the south), each a chain
                of pale lozenges on quarries of its
                colour inside a border of its metal. Every piece has its own
                shade and streaks; the cames between pieces are dark lead and
                darken the glass a little at its edges. The hall sees the
                glb's pane from behind its UVs (u runs south to north, to the
                right as one faces it), so the image is stored mirrored.
  tapestry      6 x 4 m of weave: four quarters in the houses' colours, each
                with its animal embroidered in metal thread, small flowers
                scattered over the cloth, a border of leaves and a fringe-less
                hem.

The animals and the colours are house_crests.py's (content/data/houses.json),
so a palette change is one edit there and one run of both scripts.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage
from scipy.spatial import cKDTree

import house_crests as hc

ROOT = Path(__file__).resolve().parents[2]
TEXTURES = ROOT / "game" / "assets" / "castle" / "textures"
ORDER = ["velkar", "nisera", "ilvane", "torvan"]
## The window's lancets from left to right as seen from the hall: each next
## to its house's banner on the dais wall (castle_feast.gd DAIS_BANNERS:
## Torvan and Nisera south of the window, Ilvane and Velkar north).
WINDOW_ORDER = ["torvan", "nisera", "ilvane", "velkar"]

## The window's pointed head as the glb draws it (u, v): springing to apex.
ARCH = [(0.0, 0.45), (0.0625, 0.269), (0.125, 0.198), (0.1875, 0.147), (0.25, 0.106), (0.3125, 0.073),
        (0.375, 0.044), (0.4375, 0.02), (0.5, 0.0)]


def lin(hexstr: str) -> np.ndarray:
    return hc.srgb_to_lin(hc.hexrgb(hexstr))


def houses() -> dict:
    return json.loads(hc.HOUSES.read_text(encoding="utf-8"))


def value_noise(h: int, w: int, sy: float, sx: float, seed: int) -> np.ndarray:
    """Smooth noise with cells `sy` x `sx` px (bicubic up from a random grid)."""
    rng = np.random.default_rng(seed)
    small = rng.random((max(2, int(h / sy) + 2), max(2, int(w / sx) + 2))).astype(np.float32)
    img = Image.fromarray((small * 255).astype(np.uint8)).resize((w, h), Image.BICUBIC)
    return np.asarray(img, dtype=np.float32) / 255.0


def voronoi(mask: np.ndarray, spacing: float, seed: int, stretch=(1.0, 1.0)) -> np.ndarray:
    """Cell index (from 1) of every pixel of `mask` on jittered grid seeds
    `spacing` px apart (0 outside); `stretch` (y, x) elongates the cells."""
    ys, xs = np.nonzero(mask)
    if ys.size == 0:
        return np.zeros(mask.shape, np.int32)
    rng = np.random.default_rng(seed)
    y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
    sy, sx = spacing * stretch[0], spacing * stretch[1]
    gy = np.arange(y0 - sy, y1 + sy, sy)
    gx = np.arange(x0 - sx, x1 + sx, sx)
    py, px = np.meshgrid(gy, gx, indexing="ij")
    pts = np.stack([py.ravel(), px.ravel()], 1)
    pts += (rng.random(pts.shape) - 0.5) * np.array([sy, sx]) * 0.85
    tree = cKDTree(pts / np.array([stretch[0], stretch[1]]))
    _, idx = tree.query(np.stack([ys / stretch[0], xs / stretch[1]], 1))
    out = np.zeros(mask.shape, np.int32)
    out[ys, xs] = idx + 1
    return out


# ----------------------------------------------------------------- window


class Glass:
    """Pieces of glass: a label per pixel and a linear colour per label."""

    def __init__(self, h: int, w: int):
        self.label = np.zeros((h, w), np.int64)
        self.colour: dict[int, np.ndarray] = {0: np.array([0.0, 0.0, 0.0])}
        self.next = 1

    def add(self, mask: np.ndarray, cells: np.ndarray | None, pick) -> None:
        """Pieces over `mask`: one per cell of `cells` (or one for the whole
        mask); `pick(k, cy, cx)` gives each its linear colour."""
        if cells is None:
            cells = mask.astype(np.int32)
        sub = np.where(mask, cells, 0)
        ids = np.unique(sub[sub > 0])
        if ids.size == 0:
            return
        centres = ndimage.center_of_mass(np.ones_like(sub), sub, ids)
        remap = np.zeros(int(sub.max()) + 1, np.int64)
        for k, (i, c) in enumerate(zip(ids, centres)):
            remap[i] = self.next
            self.colour[self.next] = pick(k, c[0], c[1])
            self.next += 1
        self.label = np.where(mask & (sub > 0), remap[sub], self.label)


def jitter(base: np.ndarray, rng: np.random.Generator, value=0.22, hue=0.08) -> np.ndarray:
    """`base` (linear) a little lighter or darker and a touch off in hue."""
    c = base * (1.0 + (rng.random() - 0.5) * 2.0 * value)
    c = c + (rng.random(3) - 0.5) * hue * float(base.max())
    return np.clip(c, 0.0, 1.0)


def pointed(cx: float, top: float, half: float, spring: float, xx, yy):
    """Inside a pointed (equilateral) arch of half-width `half` whose apex is
    at (cx, top) and whose sides spring at y = `spring`, straight below."""
    r = 2.0 * half
    left = (xx - (cx + half)) ** 2 + (yy - spring) ** 2 <= r * r
    right = (xx - (cx - half)) ** 2 + (yy - spring) ** 2 <= r * r
    head = (yy < spring) & left & right & (yy >= top)
    body = (yy >= spring) & (np.abs(xx - cx) <= half)
    return head | body


def west_window(w=1856, h=2304) -> Image.Image:
    hd = houses()
    rng = np.random.default_rng(1856)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    g = Glass(h, w)
    field = {k: lin(hd[k]["primary_color"]) for k in ORDER}
    metal = {k: lin(hd[k]["secondary_color"]) for k in ORDER}
    pale = lin("#efe3bd")
    amber = lin("#e0a83c")
    dusk = lin("#2b3a5c")

    # the opening: the pointed head over a straight-sided body
    au = np.array([p[0] for p in ARCH] + [1.0 - p[0] for p in reversed(ARCH[:-1])]) * w
    av = np.array([p[1] for p in ARCH] + [p[1] for p in reversed(ARCH[:-1])]) * h
    spring = 0.45 * h
    arch_y = np.interp(xx[0], au, av)
    opening = yy >= arch_y[None, :]
    frame = 34.0
    inner = ndimage.distance_transform_edt(opening) > frame

    # four lancets under the head, mullions between
    mullion = 44.0
    lw = (w - 2 * frame - 3 * mullion) / 4.0
    l_top = spring + 40.0
    l_spring = l_top + lw * 0.86
    lancets = []
    for i, key in enumerate(WINDOW_ORDER):
        cx = frame + lw * 0.5 + i * (lw + mullion)
        m = pointed(cx, l_top, lw * 0.5, l_spring, xx, yy) & (yy <= h - frame) & inner
        lancets.append((key, cx, m))
    # the rose in the head: a ring of 24 pieces round four lobes
    rcx, rcy, rr = w * 0.5, spring * 0.56, min(w * 0.235, spring * 0.47)
    dr = np.hypot(xx - rcx, yy - rcy)
    rose = (dr <= rr) & inner
    ring = rose & (dr > rr * 0.86)
    rim_stone = rose & (dr > rr * 0.83) & (dr <= rr * 0.86)
    lobe_r = rr * 0.33
    lobe_d = rr * 0.48
    lobes = []
    for k, key in enumerate(WINDOW_ORDER):
        # top-left, top-right, bottom-left, bottom-right: the lancets' order
        ang = math.radians((-135, -45, 135, 45)[k])
        lx, ly = rcx + math.cos(ang) * lobe_d, rcy + math.sin(ang) * lobe_d
        m = (np.hypot(xx - lx, yy - ly) <= lobe_r) & rose & ~ring & ~rim_stone
        lobes.append((key, lx, ly, m))
    boss = (dr <= rr * 0.11) & rose

    # spandrels of the head round the rose and over the lancets: dusk quarries
    spandrel = inner & ~rose & ~np.any([m for _, _, m in lancets], axis=0) & (yy < l_spring + 1)
    cells = voronoi(spandrel, 58.0, 11)
    house_dark = [field[k] * 0.35 + dusk * 0.5 for k in ORDER]
    g.add(spandrel, cells, lambda k, cy, cx: jitter(house_dark[rng.integers(4)] if rng.random() < 0.22 else dusk, rng, 0.3))

    # the rose: ring, lobes with their animals, the ground between, the boss
    ang_map = (np.degrees(np.arctan2(yy - rcy, xx - rcx)) + 360.0) % 360.0
    seg = (ang_map / 15.0).astype(np.int32) + 1
    g.add(ring, seg, lambda k, cy, cx: jitter(metal[ORDER[k % 4]] * 0.85 if k % 2 == 0 else field[ORDER[(k // 2) % 4]], rng, 0.15))
    between = rose & ~ring & ~rim_stone & ~np.any([m for *_, m in lobes], axis=0) & ~boss
    g.add(between, voronoi(between, 52.0, 12), lambda k, cy, cx: jitter(dusk * 1.3 if rng.random() < 0.7 else amber * 0.6, rng, 0.25))
    for key, lx, ly, m in lobes:
        side = int(lobe_r * 1.62)
        box = hc.fit_box(hc.ANIMALS[key](), 4.0)
        an = np.zeros((h, w), np.float32)
        y0, x0 = int(ly - side / 2), int(lx - side / 2)
        an[y0:y0 + side, x0:x0 + side] = hc.ANIMALS[key]().mask(side, box)
        animal = (an > 0.5) & m
        ground = m & ~animal
        g.add(ground, voronoi(ground, 46.0, 13 + len(g.colour)), lambda k, cy, cx, f=field[key]: jitter(f, rng, 0.2))
        # the animal in two or three pieces of pale glass (leads cut across it)
        g.add(animal, voronoi(animal, side * 0.42, 17), lambda k, cy, cx: jitter(pale, rng, 0.08, 0.04))
    g.add(boss, None, lambda k, cy, cx: amber)

    # the lancets: a border of the house's metal, a chain of pale lozenges,
    # quarries of the house's colour
    for i, (key, cx, m) in enumerate(lancets):
        half = lw * 0.5
        lx = np.abs(xx - cx)
        border = m & (lx > half - 30.0)
        # the border in short lengths, alternating metal and deep house colour
        bseg = ((yy - l_top) / 58.0).astype(np.int32) * 2 + (xx > cx) + 1
        g.add(border, bseg, lambda k, cy, cx_, key=key: jitter(metal[key] * 0.8 if (int(cy / 58.0) % 2) else field[key] * 0.45, rng, 0.15))
        period = 330.0
        ly = (yy - l_spring + period * 0.25) % period - period * 0.5
        loz = m & ~border & (lx / (half * 0.62) + np.abs(ly) / (period * 0.44) <= 1.0) & (yy > l_spring - 60)
        jewel = loz & (lx / (half * 0.25) + np.abs(ly) / (period * 0.17) <= 1.0)
        rest = loz & ~jewel
        g.add(rest, voronoi(rest, 64.0, 20 + i, (1.6, 1.0)), lambda k, cy, cx_: jitter(pale * 0.9, rng, 0.12, 0.05))
        g.add(jewel, ndimage.label(jewel)[0], lambda k, cy, cx_: jitter(amber, rng, 0.1))
        quarry = m & ~border & ~loz
        g.add(quarry, voronoi(quarry, 60.0, 30 + i, (1.35, 1.0)), lambda k, cy, cx_, key=key: jitter(field[key], rng, 0.28, 0.1))

    # stone where no glass was laid: the frame, the mullions, the rose's bar
    glass = g.label > 0
    # leads: every boundary between pieces, and glass meets stone
    lab = np.where(glass, g.label, -1)
    edge = np.zeros((h, w), bool)
    edge[:, 1:] |= lab[:, 1:] != lab[:, :-1]
    edge[1:, :] |= lab[1:, :] != lab[:-1, :]
    lead = ndimage.binary_dilation(edge, iterations=3)
    # every piece's colour, its streaks, a darker rim at its leads
    lut = np.zeros((g.next, 3), np.float32)
    for k, c in g.colour.items():
        lut[k] = c
    col = lut[np.clip(g.label, 0, g.next - 1)]
    streak = value_noise(h, w, 46.0, 3.0, 5) * 0.55 + value_noise(h, w, 9.0, 9.0, 6) * 0.45
    seeds = value_noise(h, w, 2.5, 2.5, 7)
    col *= (0.78 + 0.4 * streak)[..., None] * (0.94 + 0.08 * (seeds > 0.82))[..., None]
    to_lead = ndimage.distance_transform_edt(~lead)
    col *= (0.62 + 0.38 * np.clip(to_lead / 14.0, 0.0, 1.0))[..., None]
    # dusk light behind: a little brighter up the window
    col *= (0.92 - 0.2 * (yy / h))[..., None]
    lead_col = np.array([0.012, 0.011, 0.01], np.float32) * (0.7 + 0.6 * value_noise(h, w, 4.0, 4.0, 8))[..., None]
    stone = np.array([0.022, 0.02, 0.019], np.float32)
    out = np.where(glass[..., None], np.where(lead[..., None], lead_col, col), stone)
    out = np.where(opening[..., None], out, stone)
    img = Image.fromarray((hc.lin_to_srgb(out) * 255 + 0.5).astype(np.uint8), "RGB")
    return img.transpose(Image.Transpose.FLIP_LEFT_RIGHT)


# ----------------------------------------------------------------- tapestry


def tapestry(w=1264, h=848) -> Image.Image:
    hd = houses()
    S = 2
    W, H = w * S, h * S
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    rng = np.random.default_rng(1264)
    # the weave: warp and weft threads, slubs, a soft sag
    weave = 0.5 + 0.25 * np.sin(xx * 2.0) * np.sin(yy * 2.0) + 0.25 * np.sin(yy * 1.0 + np.sin(xx * 0.31))
    slub = value_noise(H, W, 30.0, 6.0, 3)
    sag = 0.9 + 0.1 * np.sin(xx / W * math.tau * 3.0 + 0.4)
    shade = sag * (0.76 + 0.16 * weave + 0.14 * slub)
    # uneven dye: broad blotches over the whole cloth
    dye = 0.82 + 0.32 * value_noise(H, W, 160.0, 160.0, 4)
    border = 70 * S
    band = 14 * S
    ground = lin("#2c3324")
    col = np.broadcast_to(ground, (H, W, 3)).copy()
    # the four quarters, each in its house's colour, darkened like old dye
    gx = (xx - border) / (W - 2 * border)
    gy = (yy - border) / (H - 2 * border)
    inside = (gx >= 0) & (gx < 1) & (gy >= 0) & (gy < 1)
    q = (gx >= 0.5).astype(np.int32) + 2 * (gy >= 0.5).astype(np.int32)
    split = (np.abs(gx - 0.5) * (W - 2 * border) < band) | (np.abs(gy - 0.5) * (H - 2 * border) < band)
    for k, key in enumerate(ORDER):
        f = lin(hd[key]["primary_color"]) * 0.5
        m = inside & (q == k) & ~split
        col[m] = f[None, :] * dye[m][:, None]
    # small flowers strewn over the field (a millefleur): blots of thread
    petals = [lin(c) for c in ("#e9dcb0", "#d9a43a", "#c45a4a", "#7aa0d0", "#e6edf5")]
    for i in range(700):
        cy, cx = rng.random() * H, rng.random() * W
        r = (3.5 + rng.random() * 4.5) * S
        c = petals[rng.integers(len(petals))]
        for p in range(5):
            a = p * math.tau / 5 + rng.random()
            py, px = cy + math.sin(a) * r * 0.7, cx + math.cos(a) * r * 0.7
            y0, y1 = int(max(0, py - r * 0.5)), int(min(H, py + r * 0.5))
            x0, x1 = int(max(0, px - r * 0.5)), int(min(W, px + r * 0.5))
            if y1 <= y0 or x1 <= x0:
                continue
            sub = (yy[y0:y1, x0:x1] - py) ** 2 + (xx[y0:y1, x0:x1] - px) ** 2 <= (r * 0.45) ** 2
            col[y0:y1, x0:x1][sub] = c * 0.75
    # the split bands and the border: a woven metal-thread band and leaves
    gold = lin("#b88a3e")
    col[inside & split] = gold * 0.55
    edge = ~inside
    leaf = value_noise(H, W, 9.0, 9.0, 9)
    berry = value_noise(H, W, 3.0, 3.0, 10)
    col[edge] = np.where((leaf[edge] > 0.6)[:, None], lin("#4f6a2e") * 0.75,
                         np.where((berry[edge] > 0.86)[:, None], gold * 0.7, lin("#4a1f18") * 0.8))
    rim = (np.minimum(np.minimum(xx, W - 1 - xx), np.minimum(yy, H - 1 - yy)) < 10 * S) | \
          (np.abs(np.minimum(np.minimum(xx, W - 1 - xx), np.minimum(yy, H - 1 - yy)) - border) < 5 * S)
    col[rim] = gold * 0.6
    # each quarter's animal, embroidered in its house's metal
    qw, qh = (W - 2 * border) / 2, (H - 2 * border) / 2
    for k, key in enumerate(ORDER):
        side = int(min(qw, qh) * 0.86)
        box = hc.fit_box(hc.ANIMALS[key](), 3.0)
        m = hc.ANIMALS[key]().mask(side, box)
        cx = border + qw * (0.5 + (k % 2))
        cy = border + qh * (0.5 + (k // 2))
        y0, x0 = int(cy - side / 2), int(cx - side / 2)
        an = np.zeros((H, W), np.float32)
        an[y0:y0 + side, x0:x0 + side] = m
        if key == "torvan":
            tm = np.zeros((H, W), np.float32)
            tm[y0:y0 + side, x0:x0 + side] = hc.tusk().mask(side, box)
        an_h = ndimage.gaussian_filter(hc.bevel(an, side * 0.02, 0.6) * 0.6, 1.5)
        thread = hc.metal(hc.normals(an_h, side * 0.05), lin(hd[key]["secondary_color"]), 16.0)
        thread *= (0.85 + 0.15 * np.sin(yy * 1.6 + xx * 0.4))[..., None]
        sh = ndimage.gaussian_filter(np.roll(an, 4 * S, 0), 4 * S)
        col *= (1 - 0.4 * sh)[..., None]
        # a dark couched outline round the embroidery
        key_m = ndimage.binary_dilation(an > 0.5, iterations=3 * S) & ~(an > 0.5)
        col *= (1 - 0.7 * ndimage.gaussian_filter(key_m.astype(np.float32), S))[..., None]
        col = col * (1 - an[..., None]) + thread * an[..., None]
        if key == "torvan":
            col = col * (1 - tm[..., None]) + lin("#e9dfc6")[None, None, :] * 0.8 * tm[..., None]
    col *= shade[..., None]
    img = Image.fromarray((hc.lin_to_srgb(col) * 255 + 0.5).astype(np.uint8), "RGB")
    return img.resize((w, h), Image.LANCZOS)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="", help="write here instead of the game's folder (a preview)")
    args = ap.parse_args()
    out = Path(args.out) if args.out else TEXTURES
    out.mkdir(parents=True, exist_ok=True)
    west_window().save(out / "stained_west.png", optimize=True)
    print("made stained_west.png")
    tapestry().save(out / "tapestry.jpg", quality=90)
    print("made tapestry.jpg")


if __name__ == "__main__":
    main()
