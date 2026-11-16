"""Paints the castle clock tower's dial (game/assets/maps/grounds/clock_dial.png).

    python tools/art/clock_dial.py

RGB is the dial's colour: a dark iron bezel, an aged cream enamel chapter ring
between two inked rings carrying the minute track and the twelve Roman
numerals (Literata, the game's one font, set radially), and a warmer inner
field with a faint guilloche of concentric rings. Alpha is where the dial
glows when it is lit from behind at night: the enamel (1), never the ink or
the iron (0). Outside the bezel alpha is 0 too; the face shader cuts the dial
out at the bezel's edge (the stone plaque shows round it). The hands are not
painted: clock_face.gdshader draws them from the realm's hour.
"""

import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "game/assets/maps/grounds/clock_dial.png"
FONT = ROOT / "game/assets/fonts/Literata-Variable.ttf"
N = 1024
SS = 2  # supersampling for the ink

IRON = (38, 34, 32)
INK = (44, 36, 30)
ENAMEL = (232, 222, 196)
FIELD = (220, 205, 170)
NUMERALS = ["XII", "I", "II", "III", "IIII", "V", "VI", "VII", "VIII", "IX", "X", "XI"]


def value_noise(n: int, cells: int, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    grid = rng.random((cells + 1, cells + 1))
    grid[-1, :] = grid[0, :]
    grid[:, -1] = grid[:, 0]
    t = np.linspace(0, cells, n, endpoint=False)
    i = t.astype(int)
    f = t - i
    f = f * f * (3 - 2 * f)
    a = grid[i][:, i]
    b = grid[i][:, i + 1]
    c = grid[i + 1][:, i]
    d = grid[i + 1][:, i + 1]
    fx = f[None, :]
    fy = f[:, None]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def main() -> None:
    size = N * SS
    c = size / 2
    yy, xx = np.mgrid[0:N, 0:N].astype(np.float32)
    r = np.hypot(xx - N / 2 + 0.5, yy - N / 2 + 0.5) / (N / 2)
    # aged enamel: low-frequency staining and a little grime toward the rim
    stain = 0.6 * value_noise(N, 6, 3) + 0.3 * value_noise(N, 17, 5) + 0.1 * value_noise(N, 53, 7)
    base = np.zeros((N, N, 3), np.float32)
    field = np.array(FIELD, np.float32)
    enamel = np.array(ENAMEL, np.float32)
    base[:] = enamel
    inner = r < 0.6
    base[inner] = field
    # guilloche: fine concentric rings in the inner field
    rings = 0.5 + 0.5 * np.cos(r * 2 * math.pi * 38)
    base[inner] *= (0.965 + 0.035 * rings[inner])[:, None]
    base *= (0.86 + 0.14 * stain)[:, :, None]
    base *= (1.0 - 0.18 * np.clip((r - 0.8) / 0.12, 0, 1))[:, :, None]
    glow = np.where(r < 0.9, 1.0, 0.0).astype(np.float32)
    glow *= 0.85 + 0.15 * stain

    # ink and iron, supersampled
    ink = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(ink)

    def ring(radius: float, width: float) -> None:
        ro = radius * c
        d.ellipse([c - ro, c - ro, c + ro, c + ro], outline=255, width=max(1, int(width * c)))

    ring(0.905, 0.012)
    ring(0.62, 0.008)
    ring(0.6, 0.004)
    ring(0.865, 0.004)
    # minute track between 0.865 and 0.905, five-minute marks heavier
    for k in range(60):
        a = k / 60 * 2 * math.pi
        heavy = k % 5 == 0
        r0, r1 = (0.84, 0.905) if heavy else (0.865, 0.905)
        w = 0.016 if heavy else 0.006
        sa, ca = math.sin(a), math.cos(a)
        p0 = (c + sa * r0 * c, c - ca * r0 * c)
        p1 = (c + sa * r1 * c, c - ca * r1 * c)
        d.line([p0, p1], fill=255, width=max(1, int(w * c)))
    # Roman numerals, set radially (their foot toward the centre)
    font = ImageFont.truetype(str(FONT), int(0.16 * c))
    try:
        font.set_variation_by_axes([600])
    except Exception:
        pass
    for k, text in enumerate(NUMERALS):
        a = k / 12 * 360.0
        tile = Image.new("L", (int(0.5 * c), int(0.3 * c)), 0)
        td = ImageDraw.Draw(tile)
        bbox = td.textbbox((0, 0), text, font=font)
        tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
        td.text(((tile.width - tw) / 2 - bbox[0], (tile.height - th) / 2 - bbox[1]), text, fill=255, font=font)
        rot = tile.rotate(-a, resample=Image.BICUBIC, expand=True)
        rad = 0.73 * c
        cx = c + math.sin(math.radians(a)) * rad
        cy = c - math.cos(math.radians(a)) * rad
        ink.paste(255, (int(cx - rot.width / 2), int(cy - rot.height / 2)), rot)
    ink = ink.resize((N, N), Image.LANCZOS).filter(ImageFilter.GaussianBlur(0.4))
    ink_a = np.asarray(ink, np.float32) / 255.0

    col = base * (1 - ink_a[:, :, None]) + np.array(INK, np.float32) * ink_a[:, :, None]
    glow *= 1 - ink_a
    # the iron bezel: a rolled rim with a highlight on its upper left
    bez = np.clip((r - 0.915) / 0.01, 0, 1) * np.clip((1.0 - r) / 0.01, 0, 1)
    ang = np.arctan2(yy - N / 2, xx - N / 2)
    shade = 0.75 + 0.35 * np.cos(ang + math.pi * 0.75) * np.sin(np.clip((r - 0.915) / 0.085, 0, 1) * math.pi)
    iron = np.array(IRON, np.float32)[None, None, :] * shade[:, :, None] * (0.85 + 0.3 * stain[:, :, None])
    col = col * (1 - bez[:, :, None]) + iron * bez[:, :, None]
    glow *= 1 - bez
    alpha_out = np.clip((1.0 - r) / 0.004, 0, 1)
    glow *= alpha_out
    rgb = np.clip(col, 0, 255).astype(np.uint8)
    # outside the bezel: the colour of the bezel's edge (mips stay clean)
    a = np.clip(glow * 255, 0, 255).astype(np.uint8)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(np.dstack([rgb, a]), "RGBA").save(OUT, optimize=True)
    print(OUT, OUT.stat().st_size)


if __name__ == "__main__":
    main()
