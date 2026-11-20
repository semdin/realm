"""The hero's head: a MakeHuman (MPFB2, CC0) head and neck fitted onto the
game rig, with its face sliders as shape keys, eyes, lashes and brows.

  blender -b <hero_q_game.blend> --python build_head.py -- <assets_out_dir> <work_dir> [--preview]

<hero_q_game.blend> is the hero source (art/characters/hero_q, kept local):
it carries GameRig (the body's armature, same rest pose as
game/assets/models/characters/hero_wizard.glb) and the old Quaternius
Hero_Head, which only lends its neck (where the collar hides the cut) and its
neck weights. Writes <assets_out_dir>/hero_head.glb and the head textures;
<work_dir> gets the review renders and a .blend of the result.

How (README.md next to this file):
  1. MPFB builds one human (phenotype + BASE_FACE targets) with high-poly
     eyes, eyelashes and every brow in BROWS; it is scaled to the hero's
     height and its neck centred on the body's neck.
  2. Each face slider (looks.json `sliders`, the same keys the old head had)
     is the sum of MakeHuman targets in FACE_SLIDERS at ±1 x SLIDER_GAIN; every
     key is measured on the base mesh AND on the fitted parts (MPFB refits
     eyes, brows and lashes to the changed face), so the parts follow.
  3. Head and neck are cut at the old head's lowest ring, subdivided once
     (Catmull-Clark, the key shapes subdivided the same way) and skinned with
     the old head's weights.
  4. The skin texture is the MakeHuman photo skin cropped to the head islands;
     a detail normal and the face zone map (beard area, oily zone, cavity)
     are generated into the head UV.
"""
import bpy, bmesh, sys, os, math, json, gzip
import numpy as np
from mathutils import Vector, kdtree
from mathutils.bvhtree import BVHTree
from bl_ext.user_default.mpfb.services import HumanService, TargetService, ClothesService
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bake_util import raster as raster_mesh  # noqa: E402

args = sys.argv[sys.argv.index('--') + 1:]
OUT = os.path.abspath(args[0])
WORK = os.path.abspath(args[1])
PREVIEW = '--preview' in args
os.makedirs(OUT, exist_ok=True)
os.makedirs(WORK, exist_ok=True)

APPDATA = os.environ['APPDATA']
MPFB_SYS = os.path.join(APPDATA, 'Blender Foundation', 'Blender', '5.2', 'extensions', 'user_default', 'mpfb', 'data')
MPFB_USER = os.path.join(APPDATA, 'Blender Foundation', 'Blender', '5.2', 'extensions', '.user', 'user_default', 'mpfb', 'data')

PHENOTYPE = {"gender": 1.0, "age": 0.5, "muscle": 0.6, "weight": 0.45, "height": 0.6, "proportions": 0.8}
RACE = {"african": 0.0, "asian": 0.0, "caucasian": 1.0}
# the default face: a young man's, a little more defined than MakeHuman's average
BASE_FACE = {
    "chin-bones-incr": 0.25, "chin-prominent-incr": 0.1,
    "l-cheek-bones-incr": 0.15, "r-cheek-bones-incr": 0.15,
    "neck-scale-horiz-incr": 0.2,
}
SKIN = "young_caucasian_male2"
# looks.json `brows` -> MakeHuman eyebrow asset
BROWS = {
    "natural": "eyebrow001", "bushy": "eyebrow002", "arched": "eyebrow003", "thin": "eyebrow004",
    "angular": "eyebrow005", "classic": "eyebrow008", "classic_straight": "eyebrow010",
}
LASHES = "eyelashes01"

# slider -> (targets summed at -1, targets summed at +1), data/targets/<group>/<name>
FACE_SLIDERS = {
    'jaw': (['chin/chin-width-decr'], ['chin/chin-width-incr']),
    'chin': (['chin/chin-prominent-decr'], ['chin/chin-prominent-incr']),
    'chin_height': (['chin/chin-height-decr'], ['chin/chin-height-incr']),
    'cheekbones': (['cheek/l-cheek-bones-decr', 'cheek/r-cheek-bones-decr'], ['cheek/l-cheek-bones-incr', 'cheek/r-cheek-bones-incr']),
    'cheeks': (['cheek/l-cheek-volume-decr', 'cheek/r-cheek-volume-decr'], ['cheek/l-cheek-volume-incr', 'cheek/r-cheek-volume-incr']),
    'nose_length': (['nose/nose-scale-vert-decr'], ['nose/nose-scale-vert-incr']),
    'nose_width': (['nose/nose-scale-horiz-decr'], ['nose/nose-scale-horiz-incr']),
    'nose_bridge': (['nose/nose-hump-decr'], ['nose/nose-hump-incr']),
    'lips': (['mouth/mouth-upperlip-volume-decr', 'mouth/mouth-lowerlip-volume-decr'], ['mouth/mouth-upperlip-volume-incr', 'mouth/mouth-lowerlip-volume-incr']),
    'brow_ridge': (['eyebrows/eyebrows-trans-backward'], ['eyebrows/eyebrows-trans-forward']),
    'eye_size': (['eyes/l-eye-scale-decr', 'eyes/r-eye-scale-decr'], ['eyes/l-eye-scale-incr', 'eyes/r-eye-scale-incr']),
    'eye_spacing': (['eyes/l-eye-trans-in', 'eyes/r-eye-trans-in'], ['eyes/l-eye-trans-out', 'eyes/r-eye-trans-out']),
    'eye_height': (['eyes/l-eye-trans-down', 'eyes/r-eye-trans-down'], ['eyes/l-eye-trans-up', 'eyes/r-eye-trans-up']),
    'eye_tilt': (['eyes/l-eye-corner1-down', 'eyes/r-eye-corner1-down', 'eyes/l-eye-corner2-up', 'eyes/r-eye-corner2-up'],
                 ['eyes/l-eye-corner1-up', 'eyes/r-eye-corner1-up', 'eyes/l-eye-corner2-down', 'eyes/r-eye-corner2-down']),
    'eyelids': (['eyes/l-eye-eyefold-up', 'eyes/r-eye-eyefold-up'], ['eyes/l-eye-eyefold-down', 'eyes/r-eye-eyefold-down']),
    'eye_bags': (['eyes/l-eye-bag-decr', 'eyes/r-eye-bag-decr'], ['eyes/l-eye-bag-incr', 'eyes/r-eye-bag-incr']),
    'nose_tip': (['nose/nose-point-down'], ['nose/nose-point-up']),
    'nostrils': (['nose/nose-flaring-decr'], ['nose/nose-flaring-incr']),
    'nose_curve': (['nose/nose-curve-concave'], ['nose/nose-curve-convex']),
    'mouth_width': (['mouth/mouth-scale-horiz-decr'], ['mouth/mouth-scale-horiz-incr']),
    'mouth_corners': (['mouth/mouth-angles-down'], ['mouth/mouth-angles-up']),
    'jaw_angle': (['chin/chin-bones-decr'], ['chin/chin-bones-incr']),
    'age': (['head/head-age-decr'], ['head/head-age-incr']),
    'ear_size': (['ears/l-ear-scale-decr', 'ears/r-ear-scale-decr'], ['ears/l-ear-scale-incr', 'ears/r-ear-scale-incr']),
    'ear_out': (['ears/l-ear-flap-decr', 'ears/r-ear-flap-decr'], ['ears/l-ear-flap-incr', 'ears/r-ear-flap-incr']),
}
# a slider at ±1 sets its targets to this (tuned on the slider sheet: at 1.0
# the eye and mouth ones barely showed, the ears and nose tip went far)
SLIDER_GAIN = {'eye_size': 0.8, 'eye_spacing': 0.7, 'eye_height': 0.7, 'eye_tilt': 0.9, 'eyelids': 1.0,
               'eye_bags': 1.0, 'nose_tip': 0.7, 'ear_size': 0.7, 'ear_out': 0.7, 'age': 0.8,
               'mouth_width': 0.8, 'mouth_corners': 0.8}
# looks.json `faces` (but "default") -> whole-face targets, at FACE_TYPE_WEIGHT
FACE_TYPES = {
    'oval': ['head/head-oval'], 'round': ['head/head-round'], 'square': ['head/head-square'],
    'triangular': ['head/head-triangular'], 'diamond': ['head/head-diamond'],
}
FACE_TYPE_WEIGHT = 0.7


def smooth_(a, b, x):
    t = min(1.0, max(0.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


def log(*a):
    print('[head]', *a, flush=True)


# ------------------------------------------------------------------ the hero
rig = bpy.data.objects['GameRig']
# the source blend is saved posed (a clip frame): fit and preview in the rest pose
rig.data.pose_position = 'REST'
old_head = bpy.data.objects['Hero_Head']
dg = bpy.context.evaluated_depsgraph_get()
old_pts = np.array([old_head.matrix_world @ v.co for v in old_head.data.vertices])
CROWN = float(old_pts[:, 2].max())
CUT = float(old_pts[:, 2].min())
log('old head crown %.4f cut %.4f verts %d' % (CROWN, CUT, len(old_pts)))


def ring(pts, z0, z1):
    sel = pts[(pts[:, 2] > z0) & (pts[:, 2] < z1)]
    c = sel[:, :2].mean(0)
    r = np.linalg.norm(sel[:, :2] - c, axis=1)
    return c, float(r.mean()), sel


# ------------------------------------------------------------------ MPFB human
def human_info():
    ph = TargetService.get_default_macro_info_dict()
    ph.update(PHENOTYPE)
    ph["race"] = dict(RACE)
    return {
        "name": "MH", "phenotype": ph, "rig": "",
        "eyes": "high-poly/high-poly.mhclo",
        "eyebrows": "%s/%s.mhclo" % (BROWS['classic'], BROWS['classic']),
        "eyelashes": "%s/%s.mhclo" % (LASHES, LASHES),
        "teeth": "", "tongue": "", "hair": "", "proxy": "",
        "targets": [{"target": t, "value": v} for t, v in BASE_FACE.items()],
        "clothes": [],
        "skin_mhmat": "%s/%s.mhmat" % (SKIN, SKIN),
        "skin_material_type": "MAKESKIN", "eyes_material_type": "MAKESKIN",
        "skin_material_settings": {}, "eyes_material_settings": {},
        "expressions": [], "alternative_materials": {},
    }


settings = HumanService.get_default_deserialization_settings()
settings["scale"] = 0.1
settings["subdiv_levels"] = 0
base = HumanService.deserialize_from_dict(human_info(), settings)
for name, asset in BROWS.items():
    if name != 'classic':
        HumanService.add_mhclo_asset(os.path.join(MPFB_USER, 'eyebrows', asset, asset + '.mhclo'), base,
                                     asset_type="Eyebrows", subdiv_levels=0, set_up_rigging=False,
                                     interpolate_weights=False, import_subrig=False, import_weights=False)
parts = {}
for o in bpy.data.objects:
    if o.type != 'MESH' or o == base or o.name.startswith('Hero_'):
        continue
    if 'high-poly' in o.name.lower():
        parts['eyes'] = o
    elif 'eyelash' in o.name.lower():
        parts['lashes'] = o
    else:
        for bname, asset in BROWS.items():
            if asset in o.name.lower():
                parts['brow_' + bname] = o
log('parts', {k: (v.name, len(v.data.vertices)) for k, v in parts.items()})
missing = [b for b in BROWS if 'brow_' + b not in parts]
assert not missing, missing


def mix_coords(obj):
    """World positions of `obj` with all its shape keys mixed."""
    me = obj.data
    if me.shape_keys:
        k = obj.shape_key_add(name='__mix', from_mix=True)
        co = np.array([obj.matrix_world @ d.co for d in k.data])
        obj.shape_key_remove(k)
        return co
    return np.array([obj.matrix_world @ v.co for v in me.vertices])


def refit_parts():
    for o in parts.values():
        ClothesService.fit_clothes_to_human(o, base, set_parent=False)


def snapshot():
    """Base mesh + every part, world positions, as they are now."""
    refit_parts()
    snap = {'base': mix_coords(base)}
    for k, o in parts.items():
        snap[k] = np.array([o.matrix_world @ v.co for v in o.data.vertices])
    return snap


# ------------------------------------------------------------------ keys
target_keys = {}


def target_key(name):
    if name not in target_keys:
        path = os.path.join(MPFB_SYS, 'targets', name + '.target.gz')
        target_keys[name] = TargetService.load_target(base, path, weight=0.0, name='k_' + name.replace('/', '_'))
    return target_keys[name]


rest = snapshot()
variants = {}
for slider, (neg, pos) in FACE_SLIDERS.items():
    gain = SLIDER_GAIN.get(slider, 1.0)
    for side, names in (('neg', neg), ('pos', pos)):
        for n in names:
            target_key(n).value = gain
        variants['face_%s_%s' % (slider, side)] = snapshot()
        for n in names:
            target_key(n).value = 0.0
for ftype, names in FACE_TYPES.items():
    for n in names:
        target_key(n).value = FACE_TYPE_WEIGHT
    variants['face_type_' + ftype] = snapshot()
    for n in names:
        target_key(n).value = 0.0
log('measured %d keys' % len(variants))

# ------------------------------------------------------------------ fit onto the hero
# the body's own faces (base.obj group "body"; the rest are MPFB helpers)
body_faces, cur = [], None
for line in open(os.path.join(MPFB_SYS, '3dobjs', 'base.obj')):
    if line.startswith('g '):
        cur = line.split()[1]
    elif line.startswith('f ') and cur == 'body':
        body_faces.append([int(t.split('/')[0]) - 1 for t in line.split()[1:]])
body_ids = np.array(sorted({i for f in body_faces for i in f}))
H = float(rest['base'][body_ids, 2].max())
S = CROWN / H
oc, orad, _ = ring(old_pts, CUT + 0.03, CUT + 0.05)
sb = rest['base'][body_ids] * S
near_axis = sb[(np.abs(sb[:, 0]) < 0.12) & (np.abs(sb[:, 1]) < 0.16)]
nc, nrad, _ = ring(near_axis, CUT + 0.03, CUT + 0.05)
T = np.array([oc[0] - nc[0], oc[1] - nc[1], 0.0])
log('MakeHuman height %.4f -> scale %.4f, neck centre shift (%.4f, %.4f), neck radius %.4f -> %.4f'
    % (H, S, T[0], T[1], nrad, orad))
NECK_TOP = CUT + 0.07
NECK_LOW = CUT + 0.015


def to_hero(co):
    """MakeHuman world positions -> on the hero: scaled, centred, and the low
    neck eased to the old neck's girth (the collars were fitted to it)."""
    p = co * S + T
    f = np.clip((NECK_TOP - p[:, 2]) / (NECK_TOP - NECK_LOW), 0.0, 1.0)
    f = f * f * (3 - 2 * f)
    k = 1.0 + (orad / nrad - 1.0) * f
    p[:, 0] = oc[0] + (p[:, 0] - oc[0]) * k
    p[:, 1] = oc[1] + (p[:, 1] - oc[1]) * k
    return p


rest_h = {k: to_hero(v) for k, v in rest.items()}
var_h = {name: {k: to_hero(v) for k, v in snap.items()} for name, snap in variants.items()}

# ------------------------------------------------------------------ cut the head and neck
# MakeHuman's head UV island (u > 0.6) holds the face, the cranium and the
# neck's front and back; the neck's sides are on the torso island. Both are
# kept above NECK_KEEP (the shoulders' slope starts below it), then the
# bottom ring is extended straight down under the collar, its radius eased
# to the old neck's, and the two islands' texels are packed side by side
# into the head texture.
uv_layer = base.data.uv_layers.active.data
face_uv = {}
for poly in base.data.polygons:
    face_uv[tuple(poly.vertices)] = [tuple(uv_layer[li].uv) for li in poly.loop_indices]


def in_head_island(f):
    fuv = face_uv[tuple(f)]
    return sum(u for u, _v in fuv) / len(fuv) > 0.6


NECK_KEEP = CUT + 0.035


def near_axis_xy(i):
    p = rest_h['base'][i]
    return math.hypot(p[0] - oc[0], p[1] - oc[1]) < 0.12


keep_faces = [f for f in body_faces if tuple(f) in face_uv and all(rest_h['base'][i, 2] >= NECK_KEEP for i in f)
              and (in_head_island(f) or all(near_axis_xy(i) for i in f))]
keep_ids = sorted({i for f in keep_faces for i in f})
new_index = {old: k for k, old in enumerate(keep_ids)}
log('head faces %d (torso island %d) verts %d' % (len(keep_faces), sum(not in_head_island(f) for f in keep_faces), len(keep_ids)))


def make_mesh(name, verts, faces, uvs):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(v) for v in verts], [], faces)
    uvl = me.uv_layers.new(name='UVMap')
    for poly, fuv in zip(me.polygons, uvs):
        for k, loop in enumerate(poly.loop_indices):
            uvl.data[loop].uv = fuv[k]
    return me


head_faces = [[new_index[i] for i in f] for f in keep_faces]
head_uvs = [list(face_uv[tuple(f)]) for f in keep_faces]
# 0 the head island, 1 / 2 the torso island's neck side at +x / -x
face_island = [0 if in_head_island(f) else (1 if rest_h['base'][f, 0].mean() > oc[0] else 2) for f in keep_faces]

edge_use = {}
for fi, f in enumerate(head_faces):
    for a, b in zip(f, f[1:] + f[:1]):
        edge_use.setdefault((min(a, b), max(a, b)), []).append((fi, a, b))
low_z = rest_h['base'][keep_ids, 2].min()
rim = [(fi, a, b) for e, uses in edge_use.items() if len(uses) == 1
       for fi, a, b in uses if max(rest_h['base'][keep_ids[a], 2], rest_h['base'][keep_ids[b], 2]) < NECK_KEEP + 0.025]
rim_verts = sorted({v for _fi, a, b in rim for v in (a, b)})
N0 = len(keep_ids)
row1 = {v: N0 + k for k, v in enumerate(rim_verts)}
row2 = {v: N0 + len(rim_verts) + k for k, v in enumerate(rim_verts)}
parents = np.array(rim_verts + rim_verts)
rest_rim = rest_h['base'][keep_ids][rim_verts]
rim_r = np.hypot(rest_rim[:, 0] - oc[0], rest_rim[:, 1] - oc[1])
ease = orad / rim_r.mean()
offsets = []
for frac in (0.5, 1.0):
    o = np.zeros((len(rim_verts), 3))
    o[:, 2] = ((CUT - 0.006) - rest_rim[:, 2]) * frac
    k = 1.0 + (ease - 1.0) * frac
    o[:, 0] = (rest_rim[:, 0] - oc[0]) * (k - 1.0)
    o[:, 1] = (rest_rim[:, 1] - oc[1]) * (k - 1.0)
    offsets.append(o)
offsets = np.concatenate(offsets)
for fi, a, b in rim:
    # the new rows mirror the rim face's texels (the row above the rim), so
    # the skin continues instead of one texel row stretched into streaks
    f = head_faces[fi]
    fuv = dict(zip(f, head_uvs[fi]))
    ua, ub = fuv[a], fuv[b]
    ia, ib = f.index(a), f.index(b)
    up_a = fuv[f[(ia - 1) % len(f)]] if len(f) == 4 else ua
    up_b = fuv[f[(ib + 1) % len(f)]] if len(f) == 4 else ub
    head_faces.append([b, a, row1[a], row1[b]])
    head_uvs.append([ub, ua, up_a, up_b])
    head_faces.append([row1[b], row1[a], row2[a], row2[b]])
    head_uvs.append([up_b, up_a, ua, ub])
    face_island += [face_island[fi]] * 2
log('neck extended: %d rim edges, %d verts, ring radius %.4f -> %.4f, bottom %.4f -> %.4f'
    % (len(rim), len(rim_verts), rim_r.mean(), orad, low_z, CUT - 0.006))


def with_neck(coords):
    c = np.asarray(coords)
    return np.concatenate([c, c[parents] + offsets])


# the extended rows take the skin MakeHuman paints there: each corner reads
# the UV of the nearest point on the body's torso island below the cut (the
# real neck base and collarbone texels; a stretched rim row read as streaks)
n_orig = len(keep_faces)
torso = [f for f in body_faces if tuple(f) in face_uv and not in_head_island(f)]
t_tris, t_uv = [], []
for f in torso:
    fuv = face_uv[tuple(f)]
    for k in range(1, len(f) - 1):
        t_tris.append((f[0], f[k], f[k + 1]))
        t_uv.append((fuv[0], fuv[k], fuv[k + 1]))
t_tris = np.array(t_tris)
t_uv = np.array(t_uv)
torso_bvh = BVHTree.FromPolygons(rest_h['base'].tolist(), t_tris.tolist())
_all = with_neck(rest_h['base'][keep_ids])


def torso_uv(p):
    loc, _n, ti, _d = torso_bvh.find_nearest(Vector(p))
    a, b, c = rest_h['base'][t_tris[ti]]
    v0, v1, v2 = b - a, c - a, np.array(loc) - a
    d00, d01, d11, d20, d21 = v0 @ v0, v0 @ v1, v1 @ v1, v2 @ v0, v2 @ v1
    den = d00 * d11 - d01 * d01
    w1 = (d11 * d20 - d01 * d21) / den if den else 0.0
    w2 = (d00 * d21 - d01 * d20) / den if den else 0.0
    return tuple(t_uv[ti][0] * (1 - w1 - w2) + t_uv[ti][1] * w1 + t_uv[ti][2] * w2)


for fi in range(n_orig, len(head_faces)):
    f = head_faces[fi]
    head_uvs[fi] = [torso_uv(_all[v]) for v in f]
    face_island[fi] = 1 if _all[f].mean(0)[0] > oc[0] else 2

# the head texture: the head island's texels copied (box 0), and each neck
# side unrolled round the neck axis into a strip at the same texel density,
# resampled from the torso island (its faces are spread over half the torso
# texture, a copied box would be mostly waste)
TEX_W = TEX_H = 2048
PAD = 12
old_uvs = [list(f) for f in head_uvs]
all_rest = with_neck(rest_h['base'][keep_ids])
us = np.array([uv for f, i in zip(head_uvs, face_island) if i == 0 for uv in f])
bx0 = max(0, int(us[:, 0].min() * TEX_W) - PAD); bx1 = min(TEX_W, int(math.ceil(us[:, 0].max() * TEX_W)) + PAD)
by0 = max(0, int(us[:, 1].min() * TEX_H) - PAD); by1 = min(TEX_H, int(math.ceil(us[:, 1].max() * TEX_H)) + PAD)
box = [bx0, by0, bx1 - bx0, by1 - by0]
# texels per metre on the head island
dens = []
for f, i, fuv in zip(head_faces, face_island, head_uvs):
    if i == 0 and len(f) >= 3:
        p0, p1, p2 = all_rest[f[0]], all_rest[f[1]], all_rest[f[2]]
        a3 = np.linalg.norm(np.cross(p1 - p0, p2 - p0))
        q0, q1, q2 = (np.array(x) * TEX_W for x in fuv[:3])
        a2 = abs(np.cross(q1 - q0, q2 - q0))
        if a3 > 1e-9:
            dens.append(math.sqrt(a2 / a3))
DENSITY = float(np.median(dens))
strips = {}
for side in (1, 2):
    vids = sorted({v for f, i in zip(head_faces, face_island) if i == side for v in f})
    pts = all_rest[vids]
    sx = 1.0 if side == 1 else -1.0
    ang = np.arctan2(pts[:, 1] - oc[1], (pts[:, 0] - oc[0]) * sx)
    rad = np.hypot(pts[:, 0] - oc[0], pts[:, 1] - oc[1]).mean()
    strips[side] = {'amin': ang.min(), 'amax': ang.max(), 'zmin': pts[:, 2].min(), 'zmax': pts[:, 2].max(), 'r': rad,
                    'sx': sx, 'w': int(math.ceil((ang.max() - ang.min()) * rad * DENSITY)) + 2 * PAD,
                    'h': int(math.ceil((pts[:, 2].max() - pts[:, 2].min()) * DENSITY)) + 2 * PAD}
dest = {0: (0, 0), 1: (box[2], 0), 2: (box[2], strips[1]['h'])}
PACK_W = (box[2] + max(strips[1]['w'], strips[2]['w']) + 3) // 4 * 4
PACK_H = (max(box[3], strips[1]['h'] + strips[2]['h']) + 3) // 4 * 4


def strip_px(side, p):
    st = strips[side]
    a_ = math.atan2(p[1] - oc[1], (p[0] - oc[0]) * st['sx'])
    x = PAD + (a_ - st['amin']) * st['r'] * DENSITY
    y = PAD + (p[2] - st['zmin']) * DENSITY
    return dest[side][0] + x, dest[side][1] + y


for fi, isl in enumerate(face_island):
    if isl == 0:
        dx, dy = dest[0]
        head_uvs[fi] = [((u * TEX_W - box[0] + dx) / PACK_W, (v * TEX_H - box[1] + dy) / PACK_H) for u, v in head_uvs[fi]]
    else:
        head_uvs[fi] = [(x / PACK_W, y / PACK_H) for x, y in (strip_px(isl, all_rest[v]) for v in head_faces[fi])]
log('skin pack %dx%d: head box %s, neck strips %s, %.0f texels/m'
    % (PACK_W, PACK_H, box, [(strips[k]['w'], strips[k]['h']) for k in (1, 2)], DENSITY))
me = make_mesh('Face_Head_lo', with_neck(rest_h['base'][keep_ids]), head_faces, head_uvs)
for p in me.polygons:
    p.use_smooth = True
lo = bpy.data.objects.new('Face_Head_lo', me)
bpy.context.scene.collection.objects.link(lo)
# MakeHuman's own regions ride through the subdivision as vertex groups
REGIONS = ('scalp', 'lips', 'ears')
for rname in REGIONS:
    src = base.vertex_groups[rname].index
    g = lo.vertex_groups.new(name=rname)
    for k, old in enumerate(keep_ids):
        for ge in base.data.vertices[old].groups:
            if ge.group == src and ge.weight > 0:
                g.add([k], ge.weight, 'REPLACE')
sub = lo.modifiers.new('sub', 'SUBSURF')
sub.levels = sub.render_levels = 1
sub.uv_smooth = 'NONE'   # linear: the packed strips were resampled on the cage's UVs


def subdivided(coords):
    lo.data.vertices.foreach_set('co', np.asarray(coords, dtype=np.float32).ravel())
    lo.data.update()
    ev = lo.evaluated_get(bpy.context.evaluated_depsgraph_get())
    out = np.zeros(len(ev.data.vertices) * 3, dtype=np.float32)
    ev.data.vertices.foreach_get('co', out)
    return out.reshape(-1, 3)


hi_rest = subdivided(with_neck(rest_h['base'][keep_ids]))
hi_keys = {name: subdivided(with_neck(snap['base'][keep_ids])) for name, snap in var_h.items()}
subdivided(with_neck(rest_h['base'][keep_ids]))
head_me = bpy.data.meshes.new_from_object(lo.evaluated_get(bpy.context.evaluated_depsgraph_get()))
head_me.name = 'Face_Head'
head = bpy.data.objects.new('Face_Head', head_me)
bpy.context.scene.collection.objects.link(head)
region_w = {r: np.zeros(len(head_me.vertices)) for r in REGIONS}
gname = [g.name for g in head.vertex_groups] or list(REGIONS)
for v in head_me.vertices:
    for ge in v.groups:
        region_w[gname[ge.group]][v.index] = ge.weight
head.vertex_groups.clear()
for v in head_me.vertices:
    pass
log('regions', {r: int((w > 0.5).sum()) for r, w in region_w.items()})


def joint(name):
    gi = base.vertex_groups[name].index
    ids = [v.index for v in base.data.vertices if any(g.group == gi for g in v.groups)]
    return rest_h['base'][ids].mean(0)


LM = {n: joint('joint-' + n) for n in ('l-eye', 'r-eye', 'mouth', 'jaw', 'head', 'neck')}
log('landmarks', {k: tuple(np.round(v, 4)) for k, v in LM.items()})

# ------------------------------------------------------------------ the lid margins
# MakeHuman's own eyelash proxy is fitted with its roots on the lid margins:
# its vertices touching the skin are the roots, the ones furthest from it
# the tips. Binned along each lid (inner = toward the nose -> outer corner)
# they give the margin line and the designed lash direction there.
MARGINS = {}
mh_lash = rest_h['lashes']
_hb = BVHTree.FromPolygons(hi_rest.tolist(), [tuple(p.vertices) for p in head_me.polygons])
d_skin = np.array([_hb.find_nearest(Vector(p))[3] for p in mh_lash])
for side in ('l', 'r'):
    centre = LM[side + '-eye']
    out_sign = 1.0 if centre[0] > 0 else -1.0
    near = np.abs(mh_lash[:, 0] - centre[0]) < 0.03
    MARGINS[side] = {'centre': centre, 'out': out_sign}
    for lid, sel in (('upper', mh_lash[:, 2] > centre[2] - 0.002), ('lower', mh_lash[:, 2] <= centre[2] - 0.002)):
        idx = np.where(near & sel)[0]
        pts, ds = mh_lash[idx], d_skin[idx]
        xo = (pts[:, 0] - centre[0]) * out_sign
        bins = np.linspace(xo.min(), xo.max(), 13)
        roots, dirs = [], []
        for b0, b1 in zip(bins[:-1], bins[1:]):
            inb = np.where((xo >= b0) & (xo <= b1))[0]
            if len(inb) < 2:
                continue
            order = inb[np.argsort(ds[inb])]
            k = max(1, len(order) // 3)
            r_, t_ = pts[order[:k]].mean(0), pts[order[-k:]].mean(0)
            roots.append(r_)
            dirs.append((t_ - r_) / max(np.linalg.norm(t_ - r_), 1e-9))
        MARGINS[side][lid] = np.array(roots)
        MARGINS[side][lid + '_dir'] = np.array(dirs)
    log('lid margin %s: upper %d lower %d points, root-skin %.2f mm'
        % (side, len(MARGINS[side]['upper']), len(MARGINS[side]['lower']), 1000 * d_skin[near].min()))
bpy.data.objects.remove(lo)
log('subdivided head verts %d faces %d' % (len(head_me.vertices), len(head_me.polygons)))


def add_keys(obj, rest_co, keys, tol=2e-5):
    obj.shape_key_add(name='Basis')
    added = 0
    for name, co in keys.items():
        if np.abs(co - rest_co).max() < tol:
            continue
        k = obj.shape_key_add(name=name)
        k.data.foreach_set('co', np.asarray(co, dtype=np.float32).ravel())
        added += 1
    return added


log('head keys', add_keys(head, hi_rest, hi_keys))

# ------------------------------------------------------------------ the parts
new_parts = {'eyes': 'Face_Eyes', 'lashes': 'Face_Lashes'}
new_parts.update({'brow_' + b: 'Face_Brow_' + b for b in BROWS})
part_objs = {}
for key, name in new_parts.items():
    pm = parts[key].data.copy()
    ob = bpy.data.objects.new(name, pm)
    bpy.context.scene.collection.objects.link(ob)
    if pm.shape_keys:
        ob.shape_key_clear()
    co = rest_h[key]
    pm.vertices.foreach_set('co', co.astype(np.float32).ravel())
    pm.update()
    n = add_keys(ob, co, {vn: var_h[vn][key] for vn in var_h})
    part_objs[key] = ob
    log('part %s verts %d keys %d' % (name, len(pm.vertices), n))

# ------------------------------------------------------------------ skin to the rig
old_w = []
for v in old_head.data.vertices:
    old_w.append({old_head.vertex_groups[g.group].name: g.weight for g in v.groups if g.weight > 1e-4})
kd = kdtree.KDTree(len(old_pts))
for i, p in enumerate(old_pts):
    kd.insert(Vector(p), i)
kd.balance()


def skin(obj, rigid=None):
    obj.parent = rig
    mod = obj.modifiers.new('Armature', 'ARMATURE')
    mod.object = rig
    groups = {}
    for v in obj.data.vertices:
        if rigid:
            w = {rigid: 1.0}
        else:
            acc = {}
            for _co, idx, d in kd.find_n(obj.matrix_world @ v.co, 6):
                iw = 1.0 / max(d, 1e-4)
                for g, gw in old_w[idx].items():
                    acc[g] = acc.get(g, 0.0) + gw * iw
            s = sum(acc.values())
            w = {g: x / s for g, x in acc.items() if x / s > 0.01}
        for g, x in w.items():
            if g not in groups:
                groups[g] = obj.vertex_groups.new(name=g)
            groups[g].add([v.index], x, 'REPLACE')


skin(head)
for ob in part_objs.values():
    skin(ob, rigid='Head')
log('skinned; head groups', [g.name for g in head.vertex_groups])
bpy.context.view_layer.update()
_ev = head.evaluated_get(bpy.context.evaluated_depsgraph_get())
_z = [(head.matrix_world @ v.co).z for v in _ev.data.vertices]
log('head z %.4f..%.4f (rest data %.4f..%.4f)' % (min(_z), max(_z), hi_rest[:, 2].min(), hi_rest[:, 2].max()))

# ------------------------------------------------------------------ images (numpy, rows bottom-up = v)
def load_img(path):
    im = bpy.data.images.load(path)
    im.colorspace_settings.name = 'Non-Color'
    w, h = im.size
    px = np.empty(w * h * 4, np.float32)
    im.pixels.foreach_get(px)
    bpy.data.images.remove(im)
    return px.reshape(h, w, 4)


def save_img(path, a):
    h, w = a.shape[:2]
    if a.shape[2] == 3:
        a = np.concatenate([a, np.ones((h, w, 1), np.float32)], 2)
    im = bpy.data.images.new('__out', w, h, alpha=True)
    im.colorspace_settings.name = 'Non-Color'
    im.pixels.foreach_set(np.clip(a, 0, 1).astype(np.float32).ravel())
    im.filepath_raw = path
    im.file_format = 'PNG'
    im.save()
    bpy.data.images.remove(im)


def blur(a, r):
    """Separable box blur, three passes (~gaussian), edges clamped."""
    out = a.astype(np.float32)
    for _ in range(3):
        for axis in (0, 1):
            pad = [(0, 0)] * out.ndim
            pad[axis] = (r, r)
            p = np.pad(out, pad, mode='edge')
            c = np.cumsum(p, axis=axis, dtype=np.float64)
            c = np.concatenate([np.zeros_like(np.take(c, [0], axis=axis)), c], axis=axis)
            n = out.shape[axis]
            out = ((np.take(c, np.arange(2 * r + 1, n + 2 * r + 1), axis=axis) -
                    np.take(c, np.arange(0, n), axis=axis)) / (2 * r + 1)).astype(np.float32)
    return out


def ramp(a, b, x):
    t = np.clip((np.asarray(x, dtype=np.float64) - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


# ------------------------------------------------------------------ the skin: the head islands of the photo skin
skin_light = load_img(os.path.join(MPFB_USER, 'skins', SKIN, 'young_lightskinned_male_diffuse2.png'))
skin_dark = load_img(os.path.join(MPFB_USER, 'skins', 'young_african_male', 'young_darkskinned_male_diffuse.png'))
TH, TW = skin_light.shape[:2]
assert (TW, TH) == (TEX_W, TEX_H)


def sample(img, px, py):
    """Bilinear lookup of img (rows = v) at pixel coordinates."""
    h, w = img.shape[:2]
    x = np.clip(px - 0.5, 0, w - 1.001); y = np.clip(py - 0.5, 0, h - 1.001)
    x0_ = np.floor(x).astype(int); y0_ = np.floor(y).astype(int)
    fx = (x - x0_)[..., None]; fy = (y - y0_)[..., None]
    return ((img[y0_, x0_] * (1 - fx) + img[y0_, x0_ + 1] * fx) * (1 - fy) +
            (img[y0_ + 1, x0_] * (1 - fx) + img[y0_ + 1, x0_ + 1] * fx) * fy)


def pack(img):
    out = np.zeros((PACK_H, PACK_W, img.shape[2]), np.float32)
    x0_, y0_, w_, h_ = box
    out[0:h_, 0:w_] = img[y0_:y0_ + h_, x0_:x0_ + w_]
    cover = np.zeros((PACK_H, PACK_W), np.float32)
    for f, isl, nuv, ouv in zip(head_faces, face_island, head_uvs, old_uvs):
        if isl == 0:
            continue
        for k in range(1, len(f) - 1):
            idx = [0, k, k + 1]
            q = np.array([nuv[j] for j in idx]) * [PACK_W, PACK_H]
            o = np.array([ouv[j] for j in idx]) * [TEX_W, TEX_H]
            xa, ya = np.floor(q.min(0)).astype(int); xb, yb = np.ceil(q.max(0)).astype(int)
            gx, gy = np.meshgrid(np.arange(xa, xb + 1) + 0.5, np.arange(ya, yb + 1) + 0.5)
            (ax_, ay_), (bx_, by_), (cx_, cy_) = q
            den = (by_ - cy_) * (ax_ - cx_) + (cx_ - bx_) * (ay_ - cy_)
            if abs(den) < 1e-9:
                continue
            l1 = ((by_ - cy_) * (gx - cx_) + (cx_ - bx_) * (gy - cy_)) / den
            l2 = ((cy_ - ay_) * (gx - cx_) + (ax_ - cx_) * (gy - cy_)) / den
            l3 = 1 - l1 - l2
            inside = (l1 >= -0.05) & (l2 >= -0.05) & (l3 >= -0.05)
            if not inside.any():
                continue
            ox = l1 * o[0, 0] + l2 * o[1, 0] + l3 * o[2, 0]
            oy = l1 * o[0, 1] + l2 * o[1, 1] + l3 * o[2, 1]
            vals = sample(img, ox[inside], oy[inside])
            yy, xx = np.nonzero(inside)
            out[ya + yy, xa + xx] = vals
            cover[ya + yy, xa + xx] = 1
    # grow the strips' edges so filtering never reads black
    region = np.zeros_like(cover); region[:, box[2]:] = 1
    for _ in range(PAD):
        grown = blur(out * cover[..., None], 1); wsum = blur(cover, 1)
        empty = (cover == 0) & (wsum > 0.01) & (region > 0)
        out[empty] = grown[empty] / wsum[empty][..., None]
        cover[empty] = 1
    out[..., 3] = 1.0
    return out


def island_mask():
    """1 on texels the head's faces cover (pack UVs), eroded by a texel:
    MakeHuman's islands end in darker edge texels that filtering pulled
    onto the neck as lines."""
    m = np.zeros((PACK_H, PACK_W), np.float32)
    for fuv in head_uvs:
        q = np.array(fuv) * [PACK_W, PACK_H]
        for k in range(1, len(q) - 1):
            tri = q[[0, k, k + 1]]
            xa, ya = np.floor(tri.min(0)).astype(int); xb, yb = np.ceil(tri.max(0)).astype(int)
            xa, ya = max(xa, 0), max(ya, 0); xb, yb = min(xb, PACK_W - 1), min(yb, PACK_H - 1)
            if xb < xa or yb < ya:
                continue
            gx, gy = np.meshgrid(np.arange(xa, xb + 1) + 0.5, np.arange(ya, yb + 1) + 0.5)
            (ax_, ay_), (bx_, by_), (cx_, cy_) = tri
            den = (by_ - cy_) * (ax_ - cx_) + (cx_ - bx_) * (ay_ - cy_)
            if abs(den) < 1e-9:
                continue
            l1 = ((by_ - cy_) * (gx - cx_) + (cx_ - bx_) * (gy - cy_)) / den
            l2 = ((cy_ - ay_) * (gx - cx_) + (ax_ - cx_) * (gy - cy_)) / den
            inside = (l1 >= 0) & (l2 >= 0) & (1 - l1 - l2 >= 0)
            m[ya:yb + 1, xa:xb + 1][inside] = 1.0
    eroded = np.minimum.reduce([np.roll(m, sh, ax) for sh in (-1, 0, 1) for ax in (0, 1)])
    return eroded


def fill_outside(img, mask, steps=24):
    out = img.copy()
    cover = mask.copy()
    for _ in range(steps):
        grown = blur(out * cover[..., None], 1)
        wsum = blur(cover, 1)
        empty = (cover == 0) & (wsum > 0.01)
        out[empty] = grown[empty] / wsum[empty][..., None]
        cover[empty] = 1.0
    out[..., 3] = 1.0
    return out


MASK = island_mask()
albedo = fill_outside(pack(skin_light), MASK)
albedo_dark = fill_outside(pack(skin_dark), MASK)
log('island texels %.1f %% of the pack' % (100 * MASK.mean()))
CW, CH = PACK_W, PACK_H
uvl = head_me.uv_layers.active.data
uv = np.zeros(len(uvl) * 2, np.float32)
uvl.foreach_get('uv', uv)
uv = uv.reshape(-1, 2)
# the lash line: the lid's skin darkens where the lashes grow (a thin dark
# line along the upper lid, fainter under the eye)
def _dist_to(points, poly):
    d = np.full(len(points), 1e9)
    for a_, b_ in zip(poly[:-1], poly[1:]):
        ab = b_ - a_
        t = np.clip(((points - a_) @ ab) / max(ab @ ab, 1e-12), 0, 1)
        d = np.minimum(d, np.linalg.norm(points - (a_ + t[:, None] * ab), axis=1))
    return d


near_eye = np.zeros(len(hi_rest))
for m in MARGINS.values():
    du = _dist_to(hi_rest, m['upper'])
    dl = _dist_to(hi_rest, m['lower'])
    near_eye = np.maximum(near_eye, 0.5 * np.exp(-(du / 0.0011) ** 2) + 0.12 * np.exp(-(du / 0.003) ** 2))
    near_eye = np.maximum(near_eye, 0.28 * np.exp(-(dl / 0.0008) ** 2))
lash_line = raster_mesh(head_me, near_eye[:, None].astype(np.float32), CW, CH)[..., 0]
albedo[..., :3] *= (1.0 - lash_line)[..., None]
albedo_dark[..., :3] *= (1.0 - 0.6 * lash_line)[..., None]
save_img(os.path.join(OUT, 'head_albedo.png'), albedo)
save_img(os.path.join(OUT, 'head_albedo_dark.png'), albedo_dark)

# detail normal: the photo's fine shading (pores, creases) as height
lum = albedo[..., :3] @ np.array([0.3, 0.59, 0.11], np.float32)
hp = lum - blur(lum, 4)
NORMAL_STRENGTH = 3.0
gx = (np.roll(hp, -1, 1) - np.roll(hp, 1, 1)) * 0.5 * NORMAL_STRENGTH
gy = (np.roll(hp, -1, 0) - np.roll(hp, 1, 0)) * 0.5 * NORMAL_STRENGTH
n = np.stack([-gx, -gy, np.ones_like(gx)], -1)
n /= np.linalg.norm(n, axis=-1, keepdims=True)
save_img(os.path.join(OUT, 'head_normal.png'), n * 0.5 + 0.5)

# ------------------------------------------------------------------ face zones (beard, oil, redness, scalp)
P = hi_rest
E = (LM['l-eye'] + LM['r-eye']) / 2
M = LM['mouth']
ear_y = float(P[region_w['ears'] > 0.5, 1].mean())
ax = np.abs(P[:, 0])
front = ramp(ear_y - 0.005, ear_y - 0.035, P[:, 1])
below = ramp(E[2] - 0.03, E[2] - 0.055, P[:, 2])
sideburn = ramp(E[2] + 0.012, E[2] - 0.008, P[:, 2]) * ramp(0.048, 0.06, ax)
neck_limit = ramp(M[2] - 0.115, M[2] - 0.085, P[:, 2])
nose = ramp(0.028, 0.016, ax) * ramp(M[2] + 0.012, M[2] + 0.022, P[:, 2])
lips = np.clip(region_w['lips'] * 1.6, 0, 1)
beard = np.maximum(below, sideburn) * front * neck_limit * (1 - nose) * (1 - lips)
nose_ridge = ramp(0.026, 0.008, ax) * ramp(M[2] + 0.012, M[2] + 0.03, P[:, 2]) * ramp(E[2] + 0.02, E[2], P[:, 2])
forehead = ramp(0.06, 0.025, ax) * ramp(E[2] + 0.025, E[2] + 0.045, P[:, 2]) * ramp(E[2] + 0.1, E[2] + 0.075, P[:, 2]) * front
oil = np.maximum(np.maximum(nose_ridge, 0.6 * forehead), 0.8 * lips)
tip = P[np.argmin(P[:, 1] + 10 * (ax > 0.01))]
cheek = np.exp(-(((ax - 0.042) / 0.018) ** 2 + ((P[:, 2] - (E[2] - 0.035)) / 0.02) ** 2)) * front
nose_tip = np.exp(-np.sum((P - tip) ** 2, 1) / 0.012 ** 2)
red = np.clip(np.maximum(np.maximum(cheek, nose_tip), 0.7 * region_w['ears']), 0, 1)
fields = np.stack([beard, oil, red, region_w['scalp']], 1).astype(np.float32)
log('zones: beard %d oil %d red %d scalp %d verts' % tuple(int((fields[:, i] > 0.5).sum()) for i in range(4)))


def raster(mesh, uvs, vfield, w, h):
    """Interpolate a per-vertex field over the UV triangles into an image."""
    img = np.zeros((h, w, vfield.shape[1]), np.float32)
    cover = np.zeros((h, w), np.float32)
    for poly in mesh.polygons:
        li = list(poly.loop_indices)
        vi = list(poly.vertices)
        for k in range(1, len(li) - 1):
            tri_uv = uvs[[li[0], li[k], li[k + 1]]] * [w, h]
            tri_f = vfield[[vi[0], vi[k], vi[k + 1]]]
            xa, ya = np.floor(tri_uv.min(0)).astype(int)
            xb, yb = np.ceil(tri_uv.max(0)).astype(int)
            xa, ya = max(xa, 0), max(ya, 0)
            xb, yb = min(xb, w - 1), min(yb, h - 1)
            if xb < xa or yb < ya:
                continue
            gx, gy = np.meshgrid(np.arange(xa, xb + 1) + 0.5, np.arange(ya, yb + 1) + 0.5)
            (ax_, ay_), (bx, by), (cx, cy) = tri_uv
            den = (by - cy) * (ax_ - cx) + (cx - bx) * (ay_ - cy)
            if abs(den) < 1e-12:
                continue
            l1 = ((by - cy) * (gx - cx) + (cx - bx) * (gy - cy)) / den
            l2 = ((cy - ay_) * (gx - cx) + (ax_ - cx) * (gy - cy)) / den
            l3 = 1 - l1 - l2
            inside = (l1 >= -0.02) & (l2 >= -0.02) & (l3 >= -0.02)
            if not inside.any():
                continue
            val = l1[..., None] * tri_f[0] + l2[..., None] * tri_f[1] + l3[..., None] * tri_f[2]
            sub = img[ya:yb + 1, xa:xb + 1]
            sub[inside] = val[inside]
            cover[ya:yb + 1, xa:xb + 1][inside] = 1
    # grow past the island edges so filtering never reads the empty background
    for _ in range(6):
        grown = blur(img * cover[..., None], 1)
        wsum = blur(cover, 1)
        empty = cover == 0
        img[empty] = (grown[empty] / np.maximum(wsum[empty][..., None], 1e-6))
        cover = np.maximum(cover, (wsum > 0.05).astype(np.float32))
    return img


ZW, ZH = CW // 2 // 4 * 4, CH // 2 // 4 * 4
zones = blur(raster(head_me, uv, fields, ZW, ZH), 2)
save_img(os.path.join(OUT, 'head_zones.png'), zones)

# ------------------------------------------------------------------ eyes: lid shadow baked on the eyeballs, cornea apart
eyes = part_objs['eyes']
em = eyes.data
eye_uv = np.zeros(len(em.uv_layers.active.data) * 2, np.float32)
em.uv_layers.active.data.foreach_get('uv', eye_uv)
eye_uv = eye_uv.reshape(-1, 2)
# MakeHuman's eye texture: two eyeball discs and the cornea's flat blue disc
CORNEA_UV, CORNEA_R = np.array([0.935, 0.065]), 0.07
cornea_face = []
for p in em.polygons:
    c = eye_uv[list(p.loop_indices)].mean(0)
    cornea_face.append(np.linalg.norm(c - CORNEA_UV) < CORNEA_R)
head_bvh = BVHTree.FromPolygons([tuple(v) for v in hi_rest], [tuple(p.vertices) for p in head_me.polygons])
ec = {s: LM[s + '-eye'] for s in ('l', 'r')}
eye_co = rest_h['eyes']
rng = np.random.default_rng(7)
dirs = rng.normal(size=(24, 3))
dirs /= np.linalg.norm(dirs, axis=1, keepdims=True)
ao = np.ones(len(eye_co))
for i, p in enumerate(eye_co):
    centre = ec['l'] if (p[0] > 0) == (ec['l'][0] > 0) else ec['r']
    out = p - centre
    out /= max(np.linalg.norm(out), 1e-6)
    if out[1] > 0.2:          # the back of the eyeball: never seen
        continue
    hits = 0
    total = 0
    for d in dirs:
        d = d if d @ out > 0 else -d
        d = (d + out) / np.linalg.norm(d + out)
        total += 1
        hit = head_bvh.ray_cast(Vector(p + d * 0.0005), Vector(d), 0.012)
        if hit[0] is not None:
            hits += 1
    ao[i] = 1.0 - hits / total
col = em.color_attributes.new('Col', 'FLOAT_COLOR', 'POINT')
for i, a in enumerate(ao):
    col.data[i].color = (a, a, a, 1.0)
log('eye lid shadow: mean %.2f min %.2f' % (ao.mean(), ao.min()))

import bmesh


def split_faces(src, name, keep):
    ob = src.copy()
    ob.data = src.data.copy()
    ob.name = name
    ob.data.name = name
    bpy.context.scene.collection.objects.link(ob)
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bm.faces.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[f for f, k in zip(bm.faces, keep) if not k], context='FACES')
    bm.to_mesh(ob.data)
    bm.free()
    return ob


cornea = split_faces(eyes, 'Face_Cornea', cornea_face)
eyeball = split_faces(eyes, 'Face_Eyeball', [not c for c in cornea_face])
bpy.data.objects.remove(eyes)


def face_outward(ob):
    # MakeHuman's eye normals point inward: the shaders cull back faces
    dots = []
    for poly in ob.data.polygons:
        c = np.array(poly.center)
        cen = ec['l'] if (c[0] > 0) == (ec['l'][0] > 0) else ec['r']
        dots.append(float(np.dot(np.array(poly.normal), c - cen)))
    if np.mean(dots) < 0:
        ob.data.flip_normals()
    return np.mean(dots) < 0


log('eye normals flipped: eyeball %s cornea %s' % (face_outward(eyeball), face_outward(cornea)))
part_objs['eyes'] = eyeball
part_objs['cornea'] = cornea

# ------------------------------------------------------------------ eyelashes
# Strips along each lid margin, inner -> outer corner; each column a lash
# direction that curls away from the eye (up for the upper lid, down for the
# lower one), longest on the outer third. The lash atlas (strand_atlas.py
# --lashes) is mapped along the strip (u) and root -> tip (v). Each column
# rides the head vertex nearest its root through the shape keys.
from mathutils import kdtree as _kd
_tree = _kd.KDTree(len(hi_rest))
for i, p in enumerate(hi_rest):
    _tree.insert(Vector(p), i)
_tree.balance()
LASH_V = {'upper': (1 - 8 / 512, 1 - 250 / 512), 'lower': (1 - 264 / 512, 1 - 400 / 512)}


def _resample(poly, n):
    """n points evenly spaced along the polyline by arc length."""
    cum = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(poly, axis=0), axis=1))])
    ts = np.linspace(0, cum[-1], n)
    return np.stack([np.interp(ts, cum, poly[:, k]) for k in range(3)], 1)


lv, lf, luv, lroot = [], [], [], []
fwd, up = np.array([0.0, -1.0, 0.0]), np.array([0.0, 0.0, 1.0])
for side, m in MARGINS.items():
    out = np.array([m['out'], 0.0, 0.0])
    for lid, n_cols in (('upper', 18), ('lower', 13)):
        pts = _resample(m[lid], n_cols)
        # the root line smoothed (a moving average keeps the strip from
        # crumpling); the lashes leave the lid forward and curl away from
        # the eye toward their tips
        sm = pts.copy()
        sm[1:-1] = (pts[:-2] + 2 * pts[1:-1] + pts[2:]) / 4
        pts = sm
        v_root, v_tip = LASH_V[lid]
        col0 = len(lv)
        for i, mp in enumerate(pts):
            s_ = i / (n_cols - 1)
            root = mp
            if lid == 'upper':
                length = 0.0058 + 0.0050 * smooth_(0.0, 0.65, s_) - 0.0022 * smooth_(0.88, 1.0, s_)
                d = fwd * 1.0 + up * 0.22 + out * 0.25 * s_
                curl = up * 0.55
            else:
                length = 0.0024 + 0.0018 * smooth_(0.1, 0.7, s_) - 0.001 * smooth_(0.88, 1.0, s_)
                d = fwd * 1.0 - up * 0.12 + out * 0.15 * s_
                curl = -up * 0.25
            d = d / np.linalg.norm(d)
            for t in (0.0, 0.5, 1.0):
                lv.append(root + d * length * t + curl * length * t * t)
                luv.append((s_, v_root + (v_tip - v_root) * t))
                lroot.append(_tree.find(Vector(mp))[1])
        for i in range(n_cols - 1):
            a0, b0 = col0 + i * 3, col0 + (i + 1) * 3
            lf.append((a0, b0, b0 + 1, a0 + 1))
            lf.append((a0 + 1, b0 + 1, b0 + 2, a0 + 2))
lv = np.array(lv)
lm = bpy.data.meshes.new('Face_Lashes')
lm.from_pydata(lv.tolist(), [], lf)
luvl = lm.uv_layers.new(name='UVMap')
for poly in lm.polygons:
    for loop, vi in zip(poly.loop_indices, poly.vertices):
        luvl.data[loop].uv = luv[vi]
for poly in lm.polygons:
    poly.use_smooth = True
lm.normals_split_custom_set_from_vertices([tuple(fwd)] * len(lv))
lashes_new = bpy.data.objects.new('Face_Lashes_new', lm)
bpy.context.scene.collection.objects.link(lashes_new)
lashes_new.shape_key_add(name='Basis')
lroot = np.array(lroot)
n_lk = 0
for name, co in hi_keys.items():
    dsp = (co - hi_rest)[lroot]
    if np.abs(dsp).max() < 2e-5:
        continue
    k = lashes_new.shape_key_add(name=name)
    k.data.foreach_set('co', (lv + dsp).astype(np.float32).ravel())
    n_lk += 1
skin(lashes_new, rigid='Head')
bpy.data.objects.remove(part_objs['lashes'])
lashes_new.name = 'Face_Lashes'
lashes_new.data.name = 'Face_Lashes'
part_objs['lashes'] = lashes_new
log('eyelashes: %d verts %d faces, follow %d keys' % (len(lv), len(lf), n_lk))
log('eyeball faces %d cornea faces %d' % (len(eyeball.data.polygons), len(cornea.data.polygons)))

# ------------------------------------------------------------------ small textures
import shutil
shutil.copy(os.path.join(MPFB_USER, 'eyes', 'materials', 'brown_eye.png'), os.path.join(OUT, 'eye.png'))
for bname, asset in BROWS.items():
    shutil.copy(os.path.join(MPFB_USER, 'eyebrows', asset, asset + '.png'), os.path.join(OUT, 'brow_%s.png' % bname))

# ------------------------------------------------------------------ materials (names only; the game assigns its shaders)
def slot(obj, name):
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    obj.data.materials.clear()
    obj.data.materials.append(mat)


slot(head, 'HF_Skin')
slot(eyeball, 'HF_Eye')
slot(cornea, 'HF_Cornea')
slot(part_objs['lashes'], 'HF_Lash')
for bname in BROWS:
    slot(part_objs['brow_' + bname], 'HF_Brow_' + bname)

meta = {
    'crown': CROWN, 'cut': CUT, 'scale': S, 'shift': T.tolist(),
    'eye_l': LM['l-eye'].tolist(), 'eye_r': LM['r-eye'].tolist(), 'mouth': LM['mouth'].tolist(),
    'ear_y': ear_y, 'skin_pack': {'box': box, 'size': [PACK_W, PACK_H], 'density': DENSITY},
}
json.dump(meta, open(os.path.join(WORK, 'head_meta.json'), 'w'), indent=1)
# the hair builder (hair_cards.py) grows its cards on MakeHuman's scalp
np.savez(os.path.join(WORK, 'head_regions.npz'), rest=hi_rest, scalp=region_w['scalp'], ears=region_w['ears'],
         lips=region_w['lips'])

# ------------------------------------------------------------------ save + export
for o in list(bpy.data.objects):
    if o.type == 'MESH' and o.name.startswith(('Hero_Hair', 'Hero_Beard', 'Hero_Brow', 'Hero_Eyes', 'Hero_Head')):
        o.hide_render = True
for o in [base] + [p for k, p in parts.items()]:
    if o.name in bpy.data.objects:
        o.hide_render = True
        o.hide_viewport = True
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(WORK, 'hero_head_work.blend'))

face_objs = [head] + list(part_objs.values())
bpy.ops.object.select_all(action='DESELECT')
for o in face_objs + [rig]:
    o.hide_set(False)
    o.hide_viewport = False
    o.select_set(True)
bpy.context.view_layer.objects.active = rig
bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, 'hero_head.glb'), export_format='GLB', use_selection=True,
                          export_skins=True, export_morph=True, export_morph_normal=False, export_tangents=True,
                          export_animations=False, export_materials='PLACEHOLDER', export_yup=True,
                          export_attributes=False, export_vertex_color='ACTIVE')
log('exported', os.path.join(OUT, 'hero_head.glb'), [o.name for o in face_objs])
log('done')
