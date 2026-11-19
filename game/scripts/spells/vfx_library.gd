extends RefCounted
class_name VFXLibrary

## The spell effects' asset registry and composition table, plus the quality
## variants. Every SpellEffect builds its layers from this table; there is no
## second copy of the composition.
##
## Layer kinds
##   flipbook : one atlas cell on a quad (billboard or flat), animated by frame
##   sprite   : a single texture or an analytic glow (`energy_shape`)
##   particles: textured quads or GPU embers (`embers`) emitted over time
##   ribbon   : tapered strip driven by the followed body's motion history
##   trail    : wisps dropped in the world behind the followed body
##   arc      : jagged electric arcs re-struck several times a second
##   light    : a dynamic light with a curve
##
## Layer keys
##   core     : carries the gameplay information; never dropped by a variant
##   optional : dropped at low
## A stage's `audio` names a sound_library.json key (AudioManager).

const ATLAS_DIR := "res://assets/vfx/atlases/"
const TEX_DIR := "res://assets/vfx/tex/"
const MESH_DIR := "res://assets/vfx/meshes/"

const ASSETS := {
	# generated flipbooks (8 x 8, row-major)
	"vfx_fire_burst": {"path": ATLAS_DIR + "fire_burst_8x8_2k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 22},
	"vfx_smoke_puff": {"path": ATLAS_DIR + "smoke_puff_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 22},
	"vfx_explosion": {"path": ATLAS_DIR + "explosion_8x8_2k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 22},
	"vfx_burst_crimson": {"path": ATLAS_DIR + "burst_crimson_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 23},
	"vfx_burst_starfall": {"path": ATLAS_DIR + "burst_starfall_8x8_2k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 40},
	"vfx_starfall_orb": {"path": ATLAS_DIR + "starfall_orb_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 22},
	"vfx_burst_frost_grip": {"path": ATLAS_DIR + "burst_frost_grip_8x8_2k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 40},
	"vfx_frost_grip_orb": {"path": ATLAS_DIR + "frost_grip_orb_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 22},
	# Blender-rendered crackling orb (the stun bolt's flight)
	"vfx_flight_orb": {"path": ATLAS_DIR + "flight_orb_8x8_2k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 24},
	"vfx_ripple_blue": {"path": ATLAS_DIR + "ripple_blue_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 25},
	"vfx_shockwave": {"path": ATLAS_DIR + "shockwave_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 23},
	"vfx_wand_flash": {"path": ATLAS_DIR + "wand_flash_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 48},
	"vfx_spark_burst": {"path": ATLAS_DIR + "spark_burst_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 33},
	"vfx_energy_orb": {"path": ATLAS_DIR + "energy_orb_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 44},
	"vfx_fire_orb": {"path": ATLAS_DIR + "fire_orb_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 48},
	# stills
	"vfx_star_flare": {"path": TEX_DIR + "star_flare_256.png", "grid": Vector2(1, 1), "frames": 1},
	"vfx_hex_shield": {"path": TEX_DIR + "hex_shield_512.png", "grid": Vector2(1, 1), "frames": 1},
	"vfx_scorch_decal": {"path": TEX_DIR + "scorch_decal_512.png", "grid": Vector2(1, 1), "frames": 1},
	"vfx_energy_streak": {"path": TEX_DIR + "energy_streak_1024x256.png", "grid": Vector2(1, 1), "frames": 1},
	"vfx_noise_flow": {"path": TEX_DIR + "noise_flow_512.png", "grid": Vector2(1, 1), "frames": 1},
	"vfx_noise_erosion": {"path": TEX_DIR + "noise_erosion_512.png", "grid": Vector2(1, 1), "frames": 1},
	# Kenney Particle Pack ingredient (CC0): a detail sprite, never the effect
	"vfx_flame_static": {"path": "res://assets/vfx/flame_01.png", "grid": Vector2(1, 1), "frames": 1},
	"vfx_shield_mesh": {"mesh": MESH_DIR + "shield_shell.glb"},
}

## Layer presets shared by several spells, so a change lands once.
const LAYER_PRESETS := {
	"ground_scorch": {"kind": "sprite", "atlas": "vfx_scorch_decal", "blend": "alpha", "optional": true,
		"flat": true, "lift": 0.1, "size": 3.0, "life": 4.0, "fade": "slow"},
}

## The composition table: a wand flash at the tip, a looping orb core with a
## wake in flight, a signature burst on impact and a smoke/ember tail.
## `colour: true` tints a white asset with the spell colour ("accent" with its
## second colour); the coloured clips keep their own colour. `fit` plays the
## whole flipbook over the layer's life, `grow` scales it over life, `roll`
## gives each copy a random rotation so two copies never read as clones.
const SPELLS := {
	# The basic flick is a single spark in its caster's house (`house_colour`):
	# a tiny white-hot head on a hair-thin wake, sparks in the house's second
	# colour. Only sparks leave the wand, and the hit is a small spray of sparks.
	"basic_cast": {
		"colour": Color(1.0, 0.72, 0.28),
		"house_colour": true,
		# The drawn bolt bends off the straight line by this fraction of its
		# flight, a new angle every cast (CombatView).
		"curve": 0.12,
		"stages": {
			"cast": {"layers": [
				{"kind": "sprite", "energy_shape": 0, "blend": "add", "core": true, "colour": true,
					"size": 0.32, "life": 0.09, "fade": "out"},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": "accent", "core": true,
					"amount": 9, "life": 0.25, "speed": 3.2, "size": 0.1, "spread": 30.0, "gravity": -7.0, "forward": true},
			], "length": 0.15, "audio": "spell_basic_cast_cast"},
			"travel": {"layers": [
				{"kind": "sprite", "energy_shape": 0, "blend": "add", "core": true, "colour": true,
					"size": 0.24, "life": 0.0, "flicker": true},
				{"kind": "ribbon", "kinked": true, "blend": "add", "core": true, "colour": true,
					"width": 0.1, "length": 0.75, "life": 0.0},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": "accent", "core": true,
					"amount": 8, "life": 0.3, "speed": 0.6, "size": 0.07, "spread": 180.0, "gravity": -6.0, "continuous": true},
			], "length": 0.0, "audio": "spell_basic_cast_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "sprite", "energy_shape": 0, "blend": "add", "core": true, "colour": true,
					"size": 0.7, "life": 0.12, "fade": "out"},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": "accent", "core": true,
					"amount": 18, "life": 0.38, "speed": 4.5, "size": 0.12, "spread": 180.0, "gravity": -9.0},
				{"kind": "light", "colour": true, "energy": 1.2, "range": 2.2, "life": 0.1},
			], "length": 0.32, "audio": "spell_basic_cast_impact"},
		},
	},
	# A jet of red light: a crackling orb (Voronoi lightning veins in a red
	# glow) leaving a wisp trail that hangs where the bolt passed and
	# dissolves there, embers curling off it. At the hit a short white flash
	# throws a spray of embers that arc, bounce on the floor and cool from
	# white through red to a dull glow, over a wisp of smoke.
	"stun_bolt": {
		"colour": Color(1.0, 0.1, 0.08),
		"curve": 0.04,
		"stages": {
			"cast": {"layers": [
				{"kind": "sprite", "energy_shape": 0, "blend": "add", "core": true, "colour": true,
					"size": 0.9, "life": 0.16, "fade": "out"},
				{"kind": "particles", "embers": true, "core": true, "colour": true, "dir": "aim",
					"amount": 26, "life": 0.7, "speed": [2.0, 7.0], "size": [0.007, 0.02], "spread": 35.0,
					"gravity": 7.0, "drag": 2.5, "floor": true},
				{"kind": "flipbook", "atlas": "vfx_wand_flash", "blend": "add", "optional": true, "colour": true,
					"size": 0.7, "life": 0.18, "fit": true, "roll": true, "grow": [0.6, 1.2]},
				{"kind": "light", "colour": true, "energy": 1.4, "range": 2.5, "life": 0.18},
			], "length": 0.3, "audio": "spell_stun_bolt_cast"},
			"travel": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_flight_orb", "blend": "add", "core": true,
					"size": 0.95, "life": 0.0, "loop": true, "roll": true},
				{"kind": "trail", "core": true, "colour": true,
					"width": [0.3, 0.85], "span": 0.2, "rise": 0.3, "wander": 1.2, "hot": 0.25, "erosion": 0.95, "noise_scale": 0.9, "opacity": 0.75},
				{"kind": "particles", "embers": true, "core": true, "colour": true, "continuous": true,
					"amount": 70, "life": 0.9, "speed": [0.2, 1.4], "size": [0.006, 0.018], "spread": 180.0,
					"gravity": 2.5, "drag": 1.2, "turbulence": 5.0, "radius": 0.12, "energy": 0.9},
			], "length": 0.0, "audio": "spell_stun_bolt_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "sprite", "energy_shape": 0, "blend": "add", "core": true, "colour": "accent",
					"size": 1.1, "life": 0.08, "fade": "out"},
				{"kind": "sprite", "energy_shape": 0, "blend": "add", "core": true, "colour": true,
					"size": 1.8, "life": 0.14, "fade": "out", "opacity": 0.7},
				{"kind": "particles", "embers": true, "core": true, "colour": true, "dir": "back", "lift": 0.25,
					"amount": 110, "life": 1.4, "speed": [1.8, 7.0], "size": [0.009, 0.028], "spread": 70.0,
					"gravity": 9.0, "drag": 1.4, "floor": true, "bounce": 0.35, "radius": 0.1},
				{"kind": "particles", "embers": true, "optional": true, "colour": true, "dir": "up",
					"amount": 36, "life": 1.8, "speed": [0.4, 2.0], "size": [0.008, 0.022], "spread": 180.0,
					"gravity": 1.2, "drag": 1.6, "turbulence": 4.0, "radius": 0.2, "energy": 0.8},
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "optional": true,
					"size": 1.4, "life": 0.9, "fit": true, "roll": true, "opacity": 0.28, "grow": [0.7, 1.3]},
				{"kind": "arc", "optional": true, "colour": true,
					"amount": 3, "length": [0.3, 0.7], "width": 0.24, "core_px": 1.6, "glow": 0.7, "life": 0.2, "strike_hz": 24.0},
				{"kind": "light", "colour": true, "energy": 2.2, "range": 4.0, "life": 0.16},
			], "length": 1.8, "audio": "spell_stun_bolt_impact"},
			# While stunned the leftover charge drips off the body as the same
			# sparks the hit threw, falling from the shoulders to the ground
			# (StatusFX keeps it on the body for as long as the stun lasts).
			"sustain": {"layers": [
				{"kind": "particles", "embers": true, "core": true, "colour": true, "continuous": true, "forward": -0.6,
					"amount": 24, "life": 1.3, "speed": [0.2, 0.9], "size": [0.009, 0.022], "spread": 180.0,
					"gravity": 4.0, "drag": 1.2, "turbulence": 3.0, "radius": 0.28, "energy": 0.9, "floor": true, "bounce": 0.3},
			], "length": 1.8, "audio": "spell_stun_bolt_end"},
		},
	},
	"flame_wave": {
		"colour": Color(1.0, 0.42, 0.06),
		"stages": {
			# The cone: rolling fire bursts marching along the aim, each a beat
			# later and larger, plus embers thrown the full length.
			"cast": {"layers": [
				# core: three bursts spanning the cone (all that the low preset keeps)
				{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "add", "core": true,
					"size": 2.0, "forward": 1.0, "life": 0.6, "fit": true, "roll": true, "grow": [0.6, 1.15]},
				{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "add", "core": true,
					"size": 3.2, "forward": 3.1, "life": 0.62, "delay": 0.05, "fit": true, "roll": true, "grow": [0.6, 1.2]},
				{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "add", "core": true,
					"size": 4.4, "forward": 5.6, "life": 0.62, "delay": 0.1, "fit": true, "roll": true, "grow": [0.6, 1.25]},
				# fill: between and beyond, for a continuous jet on medium/high
				{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "add", "optional": true,
					"size": 2.6, "forward": 2.0, "life": 0.6, "delay": 0.03, "fit": true, "roll": true, "grow": [0.6, 1.15]},
				{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "add", "optional": true,
					"size": 3.8, "forward": 4.3, "life": 0.62, "delay": 0.08, "fit": true, "roll": true, "grow": [0.6, 1.2]},
				{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "add", "optional": true,
					"size": 4.8, "forward": 7.2, "life": 0.58, "delay": 0.14, "fit": true, "roll": true, "grow": [0.6, 1.25]},
				{"kind": "particles", "tex": "vfx_flame_static", "blend": "add", "colour": true, "optional": true,
					"amount": 30, "life": 0.7, "speed": 14.0, "size": 0.35, "spread": 24.0, "gravity": 1.5, "forward": true},
				{"kind": "light", "colour": true, "energy": 3.4, "range": 7.0, "life": 0.55},
			], "length": 0.8, "audio": "spell_flame_wave_cast"},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "add", "core": true,
					"size": 1.8, "life": 0.55, "fit": true, "roll": true},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 16, "life": 0.5, "speed": 3.5, "size": 0.06, "spread": 150.0, "gravity": -3.0},
				{"kind": "light", "colour": true, "energy": 2.5, "range": 4.0, "life": 0.3},
			], "length": 0.6, "audio": "spell_flame_wave_impact"},
		},
	},
	# A silver charge down a wide cone: rippling light rings marching along
	# the aim, star dust thrown the full length.
	"light_of_ithrel": {
		"colour": Color(0.82, 0.9, 1.0),
		"stages": {
			"cast": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_ripple_blue", "blend": "add", "core": true,
					"size": 2.4, "forward": 1.6, "life": 0.6, "fit": true, "roll": true, "grow": [0.6, 1.2]},
				{"kind": "flipbook", "atlas": "vfx_ripple_blue", "blend": "add", "core": true,
					"size": 3.8, "forward": 5.4, "life": 0.65, "delay": 0.08, "fit": true, "roll": true, "grow": [0.6, 1.3]},
				{"kind": "flipbook", "atlas": "vfx_ripple_blue", "blend": "add", "optional": true,
					"size": 5.0, "forward": 9.5, "life": 0.65, "delay": 0.16, "fit": true, "roll": true, "grow": [0.6, 1.35]},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 40, "life": 0.9, "speed": 18.0, "size": 0.12, "spread": 22.0, "gravity": 0.0, "forward": true},
				{"kind": "light", "colour": true, "energy": 4.0, "range": 9.0, "life": 0.7},
			], "length": 0.9, "audio": "spell_light_of_ithrel_cast"},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_ripple_blue", "blend": "add", "core": true,
					"size": 2.0, "life": 0.5, "fit": true, "roll": true},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 18, "life": 0.6, "speed": 3.0, "size": 0.07, "spread": 160.0, "gravity": -2.0},
			], "length": 0.6, "audio": "spell_light_of_ithrel_impact"},
		},
	},
	"shockwave": {
		"colour": Color(1.0, 0.55, 0.12),
		"stages": {
			"cast": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_wand_flash", "blend": "add", "core": true, "colour": true,
					"size": 1.2, "life": 0.26, "fit": true, "roll": true, "grow": [0.6, 1.4]},
				{"kind": "particles", "tex": "vfx_flame_static", "blend": "add", "colour": true, "optional": true,
					"amount": 10, "life": 0.35, "speed": 3.0, "size": 0.2, "spread": 40.0, "gravity": 1.0, "forward": true},
				{"kind": "light", "colour": true, "energy": 2.5, "range": 4.0, "life": 0.3},
			], "length": 0.35, "audio": "spell_shockwave_cast"},
			"travel": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_fire_orb", "blend": "add", "core": true,
					"size": 1.3, "life": 0.0, "loop": true, "roll": true},
				{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": true, "colour": true,
					"width": 0.4, "length": 4.0, "life": 0.0},
				{"kind": "particles", "tex": "vfx_flame_static", "blend": "add", "colour": true, "optional": true,
					"amount": 22, "life": 0.4, "speed": 0.6, "size": 0.22, "spread": 180.0, "gravity": 1.5, "continuous": true},
			], "length": 0.0, "audio": "spell_shockwave_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_explosion", "blend": "add", "core": true,
					"forward": -1.6, "size": 6.0, "life": 1.0, "fit": true, "roll": true},
				{"kind": "flipbook", "atlas": "vfx_shockwave", "blend": "add", "core": true, "colour": true,
					"flat": true, "lift": 0.15, "size": 2.0, "life": 0.6, "fit": true},
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "optional": true,
					"forward": -1.6, "size": 5.0, "life": 1.4, "delay": 0.25, "fit": true, "roll": true, "opacity": 0.5},
				"ground_scorch",
				{"kind": "light", "colour": true, "energy": 4.5, "range": 9.0, "life": 0.5},
			], "length": 1.4, "audio": "spell_shockwave_impact"},
		},
	},
	"disarm": {
		"colour": Color(1.0, 0.18, 0.5),
		"stages": {
			"cast": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_wand_flash", "blend": "add", "core": true, "colour": true,
					"size": 0.9, "life": 0.22, "fit": true, "roll": true, "grow": [0.6, 1.25]},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 10, "life": 0.28, "speed": 3.0, "size": 0.06, "spread": 35.0, "gravity": 0.0, "forward": true},
				{"kind": "light", "colour": true, "energy": 2.2, "range": 3.0, "life": 0.2},
			], "length": 0.28, "audio": "spell_disarm_cast"},
			"travel": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_energy_orb", "blend": "add", "core": true, "colour": true,
					"size": 0.95, "life": 0.0, "loop": true, "roll": true, "spin": true},
				{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": true, "colour": true,
					"width": 0.24, "length": 4.2, "life": 0.0},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 16, "life": 0.22, "speed": 0.6, "size": 0.05, "spread": 180.0, "gravity": 0.0, "continuous": true},
			], "length": 0.0, "audio": "spell_disarm_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_burst_crimson", "blend": "add", "core": true,
					"size": 2.2, "life": 0.6, "fit": true, "roll": true},
				{"kind": "flipbook", "atlas": "vfx_spark_burst", "blend": "add", "colour": true, "optional": true,
					"size": 1.6, "life": 0.4, "fit": true, "roll": true},
				{"kind": "light", "colour": true, "energy": 2.6, "range": 4.0, "life": 0.22},
			], "length": 0.6, "audio": "spell_disarm_impact"},
		},
	},
	# The ward's raise; the shell itself is WardShield.
	"ward_shield": {
		"colour": Color(0.25, 0.62, 1.0),
		"stages": {
			"cast": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_ripple_blue", "blend": "add", "core": true,
					"size": 2.8, "life": 0.5, "fit": true},
				{"kind": "light", "colour": true, "energy": 2.5, "range": 5.0, "life": 0.3},
			], "length": 0.5, "audio": "spell_ward_shield_cast"},
		},
	},
	# A spinning ice crystal that bursts into a frost nova. The impact clip
	# starts at its peak; the flash, spark spray and ground ring give the
	# burst its punch on the hit frame.
	"frost_grip": {
		"colour": Color(0.62, 0.9, 1.0),
		"stages": {
			"cast": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_wand_flash", "blend": "add", "core": true, "colour": true,
					"size": 1.4, "life": 0.3, "fit": true, "roll": true, "grow": [0.6, 1.4]},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 14, "life": 0.35, "speed": 1.6, "size": 0.07, "spread": 180.0, "gravity": -1.0},
				{"kind": "light", "colour": true, "energy": 2.6, "range": 4.5, "life": 0.35},
			], "length": 0.4, "audio": "spell_frost_grip_cast"},
			"travel": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_frost_grip_orb", "blend": "add", "core": true,
					"size": 1.9, "life": 0.0, "loop": true},
				{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": true, "colour": true,
					"width": 0.35, "length": 4.0, "life": 0.0},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 30, "life": 0.45, "speed": 0.6, "size": 0.06, "spread": 180.0, "gravity": -1.2, "continuous": true},
			], "length": 0.0, "audio": "spell_frost_grip_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_wand_flash", "blend": "add", "core": true, "colour": true,
					"forward": -1.5, "size": 4.5, "life": 0.28, "fit": true, "grow": [0.7, 1.6]},
				{"kind": "flipbook", "atlas": "vfx_burst_frost_grip", "blend": "add", "core": true,
					"forward": -1.5, "size": 6.5, "life": 1.4, "fit": true},
				{"kind": "flipbook", "atlas": "vfx_shockwave", "blend": "add", "core": true, "colour": true,
					"flat": true, "lift": 0.15, "size": 2.0, "life": 0.6, "fit": true},
				{"kind": "flipbook", "atlas": "vfx_spark_burst", "blend": "add", "colour": true, "optional": true,
					"forward": -1.5, "size": 3.2, "life": 0.45, "fit": true, "roll": true},
				{"kind": "light", "colour": true, "energy": 3.5, "range": 9.0, "life": 0.6},
			], "length": 1.4, "audio": "spell_frost_grip_impact"},
		},
	},
	# Starfall: a falling star (violet ring, white-gold core, stardust).
	"ultimate": {
		"colour": Color(0.72, 0.52, 1.0),
		"stages": {
			"cast": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_wand_flash", "blend": "add", "core": true, "colour": true,
					"size": 1.6, "life": 0.32, "fit": true, "roll": true, "grow": [0.6, 1.5]},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 18, "life": 0.4, "speed": 2.0, "size": 0.09, "spread": 180.0, "gravity": 0.0},
				{"kind": "light", "colour": true, "energy": 3.2, "range": 5.0, "life": 0.4},
			], "length": 0.45, "audio": "spell_ultimate_cast"},
			"travel": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_starfall_orb", "blend": "add", "core": true,
					"size": 2.2, "life": 0.0, "loop": true},
				{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": true, "colour": true,
					"width": 0.45, "length": 5.0, "life": 0.0},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 36, "life": 0.5, "speed": 0.8, "size": 0.08, "spread": 180.0, "gravity": 0.0, "continuous": true},
			], "length": 0.0, "audio": "spell_ultimate_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_burst_starfall", "blend": "add", "core": true,
					"forward": -2.0, "size": 8.0, "life": 1.6, "fit": true},
				{"kind": "flipbook", "atlas": "vfx_shockwave", "blend": "add", "core": true, "colour": true,
					"flat": true, "lift": 0.15, "size": 2.0, "life": 0.7, "fit": true},
				"ground_scorch",
				{"kind": "light", "colour": true, "energy": 4.0, "range": 12.0, "life": 0.8},
			], "length": 1.6, "audio": "spell_ultimate_impact"},
		},
	},
	# Hushing Gale: a short gust down the cone. Pale wind-smoke rolls out in
	# three beats, a pressure ripple leaves the wand and a stream of cold motes
	# is blown the cone's length; on each body a puff and a spray of motes
	# thrown back off it.
	"hushing_gale": {
		"colour": Color(0.72, 0.9, 0.96),
		"stages": {
			"cast": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_ripple_blue", "blend": "add", "core": true, "colour": true,
					"size": 2.0, "forward": 1.0, "life": 0.4, "fit": true, "roll": true, "grow": [0.5, 1.4]},
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "core": true, "colour": true,
					"size": 2.4, "forward": 1.6, "life": 0.55, "fit": true, "roll": true, "grow": [0.5, 1.3], "opacity": 0.55},
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "core": true, "colour": true,
					"size": 4.0, "forward": 4.0, "life": 0.6, "delay": 0.06, "fit": true, "roll": true, "grow": [0.5, 1.35], "opacity": 0.48},
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "optional": true, "colour": true,
					"size": 5.4, "forward": 6.6, "life": 0.6, "delay": 0.12, "fit": true, "roll": true, "grow": [0.5, 1.4], "opacity": 0.4},
				{"kind": "flipbook", "atlas": "vfx_ripple_blue", "blend": "add", "optional": true, "colour": true,
					"size": 3.4, "forward": 4.2, "life": 0.45, "delay": 0.05, "fit": true, "roll": true, "grow": [0.5, 1.4], "opacity": 0.7},
				{"kind": "particles", "embers": true, "core": true, "colour": true, "dir": "aim",
					"amount": 110, "life": 0.75, "speed": [7.0, 15.0], "size": [0.01, 0.024], "spread": 34.0,
					"gravity": 0.6, "drag": 1.6, "turbulence": 5.0, "radius": 0.2, "energy": 1.0, "stretch": 0.025},
				{"kind": "light", "colour": true, "energy": 1.6, "range": 5.0, "life": 0.3},
			], "length": 0.8, "audio": "spell_hushing_gale_cast"},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "core": true, "colour": true,
					"size": 1.4, "life": 0.5, "fit": true, "roll": true, "grow": [0.6, 1.3], "opacity": 0.4},
				{"kind": "particles", "embers": true, "core": true, "colour": true, "dir": "back", "lift": 0.2,
					"amount": 26, "life": 0.6, "speed": [2.0, 5.0], "size": [0.006, 0.014], "spread": 50.0,
					"gravity": 1.0, "drag": 1.8, "turbulence": 3.0, "radius": 0.15, "energy": 0.8},
			], "length": 0.6, "audio": "spell_hushing_gale_impact"},
		},
	},
	# Starnail: a white-blue splinter of starlight, small and fast, a long thin
	# streak behind it and star dust shed in flight; it strikes in a hard white
	# flash and a spray of sparks that skitter on the floor.
	"starnail": {
		"colour": Color(0.7, 0.82, 1.0),
		"stages": {
			"cast": {"layers": [
				{"kind": "sprite", "energy_shape": 0, "blend": "add", "core": true, "colour": "accent",
					"size": 0.7, "life": 0.12, "fade": "out"},
				{"kind": "flipbook", "atlas": "vfx_wand_flash", "blend": "add", "core": true, "colour": true,
					"size": 0.8, "life": 0.18, "fit": true, "roll": true, "grow": [0.6, 1.2]},
				{"kind": "particles", "embers": true, "optional": true, "colour": true, "dir": "aim",
					"amount": 18, "life": 0.5, "speed": [3.0, 9.0], "size": [0.006, 0.014], "spread": 18.0,
					"gravity": 3.0, "drag": 2.0},
				{"kind": "light", "colour": true, "energy": 1.6, "range": 3.0, "life": 0.16},
			], "length": 0.3, "audio": "spell_starnail_cast"},
			"travel": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_energy_orb", "blend": "add", "core": true, "colour": "accent",
					"size": 0.95, "life": 0.0, "loop": true, "roll": true, "spin": true},
				{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": true, "colour": true,
					"width": 0.22, "length": 7.0, "life": 0.0},
				{"kind": "particles", "embers": true, "core": true, "colour": true, "continuous": true,
					"amount": 40, "life": 0.6, "speed": [0.1, 0.8], "size": [0.005, 0.012], "spread": 180.0,
					"gravity": 0.5, "drag": 1.4, "turbulence": 3.0, "radius": 0.06, "energy": 1.0},
			], "length": 0.0, "audio": "spell_starnail_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "sprite", "energy_shape": 0, "blend": "add", "core": true, "colour": "accent",
					"size": 1.2, "life": 0.08, "fade": "out"},
				{"kind": "flipbook", "atlas": "vfx_spark_burst", "blend": "add", "core": true, "colour": true,
					"size": 1.6, "life": 0.35, "fit": true, "roll": true},
				{"kind": "particles", "embers": true, "core": true, "colour": true, "dir": "back", "lift": 0.3,
					"amount": 80, "life": 1.1, "speed": [2.5, 8.0], "size": [0.007, 0.02], "spread": 60.0,
					"gravity": 9.0, "drag": 1.4, "floor": true, "bounce": 0.4, "radius": 0.08},
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "optional": true,
					"size": 1.1, "life": 0.7, "fit": true, "roll": true, "opacity": 0.22, "grow": [0.7, 1.3]},
				{"kind": "light", "colour": true, "energy": 2.4, "range": 4.0, "life": 0.14},
			], "length": 1.2, "audio": "spell_starnail_impact"},
		},
	},
	# Shardglass Ward's raise (the shell itself is WardShield with the
	# shard-glass surface): a mint-pale ripple and glints of glass rising round
	# the caster.
	"shardglass_ward": {
		"colour": Color(0.55, 0.95, 0.85),
		"stages": {
			"cast": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_ripple_blue", "blend": "add", "core": true, "colour": true,
					"size": 3.2, "life": 0.55, "fit": true},
				{"kind": "particles", "embers": true, "core": true, "colour": true, "dir": "up",
					"amount": 40, "life": 1.0, "speed": [0.8, 2.6], "size": [0.008, 0.02], "spread": 70.0,
					"gravity": -0.4, "drag": 1.6, "turbulence": 2.0, "radius": 0.7, "energy": 1.0},
				{"kind": "light", "colour": true, "energy": 2.5, "range": 5.0, "life": 0.35},
			], "length": 0.6, "audio": "spell_shardglass_ward_cast"},
		},
	},
	# Dawnbreak: a narrow beam of warm dawn light. A flash at the wand, golden
	# streaks that fill the beam's length in a few tenths of a second and hang
	# as motes, pulses of light marching down it and glints thrown its length;
	# on each body a small burst of light.
	"dawnbreak": {
		"colour": Color(1.0, 0.82, 0.5),
		"stages": {
			"cast": {"layers": [
				{"kind": "sprite", "energy_shape": 0, "blend": "add", "core": true, "colour": "accent",
					"size": 1.4, "life": 0.24, "fade": "out"},
				# the beam: streaks of light shot down the aim in a tight fan, every
				# speed from slow to very fast under a hard drag, so in a few
				# tenths of a second they stand spread along the whole beam and
				# hang there as glowing motes while they cool
				{"kind": "particles", "embers": true, "core": true, "colour": true, "dir": "aim",
					"amount": 280, "life": 1.0, "speed": [6.0, 95.0], "size": [0.018, 0.04], "spread": 3.0,
					"gravity": -0.3, "drag": 3.3, "turbulence": 1.2, "radius": 0.2, "energy": 2.0, "stretch": 0.05},
				# pulses of light running down it, each a beat later
				{"kind": "flipbook", "atlas": "vfx_wand_flash", "blend": "add", "core": true, "colour": true,
					"size": 1.5, "forward": 2.0, "life": 0.42, "fit": true, "roll": true, "grow": [0.6, 1.2]},
				{"kind": "flipbook", "atlas": "vfx_spark_burst", "blend": "add", "core": true, "colour": true,
					"size": 1.7, "forward": 6.0, "life": 0.44, "delay": 0.04, "fit": true, "roll": true, "grow": [0.6, 1.2]},
				{"kind": "flipbook", "atlas": "vfx_wand_flash", "blend": "add", "optional": true, "colour": true,
					"size": 1.8, "forward": 10.0, "life": 0.44, "delay": 0.08, "fit": true, "roll": true, "grow": [0.6, 1.2]},
				{"kind": "flipbook", "atlas": "vfx_spark_burst", "blend": "add", "optional": true, "colour": true,
					"size": 2.0, "forward": 14.0, "life": 0.46, "delay": 0.12, "fit": true, "roll": true, "grow": [0.6, 1.2]},
				{"kind": "flipbook", "atlas": "vfx_wand_flash", "blend": "add", "optional": true, "colour": true,
					"size": 2.1, "forward": 18.5, "life": 0.46, "delay": 0.16, "fit": true, "roll": true, "grow": [0.6, 1.2]},
				{"kind": "flipbook", "atlas": "vfx_spark_burst", "blend": "add", "optional": true, "colour": true,
					"size": 2.3, "forward": 23.0, "life": 0.46, "delay": 0.2, "fit": true, "roll": true, "grow": [0.6, 1.2]},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": "accent", "optional": true,
					"amount": 56, "life": 0.85, "speed": 32.0, "size": 0.22, "spread": 5.0, "gravity": 0.0, "forward": true},
				{"kind": "light", "colour": true, "energy": 3.6, "range": 9.0, "life": 0.6},
			], "length": 0.9, "audio": "spell_dawnbreak_cast"},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_wand_flash", "blend": "add", "core": true, "colour": true,
					"size": 1.8, "life": 0.35, "fit": true, "roll": true, "grow": [0.6, 1.3]},
				{"kind": "particles", "embers": true, "core": true, "colour": true, "dir": "up",
					"amount": 30, "life": 1.0, "speed": [0.6, 2.4], "size": [0.008, 0.02], "spread": 120.0,
					"gravity": -0.6, "drag": 1.4, "turbulence": 2.5, "radius": 0.25, "energy": 1.2},
			], "length": 0.6, "audio": "spell_dawnbreak_impact"},
		},
	},
}

## Quality variants: fewer layers, no dynamic lights, fewer particles and
## coarser flipbook stepping at low, never dropping the layer that carries the
## gameplay information.
const QUALITY := {
	"low": {"max_layers": 3, "lights": false, "particles": 0.5, "frame_step": 2, "atlas_scale": 0.5, "sprite_scale": 0.5},
	"medium": {"max_layers": 5, "lights": true, "particles": 0.8, "frame_step": 1, "atlas_scale": 0.75, "sprite_scale": 0.75},
	"high": {"max_layers": 99, "lights": true, "particles": 1.0, "frame_step": 1, "atlas_scale": 1.0, "sprite_scale": 1.0},
}

static func asset(id: String) -> Dictionary:
	return ASSETS.get(id, {})

static func asset_path(id: String) -> String:
	var entry := asset(id)
	return String(entry.get("path", entry.get("mesh", "")))

static func has_spell(spell_id: String) -> bool:
	return SPELLS.has(spell_id)

static func stages_for(spell_id: String) -> Dictionary:
	return (SPELLS.get(spell_id, {}) as Dictionary).get("stages", {})

static func spell_colour(spell_id: String) -> Color:
	return (SPELLS.get(spell_id, {}) as Dictionary).get("colour", Color.WHITE)

## [colour, accent] a spell is drawn in. A `house_colour` spell takes its
## caster's house (houses.json): its main colour, the sparks its second (a dark
## second colour cannot be added light, so the sparks are a pale main colour
## instead), brightened to full value since dark shades vanish in additive
## light. Everything else keeps the table's colour.
static func colours_for(spell_id: String, house: String = "") -> Array:
	var base := spell_colour(spell_id)
	var houses: Variant = RealmContent.table("houses")
	var data: Dictionary = {}
	if bool((SPELLS.get(spell_id, {}) as Dictionary).get("house_colour", false)) and houses is Dictionary:
		data = (houses as Dictionary).get(house, {})
	if data.is_empty():
		return [base, base.lightened(0.35)]
	var primary := Color.html(String(data.get("primary_color", "#ffffff")))
	var second := Color.html(String(data.get("secondary_color", "#ffffff")))
	var colour := Color.from_hsv(primary.h, 0.78, 1.0)
	var accent := Color.from_hsv(second.h, minf(second.s, 0.7), 1.0) if second.v > 0.4 else colour.lightened(0.55)
	return [colour, accent]

## Expand preset names and apply the quality variant: the layers the effect
## builds, in draw order.
static func layers_for(spell_id: String, stage: String, quality: String = "low") -> Array:
	var stage_data: Dictionary = stages_for(spell_id).get(stage, {})
	if stage_data.is_empty():
		return []
	var preset: Dictionary = QUALITY.get(quality, QUALITY["low"])
	var expanded: Array = []
	for raw in stage_data.get("layers", []):
		expanded.append(_expand(raw))
	# Alpha layers (smoke, fire body) draw first so additive light on top of
	# them reads as light, not as a wash.
	expanded.sort_custom(func(a, b): return _blend_rank(a) < _blend_rank(b))
	var out: Array = []
	for layer: Dictionary in expanded:
		var is_core := bool(layer.get("core", false))
		if quality == "low" and bool(layer.get("optional", false)) and not is_core:
			continue
		if layer.get("kind", "") == "light" and not bool(preset["lights"]) and not is_core:
			continue
		out.append(_tune(layer, preset))
	var budget := int(preset["max_layers"])
	if out.size() > budget:
		# Trim from the end, but never below the core layers.
		var core_layers: Array = []
		var extras: Array = []
		for layer: Dictionary in out:
			if bool(layer.get("core", false)):
				core_layers.append(layer)
			else:
				extras.append(layer)
		out = core_layers + extras.slice(0, maxi(0, budget - core_layers.size()))
	return out

static func _blend_rank(layer: Dictionary) -> int:
	if layer.get("kind", "") == "particles":
		return 2
	return 1 if String(layer.get("blend", "alpha")) == "add" else 0

static func _expand(raw: Variant) -> Dictionary:
	if raw is String and LAYER_PRESETS.has(raw):
		return (LAYER_PRESETS[raw] as Dictionary).duplicate(true)
	if raw is Dictionary:
		return (raw as Dictionary).duplicate(true)
	return {}

static func _tune(layer: Dictionary, preset: Dictionary) -> Dictionary:
	var out := layer.duplicate(true)
	var core := bool(out.get("core", false))
	match String(out.get("kind", "")):
		"particles":
			out["amount"] = maxi(1, int(round(float(out.get("amount", 12)) * float(preset["particles"]))))
		"flipbook":
			out["frame_step"] = int(preset["frame_step"])
			out["size"] = float(out.get("size", 1.0)) * (1.0 if core else float(preset["atlas_scale"]))
		"sprite":
			out["size"] = float(out.get("size", 1.0)) * (1.0 if core else float(preset["sprite_scale"]))
		"ribbon":
			out["width"] = float(out.get("width", 0.1)) * (1.0 if core else float(preset["atlas_scale"]))
		"light":
			out["energy"] = float(out.get("energy", 2.0)) * float(preset["particles"])
	return out
