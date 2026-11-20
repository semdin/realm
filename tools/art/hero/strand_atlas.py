"""The hair-card strand atlas, shared by every hairstyle.

  python strand_atlas.py <out.png> [--preview <preview.png>]

Each column of the atlas is one card type, drawn root (top row) -> tip
(bottom row); a card (hair_cards.py) maps a column across its width.
A column holds LOCKS: groomed bunches of many parallel strands that taper
together to a point, the way hair reads in a game at the distance players
see it (a card of separate random strands read as frizz / straw). Inside a
lock the strands are evenly spread across its width and follow its centre
line, so they converge cleanly at the tip; a few strands end early.

Channels (game/assets/shaders/hero_hair_card.gdshaderinc):
  R  strand id: a random per strand (fine brightness and glint variation)
  G  where in its lock a strand lies: 1 on the lock's crown .. 0 at its
     edges (the shader shades each lock round, like a real bunch of hair)
  B  unused (1)
  A  coverage (4x supersampled, so edges are anti-aliased)

The types (COLUMNS): dense (3 overlapping locks: the volume that hides the
scalp), locks (2-3 separate locks), fine (thin, longer tapering locks for
the outer layer and the hairline), single (one lock: a loose piece), strays
(a few loose strands). Deterministic (seeded).
"""
import sys
import math
import numpy as np

W, H = 2048, 1024
SS = 4
# (name, locks, lock width as a share of the column, overlap, strands per lock,
#  strand width px, lock length range, bend px, strays)
COLUMNS = [
    ("dense_a", 3, 0.44, 0.18, 200, 2.0, (0.9, 1.0), 6.0, 4),
    ("dense_b", 2, 0.58, 0.16, 260, 2.0, (0.85, 1.0), 9.0, 4),
    ("locks_a", 2, 0.5, 0.06, 220, 1.9, (0.8, 1.0), 10.0, 5),
    ("locks_b", 3, 0.36, 0.04, 160, 1.9, (0.75, 1.0), 12.0, 5),
    ("fine_a", 2, 0.38, 0.0, 120, 1.7, (0.7, 1.0), 14.0, 6),
    ("fine_b", 3, 0.28, 0.0, 90, 1.6, (0.65, 1.0), 12.0, 6),
    ("single", 1, 0.6, 0.0, 200, 1.8, (0.85, 1.0), 16.0, 5),
    ("strays", 0, 0.0, 0.0, 0, 1.4, (0.6, 1.0), 20.0, 9),
]
COL_W = W // len(COLUMNS)
N = 64                       # points per strand


def _lock_profile(t, length):
    """Lock width (0..1) along t: full over the body, then a point."""
    u = np.clip(t / max(length, 1e-6), 0.0, 1.0)
    return 1.0 - 0.88 * np.clip((u - 0.5) / 0.5, 0.0, 1.0) ** 1.4


def column(rng, ci, spec, draw):
    name, locks, lock_w, overlap, strands, width, (lmin, lmax), bend, strays = spec
    cov, ids, prof = draw
    x0 = ci * COL_W
    t = np.linspace(0.0, 1.0, N)
    items = []
    if locks:
        # lock centres across the column, overlapping (or apart) by `overlap`
        span = locks * lock_w - (locks - 1) * overlap
        left = x0 + COL_W * (0.5 - span / 2)
        for k in range(locks):
            c = left + COL_W * (lock_w / 2 + k * (lock_w - overlap))
            length = rng.uniform(lmin, lmax)
            phase = rng.uniform(0, 2 * math.pi)
            centre = c + np.sin(t * math.pi * rng.uniform(0.7, 1.4) + phase) * bend * t
            half = COL_W * lock_w / 2 * _lock_profile(t, length)
            # strands spread evenly over the lock (edges drawn first, the
            # crown last: it lies on top)
            offs = np.sort(rng.uniform(-1.0, 1.0, strands))
            order = np.argsort(-np.abs(offs))
            for j in order:
                s = offs[j]
                # strands end unevenly: the lock's tip frays a little
                end = length * (1.0 - rng.uniform(0.0, 0.45) ** 1.3 * (0.3 + 0.7 * abs(s)))
                xs = centre + s * half + rng.normal(0, 0.25) * t
                start = rng.uniform(0.0, 0.14) ** 1.3
                items.append((xs, t * H, end, 1.0 - s * s, rng.uniform(), width * rng.uniform(0.85, 1.15), start))
    for _ in range(strays):
        xr = x0 + COL_W * rng.uniform(0.15, 0.85)
        phase = rng.uniform(0, 2 * math.pi)
        xs = xr + np.sin(t * math.pi * rng.uniform(1.0, 2.0) + phase) * bend * t
        items.append((xs, t * H, rng.uniform(lmin, lmax), 0.5, rng.uniform(), width * 0.8, rng.uniform(0.05, 0.2)))
    for xs, ys, end, crown, sid, wpx, start in items:
        n_end = max(2, int(end * (N - 1)))
        n_start = int(start * (N - 1))
        for i in range(n_start, n_end):
            u = (i - n_start) / max(1, n_end - n_start)
            # soft root over the first 10 %, the strand thins over its last 30 %
            fade = min(1.0, u / 0.1) * (1.0 if u < 0.7 else max(0.0, 1.0 - (u - 0.7) / 0.3))
            w = max(1, int(round(wpx * SS * (0.45 + 0.55 * fade))))
            a = int(round(255 * min(1.0, 0.35 + 0.65 * fade)))
            seg = [(xs[i] * SS, ys[i] * SS), (xs[i + 1] * SS, ys[i + 1] * SS)]
            cov.line(seg, fill=a, width=w)
            ids.line(seg, fill=int(sid * 255), width=w)
            prof.line(seg, fill=int(crown * 255), width=w)


def build(seed=11):
    from PIL import Image, ImageDraw
    rng = np.random.default_rng(seed)
    imgs = [Image.new("L", (W * SS, H * SS), 0) for _ in range(3)]
    draw = [ImageDraw.Draw(im) for im in imgs]
    for ci, spec in enumerate(COLUMNS):
        column(rng, ci, spec, draw)
    c, i, g = (np.asarray(im, np.float32) / 255.0 for im in imgs)

    def down(a):
        return a.reshape(H, SS, W, SS).mean((1, 3))
    hit = down((c > 0).astype(np.float32))
    out = np.zeros((H, W, 4), np.float32)
    out[..., 0] = down(i * (c > 0)) / np.maximum(hit, 1e-6)
    out[..., 1] = down(g * (c > 0)) / np.maximum(hit, 1e-6)
    out[..., 2] = 1.0
    out[..., 3] = down(c)
    # outside the strands the nearest strand's id / profile (grown), so
    # filtering at the coverage edge never pulls them toward 0
    for _ in range(4):
        empty = hit == 0
        for ch in (0, 1):
            a = out[..., ch]
            grown = np.maximum.reduce([np.roll(a, s, ax) for s in (-1, 1) for ax in (0, 1)])
            a[empty] = grown[empty]
        hit = np.maximum(hit, (np.maximum.reduce([np.roll(hit, s, ax) for s in (-1, 1) for ax in (0, 1)]) > 0))
    return out


# ---------------------------------------------------------------- lashes
# lash_atlas.png (build_head.py maps the lash strips onto it): the upper
# lashes in the top half, the lower ones in the bottom half, roots at the
# top of each half. Lashes taper from a thick root, the neighbours' tips
# gather in twos and threes (real lashes clump), a dense dark line runs
# along the roots (the lash line).
LASH_W, LASH_H = 1024, 512
LASH_HALVES = {   # name: (root row, longest tip row, lashes, root width px, length range)
    "upper": (8, 250, 150, 3.4, (0.55, 1.0)),
    "lower": (264, 400, 70, 2.4, (0.45, 1.0)),
}


def build_lashes(seed=5):
    from PIL import Image, ImageDraw
    rng = np.random.default_rng(seed)
    cov_img = Image.new("L", (LASH_W * SS, LASH_H * SS), 0)
    cov = ImageDraw.Draw(cov_img)
    for name, (r0, r1, count, w0, (lmin, lmax)) in LASH_HALVES.items():
        # evenly along the lid with a little jitter (random gaps read as bald spots)
        xs = np.sort(0.02 + 0.96 * (np.arange(count) + 0.5) / count + rng.normal(0, 0.35 / count, count)) * LASH_W
        # clumps: runs of 2-3 lashes whose tips meet
        tips = xs.copy()
        i = 0
        while i < count:
            n = int(rng.integers(1, 4))
            centre = xs[i:i + n].mean() + rng.normal(0, 3.0)
            tips[i:i + n] = xs[i:i + n] + (centre - xs[i:i + n]) * rng.uniform(0.5, 0.9)
            i += n
        for x, tx in zip(xs, tips):
            length = (r1 - r0) * rng.uniform(lmin, lmax)
            n_pts = 24
            t = np.linspace(0.0, 1.0, n_pts)
            bend = rng.normal(0, 2.0)
            px = x + (tx - x) * t ** 1.5 + bend * t * t
            py = r0 + length * t
            for k in range(n_pts - 1):
                w = max(1, int(round(w0 * SS * (1.0 - 0.8 * t[k]))))
                a = int(255 * (1.0 - 0.6 * t[k] ** 2))
                cov.line([(px[k] * SS, py[k] * SS), (px[k + 1] * SS, py[k + 1] * SS)], fill=a, width=w)
        # the lash line: the roots' dense dark band
        cov.rectangle([0, (r0 - 2) * SS, LASH_W * SS, (r0 + 3) * SS], fill=230)
    c = np.asarray(cov_img, np.float32) / 255.0
    c = c.reshape(LASH_H, SS, LASH_W, SS).mean((1, 3))
    out = np.zeros((LASH_H, LASH_W, 4), np.float32)
    out[..., :3] = 0.03
    out[..., 3] = c
    return out


if __name__ == "__main__":
    from PIL import Image
    out_path = sys.argv[1]
    atlas = build()
    Image.fromarray((np.clip(atlas, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA").save(out_path)
    print("[atlas] %s %dx%d, %d columns: %s" % (out_path, W, H, len(COLUMNS), [c[0] for c in COLUMNS]))
    if "--lashes" in sys.argv:
        lash_path = sys.argv[sys.argv.index("--lashes") + 1]
        Image.fromarray((np.clip(build_lashes(), 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA").save(lash_path)
        print("[atlas] %s %dx%d" % (lash_path, LASH_W, LASH_H))
    if "--preview" in sys.argv:
        prev = sys.argv[sys.argv.index("--preview") + 1]
        a = atlas
        shade = (0.55 + 0.45 * a[..., 1]) * (0.93 + 0.12 * a[..., 0])
        rgb = np.stack([shade * 0.42, shade * 0.28, shade * 0.18], -1)
        bg = np.array([0.82, 0.84, 0.86])
        img = rgb * a[..., 3:4] + bg * (1 - a[..., 3:4])
        Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).save(prev)
