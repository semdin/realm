extends SceneTree

## Builds the drawn caverns and dungeon maps headless and prints what each
## built; with `--write <patches dir>` it writes every map's drawn solids
## that the old game gave no collider (the views' `solids`) as
## <dir>/<map>.json, the collider patch format of realm_worldc
## (crates/realm_worldc/src/patch.rs), then `realm_worldc patch` adds them to
## the packs:
##
##   godot --headless --path game -s res://maps/dng_common/map_solids.gd -- --write ../world/patches
##   ./build/lead_target/release/realm_worldc patch world/maps content/data

const MAPS := ["spider_caverns", "dng_trial", "dng_sealed_wing", "dng_spider_lair"]

var _done := false

## The views are built on the first frame, inside the tree (a skinned
## model's bounds follow its skeleton only there).
func _process(_delta: float) -> bool:
	if _done:
		return false
	_done = true
	_run()
	return false

func _run() -> void:
	# the content tables the views read (portals): the realm checkout's
	var content := ProjectSettings.globalize_path("res://").path_join("../content/data").simplify_path()
	if not ClassDB.class_call_static("RealmContent", "load", content):
		push_error("content/data could not be read")
		quit(1)
		return
	var args := OS.get_cmdline_user_args()
	var i := args.find("--write")
	var out_dir := args[i + 1] if i >= 0 and i + 1 < args.size() else ""
	if out_dir != "" and out_dir.is_relative_path():
		out_dir = ProjectSettings.globalize_path("res://").path_join(out_dir).simplify_path()
	var failed := false
	for map in MAPS:
		var path := "res://maps/%s/%s.tscn" % [map, map]
		var view: Node3D = (load(path) as PackedScene).instantiate()
		root.add_child(view)
		view.call("build")
		var solids: Array = view.get("solids")
		print("map %s: %s" % [map, view.get("built_stats")])
		for s: Dictionary in solids:
			print("  solid %s centre %s half %s yaw %s" % [s["note"], s["center"], s["half"], s["yaw_deg"]])
		if out_dir != "":
			var doc := {
				"_comment": ("Colliders for drawn solids the old %s gave no collider, recorded by the map's own view " +
					"(game/maps/%s; written by game/maps/dng_common/map_solids.gd --write). Pack coordinates " +
					"(a dungeon's copy-local ones). Applied by realm_worldc patch.") % [map, map],
				"boxes": solids,
			}
			var file := FileAccess.open(out_dir.path_join(map + ".json"), FileAccess.WRITE)
			if file == null:
				push_error("cannot write %s" % out_dir.path_join(map + ".json"))
				failed = true
			else:
				file.store_string(JSON.stringify(doc, "  ") + "\n")
				file.close()
				print("  wrote %d boxes to %s" % [solids.size(), out_dir.path_join(map + ".json")])
		view.queue_free()
	quit(1 if failed else 0)
