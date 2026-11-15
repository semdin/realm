extends RefCounted
class_name RealmPaths

## Where the files the Rust core reads with std::fs live (they are not in the
## pck): `keys/tls.crt.der` (the realm's pinned QUIC certificate),
## `content/data` and `world/maps`, all under one root.
##
##   dev run (the editor binary:          the realm checkout the project sits in
##   `godot --path game`, the checks)     (res://..), with keys/ from `keygen`
##   exported game (feature "template")   the release root: the executable's folder
##                                        on Windows and Linux; on macOS the folder
##                                        the .app bundle is in (the bundle itself
##                                        stays exactly as the export signed it)
##
## tools/release/stage_client.sh fills the release root after an export.
## `--keys`, `--content` and `--maps` still override each folder.

static func root() -> String:
	if OS.has_feature("template"):
		var exe_dir := OS.get_executable_path().get_base_dir()
		if OS.has_feature("macos"):
			# <dir>/<name>.app/Contents/MacOS/<binary> -> <dir>: the data sits
			# beside the bundle, which stays as the export signed it
			return exe_dir.path_join("../../..").simplify_path()
		return exe_dir
	return ProjectSettings.globalize_path("res://").path_join("..").simplify_path()

## True in an exported game (no dev keys, no dev checks, the realm's own
## login service by default).
static func is_release() -> bool:
	return OS.has_feature("template")
