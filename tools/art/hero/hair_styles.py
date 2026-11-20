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
    """Away from the crown point, turning clockwise round it close to it."""
    q = np.asarray(q)
    away = q - CROWN
    dist = np.linalg.norm(away)
    around = np.cross(norm(q), norm(away))
    turn = 1.0 - smooth(0.05, 0.45, dist)
    return norm(norm(away) * (1.0 - 0.7 * turn) + around * 0.9 * turn)


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
            # short fine cards along the hairline: the edge ends in strands
            {"name": "hairline", "edge": True, "depth": 0.7, "spacing": 0.0055, "width": 0.009, "columns": [4, 5, 7],
             "offset": 0.0008, "length": 0.35, "lift": 0.1, "noise": 0.1, "twist": 0.05, "arc": 0.04},
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
            {"name": "hairline", "edge": True, "depth": 0.7, "spacing": 0.0055, "width": 0.009, "columns": [4, 5, 7],
             "offset": 0.0008, "length": 0.35, "lift": 0.1, "noise": 0.12, "twist": 0.08, "arc": 0.04},
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
}
