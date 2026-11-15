extends "res://maps/dng_common/dungeon_view.gd"

## The Trial Hall drawn (maps.json "dng_trial"): the old game's first dungeon
## (scripts/world/dungeons/dungeon_trial.gd) in the castle's cold stone.
##
## Rooms, north (entry, local z +12) to south:
##   entry hall    z  12 ..  -12   the way back                         start
##   corridor      z -12 ..  -36   a pack; side rooms west/east          gate_h
##   pillared hall z -36 ..  -80   packs between pillars; ossuaries west/east
##   passage       z -80 .. -100   a pack                               gate_a
##   arena         z -100 .. -152  the Trial Warden                     gate_x
##   way out       z -152 .. -168  the exit once the trial is complete
## Positions are local to the copy (the scene stands at the copy's offset).

func _build() -> void:
	map_id = "dng_trial"
	floor_y = 1000.0
	var f := floor_y
	var wy := f + wall_h * 0.5
	_room(Vector2(0, 0), Vector2(24, 24), [-12.0])
	# Corridor with the side rooms off it.
	_box(Vector3(0, f - 0.5, -24), Vector3(8, 1, 24), _floor_mat)
	_wall_x(-4.5, wy, -36, -12, [-24.0])
	_wall_x(4.5, wy, -36, -12, [-24.0])
	_deco(Vector3(0, f + wall_h + 0.25, -24), Vector3(10, 0.5, 24), _vault)
	_room(Vector2(-12.5, -24), Vector2(15, 14), [], 8.0, INF, [], 1)
	_room(Vector2(12.5, -24), Vector2(15, 14), [], 8.0, INF, [], -1)
	# The pillared hall and its ossuaries.
	_room(Vector2(0, -58), Vector2(34, 44), [-36.0, -80.0], 8.0, INF, [Vector2(-1, -58), Vector2(1, -58)])
	_room(Vector2(-25, -58), Vector2(16, 18), [], 8.0, INF, [], 1)
	_room(Vector2(25, -58), Vector2(16, 18), [], 8.0, INF, [], -1)
	for x in [-8.0, 8.0]:
		for z in [-48.0, -68.0]:
			_box(Vector3(x, wy, z), Vector3(1.6, wall_h, 1.6), _trim)
	# The passage to the arena.
	_box(Vector3(0, f - 0.5, -90), Vector3(8, 1, 20), _floor_mat)
	_wall_x(-4.5, wy, -100, -80, [])
	_wall_x(4.5, wy, -100, -80, [])
	_deco(Vector3(0, f + wall_h + 0.25, -90), Vector3(10, 0.5, 20), _vault)
	_room(Vector2(0, -126), Vector2(40, 52), [-100.0, -152.0])
	# Behind the arena: the way out, opened when the trial is complete.
	_room(Vector2(0, -160), Vector2(16, 16), [-152.0])
	for z in [8.0, -8.0]:
		for x in [-10.0, 10.0]:
			_torch(Vector3(x, f + 3.5, z))
	for z in [-16.0, -32.0, -84.0, -96.0]:
		for x in [-3.5, 3.5]:
			_torch(Vector3(x, f + 3.5, z))
	for z in [-42.0, -58.0, -74.0]:
		for x in [-16.0, 16.0]:
			if z != -58.0:
				_torch(Vector3(x, f + 3.5, z))
	for x in [-19.5, 19.5]:
		_torch(Vector3(x, f + 3.5, -24), Color(0.75, 0.85, 1.0), 1.3)
	for x in [-32.0, 32.0]:
		_torch(Vector3(x, f + 3.5, -58), Color(0.6, 1.0, 0.7), 1.3)
	for z in [-110.0, -126.0, -142.0]:
		for x in [-18.0, 18.0]:
			_torch(Vector3(x, f + 3.5, z))
