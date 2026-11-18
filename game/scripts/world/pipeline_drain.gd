extends RefCounted
class_name PipelineDrain

## Tells when the renderer's background work has run out, without waiting for
## it on the main thread.
##
## Godot compiles the pipelines of what enters the scene on its worker pool, in
## the order asked, and has no call that says when they are done: the rendering
## info counters count requests. The pool is first in, first out, so one task
## per pool thread queued now can only all run together once every older task
## has finished. Each waits a moment for the others at a gate; if they meet the
## queue before them is empty, if not (a compile still runs) they let go and the
## caller queues them again. Between tries the frames go on.
##
##   var drain := PipelineDrain.new()
##   drain.start()
##   ... each frame: match drain.poll() ...

enum { RUNNING, PASSED, MISSED }

## How long a gate task waits for the others.
const GATE_MS := 200
const THREADS_SETTING := "threading/worker_pool/max_threads"

var _mutex := Mutex.new()
var _need := 0
var _arrived := 0
var _met := false
var _tasks: Array[int] = []

## The pool's size, as the engine works it out at start.
static func pool_size() -> int:
	var configured := int(ProjectSettings.get_setting(THREADS_SETTING, -1))
	return configured if configured > 0 else OS.get_processor_count()

## Waits frame by frame (at most `limit` seconds) for what is queued now, the
## pipelines of this frame's new surfaces included.
static func settle(tree: SceneTree, limit: float) -> void:
	await tree.process_frame
	var drain := PipelineDrain.new()
	drain.start()
	var ends := Time.get_ticks_msec() + int(limit * 1000.0)
	while Time.get_ticks_msec() < ends:
		await tree.process_frame
		match drain.poll():
			PASSED:
				return
			MISSED:
				drain.start()

func start() -> void:
	_need = pool_size()
	_arrived = 0
	_met = false
	_tasks.clear()
	for i in _need:
		_tasks.append(WorkerThreadPool.add_task(_gate, true, "pipeline drain"))

func poll() -> int:
	for task: int in _tasks:
		if not WorkerThreadPool.is_task_completed(task):
			return RUNNING
	for task: int in _tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_tasks.clear()
	return PASSED if _met else MISSED

## On a pool thread.
func _gate() -> void:
	_mutex.lock()
	_arrived += 1
	if _arrived >= _need:
		_met = true
	_mutex.unlock()
	var ends := Time.get_ticks_msec() + GATE_MS
	while Time.get_ticks_msec() < ends:
		_mutex.lock()
		var met := _met
		_mutex.unlock()
		if met:
			return
		OS.delay_usec(250)
