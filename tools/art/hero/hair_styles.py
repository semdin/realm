"""Hairstyle definitions for hair_cards.py (one dict per style).

A style is data: where hair grows (the hairline: MakeHuman's scalp, trimmed),
which way it is combed (`flow`, a function of the point on the scalp), how
long it is there (`length`), and the card layers laid over the scalp. To add
a style: copy one, change these, run build_hair.sh <style> (README.md).

Head frame (metres, the hero's rest pose): +X the hero's left, -Y the face,
+Z up. Every function gets `q`, the point relative to the skull centre C
divided by the skull radius R (so |q| ~ 1 on the scalp), and returns
directions as world vectors (hair_cards.py projects them onto the scalp).
"""
import math
import numpy as np


def smooth(a, b, x):
    t = min(1.0, max(0.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


def norm(v):
    v = np.asarray(v, dtype=float)
    return v / max(np.linalg.norm(v), 1e-9)


# ---------------------------------------------------------------- SimpleParted
# A classic short side part: parted on the hero's left, the top combed across
# to the right and back with a soft lift at the front, short sides and back
# tapered to the nape.
PART_X = 0.30          # the part, in q.x (a bit left of the middle)


def parted_flow(q):
    x, y, z = q
    top = smooth(0.25, 0.6, z)
    front = smooth(-0.2, -0.75, y)            # toward the face
    # hair beside the part runs back along it (the part stays a thin line),
    # turning across the head further from it
    away = smooth(0.03, 0.3, abs(x - PART_X))
    if x < PART_X:
        # the big side: across to the right and back, the front swept back
        across = norm([-0.75, 0.55 + 0.25 * front, 0.05])
    else:
        # the small side: down toward the left ear and back
        across = norm([0.7, 0.45, -0.35])
    d_top = norm(norm([0.0, 1.0, 0.05]) * (1 - away) + across * away)
    # behind the crown there is no part: the hair falls away from the crown,
    # turning round it (a whorl) so the crown point is covered
    crown = smooth(0.2, 0.55, y)
    d_top = norm(d_top * (1 - crown) + whorl(q) * crown)
    # the sides: down and back over the ears
    side_sign = 1.0 if x > 0 else -1.0
    d_side = norm([0.15 * side_sign, 0.55, -1.0])
    # the back: down, a little in toward the nape's middle
    d_back = norm([-0.15 * x, 0.15, -1.0])
    back = smooth(0.1, 0.6, y)
    d_low = norm(d_side * (1 - back) + d_back * back)
    return norm(d_top * top + d_low * (1 - top))


def parted_length(q):
    x, y, z = q
    top = smooth(0.2, 0.65, z)
    front = smooth(-0.1, -0.7, y) * top
    nape = smooth(-0.35, -0.8, z)
    side = 0.022 - 0.008 * nape
    back = 0.036 - 0.022 * nape
    low = side + (back - side) * smooth(-0.1, 0.5, y)
    l_top = 0.068 + 0.014 * front
    return low + (l_top - low) * top


def parted_lift(q):
    """Extra height (m) the hair stands off the scalp mid-card: volume on top."""
    x, y, z = q
    top = smooth(0.3, 0.7, z)
    front = smooth(0.0, -0.7, y)
    return 0.001 + 0.012 * top + 0.006 * top * front


def parted_hairline(q):
    """1 where this style grows hair, 0 not (multiplies MakeHuman's scalp):
    a short-back-and-sides cut stops above the nape's bottom."""
    x, y, z = q
    return smooth(-0.95, -0.82, z)


def whorl(q):
    """Away from the crown point, turning clockwise round it close to it;
    right over it every lock lies the same way (backward), so the locks
    overlap the crown instead of all leaving it bare."""
    q = np.asarray(q)
    away = q - CROWN
    dist = np.linalg.norm(away)
    around = np.cross(norm(q), norm(away))
    turn = 1.0 - smooth(0.05, 0.45, dist)
    d = norm(norm(away) * (1.0 - 0.7 * turn) + around * 0.9 * turn)
    over = 1.0 - smooth(0.06, 0.2, dist)
    return norm(d * (1.0 - over) + np.array([0.15, 1.0, -0.3]) * over)


# ---------------------------------------------------------------- Tousled
# Textured and messy: the top pushed up and forward from the crown in loose
# pieces, a broken fringe over the forehead, short sides and back.
CROWN = np.array([0.0, 0.5, 0.82])


def tousled_flow(q):
    x, y, z = q
    top = smooth(0.15, 0.5, z)
    # away from the crown (turning round it), leaning forward; pieces turn
    # this way and that
    d = whorl(q)
    d = norm(d + np.array([0.0, -0.55, 0.0]))
    wob = math.sin(9.0 * x + 4.0 * y) * 0.55 + math.sin(6.0 * y - 7.0 * z + 1.3) * 0.35
    perp = norm(np.cross(np.asarray(q), d))
    d_top = norm(d + perp * wob)
    side_sign = 1.0 if x > 0 else -1.0
    d_side = norm([0.1 * side_sign, 0.35, -1.0])
    d_back = norm([-0.1 * x, 0.1, -1.0])
    back = smooth(0.1, 0.6, y)
    d_low = norm(d_side * (1 - back) + d_back * back)
    return norm(d_top * top + d_low * (1 - top))


def tousled_length(q):
    x, y, z = q
    top = smooth(0.15, 0.6, z)
    front = smooth(-0.1, -0.7, y) * top
    nape = smooth(-0.35, -0.8, z)
    side = 0.024 - 0.008 * nape
    back = 0.038 - 0.022 * nape
    low = side + (back - side) * smooth(-0.1, 0.5, y)
    l_top = 0.064 + 0.01 * front
    return low + (l_top - low) * top


def tousled_lift(q):
    x, y, z = q
    top = smooth(0.2, 0.65, z)
    return 0.001 + 0.019 * top


def overhang_short(q):
    """How far (m) hair may run past the hairline: a little over the
    forehead's top, hardly any at the sides and the nape."""
    x, y, z = q
    front = smooth(-0.3, -0.75, y) * smooth(0.1, 0.5, z)
    return 0.002 + 0.016 * front


def overhang_fringe(q):
    """The tousled fringe falls over the forehead."""
    x, y, z = q
    front = smooth(-0.2, -0.7, y) * smooth(0.0, 0.4, z)
    return 0.002 + 0.035 * front


# ---------------------------------------------------------------- shared
def full_hairline(q):
    """All of MakeHuman's scalp, the nape included (hair that grows long)."""
    return 1.0


def grow_flow(q):
    """How hair grows when nobody combs it: forward on the top from the
    crown's whorl, down and back at the sides, down at the back."""
    x, y, z = q
    top = smooth(0.15, 0.55, z)
    d_top = norm(whorl(q) + np.array([0.0, -0.4, 0.0]))
    side_sign = 1.0 if x > 0 else -1.0
    d_side = norm([0.12 * side_sign, 0.35, -1.0])
    d_back = norm([-0.1 * x, 0.12, -1.0])
    back = smooth(0.1, 0.6, y)
    d_low = norm(d_side * (1 - back) + d_back * back)
    return norm(d_top * top + d_low * (1 - top))


def no_overhang(q):
    return 0.002


# ---------------------------------------------------------------- Buzzed
# A buzz cut: 3-6 mm all over, drawn by the hair cap alone (as games do a
# buzz cut): no cards, no cost beyond the head's own texture.
def buzz_length(q):
    return 0.0055


# ---------------------------------------------------------------- Neat
# Short and tidy: the top combed straight back with a slight sweep to the
# right, short sides combed back, a clean tapered nape.
def neat_flow(q):
    x, y, z = q
    top = smooth(0.2, 0.6, z)
    d_top = norm([-0.18, 1.0, 0.12])
    crown = smooth(0.2, 0.55, y)
    d_top = norm(d_top * (1 - crown) + whorl(q) * crown)
    side_sign = 1.0 if x > 0 else -1.0
    d_side = norm([0.08 * side_sign, 0.75, -0.6])
    d_back = norm([-0.1 * x, 0.2, -1.0])
    back = smooth(0.1, 0.6, y)
    d_low = norm(d_side * (1 - back) + d_back * back)
    return norm(d_top * top + d_low * (1 - top))


def neat_length(q):
    x, y, z = q
    top = smooth(0.2, 0.65, z)
    front = smooth(-0.1, -0.7, y) * top
    nape = smooth(-0.35, -0.8, z)
    side = 0.018 - 0.006 * nape
    back = 0.026 - 0.014 * nape
    low = side + (back - side) * smooth(-0.1, 0.5, y)
    l_top = 0.052 + 0.01 * front
    return low + (l_top - low) * top


def neat_lift(q):
    x, y, z = q
    top = smooth(0.3, 0.7, z)
    front = smooth(0.0, -0.7, y)
    return 0.001 + 0.007 * top + 0.006 * top * front


# ---------------------------------------------------------------- Wavy
# Jaw-length waves: parted a little left of the middle, falling free from
# about the ears' top over the ears and the nape.
WAVY_PART = 0.18


def wavy_flow(q):
    x, y, z = q
    top = smooth(0.1, 0.5, z)
    away = smooth(0.03, 0.25, abs(x - WAVY_PART))
    sgn = -1.0 if x < WAVY_PART else 1.0
    across = norm([0.75 * sgn, 0.35, -0.45])
    d_top = norm(norm([0.0, 1.0, 0.0]) * (1 - away) + across * away)
    crown = smooth(0.25, 0.6, y)
    d_top = norm(d_top * (1 - crown) + whorl(q) * crown)
    side_sign = 1.0 if x > 0 else -1.0
    d_side = norm([0.15 * side_sign, 0.25, -1.0])
    d_back = norm([-0.05 * x, 0.1, -1.0])
    back = smooth(0.1, 0.6, y)
    d_low = norm(d_side * (1 - back) + d_back * back)
    return norm(d_top * top + d_low * (1 - top))


def wavy_length(q):
    x, y, z = q
    front = smooth(-0.2, -0.7, y)
    back = smooth(0.0, 0.6, y)
    return 0.12 + 0.045 * back - 0.03 * front * smooth(0.0, 0.5, z)


def wavy_lift(q):
    x, y, z = q
    return 0.002 + 0.01 * smooth(0.2, 0.7, z) * (0.25 + 0.75 * smooth(0.03, 0.22, abs(x - WAVY_PART)))


def ear_release(q):
    """Hair leaves the scalp from about the ears' top down."""
    x, y, z = q
    return -0.2 + 0.15 * smooth(0.2, 0.7, y)


def wavy_overhang(q):
    x, y, z = q
    return 0.002 + 0.03 * smooth(-0.2, -0.7, y) * smooth(-0.3, 0.3, z)


# ---------------------------------------------------------------- Long
# Shoulder length, parted in the middle: framing the face at the sides,
# falling down the back past the shoulders.
def long_flow(q):
    x, y, z = q
    top = smooth(0.0, 0.5, z)
    # beside the part the hair runs back along it, turning down the sides
    # further out (a wide fan left a bald V at the front); at the front the
    # locks sweep from the part to the sides at once, framing the forehead
    away = max(smooth(0.01, 0.14, abs(x)), smooth(-0.3, -0.75, y))
    sgn = 1.0 if x > 0 else -1.0
    across = norm([0.8 * sgn, 0.2, -0.5])
    d_top = norm(norm([0.0, 1.0, 0.0]) * (1 - away) + across * away)
    crown = smooth(0.3, 0.65, y)
    d_top = norm(d_top * (1 - crown) + norm([0.0, 0.6, -1.0]) * crown)
    d_low = norm([0.12 * sgn * smooth(0.4, -0.2, y), 0.15, -1.0])
    return norm(d_top * top + d_low * (1 - top))


def long_length(q):
    x, y, z = q
    front = smooth(0.0, -0.7, y)
    return 0.27 - 0.05 * front


def long_lift(q):
    x, y, z = q
    # flat along the part: lifted locks either side opened it into a V
    return 0.002 + 0.006 * smooth(0.2, 0.7, z) * (0.25 + 0.75 * smooth(0.03, 0.22, abs(x)))


def long_release(q):
    x, y, z = q
    return -0.05 + 0.1 * smooth(0.2, 0.7, y)


# ---------------------------------------------------------------- Ponytail
# Everything combed back tight to a tie behind the crown; the tail falls
# from it down the back.
TIE = np.array([0.0, 0.92, 0.05])


def pony_flow(q):
    q = np.asarray(q)
    to_tie = TIE / np.linalg.norm(TIE) - norm(q)
    return norm(to_tie + np.array([0.0, 0.05, 0.0]))


def pony_length(q):
    q = np.asarray(q)
    dist = np.linalg.norm(norm(q) - TIE / np.linalg.norm(TIE))
    return float(min(0.2, max(0.02, dist * 0.088 * 1.08)))


def pony_lift(q):
    return 0.001


# ---------------------------------------------------------------- Curly
# Short-to-medium curls with volume: every lock a loose spiral.
def curly_length(q):
    x, y, z = q
    top = smooth(0.1, 0.6, z)
    nape = smooth(-0.35, -0.8, z)
    low = 0.032 - 0.012 * nape
    return low + (0.062 - low) * top


def curly_lift(q):
    x, y, z = q
    return 0.003 + 0.016 * smooth(0.1, 0.65, z)


def curly_overhang(q):
    x, y, z = q
    return 0.004 + 0.02 * smooth(-0.2, -0.7, y) * smooth(0.0, 0.5, z)


# ---------------------------------------------------------------- beards
# Grown in the beard area (build_head.py zones, which keep the lips and the
# nose bare), trimmed to a real beard's lines here ("region": "beard").
# Measured on the head, in q: eyes z -0.22, nose tip -0.68, lips -0.92 ..
# -1.16 (corners |x| 0.32), chin -1.55, ears z -0.75 .. -0.17 at y -0.2 ..
# 0.15; the face is -y.
def beard_flow(q):
    x, y, z = q
    sgn = 1.0 if x > 0 else -1.0
    ax = abs(x)
    # cheeks and jaw: down, a little out; under the chin: back down the neck
    d = norm([0.25 * sgn * smooth(0.05, 0.45, ax), -0.1 + 0.7 * smooth(-1.4, -1.65, z), -1.0])
    # the moustache: from the philtrum out and down over the lip
    mo = smooth(-0.72, -0.8, z) * smooth(-0.98, -0.9, z) * smooth(0.45, 0.3, ax)
    d_mo = norm([sgn, -0.2, -0.8])
    return norm(d * (1 - mo) + d_mo * mo)


def beard_hairline(q):
    """A groomed beard's lines: the cheek line from just above the mouth's
    corner rising to the sideburn in front of the ear, the moustache under
    the nose, the neckline a finger under the jaw; densest on the chin and
    the moustache, lighter high on the cheeks."""
    x, y, z = q
    ax = abs(x)
    u = smooth(-1.25, -0.25, y)                 # 0 by the mouth .. 1 by the ear
    top = -0.84 + 0.28 * u + 0.36 * smooth(0.82, 0.97, u)
    top = max(top, -0.78) if ax < 0.36 else top  # the moustache under the nose
    cheek = smooth(top + 0.03, top - 0.16, z)
    neck = smooth(-2.12, -1.9, z)
    dens = cheek * neck
    return dens * (0.62 + 0.38 * max(smooth(-0.95, -1.3, z), smooth(0.4, 0.25, ax) * smooth(-0.74, -0.84, z)))


def stubble_length(q):
    return 0.0018


def short_beard_length(q):
    return 0.0055


def full_beard_length(q):
    x, y, z = q
    chin = smooth(-1.05, -1.4, z) * smooth(0.5, 0.15, abs(x))
    jaw = smooth(-0.95, -1.25, z)
    return 0.012 + 0.006 * jaw + 0.012 * chin


def beard_lift(q):
    """A full beard stands off the face: most on the chin and the jaw."""
    x, y, z = q
    return 0.002 + 0.006 * smooth(-0.95, -1.35, z)


def chin_release(q):
    """Beard hair leaves the face under the jaw line."""
    return -1.38


STYLES = {
    "SimpleParted": {
        "flow": parted_flow,
        "length": parted_length,
        "lift": parted_lift,
        "hairline": parted_hairline,
        "overhang": overhang_short,
        "gravity": 0.15,
        # card layers, inside out. spacing / width in metres; atlas columns
        # (strand_atlas.COLUMNS) picked at random per card; offset = height
        # over the scalp at the root; length = fraction of the local length
        "layers": [
            # the short sides and back: narrow dense cards lying flat on the
            # head, long enough to overlap (no card edge stands out)
            {"name": "sides", "spacing": 0.0068, "width": 0.012, "columns": [0, 1, 2], "offset": 0.0014,
             "length": 1.0, "lift": 0.0, "noise": 0.05, "twist": 0.0, "arc": 0.05, "max_z": 0.35},
            {"name": "base", "spacing": 0.010, "width": 0.024, "columns": [0, 1], "offset": 0.0025,
             "length": 0.85, "lift": 0.5, "noise": 0.05, "twist": 0.05, "arc": 0.12, "min_z": 0.2},
            {"name": "main", "spacing": 0.0125, "width": 0.022, "columns": [2, 3], "offset": 0.0055,
             "length": 1.0, "lift": 1.0, "noise": 0.06, "twist": 0.08, "arc": 0.16},
            {"name": "top", "spacing": 0.016, "width": 0.018, "columns": [2, 3, 6], "offset": 0.0085,
             "length": 1.0, "lift": 1.2, "noise": 0.08, "twist": 0.12, "arc": 0.18, "min_z": 0.0},
            {"name": "wisps", "spacing": 0.04, "width": 0.009, "columns": [6, 7], "offset": 0.01,
             "length": 0.9, "lift": 1.3, "noise": 0.15, "twist": 0.2, "arc": 0.08},
        ],
    },
    "Tousled": {
        "flow": tousled_flow,
        "length": tousled_length,
        "lift": tousled_lift,
        "hairline": parted_hairline,
        "overhang": overhang_fringe,
        "gravity": 0.25,
        "layers": [
            {"name": "sides", "spacing": 0.0068, "width": 0.012, "columns": [0, 1, 2], "offset": 0.0014,
             "length": 1.0, "lift": 0.0, "noise": 0.06, "twist": 0.0, "arc": 0.05, "max_z": 0.3},
            {"name": "base", "spacing": 0.010, "width": 0.024, "columns": [0, 1], "offset": 0.0025,
             "length": 0.8, "lift": 0.5, "noise": 0.08, "twist": 0.08, "arc": 0.12, "min_z": 0.15},
            {"name": "main", "spacing": 0.0125, "width": 0.021, "columns": [2, 3], "offset": 0.006,
             "length": 1.0, "lift": 1.0, "noise": 0.12, "twist": 0.15, "arc": 0.18},
            {"name": "top", "spacing": 0.015, "width": 0.017, "columns": [3, 4, 6], "offset": 0.009,
             "length": 1.0, "lift": 1.25, "noise": 0.18, "twist": 0.25, "arc": 0.2, "min_z": -0.1},
            {"name": "wisps", "spacing": 0.035, "width": 0.009, "columns": [6, 7], "offset": 0.011,
             "length": 0.9, "lift": 1.4, "noise": 0.25, "twist": 0.3, "arc": 0.08},
        ],
    },
    "Buzzed": {
        "flow": grow_flow,
        "length": buzz_length,
        "lift": pony_lift,
        "hairline": parted_hairline,
        "overhang": no_overhang,
        "gravity": 0.0,
        "cap_strands": 150000,
        "cap_max": 0.006,
        "layers": [],
    },
    "Neat": {
        "flow": neat_flow,
        "length": neat_length,
        "lift": neat_lift,
        "hairline": parted_hairline,
        "overhang": overhang_short,
        "gravity": 0.1,
        "layers": [
            {"name": "sides", "spacing": 0.0068, "width": 0.012, "columns": [0, 1, 2], "offset": 0.0013,
             "length": 1.0, "lift": 0.0, "noise": 0.03, "twist": 0.0, "arc": 0.05, "max_z": 0.35},
            {"name": "base", "spacing": 0.010, "width": 0.024, "columns": [0, 1], "offset": 0.0024,
             "length": 0.85, "lift": 0.5, "noise": 0.03, "twist": 0.03, "arc": 0.12, "min_z": 0.2},
            {"name": "main", "spacing": 0.0125, "width": 0.022, "columns": [2, 3], "offset": 0.005,
             "length": 1.0, "lift": 1.0, "noise": 0.04, "twist": 0.05, "arc": 0.15},
            {"name": "top", "spacing": 0.017, "width": 0.018, "columns": [2, 3], "offset": 0.0075,
             "length": 1.0, "lift": 1.15, "noise": 0.05, "twist": 0.08, "arc": 0.16, "min_z": 0.0},
        ],
    },
    "Wavy": {
        "cap_strands": 110000,
        "cap_max": 0.01,
        "flow": wavy_flow,
        "length": wavy_length,
        "lift": wavy_lift,
        "hairline": full_hairline,
        "overhang": wavy_overhang,
        "release": ear_release,
        "fall": 0.55,
        "gravity": 0.2,
        "wave": (0.0045, 0.05),
        "seg_len": 0.0135,
        "drop_skin": (1.62, 1.50),
        "far_layers": ["base", "main"],
        "layers": [
            {"name": "base", "spacing": 0.0105, "width": 0.026, "columns": [0, 1], "offset": 0.0025,
             "length": 0.85, "lift": 0.5, "noise": 0.06, "twist": 0.06, "arc": 0.12},
            {"name": "main", "spacing": 0.013, "width": 0.024, "columns": [2, 3], "offset": 0.0055,
             "length": 1.0, "lift": 1.0, "noise": 0.08, "twist": 0.1, "arc": 0.16},
            {"name": "top", "spacing": 0.018, "width": 0.02, "columns": [2, 3, 6], "offset": 0.008,
             "length": 1.0, "lift": 1.15, "noise": 0.1, "twist": 0.15, "arc": 0.18, "min_z": -0.1},
            {"name": "wisps", "spacing": 0.045, "width": 0.01, "columns": [6, 7], "offset": 0.01,
             "length": 0.95, "lift": 1.2, "noise": 0.18, "twist": 0.2, "arc": 0.08},
        ],
    },
    "Long": {
        "cap_strands": 110000,
        "cap_max": 0.01,
        "flow": long_flow,
        "length": long_length,
        "lift": long_lift,
        "hairline": full_hairline,
        "overhang": no_overhang,
        "release": long_release,
        "fall": 0.85,
        "gravity": 0.3,
        "wave": (0.002, 0.07),
        "seg_len": 0.016,
        "drop_skin": (1.62, 1.44),
        "far_layers": ["base", "main"],
        "layers": [
            {"name": "base", "spacing": 0.0135, "width": 0.03, "columns": [0, 1], "offset": 0.0025,
             "length": 0.9, "lift": 0.5, "noise": 0.04, "twist": 0.05, "arc": 0.12},
            {"name": "main", "spacing": 0.017, "width": 0.026, "columns": [2, 3], "offset": 0.005,
             "length": 1.0, "lift": 1.0, "noise": 0.05, "twist": 0.08, "arc": 0.15},
            {"name": "top", "spacing": 0.024, "width": 0.022, "columns": [2, 3, 6], "offset": 0.0075,
             "length": 1.0, "lift": 1.1, "noise": 0.07, "twist": 0.1, "arc": 0.16, "min_z": -0.2},
        ],
    },
    "Ponytail": {
        "flow": pony_flow,
        "length": pony_length,
        "lift": pony_lift,
        "hairline": full_hairline,
        "overhang": no_overhang,
        "fall": 0.9,
        "gravity": 0.0,
        "seg_len": 0.012,
        "drop_skin": (1.66, 1.50),
        "far_layers": ["base", "tail"],
        "layers": [
            {"name": "base", "spacing": 0.0095, "width": 0.022, "columns": [0, 1], "offset": 0.0015,
             "length": 1.0, "lift": 0.0, "noise": 0.02, "twist": 0.0, "arc": 0.06},
            {"name": "main", "spacing": 0.014, "width": 0.02, "columns": [2, 3], "offset": 0.003,
             "length": 1.0, "lift": 0.0, "noise": 0.03, "twist": 0.03, "arc": 0.08, "min_z": -0.3},
            {"name": "tail", "tail": [0.0, 0.92, 0.05], "count": 46, "radius": 0.017, "length": 0.2, "wraps": 9,
             "width": 0.032, "columns": [0, 1, 2, 3], "offset": 0.002, "lift": 0.0, "noise": 0.06, "twist": 0.25,
             "arc": 0.18, "depth": 0.8},
        ],
    },
    "Curly": {
        "flow": grow_flow,
        "length": curly_length,
        "lift": curly_lift,
        "hairline": parted_hairline,
        "overhang": curly_overhang,
        "gravity": 0.15,
        "curl": (0.0038, 0.02),
        "layers": [
            {"name": "sides", "spacing": 0.0085, "width": 0.014, "columns": [0, 1, 2], "offset": 0.0015,
             "length": 1.0, "lift": 0.2, "noise": 0.2, "twist": 0.2, "arc": 0.08, "max_z": 0.3},
            {"name": "base", "spacing": 0.0125, "width": 0.02, "columns": [0, 1], "offset": 0.003,
             "length": 0.85, "lift": 0.6, "noise": 0.25, "twist": 0.3, "arc": 0.12, "min_z": 0.15},
            {"name": "main", "spacing": 0.0155, "width": 0.018, "columns": [2, 3, 4], "offset": 0.007,
             "length": 1.0, "lift": 1.0, "noise": 0.3, "twist": 0.4, "arc": 0.16},
            {"name": "top", "spacing": 0.02, "width": 0.016, "columns": [3, 4, 6], "offset": 0.011,
             "length": 1.0, "lift": 1.2, "noise": 0.35, "twist": 0.5, "arc": 0.18, "min_z": 0.0},
        ],
    },
    "Beard_Stubble": {
        "normal_surface": 1.0,
        "region": "beard",
        "flow": beard_flow,
        "length": stubble_length,
        "lift": pony_lift,
        "hairline": beard_hairline,
        "overhang": no_overhang,
        "gravity": 0.0,
        "cap_strands": 110000,
        "cap_max": 0.0022,
        # the beard's shadow under the skin carries a stubble; its strands
        # are fine dark points over it
        "cap_shadow": 0.55,
        "cap_alpha": 0.55,
        "layers": [],
    },
    "Beard_Short": {
        "normal_surface": 1.0,
        "region": "beard",
        "flow": beard_flow,
        "length": short_beard_length,
        "lift": pony_lift,
        "hairline": beard_hairline,
        "overhang": no_overhang,
        "gravity": 0.0,
        "cap_strands": 170000,
        "cap_max": 0.006,
        "cap_shadow": 0.8,
        "cap_alpha": 0.85,
        "layers": [],
    },
    "Beard_Full": {
        "normal_surface": 1.0,
        "region": "beard",
        "flow": beard_flow,
        "length": full_beard_length,
        "lift": beard_lift,
        "hairline": beard_hairline,
        "overhang": no_overhang,
        "gravity": 0.2,
        "wave": (0.0015, 0.014),
        "min_card": 0.008,
        # the face of the beard is drawn on the skin: long dense strands over
        # its full shadow; cards only give the jaw's underside and the chin
        # their volume in silhouette (cards over the cheeks and the mouth
        # read as flakes where they end)
        "cap_strands": 300000,
        "cap_max": 0.015,
        "cap_shadow": 0.96,
        "cap_alpha": 1.0,
        "dense": 0.45,
        "edge_w": 0.45,
        "edge_fade": (0.35, 0.75),
        "band_jitter": 0.2,
        "far_layers": ["under"],
        "layers": [
            {"name": "under", "spacing": 0.0052, "width": 0.009, "columns": [2, 3], "offset": 0.0015,
             "length": 1.1, "lift": 0.7, "noise": 0.1, "twist": 0.08, "arc": 0.12, "depth": 0.8, "max_z": -1.0,
             "root_fade": 0.55, "lift_start": 0.3},
            {"name": "wisps", "spacing": 0.0075, "width": 0.0065, "columns": [4, 6], "offset": 0.0035,
             "length": 1.15, "lift": 1.0, "noise": 0.16, "twist": 0.15, "arc": 0.1, "depth": 1.0, "max_z": -1.05,
             "root_fade": 0.55, "lift_start": 0.35},
        ],
    },
}
