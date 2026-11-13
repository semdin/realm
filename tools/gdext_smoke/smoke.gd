extends SceneTree

## Loads the realm_client extension and checks it reports the build's facts.
##   godot --headless --path tools/gdext_smoke -s res://smoke.gd -- <protocol> <sim_hz>
## The expected numbers come from the caller so this file never goes stale.

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if not ClassDB.class_exists("RealmInfo"):
		printerr("gdext smoke: RealmInfo is not registered (extension did not load)")
		quit(1)
		return
	var info = ClassDB.instantiate("RealmInfo")
	var got := "%d %d" % [info.protocol_version(), info.sim_hz()]
	var want := " ".join(args)
	if args.size() == 2 and got != want:
		printerr("gdext smoke: got '%s', expected '%s'" % [got, want])
		quit(1)
		return
	print("gdext smoke ok: protocol v%d, sim %d Hz, Godot %s" % [info.protocol_version(), info.sim_hz(), Engine.get_version_info().string])
	quit(0)
