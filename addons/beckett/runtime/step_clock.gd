extends RefCounted
## The game-side tick clock (1.17) behind time_control's step windows (op=step, op=step_until) and the playtest replay
## window (playtest op=run). Full-only: pack.ps1 trims it from Lite, and mcp_runtime.gd loads it by path
## (_step_clock), so a build without it answers that frame stepping is a Full-edition feature.
##
## Why a clock of its own. Before 1.17 the runtime counted its own _physics_process calls while the tree was unpaused.
## That node is PROCESS_MODE_ALWAYS, so it ticked whether or not the scene did: a step of 1 could leave the game's
## pausable nodes and the physics server without a single tick (field report 2026-10-12), and input went in from inside
## a tick, where a pausable node's _input of the same tick had already run. Now:
##   - A WITNESS (Probe: a PAUSABLE child of the runtime, last in the physics order) marks every tick the scene really
##     ran. The HEAD (the tree's physics_frame signal, which the runtime hooks before any scene script can) counts the
##     tick the witness saw, so a window counts the ticks the scene ran, not the ones the runtime ran.
##   - Input for tick i goes in during the IDLE part (the process_frame signal) after tick i-1, so the next tick reads
##     it as fresh input: _input runs before the tick, and is_action_just_pressed is true on that tick. Entry 0 goes in
##     when the window opens. While a window runs, Engine.max_physics_steps_per_frame is 1, so every tick has an idle
##     part after it, even in a game whose frames are slow.
##   - The head after the last tick pauses the tree, before that frame's nodes and the physics server run. Then one
##     SETTLE frame: the next idle part lifts the pause so _process runs once on the final state (labels, cameras,
##     anything drawn from it), and the witness's own _process, last in the order, puts the pause back (settle_end).
##   - When two heads come with no idle part between them (the Game view's speed above 1x, --fixed-fps), the late tick's
##     input goes in at its head, and from then on (tail mode) at the end of the tick before, from the witness; the
##     window's note says how many events went in inside physics.
##   - A game that pauses the tree itself ends the window (game_paused) and keeps its pause; a tick it paused in the
##     middle of is not counted.
## The handlers do nothing while the runtime node cannot process (the Game view's Suspend).

const CallArgs := preload("res://addons/beckett/core/callargs.gd")
const InputCodec := preload("res://addons/beckett/runtime/input_codec.gd")

## The witness node's name under the runtime, and its physics/process priority: the highest, so it runs last.
const PROBE_NAME := &"BeckettStepWitness"
const PROBE_PRIORITY := 1000000000
## The longest replay window: an event stamped later, or a settle that takes it further, is refused at open rather
## than planned frame by frame (30 minutes at 60 ticks a second).
const REPLAY_FRAMES_MAX := 108000

const BACK_TO_BACK_NOTE := "ticks ran back to back (the Game view's speed above 1x, or --fixed-fps), so %d input event(s) went in inside physics"

enum Phase { IDLE, RUNNING, SETTLE, SETTLING, DONE }


## The witness: marks each tick the scene ran (it is PAUSABLE, so a paused tree, or a pause the game set earlier in
## the same tick, skips it), and its _process ends the settle frame after every other node's _process.
class Probe extends Node:
	var ran := false
	var on_tail := Callable()
	var on_idle_end := Callable()

	func _physics_process(_delta: float) -> void:
		ran = true
		if on_tail.is_valid():
			on_tail.call()

	func _process(_delta: float) -> void:
		if on_idle_end.is_valid():
			on_idle_end.call()


var _host: Node = null
var _inject := Callable()
var _hooked_tree: SceneTree = null
var _probe: Probe = null

var _phase: int = Phase.IDLE
var _kind := ""                 # "count" | "until" | "replay" (the open window, or the last one)
var _plan: Array = []           # per tick: an Array of wire events (or null: none), entry i goes in before tick i
var _target := 0                # count: the ticks to run; replay: the end frame
var _ticks := 0                 # ticks the scene ran in this window (counted at the head after each)
var _next_idx := 0              # the first plan entry not yet put in
var _injected := 0              # events that went in
var _consumed := 0              # plan events passed (built or not): replay's remaining = total - consumed
var _total := 0                 # replay: events in the plan
var _late := 0                  # events that went in inside physics (back-to-back ticks)
var _tail_mode := false
var _idle_seen := true          # an idle part came since the last head
var _unfreeze := false
var _terminator := ""
var _notes: PackedStringArray = []
var _held := {}                 # what this window's events hold down (signature -> release event)
var _steps_saved := -1          # Engine.max_physics_steps_per_frame before the window, -1 while it is the game's
var _head := Callable()         # replay: called at every head with (frame, closing)

# step_until
var _expr: Expression = null
var _base := Callable()
var _safe := Callable()
var _cond_value: Variant = null
var _max_frames := 0
var _deadline_ms := 0


# ---------------------------------------------------------------- pure plans

## A step's plan: {frames, ticks, grown}. frames is at least 1, and a batch longer than it grows it (grown); an entry
## that is no Array is a tick with no input, and a batch that is no Array is no input at all.
static func plan_ticks(batch: Variant, frames: int) -> Dictionary:
	var n := maxi(1, frames)
	var ticks: Array = []
	if batch is Array:
		for e in (batch as Array):
			ticks.append((e as Array).duplicate() if e is Array else [])
	var grown := ticks.size() > n
	if grown:
		n = ticks.size()
	return {"frames": n, "ticks": ticks, "grown": grown}


## A replay's plan: {ticks, end, total} or {error}. An event stamped f goes in before frame f+1 (index f+1; a missing f
## counts as 0, and a stamp of -1 or below goes in before frame 0); events of one frame keep their order. The window
## runs frames 0 .. end-1, end = the last stamp + settle (never below 0); with settle 0 the last events sit at index
## end+1, past the last frame, and go in at the close. A frame with no event holds null.
static func plan_replay(events: Variant, settle: int) -> Dictionary:
	var placed: Array = []
	var last_f := 0
	var total := 0
	if events is Array:
		for e in (events as Array):
			if not (e is Dictionary):
				continue
			var f := _stamp((e as Dictionary).get("f", 0))
			last_f = f if total == 0 else maxi(last_f, f)
			total += 1
			placed.append([0 if f < 0 else f + 1, e])
	var end := maxi(0, last_f + maxi(0, settle))
	if end > REPLAY_FRAMES_MAX:
		return {"error": "the replay would run %d frames (its last event is stamped f=%d, plus %d settle frames): past the %d frames a replay window may run" % [end, last_f, maxi(0, settle), REPLAY_FRAMES_MAX]}
	var size := end
	for p in placed:
		size = maxi(size, int(p[0]) + 1)
	var ticks: Array = []
	ticks.resize(size)
	for p in placed:
		var i: int = p[0]
		if ticks[i] == null:
			ticks[i] = []
		(ticks[i] as Array).append(p[1])
	return {"ticks": ticks, "end": end, "total": total}


static func _stamp(v: Variant) -> int:
	if v is int or v is float:
		return int(v)
	if v is String and (v as String).is_valid_float():
		return int((v as String).to_float())
	return 0


## Why a window closes at a head, or "" while it runs. count and replay end at their target; until ends on the
## condition first (even at max_frames or past the deadline), then max_frames (0: none), then the deadline.
static func close_reason(kind: String, ticks: int, target: int, max_frames: int, now_ms: int, deadline_ms: int, cond_true: bool) -> String:
	match kind:
		"count", "replay":
			return "done" if ticks >= target else ""
		"until":
			if cond_true:
				return "condition"
			if max_frames > 0 and ticks >= max_frames:
				return "max_frames"
			if now_ms >= deadline_ms:
				return "timeout"
	return ""


# ---------------------------------------------------------------- hooking up

## Hook the clock to `host` (the runtime node): input goes in through `inject`; with `hook`, the tree's physics_frame
## and process_frame signals drive it (a test passes false and calls the handlers itself).
func attach(host: Node, inject: Callable, hook: bool = true) -> void:
	_unhook()
	_host = host
	_inject = inject
	if hook and host != null and host.is_inside_tree():
		var t := host.get_tree()
		t.physics_frame.connect(on_physics_frame)
		t.process_frame.connect(on_process_frame)
		_hooked_tree = t


func attached_to(host: Node) -> bool:
	return _host != null and is_instance_valid(_host) and _host == host


## End any open window and let go of the tree (the runtime leaves it).
func detach() -> void:
	abort()
	_unhook()
	_host = null
	_inject = Callable()


func _unhook() -> void:
	if _hooked_tree != null and is_instance_valid(_hooked_tree):
		if _hooked_tree.physics_frame.is_connected(on_physics_frame):
			_hooked_tree.physics_frame.disconnect(on_physics_frame)
		if _hooked_tree.process_frame.is_connected(on_process_frame):
			_hooked_tree.process_frame.disconnect(on_process_frame)
	_hooked_tree = null


# ---------------------------------------------------------------- state

func is_open() -> bool:
	return _phase == Phase.RUNNING or _phase == Phase.SETTLE or _phase == Phase.SETTLING


func in_step() -> bool:
	return is_open() and _kind != "replay"


func is_replay() -> bool:
	return is_open() and _kind == "replay"


## A step window's status: kind, frames (the ticks the scene ran) and in_step; once its last tick has run (the settle
## frame included) also the terminator, inputs_injected, step_until's condition_value and a note.
func status() -> Dictionary:
	var out := {"kind": _kind, "frames": _ticks, "in_step": in_step()}
	if _phase == Phase.RUNNING:
		return out
	if not _terminator.is_empty():
		out["terminator"] = _terminator
	if _injected > 0 and _kind != "replay":
		out["inputs_injected"] = _injected
	if _kind == "until":
		out["condition_value"] = _shown_value()
	var note := _note()
	if not note.is_empty():
		out["note"] = note
	return out


## The replay window's status: replaying, injected, frames (the frames the scene ran), total_events, remaining; once
## closed, a terminator when it did not run to its end, and a note.
func replay_status() -> Dictionary:
	if _kind != "replay":
		return {"replaying": false, "injected": 0, "frames": 0, "total_events": 0, "remaining": 0}
	var out := {"replaying": is_replay(), "injected": _injected, "frames": _ticks, "total_events": _total, "remaining": _total - _consumed}
	if _phase == Phase.RUNNING:
		return out
	if not _terminator.is_empty() and _terminator != "done":
		out["terminator"] = _terminator
	var note := _note()
	if not note.is_empty():
		out["note"] = note
	return out


func _note() -> String:
	var parts := _notes.duplicate()
	if _late > 0:
		parts.append(BACK_TO_BACK_NOTE % _late)
	return "; ".join(parts)


# ---------------------------------------------------------------- opening a window

## Open a step of `frames` ticks; entry i of `batch` goes in before tick i, and a longer batch grows the window. A step
## window that is open is replaced (its held input let go); a replay window refuses it.
func open_count(frames: int, batch: Variant, unfreeze: bool) -> Dictionary:
	if is_replay():
		return {"ok": false, "error": "a playtest replay window is open: let it finish (replay_status), or time_control op=freeze, before stepping"}
	if _tree() == null:
		return {"ok": false, "error": "no scene tree"}
	var replaced := _end_for_replace()
	var plan := plan_ticks(batch, frames)
	var ticks: Array = plan["ticks"]
	_begin("count", ticks, int(plan["frames"]), unfreeze)
	var out := {"ok": true, "started": true, "kind": "count", "frames_requested": int(plan["frames"])}
	if not ticks.is_empty():
		out["input_frames"] = ticks.size()
	var notes := PackedStringArray()
	if bool(plan["grown"]):
		notes.append("frames raised to %d to cover the inputs_per_frame batch" % int(plan["frames"]))
	if not replaced.is_empty():
		notes.append(replaced)
	if not notes.is_empty():
		out["note"] = "; ".join(notes)
	return out


## Open a condition window: `expr` (parsed) is read against base.call() when it opens (already true: no tick runs, and
## the game is frozen unless unfreeze) and at the head of every tick; max_frames 0 is no cap.
func open_until(expr: Expression, max_frames: int, timeout_sec: float, unfreeze: bool, base: Callable, safe: Callable) -> Dictionary:
	if is_replay():
		return {"ok": false, "error": "a playtest replay window is open: let it finish (replay_status), or time_control op=freeze, before stepping"}
	var tree := _tree()
	if tree == null:
		return {"ok": false, "error": "no scene tree"}
	var replaced := _end_for_replace()
	_expr = expr
	_base = base
	_safe = safe
	_kind = "until"
	_max_frames = maxi(0, max_frames)
	_deadline_ms = Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	_ticks = 0
	_injected = 0
	_late = 0
	_notes = PackedStringArray()
	_cond_value = null
	if _eval():
		_terminator = "condition"
		_phase = Phase.DONE
		tree.paused = not unfreeze
		_expr = null
		var im := {"ok": true, "started": false, "kind": "until", "immediate": true, "terminator": "condition", "frames": 0,
			"condition_value": _shown_value(), "paused": tree.paused}
		if not replaced.is_empty():
			im["note"] = replaced
		return im
	var keep_value: Variant = _cond_value
	_begin("until", [], 0, unfreeze)
	_cond_value = keep_value
	var out := {"ok": true, "started": true, "kind": "until", "immediate": false, "timeout_sec": timeout_sec, "max_frames": _max_frames}
	if not replaced.is_empty():
		out["note"] = replaced
	return out


## Open the replay window: `events` by their f stamps (plan_replay), `settle` frames after the last; `head` is called
## at every head with (frame, closing). Refused while a step window is open.
func open_replay(events: Variant, settle: int, head: Callable) -> Dictionary:
	if in_step():
		return {"ok": false, "error": "a time_control step window is open: let it finish, or time_control op=freeze, before replay"}
	if _tree() == null:
		return {"ok": false, "error": "no scene tree"}
	var plan := plan_replay(events, settle)
	if plan.has("error"):
		return {"ok": false, "error": str(plan["error"])}
	if is_replay():
		_finish_now()
	_begin("replay", plan["ticks"], int(plan["end"]), false)
	_total = int(plan["total"])
	_head = head
	return {"ok": true, "started": true, "events": _total, "end_frame": _target}


func _begin(kind: String, plan: Array, target: int, unfreeze: bool) -> void:
	_kind = kind
	_plan = plan
	_target = target
	_ticks = 0
	_next_idx = 0
	_injected = 0
	_consumed = 0
	_total = 0
	_late = 0
	_tail_mode = false
	_idle_seen = true  # a window opens from a bridge handler, in an idle part
	_unfreeze = unfreeze
	_terminator = ""
	_notes = PackedStringArray()
	_held = {}
	_head = Callable()
	if kind != "until":
		_expr = null
		_cond_value = null
	_ensure_probe()
	_probe.ran = false
	_probe.set_physics_process(true)
	_probe.set_process(true)
	if _steps_saved < 0:
		_steps_saved = Engine.max_physics_steps_per_frame
	Engine.max_physics_steps_per_frame = 1
	_phase = Phase.RUNNING
	_tree().paused = false
	_feed(0, false)


## End an open step window for the one that replaces it: the note says how far it got and what it let go of.
func _end_for_replace() -> String:
	if _phase == Phase.RUNNING:
		var n := _ticks + (1 if _probe_ran() else 0)
		var released := 0
		for sig in _held:
			if _inject.is_valid():
				_inject.call(_held[sig])
			released += 1
		_held = {}
		_ticks = n
		_terminator = "replaced"
		_finish_now()
		var note := "the open step window was ended after %d tick(s)" % n
		if released > 0:
			note += " and let go of %d input(s) it held" % released
		return note
	if is_open():
		_finish_now()
	return ""


func _ensure_probe() -> void:
	if _probe != null and is_instance_valid(_probe) and _probe.get_parent() == _host:
		return
	if _probe != null and is_instance_valid(_probe):
		_probe.queue_free()
	var p := Probe.new()
	p.name = PROBE_NAME
	p.process_mode = Node.PROCESS_MODE_PAUSABLE
	p.process_physics_priority = PROBE_PRIORITY
	p.process_priority = PROBE_PRIORITY
	p.on_tail = Callable(self, "_on_tail")
	p.on_idle_end = Callable(self, "_on_idle_end")
	_probe = p
	_host.add_child(p)


# ---------------------------------------------------------------- the engine's two points

## The head of a physics tick (the tree's physics_frame signal): count the tick the witness saw end, and close the
## window here, before this tick's nodes and the physics server run, when it is done.
func on_physics_frame() -> void:
	if not _can_run():
		return
	if _phase == Phase.SETTLING:
		settle_end()  # the settle frame's idle part ended without the witness: end it before this tick
		return
	if _phase != Phase.RUNNING:
		return
	var b2b := not _idle_seen
	_idle_seen = false
	var ran := _probe_ran()
	if ran:
		_ticks += 1
		_probe.ran = false
	var tree := _tree()
	if tree.paused:
		if ran:
			_notes.append("the game paused the tree itself after %d tick(s); it stays paused" % _ticks)
		else:
			_notes.append("the game paused the tree itself during tick %d, so that tick did not finish; it stays paused" % (_ticks + 1))
		_terminator = "game_paused"
		if _head.is_valid():
			_head.call(_ticks, true)
		_finish_now()
		return
	if b2b and ran:
		_tail_mode = true
		_feed(_ticks, true)  # no idle part came after the last tick: its successor's input goes in here
	var cond := _eval() if _kind == "until" else false
	var reason := close_reason(_kind, _ticks, _target, _max_frames, Time.get_ticks_msec(), _deadline_ms, cond)
	if reason.is_empty():
		if _head.is_valid():
			_head.call(_ticks, false)
		return
	_terminator = reason
	_feed(_plan.size() - 1, false)  # what sits past the last frame (a replay with settle 0) goes in while the game runs
	if _head.is_valid():
		_head.call(_ticks, true)
	_restore_steps()
	if _unfreeze:
		_finish_now()
		return
	tree.paused = true
	_phase = Phase.SETTLE


## The start of an idle part (the tree's process_frame signal): the input of the next tick goes in; in a settle frame,
## the pause is lifted for this one _process.
func on_process_frame() -> void:
	if not _can_run():
		return
	_idle_seen = true
	match _phase:
		Phase.SETTLE:
			_tree().paused = false
			_phase = Phase.SETTLING
		Phase.RUNNING:
			if _tree().paused:
				return
			_feed(_ticks + (1 if _probe_ran() else 0), false)


## The end of the settle frame: freeze again, and say when the settle frame changed what step_until's condition reads.
func settle_end() -> void:
	if _phase != Phase.SETTLE and _phase != Phase.SETTLING:
		return
	var tree := _tree()
	if tree != null:
		tree.paused = true
	if _kind == "until" and _expr != null:
		var closed_on: Variant = _cond_value
		_eval()
		var after: Variant = _cond_value
		_cond_value = closed_on
		if typeof(after) != typeof(closed_on) or after != closed_on:
			_notes.append("the condition reads %s after the settle frame (it read %s when the window closed): the settle frame's _process changed it" % [str(after), str(closed_on)])
	_finish_now()


## End the window where it stands (time_control freeze/unfreeze, a scene restart, the runtime leaving the tree). A
## window already past its last tick just finishes.
func abort() -> void:
	if not is_open():
		return
	if _phase == Phase.RUNNING:
		_ticks += 1 if _probe_ran() else 0
		_terminator = "aborted"
		_notes.append("time_control freeze/unfreeze, a scene restart or the runtime leaving the tree ended the window after %d tick(s)" % _ticks)
	_finish_now()


func _finish_now() -> void:
	_restore_steps()
	_phase = Phase.DONE
	_expr = null
	_head = Callable()
	if _probe != null and is_instance_valid(_probe):
		_probe.ran = false
		_probe.set_physics_process(false)
		_probe.set_process(false)


func _on_tail() -> void:
	if _tail_mode and _phase == Phase.RUNNING and _can_run():
		_feed(_ticks + 1, true)  # the witness ran last in tick _ticks: the next tick's input, inside physics


func _on_idle_end() -> void:
	if _phase == Phase.SETTLING:
		settle_end()


# ---------------------------------------------------------------- helpers

## Put in every plan entry up to `upto` not yet put in.
func _feed(upto: int, late: bool) -> void:
	while _next_idx <= upto and _next_idx < _plan.size():
		var batch: Variant = _plan[_next_idx]
		_next_idx += 1
		if not (batch is Array):
			continue
		for e in (batch as Array):
			if not (e is Dictionary):
				continue
			_consumed += 1
			var ie: InputEvent = InputCodec.build_event(e)
			if ie == null:
				continue
			if _inject.is_valid():
				_inject.call(ie)
			InputCodec.track(_held, ie)
			_injected += 1
			if late:
				_late += 1


## Read step_until's condition once: true or false, its value kept in _cond_value (an object as its text; the rest as
## it is, made safe to send by the reply that carries it, so a struct goes out typed); an error reads as "not yet", and
## its text is the value.
func _eval() -> bool:
	if _expr == null:
		return false
	var base: Variant = _base.call() if _base.is_valid() else null
	if not (base is Object) or base == null:
		base = _host
	var v: Variant = _expr.execute([], base, true)
	if _expr.has_execute_failed():
		_cond_value = "error: " + _expr.get_error_text()
		return false
	_cond_value = str(v) if typeof(v) == TYPE_OBJECT else v
	return CallArgs.to_bool(v)


## The condition's value as a reply sends it: through the runtime's _safe, inside the reply that carries it.
func _shown_value() -> Variant:
	return _safe.call(_cond_value) if _safe.is_valid() else _cond_value


func _probe_ran() -> bool:
	return _probe != null and is_instance_valid(_probe) and _probe.ran


func _restore_steps() -> void:
	if _steps_saved >= 0:
		Engine.max_physics_steps_per_frame = _steps_saved
		_steps_saved = -1


func _tree() -> SceneTree:
	if _host == null or not is_instance_valid(_host) or not _host.is_inside_tree():
		return null
	return _host.get_tree()


## The handlers run only while the runtime node can process (not under the Game view's Suspend).
func _can_run() -> bool:
	return _host != null and is_instance_valid(_host) and _host.is_inside_tree() and _host.can_process()
