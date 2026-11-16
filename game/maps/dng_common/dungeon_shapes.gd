extends RefCounted

## The dungeons' drawn shapes the server never has a collider for, built from
## code (dungeon_view.gd): barrel vaults with their end lunettes and arched
## ribs, rock skins over flat cave walls, rock ceilings, iron chain and
## rubble chunks. Everything is above head height, inside a wall's drawn
## stone, no more than a body's radius (0.35 m, realm_sim CAPSULE_RADIUS)
## proud of a wall, or low enough to step over.
##
## Meshes carry UVs in metres (u across / along the surface, v up or along
## the axis) with normals and tangents, for dungeon_surface.gdshader's
## mesh-UV mapping (a curved surface never shows the triplanar projection's
## axis seam).

## Where the mesh being built is centred: its vertices are stored relative to
## this (the view places the piece there, so batching cuts it on the right
## cell without a second copy of the mesh).
static var origin := Vector3.ZERO

## Godot draws clockwise triangles as front faces: a triangle is turned so
## its front faces `n`.
static func tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2) -> void:
	var face := (b - a).cross(c - a)
	if face.dot(na + nb + nc) > 0.0:
		var t := b; b = c; c = t
		var tn := nb; nb = nc; nc = tn
		var tu := ub; ub = uc; uc = tu
	st.set_normal(na); st.set_uv(ua); st.add_vertex(a - origin)
	st.set_normal(nb); st.set_uv(ub); st.add_vertex(b - origin)
	st.set_normal(nc); st.set_uv(uc); st.add_vertex(c - origin)

static func quad(st: SurfaceTool, p: Array, n: Array, uv: Array) -> void:
	tri(st, p[0], p[1], p[2], n[0], n[1], n[2], uv[0], uv[1], uv[2])
	tri(st, p[0], p[2], p[3], n[0], n[2], n[3], uv[0], uv[2], uv[3])

## The built surface as mesh arrays (vertex, normal, tangent, uv; not yet
## a mesh: the view batches them per cell and material, so nothing is sent
## to the GPU twice). `material` is the caller's to remember.
static func finish(st: SurfaceTool, _material: Material = null) -> Array:
	st.generate_tangents()
	return st.commit_to_arrays()

## A vault's cross-section over `span` rising `rise` from its springing:
## [{across, y (over the springing), n: Vector2 (across, y) inward, s: arc
## length}], `steps` + 1 points from one wall to the other.
static func arc_profile(span: float, rise: float, step: float = 0.8) -> Array:
	var radius := (span * span * 0.25 + rise * rise) / (2.0 * rise)
	var half := asin(clampf(span * 0.5 / radius, 0.0, 1.0))
	var centre_y := rise - radius
	var steps := maxi(8, ceili(radius * 2.0 * half / step))
	var out: Array = []
	for i in steps + 1:
		var a := -half + 2.0 * half * float(i) / steps
		out.append({"across": sin(a) * radius, "y": centre_y + cos(a) * radius,
			"n": Vector2(-sin(a), -cos(a)), "s": radius * (a + half)})
	return out

## A point on a vault: (across, y over the springing, along) -> world, for a
## vault centred on `centre` (x, springing y, z) running along z or along x.
static func vault_point(centre: Vector3, along_z: bool, across: float, y: float, along: float) -> Vector3:
	if along_z:
		return Vector3(centre.x + across, centre.y + y, centre.z + along)
	return Vector3(centre.x + along, centre.y + y, centre.z + across)

static func vault_dir(along_z: bool, across: float, y: float, along: float) -> Vector3:
	return Vector3(across, y, along) if along_z else Vector3(along, y, across)

## One length of barrel vault (along from `l0` to `l1`), its inside face.
static func vault_shell(centre: Vector3, along_z: bool, profile: Array, l0: float, l1: float, material: Material) -> Array:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in profile.size() - 1:
		var a: Dictionary = profile[i]
		var b: Dictionary = profile[i + 1]
		var na := vault_dir(along_z, a.n.x, a.n.y, 0.0)
		var nb := vault_dir(along_z, b.n.x, b.n.y, 0.0)
		quad(st, [vault_point(centre, along_z, a.across, a.y, l0), vault_point(centre, along_z, b.across, b.y, l0),
				vault_point(centre, along_z, b.across, b.y, l1), vault_point(centre, along_z, a.across, a.y, l1)],
			[na, nb, nb, na],
			[Vector2(a.s, l0), Vector2(b.s, l0), Vector2(b.s, l1), Vector2(a.s, l1)])
	return finish(st, material)

## The half-moon wall closing a vault's end at `along` above the springing,
## facing `inward` (+1: toward +along).
static func lunette(centre: Vector3, along_z: bool, profile: Array, along: float, inward: float, material: Material) -> Array:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := vault_dir(along_z, 0.0, 0.0, inward)
	var foot := vault_point(centre, along_z, 0.0, -0.05, along)
	for i in profile.size() - 1:
		var a: Dictionary = profile[i]
		var b: Dictionary = profile[i + 1]
		tri(st, foot, vault_point(centre, along_z, a.across, a.y, along), vault_point(centre, along_z, b.across, b.y, along),
			n, n, n, Vector2(0.0, 0.0), Vector2(a.across, a.y), Vector2(b.across, b.y))
	return finish(st, material)

## An arched rib under the vault at `along`: `width` along the axis, standing
## `depth` down from the vault's face.
static func rib(centre: Vector3, along_z: bool, profile: Array, along: float, width: float, depth: float, material: Material) -> Array:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var l0 := along - width * 0.5
	var l1 := along + width * 0.5
	for i in profile.size() - 1:
		var a: Dictionary = profile[i]
		var b: Dictionary = profile[i + 1]
		var ia := Vector2(a.across, a.y) + (a.n as Vector2) * depth
		var ib := Vector2(b.across, b.y) + (b.n as Vector2) * depth
		var na := vault_dir(along_z, a.n.x, a.n.y, 0.0)
		var nb := vault_dir(along_z, b.n.x, b.n.y, 0.0)
		# soffit
		quad(st, [vault_point(centre, along_z, ia.x, ia.y, l0), vault_point(centre, along_z, ib.x, ib.y, l0),
				vault_point(centre, along_z, ib.x, ib.y, l1), vault_point(centre, along_z, ia.x, ia.y, l1)],
			[na, nb, nb, na], [Vector2(a.s, 0.0), Vector2(b.s, 0.0), Vector2(b.s, width), Vector2(a.s, width)])
		# the two faces
		for side in [-1.0, 1.0]:
			var l := l0 if side < 0.0 else l1
			var ns := vault_dir(along_z, 0.0, 0.0, side)
			quad(st, [vault_point(centre, along_z, a.across, a.y, l), vault_point(centre, along_z, b.across, b.y, l),
					vault_point(centre, along_z, ib.x, ib.y, l), vault_point(centre, along_z, ia.x, ia.y, l)],
				[ns, ns, ns, ns], [Vector2(a.s, 0.0), Vector2(b.s, 0.0), Vector2(b.s, depth), Vector2(a.s, depth)])
	return finish(st, material)

## A rock ceiling's height over (x, z): a low dome over the room's inner
## rect `area` (springing at `spring`), dipping under the springing at the
## walls, broken up by the noise.
static func rock_height(noise: FastNoiseLite, area: Rect2, spring: float, rise: float, x: float, z: float) -> float:
	var c := area.get_center()
	var dx := absf(x - c.x) / maxf(area.size.x * 0.5, 0.5)
	var dz := absf(z - c.y) / maxf(area.size.y * 0.5, 0.5)
	var d := clampf(maxf(dx, dz) * 0.7 + Vector2(dx, dz).length() * 0.3, 0.0, 1.15)
	var dome := 1.0 - pow(minf(d, 1.0), 2.2)
	var n := noise.get_noise_2d(x, z)
	var crag := noise.get_noise_2d(x * 2.7 + 31.0, z * 2.7 - 17.0)
	return spring - 0.45 + rise * dome + 1.1 * n + 0.35 * crag

## One chunk of a rock ceiling ([x0, x1] x [z0, z1]), its underside, normals
## from the height grid itself (one cell past the chunk's edge, so chunks
## meet without a crease).
static func rock_ceiling(noise: FastNoiseLite, area: Rect2, spring: float, rise: float, x0: float, x1: float,
		z0: float, z1: float, step: float, material: Material) -> Array:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var nx := maxi(1, ceili((x1 - x0) / step))
	var nz := maxi(1, ceili((z1 - z0) / step))
	var dx := (x1 - x0) / nx
	var dz := (z1 - z0) / nz
	var w := nx + 3
	var h := PackedFloat32Array()
	h.resize(w * (nz + 3))
	for j in nz + 3:
		for i in w:
			h[j * w + i] = rock_height(noise, area, spring, rise, x0 + (i - 1) * dx, z0 + (j - 1) * dz)
	var pts: Array = []
	var nrm: Array = []
	for j in nz + 1:
		for i in nx + 1:
			var k := (j + 1) * w + i + 1
			pts.append(Vector3(x0 + i * dx, h[k], z0 + j * dz))
			var gx := (h[k + 1] - h[k - 1]) / (2.0 * dx)
			var gz := (h[k + w] - h[k - w]) / (2.0 * dz)
			# the underside faces down
			nrm.append(Vector3(gx, -1.0, gz).normalized())
	for j in nz:
		for i in nx:
			var k := j * (nx + 1) + i
			var p: Array = []
			var n: Array = []
			var uv: Array = []
			for q in [k, k + 1, k + nx + 2, k + nx + 1]:
				p.append(pts[q])
				n.append(nrm[q])
				uv.append(Vector2((pts[q] as Vector3).x, (pts[q] as Vector3).z))
			quad(st, p, n, uv)
	return finish(st, material)

## A rock skin over one face of a flat wall: the face at `plane` (world x for
## a wall along z, world z for one along x), facing `out` (+1 / -1 along that
## axis), from `u0` to `u1` along it and `y0` to `y1` up; the rock stands
## 0.03..0.25 m proud of the face, nothing at the wall's ends (`end0`,
## `end1`: the whole wall's, a skin is cut into lengths).
static func rock_skin(noise: FastNoiseLite, along_z: bool, plane: float, out: float, u0: float, u1: float,
		end0: float, end1: float, y0: float, y1: float, step: float, material: Material) -> Array:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var nu := maxi(1, ceili((u1 - u0) / step))
	var nv := maxi(1, ceili((y1 - y0) / step))
	var du := (u1 - u0) / nu
	var dv := (y1 - y0) / nv
	var w := nu + 3
	var d := PackedFloat32Array()
	d.resize(w * (nv + 3))
	for j in nv + 3:
		for i in w:
			d[j * w + i] = skin_depth(noise, along_z, plane, u0 + (i - 1) * du, y0 + (j - 1) * dv, end0, end1)
	var pts: Array = []
	var nrm: Array = []
	for j in nv + 1:
		for i in nu + 1:
			var k := (j + 1) * w + i + 1
			var u := u0 + i * du
			var y := y0 + j * dv
			var wv := plane + out * d[k]
			pts.append(Vector3(wv, y, u) if along_z else Vector3(u, y, wv))
			nrm.append(_skin_normal(along_z, out, (d[k + 1] - d[k - 1]) / (2.0 * du), (d[k + w] - d[k - w]) / (2.0 * dv)))
	for j in nv:
		for i in nu:
			var k := j * (nu + 1) + i
			var p: Array = []
			var n: Array = []
			var uv: Array = []
			for q in [k, k + 1, k + nu + 2, k + nu + 1]:
				p.append(pts[q])
				n.append(nrm[q])
				var v: Vector3 = pts[q]
				uv.append(Vector2(v.z if along_z else v.x, v.y))
			quad(st, p, n, uv)
	return finish(st, material)

## The outward normal of a skin whose depth (out along the face normal)
## changes `du` per metre along the wall and `dy` per metre up.
static func _skin_normal(along_z: bool, out: float, du: float, dy: float) -> Vector3:
	# surface P(u, y) = plane + out * d along the face axis; tangents
	# Tu = (u axis) + out * du * N, Ty = up + out * dy * N, N = the face normal
	var face := Vector3(out, 0.0, 0.0) if along_z else Vector3(0.0, 0.0, out)
	var u_axis := Vector3(0.0, 0.0, 1.0) if along_z else Vector3(1.0, 0.0, 0.0)
	var tu := u_axis + face * du
	var ty := Vector3.UP + face * dy
	var n := tu.cross(ty)
	if n.dot(face) < 0.0:
		n = -n
	return n.normalized()

static func skin_depth(noise: FastNoiseLite, along_z: bool, plane: float, u: float, y: float, end0: float, end1: float) -> float:
	var taper := smoothstep(0.0, 0.9, u - end0) * smoothstep(0.0, 0.9, end1 - u)
	var p := Vector3(plane, y, u) if along_z else Vector3(u, y, plane)
	var n := noise.get_noise_3d(p.x * 0.9, p.y * 1.4, p.z * 0.9) * 0.5 + 0.5
	# ledges: the rock's bedding, broken by the noise
	var bed := absf(sin(y * 1.9 + noise.get_noise_2d(u * 0.5, plane) * 3.0))
	return taper * clampf(0.03 + 0.17 * n + 0.06 * bed, 0.0, 0.25)

## A chain of iron links along `points` (a polyline), each link `link` m
## long, turned a quarter between neighbours: one mesh.
static func chain(points: PackedVector3Array, link: float, material: Material) -> Array:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var proto := TorusMesh.new()
	proto.inner_radius = link * 0.22
	proto.outer_radius = link * 0.42
	proto.rings = 8
	proto.ring_segments = 5
	var arrays := proto.get_mesh_arrays()
	var total := 0.0
	var lengths: Array = [0.0]
	for i in range(1, points.size()):
		total += points[i].distance_to(points[i - 1])
		lengths.append(total)
	var count := maxi(1, floori(total / (link * 0.72)))
	var seg := 0
	for k in count:
		var s := (float(k) + 0.5) * total / count
		while seg < points.size() - 2 and lengths[seg + 1] < s:
			seg += 1
		var a := points[seg]
		var b := points[seg + 1]
		var t := (s - float(lengths[seg])) / maxf(float(lengths[seg + 1]) - float(lengths[seg]), 0.001)
		var at := a.lerp(b, t)
		var dir := (b - a).normalized()
		var side := dir.cross(Vector3.UP)
		if side.length() < 0.1:
			side = dir.cross(Vector3.RIGHT)
		side = side.normalized()
		if k % 2 == 1:
			side = side.rotated(dir, PI * 0.5)
		# the torus lies in its x-z plane: x along the chain, stretched
		var basis := Basis(dir * 1.35, side.cross(dir).normalized(), side)
		var xf := Transform3D(basis, at)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for q in index.size():
			var v := index[q]
			st.set_normal((xf.basis * norms[v]).normalized())
			st.set_uv(Vector2(float(q % 7) * 0.1, float(k) * 0.1))
			st.add_vertex(xf * verts[v] - origin)
	return finish(st, material)

## A sagging chain between two points (a catenary-like droop of `sag` m).
static func sag_points(a: Vector3, b: Vector3, sag: float, steps: int = 10) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in steps + 1:
		var t := float(i) / steps
		out.append(a.lerp(b, t) - Vector3(0.0, sag * 4.0 * t * (1.0 - t), 0.0))
	return out

## A rough stone chunk (a squashed, jittered ball) about 1 m across: a few
## variants made once, scaled per placement.
static func chunk(seed: int) -> Array:
	origin = Vector3.ZERO
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var ball := SphereMesh.new()
	ball.radial_segments = 7
	ball.rings = 4
	ball.radius = 0.5
	ball.height = 0.7
	var arrays := ball.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	# one jitter per distinct position, so the seams stay shut
	var moved := {}
	for i in verts.size():
		var key := verts[i].snapped(Vector3(0.001, 0.001, 0.001))
		if not moved.has(key):
			var v := key * Vector3(rng.randf_range(0.8, 1.25), rng.randf_range(0.7, 1.1), rng.randf_range(0.8, 1.25))
			# cut faces: flatten toward a random plane now and then
			if rng.randf() < 0.35:
				v *= 0.85
			moved[key] = v
		verts[i] = moved[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for q in range(0, index.size(), 3):
		var a := verts[index[q]]
		var b := verts[index[q + 1]]
		var c := verts[index[q + 2]]
		var n := (b - a).cross(c - a).normalized()
		# faceted: a flat normal per face (cut stone), pointing outward
		if n.dot((a + b + c) / 3.0) < 0.0:
			n = -n
		tri(st, a, b, c, n, n, n, Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z))
	return st.commit_to_arrays()
