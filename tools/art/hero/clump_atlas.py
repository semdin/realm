"""The clump atlas for groomed hair cards (hair_cards.py, `method: envelope`).

  python clump_atlas.py <out.png> [--preview <preview.png>]

What the first atlas (strand_atlas.py) got wrong, seen on light hair close
up: every lock was a solid block that ran to a single point, so each card
ended in a V (a sawtooth along the nape and the temples, "straw" on top),
and every strand had its own brightness (stripes). Here a column is one card
type drawn root (top row) -> tip (bottom row) as CLUMPS of fine strands:

- strands are 1-1.5 px wide (a hair is ~0.07 mm; a 2 cm card over 256 px is
  0.08 mm a pixel), so a card reads as hair, not as a painted ribbon;
- a clump narrows only a little toward its end and its strands END at
  staggered lengths over the last third, each one thinning to its own tip:
  the card's end is a soft fringe of hair ends, never a cut or a point;
- brightness varies by clump (R: the clump's id plus a little per strand),
  so the hair shades in locks;
- strands overlap in depth: B is a strand's depth (0 under .. 1 on top), the
  shader darkens the deep ones (self-shadow inside a card);
- roots fade in over the first few per cent (the root row is never a line).

Channels: R clump/strand id, G across the clump (1 its middle .. 0 its
edges: round shading), B depth, A coverage (4x supersampled).
Deterministic (seeded).
"""
import sys
import math
import numpy as np

W, H = 2048, 1024
SS = 4
N = 72                       # points per strand
# name, then: clumps, clump width (share of the column), strands per clump,
# strand width px, clump end width (share of its width), clump lengths
# (range), wave px, strays, root fade. Clumps are narrow and overlap; each
# tapers toward its own end at its own length, so a card's end is many small
# ragged points (hair ends), its sides thin out strand by strand.
COLUMNS = [
    # the mass: wide, nearly opaque cards that hide the scalp
    ("mass_a", dict(clumps=7, cw=0.26, per=95, wpx=1.35, end_w=0.4, clen=(0.62, 1.0), wave=3.0, strays=3, root=0.06)),
    ("mass_b", dict(clumps=6, cw=0.3, per=110, wpx=1.35, end_w=0.35, clen=(0.58, 1.0), wave=4.0, strays=3, root=0.06)),
    # clumps with gaps toward the ends: the outer layers' locks
    ("clump_a", dict(clumps=4, cw=0.3, per=110, wpx=1.3, end_w=0.3, clen=(0.6, 1.0), wave=5.0, strays=4, root=0.05)),
    ("clump_b", dict(clumps=3, cw=0.36, per=130, wpx=1.3, end_w=0.28, clen=(0.65, 1.0), wave=6.0, strays=4, root=0.05)),
    # one defined lock (the top's surface pieces) with two thin side locks
    ("lock", dict(clumps=3, cw=0.3, per=120, wpx=1.3, end_w=0.25, clen=(0.7, 1.0), wave=6.0, strays=3, root=0.05,
                  main=1)),
    # sparse fine hair: the hairline, the part, the edges
    ("fine", dict(clumps=8, cw=0.12, per=16, wpx=1.1, end_w=0.6, clen=(0.45, 1.0), wave=4.0, strays=6, root=0.12)),
    # short hair: the sides and the nape, ends all down the card (a taper)
    ("short", dict(clumps=8, cw=0.18, per=55, wpx=1.2, end_w=0.4, clen=(0.4, 1.0), wave=2.0, strays=3, root=0.04)),
    # loose strands
    ("strays", dict(clumps=0, cw=0.0, per=0, wpx=1.15, end_w=1.0, clen=(0.6, 1.0), wave=10.0, strays=12, root=0.1)),
]
COL_W = W // len(COLUMNS)


def column(rng, ci, spec):
    """The column's strands: (xs, ys, end, crown, id, width, start, depth)."""
    name, c = spec
    x0 = ci * COL_W
    t = np.linspace(0.0, 1.0, N)
    items = []
    clumps, cw, per, wpx = c["clumps"], c["cw"], c["per"], c["wpx"]
    if clumps:
        # clump centres spread over the column with jitter; the edge clumps
        # keep clear of the column's sides (filtering bleeds)
        margin = COL_W * (0.05 + cw / 2)
        cs = np.linspace(x0 + margin, x0 + COL_W - margin, clumps) if clumps > 1 else np.array([x0 + COL_W / 2])
        cs = cs + rng.normal(0, COL_W * cw * 0.12, clumps)
        for k, cx in enumerate(cs):
            main = c.get("main") is not None and k == c["main"]
            cid = rng.uniform(0.25, 0.75)
            phase = rng.uniform(0, 2 * math.pi)
            freq = rng.uniform(0.6, 1.3)
            drift = rng.normal(0, COL_W * 0.025)
            centre = cx + drift * t * t + np.sin(t * math.pi * freq + phase) * c["wave"] * t
            cl = rng.uniform(*c["clen"]) if not main else 1.0
            # the clump narrows toward its own end
            u = np.clip(t / cl, 0, 1)
            half = COL_W * cw / 2 * (1.0 - (1.0 - c["end_w"]) * np.clip((u - 0.3) / 0.7, 0, 1) ** 1.3)
            n_str = int(per * (1.6 if main else 1.0))
            # strands crowd the clump's middle: its sides thin out
            offs = np.clip(rng.normal(0, 0.45, n_str), -1, 1)
            for s_ in offs:
                end = cl * (1.0 - 0.4 * rng.random() ** 2.5 - 0.25 * abs(s_) * rng.random())
                xs = centre + s_ * half + rng.normal(0, 0.5) * t + np.sin(t * math.pi * rng.uniform(2, 4) + rng.uniform(0, 6.3)) * rng.uniform(0, 0.7)
                start = rng.uniform(0.0, c["root"]) ** 1.5
                sid = np.clip(cid + rng.normal(0, 0.07), 0, 1)
                items.append((xs, t * (H - 1), min(end, 1.0), 1.0 - s_ * s_, sid, wpx * rng.uniform(0.85, 1.15), start,
                              rng.random()))
    for _ in range(c["strays"]):
        xr = x0 + COL_W * rng.uniform(0.12, 0.88)
        phase = rng.uniform(0, 2 * math.pi)
        amp = rng.uniform(3.0, c["wave"] * 1.5 + 4.0)
        xs = xr + np.sin(t * math.pi * rng.uniform(0.8, 1.8) + phase) * amp * t + rng.normal(0, COL_W * 0.08) * t * t
        items.append((xs, t * (H - 1), rng.uniform(0.55, 1.0), 0.6, rng.uniform(0.3, 0.9), wpx * 0.9,
                      rng.uniform(0.0, 0.25), 1.0))
    return items


def build(seed=23):
    from PIL import Image, ImageDraw
    rng = np.random.default_rng(seed)
    layers = {k: Image.new("L", (W * SS, H * SS), 0) for k in ("cov", "id", "crown", "depth")}
    draw = {k: ImageDraw.Draw(im) for k, im in layers.items()}
    items = []
    for ci, spec in enumerate(COLUMNS):
        items += column(rng, ci, spec)
    # deep strands first: the top ones win the texel
    items.sort(key=lambda it: it[7])
    for xs, ys, end, crown, sid, wpx, start, depth in items:
        i0 = int(start * (N - 1))
        i1 = max(i0 + 2, int(math.ceil(end * (N - 1))))
        i1 = min(i1, N - 1)
        span = max(1e-6, (i1 - i0) / (N - 1))
        for i in range(i0, i1):
            u = (i - i0) / max(1, i1 - i0)
            # in from the root over 8 % of its length, thinning to its own
            # tip over the last 25 %
            fin = min(1.0, (u + 0.02) / 0.08)
            fout = 1.0 if u < 0.75 else max(0.0, 1.0 - (u - 0.75) / 0.25)
            f = fin * fout
            w = max(1, int(round(wpx * SS * (0.35 + 0.65 * fout))))
            a = int(round(255 * min(1.0, 0.25 + 0.75 * f) * (0.4 + 0.6 * fin)))
            seg = [(xs[i] * SS, ys[i] * SS), (xs[i + 1] * SS, ys[i + 1] * SS)]
            draw["cov"].line(seg, fill=a, width=w)
            draw["id"].line(seg, fill=int(sid * 255), width=w)
            draw["crown"].line(seg, fill=int(crown * 255), width=w)
            draw["depth"].line(seg, fill=int(depth * 255), width=w)
    c, i, g, d = (np.asarray(layers[k], np.float32) / 255.0 for k in ("cov", "id", "crown", "depth"))

    def down(a):
        return a.reshape(H, SS, W, SS).mean((1, 3))
    hitm = (c > 0).astype(np.float32)
    hit = down(hitm)
    out = np.zeros((H, W, 4), np.float32)
    for ch, src in ((0, i), (1, g), (2, d)):
        out[..., ch] = down(src * hitm) / np.maximum(hit, 1e-6)
    out[..., 3] = down(c)
    # outside the strands the nearest strand's values (grown), so filtering
    # at the coverage edge never pulls them toward 0
    hitb = hit > 0
    for _ in range(6):
        empty = ~hitb
        for ch in (0, 1, 2):
            a = out[..., ch]
            grown = np.maximum.reduce([np.roll(a, s, ax) for s in (-1, 1) for ax in (0, 1)])
            a[empty] = grown[empty]
        hitb = hitb | np.logical_or.reduce([np.roll(hitb, s, ax) for s in (-1, 1) for ax in (0, 1)])
    return out


def preview(a, path, hair=(0.62, 0.45, 0.27)):
    from PIL import Image
    shade = (0.75 + 0.25 * a[..., 1]) * (0.85 + 0.3 * a[..., 0]) * (0.7 + 0.3 * a[..., 2])
    rgb = np.stack([shade * hair[0], shade * hair[1], shade * hair[2]], -1)
    bg = np.array([0.12, 0.13, 0.15])
    img = rgb * a[..., 3:4] + bg * (1 - a[..., 3:4])
    Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).save(path)


if __name__ == "__main__":
    from PIL import Image
    out_path = sys.argv[1]
    atlas = build()
    Image.fromarray((np.clip(atlas, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA").save(out_path)
    print("[clumps] %s %dx%d, %d columns: %s" % (out_path, W, H, len(COLUMNS), [c[0] for c in COLUMNS]))
    for ci, c in enumerate(COLUMNS):
        a = atlas[:, ci * COL_W:(ci + 1) * COL_W, 3]
        print("[clumps]  %-8s coverage root half %.2f, tip quarter %.2f" % (c[0], a[: H // 2].mean(), a[3 * H // 4:].mean()))
    if "--preview" in sys.argv:
        preview(atlas, sys.argv[sys.argv.index("--preview") + 1])
