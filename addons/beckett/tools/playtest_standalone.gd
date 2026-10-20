# @@HEADER@@
extends SceneTree
## A saved playtest suite as a standalone GDScript test (v1.16 M5c, playtest op=export_gd).
##
## This file is the TEMPLATE: playtest_export.gd replaces the first line with a header of comments and the
## block between the data markers with the suite's own constants, and writes the result into the project.
## The generated test runs where Beckett is not installed at all, the way CI runs a test:
##
##   godot --headless --path <project> --script res://tests/beckett/<suite>_test.gd
##
## It loads the suite's scene itself, replays the recorded input (one event batch per physics frame, the
## frame stamps `f` the recorder wrote) or drives the steps flow (click / type / wait / assert / input /
## inject / state, in real time), checks the per-frame invariants, judges the end-state asserts and quits
## with the verdict as its exit code: 0 pass, 1 fail, 2 blocked (nothing failed, but something could not
## be judged). One line per judgement, a summary line, and a last line BECKETT_RESULT {json} for a CI
## step to read. What it cannot run (a screenshot or perf assert, a physics overlap query) it prints as
## skipped, never drops.
##
## It must not name the addon (no preload, no addon path): everything it needs is copied in below. The
## static helpers are copies of the editor-side code, and the unit suite pins that they agree with it:
##   build_event                      runtime/input_codec.gd
##   to_bool, coerce, prepare         core/callargs.gd
##   inv_*, operands_of, reads_of     runtime/invariants.gd
##   state_*                          runtime/game_state.gd (lookup / compare / evaluate)
##   resolve_node, resolve_target     the runtime's path resolver and selector (runtime/mcp_runtime.gd)
##   write_property, call_method      the runtime's set and call commands
##   inject_error, inject_budget_ms   runtime/ui_do.gd
##   eval_assert                      playtest's own node_state / expr / screen_text asserts
## Change one side, change both.
##
## It is compiled with every GDScript warning as an error by the unit suite (a project may run that way),
## so it stays warning-free: typed declarations, no Variant inference, no unused names.

# @@DATA-BEGIN@@
const SUITE := "template"
const SCENE := "res://main.tscn"
const MODE := "events"
const SETTLE_FRAMES := 4
const STEP_TIMEOUT_MS := 5000
const EVENTS := []
const STEPS := []
const ASSERTS := []
const INVARIANTS := []
# @@DATA-END@@

const REPORT_CAP := 160      # characters of any expression, value or error echoed in a result
const DETAIL_CAP := 200      # characters of one printed judgement
const MAX_READS := 6         # operand values reported for a false expression or a broken rule
const INV_MAX_ITEMS := 16
const INV_MAX_NAME := 60
const INV_MAX_EXPR := 400
const INJECT_MAX_FRAMES := 600
const STEP_SETTLE := 2       # frames the UI gets to react between two steps (the ui_do default)
const STATE_OPS := ["eq", "ne", "lt", "le", "gt", "ge", "contains", "exists"]
const STATE_METHOD := "_beckett_state"
const STATE_METHOD_ALT := "_mcp_state"
const STATE_GROUP := "beckett_state"
const PURE_CALLS := ["get_node", "get_node_or_null", "get_parent", "get_child", "get_child_count", "get_children", "get_tree", "get_nodes_in_group", "get_path",
	"size", "length", "has", "abs", "absf", "absi", "min", "max", "mini", "maxi", "minf", "maxf", "clamp", "clampi", "clampf", "floor", "floorf", "floori",
	"ceil", "ceilf", "ceili", "round", "roundf", "roundi", "sqrt", "sign", "signf", "signi", "pow", "len", "str", "int", "float", "bool", "lerp", "lerpf"]
const LIST_TYPES := [TYPE_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY,
	TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY,
	TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY]
const EVENT_TYPES := ["key", "action", "mouse_button", "mouse_motion", "joy_button", "joy_axis", "touch", "touch_drag"]

var _done := false             # the verdict is printed (or being printed): nothing more is judged
var _t0 := 0                   # Time.get_ticks_msec() when the run started
var _budget_ms := 0            # wall-clock budget of the whole run
var _inv_items: Array = []
var _units: Array = []         # every judgement, in print order: {id, type, status, detail}

# the replay (MODE events)
var _replaying := false
var _events: Array = []
var _ev_i := 0
var _tick := 0
var _end_frame := 0

# the steps flow (MODE steps): the same machine as the game-side ui_do window
var _flowing := false
var _steps: Array = []
var _si := 0
var _step_results: Array = []
var _stopped := -1             # the step the flow stopped at, -1 while it has not
var _deadline := 0
var _step_t0 := 0
var _settle_left := 0
var _cond: Expression = null
var _cond_src := ""
var _last_wait := ""
var _evaluated := false
var _inj_applied := false
var _inj_report: Array = []
var _inj_frames := 1
var _inj_f0_process := 0
var _inj_f0_physics := 0
var _inv_f0 := 0


# ---------------------------------------------------------------- the run

func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	print("[beckett-test] %s: %s suite on %s" % [_line(SUITE), MODE, _line(SCENE)])
	var bad := scene_error(SCENE)
	if not bad.is_empty():
		_end_blocked("scene", bad)
		return
	if not ResourceLoader.exists(SCENE):
		_end_blocked("scene", "scene '%s' does not exist" % SCENE)
		return
	var opened := inv_open(INVARIANTS)
	if not bool(opened.get("ok", false)):
		_unit("invariants", "", "fail", "the suite's invariants do not load: %s" % str(opened.get("error", "")))
		_finish()
		return
	_inv_items = opened["items"]
	var packed := load(SCENE) as PackedScene
	if packed == null:
		_end_blocked("scene", "scene '%s' could not be loaded as a PackedScene" % SCENE)
		return
	var inst := packed.instantiate()
	if inst == null:
		_end_blocked("scene", "scene '%s' could not be instantiated" % SCENE)
		return
	root.add_child(inst)
	current_scene = inst
	var rate := maxi(1, Engine.physics_ticks_per_second)
	if MODE == "steps":
		_steps = (STEPS as Array).duplicate(true)
		if _steps.is_empty():
			_end_blocked("run", "the suite has no steps: nothing to run")
			return
		var inject_ms := 0
		for s in _steps:
			if s is Dictionary and is_inject(s):
				var body: Variant = inject_body(s)
				var frames := 1
				if body is Dictionary and ((body as Dictionary).get("frames", 1) is int or (body as Dictionary).get("frames", 1) is float):
					frames = int((body as Dictionary).get("frames", 1))
				inject_ms += inject_budget_ms(frames, rate, 1.0)
		_budget_ms = mini(60000, _steps.size() * maxi(100, STEP_TIMEOUT_MS) + 3000 + inject_ms)
		_si = 0
		_inv_f0 = Engine.get_physics_frames()
		_flowing = true
		_arm_step()
		return
	# events: frame-stamped input, one batch per physics frame (an event without a stamp goes in on the first)
	for e in (EVENTS as Array):
		if e is Dictionary:
			_events.append((e as Dictionary).duplicate(true))
	if _events.is_empty():
		_end_blocked("run", "the suite has no events: nothing to replay")
		return
	_events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("f", 0)) < int(b.get("f", 0)))
	var last_f := int((_events[_events.size() - 1] as Dictionary).get("f", 0))
	_end_frame = last_f + maxi(0, SETTLE_FRAMES)
	_budget_ms = clampi(int(float(_end_frame + 1) * 2000.0 / float(rate)) + 5000, 2000, 300000)
	_replaying = true


## One physics frame. MainLoop calls this before the scene's nodes run theirs, so what is injected here is in
## Input when the game polls it on this same frame (flushed at once: with several physics frames in one engine
## iteration the engine's own buffer would deliver it frames late).
func _physics_process(_delta: float) -> bool:
	if _done:
		return false
	if _replaying:
		if paused:
			return false  # only a frame the game really simulates counts, as in the editor's replay window
		if _tick > _end_frame:
			_replaying = false
			_judge_end()
			return false
		inv_check(_inv_items, _base(), _tick)
		# an event stamped f was injected by the game-side window during frame f and acted from f + 1: here it goes
		# in at the start of frame f + 1
		while _ev_i < _events.size() and int((_events[_ev_i] as Dictionary).get("f", 0)) < _tick:
			var ie := build_event(_events[_ev_i])
			if ie != null:
				Input.parse_input_event(ie)
			_ev_i += 1
		Input.flush_buffered_events()
		_tick += 1
	elif _flowing and not paused:
		inv_check(_inv_items, _base(), Engine.get_physics_frames() - _inv_f0)
	return false


func _process(_delta: float) -> bool:
	if _done:
		return false
	if Time.get_ticks_msec() - _t0 > _budget_ms:
		if _replaying:
			var why := "the replay did not finish within %d ms (%d of %d physics frames ran)" % [_budget_ms, _tick, _end_frame + 1]
			if paused:
				why += ": the game kept the tree paused, so the replay could not go on"
			_replaying = false
			_end_early(why)
		elif _flowing:
			_flowing = false
			_end_early("the flow was still running after %d ms and was aborted (at step %d)" % [_budget_ms, _si])
		return false
	if _flowing:
		_flow_tick()
	return false


## The game quit (or something else ended the main loop) before the suite was judged: say so, never exit 0.
func _finalize() -> void:
	if _done:
		return
	_replaying = false
	_flowing = false
	_end_early("the run ended before the suite was judged (the game quit or ended the main loop%s)" % (", at physics frame %d of the replay" % _tick if MODE != "steps" else ", during step %d" % _si))


func _base() -> Node:
	return current_scene if current_scene != null else root


## The end of a complete replay or flow: judge the asserts on the scene as it is now.
func _judge_end() -> void:
	_fold_steps()
	_fold_invariants()
	for i in (ASSERTS as Array).size():
		var a: Variant = (ASSERTS as Array)[i]
		var r: Dictionary
		if _stopped >= 0:
			r = {"type": _assert_type(a), "status": "skip", "detail": "not evaluated: the flow stopped at step %d (%s), so the end state is not the one the suite judges" % [_stopped, _stop_status()]}
		else:
			r = eval_assert(a, _base())
		_unit("asserts[%d]" % i, str(r.get("type", "?")), str(r["status"]), str(r["detail"]))
	_finish()


## A run that could not finish: what was judged so far, the asserts skipped, and one blocked unit for the run.
func _end_early(why: String) -> void:
	_fold_steps()
	_fold_invariants()
	for i in (ASSERTS as Array).size():
		_unit("asserts[%d]" % i, _assert_type((ASSERTS as Array)[i]), "skip", "not evaluated: the run did not reach its end")
	_unit("run", "", "blocked", why)
	_finish()


func _end_blocked(id: String, why: String) -> void:
	_unit(id, "", "blocked", why)
	_finish()


func _fold_invariants() -> void:
	for r in inv_results(_inv_items):
		_unit("invariant", str(r["name"]), str(r["status"]), str(r["detail"]))
	_inv_items = []


func _fold_steps() -> void:
	if MODE != "steps":
		return
	for r in _step_results:
		var detail := str(r.get("detail", r.get("error", "")))
		_unit("steps[%d]" % int(r["step"]), str(r["op"]), str(r["status"]), detail)
	var from := _step_results.size()
	for i in range(from, _steps.size()):
		var s: Variant = _steps[i]
		var why := "not run: the steps flow stopped at step %d" % _stopped if _stopped >= 0 else "not run: the run ended first"
		_unit("steps[%d]" % i, _op_of(s) if s is Dictionary else "?", "skip", why)
	_step_results = []
	_steps = []


func _stop_status() -> String:
	for r in _step_results:
		if int(r["step"]) == _stopped:
			return str(r["status"])
	return "blocked"


func _unit(id: String, type: String, status: String, detail: String) -> void:
	var line := status + " ".repeat(maxi(1, 8 - status.length())) + id + (" " + _line(type) if not type.is_empty() else "") + ": " + _line(detail)
	print(line)
	_units.append({"id": id, "type": type.left(40), "status": status, "detail": detail.left(DETAIL_CAP)})


## The verdict: summary line, BECKETT_RESULT line, exit code.
func _finish() -> void:
	if _done:
		return
	_done = true
	var tally := {"pass": 0, "fail": 0, "blocked": 0, "skip": 0}
	for u in _units:
		var s := str(u["status"])
		tally[s if tally.has(s) else "fail"] = int(tally[s if tally.has(s) else "fail"]) + 1
	var verdict := "fail" if int(tally["fail"]) > 0 else ("blocked" if int(tally["blocked"]) > 0 else "pass")
	var code := 1 if verdict == "fail" else (2 if verdict == "blocked" else 0)
	print("[beckett-test] %s %s: %d passed, %d failed, %d blocked, %d skipped" % [verdict.to_upper(), _line(SUITE), int(tally["pass"]), int(tally["fail"]), int(tally["blocked"]), int(tally["skip"])])
	print("BECKETT_RESULT " + JSON.stringify({"suite": SUITE, "scene": SCENE, "mode": MODE, "verdict": verdict, "exit_code": code,
		"passed": tally["pass"], "failed": tally["fail"], "blocked": tally["blocked"], "skipped": tally["skip"], "units": _units}))
	quit(code)


## Text for one printed line: no line breaks or other control characters, capped.
static func _line(s: String) -> String:
	var out := ""
	for i in mini(s.length(), DETAIL_CAP):
		var c := s.unicode_at(i)
		out += " " if (c < 32 or c == 127 or (c >= 0x80 and c < 0xA0) or c == 0x2028 or c == 0x2029) else s[i]
	return out + ("..." if s.length() > DETAIL_CAP else "")


static func _assert_type(a: Variant) -> String:
	if a is Dictionary:
		return str((a as Dictionary).get("type", "")).strip_edges().to_lower().left(40)
	return "assert"


## "" when `scene` may be loaded by this test, else why not: a res:// or user:// path inside the project.
static func scene_error(scene: String) -> String:
	if not (scene.begins_with("res://") or scene.begins_with("user://")) or scene.contains("..") or scene.length() > 300:
		return "'%s' is not a scene of this project (a res:// or user:// path without '..')" % scene.left(REPORT_CAP)
	return ""


# ---------------------------------------------------------------- the steps flow (ui_do's machine)

func _flow_tick() -> void:
	if _settle_left > 0:
		_settle_left -= 1
		return
	var step: Variant = _steps[_si]
	var r := _try(step if step is Dictionary else {})
	if r.is_empty():
		if Time.get_ticks_msec() > _deadline:
			var why := "step %d timed out after %d ms" % [_si, _step_timeout(step)]
			if _last_wait != "":
				why += " — last blocker: %s" % _last_wait
			var verdict := "fail" if (step is Dictionary and ((step as Dictionary).has("assert") or is_state(step)) and _evaluated) else "blocked"
			_finish_step(step, {"ok": false, "status": verdict, "error": why})
		return
	_finish_step(step, r)


func _finish_step(step: Variant, r: Dictionary) -> void:
	r["step"] = _si
	r["op"] = _op_of(step) if step is Dictionary else "?"
	if not r.has("status"):
		r["status"] = "pass" if bool(r.get("ok", false)) else "blocked"
	_step_results.append(r)
	if not bool(r.get("ok", false)):
		_stopped = _si
		_flowing = false
		_judge_end()
		return
	_si += 1
	if _si >= _steps.size():
		_flowing = false
		_judge_end()
		return
	_settle_left = STEP_SETTLE
	_arm_step()


func _arm_step() -> void:
	_deadline = Time.get_ticks_msec() + _step_timeout(_steps[_si])
	_step_t0 = Time.get_ticks_msec()
	_cond = null
	_cond_src = ""
	_last_wait = ""
	_evaluated = false
	_inj_applied = false
	_inj_report = []


static func _step_timeout(step: Variant) -> int:
	if step is Dictionary:
		var t: Variant = (step as Dictionary).get("timeout_ms", STEP_TIMEOUT_MS)
		if t is int or t is float:
			return maxi(100, int(t))
	return maxi(100, STEP_TIMEOUT_MS)


static func _op_of(step: Dictionary) -> String:
	for k in ["click", "type", "wait", "assert", "input"]:
		if step.has(k):
			return k
	if is_inject(step):
		return "inject"
	return "state" if is_state(step) else "?"


static func is_inject(step: Dictionary) -> bool:
	return step.has("inject") or str(step.get("kind", "")) == "inject"


static func inject_body(step: Dictionary) -> Variant:
	return step["inject"] if step.has("inject") else step


static func is_state(step: Variant) -> bool:
	return step is Dictionary and ((step as Dictionary).has("state") or str((step as Dictionary).get("kind", "")) == "state")


static func state_body(step: Dictionary) -> Variant:
	return step["state"] if step.has("state") else step


## {} = not ready yet (retry next frame); anything else finishes the step.
func _try(step: Dictionary) -> Dictionary:
	if step.has("click"):
		return _try_click(_sel(step["click"]))
	if step.has("type"):
		return _try_type(step["type"] if step["type"] is Dictionary else {})
	if step.has("wait"):
		return _try_wait(step["wait"] if step["wait"] is Dictionary else {})
	if step.has("assert"):
		return _try_assert(step["assert"] if step["assert"] is Dictionary else {})
	if step.has("input"):
		var events: Variant = (step["input"] as Dictionary).get("events", []) if step["input"] is Dictionary else []
		var count := 0
		if events is Array:
			for e in (events as Array):
				if not (e is Dictionary):
					continue
				var ie := build_event(e)
				if ie != null:
					Input.parse_input_event(ie)
					count += 1
		Input.flush_buffered_events()
		return {"ok": true, "detail": "dispatched %d event(s)" % count}
	if is_inject(step):
		var body: Variant = inject_body(step)
		return _try_inject(body if body is Dictionary else {})
	if is_state(step):
		var spec: Variant = state_body(step)
		return _try_state(spec if spec is Dictionary else {})
	return {"ok": false, "status": "fail", "error": "unknown step: use one of click/type/wait/assert/input/inject/state"}


static func _sel(v: Variant) -> Dictionary:
	if v is String:
		return {"text": str(v)}
	return (v as Dictionary).duplicate() if v is Dictionary else {}


## A click: a mouse press and release at the control's centre, pushed into the viewport. Unlike the game-side
## click_control it does not check what covers the control (no occlusion check).
func _try_click(sel: Dictionary) -> Dictionary:
	var msg := sel
	if str(msg.get("text", "")) != "" and str(msg.get("class", "")) == "" and str(msg.get("path", "")) == "" and str(msg.get("name", "")) == "":
		msg = msg.duplicate()
		msg["class"] = "BaseButton"
	var base := _base()
	var n := resolve_target(base, msg)
	if n == null:
		_last_wait = _not_found(msg)
		return {}
	if not (n is Control):
		return {"ok": false, "error": "not a Control (%s): a click step clicks a control" % n.get_class()}
	var ctrl := n as Control
	var path := str(base.get_path_to(ctrl))
	if not ctrl.is_visible_in_tree():
		_last_wait = "control is hidden (not visible in tree)"
		return {}
	if ctrl is BaseButton and (ctrl as BaseButton).disabled:
		_last_wait = "control is disabled"
		return {}
	var center: Vector2 = ctrl.get_global_rect().get_center()
	var button := MOUSE_BUTTON_LEFT
	var raw_button: Variant = msg.get("button", 1)
	if (raw_button is int or raw_button is float) and int(raw_button) == 2:
		button = MOUSE_BUTTON_RIGHT
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = button
		ev.pressed = pressed
		ev.position = center
		ev.global_position = center
		root.push_input(ev, true)
	return {"ok": true, "detail": "clicked %s" % path}


## Typing: every character a key event carrying its unicode, into the focused control (type_text's rules).
func _try_type(msg: Dictionary) -> Dictionary:
	var spec := msg.duplicate()
	spec.erase("text")
	var base := _base()
	var n := resolve_target(base, spec)
	if n == null:
		_last_wait = _not_found(spec)
		return {}
	if not (n is Control):
		return {"ok": false, "error": "not a Control (%s): a type step drives a focusable text input" % n.get_class()}
	var ctrl := n as Control
	var path := str(base.get_path_to(ctrl))
	if not ctrl.is_visible_in_tree():
		_last_wait = "control is hidden"
		return {}
	if ctrl is BaseButton and (ctrl as BaseButton).disabled:
		_last_wait = "control is disabled"
		return {}
	if "editable" in ctrl and not to_bool(ctrl.get("editable"), true):
		_last_wait = "control is not editable"
		return {}
	if ctrl.focus_mode == Control.FOCUS_NONE:
		return {"ok": false, "error": "%s has focus_mode NONE: it cannot take keyboard input" % path}
	ctrl.grab_focus()
	if root.gui_get_focus_owner() != ctrl:
		return {"ok": false, "error": "could not focus %s: another control refuses to release focus" % path}
	var text := str(msg.get("text", ""))
	var submit := to_bool(msg.get("submit"), false)
	if to_bool(msg.get("clear"), true):
		if ctrl.has_method("select_all"):
			ctrl.call("select_all")
			if text.is_empty():
				_push_key(KEY_BACKSPACE, 0)
		elif "text" in ctrl:
			ctrl.set("text", "")
	var typed := 0
	for i in text.length():
		var code := text.unicode_at(i)
		if code == 10:
			_push_key(KEY_ENTER, 0)
		else:
			_push_key(KEY_NONE, code)
		typed += 1
	if submit:
		_push_key(KEY_ENTER, 0)
	return {"ok": true, "detail": "typed %d char(s) into %s" % [typed, path]}


func _push_key(keycode: Key, unicode: int) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = keycode
		ev.physical_keycode = keycode
		ev.unicode = unicode if pressed else 0
		ev.pressed = pressed
		root.push_input(ev)


func _try_wait(w: Dictionary) -> Dictionary:
	if w.has("ms"):
		var ms := int(w["ms"]) if (w["ms"] is int or w["ms"] is float) else 0
		if Time.get_ticks_msec() - _step_t0 >= ms:
			return {"ok": true, "detail": "waited %d ms" % ms}
		_last_wait = "waiting %d ms" % ms
		return {}
	if w.has("node"):
		if resolve_node(_base(), str(w["node"])) != null:
			return {"ok": true, "detail": "node appeared: %s" % str(w["node"])}
		_last_wait = "node not found yet: %s" % str(w["node"])
		return {}
	if w.has("condition"):
		return _eval_eventually(str(w["condition"]), "wait")
	return {"ok": false, "status": "fail", "error": "wait needs one of ms / node / condition"}


func _try_assert(a: Dictionary) -> Dictionary:
	if a.has("condition"):
		return _eval_eventually(str(a["condition"]), "assert")
	if a.has("node") and a.has("property"):
		var n := resolve_node(_base(), str(a["node"]))
		if n == null:
			_last_wait = "assert target not found yet: %s" % str(a["node"])
			return {}
		var actual: Variant = n.get(str(a["property"]))
		_evaluated = true
		if _step_equal(actual, a.get("equals")):
			return {"ok": true, "detail": "%s.%s == %s" % [str(a["node"]), str(a["property"]), str(a.get("equals"))]}
		_last_wait = "%s.%s = %s (want %s)" % [str(a["node"]), str(a["property"]), str(actual), str(a.get("equals"))]
		return {}
	return {"ok": false, "status": "fail", "error": "assert needs condition, or node+property+equals"}


func _eval_eventually(src: String, what: String) -> Dictionary:
	if _cond == null or _cond_src != src:
		_cond = Expression.new()
		_cond_src = src
		if _cond.parse(src) != OK:
			return {"ok": false, "status": "fail", "error": "%s condition parse error: %s" % [what, _cond.get_error_text()]}
	var v: Variant = _cond.execute([], _base(), false)
	if _cond.has_execute_failed():
		_last_wait = "%s condition exec error: %s" % [what, _cond.get_error_text()]
		return {}
	_evaluated = true
	if to_bool(v):
		return {"ok": true, "detail": "%s: %s -> true" % [what, src]}
	_last_wait = "%s: %s -> %s" % [what, src, str(v)]
	return {}


func _try_state(spec: Dictionary) -> Dictionary:
	var bad := state_spec_error(spec)
	if not bad.is_empty():
		return {"ok": false, "status": "fail", "error": bad}
	var n := resolve_node(_base(), str(spec["node"]))
	if n == null:
		_last_wait = "state node not found yet: %s" % str(spec["node"]).left(80)
		return {}
	var r := state_evaluate(n, spec)
	if bool(r.get("evaluated", false)):
		_evaluated = true
	match str(r.get("status", "")):
		"pass":
			return {"ok": true, "detail": str(r["detail"])}
		"blocked":
			return {"ok": false, "status": "blocked", "error": str(r["detail"])}
	_last_wait = str(r.get("detail", ""))
	return {}


func _try_inject(spec: Dictionary) -> Dictionary:
	if not _inj_applied:
		var bad := inject_error(spec)
		if not bad.is_empty():
			return {"ok": false, "status": "fail", "error": bad}
		var sets: Array = spec.get("set", []) if spec.get("set", []) is Array else []
		var calls: Array = spec.get("call", []) if spec.get("call", []) is Array else []
		var base := _base()
		for e in sets + calls:
			if resolve_node(base, str((e as Dictionary)["node"])) == null:
				_last_wait = "inject target not found yet: %s" % str((e as Dictionary)["node"]).left(80)
				return {}
		var applied: Array = []
		for e in sets:
			var ed: Dictionary = e
			var r := write_property(resolve_node(base, str(ed["node"])), str(ed["property"]), ed["value"])
			if not bool(r.get("ok", false)):
				return {"ok": false, "status": "blocked", "error": ("inject set %s.%s failed: %s" % [str(ed["node"]), str(ed["property"]), str(r.get("error", "refused"))]).left(240)}
			applied.append(("set %s.%s: %s -> %s" % [str(ed["node"]), str(ed["property"]), str(r.get("before")), str(r.get("after"))]).left(160))
		for e in calls:
			var cd: Dictionary = e
			var raw_args: Variant = cd.get("args", [])
			var cr := call_method(resolve_node(base, str(cd["node"])), str(cd["method"]), raw_args if raw_args is Array else [], base)
			if not bool(cr.get("ok", false)):
				return {"ok": false, "status": "blocked", "error": ("inject call %s.%s failed: %s" % [str(cd["node"]), str(cd["method"]), str(cr.get("error", "refused"))]).left(240)}
			applied.append(("call %s.%s -> %s" % [str(cd["node"]), str(cd["method"]), str(cr.get("result"))]).left(160))
		_inj_applied = true
		_inj_report = applied
		var raw_frames: Variant = spec.get("frames", 1)
		_inj_frames = clampi(int(raw_frames) if (raw_frames is int or raw_frames is float) else 1, 1, INJECT_MAX_FRAMES)
		_inj_f0_process = Engine.get_process_frames()
		_inj_f0_physics = Engine.get_physics_frames()
		# the stepping is the game's own time, not the step waiting to get ready: the step's clock covers it
		_deadline = maxi(_deadline, Time.get_ticks_msec() + inject_budget_ms(_inj_frames, Engine.physics_ticks_per_second, Engine.time_scale))
	if Engine.get_process_frames() - _inj_f0_process >= _inj_frames and Engine.get_physics_frames() - _inj_f0_physics >= _inj_frames:
		return {"ok": true, "detail": "applied %d change(s), stepped %d frame(s)" % [_inj_report.size(), _inj_frames]}
	_last_wait = "stepping %d frame(s) after the inject" % _inj_frames
	return {}


## Numeric-tolerant equality of a step's assert (ui_do's rule): JSON numbers are floats.
static func _step_equal(actual: Variant, expected: Variant) -> bool:
	if (actual is int or actual is float) and (expected is int or expected is float):
		return is_equal_approx(float(actual), float(expected))
	return str(actual) == str(expected)


## How long the stepping of an inject may take, in ms (ui_do.inject_budget_ms).
static func inject_budget_ms(frames: int, ticks_per_second: int, time_scale: float) -> int:
	var rate := maxf(1.0, float(ticks_per_second)) * clampf(time_scale, 0.1, 10.0)
	return int(2000.0 * float(clampi(frames, 1, INJECT_MAX_FRAMES)) / rate) + 1000


## "" when `spec` is a well-formed inject step body, else what is wrong with it (ui_do.inject_error).
static func inject_error(spec: Variant) -> String:
	if not (spec is Dictionary):
		return "inject takes an object: {set: [{node, property, value}], call: [{node, method, args}], frames: N}"
	var sets: Variant = (spec as Dictionary).get("set", [])
	var calls: Variant = (spec as Dictionary).get("call", [])
	if not (sets is Array) or not (calls is Array):
		return "inject: set and call must be arrays"
	if (sets as Array).is_empty() and (calls as Array).is_empty():
		return "inject needs set and/or call (nothing to apply)"
	for i in (sets as Array).size():
		var s: Variant = (sets as Array)[i]
		if not (s is Dictionary) or str((s as Dictionary).get("node", "")).is_empty() or str((s as Dictionary).get("property", "")).is_empty() or not (s as Dictionary).has("value"):
			return "inject set[%d] needs {node, property, value}" % i
	for i in (calls as Array).size():
		var c: Variant = (calls as Array)[i]
		if not (c is Dictionary) or str((c as Dictionary).get("node", "")).is_empty() or str((c as Dictionary).get("method", "")).is_empty():
			return "inject call[%d] needs {node, method, args?}" % i
		if (c as Dictionary).has("args") and not ((c as Dictionary)["args"] is Array):
			return "inject call[%d]: args must be an array" % i
	return ""


# ---------------------------------------------------------------- end-state asserts

## Judge one end-state assert against `scene` (the scene root): {type, status, detail}, the statuses and the
## details the editor's op=run gives. A screenshot, perf or no_overlap assert, and a type nobody knows, is
## skipped: this test has no rendered frame, no replay window measurements and no physics query of Beckett's.
static func eval_assert(a: Variant, scene: Node) -> Dictionary:
	if not (a is Dictionary):
		return {"type": "assert", "status": "skip", "detail": "not run here: an assert must be an object {type, ...}"}
	var d: Dictionary = a
	var type := str(d.get("type", "")).strip_edges().to_lower()
	match type:
		"node_state":
			return _eval_node_state(d, scene)
		"expr":
			return _eval_expr(d, scene)
		"screen_text":
			return _eval_screen_text(d, scene)
		"screenshot":
			return {"type": type, "status": "skip", "detail": "not run here: it compares a rendered frame with its baseline, and this test renders none (op=run in the editor judges it)"}
		"perf":
			return {"type": type, "status": "skip", "detail": "not run here: it reads the editor's replay window measurements, which this test does not take (op=run in the editor judges it)"}
		"no_overlap":
			return {"type": type, "status": "skip", "detail": "not run here: it needs Beckett's physics overlap query, which this test does not have (op=run in the editor judges it)"}
	return {"type": type.left(40), "status": "skip", "detail": "unknown assert type '%s': not judged" % type.left(40)}


static func _eval_node_state(d: Dictionary, scene: Node) -> Dictionary:
	var target := str(d.get("target", "")).strip_edges()
	var prop := str(d.get("property", "")).strip_edges()
	if target.is_empty() or prop.is_empty() or not d.has("equals"):
		return {"type": "node_state", "status": "fail", "detail": "node_state needs target, property and equals"}
	var subject := "%s.%s" % [target, prop]
	if scene == null:
		return {"type": "node_state", "status": "blocked", "detail": "%s: no current scene" % subject}
	var n := resolve_node(scene, target)
	if n == null:
		return {"type": "node_state", "status": "blocked", "detail": ("%s: node not found: %s" % [subject, target]).left(DETAIL_CAP)}
	var res := _property_owner(n, prop)
	if not bool(res.get("ok", false)):
		return {"type": "node_state", "status": "fail", "detail": ("%s: %s" % [subject, str(res.get("error", "get failed"))]).left(DETAIL_CAP)}
	var v: Variant = _safe(_read_at(res))
	if _values_equal(v, d["equals"]):
		return {"type": "node_state", "status": "pass", "detail": "%s == %s" % [subject, str(v)]}
	return {"type": "node_state", "status": "fail", "detail": ("%s = %s (expected %s)" % [subject, str(v), str(d["equals"])]).left(DETAIL_CAP)}


static func _eval_expr(d: Dictionary, scene: Node) -> Dictionary:
	var cond := str(d.get("condition", "")).strip_edges()
	if cond.is_empty():
		return {"type": "expr", "status": "fail", "detail": "expr needs a condition"}
	if scene == null:
		return {"type": "expr", "status": "blocked", "detail": "%s: no current scene" % cond.left(120)}
	var ex := Expression.new()
	if ex.parse(cond) != OK:
		return {"type": "expr", "status": "fail", "detail": ("%s: expr parse error: %s" % [cond.left(120), ex.get_error_text()]).left(DETAIL_CAP)}
	var v: Variant = ex.execute([], scene, false)
	if ex.has_execute_failed():
		return {"type": "expr", "status": "blocked", "detail": ("%s: expr exec error: %s" % [cond.left(120), ex.get_error_text()]).left(DETAIL_CAP)}
	if to_bool(v):
		return {"type": "expr", "status": "pass", "detail": "%s -> true" % cond.left(160)}
	return {"type": "expr", "status": "fail", "detail": ("%s -> false (want true)" % cond.left(160)) + reads_suffix(reads_of(cond, scene))}


static func _eval_screen_text(d: Dictionary, scene: Node) -> Dictionary:
	var text := str(d.get("text", ""))
	if text.strip_edges().is_empty():
		return {"type": "screen_text", "status": "fail", "detail": "screen_text needs text"}
	if scene == null:
		return {"type": "screen_text", "status": "blocked", "detail": "'%s': no current scene" % text.left(80)}
	var found: Array = []
	for c in scene.get_children():
		_find_text(c, text, found)
	if found.is_empty():
		return {"type": "screen_text", "status": "fail", "detail": "no visible node shows '%s'" % text.left(80)}
	return {"type": "screen_text", "status": "pass", "detail": "'%s' is shown (%d node(s))" % [text.left(80), found.size()]}


static func _find_text(node: Node, text: String, found: Array) -> void:
	if found.size() >= 100:
		return
	if _node_text(node).findn(text) != -1:
		found.append(node)
	for c in node.get_children():
		_find_text(c, text, found)


## playtest's equality for node_state: numbers by value, bools by text, arrays and dictionaries entry by entry.
static func _values_equal(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		return is_equal_approx(float(a), float(b))
	if a is bool or b is bool:
		return str(a).to_lower() == str(b).to_lower()
	if a is Array and b is Array:
		if (a as Array).size() != (b as Array).size():
			return false
		for i in (a as Array).size():
			if not _values_equal((a as Array)[i], (b as Array)[i]):
				return false
		return true
	if a is Dictionary and b is Dictionary:
		if (a as Dictionary).size() != (b as Dictionary).size():
			return false
		for k in (a as Dictionary):
			if not (b as Dictionary).has(k) or not _values_equal((a as Dictionary)[k], (b as Dictionary)[k]):
				return false
		return true
	return str(a) == str(b)


## "; read: a = 1, b = 2" from what a false expression read, "" when it read nothing.
static func reads_suffix(reads: Dictionary) -> String:
	if reads.is_empty():
		return ""
	var parts := PackedStringArray()
	for k in reads:
		parts.append("%s = %s" % [str(k), str(reads[k])])
	return "; read: " + ", ".join(parts)


# ---------------------------------------------------------------- finding nodes (the runtime's resolver)

## A node by path or name, from `scene`: the scene itself for "" / "." / its own name, an absolute /root/...
## path, a path relative to the scene, then a name search in the scene and in the whole tree.
static func resolve_node(scene: Node, path: String) -> Node:
	if scene == null:
		return null
	if path.is_empty() or path == "." or path == scene.name:
		return scene
	var tree := scene.get_tree()
	if path.begins_with("/root") and tree != null:
		var absolute := tree.root.get_node_or_null(NodePath(path))
		if absolute != null:
			return absolute
	var n := scene.get_node_or_null(NodePath(path))
	if n != null:
		return n
	n = scene.find_child(path, true, false)
	if n != null:
		return n
	if tree != null and tree.root != null:
		n = tree.root.find_child(path, true, false)
	return n


## A node by "path", or by a selector (class / name / text, optionally "under" a node) and its "nth" match.
static func resolve_target(scene: Node, sel: Dictionary) -> Node:
	var matches: Array = []
	var path := str(sel.get("path", ""))
	if not path.is_empty():
		var direct := resolve_node(scene, path)
		if direct != null:
			matches.append(direct)
	else:
		var cls := str(sel.get("class", ""))
		var name_q := str(sel.get("name", ""))
		var text_q := str(sel.get("text", ""))
		if cls == "" and name_q == "" and text_q == "":
			return null
		var scope := scene
		var under := str(sel.get("under", ""))
		if not under.is_empty():
			scope = resolve_node(scene, under)
		if scope == null:
			return null
		_select_walk(scope, cls, name_q, text_q, matches)
	if matches.is_empty():
		return null
	var raw_nth: Variant = sel.get("nth", 0)
	var nth := int(raw_nth) if (raw_nth is int or raw_nth is float) else 0
	if nth < 0 or nth >= matches.size():
		return null
	return matches[nth]


static func _select_walk(node: Node, cls: String, name_q: String, text_q: String, out: Array) -> void:
	var ok := true
	if cls != "" and not _class_match(node, cls):
		ok = false
	if ok and name_q != "" and str(node.name).findn(name_q) == -1:
		ok = false
	if ok and text_q != "" and _node_text(node).findn(text_q) == -1:
		ok = false
	if ok:
		out.append(node)
	for c in node.get_children():
		_select_walk(c, cls, name_q, text_q, out)


static func _class_match(node: Node, cls: String) -> bool:
	if cls == "":
		return true
	if node.is_class(cls):
		return true
	var gn := _script_global_name(node)
	return gn != "" and gn.nocasecmp_to(cls) == 0


static func _script_global_name(node: Node) -> String:
	var s: Variant = node.get_script()
	if s == null or not (s is Script):
		return ""
	return str((s as Script).get_global_name())


static func _node_text(n: Node) -> String:
	for p in n.get_property_list():
		if str(p.get("name", "")) == "text":
			return str(n.get("text"))
	return ""


static func _not_found(sel: Dictionary) -> String:
	var path := str(sel.get("path", ""))
	if not path.is_empty():
		return "node not found: %s" % path
	var parts: Array = []
	for k in ["class", "name", "text"]:
		var v := str(sel.get(k, ""))
		if v != "":
			parts.append("%s=%s" % [k, v])
	if parts.is_empty():
		return "no path or selector (class/name/text) given"
	var raw_nth: Variant = sel.get("nth", 0)
	return "no node matches selector %s (nth=%d)" % [", ".join(parts), int(raw_nth) if (raw_nth is int or raw_nth is float) else 0]


# ---------------------------------------------------------------- writing state (the runtime's set and call)

## Write a property (a sub-property with ':', position:x) the way the runtime's set command does: the value is
## coerced to the property's type, a value that cannot fit is refused, and the write is read back.
## {ok, before, after} or {ok: false, error}.
static func write_property(n: Node, prop: String, value: Variant) -> Dictionary:
	if n == null:
		return {"ok": false, "error": "node not found"}
	var res := _property_owner(n, prop)
	if not bool(res.get("ok", false)):
		return res
	var before: Variant = _read_at(res)
	var want: Variant = _coerce_to(before, value)
	var mismatch := _coercion_error(before, want)
	if not mismatch.is_empty():
		return {"ok": false, "error": mismatch}
	if bool(res.get("indexed", false)):
		(res["owner"] as Object).set_indexed(NodePath(str(res["leaf"])), want)
	else:
		(res["owner"] as Object).set(str(res["leaf"]), want)
	var after: Variant = _read_at(res)
	var out := {"ok": true, "before": _safe(before), "after": _safe(after)}
	if _value_eq(after, want):
		if not _value_eq(before, after):
			out["changed"] = true
		return out
	if _value_eq(before, after):
		out["ok"] = false
		out["error"] = "write did not stick: %s.%s is still %s (wanted %s)" % [(res["owner"] as Object).get_class(), str(res["leaf"]), str(_safe(after)), str(_safe(want))]
		return out
	out["changed"] = true
	return out


## Call a method the way the runtime's call command does: the arguments are coerced to the declared types and a
## mismatch is an error instead of a call that silently does not run. {ok, result} or {ok: false, error}.
static func call_method(n: Node, method: String, args: Array, scene: Node = null) -> Dictionary:
	if n == null:
		return {"ok": false, "error": "node not found"}
	if not n.has_method(method):
		return {"ok": false, "error": "%s has no method '%s'" % [n.get_class(), method]}
	var prep := prepare(n, method, args, scene)
	if not bool(prep.get("ok", false)):
		return {"ok": false, "error": "%s.%s: %s" % [n.get_class(), method, str(prep.get("error", "argument mismatch"))]}
	return {"ok": true, "result": _safe(n.callv(method, prep["args"]))}


static func _property_owner(obj: Object, prop: String) -> Dictionary:
	if prop.is_empty():
		return {"ok": false, "error": "prop is required (the property name, e.g. position or environment:fog_density)"}
	var parts := prop.split(":", false)
	if parts.is_empty():
		return {"ok": false, "error": "prop is required"}
	var holder: Object = obj
	for i in range(parts.size() - 1):
		var seg := str(parts[i])
		if not _has_property(holder, seg):
			return _no_property(holder, seg, prop)
		var nxt: Variant = holder.get(seg)
		if nxt == null:
			return {"ok": false, "error": "%s.%s is null, so '%s' cannot be reached" % [holder.get_class(), seg, prop]}
		if not (nxt is Object):
			return {"ok": true, "owner": obj, "leaf": prop, "indexed": true}
		holder = nxt as Object
		if not is_instance_valid(holder):
			return {"ok": false, "error": "%s in '%s' points at a freed object" % [seg, prop]}
	var leaf := str(parts[parts.size() - 1])
	if not _has_property(holder, leaf):
		return _no_property(holder, leaf, prop)
	return {"ok": true, "owner": holder, "leaf": leaf, "indexed": false}


static func _no_property(holder: Object, seg: String, prop: String) -> Dictionary:
	var where := "" if seg == prop else " (in path '%s')" % prop
	return {"ok": false, "error": "%s has no property '%s'%s" % [holder.get_class(), seg, where]}


static func _has_property(obj: Object, prop: String) -> bool:
	for p in obj.get_property_list():
		if str(p.get("name", "")) == prop:
			return true
	return false


static func _read_at(res: Dictionary) -> Variant:
	var holder: Object = res.get("owner")
	if bool(res.get("indexed", false)):
		return holder.get_indexed(NodePath(str(res.get("leaf", ""))))
	return holder.get(str(res.get("leaf", "")))


static func _coercion_error(current: Variant, want: Variant) -> String:
	var ct := typeof(current)
	if ct == TYPE_NIL or typeof(want) == ct:
		return ""
	if want == null and (ct == TYPE_OBJECT or ct == TYPE_NODE_PATH):
		return ""
	if ct == TYPE_OBJECT and want is Object:
		return ""
	return "cannot store %s in a %s property (value: %s)" % [type_string(typeof(want)), type_string(ct), str(_safe(want))]


static func _value_eq(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	match typeof(a):
		TYPE_FLOAT:
			return is_equal_approx(float(a), float(b))
		TYPE_VECTOR2:
			return (a as Vector2).is_equal_approx(b as Vector2)
		TYPE_VECTOR3:
			return (a as Vector3).is_equal_approx(b as Vector3)
		TYPE_VECTOR4:
			return (a as Vector4).is_equal_approx(b as Vector4)
		TYPE_COLOR:
			return (a as Color).is_equal_approx(b as Color)
		TYPE_QUATERNION:
			return (a as Quaternion).is_equal_approx(b as Quaternion)
		TYPE_PLANE:
			return (a as Plane).is_equal_approx(b as Plane)
		TYPE_TRANSFORM2D:
			return (a as Transform2D).is_equal_approx(b as Transform2D)
		TYPE_TRANSFORM3D:
			return (a as Transform3D).is_equal_approx(b as Transform3D)
		TYPE_BASIS:
			return (a as Basis).is_equal_approx(b as Basis)
	return a == b


static func _coerce_to(current: Variant, value: Variant) -> Variant:
	var v: Variant = value
	if v is String:
		var raw := (v as String).strip_edges()
		if raw.begins_with("[") or raw.begins_with("{"):
			var parsed: Variant = JSON.parse_string(raw)
			if parsed is Array or parsed is Dictionary:
				v = parsed
	match typeof(current):
		TYPE_INT:
			return int(v) if (v is String or v is float) else v
		TYPE_FLOAT:
			return float(v) if (v is String or v is int) else v
		TYPE_BOOL:
			if v is String:
				return (v as String).to_lower() in ["true", "1", "yes"]
			return to_bool(v)
		TYPE_STRING:
			return str(v)
		TYPE_VECTOR2:
			return _vec2(v)
		TYPE_VECTOR3:
			if v is Array and (v as Array).size() >= 3:
				return Vector3((v as Array)[0], (v as Array)[1], (v as Array)[2])
			if v is Dictionary:
				return Vector3((v as Dictionary).get("x", 0), (v as Dictionary).get("y", 0), (v as Dictionary).get("z", 0))
			return Vector3.ZERO
		TYPE_COLOR:
			if v is Array and (v as Array).size() >= 3:
				var arr: Array = v
				return Color(arr[0], arr[1], arr[2], arr[3] if arr.size() > 3 else 1.0)
			if v is String:
				return Color(v as String)
	return v


## A JSON-safe copy of a value for a reply: an object or a maths struct is its text.
static func _safe(v: Variant) -> Variant:
	var t := typeof(v)
	if t == TYPE_OBJECT:
		return str(v)
	var structs := [TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I,
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_COLOR, TYPE_RECT2, TYPE_RECT2I,
		TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_BASIS, TYPE_QUATERNION,
		TYPE_AABB, TYPE_PLANE, TYPE_PROJECTION]
	if t in structs:
		return str(v)
	return v


# ---------------------------------------------------------------- input events (input_codec.build_event)

static func build_event(e: Dictionary) -> InputEvent:
	var keyboard := -1
	var mouse := -1
	if ClassDB.class_has_integer_constant("InputEvent", "DEVICE_ID_KEYBOARD"):
		keyboard = ClassDB.class_get_integer_constant("InputEvent", "DEVICE_ID_KEYBOARD")
	if ClassDB.class_has_integer_constant("InputEvent", "DEVICE_ID_MOUSE"):
		mouse = ClassDB.class_get_integer_constant("InputEvent", "DEVICE_ID_MOUSE")
	match str(e.get("type", "")):
		"key":
			var k := InputEventKey.new()
			var kc := OS.find_keycode_from_string(str(e.get("keycode", "")))
			k.keycode = kc
			k.physical_keycode = kc
			k.pressed = to_bool(e.get("pressed"), true)
			var uni: Variant = e.get("unicode", 0)
			if uni is String and (uni as String).length() > 0:
				k.unicode = (uni as String).unicode_at(0)
			else:
				k.unicode = int(uni) if (uni is int or uni is float) else 0
			if keyboard >= 0:
				k.device = keyboard
			return k
		"action":
			var a := InputEventAction.new()
			a.action = StringName(str(e.get("action", "")))
			a.pressed = to_bool(e.get("pressed"), true)
			a.strength = _num(e.get("strength", 1.0), 1.0) if a.pressed else 0.0
			return a
		"mouse_button":
			var mb := InputEventMouseButton.new()
			mb.button_index = int(_num(e.get("button", 1), 1.0)) as MouseButton
			mb.pressed = to_bool(e.get("pressed"), true)
			mb.position = _vec2(e.get("position", [0, 0]))
			if mouse >= 0:
				mb.device = mouse
			return mb
		"mouse_motion":
			var mm := InputEventMouseMotion.new()
			mm.position = _vec2(e.get("position", [0, 0]))
			mm.relative = _vec2(e.get("relative", [0, 0]))
			if mouse >= 0:
				mm.device = mouse
			return mm
		"joy_button":
			var jb := InputEventJoypadButton.new()
			jb.button_index = int(_num(e.get("button", 0), 0.0)) as JoyButton
			jb.pressed = to_bool(e.get("pressed"), true)
			jb.device = int(_num(e.get("device", 0), 0.0))
			return jb
		"joy_axis":
			var ja := InputEventJoypadMotion.new()
			ja.axis = int(_num(e.get("axis", 0), 0.0)) as JoyAxis
			ja.axis_value = clampf(_num(e.get("value", 0.0), 0.0), -1.0, 1.0)
			ja.device = int(_num(e.get("device", 0), 0.0))
			return ja
		"touch":
			var st := InputEventScreenTouch.new()
			st.index = int(_num(e.get("index", 0), 0.0))
			st.position = _vec2(e.get("position", [0, 0]))
			st.pressed = to_bool(e.get("pressed"), true)
			return st
		"touch_drag":
			var sd := InputEventScreenDrag.new()
			sd.index = int(_num(e.get("index", 0), 0.0))
			sd.position = _vec2(e.get("position", [0, 0]))
			sd.relative = _vec2(e.get("relative", [0, 0]))
			return sd
	return null


static func _num(v: Variant, fallback: float) -> float:
	if v is int or v is float:
		return float(v)
	if v is String and (v as String).strip_edges().is_valid_float():
		return (v as String).strip_edges().to_float()
	return fallback


static func _vec2(v: Variant) -> Vector2:
	if v is Array and (v as Array).size() >= 2:
		return Vector2(_num((v as Array)[0], 0.0), _num((v as Array)[1], 0.0))
	if v is Dictionary:
		return Vector2(_num((v as Dictionary).get("x", 0), 0.0), _num((v as Dictionary).get("y", 0), 0.0))
	return Vector2.ZERO


# ---------------------------------------------------------------- flags and coercion (callargs.gd)

## A JSON-decoded flag as a bool (CallArgs.to_bool): a bool; a number (nonzero is true); "true" / "false" /
## "1" / "0" / "yes" / "no" in any case; anything else is `default`.
static func to_bool(raw: Variant, default: bool = false) -> bool:
	match typeof(raw):
		TYPE_BOOL:
			return raw
		TYPE_INT, TYPE_FLOAT:
			return raw != 0
		TYPE_STRING, TYPE_STRING_NAME:
			match str(raw).strip_edges().to_lower():
				"true", "1", "yes":
					return true
				"false", "0", "no":
					return false
	return default


## Coerce every argument to the declared parameter types of obj.method (CallArgs.prepare). An Object-typed
## parameter takes a node path, resolved from `scene`.
static func prepare(obj: Object, method: String, raw_args: Array, scene: Node = null) -> Dictionary:
	var meta := {}
	for m in obj.get_method_list():
		if str(m.get("name", "")) == method:
			meta = m
			break
	if meta.is_empty():
		return {"ok": true, "args": raw_args}
	var decl: Array = meta.get("args", [])
	var defaults: Array = meta.get("default_args", [])
	var vararg := (int(meta.get("flags", 0)) & METHOD_FLAG_VARARG) != 0
	var required := decl.size() - defaults.size()
	if raw_args.size() < required:
		return {"ok": false, "error": "takes at least %d arg(s), got %d - signature: %s" % [required, raw_args.size(), _signature(meta)]}
	if not vararg and raw_args.size() > decl.size():
		return {"ok": false, "error": "takes at most %d arg(s), got %d - signature: %s" % [decl.size(), raw_args.size(), _signature(meta)]}
	var out: Array = []
	for i in range(raw_args.size()):
		if i >= decl.size():
			out.append(raw_args[i])
			continue
		var a: Dictionary = decl[i]
		var want := int(a.get("type", TYPE_NIL))
		var aname := str(a.get("name", "arg%d" % i))
		if want == TYPE_OBJECT:
			var rv: Variant = raw_args[i]
			if rv == null or typeof(rv) == TYPE_OBJECT:
				out.append(rv)
				continue
			if rv is String and scene != null:
				var o := resolve_node(scene, rv as String)
				if o != null:
					out.append(o)
					continue
				return {"ok": false, "error": "arg %d (%s): could not resolve '%s' to a live object" % [i, aname, str(rv)]}
			var cls := str(a.get("class_name", ""))
			if cls.is_empty():
				cls = "Object"
			return {"ok": false, "error": "arg %d (%s): expected %s - pass a node name/path or res:// path" % [i, aname, cls]}
		var r := coerce(raw_args[i], want)
		if not bool(r.get("ok", false)):
			return {"ok": false, "error": "arg %d (%s): %s" % [i, aname, str(r.get("error", "type mismatch"))]}
		out.append(r["value"])
	return {"ok": true, "args": out}


static func _signature(meta: Dictionary) -> String:
	var parts: Array = []
	for a in meta.get("args", []):
		var t := int((a as Dictionary).get("type", TYPE_NIL))
		var tn := "Variant"
		if t == TYPE_OBJECT:
			tn = str((a as Dictionary).get("class_name", ""))
			if tn.is_empty():
				tn = "Object"
		elif t != TYPE_NIL:
			tn = type_string(t)
		parts.append("%s %s" % [tn, str((a as Dictionary).get("name", "arg"))])
	return "%s(%s)" % [str(meta.get("name", "?")), ", ".join(parts)]


## Coerce ONE JSON-decoded value to the Variant type `want` (CallArgs.coerce, for the types a state value, a
## property or an argument of a game usually has). {ok: true, value} or {ok: false, error}.
static func coerce(raw: Variant, want: int) -> Dictionary:
	if want == TYPE_NIL or typeof(raw) == want:
		return {"ok": true, "value": raw}
	match want:
		TYPE_BOOL:
			if raw is int and (raw == 0 or raw == 1):
				return {"ok": true, "value": raw == 1}
			if raw is float and (raw == 0.0 or raw == 1.0):
				return {"ok": true, "value": raw == 1.0}
			if raw is String:
				var s := (raw as String).to_lower()
				if s in ["true", "1", "yes"]:
					return {"ok": true, "value": true}
				if s in ["false", "0", "no"]:
					return {"ok": true, "value": false}
			return _err("expected bool, got %s" % _show(raw))
		TYPE_INT:
			if raw is float:
				if raw == floor(raw):
					return {"ok": true, "value": int(raw)}
				return _err("expected int, got fractional %s" % str(raw))
			if raw is String and (raw as String).strip_edges().is_valid_int():
				return {"ok": true, "value": (raw as String).strip_edges().to_int()}
			return _err("expected int, got %s" % _show(raw))
		TYPE_FLOAT:
			if raw is int:
				return {"ok": true, "value": float(raw)}
			if raw is String and (raw as String).strip_edges().is_valid_float():
				return {"ok": true, "value": (raw as String).strip_edges().to_float()}
			return _err("expected float, got %s" % _show(raw))
		TYPE_STRING:
			if raw is int or raw is float or raw is bool or raw is StringName or raw is NodePath:
				return {"ok": true, "value": str(raw)}
			return _err("expected String, got %s" % _show(raw))
		TYPE_STRING_NAME:
			if raw is String:
				return {"ok": true, "value": StringName(raw as String)}
			return _err("expected StringName, got %s" % _show(raw))
		TYPE_NODE_PATH:
			if raw is String:
				return {"ok": true, "value": NodePath(raw as String)}
			return _err("expected NodePath, got %s" % _show(raw))
		TYPE_VECTOR2:
			return _vec(raw, 2, false)
		TYPE_VECTOR2I:
			return _vec(raw, 2, true)
		TYPE_VECTOR3:
			return _vec(raw, 3, false)
		TYPE_VECTOR3I:
			return _vec(raw, 3, true)
		TYPE_VECTOR4:
			return _vec(raw, 4, false)
		TYPE_VECTOR4I:
			return _vec(raw, 4, true)
		TYPE_COLOR:
			return _color(raw)
		TYPE_QUATERNION:
			if raw is Array and (raw as Array).size() == 4 and _all_numbers(raw):
				var q: Array = raw
				return {"ok": true, "value": Quaternion(q[0], q[1], q[2], q[3])}
			return _literal(raw, want, 'pass [x,y,z,w] or "Quaternion(...)"')
		TYPE_RECT2:
			if raw is Array and (raw as Array).size() == 4 and _all_numbers(raw):
				var r: Array = raw
				return {"ok": true, "value": Rect2(r[0], r[1], r[2], r[3])}
			return _literal(raw, want, 'pass [x,y,w,h] or "Rect2(...)"')
		TYPE_RECT2I:
			if raw is Array and (raw as Array).size() == 4 and _all_numbers(raw):
				var ri: Array = raw
				return {"ok": true, "value": Rect2i(int(ri[0]), int(ri[1]), int(ri[2]), int(ri[3]))}
			return _literal(raw, want, 'pass [x,y,w,h] or "Rect2i(...)"')
	return _err("expected %s: the standalone test coerces bool, int, float, String, StringName, NodePath, Vector2/3/4 (and i), Color, Quaternion and Rect2 (and i), got %s" % [type_string(want), _show(raw)])


static func _vec(raw: Variant, dim: int, as_int: bool) -> Dictionary:
	var want_name := "Vector%d%s" % [dim, "i" if as_int else ""]
	var comps: Array = []
	match typeof(raw):
		TYPE_VECTOR2, TYPE_VECTOR2I:
			if dim == 2:
				comps = [float(raw.x), float(raw.y)]
		TYPE_VECTOR3, TYPE_VECTOR3I:
			if dim == 3:
				comps = [float(raw.x), float(raw.y), float(raw.z)]
		TYPE_VECTOR4, TYPE_VECTOR4I:
			if dim == 4:
				comps = [float(raw.x), float(raw.y), float(raw.z), float(raw.w)]
		TYPE_ARRAY:
			if (raw as Array).size() != dim:
				return _err("expected %s: the array needs exactly %d numbers, got %d" % [want_name, dim, (raw as Array).size()])
			for e in (raw as Array):
				if not (e is int or e is float):
					return _err("expected %s: array element %s is not a number" % [want_name, _show(e)])
				comps.append(float(e))
		TYPE_DICTIONARY:
			for k in (["x", "y", "z", "w"].slice(0, dim)):
				var v: Variant = (raw as Dictionary).get(k)
				if not (v is int or v is float):
					return _err('expected %s: the dict needs a numeric "%s"' % [want_name, k])
				comps.append(float(v))
		TYPE_STRING:
			var parsed: Variant = str_to_var(raw as String)
			match typeof(parsed):
				TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_VECTOR4, TYPE_VECTOR4I:
					return _vec(parsed, dim, as_int)
			var parts: PackedStringArray = (raw as String).replace(",", " ").split(" ", false)
			if parts.size() == dim:
				for p in parts:
					if not p.is_valid_float():
						return _err("expected %s: '%s' is not a number" % [want_name, p])
					comps.append(p.to_float())
	if comps.size() != dim:
		return _err('expected %s - pass [x,y,..], {"x":..}, or "x y .."' % want_name)
	var value: Variant
	if dim == 2:
		value = Vector2(comps[0], comps[1])
		if as_int:
			value = Vector2i(int(comps[0]), int(comps[1]))
	elif dim == 3:
		value = Vector3(comps[0], comps[1], comps[2])
		if as_int:
			value = Vector3i(int(comps[0]), int(comps[1]), int(comps[2]))
	else:
		value = Vector4(comps[0], comps[1], comps[2], comps[3])
		if as_int:
			value = Vector4i(int(comps[0]), int(comps[1]), int(comps[2]), int(comps[3]))
	return {"ok": true, "value": value}


static func _color(raw: Variant) -> Dictionary:
	match typeof(raw):
		TYPE_COLOR:
			return {"ok": true, "value": raw}
		TYPE_STRING:
			var s := (raw as String).strip_edges()
			var sentinel := Color(-9999.0, -9999.0, -9999.0, -9999.0)
			var c := Color.from_string(s, sentinel)
			if c != sentinel:
				return {"ok": true, "value": c}
			var parsed: Variant = str_to_var(s)
			if parsed is Color:
				return {"ok": true, "value": parsed}
			return _err('expected Color: "%s" is not a hex value or color name' % s)
		TYPE_ARRAY:
			var arr: Array = raw
			if (arr.size() == 3 or arr.size() == 4) and _all_numbers(arr):
				return {"ok": true, "value": Color(arr[0], arr[1], arr[2], arr[3] if arr.size() > 3 else 1.0)}
		TYPE_DICTIONARY:
			var d: Dictionary = raw
			if (d.get("r") is int or d.get("r") is float) and (d.get("g") is int or d.get("g") is float) and (d.get("b") is int or d.get("b") is float):
				return {"ok": true, "value": Color(d.get("r"), d.get("g"), d.get("b"), d.get("a", 1.0))}
	return _err('expected Color - pass "#rrggbb", a color name, or [r,g,b,a]')


static func _literal(raw: Variant, want: int, hint: String) -> Dictionary:
	if raw is String:
		var parsed: Variant = str_to_var(raw as String)
		if typeof(parsed) == want:
			return {"ok": true, "value": parsed}
	return _err("expected %s, got %s - %s" % [type_string(want), _show(raw), hint])


static func _all_numbers(arr: Array) -> bool:
	for e in arr:
		if not (e is int or e is float):
			return false
	return true


static func _show(v: Variant) -> String:
	var s := str(v)
	if s.length() > 48:
		s = s.substr(0, 48) + "..."
	return "%s (%s)" % [s, type_string(typeof(v))]


static func _err(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}


# ---------------------------------------------------------------- per-frame rules (invariants.gd)

## Validate a suite's `invariants` and compile them: {ok: true, items} or {ok: false, error} (Invariants.normalize
## with the same words, plus each rule's compiled Expression and counters).
static func inv_open(list: Variant) -> Dictionary:
	if list == null:
		return {"ok": true, "items": []}
	if not (list is Array):
		return {"ok": false, "error": "invariants must be an array of {name, expr} objects"}
	var arr: Array = list
	if arr.size() > INV_MAX_ITEMS:
		return {"ok": false, "error": "at most %d invariants per suite (got %d): each one is evaluated on every physics frame, so the list is capped" % [INV_MAX_ITEMS, arr.size()]}
	var items: Array = []
	var seen := {}
	for i in arr.size():
		var e: Variant = arr[i]
		if not (e is Dictionary):
			return {"ok": false, "error": "invariant %d must be an object {name, expr}, got: %s" % [i, str(e).left(60)]}
		var src: Variant = (e as Dictionary).get("expr", null)
		if not (src is String) or (src as String).strip_edges().is_empty():
			return {"ok": false, "error": "invariant %d needs an 'expr' string: a GDScript boolean such as \"get_node('Player').health >= 0\"" % i}
		var text := (src as String).strip_edges()
		if text.length() > INV_MAX_EXPR:
			return {"ok": false, "error": "invariant %d: expr is %d characters, the limit is %d" % [i, text.length(), INV_MAX_EXPR]}
		var nm_raw: Variant = (e as Dictionary).get("name", null)
		var nm := (str(nm_raw).strip_edges() if nm_raw != null else "")
		if nm.is_empty():
			nm = "inv%d" % (i + 1)
		if nm.length() > INV_MAX_NAME:
			return {"ok": false, "error": "invariant %d: name is %d characters, the limit is %d" % [i, nm.length(), INV_MAX_NAME]}
		if seen.has(nm):
			return {"ok": false, "error": "two invariants are named '%s': names identify them in the results, so they must differ" % nm}
		seen[nm] = true
		var ex := Expression.new()
		if ex.parse(text) != OK:
			return {"ok": false, "error": "invariant '%s' does not parse: %s" % [nm, ex.get_error_text()]}
		items.append({"name": nm, "expr": text, "ex": ex, "checked": 0, "violations": 0, "errors": 0, "last_error": "", "first": {}})
	return {"ok": true, "items": items}


## Evaluate every rule once, against `base` (the scene root), for physics frame `frame` (Invariants.check).
static func inv_check(items: Array, base: Object, frame: int) -> void:
	for it in items:
		var ex: Expression = it["ex"]
		var v: Variant = ex.execute([], base, false)
		if ex.has_execute_failed():
			it["errors"] = int(it["errors"]) + 1
			if str(it["last_error"]).is_empty():
				it["last_error"] = ex.get_error_text().left(REPORT_CAP)
			continue
		it["checked"] = int(it["checked"]) + 1
		if to_bool(v):
			continue
		it["violations"] = int(it["violations"]) + 1
		if (it["first"] as Dictionary).is_empty():
			var first := {"frame": frame, "reads": reads_of(str(it["expr"]), base)}
			if not (v is bool):
				first["value"] = _plain(v)
			it["first"] = first


## One result per rule, shaped like an assert result (Invariants.result_of).
static func inv_results(items: Array) -> Array:
	var out: Array = []
	for it in items:
		var checked := int(it["checked"])
		var violations := int(it["violations"])
		var errors := int(it["errors"])
		var r := {"type": "invariant", "name": str(it["name"]), "checked": checked, "violations": violations}
		if errors > 0:
			r["errors"] = errors
		if violations > 0:
			var first: Dictionary = it["first"]
			r["status"] = "fail"
			r["expr"] = str(it["expr"]).left(REPORT_CAP)
			r["first_violation"] = first
			r["detail"] = "violated at frame %d (%d of %d checked frames): %s" % [int(first.get("frame", 0)), violations, checked, _reads_text(first)]
		elif checked == 0:
			r["status"] = "blocked"
			r["expr"] = str(it["expr"]).left(REPORT_CAP)
			r["detail"] = "never evaluated, so nothing was judged: %s" % (_with_hint(str(it["last_error"])) if errors > 0 else "no physics frame ran in the window")
		else:
			r["status"] = "pass"
			var d := "held on %d frame(s)" % checked
			if errors > 0:
				d += ", %d frame(s) could not be evaluated (%s)" % [errors, _with_hint(str(it["last_error"]))]
			r["detail"] = d
		out.append(r)
	return out


static func _with_hint(err: String) -> String:
	if err.contains("base type Object") or err.contains("instance is null"):
		return err + " - a node it names may be missing: guard it, e.g. get_node_or_null('X') == null or get_node('X').health >= 0"
	return err


static func _reads_text(first: Dictionary) -> String:
	var reads: Variant = first.get("reads", {})
	var parts: Array = []
	if reads is Dictionary:
		for k in (reads as Dictionary):
			parts.append("%s = %s" % [str(k), str((reads as Dictionary)[k])])
	if parts.is_empty():
		return "value %s" % str(first.get("value", false))
	return ", ".join(parts)


## The values an expression read: the operands of its comparisons, each evaluated on its own (only those that are
## safe to evaluate a second time, see is_pure_read). Invariants.reads_of.
static func reads_of(src: String, base: Object) -> Dictionary:
	var out := {}
	for operand in operands_of(src):
		if out.size() >= MAX_READS:
			break
		if not is_pure_read(operand):
			continue
		var ex := Expression.new()
		if ex.parse(operand) != OK:
			continue
		var v: Variant = ex.execute([], base, false)
		if ex.has_execute_failed():
			continue
		out[str(operand).left(REPORT_CAP)] = _plain(v)
	return out


## Is this operand safe to evaluate again? Property reads, the calls in PURE_CALLS, is_ / has_ tests and
## constructors are; any other call is not (Invariants.is_pure_read).
static func is_pure_read(operand: String) -> bool:
	var re := RegEx.create_from_string("([A-Za-z_][A-Za-z0-9_]*)\\s*\\(")
	for m in re.search_all(_without_strings(operand)):
		var fn := m.get_string(1)
		if PURE_CALLS.has(fn) or fn.begins_with("is_") or fn.begins_with("has_") or (fn[0] >= "A" and fn[0] <= "Z"):
			continue
		return false
	return true


static func _without_strings(s: String) -> String:
	var out := ""
	var quote := ""
	var i := 0
	while i < s.length():
		var c := s[i]
		if quote != "":
			if c == "\\":
				i += 2
				continue
			if c == quote:
				quote = ""
				out += c
		elif c == "'" or c == "\"":
			quote = c
			out += c
		else:
			out += c
		i += 1
	return out


## The non-literal operands of an expression's comparisons, in source order, de-duplicated (Invariants.operands_of).
static func operands_of(src: String, depth: int = 0) -> Array:
	var out: Array = []
	for clause in _split_logic(src):
		var c := _strip_wrapping(String(clause).strip_edges())
		if c.is_empty():
			continue
		if depth < 4 and c != String(clause).strip_edges() and _split_logic(c).size() > 1:
			for o in operands_of(c, depth + 1):
				if not out.has(o):
					out.append(o)
			continue
		for side in _split_comparison(c):
			var s := _strip_wrapping(String(side).strip_edges())
			if s.is_empty() or _is_literal(s) or out.has(s):
				continue
			out.append(s)
	return out


static func _split_logic(src: String) -> Array:
	var out: Array = []
	var depth := 0
	var quote := ""
	var start := 0
	var i := 0
	var n := src.length()
	while i < n:
		var c := src[i]
		if quote != "":
			if c == "\\":
				i += 2
				continue
			if c == quote:
				quote = ""
			i += 1
			continue
		if c == "'" or c == "\"":
			quote = c
		elif c == "(" or c == "[" or c == "{":
			depth += 1
		elif c == ")" or c == "]" or c == "}":
			depth -= 1
		elif depth == 0:
			var skip := _logic_len(src, i)
			if skip > 0:
				out.append(src.substr(start, i - start))
				i += skip
				start = i
				continue
		i += 1
	out.append(src.substr(start))
	return out


static func _logic_len(src: String, i: int) -> int:
	var two := src.substr(i, 2)
	if two == "&&" or two == "||":
		return 2
	for word in ["and", "or"]:
		var w: String = word
		if src.substr(i, w.length()) == w and (i == 0 or not _is_ident(src[i - 1])) \
				and (i + w.length() >= src.length() or not _is_ident(src[i + w.length()])):
			return w.length()
	return 0


static func _split_comparison(clause: String) -> Array:
	var depth := 0
	var quote := ""
	var i := 0
	var n := clause.length()
	while i < n:
		var c := clause[i]
		if quote != "":
			if c == "\\":
				i += 2
				continue
			if c == quote:
				quote = ""
			i += 1
			continue
		if c == "'" or c == "\"":
			quote = c
		elif c == "(" or c == "[" or c == "{":
			depth += 1
		elif c == ")" or c == "]" or c == "}":
			depth -= 1
		elif depth == 0:
			var two := clause.substr(i, 2)
			if two == "==" or two == "!=" or two == "<=" or two == ">=":
				return [clause.substr(0, i), clause.substr(i + 2)]
			if (c == "<" or c == ">") and two != "<<" and two != ">>":
				return [clause.substr(0, i), clause.substr(i + 1)]
		i += 1
	return [clause]


static func _strip_wrapping(s: String) -> String:
	var t := s.strip_edges()
	if t.begins_with("!") and not t.begins_with("!="):
		t = t.substr(1).strip_edges()
	elif t.begins_with("not ") or t.begins_with("not("):
		t = t.substr(3).strip_edges()
	while t.length() >= 2 and t.begins_with("(") and t.ends_with(")") and _closes_at_end(t):
		t = t.substr(1, t.length() - 2).strip_edges()
	return t


static func _closes_at_end(t: String) -> bool:
	var depth := 0
	var quote := ""
	var i := 0
	while i < t.length():
		var c := t[i]
		if quote != "":
			if c == "\\":
				i += 2
				continue
			if c == quote:
				quote = ""
		elif c == "'" or c == "\"":
			quote = c
		elif c == "(":
			depth += 1
		elif c == ")":
			depth -= 1
			if depth == 0:
				return i == t.length() - 1
		i += 1
	return false


static func _is_ident(c: String) -> bool:
	return c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9")


static func _is_literal(s: String) -> bool:
	if s == "true" or s == "false" or s == "null":
		return true
	if s.is_valid_float():
		return true
	if s.length() >= 2 and (s[0] == "'" or s[0] == "\"") and s[s.length() - 1] == s[0]:
		return true
	return false


static func _plain(v: Variant) -> Variant:
	if v is bool or v is int:
		return v
	if v is float:
		return v if (not is_nan(v) and not is_inf(v)) else str(v)
	if v is String:
		return (v as String).left(REPORT_CAP)
	return str(v).left(REPORT_CAP)


# ---------------------------------------------------------------- game-owned state (game_state.gd)

## "" when `spec` is a well-formed state step body, else what is wrong with it (GameState.spec_error).
static func state_spec_error(spec: Variant) -> String:
	if not (spec is Dictionary):
		return "state takes an object: {node, path, op, value} (ops: %s)" % ", ".join(STATE_OPS)
	var d: Dictionary = spec
	if str(d.get("node", "")).strip_edges().is_empty():
		return "state needs a 'node': the path or name of a node that exposes state"
	if str(d.get("path", "")).strip_edges().is_empty():
		return "state needs a 'path' into the node's state dictionary (dotted: stats.hp, inventory.0)"
	var op := str(d.get("op", "eq")).strip_edges().to_lower()
	if not STATE_OPS.has(op):
		return "state op '%s' is not one of: %s" % [op, ", ".join(STATE_OPS)]
	if op != "exists" and not d.has("value"):
		return "state op %s needs a 'value' to compare with" % op
	return ""


static func _state_read(node: Object) -> Dictionary:
	if node == null or not is_instance_valid(node):
		return {"ok": false, "error": "the node is gone"}
	var m := ""
	if node.has_method(STATE_METHOD):
		m = STATE_METHOD
	elif node.has_method(STATE_METHOD_ALT):
		m = STATE_METHOD_ALT
	if m.is_empty():
		return {"ok": false, "missing": true, "error": "the node has no %s() or %s(): add `func %s() -> Dictionary` to its script and put the node in the group \"%s\"" % [STATE_METHOD, STATE_METHOD_ALT, STATE_METHOD, STATE_GROUP]}
	var v: Variant = node.call(m)
	if not (v is Dictionary):
		return {"ok": false, "error": "%s() returned %s, not a Dictionary (if it raised an error, game_logs has it)" % [m, type_string(typeof(v))]}
	return {"ok": true, "state": v, "method": m}


## Judge one state step against a node: {status: pass | fail | blocked, detail, evaluated} (GameState.evaluate).
static func state_evaluate(node: Object, spec: Dictionary) -> Dictionary:
	var op := str(spec.get("op", "eq")).strip_edges().to_lower()
	var path := str(spec.get("path", "")).strip_edges()
	var label := "state %s.%s" % [str(spec.get("node", "")).left(60), path.left(60)]
	var r := _state_read(node)
	if not bool(r.get("ok", false)):
		return {"status": "blocked", "evaluated": false, "detail": "%s: %s" % [label, str(r.get("error", "no state"))]}
	var found := state_lookup(r["state"], path)
	if op == "exists":
		var want := to_bool(spec.get("value"), true)
		if bool(found["found"]) == want:
			return {"status": "pass", "evaluated": true, "detail": "%s %s" % [label, "exists" if want else "does not exist"]}
		return {"status": "fail", "evaluated": true, "detail": "%s %s" % [label, "does not exist" if want else "exists"]}
	if not bool(found["found"]):
		return {"status": "fail", "evaluated": true, "detail": "%s: %s" % [label, _missing_text(found)]}
	var actual: Variant = found["value"]
	var expected: Variant = spec.get("value")
	var cmp := state_compare(op, actual, expected)
	var shown := "%s = %s" % [label, str(actual).left(REPORT_CAP)]
	if str(cmp["error"]) != "":
		return {"status": "fail", "evaluated": true, "detail": "%s: %s" % [shown, str(cmp["error"])]}
	if bool(cmp["holds"]):
		return {"status": "pass", "evaluated": true, "detail": "%s (%s %s)" % [shown, op, str(expected).left(REPORT_CAP)]}
	return {"status": "fail", "evaluated": true, "detail": "%s, wanted %s %s" % [shown, op, str(expected).left(REPORT_CAP)]}


static func _missing_text(found: Dictionary) -> String:
	var at := str(found.get("at", ""))
	var s := "has no '%s'" % str(found.get("missing", ""))
	if not at.is_empty():
		s += " under '%s'" % at
	var keys: Variant = found.get("keys", [])
	if keys is Array and not (keys as Array).is_empty():
		s += " (it has: %s)" % ", ".join(PackedStringArray(keys as Array)).left(REPORT_CAP)
	return s


## Walk a dotted path through a state value: {found: true, value, at} or {found: false, at, missing, keys}
## (GameState.lookup).
static func state_lookup(state: Variant, dotted: String) -> Dictionary:
	var cur: Variant = state
	var at := ""
	for seg in dotted.split(".", false):
		var s := String(seg)
		var nxt := _state_child(cur, s)
		if not bool(nxt["found"]):
			return {"found": false, "at": at, "missing": s, "keys": _keys_of(cur)}
		cur = nxt["value"]
		at = s if at.is_empty() else at + "." + s
	return {"found": true, "value": cur, "at": at}


static func _state_child(cur: Variant, seg: String) -> Dictionary:
	var t := typeof(cur)
	if t == TYPE_DICTIONARY:
		var d: Dictionary = cur
		if d.has(seg):
			return {"found": true, "value": d[seg]}
		if d.has(StringName(seg)):
			return {"found": true, "value": d[StringName(seg)]}
		if seg.is_valid_int() and d.has(seg.to_int()):
			return {"found": true, "value": d[seg.to_int()]}
	elif t in LIST_TYPES:
		if seg.is_valid_int():
			var n: int = cur.size()
			var i := seg.to_int()
			if i < 0:
				i += n
			if i >= 0 and i < n:
				return {"found": true, "value": cur[i]}
	elif t == TYPE_VECTOR2 or t == TYPE_VECTOR2I:
		if seg in ["x", "y"]:
			return {"found": true, "value": cur[seg]}
	elif t == TYPE_VECTOR3 or t == TYPE_VECTOR3I:
		if seg in ["x", "y", "z"]:
			return {"found": true, "value": cur[seg]}
	elif t == TYPE_VECTOR4 or t == TYPE_VECTOR4I or t == TYPE_QUATERNION:
		if seg in ["x", "y", "z", "w"]:
			return {"found": true, "value": cur[seg]}
	elif t == TYPE_COLOR:
		if seg in ["r", "g", "b", "a"]:
			return {"found": true, "value": cur[seg]}
	elif t == TYPE_RECT2 or t == TYPE_RECT2I:
		if seg in ["position", "size"]:
			return {"found": true, "value": cur[seg]}
	elif t == TYPE_OBJECT and is_instance_valid(cur):
		for p in (cur as Object).get_property_list():
			if str(p.get("name", "")) == seg:
				return {"found": true, "value": (cur as Object).get(seg)}
	return {"found": false}


static func _keys_of(v: Variant) -> Array:
	var out: Array = []
	if v is Dictionary:
		for k in (v as Dictionary):
			out.append(str(k).left(40))
			if out.size() >= 12:
				break
	return out


## {holds: bool, error: String}: does `actual` satisfy `op expected`? (GameState.compare)
static func state_compare(op: String, actual: Variant, expected: Variant) -> Dictionary:
	match op:
		"eq":
			return {"holds": _state_equal(actual, expected), "error": ""}
		"ne":
			return {"holds": not _state_equal(actual, expected), "error": ""}
		"lt", "le", "gt", "ge":
			return _order(op, actual, expected)
		"contains":
			return _contains(actual, expected)
	return {"holds": false, "error": "unknown op '%s'" % op}


static func _state_equal(actual: Variant, expected: Variant) -> bool:
	var ta := typeof(actual)
	var te := typeof(expected)
	var a_num := ta == TYPE_INT or ta == TYPE_FLOAT
	var e_num := te == TYPE_INT or te == TYPE_FLOAT
	if a_num and e_num:
		if ta == TYPE_INT and te == TYPE_INT:
			return actual == expected
		return is_equal_approx(float(actual), float(expected))
	if ta == TYPE_NIL or te == TYPE_NIL:
		return ta == te
	var a_text := ta == TYPE_STRING or ta == TYPE_STRING_NAME
	var e_text := te == TYPE_STRING or te == TYPE_STRING_NAME
	if a_text and e_text:
		return str(actual) == str(expected)
	if ta == TYPE_DICTIONARY and te == TYPE_DICTIONARY:
		if (actual as Dictionary).size() != (expected as Dictionary).size():
			return false
		for k in (actual as Dictionary):
			var found := false
			for k2 in (expected as Dictionary):
				if str(k2) == str(k):
					found = true
					if not _state_equal((actual as Dictionary)[k], (expected as Dictionary)[k2]):
						return false
					break
			if not found:
				return false
		return true
	if ta == TYPE_ARRAY and te == TYPE_ARRAY:
		if (actual as Array).size() != (expected as Array).size():
			return false
		for i in (actual as Array).size():
			if not _state_equal((actual as Array)[i], (expected as Array)[i]):
				return false
		return true
	if ta != te:
		var c := coerce(expected, ta)
		if not bool(c.get("ok", false)):
			return false
		return _state_equal(actual, c["value"])
	if ta == TYPE_VECTOR2 or ta == TYPE_VECTOR3 or ta == TYPE_VECTOR4 or ta == TYPE_COLOR or ta == TYPE_QUATERNION or ta == TYPE_PLANE:
		return _value_eq(actual, expected)
	return actual == expected


static func _order(op: String, actual: Variant, expected: Variant) -> Dictionary:
	var e: Variant = expected
	var a_num := typeof(actual) == TYPE_INT or typeof(actual) == TYPE_FLOAT
	if a_num and typeof(e) == TYPE_STRING and (e as String).strip_edges().is_valid_float():
		e = (e as String).strip_edges().to_float()
	var e_num := typeof(e) == TYPE_INT or typeof(e) == TYPE_FLOAT
	if a_num and e_num:
		return {"holds": _order_numbers(op, actual, e), "error": ""}
	var a_text := typeof(actual) == TYPE_STRING or typeof(actual) == TYPE_STRING_NAME
	var e_text := typeof(e) == TYPE_STRING or typeof(e) == TYPE_STRING_NAME
	if a_text and e_text:
		var s := str(actual)
		var t := str(e)
		match op:
			"lt":
				return {"holds": s < t, "error": ""}
			"le":
				return {"holds": s <= t, "error": ""}
			"gt":
				return {"holds": s > t, "error": ""}
		return {"holds": s >= t, "error": ""}
	return {"holds": false, "error": "%s orders two numbers or two strings, but the state is %s and the step wants %s" % [op, type_string(typeof(actual)), type_string(typeof(expected))]}


static func _order_numbers(op: String, a: Variant, e: Variant) -> bool:
	if typeof(a) == TYPE_INT and typeof(e) == TYPE_INT:
		var ai: int = a
		var ei: int = e
		match op:
			"lt":
				return ai < ei
			"le":
				return ai <= ei
			"gt":
				return ai > ei
		return ai >= ei
	var x := float(a)
	var y := float(e)
	var same := is_equal_approx(x, y)
	match op:
		"lt":
			return x < y and not same
		"le":
			return x < y or same
		"gt":
			return x > y and not same
	return x > y or same


static func _contains(actual: Variant, expected: Variant) -> Dictionary:
	var t := typeof(actual)
	if t == TYPE_STRING or t == TYPE_STRING_NAME:
		return {"holds": str(actual).contains(str(expected)), "error": ""}
	if t == TYPE_DICTIONARY:
		for k in (actual as Dictionary):
			if str(k) == str(expected):
				return {"holds": true, "error": ""}
		return {"holds": false, "error": ""}
	if t in LIST_TYPES:
		for e in actual:
			if _state_equal(e, expected):
				return {"holds": true, "error": ""}
		return {"holds": false, "error": ""}
	return {"holds": false, "error": "contains works on a string, an array or a dictionary, but the state is %s" % type_string(t)}
