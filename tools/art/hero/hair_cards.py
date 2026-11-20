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
from bake_util import save_img, blur, raster  # noqa: E402

args = sys.argv[sys.argv.index('--') + 1:]
STYLE = args[0]
OUT = os.path.abspath(args[1])
WORK = os.path.abspath(args[2])
os.makedirs(OUT, exist_ok=True)
spec = hair_styles.STYLES[STYLE]
rng = np.random.default_rng(sum(ord(c) for c in STYLE) * 7919)
N_COLUMNS = len(strand_atlas.COLUMNS)
# the light / wispy columns (strand_atlas.COLUMNS) for cards on the hairline
EDGE_COLUMNS = [4, 5]


def log(*a):
    print('[hair]', *a, flush=True)


rig = bpy.data.objects['GameRig']
rig.data.pose_position = 'REST'
head = bpy.data.objects['Face_Head']
reg = np.load(os.path.join(WORK, 'head_regions.npz'))
REST = reg['rest'].astype(np.float64)
SCALP = reg['scalp']
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
tri_w = SCALP[tris].mean(1)
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


def poisson(spacing, min_z=None, edge=False, max_z=None):
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
        elif cand_w[i] < 0.7 or rng.random() > smooth(0.7, 0.95, cand_w[i]):
            # the inner layers stay inside the hairline: their blunt card
            # sides on the edge read as torn paper
            continue
        if min_z is not None and q_of(p)[2] < min_z:
            continue
        if max_z is not None and q_of(p)[2] > max_z:
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


# ------------------------------------------------------------------ cards
cards = []
n_layers = len(spec['layers'])
card_count = 0
for li, layer in enumerate(spec['layers']):
    # how deep in the hair the layer lies (0 under everything .. 1 on top);
    # the hairline layer is on the outside of the edge, never in shadow
    depth = layer.get('depth', li / max(1, n_layers - 1))
    roots = poisson(layer['spacing'], layer.get('min_z'), layer.get('edge', False), layer.get('max_z'))
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

        def march(length, check=True):
            """The card's path over the scalp: (surface point, normal,
            direction) per row, and how far it got before running past the
            hairline by more than the style's overhang there."""
            crng = np.random.default_rng(card_seed)
            nseg = int(min(10, max(3, round(length / 0.009))))
            step = length / nseg
            surf, n, d = surf0, n0, d0
            path, outside, run = [], 0.0, 0.0
            for i in range(nseg + 1):
                path.append((surf, n, d))
                if i == nseg:
                    break
                target = surf + d * step + np.array([0, 0, -1.0]) * spec['gravity'] * step * (i / nseg)
                surf, n, ti = nearest(target)
                run += step
                if check and grow_w[ti] < 0.3:
                    outside += step
                    if outside > overhang:
                        return path, run - (outside - overhang)
                nd = tangent(spec['flow'](q_of(surf)), n)
                d = tangent(0.7 * d + 0.3 * nd, n)
                d = rotate(d, n, crng.normal(0, layer['noise'] * 0.25))
            return path, length

        path, reach = march(L)
        if reach < L * 0.97:
            # past the hairline: the card ends at the overhang, tapering there
            L = max(reach, 0.006)
            path, _r = march(L, check=False)
        nseg = len(path) - 1
        rows = []
        for i, (surf, n, d) in enumerate(path):
            t = i / nseg
            # the root grows out of the scalp and rises to its layer: a root
            # floating at the layer's height showed its straight cut end
            h = 0.0006 + (layer['offset'] - 0.0006) * smooth(0.0, 0.25, t)                 + lift * smooth(0.0, 0.35, t) * (1.0 - 0.35 * t)
            p = surf + n * h
            side = np.cross(n, d)
            side /= max(np.linalg.norm(side), 1e-9)
            side = rotate(side, d, twist * (0.4 + 0.6 * t))
            out = np.cross(d, side)
            w = width * (1.0 - 0.5 * t)
            left, right = p - side * w / 2, p + side * w / 2
            mid = p + out * layer['arc'] * w
            # an edge that dips under the scalp is lifted back over it
            fixed = []
            for e in (left, mid, right):
                loc, en, _ = nearest(e)
                if (e - loc) @ en < 0.0008:
                    e = loc + en * 0.0008
                fixed.append(e)
            rows.append((fixed, t, p))
        # cards rooted where the scalp fades out take the light columns, so
        # the hairline ends in loose strands, not in dense card ends
        _l, _n, root_tri = nearest(root)
        edge_card = grow_w[root_tri] < 0.8 and not layer.get('edge', False)
        col = int(rng.choice(EDGE_COLUMNS if edge_card else layer['columns']))
        u0, u1 = col / N_COLUMNS, (col + 1) / N_COLUMNS
        if rng.random() < 0.5:
            u0, u1 = u1, u0
        cards.append({'layer': layer['name'], 'rows': rows, 'u': (u0, u1), 'depth': depth,
                      'rnd': float(rng.random()), 'flex': float(min(1.5, max(0.2, L / 0.07)))})
        card_count += 1
    log('layer %s: %d cards' % (layer['name'], len(roots)))
# far LOD: the base and main layers only, every other row (hair_far, past
# HeroAppearance.HAIR_NEAR metres; no fringe pass there)
FAR_LAYERS = ('sides', 'base', 'main')
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
                nrms.append((e - C) / np.linalg.norm(e - C))
                uv_a.append((u0 + (u1 - u0) * k / 2, 1.0 - t))
                uv_b.append((t, 1.0 - card['depth']))
                ao = (0.8 + 0.2 * card['depth']) * (0.75 + 0.25 * smooth(0.0, 0.6, t))
                cols.append((card['rnd'], card['flex'], ao, 1.0))
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
    g.add(list(range(len(verts))), 1.0, 'REPLACE')
    log('%s: verts %d tris %d, follows %d head keys' % (name, len(verts), 2 * len(faces), followed))
    return ob


hair = build_object('Hair_' + STYLE, cards, 1)
hair_far = build_object('Hair_' + STYLE + '_far', [c for c in cards if c['layer'] in FAR_LAYERS], 2)
log('cards %d' % card_count)

# ------------------------------------------------------------------ the scalp mask (head UV)
meta = json.load(open(os.path.join(WORK, 'head_meta.json')))
pw, ph = meta['skin_pack']['size']
# soft toward the edge: the painted short hair fades out over the hairline band
hv = np.array([spec['hairline'](q_of(p)) for p in REST]) * np.clip(SCALP / 0.85, 0, 1) ** 1.5
mask = raster(me, hv[:, None].astype(np.float32), pw // 2 // 4 * 4, ph // 2 // 4 * 4)
mask = blur(mask, 2)
save_img(os.path.join(OUT, 'scalp_%s.png' % STYLE), np.repeat(mask, 3, 2))

# ------------------------------------------------------------------ export
bpy.ops.object.select_all(action='DESELECT')
for o in bpy.data.objects:
    o.hide_set(False)
hair.select_set(True)
hair_far.select_set(True)
rig.select_set(True)
bpy.context.view_layer.objects.active = rig
out_glb = os.path.join(OUT, 'hair_%s.glb' % STYLE)
bpy.ops.export_scene.gltf(filepath=out_glb, export_format='GLB', use_selection=True, export_skins=True,
                          export_morph=True, export_morph_normal=False, export_tangents=True,
                          export_animations=False, export_materials='PLACEHOLDER', export_yup=True,
                          export_attributes=False, export_vertex_color='ACTIVE')
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(WORK, 'hair_%s_work.blend' % STYLE))
log('exported', out_glb)
