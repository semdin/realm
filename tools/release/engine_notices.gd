extends SceneTree

## Writes the engine's own licence data as JSON for gen_notices.py:
##   godot --headless --path game --script ../tools/release/engine_notices.gd -- <out.json>

func _initialize() -> void:
	var out: String = OS.get_cmdline_user_args()[0]
	var file := FileAccess.open(out, FileAccess.WRITE)
	file.store_string(JSON.stringify({
		"version": Engine.get_version_info().get("string", ""),
		"license": Engine.get_license_text(),
		"copyright": Engine.get_copyright_info(),
		"licenses": Engine.get_license_info(),
	}))
	file.close()
	quit()
