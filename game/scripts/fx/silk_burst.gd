extends RefCounted
class_name SilkBurst

## A web thing splitting open (creature_views.json rig `web_object`: an egg
## sac hatching or burnt, a cocoon broken or spent): a puff of torn silk, a
## spray of the fluid inside (an egg sac's), a wet splash settling on the
## floor and pale silk flecks thrown up and drifting down. Flipbooks and GPU
## motes only (FlipbookFX, RisingMotes); frees itself. Nothing is built on a
## headless process.
##
##   SilkBurst.play(parent, at, size, fluid)
##
## `size` is (width, height) of the thing, `fluid` the tint of what is
## inside it (transparent: dry silk, no spray).

const SILK := Color(0.86, 0.84, 0.9)
const FLECKS := Color(0.92, 0.9, 0.96)

static func play(parent: Node, at: Vector3, size: Vector2, fluid: Color) -> void:
	if parent == null or not parent.is_inside_tree() or DisplayServer.get_name() == "headless":
		return
	var width := maxf(0.6, size.x)
	var height := maxf(0.6, size.y)
	var low := SkillFX.quality == "low"
	var layers: Array = [
		{"atlas": "smoke_puff_8x8_1k", "size": maxf(width, height) * 1.5, "height": height * 0.5, "fps": 20.0,
			"tint": SILK, "opacity": 0.7},
	]
	if fluid.a > 0.0:
		layers.append({"atlas": "smoke_puff_8x8_1k", "size": width * 1.05, "height": height * 0.35, "fps": 30.0,
			"delay": 0.03, "tint": fluid, "opacity": 0.55, "roll": randf() * TAU})
		layers.append({"atlas": "smoke_puff_8x8_1k", "size": width * 1.6, "height": 0.06, "flat": true, "fps": 12.0,
			"delay": 0.1, "tint": fluid.darkened(0.3), "opacity": 0.4, "roll": randf() * TAU})
	if not low:
		layers.append({"atlas": "smoke_puff_8x8_1k", "size": width * 1.9, "height": 0.35, "fps": 12.0, "delay": 0.2,
			"tint": SILK.darkened(0.35), "opacity": 0.4})
	var fx := FlipbookFX.play(parent, at, layers, {"name": "SilkBurst", "life": 3.2})
	if fx == null:
		return
	var flecks := RisingMotes.make(width * 0.45, 4.0, FLECKS, 18 if low else 44, 1.6, Vector2(1.2, 3.8),
		Vector2(0.018, 0.045), true)
	flecks.position = Vector3(0, height * 0.35, 0)
	fx.add_child(flecks)
	flecks.emitting = true
