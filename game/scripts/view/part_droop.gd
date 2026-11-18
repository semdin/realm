extends SkeletonModifier3D
class_name PartDroop

## A multi-part boss's fallen parts on its model (the old game's part_droop):
## Wheelwarden's slumped head, the Brinebriar's withered vine. It runs after
## the AnimationPlayer, so the clip keeps playing on everything else, and bends
## (about each bone's local X) and shrinks the bone chain of every part that is
## down, eased in so a part sags rather than snaps. Presentation only: which
## parts are down comes from the snapshot (CreatureView.set_parts_down).

## Part key (L / M / R / T) -> bone names, root first.
var chains: Dictionary = {}
## The part keys to bend.
var down: Array = []
## Degrees each bone of a downed chain bends and the scale it shrinks to (1.0:
## its size kept).
var bend_degrees := 22.0
var shrink := 1.0
## Per second the sag eases in (or out, when a part stands again).
var ease_rate := 0.8
## key -> 0..1
var _blend: Dictionary = {}
## key -> bone indices (looked up once).
var _bones: Dictionary = {}

## How far part `key` has sagged (0 standing, 1 fully down).
func sag(key: String) -> float:
	return float(_blend.get(key, 0.0))

func _process_modification_with_delta(delta: float) -> void:
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	for key: String in chains.keys():
		var target := 1.0 if down.has(key) else 0.0
		var t := move_toward(float(_blend.get(key, 0.0)), target, delta * ease_rate)
		_blend[key] = t
		if t <= 0.0:
			continue
		if not _bones.has(key):
			var found: Array = []
			for bone_name: Variant in chains[key]:
				var idx := skeleton.find_bone(String(bone_name))
				if idx >= 0:
					found.append(idx)
			_bones[key] = found
		var turn := Quaternion(Vector3.RIGHT, deg_to_rad(bend_degrees) * t)
		var scale_to := lerpf(1.0, shrink, t)
		for idx: int in _bones[key]:
			skeleton.set_bone_pose_rotation(idx, skeleton.get_bone_pose_rotation(idx) * turn)
			if scale_to != 1.0:
				skeleton.set_bone_pose_scale(idx, skeleton.get_bone_pose_scale(idx) * scale_to)
