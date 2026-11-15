"""The launcher's background, drawn from noise (no generated art, no franchise
look): a night over Kaf's hills - a deep teal-to-ink sky with drifting mist
from layered value noise, a low warm glow on the horizon, embers rising
from it, and a vignette that keeps the launcher's text readable.

    python launcher/assets/make_background.py   -> launcher/assets/launcher_bg.jpg

Deterministic (fixed seed): the same file every time.
"""

from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

W, H = 1280, 714
rng = np.random.default_rng(1000)


def value_noise(scale: float, octaves: int) -> np.ndarray:
    """Fractal value noise in [0, 1], `scale` pixels per base cell."""
    out = np.zeros((H, W), np.float32)
    amp, total = 1.0, 0.0
    for o in range(octaves):
        cell = scale / (2**o)
        gh, gw = int(H / cell) + 2, int(W / cell) + 2
        grid = rng.random((gh, gw)).astype(np.float32)
        img = Image.fromarray((grid * 255).astype(np.uint8)).resize(
            (int(gw * cell), int(gh * cell)), Image.BICUBIC
        )
        out += np.asarray(img, np.float32)[:H, :W] / 255.0 * amp
        total += amp
        amp *= 0.5
    return out / total


y = np.linspace(0.0, 1.0, H, dtype=np.float32)[:, None]
x = np.linspace(0.0, 1.0, W, dtype=np.float32)[None, :]

# Sky: ink at the top, deep teal lower down.
top = np.array([6, 9, 16], np.float32)
low = np.array([14, 38, 46], np.float32)
sky = top + (low - top) * (y**1.4)[..., None]
img = np.broadcast_to(sky, (H, W, 3)).copy()

# Mist: two noise layers, thicker towards the horizon.
mist = value_noise(260, 5) * 0.65 + value_noise(90, 4) * 0.35
mist = np.clip((mist - 0.42) * 2.2, 0, 1) * (0.25 + 0.75 * y)
img += mist[..., None] * np.array([40, 72, 80], np.float32)

# Horizon glow, warm, off-centre to the right (the launcher's text sits left).
gx, gy = 0.66, 0.79
d = np.sqrt(((x - gx) * 1.6) ** 2 + ((y - gy) * 3.2) ** 2)
glow = np.exp(-(d**2) * 3.5)
img += glow[..., None] * np.array([170, 78, 24], np.float32)

# Embers rising from the glow: soft dots, warmer and brighter near it.
embers = np.zeros((H, W), np.float32)
for _ in range(220):
    ex = rng.normal(gx, 0.13) * W
    ey = H * (0.80 - rng.random() ** 0.8 * 0.70)
    if not (0 <= ex < W and 0 <= ey < H):
        continue
    r = 0.6 + rng.random() * 1.6
    b = (0.35 + rng.random() * 0.65) * (1.0 - ey / H * 0.2)
    x0, x1 = int(max(ex - 6, 0)), int(min(ex + 7, W))
    y0, y1 = int(max(ey - 6, 0)), int(min(ey + 7, H))
    yy, xx = np.mgrid[y0:y1, x0:x1]
    embers[y0:y1, x0:x1] += b * np.exp(-((xx - ex) ** 2 + (yy - ey) ** 2) / (2 * r * r))
ember_img = Image.fromarray(np.clip(embers * 255, 0, 255).astype(np.uint8))
halo = np.asarray(ember_img.filter(ImageFilter.GaussianBlur(4)), np.float32) / 255.0
img += embers[..., None] * np.array([255, 170, 80], np.float32)
img += halo[..., None] * np.array([120, 50, 10], np.float32)

# Hills: two ridgelines from 1-D noise, dark against the glow.
for base, amp, scale, shade in ((0.80, 0.08, 220, 0.30), (0.88, 0.06, 120, 0.12)):
    ridge = value_noise(scale, 3)[H // 2]  # one row of 2-D noise as a 1-D profile
    line = (base - amp * ridge) * H
    rows = np.arange(H, dtype=np.float32)[:, None]
    below = np.clip((rows - line[None, :]) / 3.0, 0, 1)
    img = img * (1 - below[..., None]) + (img * shade) * below[..., None]

# Stars, faint, only in the upper sky.
stars = (rng.random((H, W)) > 0.9993) * (1 - y) ** 2
img += stars[..., None] * np.array([150, 160, 175], np.float32)

# Vignette, heavier on the left where the launcher draws its text.
v = np.sqrt(((x - 0.6) * 1.1) ** 2 + ((y - 0.5) * 1.4) ** 2)
img *= np.clip(1.15 - v * 0.95, 0.25, 1.0)[..., None]
img *= (0.6 + 0.4 * np.clip(x * 1.6, 0, 1))[..., None]

out = Path(__file__).with_name("launcher_bg.jpg")
Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).save(out, quality=90)
print(out)
