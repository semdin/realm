extends RefCounted

## The grounds' baked vegetation and prop instances
## (assets/terrain/grounds/scatter/<variant>.bin: float32 x, y, z, yaw, scale
## per instance), the files the old world's trunk and boulder colliders were
## built from too (the server's map pack has them; vegetation layer 32, the
## player collides with them, creatures and bolts pass through).

const DIR := "res://assets/terrain/grounds/"


## Raw instances of one variant as PackedFloat32Array (5 floats per instance).
static func instances(variant: String) -> PackedFloat32Array:
	var path := DIR + "scatter/" + variant + ".bin"
	if not FileAccess.file_exists(path):
		return PackedFloat32Array()
	return FileAccess.get_file_as_bytes(path).to_float32_array()


static func transform_of(data: PackedFloat32Array, i: int) -> Transform3D:
	var o := i * 5
	var s := data[o + 4]
	var basis := Basis(Vector3.UP, data[o + 3]).scaled(Vector3(s, s, s))
	return Transform3D(basis, Vector3(data[o], data[o + 1], data[o + 2]))
