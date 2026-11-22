extends Node

## ExitMark autoload - tells the launcher the game ended on purpose.
##
## The launcher (launcher/src/launcher_app.cpp PollGame) takes a game that
## ends within 20 s of starting as one that failed to start ("The game closed
## right after starting"). A player who quits from the login card at once is
## not that. When the game shuts down in order - the Quit button, the
## window's close, the leave countdown - the scene tree lets go of its
## autoloads and this writes user://clean_exit, which the launcher deletes
## before each start and looks for after an early end. A crash never gets
## here, so the launcher still reports one.

const PATH := "user://clean_exit"

func _exit_tree() -> void:
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	if file != null:
		file.store_string("quit\n")
