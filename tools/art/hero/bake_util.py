"""Image helpers for the Blender hero scripts (Blender's Python has numpy but
no PIL): PNG in/out through bpy images, a box blur, and a rasteriser that
paints a per-vertex field over a mesh's UV triangles."""
import bpy
import numpy as np


def load_img(path):
    """RGBA float array, rows bottom-up (row = v), values as stored."""
    im = bpy.data.images.load(path)
    im.colorspace_settings.name = 'Non-Color'
    w, h = im.size
    px = np.empty(w * h * 4, np.float32)
    im.pixels.foreach_get(px)
    bpy.data.images.remove(im)
    return px.reshape(h, w, 4)


def save_img(path, a):
    h, w = a.shape[:2]
    if a.ndim == 2:
        a = np.repeat(a[..., None], 3, 2)
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


def raster(mesh, vfield, w, h, grow=6):
    """Interpolate a per-vertex field (N x C) over the mesh's active UV map
    into an h x w x C image (rows = v), grown past the islands' edges."""
    uvl = mesh.uv_layers.active.data
    uvs = np.zeros(len(uvl) * 2, np.float32)
    uvl.foreach_get('uv', uvs)
    uvs = uvs.reshape(-1, 2)
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
    for _ in range(grow):
        grown = blur(img * cover[..., None], 1)
        wsum = blur(cover, 1)
        empty = cover == 0
        img[empty] = grown[empty] / np.maximum(wsum[empty][..., None], 1e-6)
        cover = np.maximum(cover, (wsum > 0.05).astype(np.float32))
    return img
