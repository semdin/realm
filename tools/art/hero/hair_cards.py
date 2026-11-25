"""One hairstyle as hair cards on the hero's head.

  blender -b <work>/hero_head_work.blend --python hair_cards.py -- <style> <hair_out_dir> <work_dir>

<work_dir> is build_head.py's: its hero_head_work.blend (Face_Head on
GameRig), head_regions.npz (MakeHuman's scalp per head vertex) and
head_meta.json. Writes <hair_out_dir>/hair_<style>.glb (mesh Hair_<style>
skinned to the Head bone, with a shape key for every head key that moves the
scalp, so the hair follows the face types and the age slider) and
scalp_<style>.png (where the style covers the scalp, in the head's UV: the
skin shader paints short hair there so no bald skin shows between cards).

The style (hair_styles.STYLES) says where hair grows, which way it is
combed and how long it is; this script:
  1. samples card roots over the scalp per layer (Poisson disk, spacing per
     layer; thinner toward the hairline),
  2. grows each card's centre line along the flow, hugging the scalp at the
     layer's height (+ the style's lift: volume) - re-projected on the head
     every step, so cards never cut into it,
  3. sweeps a ribbon (3 verts across, the middle bowed outward) with the
     card's atlas column across it and root -> tip down it,
  4. writes the card data the shader reads: UV2 = (root..tip, layer),
     COLOR = (random, swing, occlusion), normals bent out of the skull
     (the hair lights as one volume).
Deterministic: the same style builds the same cards.
"""
import bpy
import sys
import os
import math
import json
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hair_styles  # noqa: E402
import strand_atlas  # noqa: E402
import clump_atlas  # noqa: E402
from bake_util import save_img, blur, raster  # noqa: E402

args = sys.argv[sys.argv.index('--') + 1:]
STYLE = args[0]
OUT = os.path.abspath(args[1])
WORK = os.path.abspath(args[2])
os.makedirs(OUT, exist_ok=True)
spec = hair_styles.STYLES[STYLE]
rng = np.random.default_rng(sum(ord(c) for c in STYLE) * 7919)
# the style's atlas: the clump atlas (groomed styles, `env_layers`) or the
# first strand atlas
N_COLUMNS = len(clump_atlas.COLUMNS if spec.get('atlas') == 'clumps' else strand_atlas.COLUMNS)
# the light / wispy columns (strand_atlas.COLUMNS) for cards on the hairline
EDGE_COLUMNS = [4, 5]
# the shortest card worth drawing (m)
MIN_CARD = 0.012


def log(*a):
    print('[hair]', *a, flush=True)


rig = bpy.data.objects['GameRig']
rig.data.pose_position = 'REST'
head = bpy.data.objects['Face_Head']
reg = np.load(os.path.join(WORK, 'head_regions.npz'))
REST = reg['rest'].astype(np.float64)
SCALP = reg['scalp']
# where this style grows: the scalp, or the beard area (build_head.py zones)
REGION = reg[spec.get('region', 'scalp')]
me = head.data
tris = []
for poly in me.polygons:
    v = list(poly.vertices)
    for k in range(1, len(v) - 1):
        tris.append((v[0], v[k], v[k + 1]))
tris = np.array(tris)
bvh = BVHTree.FromPolygons(REST.tolist(), tris.tolist())

# the skull: a sphere through MakeHuman's scalp
sp = REST[SCALP > 0.5]
A = np.c_[2 * sp, np.ones(len(sp))]
sol = np.linalg.lstsq(A, (sp ** 2).sum(1), rcond=None)[0]
C = sol[:3]
R = math.sqrt(sol[3] + C @ C)
log('skull centre', C.round(4), 'radius %.4f' % R, 'scalp verts', len(sp))


def q_of(p):
    return (np.asarray(p) - C) / R


def tangent(d, n):
    d = np.asarray(d) - n * (np.asarray(d) @ n)
    return d / max(np.linalg.norm(d), 1e-9)


def rotate(v, axis, ang):
    axis = axis / np.linalg.norm(axis)
    return v * math.cos(ang) + np.cross(axis, v) * math.sin(ang) + axis * (axis @ v) * (1 - math.cos(ang))


def nearest(p):
    loc, nrm, idx, dist = bvh.find_nearest(Vector(p))
    return np.array(loc), np.array(nrm), idx


def smooth(a, b, x):
    return hair_styles.smooth(a, b, x)


# ------------------------------------------------------------------ where hair grows
tri_p = REST[tris]
tri_area = 0.5 * np.linalg.norm(np.cross(tri_p[:, 1] - tri_p[:, 0], tri_p[:, 2] - tri_p[:, 0]), axis=1)
tri_w = REGION[tris].mean(1)
centres = tri_p.mean(1)
hairline = np.array([spec['hairline'](q_of(c)) for c in centres])
grow_w = tri_w * hairline
cand_n = 60000
prob = tri_area * (grow_w > 0.25)
prob /= prob.sum()
pick = rng.choice(len(tris), size=cand_n, p=prob)
r1, r2 = rng.random(cand_n), rng.random(cand_n)
s1 = np.sqrt(r1)
bary = np.stack([1 - s1, s1 * (1 - r2), s1 * r2], 1)
cand = (tri_p[pick] * bary[:, :, None]).sum(1)
cand_w = grow_w[pick]
log('scalp area %.4f m2, candidates %d' % ((tri_area * (grow_w > 0.25)).sum(), cand_n))


# inner layers grow where the scalp (or beard) weight is at least this; a
# beard's density is lower on the cheeks than a scalp's anywhere
DENSE = spec.get('dense', 0.7)
EDGE_W = spec.get('edge_w', 0.92)
BAND_JITTER = spec.get('band_jitter', 0.0)
# card normals: the head's surface normal (1) .. the skull's radial direction (0)
NORMAL_SURFACE = spec.get('normal_surface', 0.35)
# cards fade out over this band of scalp weight toward the hairline, leaving
# the edge to the hair cap (card tips ending on the temple drew square steps)
EDGE_FADE = (0.55, 0.97)


def poisson(spacing, min_z=None, edge=False, max_z=None, dense=None):
    cell = spacing / math.sqrt(3)
    grid = {}
    out = []
    order = rng.permutation(cand_n)
    for i in order:
        p = cand[i]
        if edge:
            # the hairline layer: only the band where the scalp fades out
            if not 0.15 < cand_w[i] < 0.85:
                continue
        elif cand_w[i] < (dense or DENSE) or rng.random() > smooth(dense or DENSE, (dense or DENSE) + 0.25, cand_w[i]):
            # the inner layers stay inside the hairline: their blunt card
            # sides on the edge read as torn paper
            continue
        # a layer's band edges are ragged (a straight root line read as a
        # cut edge across the face)
        if min_z is not None and q_of(p)[2] < min_z + rng.random() * BAND_JITTER:
            continue
        if max_z is not None and q_of(p)[2] > max_z - rng.random() * BAND_JITTER:
            continue
        key = tuple((p // cell).astype(int))
        ok = True
        for dx in (-2, -1, 0, 1, 2):
            for dy in (-2, -1, 0, 1, 2):
                for dz in (-2, -1, 0, 1, 2):
                    for j in grid.get((key[0] + dx, key[1] + dy, key[2] + dz), ()):
                        if np.sum((out[j] - p) ** 2) < spacing * spacing:
                            ok = False
                            break
                    if not ok:
                        break
                if not ok:
                    break
            if not ok:
                break
        if ok:
            grid.setdefault(key, []).append(len(out))
            out.append(p)
    return np.array(out)


# ------------------------------------------------------------------ the body (long hair falls over it)
body_parts = [o for o in bpy.data.objects if o.type == 'MESH' and o.name in ('Hero_Peasant_Body', 'Hero_Ranger_Body')]
body_v, body_f = [], []
for o in body_parts:
    off = len(body_v)
    body_v += [tuple(o.matrix_world @ v.co) for v in o.data.vertices]
    body_f += [tuple(i + off for i in poly.vertices) for poly in o.data.polygons]
body_bvh = BVHTree.FromPolygons(body_v, body_f) if body_v else None
DOWN = np.array([0.0, 0.0, -1.0])
MIN_CARD_STYLE = spec.get('min_card', MIN_CARD)


def keep_out(p, clear_head, clear_body):
    """p pushed out of the head / neck and the body by the clearances."""
    # only surfaces close by: the side a far point lies on, read from the
    # nearest face's normal, is not to be trusted (a point over the crown
    # was "inside" the shirt and jumped 20 cm down)
    loc, nrm, _i, dist = bvh.find_nearest(Vector(p))
    loc, nrm = np.array(loc), np.array(nrm)
    if dist < 0.03 and (p - loc) @ nrm < clear_head:
        p = loc + nrm * clear_head
    if body_bvh is not None:
        hit = body_bvh.find_nearest(Vector(p))
        if hit[0] is not None and hit[3] < 0.03:
            bl, bn = np.array(hit[0]), np.array(hit[1])
            if (p - bl) @ bn < clear_body:
                p = bl + bn * clear_body
    return p


# ------------------------------------------------------------------ cards
cards = []
n_layers = len(spec['layers'])
card_count = 0
release = spec.get('release')          # q -> the height (q.z) below which hair leaves the scalp
fall = spec.get('fall', 0.0)           # how fast free hair turns down (per 2 cm)
wave = spec.get('wave')                # (amplitude m, wavelength m)
curl = spec.get('curl')                # (radius m, period m)


def card_path(surf0, n0, d0, L, layer, lift, card_seed, overhang, free_from_start=False, tail_top=None):
    """The card's centre line: rows of (point, normal, direction), and how
    far it got before running past the hairline by more than the overhang
    (only while it walks the scalp). Over the scalp each row is re-projected
    onto it at the layer's height (the root on the skin, rising to the layer
    + the lift); where the style releases it (or from the start: a tail) it
    falls free - turning down with `fall`, kept clear of the head, the neck
    and the body."""
    crng = np.random.default_rng(card_seed)
    seg_len = spec.get('seg_len', 0.009) if curl is None else min(spec.get('seg_len', 0.009), curl[1] / 5)
    nseg = int(min(24, max(3, round(L / seg_len))))
    step = L / nseg
    surf, n, d = surf0, n0, d0
    free = free_from_start
    p = surf + n * (0.0006 if not free else 0.002)
    rows, outside, run = [(p, n, d)], 0.0, 0.0
    clear_free = layer['offset'] + 0.004
    for i in range(1, nseg + 1):
        t = i / nseg
        run += step
        if not free:
            target = surf + d * step + DOWN * spec['gravity'] * step * t
            s2, n2, ti = nearest(target)
            q2 = q_of(s2)
            if release is not None and q2[2] < release(q2):
                free = True
            else:
                if overhang is not None and grow_w[ti] < 0.3:
                    outside += step
                    if outside > overhang:
                        return rows, run - (outside - overhang)
                surf, n = s2, n2
                nd = tangent(spec['flow'](q2), n)
                d = tangent(0.7 * d + 0.3 * nd, n)
                d = rotate(d, n, crng.normal(0, layer['noise'] * 0.25))
                # `lift_start`: the card lies on the skin for that share of
                # its length before it rises (a beard's mass grows downward)
                ls = layer.get('lift_start', 0.0)
                h = 0.0006 + (layer['offset'] - 0.0006) * smooth(ls, ls + 0.25, t) \
                    + lift * smooth(ls, ls + 0.35, t) * (1.0 - 0.35 * t)
                p = surf + n * h
        if free:
            d = d + DOWN * fall * step / 0.02
            d = d / np.linalg.norm(d)
            d = rotate(d, DOWN, crng.normal(0, layer['noise'] * 0.15))
            p = keep_out(p + d * step, clear_free, 0.012)
            if tail_top is not None:
                radial = p - tail_top
            else:
                radial = np.array([p[0] - C[0], p[1] - C[1], 0.0])
            radial[2] = 0.0
            radial /= max(np.linalg.norm(radial), 1e-9)
            n = n * 0.5 + radial * 0.5
            n = n - d * (n @ d)
            n /= max(np.linalg.norm(n), 1e-9)
        rows.append((p, n, d))
    return rows, L


def ribbon(rows, L, layer, twist, width, phase, taper=0.5, width_profile=None):
    """The card's ribbon (3 vertices a row: the middle bowed outward), with
    the style's waves or curls laid on the centre line."""
    out_rows = []
    nseg = len(rows) - 1
    for i, (p, n, d) in enumerate(rows):
        t = i / nseg
        side = np.cross(n, d)
        side /= max(np.linalg.norm(side), 1e-9)
        side = rotate(side, d, twist * (0.4 + 0.6 * t))
        nrm = np.cross(d, side)
        dist = t * L
        ramp = smooth(0.0, 0.015, dist)
        if wave is not None:
            p = p + side * wave[0] * ramp * math.sin(2 * math.pi * dist / wave[1] + phase)
        if curl is not None:
            th = 2 * math.pi * dist / curl[1] + phase
            p = p + (side * math.cos(th) + nrm * math.sin(th)) * curl[0] * ramp
        w = width * (width_profile(t) if width_profile else (1.0 - taper * t))
        left, right = p - side * w / 2, p + side * w / 2
        mid = p + nrm * layer['arc'] * w
        fixed = [keep_out(e, 0.0008, 0.004) for e in (left, mid, right)]
        out_rows.append((fixed, t, p))
    return out_rows


def tail_profile(t):
    """A ponytail card: gathered at the tie, full in the middle, a point."""
    return 0.45 + 0.55 * math.sin(min(1.0, t * 1.4) * math.pi * 0.5) * (1.0 - 0.7 * smooth(0.6, 1.0, t))


for li, layer in enumerate(spec['layers']):
    # how deep in the hair the layer lies (0 under everything .. 1 on top);
    # the hairline layer is on the outside of the edge, never in shadow
    depth = layer.get('depth', li / max(1, n_layers - 1))
    if layer.get('tail'):
        # a ponytail: cards round the tie, falling from it
        tie_q = np.array(layer['tail'], dtype=float)
        tie_s, tie_n, _ = nearest(C + tie_q / np.linalg.norm(tie_q) * R * 1.3)
        e1 = np.cross(tie_n, DOWN)
        e1 /= np.linalg.norm(e1)
        e2 = np.cross(tie_n, e1)
        top = tie_s + tie_n * 0.006
        made = 0
        for k in range(layer['count']):
            a_ = 2 * math.pi * (k + rng.random() * 0.6) / layer['count']
            radial0 = e1 * math.cos(a_) + e2 * math.sin(a_)
            root = top + radial0 * layer['radius'] * rng.uniform(0.4, 1.0)
            d0 = tie_n * 0.6 + DOWN * 0.8 + radial0 * 0.15
            d0 /= np.linalg.norm(d0)
            L = layer['length'] * rng.uniform(0.75, 1.05)
            rows, _r = card_path(root, radial0, d0, L, layer, 0.0, int(rng.integers(1 << 30)), None,
                                 free_from_start=True, tail_top=top)
            col = int(rng.choice(layer['columns']))
            u0, u1 = col / N_COLUMNS, (col + 1) / N_COLUMNS
            built = ribbon(rows, L, layer, rng.normal(0, layer['twist']), layer['width'] * rng.uniform(0.85, 1.15),
                           rng.uniform(0, 2 * math.pi), width_profile=tail_profile)
            cards.append({'layer': layer['name'], 'rows': built, 'u': (u0, u1), 'depth': depth,
                          'rnd': float(rng.random()), 'flex': float(min(1.5, max(0.2, L / 0.07)))})
            made += 1
        # the tie: a lock wrapped round the tail's root (hair over the band,
        # the way it is tied), short cards running round it
        wraps = layer.get('wraps', 0)
        for k in range(wraps):
            rows = []
            a_start = 2 * math.pi * k / wraps
            for j in range(4):
                a_ = a_start + (2 * math.pi / wraps) * 1.35 * j / 3
                radial = e1 * math.cos(a_) + e2 * math.sin(a_)
                tangent_ = -e1 * math.sin(a_) + e2 * math.cos(a_)
                p_ = top + tie_n * 0.003 + radial * (layer['radius'] * 1.05)
                rows.append((p_, radial, tangent_))
            built = ribbon(rows, 0.02, layer, 0.0, 0.011, 0.0, taper=0.2)
            # the wrap's cards lie across the tie (no free fall, no collision push)
            cards.append({'layer': layer['name'], 'rows': built, 'u': (2 / N_COLUMNS, 3 / N_COLUMNS),
                          'depth': 1.0, 'rnd': float(rng.random()), 'flex': 0.0})
            made += 1
        card_count += made
        log('layer %s: %d tail cards' % (layer['name'], made))
        continue
    roots = poisson(layer['spacing'], layer.get('min_z'), layer.get('edge', False), layer.get('max_z'), layer.get('dense'))
    made = 0
    for root in roots:
        surf0, n0, _ = nearest(root)
        q = q_of(surf0)
        L = spec['length'](q) * layer['length'] * rng.uniform(0.85, 1.12)
        lift = spec['lift'](q) * layer['lift'] * rng.uniform(0.7, 1.2)
        d0 = tangent(spec['flow'](q), n0)
        d0 = rotate(d0, n0, rng.normal(0, layer['noise']))
        twist = rng.normal(0, layer['twist'])
        width = layer['width'] * rng.uniform(0.85, 1.15)
        card_seed = int(rng.integers(1 << 30))
        overhang = spec['overhang'](q)
        rows, reach = card_path(surf0, n0, d0, L, layer, lift, card_seed, overhang)
        if reach < L * 0.97:
            # past the hairline: the card ends at the overhang, tapering there
            L = reach
            rows, _r = card_path(surf0, n0, d0, L, layer, lift, card_seed, None)
        if L < MIN_CARD_STYLE:
            # a whole lock squeezed into a few mm is a dark chip on the edge:
            # the hair cap carries the hairline there
            continue
        # cards rooted near the hairline are narrower and take the fine
        # columns: wide card sides along the edge drew a stepped outline
        _l, _n, root_tri = nearest(root)
        edge_card = grow_w[root_tri] < EDGE_W and not layer.get('edge', False)
        built = ribbon(rows, L, layer, twist, width * (0.55 if edge_card else 1.0), rng.uniform(0, 2 * math.pi))
        col = int(rng.choice(EDGE_COLUMNS if edge_card else layer['columns']))
        u0, u1 = col / N_COLUMNS, (col + 1) / N_COLUMNS
        if rng.random() < 0.5:
            u0, u1 = u1, u0
        cards.append({'layer': layer['name'], 'rows': built, 'u': (u0, u1), 'depth': depth,
                      'rnd': float(rng.random()), 'flex': float(min(1.5, max(0.2, L / 0.07))),
                      'root_fade': layer.get('root_fade', 0.0) * rng.uniform(0.6, 1.4)})
        made += 1
    card_count += made
    log('layer %s: %d cards' % (layer['name'], made))


# ------------------------------------------------------------------ groomed cards (the envelope)
# The way hair cards are laid by hand (PixelicaCG, HairTool): the haircut is a
# smooth VOLUME over the scalp - its thickness T(q) is the style's
# `thickness` - and cards are laid in layers through it like roof shingles:
# each card's root sits on the skin under the hair upstream of it, it rises
# to its layer's height (a share `f` of T) over the first `rise` of its
# length and then lies in that layer along the comb's flow to its tip. All
# three vertices across a card sit at that height over the skin below them,
# so a card bends round the head with the volume: no card stands off it, no
# edge sticks out of the silhouette, neighbours shade alike. Where nothing
# lies upstream (the hairline, the part) the roots fade in.
def edge_distance():
    """Per head vertex: how far (m) inside the style's hairline it lies
    (0 outside)."""
    from mathutils.kdtree import KDTree
    hv = np.array([spec['hairline'](q_of(p)) for p in REST]) * REGION
    inside = hv >= 0.5
    out_idx = np.where(~inside)[0]
    kd = KDTree(len(out_idx))
    for k, vi in enumerate(out_idx):
        kd.insert(REST[vi], k)
    kd.balance()
    ed = np.zeros(len(REST))
    for vi in np.where(inside)[0]:
        ed[vi] = kd.find(REST[vi])[2]
    return ed


def bary_of(loc, ti):
    a, b, c = REST[tris[ti]]
    v0, v1, v2 = b - a, c - a, np.asarray(loc) - a
    d00, d01, d11, d20, d21 = v0 @ v0, v0 @ v1, v1 @ v1, v2 @ v0, v2 @ v1
    den = d00 * d11 - d01 * d01
    w1 = (d11 * d20 - d01 * d21) / den if den else 0.0
    w2 = (d00 * d21 - d01 * d20) / den if den else 0.0
    return np.array([1 - w1 - w2, w1, w2])


def env_cards():
    ed_v = edge_distance()

    def edge_at(loc, ti):
        return float(bary_of(loc, ti) @ ed_v[tris[ti]])

    def off_dir(surf, n):
        """The direction the volume rises in: the skin's normal eased toward
        the skull's radial one (the head's small dents do not show)."""
        r = (surf - C) / np.linalg.norm(surf - C)
        v = 0.6 * n + 0.4 * r
        return v / np.linalg.norm(v)

    thick = spec['thickness']
    part = spec.get('part_dist')
    low_z = spec.get('low_z', 0.2)
    n_env = len(spec['env_layers'])
    made_all = 0
    seg_len = spec.get('seg_len', 0.0085)
    for li, layer in enumerate(spec['env_layers']):
        depth = layer.get('depth', min(1.0, layer['f']))
        # roots: a Poisson disk over the scalp, kept to the layer's band of
        # distance from the hairline
        spacing = layer['spacing']
        cell = spacing / math.sqrt(3)
        grid, roots = {}, []
        min_e, max_e = layer.get('min_edge', 0.0), layer.get('max_edge', 1.0)
        for i in rng.permutation(cand_n):
            p = cand[i]
            loc, nrm, ti, _d = bvh.find_nearest(Vector(p))
            e = edge_at(np.array(loc), ti)
            if not (min_e <= e <= max_e) or e <= 0.0:
                continue
            q = q_of(np.array(loc))
            if layer.get('near') is not None:
                # a layer kept round one point (q) within a radius (m)
                if np.linalg.norm(np.array(loc) - (C + R * np.asarray(layer['near'][0]) / np.linalg.norm(layer['near'][0]))) > layer['near'][1]:
                    continue
            if layer.get('min_z') is not None and q[2] < layer['min_z']:
                continue
            if layer.get('max_z') is not None and q[2] > layer['max_z']:
                continue
            key = tuple((p // cell).astype(int))
            ok = True
            for dx in (-2, -1, 0, 1, 2):
                for dy in (-2, -1, 0, 1, 2):
                    for dz in (-2, -1, 0, 1, 2):
                        for j in grid.get((key[0] + dx, key[1] + dy, key[2] + dz), ()):
                            if np.sum((roots[j][0] - p) ** 2) < spacing * spacing:
                                ok = False
                                break
                        if not ok:
                            break
                    if not ok:
                        break
                if not ok:
                    break
            if ok:
                grid.setdefault(key, []).append(len(roots))
                roots.append((p, e))
        made = 0
        for root, e_root in roots:
            surf, n, _ti = nearest(root)
            q = q_of(surf)
            L = spec['length'](q) * layer['length'] * rng.uniform(0.85, 1.1)
            d = tangent(spec['flow'](q), n)
            d = rotate(d, n, rng.normal(0, layer.get('noise', spec.get('card_noise', 0.035))))
            # a little height jitter only: cards of one layer that cross each
            # other draw a hard cut line where they intersect
            f = layer['f'] * rng.uniform(0.96, 1.04)
            rise = layer.get('rise', 0.2) * rng.uniform(0.8, 1.2)
            tuck = layer.get('tuck', 0.0)
            overhang = spec['overhang'](q)
            # rows: short ones over the rise (the card climbs out of
            # the layers below smoothly, not in one steep step), then even ones
            # the climb out of the skin has a length of its own (m), not a
            # share of the card: a long top card took 2-3 cm and its faded
            # root half thinned the front into a receding hairline
            rise_len = min(max(rise * L, 0.004), layer.get('rise_max', spec.get('rise_max', 0.013)))
            n_rest = int(min(14, max(2, round((L - rise_len) / seg_len))))
            n_rise = spec.get('rise_rows', 2)
            steps = [rise_len / n_rise] * n_rise + [(L - rise_len) / n_rest] * n_rest
            # walk the centre line over the skin (re-projected every step)
            path, runs = [(surf, n, d)], [0.0]
            outside, run = 0.0, 0.0
            for step in steps:
                target = surf + d * step + DOWN * spec['gravity'] * step * (run / L)
                s2, n2, ti2 = nearest(target)
                if overhang is not None and grow_w[ti2] < 0.3:
                    outside += step
                    if outside > overhang:
                        break
                run += step
                surf, n = s2, n2
                nd = tangent(spec['flow'](q_of(surf)), n)
                # neighbours follow the comb alike: a card's own heading
                # turned its highlight band away from its neighbours' (patches)
                d = tangent(0.5 * d + 0.5 * nd, n)
                path.append((surf, n, d))
                runs.append(run)
            if len(path) < 5 or run < MIN_CARD_STYLE:
                continue
            L = run
            rise = min(rise * (rise_len / max(rise_len, 1e-9)), rise_len / L)
            width = layer['width'] * rng.uniform(0.85, 1.15)
            rows = []
            ramp = spec.get('edge_ramp', 0.0)
            for k, (s, nn, dd) in enumerate(path):
                t = runs[k] / L
                h_env = thick(q_of(s))
                if ramp > 0.0:
                    # the volume rounds off toward the hairline (a quiff's
                    # front, the temples): no cliff of stacked card roots
                    _l, _n, _ti, _dd = bvh.find_nearest(Vector(s))
                    floor_ = spec.get('edge_ramp_floor', 0.3)
                    h_env *= floor_ + (1.0 - floor_) * smooth(0.0, ramp, edge_at(np.array(_l), _ti))
                h = 0.0006 + max(0.0, f * h_env - 0.0006) * smooth(0.0, rise, t) * (1.0 - tuck * smooth(0.7, 1.0, t))
                side = np.cross(nn, dd)
                side /= max(np.linalg.norm(side), 1e-9)
                w = width * (1.0 - layer.get('taper', 0.2) * t)
                pts = []
                for kk in (-1, 0, 1):
                    sk, nk, _tk = nearest(s + side * kk * w / 2)
                    ok_ = off_dir(sk, nk)
                    hk = h + (layer.get('arc', 0.08) * w if kk == 0 else 0.0)
                    pts.append(keep_out(sk + ok_ * hk, 0.0006, 0.004))
                rows.append((pts, t, pts[1]))
            q_root = q_of(path[0][0])
            low = q_root[2] < low_z
            cols_ = layer.get('low_columns', layer['columns']) if low else layer['columns']
            col = int(rng.choice(cols_))
            u0, u1 = col / N_COLUMNS, (col + 1) / N_COLUMNS
            if rng.random() < 0.5:
                u0, u1 = u1, u0
            # every card fades in strand by strand while it rises out of the
            # layers below (where it crossed them it drew a hard cut line);
            # roots with nothing upstream (the hairline, the part) fade longer
            rf = max(layer.get('root_fade', 0.0), min(0.6, rise * layer.get('rise_fade', spec.get('rise_fade', 1.1))))
            near_edge = 1.0 - smooth(0.006, 0.016, e_root)
            if not layer.get('cover'):
                rf = max(rf, min(0.5, spec.get('edge_root_fade', 0.012) / L) * near_edge)
                if part is not None:
                    # along the part only a short fade: the hair leaves the
                    # scalp right there (a long one opened a dark hollow)
                    near_part = 1.0 - smooth(0.004, 0.012, part(q_root))
                    rf = max(rf, min(0.5, 0.006 / L) * near_part)
            cards.append({'layer': layer['name'], 'rows': rows, 'u': (u0, u1), 'depth': depth,
                          'rnd': float(rng.random()), 'flex': float(min(1.5, max(0.2, L / 0.07))),
                          'root_fade': rf})
            made += 1
        made_all += made
        log('envelope layer %s: %d cards (f %.2f, spacing %.1f mm)' % (layer['name'], made, layer['f'], 1000 * spacing))
    return made_all


if spec.get('env_layers'):
    card_count += env_cards()
# far LOD: the inner layers only, every other row (hair_far, past
# HeroAppearance.HAIR_NEAR metres; no fringe pass there)
FAR_LAYERS = tuple(spec.get('far_layers', ('sides', 'base', 'main')))
keys = head.data.shape_keys.key_blocks if head.data.shape_keys else []


def build_object(name, use_cards, row_step):
    verts, faces, uv_a, uv_b, cols, nrms = [], [], [], [], [], []
    for card in use_cards:
        rows = card['rows']
        idx = list(range(0, len(rows), row_step))
        if idx[-1] != len(rows) - 1:
            idx.append(len(rows) - 1)
        u0, u1 = card['u']
        base = len(verts)
        for ri in idx:
            (left, mid, right), t, p = rows[ri]
            for k, e in enumerate((left, mid, right)):
                verts.append(e)
                # the card's normal: the head's surface below it (a beard faces
                # the way the jaw does - radial from the skull's centre it faced
                # down, away from every light, and read black), blended with the
                # skull's radial direction for scalp hair (one round volume)
                _loc, _sn, _ti, _d = bvh.find_nearest(Vector(e))
                radial = (e - C) / np.linalg.norm(e - C)
                ws = NORMAL_SURFACE
                nv = np.array(_sn) * ws + radial * (1.0 - ws)
                nrms.append(nv / max(np.linalg.norm(nv), 1e-9))
                uv_a.append((u0 + (u1 - u0) * k / 2, 1.0 - t))
                uv_b.append((t, 1.0 - card['depth']))
                # each card a little darker toward its root (groomed cards:
                # hardly - their roots are under the hair upstream, and a dark
                # root on every card drew fish scales over the surface)
                root_ao = spec.get('card_root_ao', 0.75)
                ao = (0.8 + 0.2 * card['depth']) * (root_ao + (1.0 - root_ao) * smooth(0.0, 0.6, t))
                # where the card lies over the skin near and past the hairline
                # it fades out (the shader thins it strand by strand): no card
                # edge draws the hairline as steps - also cards standing a
                # little off the skin (at 5 mm the temple kept square ends)
                loc, _nn, ti, dist = bvh.find_nearest(Vector(e))
                fade = 1.0 if dist > 0.02 else smooth(spec.get('edge_fade', EDGE_FADE)[0], spec.get('edge_fade', EDGE_FADE)[1], float(grow_w[ti]))
                if release is not None:
                    # hair that has left the scalp (falling past the ears and
                    # the nape) is not at a hairline: it keeps its coverage
                    _ql = q_of(np.array(loc))
                    if _ql[2] < release(_ql) + 0.08:
                        fade = 1.0
                if card.get('root_fade', 0.0) > 0.0:
                    # the card grows out of the skin: no visible cut root row
                    fade *= smooth(0.0, card['root_fade'], t)
                cols.append((card['rnd'], card['flex'], ao, fade))
        for i in range(len(idx) - 1):
            a0, b0 = base + i * 3, base + (i + 1) * 3
            faces.append((a0, a0 + 1, b0 + 1, b0))
            faces.append((a0 + 1, a0 + 2, b0 + 2, b0 + 1))
    verts = np.array(verts)
    hm = bpy.data.meshes.new(name)
    hm.from_pydata(verts.tolist(), [], faces)
    uv1 = hm.uv_layers.new(name='UVMap')
    uv2 = hm.uv_layers.new(name='UVMap2')
    for poly in hm.polygons:
        for loop, v in zip(poly.loop_indices, poly.vertices):
            uv1.data[loop].uv = uv_a[v]
            uv2.data[loop].uv = uv_b[v]
    hm.uv_layers.active = uv1
    ca = hm.color_attributes.new('Col', 'FLOAT_COLOR', 'POINT')
    ca.data.foreach_set('color', np.array(cols, np.float32).ravel())
    hm.color_attributes.active_color = ca
    for poly in hm.polygons:
        poly.use_smooth = True
    hm.normals_split_custom_set_from_vertices([tuple(n) for n in nrms])
    hm.materials.append(bpy.data.materials.get('HC_' + STYLE) or bpy.data.materials.new('HC_' + STYLE))
    ob = bpy.data.objects.new(name, hm)
    bpy.context.scene.collection.objects.link(ob)
    # follow the head's shape keys where they move the scalp
    bind = []
    for v in verts:
        loc, _n, ti, _d = bvh.find_nearest(Vector(v))
        a, b, c = REST[tris[ti]]
        v0, v1, v2 = b - a, c - a, np.array(loc) - a
        d00, d01, d11 = v0 @ v0, v0 @ v1, v1 @ v1
        d20, d21 = v2 @ v0, v2 @ v1
        den = d00 * d11 - d01 * d01
        wv = (d11 * d20 - d01 * d21) / den if den else 0.0
        ww = (d00 * d21 - d01 * d20) / den if den else 0.0
        bind.append((ti, (1 - wv - ww, wv, ww)))
    ob.shape_key_add(name='Basis')
    followed = 0
    for kb in keys:
        if kb.name == 'Basis':
            continue
        kc = np.zeros(len(kb.data) * 3, np.float32)
        kb.data.foreach_get('co', kc)
        disp = kc.reshape(-1, 3) - REST
        hd = np.array([sum(w * disp[i] for w, i in zip(bw, tris[ti])) for ti, bw in bind])
        if np.abs(hd).max() < 0.0005:
            continue
        k = ob.shape_key_add(name=kb.name)
        k.data.foreach_set('co', (verts + hd).astype(np.float32).ravel())
        followed += 1
    ob.parent = rig
    mod = ob.modifiers.new('Armature', 'ARMATURE')
    mod.object = rig
    g = ob.vertex_groups.new(name='Head')
    drop = spec.get('drop_skin')       # (z full head, z full chest): long hair's ends ride the torso
    if drop is None:
        g.add(list(range(len(verts))), 1.0, 'REPLACE')
    else:
        gn = ob.vertex_groups.new(name='Neck')
        gc = ob.vertex_groups.new(name='UpperChest')
        for vi, v in enumerate(verts):
            w = smooth(drop[1], drop[0], v[2])      # 1 at the head .. 0 down the back
            if w > 0.001:
                g.add([vi], w, 'REPLACE')
            if 1.0 - w > 0.001:
                gn.add([vi], (1.0 - w) * 0.35, 'REPLACE')
                gc.add([vi], (1.0 - w) * 0.65, 'REPLACE')
    log('%s: verts %d tris %d, follows %d head keys' % (name, len(verts), 2 * len(faces), followed))
    return ob


hair = build_object('Hair_' + STYLE, cards, 1) if cards else None
far_cards = [c for c in cards if c['layer'] in FAR_LAYERS]
hair_far = build_object('Hair_' + STYLE + '_far', far_cards, 2) if far_cards else None
log('cards %d' % card_count)

# ------------------------------------------------------------------ the hair cap (head UV)
# Where the scalp shows - the hairline, the part, the crown, between the outer
# cards - the skin carries the style's short hair: tens of thousands of short
# strands drawn along the same flow on the head's own texture (the "hair cap"
# of AAA hair). Toward the hairline they thin out and get shorter, so the
# edge is a gradient of single hairs, not a line. cap_<style>.png:
#   R strand coverage, G strand shade, B the hair's base shadow on the scalp.
meta = json.load(open(os.path.join(WORK, 'head_meta.json')))
pw, ph = meta['skin_pack']['size']
CAP_SS = 2
CW_, CH_ = pw * CAP_SS, ph * CAP_SS
uvl = me.uv_layers.active.data
loop_uv = np.zeros(len(uvl) * 2, np.float32)
uvl.foreach_get('uv', loop_uv)
loop_uv = loop_uv.reshape(-1, 2)
tri_loops = []
for poly in me.polygons:
    li = list(poly.loop_indices)
    for k in range(1, len(li) - 1):
        tri_loops.append((li[0], li[k], li[k + 1]))
tri_loops = np.array(tri_loops)


def to_uv(points):
    """Surface points -> head UV pixels (cap resolution), via their triangle."""
    out = np.zeros((len(points), 2))
    for i, p in enumerate(points):
        loc, _n, ti, _d = bvh.find_nearest(Vector(p))
        a, b, c = REST[tris[ti]]
        v0, v1, v2 = b - a, c - a, np.array(loc) - a
        d00, d01, d11, d20, d21 = v0 @ v0, v0 @ v1, v1 @ v1, v2 @ v0, v2 @ v1
        den = d00 * d11 - d01 * d01
        w1 = (d11 * d20 - d01 * d21) / den if den else 0.0
        w2 = (d00 * d21 - d01 * d20) / den if den else 0.0
        uv = loop_uv[tri_loops[ti]]
        out[i] = uv[0] * (1 - w1 - w2) + uv[1] * w1 + uv[2] * w2
    return out * [CW_, CH_]


CAP_STRANDS = spec.get('cap_strands', 70000)
CAP_STEPS = 5
cap_tri = rng.choice(len(tris), size=CAP_STRANDS, p=(tri_area * grow_w ** 2) / (tri_area * grow_w ** 2).sum())
r1, r2 = rng.random(CAP_STRANDS), rng.random(CAP_STRANDS)
s1 = np.sqrt(r1)
cap_bary = np.stack([1 - s1, s1 * (1 - r2), s1 * r2], 1)
cap_root = (tri_p[cap_tri] * cap_bary[:, :, None]).sum(1)
cap_w = grow_w[cap_tri]
sx, sy, sa, sid = [], [], [], []
for i in range(CAP_STRANDS):
    p = cap_root[i]
    surf, n, _ = nearest(p)
    q = q_of(surf)
    # short hairs: 3-7 mm inside, shorter and finer toward the hairline
    length = min(spec['length'](q), spec.get('cap_max', 0.007)) * rng.uniform(0.55, 1.1) * (0.45 + 0.55 * smooth(0.25, 0.9, cap_w[i]))
    d = tangent(spec['flow'](q), n)
    d = rotate(d, n, rng.normal(0, 0.18))
    pts = [surf]
    step = length / CAP_STEPS
    for k in range(CAP_STEPS):
        surf, n, _ = nearest(pts[-1] + d * step)
        d = tangent(0.75 * d + 0.25 * tangent(spec['flow'](q_of(surf)), n), n)
        pts.append(surf)
    uv = to_uv(pts)
    seg = np.diff(uv, axis=0)
    a0 = rng.uniform(0.75, 1.0) * (0.55 + 0.45 * smooth(0.25, 0.9, cap_w[i])) * spec.get('cap_alpha', 1.0)
    shade = rng.random()
    for k in range(CAP_STEPS):
        if np.abs(seg[k]).max() > 40:
            # this step crosses a UV seam: its two ends lie on different
            # islands, the rest of the strand is still drawn (skipping whole
            # strands left a hairless line along every seam)
            continue
        n_s = int(np.ceil(np.hypot(*seg[k]) * 1.5)) + 1
        t = np.linspace(0, 1, n_s, endpoint=False)
        xy = uv[k] + seg[k] * t[:, None]
        fade = 1.0 - (k + t) / CAP_STEPS * 0.7       # tapers to the tip
        sx.append(xy[:, 0]); sy.append(xy[:, 1]); sa.append(a0 * fade); sid.append(np.full(n_s, shade))
sx, sy, sa, sid = (np.concatenate(v) for v in (sx, sy, sa, sid))
ix = np.clip(sx.astype(int), 0, CW_ - 1)
iy = np.clip(sy.astype(int), 0, CH_ - 1)
cov = np.zeros((CH_, CW_), np.float32)
np.maximum.at(cov, (iy, ix), sa.astype(np.float32))
acc = np.zeros((CH_, CW_), np.float32)
wsum = np.zeros((CH_, CW_), np.float32)
np.add.at(acc, (iy, ix), (sa * sid).astype(np.float32))
np.add.at(wsum, (iy, ix), sa.astype(np.float32))
cov = cov.reshape(ph, CAP_SS, pw, CAP_SS).mean((1, 3))
shade = (acc.reshape(ph, CAP_SS, pw, CAP_SS).sum((1, 3)) /
         np.maximum(wsum.reshape(ph, CAP_SS, pw, CAP_SS).sum((1, 3)), 1e-6))
# the hair's base shadow on the scalp: the style's region, soft at the edge
hv = np.array([spec['hairline'](q_of(p)) for p in REST]) * np.clip(REGION / 0.85, 0, 1) ** (1.5 if spec.get('region', 'scalp') == 'scalp' else 0.6)
base = blur(raster(me, hv[:, None].astype(np.float32), pw, ph)[..., 0], 3) * spec.get('cap_shadow', 1.0)
# grow the strands past the UV islands' edges: filtering at a seam read the
# empty texels outside the island and drew a bare line along it
isl = raster(me, np.ones((len(REST), 1), np.float32), pw, ph, grow=0)[..., 0] > 0.5
isl = isl & (np.minimum.reduce([np.roll(isl, sh, ax) for sh in (-1, 1) for ax in (0, 1)]))
filled = isl.astype(np.float32)
cov_f, shade_f = cov * filled, shade * filled
for _ in range(10):
    grow_c = blur(cov_f, 1); grow_s = blur(shade_f, 1); gw = blur(filled, 1)
    empty = (filled == 0) & (gw > 0.01)
    cov_f[empty] = grow_c[empty] / gw[empty]
    shade_f[empty] = grow_s[empty] / gw[empty]
    filled[empty] = 1.0
cov = np.where(isl, cov, cov_f)
shade = np.where(isl, shade, shade_f)
cap = np.stack([cov, shade, base], -1)
save_img(os.path.join(OUT, 'cap_%s.png' % STYLE), cap)
log('hair cap: %d strands, coverage mean %.3f where it grows' % (CAP_STRANDS, cov[base > 0.25].mean() if (base > 0.25).any() else 0.0))


# ------------------------------------------------------------------ shells (short dense hair: a buzz cut)
# Short dense hair is a volume, not a few dozen cards: it is drawn as SHELLS -
# the style's area of the head copied `layers` times, each copy risen off the
# skin and slid along the flow (the hairs lie combed down), with a strand
# texture in the head's UV (shell_<style>.png): every strand is a dot with
# its own length, so a layer shows the strands that reach it, thinner toward
# their tips. Seen from any side the hair has depth, a soft fuzzy outline and
# no card edge anywhere. The game draws it with hero_hair_shell.gdshader,
# near the camera only (the hair cap below carries it further out).
shell_spec = spec.get('shells')
shell_obj = None
if shell_spec:
    NL = shell_spec['layers']
    vn = np.zeros(len(me.vertices) * 3, np.float32)
    me.vertices.foreach_get('normal', vn)
    vn = vn.reshape(-1, 3).astype(np.float64)
    dens_v = np.array([spec['hairline'](q_of(p)) for p in REST]) * np.clip(REGION / 0.85, 0, 1) ** 0.6
    hmax_v = np.array([shell_spec['height'](q_of(p)) for p in REST])
    # the hairs get shorter toward the style's lines: a soft outline
    hv_v = hmax_v * np.array([smooth(0.04, 0.45, float(d)) for d in dens_v])
    flow_v = np.array([tangent(spec['flow'](q_of(p)), n) for p, n in zip(REST, vn)])
    keep = [poly for poly in me.polygons if all(dens_v[v] > 0.03 for v in poly.vertices)]
    uvl = me.uv_layers.active.data
    # the shells are built on the head's unsubdivided cage (a quarter of the
    # faces): the style's faces copied out, bmesh unsubdivide, the cage's
    # corners mapped back to their head vertices
    import bmesh
    _bm = bmesh.new()
    _uvb = _bm.loops.layers.uv.new('UVMap')
    # one bmesh vertex per (head vertex, UV): the UV islands come apart at
    # their seams, so unsubdividing never merges faces across a seam (that
    # stretched the strand texture into a line under the jaw)
    _vmap = {}
    _src_of = {}
    for poly in keep:
        for v, li in zip(poly.vertices, poly.loop_indices):
            key = (v, round(uvl[li].uv[0], 5), round(uvl[li].uv[1], 5))
            if key not in _vmap:
                bv = _bm.verts.new(REST[v])
                _vmap[key] = bv
                _src_of[bv] = v
    for poly in keep:
        keys = [(v, round(uvl[li].uv[0], 5), round(uvl[li].uv[1], 5)) for v, li in zip(poly.vertices, poly.loop_indices)]
        try:
            f = _bm.faces.new([_vmap[k] for k in keys])
        except ValueError:
            continue
        for loop, li in zip(f.loops, poly.loop_indices):
            loop[_uvb].uv = uvl[li].uv
    if shell_spec.get('cage', True):
        bmesh.ops.unsubdivide(_bm, verts=list(_bm.verts), iterations=2)
    keep_cage = []
    for f in _bm.faces:
        keep_cage.append(([_src_of[v] for v in f.verts], [tuple(l[_uvb].uv) for l in f.loops]))
    _bm.free()
    base_ids = sorted({v for vs, _u in keep_cage for v in vs})
    idx = {v: k for k, v in enumerate(base_ids)}
    sv, sf, suv, suv2, scol, snrm, ssrc = [], [], [], [], [], [], []
    rise, lean = shell_spec.get('rise', 0.6), shell_spec.get('lean', 0.9)
    for L in range(1, NL + 1):
        t = L / NL
        off = len(sv)
        for v in base_ids:
            h = hv_v[v]
            # out of the skin, bending over along the flow (combed down)
            p = REST[v] + vn[v] * h * rise * t * (1.0 - 0.3 * t) + flow_v[v] * h * lean * t * t
            sv.append(p)
            snrm.append(vn[v])
            ssrc.append(v)
            scol.append((flow_v[v][0] * 0.5 + 0.5, flow_v[v][1] * 0.5 + 0.5, flow_v[v][2] * 0.5 + 0.5, 1.0))
        for vs, fuv in keep_cage:
            sf.append(tuple(off + idx[v] for v in vs))
            suv.append(fuv)
            suv2.append(t)
    sv = np.array(sv)
    sm = bpy.data.meshes.new('Hair_' + STYLE + '_shell')
    sm.from_pydata(sv.tolist(), [], sf)
    u1 = sm.uv_layers.new(name='UVMap')
    u2 = sm.uv_layers.new(name='UVMap2')
    for poly, fuv, t in zip(sm.polygons, suv, suv2):
        for k, loop in enumerate(poly.loop_indices):
            u1.data[loop].uv = fuv[k]
            u2.data[loop].uv = (t, 0.0)
    sm.uv_layers.active = u1
    ca = sm.color_attributes.new('Col', 'FLOAT_COLOR', 'POINT')
    ca.data.foreach_set('color', np.array(scol, np.float32).ravel())
    sm.color_attributes.active_color = ca
    for poly in sm.polygons:
        poly.use_smooth = True
    sm.normals_split_custom_set_from_vertices([tuple(n) for n in snrm])
    sm.materials.append(bpy.data.materials.new('HS_' + STYLE))
    shell_obj = bpy.data.objects.new('Hair_' + STYLE + '_shell', sm)
    bpy.context.scene.collection.objects.link(shell_obj)
    # the head's shape keys move each layer with its skin vertex
    ssrc = np.array(ssrc)
    shell_obj.shape_key_add(name='Basis')
    nk = 0
    for kb in (head.data.shape_keys.key_blocks if head.data.shape_keys else []):
        if kb.name == 'Basis':
            continue
        kc = np.zeros(len(kb.data) * 3, np.float32)
        kb.data.foreach_get('co', kc)
        disp = kc.reshape(-1, 3) - REST
        d = disp[ssrc]
        if np.abs(d).max() < 0.0003:
            continue
        k = shell_obj.shape_key_add(name=kb.name)
        k.data.foreach_set('co', (sv + d).astype(np.float32).ravel())
        nk += 1
    # skinned exactly like the skin below it
    shell_obj.parent = rig
    mod = shell_obj.modifiers.new('Armature', 'ARMATURE')
    mod.object = rig
    gmap = {}
    for vg in head.vertex_groups:
        gmap[vg.index] = shell_obj.vertex_groups.new(name=vg.name)
    for si, v in enumerate(ssrc):
        for g in me.vertices[int(v)].groups:
            if g.weight > 1e-4 and g.group in gmap:
                gmap[g.group].add([si], g.weight, 'REPLACE')
    log('shells: %d layers x %d faces = %d tris, follow %d head keys, hair up to %.1f mm'
        % (NL, len(keep_cage), 2 * len(sf), nk, 1000 * hv_v.max()))

    # the strand texture in the head's UV: R a random per strand, G its
    # length (0..1 of the local height; 0 = no strand), B its core (1 at the
    # strand's centre .. 0 at its edge)
    meta_s = json.load(open(os.path.join(WORK, 'head_meta.json')))
    tw, th = meta_s['skin_pack']['size']
    dens_px = raster(me, dens_v[:, None].astype(np.float32), tw, th, grow=2)[..., 0]
    cand = np.argwhere(dens_px > 0.03)
    fill = shell_spec.get('strands_per_texel', 0.4)
    nstr = int(len(cand) * fill)
    pick = cand[rng.integers(0, len(cand), nstr)]
    jit = rng.random((nstr, 2))
    cy, cx = pick[:, 0] + jit[:, 0], pick[:, 1] + jit[:, 1]
    d_at = dens_px[pick[:, 0], pick[:, 1]]
    # toward the style's lines the hairs end shorter and shorter, down to
    # none: no layer can show a polygon edge (a hard sawtooth outline)
    length = rng.uniform(0.5, 1.0, nstr) * np.clip((d_at - 0.04) / 0.5, 0.0, 1.0) ** 1.2
    sid = rng.random(nstr)
    r0 = shell_spec.get('strand_radius', 1.15)
    G = np.zeros((th, tw), np.float32)
    B = np.zeros((th, tw), np.float32)
    Rr = np.zeros((th, tw), np.float32)
    order = np.argsort(length)          # longer strands drawn last win the texel
    cy, cx, length, sid = cy[order], cx[order], length[order], sid[order]
    for dy in (-2, -1, 0, 1, 2):
        for dx in (-2, -1, 0, 1, 2):
            py = np.floor(cy).astype(int) + dy
            px = np.floor(cx).astype(int) + dx
            dist = np.hypot(py + 0.5 - cy, px + 0.5 - cx)
            core = np.clip(1.0 - dist / r0, 0.0, 1.0)
            ok = (core > 0) & (py >= 0) & (py < th) & (px >= 0) & (px < tw)
            py, px, core_k, len_k, sid_k = py[ok], px[ok], core[ok], length[ok], sid[ok]
            better = core_k * len_k > B[py, px] * G[py, px]
            py, px = py[better], px[better]
            G[py, px] = len_k[better]
            B[py, px] = core_k[better]
            Rr[py, px] = sid_k[better]
    save_img(os.path.join(OUT, 'shell_%s.png' % STYLE), np.stack([Rr, G, B], -1))
    log('shell texture %dx%d: %d strands, %.1f %% of the area covered'
        % (tw, th, nstr, 100.0 * (G[dens_px > 0.3] > 0).mean()))

# ------------------------------------------------------------------ export
out_glb = os.path.join(OUT, 'hair_%s.glb' % STYLE)
if hair is None and shell_obj is None:
    # a style drawn by its hair cap alone (a buzz cut): no glb
    if os.path.exists(out_glb):
        os.remove(out_glb)
    log('no cards: cap only')
    raise SystemExit(0)
bpy.ops.object.select_all(action='DESELECT')
for o in bpy.data.objects:
    o.hide_set(False)
for _o in (hair, hair_far, shell_obj):
    if _o is not None:
        _o.select_set(True)
rig.select_set(True)
bpy.context.view_layer.objects.active = rig
bpy.ops.export_scene.gltf(filepath=out_glb, export_format='GLB', use_selection=True, export_skins=True,
                          export_morph=True, export_morph_normal=False, export_tangents=True,
                          export_animations=False, export_materials='PLACEHOLDER', export_yup=True,
                          export_attributes=False, export_vertex_color='ACTIVE')
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(WORK, 'hair_%s_work.blend' % STYLE))
log('exported', out_glb)
