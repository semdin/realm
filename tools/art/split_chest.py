# Splits the loot chest (one closed generated mesh, art/loot_chest/loot_chest.glb)
# into Body and Lid for the opening animation (ChestView). Headless:
#   blender -b --python tools/art/split_chest.py -- ../art/loot_chest/loot_chest.glb
#       game/assets/models/environment/loot_chest.glb [preview_dir]
# The cut is the lid seam (z = SEAM, Blender up). The body's open top gets a
# rim WALL wide and a cavity CAVITY deep, the lid's underside a rim and a
# shallow hollow; those faces take the material "ChestInside" (the game draws
# it with chest_inside.gdshader). The lid's origin is the hinge on the back top
# edge (Blender +Y is the back: the lock faces -Y; Godot -Z), so the game
# swings it about its own X axis (negative opens).
import bpy, bmesh, sys, math
from mathutils import Vector, geometry

argv = sys.argv[sys.argv.index("--") + 1:]
SRC, DST = argv[0], argv[1]
PREVIEW = argv[2] if len(argv) > 2 else ""
SEAM = 0.238
WALL = 0.016
CAVITY = 0.17
LID_HOLLOW = 0.06

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
src = next(o for o in bpy.context.scene.objects if o.type == "MESH")
src.data.transform(src.matrix_world)
src.matrix_world.identity()

inside = bpy.data.materials.new("ChestInside")
inside.use_nodes = True
bsdf = next(n for n in inside.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
bsdf.inputs["Base Color"].default_value = (0.11, 0.06, 0.035, 1.0)
bsdf.inputs["Roughness"].default_value = 0.85
src.data.materials.append(inside)
INSIDE = len(src.data.materials) - 1


def piece(name, keep_above):
    ob = src.copy()
    ob.data = src.data.copy()
    ob.name = name
    ob.data.name = name
    bpy.context.scene.collection.objects.link(ob)
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-5)
    geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
    bmesh.ops.bisect_plane(bm, geom=geom, dist=1e-5, plane_co=(0, 0, SEAM), plane_no=(0, 0, 1),
                           clear_inner=keep_above, clear_outer=not keep_above)
    bm.verts.ensure_lookup_table()
    bm.verts.ensure_lookup_table()
    # the opening: the cut is a rectangle (the walls at x -0.335..0.336,
    # y -0.152..0.156; the hasp sticks out at the front), so the rim is one
    # a hair inside it, and the cavity is inset WALL from that
    X0, X1, Y0, Y1 = -0.333, 0.334, -0.150, 0.154
    centre = Vector(((X0 + X1) * 0.5, (Y0 + Y1) * 0.5, SEAM))
    def rect(inset):
        return [Vector((X0 + inset, Y0 + inset, SEAM)), Vector((X1 - inset, Y0 + inset, SEAM)),
                Vector((X1 - inset, Y1 - inset, SEAM)), Vector((X0 + inset, Y1 - inset, SEAM))]
    outer = [bm.verts.new(p) for p in rect(0.0)]
    inner = [bm.verts.new(p) for p in rect(WALL)]
    hull = outer
    depth = -CAVITY if keep_above is False else LID_HOLLOW
    floor = []
    for v in inner:
        c = v.co
        floor.append(bm.verts.new(Vector((centre.x + (c.x - centre.x) * 0.96, centre.y + (c.y - centre.y) * 0.93, SEAM + depth))))
    up = Vector((0, 0, 1)) if keep_above is False else Vector((0, 0, -1))
    made = []
    n = len(hull)
    for i in range(n):
        j = (i + 1) % n
        made.append((bm.faces.new((outer[i], outer[j], inner[j], inner[i])), up))
        wall = bm.faces.new((inner[i], inner[j], floor[j], floor[i]))
        made.append((wall, None))
    made.append((bm.faces.new(floor), up))
    for f, want in made:
        f.material_index = INSIDE
        f.normal_update()
        if want is None:
            want = (centre - f.calc_center_median())
            want.z = 0.0
        if f.normal.dot(want) < 0.0:
            f.normal_flip()
    # simple planar UVs on the inside faces (the shader draws grain from noise)
    uv = bm.loops.layers.uv.active
    for f in bm.faces:
        if f.material_index == INSIDE:
            n = f.normal
            for loop in f.loops:
                c = loop.vert.co
                if abs(n.z) > 0.7:
                    loop[uv].uv = (c.x * 2.0 + 0.5, c.y * 2.0 + 0.5)
                elif abs(n.x) > abs(n.y):
                    loop[uv].uv = (c.y * 2.0 + 0.5, c.z * 2.0)
                else:
                    loop[uv].uv = (c.x * 2.0 + 0.5, c.z * 2.0)
    bm.to_mesh(ob.data)
    bm.free()
    ob.data.update()
    return ob


body = piece("Body", False)
lid = piece("Lid", True)
bpy.data.objects.remove(src)
# the hinge: the back top edge of the body, at the lid's centre line
ys = [v.co.y for v in lid.data.vertices if abs(v.co.z - SEAM) < 0.02]
hinge = Vector((0.0, max(ys) - 0.01, SEAM))
print("hinge", hinge)
lid.data.transform(__import__("mathutils").Matrix.Translation(-hinge))
lid.location = hinge
lid.rotation_mode = "XYZ"
for ob in (body, lid):
    ob.parent = None
for ob in (body, lid):
    print(ob.name, len(ob.data.vertices), "verts", len(ob.data.polygons), "faces", [m.name for m in ob.data.materials])

if PREVIEW:
    sc = bpy.context.scene
    try:
        sc.render.engine = "BLENDER_EEVEE"
    except TypeError:
        pass
    sc.world = bpy.data.worlds.new("W")
    sc.world.use_nodes = True
    sc.world.node_tree.nodes["Background"].inputs[1].default_value = 2.5
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.data.energy = 4.0
    sun.rotation_euler = (math.radians(50), 0, math.radians(30))
    sc.collection.objects.link(sun)
    sc.render.resolution_x = 700
    sc.render.resolution_y = 500
    cam = bpy.data.objects.new("C", bpy.data.cameras.new("C"))
    sc.collection.objects.link(cam)
    sc.camera = cam
    lid.rotation_euler.x = math.radians(-105)
    for name, loc in [("open_front", (0.5, -1.1, 0.9)), ("open_side", (1.2, 0.2, 0.5))]:
        cam.location = loc
        cam.rotation_euler = (Vector((0, 0, 0.2)) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
        sc.render.filepath = PREVIEW + "/chest_" + name + ".png"
        bpy.ops.render.render(write_still=True)
    lid.rotation_euler.x = 0.0

bpy.ops.export_scene.gltf(filepath=DST, export_format="GLB", export_yup=True, export_apply=False,
                          export_image_format="AUTO", export_materials="EXPORT")
print("exported", DST)
