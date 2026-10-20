extends Node
## The headless playtest runner (v1.16): every saved playtest suite of a project, run in CI with no editor, no
## Beckett plugin and no autoload, and the process exit code is the verdict:
##
##   godot --headless --path <project> res://addons/beckett/runtime/playtest_runner.tscn
##
## exits 0 when every suite passed (or there is none), 1 when any failed, and 2 when none failed but one could
## not be judged (blocked), or the run ended before every suite was judged (the game quit or changed the scene).
##
## Suites are <beckett/test_dir, default res://tests>/playtests/*.json (a *.report.json is not a suite), run in
## file-name order and named by the `name` inside the file. Each one: its scene is instanced beside this node,
## its recorded events (frame-stamped `f`, the record_input format) are replayed frame for frame, the window
## runs SETTLE_FRAMES more frames, and then its end-state asserts and per-frame invariants are judged on the
## scene, with the same judgement rules as playtest op=run in the editor (pass | fail | skip | blocked; blocked =
## nothing failed, but something could not be judged). A steps flow (ui_do steps) is not replayed here: such a
## suite is BLOCKED with the way on (playtest op=run, or op=export_gd and run the exported test).
##
## Frame-exact: this node runs LAST in every physics frame (process_physics_priority), so at the end of the
## scene's frame N it injects the events stamped N and flushes them through Input, and the game sees them from
## frame N+1 - exactly when the editor's replay window (mcp_runtime) delivers them, and still on the right frame
## when a slow start makes the engine run several physics frames in one iteration. Input a suite left held is
## released before the next suite starts.
##
## Self-contained by design: it preloads only path_guard (its one write, the .actual.png of a failed screenshot
## assert), callargs, invariants, input_codec (held-input bookkeeping) and physics_overlap (with game_state, the
## one file that preloads); a project carries just those under addons/beckett to run it. It keeps
## its own copy of the input codec's build_event and of replay_perf's summary maths (both say so: extend both).
## The suites, the scenes they name and the baselines are read without the read check (SECURITY.md): a CI run
## executes the project's own code anyway.

const PathGuard := preload("res://addons/beckett/core/path_guard.gd")  # the .actual.png beside a baseline goes through the write rule
const CallArgs := preload("res://addons/beckett/core/callargs.gd")  # flags in a suite can be text ("false")
const Invariants := preload("res://addons/beckett/runtime/invariants.gd")  # the per-frame rule checker, the same module the game arms
const InputCodec := preload("res://addons/beckett/runtime/input_codec.gd")  # track / release_all: input a suite left held
const PhysicsOverlap := preload("res://addons/beckett/runtime/physics_overlap.gd")  # the no_overlap assert, on this process's physics

const TEST_DIR_SETTING := "beckett/test_dir"
const TEST_DIR_DEFAULT := "res://tests"
## Frames the replay window runs after the last event (the editor's default is 4; a CI machine gets a wider margin).
const SETTLE_FRAMES := 8
const SCHEMA_MAX := 2
const SNR_DEFAULT := 30.0
const DETAIL_CAP := 300
## Wall-clock budget of one suite on top of the time its frames take at the physics tick rate: a game that keeps
## the tree paused ends the suite blocked instead of hanging CI.
const SUITE_BUDGET_MS := 20000
const PERF_CAP := 36000
const ASSERT_TYPES := ["node_state", "expr", "screen_text", "screenshot", "perf", "no_overlap"]
const PERF_METRICS := ["frames", "frame_ms_min", "frame_ms_avg", "frame_ms_p95", "frame_ms_max", "fps_min", "fps_avg",
	"memory_static_end", "memory_delta", "orphan_delta", "draw_calls_end"]

var _scene: Node = null            # the live scene of the suite under test: asserts and rules read it
var _doc: Dictionary = {}          # the suite being run
var _inv = Invariants.new()        # its per-frame rules
var _suites_passed := 0
var _suites_failed := 0
var _suites_blocked := 0
var _not_judged := 0

# Perf capture across the replay window: mirrors runtime/replay_perf.gd (deliberately: this runner is self-contained).
var _perf_ms := PackedFloat64Array()
var _perf_fps := PackedFloat64Array()
var _perf_mem0 := 0.0
var _perf_orphan0 := 0.0

var _queue: Array = []             # suite files still to run
var _total := 0
var _running := false              # a suite's replay window is open
var _finished := false             # the summary was printed (normally or after an early end)
var _current := ""                 # the suite that is running, for the early-end note
var _events: Array = []            # this suite's events, frame-sorted, each with its frame in "_f"
var _ev_i := 0
var _tick := 0                     # scene frames run in this window
var _end := 0
var _deadline := 0
var _held := {}                    # what the injected events hold down (InputCodec.track)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Last in every frame: the scene's own physics runs first, then the events for the next frame go in.
	process_priority = 1 << 30
	if "process_physics_priority" in self:
		set("process_physics_priority", 1 << 30)
	var dir := _test_root() + "/playtests"
	_queue = _suite_files(dir)
	_total = _queue.size()
	if _queue.is_empty():
		_finished = true
		print("[beckett-runner] no suites found in %s: nothing to run" % dir)
		get_tree().quit(0)
		return
	print("[beckett-runner] %d suite(s) in %s" % [_total, dir])


func _physics_process(_delta: float) -> void:
	if _finished:
		return
	if _running:
		_step()
	else:
		_start_next()


## The game ended the run under us: it quit (the tree is being torn down), or changed the scene, which replaces
## this node (the scene the runner runs as). Whatever was not judged is said, and the exit code is not a pass.
func _exit_tree() -> void:
	if _finished:
		return
	_finished = true
	_running = false
	_not_judged = maxi(0, _total - _suites_passed - _suites_failed - _suites_blocked)
	print("BLOCKED: the run ended early (the game quit, or changed the scene and so replaced the runner) while '%s' was running: %d suite(s) not judged"
		% [_current.left(80), _not_judged])
	print(_summary_line())
	var tree := get_tree()
	if tree != null:
		tree.quit(_exit_code())


# ---------------------------------------------------------------- suites

static func _test_root() -> String:
	var r := str(ProjectSettings.get_setting(TEST_DIR_SETTING, TEST_DIR_DEFAULT)).strip_edges().trim_suffix("/")
	if not r.begins_with("res://") or r == "res:" or not PathGuard.write_path_error(r + "/x.json").is_empty():
		return TEST_DIR_DEFAULT
	return r


static func _suite_files(dir: String) -> Array:
	var names: Array = []
	for f in DirAccess.get_files_at(dir):
		var s := str(f)
		if s.ends_with(".json") and not s.ends_with(".report.json"):
			names.append(s)
	names.sort()
	var out: Array = []
	for n in names:
		out.append("%s/%s" % [dir, n])
	return out


func _suite_name() -> String:
	var n := str(_doc.get("name", "")).strip_edges()
	return (n if not n.is_empty() else "?").left(120)


func _start_next() -> void:
	if _queue.is_empty():
		_finish_run()
		return
	var path: String = _queue.pop_front()
	_doc = {}
	_scene = null
	_inv.close()
	_current = path.get_file().get_basename()
	get_tree().paused = false  # a suite that paused the game does not hand it on paused
	var json := JSON.new()  # an instance: a file that is not JSON is this suite's problem, not an engine error line
	var parsed: Variant = json.data if json.parse(FileAccess.get_file_as_string(path)) == OK else null
	if not (parsed is Dictionary):
		_doc = {"name": _current}
		_suite_ends("blocked", "%s is not a JSON object (a playtest suite)" % path)
		return
	_doc = parsed
	if str(_doc.get("name", "")).strip_edges().is_empty():
		_doc["name"] = _current
	_current = _suite_name()
	var schema: Variant = _whole(_doc.get("schema_version", 1))
	if schema != null and int(schema) > SCHEMA_MAX:
		_suite_ends("blocked", "schema_version %d: this runner reads up to %d (update the Beckett addon of this project)" % [int(schema), SCHEMA_MAX])
		return
	var steps: Variant = _doc.get("steps", null)
	if steps is Array and not (steps as Array).is_empty():
		_suite_ends("blocked", "a steps flow is not replayed by the headless runner (it replays recorded events): run it with playtest op=run, or export it with playtest op=export_gd and run that test")
		return
	var scene_path := str(_doc.get("scene", "")).strip_edges()
	if scene_path.is_empty():
		scene_path = str(ProjectSettings.get_setting("application/run/main_scene", "")).strip_edges()
		if scene_path.is_empty():
			_suite_ends("blocked", "the suite names no scene and the project has no main scene")
			return
	var serr := _scene_error(scene_path)
	if not serr.is_empty():
		_suite_ends("blocked", serr)
		return
	var packed: Variant = load(scene_path)
	if not (packed is PackedScene):
		_suite_ends("blocked", "scene '%s' did not load as a scene" % scene_path.left(160))
		return
	var opened: Dictionary = _inv.open(_doc.get("invariants", null))
	if opened.get("ok", false) != true:
		_suite_ends("fail", "invariants: %s" % str(opened.get("error", "they do not load")))
		return
	var inst: Node = (packed as PackedScene).instantiate()
	if inst == null:
		_inv.close()
		_suite_ends("blocked", "scene '%s' could not be instanced" % scene_path.left(160))
		return
	_events = _frame_sorted(_doc.get("events", []))
	_ev_i = 0
	_tick = 0
	var last_f := 0
	if not _events.is_empty():
		last_f = int(_events[_events.size() - 1]["_f"])
	_end = last_f + SETTLE_FRAMES
	_perf_ms = PackedFloat64Array()
	_perf_fps = PackedFloat64Array()
	_perf_mem0 = Performance.get_monitor(Performance.MEMORY_STATIC)
	_perf_orphan0 = Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var tps := maxi(1, int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60)))
	_deadline = Time.get_ticks_msec() + SUITE_BUDGET_MS + int(float(_end) * 1000.0 / float(tps)) * 4
	get_tree().root.add_child(inst)
	_scene = inst
	_running = true
	# Frame 0 of the rules: the state the scene starts in (the editor's window judges the same one first).
	if _inv.active:
		_inv.check(_scene, 0)


## "" when `path` can be played, else why not: a scene of this project (res://, no '..') that exists.
static func _scene_error(path: String) -> String:
	if path.length() > 400 or not (path.begins_with("res://") or path.begins_with("uid://")) or path.contains(".."):
		return "scene '%s' is not a scene of this project (a res:// path without '..')" % path.left(160)
	for i in path.length():
		if path.unicode_at(i) < 32:
			return "scene '%s' is not a scene of this project (control characters)" % path.left(160).c_escape()
	if not ResourceLoader.exists(path):
		return "scene '%s' does not exist" % path.left(160)
	return ""


## The events with their frame ("_f": the `f` stamp, else the `t` ms at the physics tick rate, else 0), in frame order.
static func _frame_sorted(raw: Variant) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	var tps := maxi(1, int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60)))
	for e in (raw as Array):
		if not (e is Dictionary):
			continue
		var ev: Dictionary = (e as Dictionary).duplicate()
		var f: Variant = _num(ev.get("f", null))
		if f == null:
			var t: Variant = _num(ev.get("t", null))
			f = 0.0 if t == null else float(t) * float(tps) / 1000.0
		ev["_f"] = maxi(0, int(round(float(f))))
		out.append(ev)
	# a stable sort: events stamped with the same frame keep their recorded order
	var keyed: Array = []
	for i in out.size():
		keyed.append([int(out[i]["_f"]), i, out[i]])
	keyed.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]))
	var sorted: Array = []
	for k in keyed:
		sorted.append(k[2])
	return sorted


## One physics frame of the open window, at its END (this node runs last): the scene's frame `_tick` just ran.
func _step() -> void:
	if not _scene_alive():
		_suite_ends("blocked", "the scene was freed (or left the tree) at frame %d of %d, before the suite could be judged" % [_tick, _end])
		return
	if Time.get_ticks_msec() > _deadline:
		_suite_ends("blocked", "the replay did not finish within its wall-clock budget: %d of %d frames ran (the game kept the tree paused, or stopped running physics frames)" % [_tick, _end])
		return
	if get_tree().paused:
		return  # a paused game is not simulating: this frame did not run, and it is not counted
	_perf_tick()
	_tick += 1
	while _ev_i < _events.size() and int(_events[_ev_i]["_f"]) < _tick:
		var ie := _build_event(_events[_ev_i])
		if ie != null:
			Input.parse_input_event(ie)
			InputCodec.track(_held, ie)
		_ev_i += 1
	# Delivered now, not at the next engine iteration: when one iteration runs several physics frames (a slow
	# start), a buffered event would act frames late.
	Input.flush_buffered_events()
	if _inv.active:
		_inv.check(_scene, _tick)
	if _ev_i >= _events.size() and _tick >= _end:
		_running = false
		_run_asserts()
		_close_suite()


func _scene_alive() -> bool:
	return _scene != null and is_instance_valid(_scene) and _scene.is_inside_tree() and not _scene.is_queued_for_deletion()


## Judge the current suite (_doc's asserts on _scene, plus the rules _inv collected), print it, count it.
func _run_asserts() -> void:
	var results: Array = []
	var asserts: Variant = _doc.get("asserts", [])
	if asserts is Array:
		for i in (asserts as Array).size():
			var r := _eval_assert(asserts[i])
			r["id"] = "asserts[%d]" % i
			results.append(r)
	for inv in _inv.results():
		var ir: Dictionary = inv
		ir["id"] = "invariant %s" % str(ir.get("name", "?"))
		results.append(ir)
	_inv.close()
	var t := {"pass": 0, "fail": 0, "blocked": 0, "skip": 0}
	for r in results:
		var s := str(r.get("status", "fail"))
		t[s if t.has(s) else "fail"] = int(t[s if t.has(s) else "fail"]) + 1
	var name := _suite_name()
	if int(t["fail"]) > 0:
		_suites_failed += 1
		print("FAIL %s: %d failed, %d blocked, %d passed, %d skipped" % [name, t["fail"], t["blocked"], t["pass"], t["skip"]])
	elif int(t["blocked"]) > 0:
		_suites_blocked += 1
		print("BLOCKED %s: nothing failed, but %d could not be judged (%d passed, %d skipped)" % [name, t["blocked"], t["pass"], t["skip"]])
	else:
		_suites_passed += 1
		print("ok   %s: %d passed, %d skipped" % [name, t["pass"], t["skip"]])
	for r in results:
		var label := str(r["id"]) if str(r.get("type", "")) == "invariant" else "%s %s" % [r["id"], str(r.get("type", "?"))]
		print("    %-7s %s: %s" % [str(r.get("status", "?")), label, str(r.get("detail", "")).left(DETAIL_CAP).replace("\n", " ")])


## A suite that ended before its asserts were judged (or never started): `status` "blocked" or "fail".
func _suite_ends(status: String, why: String) -> void:
	_running = false
	var name := _suite_name()
	if status == "fail":
		_suites_failed += 1
		print("FAIL %s" % name)
	else:
		_suites_blocked += 1
		print("BLOCKED %s" % name)
	print("    %s" % why.left(DETAIL_CAP).replace("\n", " "))
	_close_suite()


## Put the game back for the next suite: the scene goes, the rules close, held input is let go.
func _close_suite() -> void:
	if _scene != null and is_instance_valid(_scene) and not _scene.is_queued_for_deletion():
		_scene.queue_free()
	_scene = null
	_inv.close()
	if not _held.is_empty():
		InputCodec.release_all(_held)
		Input.flush_buffered_events()


func _finish_run() -> void:
	_finished = true
	print(_summary_line())
	get_tree().quit(_exit_code())


func _summary_line() -> String:
	var line := "%d/%d suites passed (%d failed, %d blocked" % [_suites_passed, _total, _suites_failed, _suites_blocked]
	if _not_judged > 0:
		line += ", %d not judged" % _not_judged
	return line + ")"


## 0 when nothing failed or blocked, 1 when any suite failed (it wins), else 2 (blocked, or not judged).
func _exit_code() -> int:
	if _suites_failed > 0:
		return 1
	if _suites_blocked > 0 or _not_judged > 0:
		return 2
	return 0


# ---------------------------------------------------------------- asserts (the editor's rules: playtest_tools._eval_assert)

func _eval_assert(a: Variant) -> Dictionary:
	if not (a is Dictionary):
		return {"type": "?", "status": "fail", "detail": "an assert must be an object {type, ...}"}
	var d: Dictionary = a
	var type := str(d.get("type", "")).strip_edges().to_lower()
	match type:
		"node_state":
			return _eval_node_state(d)
		"expr":
			return _eval_expr(d)
		"screen_text":
			return _eval_screen_text(d)
		"screenshot":
			return _eval_screenshot(d)
		"perf":
			return _eval_perf(d)
		"no_overlap":
			return _eval_no_overlap(d)
	return {"type": type.left(40), "status": "skip", "detail": "unknown assert type '%s' (%s): not judged" % [type.left(40), " | ".join(PackedStringArray(ASSERT_TYPES))]}


func _gone(type: String) -> Dictionary:
	return {"type": type, "status": "blocked", "detail": "no current scene: the suite's scene is gone"}


## A node by path from the suite's scene: "" or "." is the scene itself, /root/... is absolute, a bare name is
## also looked for anywhere below the scene (the runtime's resolver, without its tree-wide last resort).
func _resolve_node(path: String) -> Node:
	if _scene == null or not is_instance_valid(_scene):
		return null
	var p := path.strip_edges()
	if p.is_empty() or p == "." or p == str(_scene.name):
		return _scene
	if p.begins_with("/"):
		return _scene.get_tree().root.get_node_or_null(NodePath(p)) if _scene.is_inside_tree() else null
	var n := _scene.get_node_or_null(NodePath(p))
	if n == null and not p.contains("/"):
		n = _scene.find_child(p, true, false)
	return n


func _eval_node_state(d: Dictionary) -> Dictionary:
	var target := str(d.get("target", "")).strip_edges()
	var prop := str(d.get("property", "")).strip_edges()
	if target.is_empty() or prop.is_empty() or not d.has("equals"):
		return {"type": "node_state", "status": "fail", "detail": "node_state needs target, property and equals"}
	var subject := "%s.%s" % [target, prop]
	if _scene == null or not is_instance_valid(_scene):
		return _gone("node_state")
	var n := _resolve_node(target)
	if n == null:
		return {"type": "node_state", "status": "blocked", "detail": ("%s: node not found: %s" % [subject, target]).left(DETAIL_CAP)}
	var first := prop.get_slice(":", 0)
	if not (first in n):
		return {"type": "node_state", "status": "fail", "detail": ("%s: %s has no property '%s'" % [subject, n.get_class(), first]).left(DETAIL_CAP)}
	var v: Variant = n.get_indexed(NodePath(prop))
	if _values_equal(v, d["equals"]):
		return {"type": "node_state", "status": "pass", "detail": ("%s == %s" % [subject, str(v)]).left(DETAIL_CAP)}
	return {"type": "node_state", "status": "fail", "detail": ("%s = %s (expected %s)" % [subject, str(v), str(d["equals"])]).left(DETAIL_CAP)}


func _eval_expr(d: Dictionary) -> Dictionary:
	var cond := str(d.get("condition", "")).strip_edges()
	if cond.is_empty():
		return {"type": "expr", "status": "fail", "detail": "expr needs a condition"}
	var ex := Expression.new()
	if ex.parse(cond) != OK:
		return {"type": "expr", "status": "fail", "detail": ("%s: expr parse error: %s" % [cond.left(120), ex.get_error_text()]).left(DETAIL_CAP)}
	if _scene == null or not is_instance_valid(_scene):
		return _gone("expr")
	var v: Variant = ex.execute([], _scene, false)
	if ex.has_execute_failed():
		return {"type": "expr", "status": "blocked", "detail": ("%s: expr exec error: %s" % [cond.left(120), ex.get_error_text()]).left(DETAIL_CAP)}
	if CallArgs.to_bool(v):
		return {"type": "expr", "status": "pass", "detail": "%s -> true" % cond.left(160)}
	return {"type": "expr", "status": "fail", "detail": (("%s -> false (want true)" % cond.left(160)) + _reads_suffix(Invariants.reads_of(cond, _scene))).left(DETAIL_CAP)}


static func _reads_suffix(reads: Dictionary) -> String:
	if reads.is_empty():
		return ""
	var parts := PackedStringArray()
	for k in reads:
		parts.append("%s = %s" % [str(k), str(reads[k])])
	return "; read: " + ", ".join(parts)


func _eval_screen_text(d: Dictionary) -> Dictionary:
	var text := str(d.get("text", ""))
	if text.strip_edges().is_empty():
		return {"type": "screen_text", "status": "fail", "detail": "screen_text needs text"}
	if _scene == null or not is_instance_valid(_scene):
		return _gone("screen_text")
	var found := 0
	var stack: Array = [_scene]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n != _scene and "text" in n and str(n.get("text")).findn(text) != -1:
			found += 1
		stack.append_array(n.get_children())
	if found == 0:
		return {"type": "screen_text", "status": "fail", "detail": "no visible node shows '%s'" % text.left(80)}
	return {"type": "screen_text", "status": "pass", "detail": "'%s' is shown (%d node(s))" % [text.left(80), found]}


func _baseline_path(a: Dictionary) -> String:
	var b := str(a.get("baseline", "")).strip_edges()
	if b.is_empty() or b.contains("://"):
		return b
	return "%s/baselines/%s" % [_test_root(), b if b.get_extension().to_lower() == "png" else b + ".png"]


func _eval_screenshot(a: Dictionary) -> Dictionary:
	var out := {"type": "screenshot"}
	var baseline := _baseline_path(a)
	if baseline.is_empty():
		out["status"] = "fail"
		out["detail"] = "a screenshot assert needs baseline: a .png path such as %s/baselines/<name>.png" % _test_root()
		return out
	out["baseline"] = baseline
	var werr := PathGuard.write_path_error(baseline)
	if not werr.is_empty():
		out["status"] = "skip"
		out["detail"] = "baseline %s refused: %s; nothing was captured and nothing was written" % [baseline.left(160), werr]
		return out
	if baseline.get_extension().to_lower() != "png":
		out["status"] = "fail"
		out["detail"] = "the baseline must be a .png file: %s" % baseline.left(160)
		return out
	if DisplayServer.get_name() == "headless":
		out["status"] = "skip"
		out["detail"] = "the headless display server renders nothing, so the frame was not compared (run the runner with a display to judge screenshots)"
		return out
	if not _scene_alive():
		return _gone("screenshot")
	var img: Image = _scene.get_viewport().get_texture().get_image()
	if img == null or img.is_empty():
		out["status"] = "blocked"
		out["detail"] = "could not capture the game's frame"
		return out
	if not FileAccess.file_exists(baseline):
		if not DirAccess.dir_exists_absolute(baseline.get_base_dir()):
			DirAccess.make_dir_recursive_absolute(baseline.get_base_dir())
		var serr := img.save_png(baseline)
		out["status"] = "skip" if serr == OK else "blocked"
		out["detail"] = ("baseline saved (first run): %s; later runs compare against it" % baseline) if serr == OK else "could not save the baseline %s: %s" % [baseline, error_string(serr)]
		return out
	var base := Image.new()
	var bbytes := FileAccess.get_file_as_bytes(baseline)
	if bbytes.is_empty() or base.load_png_from_buffer(bbytes) != OK:
		out["status"] = "fail"
		out["detail"] = "the baseline %s is not a readable PNG" % baseline
		return out
	var threshold := SNR_DEFAULT
	var th: Variant = _num(a.get("threshold", null))
	if th != null:
		threshold = float(th)
	var snr := _peak_snr(base, img)
	out["peak_snr"] = snr if is_finite(snr) else 999.0
	if snr >= threshold:
		out["status"] = "pass"
		out["detail"] = "peak_snr %.1f dB >= %.1f against %s" % [minf(snr, 999.0), threshold, baseline]
		return out
	out["status"] = "fail"
	var detail := "peak_snr %.1f dB < %.1f: the frame differs from %s" % [snr, threshold, baseline]
	var saved := _save_actual(img, baseline)
	if saved.has("actual"):
		out["actual"] = saved["actual"]
		detail += "; actual: %s" % saved["actual"]
	else:
		detail += "; the actual frame was not written: %s" % str(saved.get("why", "?"))
	out["detail"] = detail
	return out


## Write the frame a screenshot assert saw beside its baseline (<baseline minus .png>.actual.png), through the
## write rule: {"actual": path}, or {"why": text} when it was refused (a link at that name) or failed.
func _save_actual(img: Image, baseline: String) -> Dictionary:
	var actual := baseline.get_basename() + ".actual.png"
	var err := PathGuard.write_path_error(actual)
	if not err.is_empty():
		return {"why": err}
	if not DirAccess.dir_exists_absolute(actual.get_base_dir()):
		DirAccess.make_dir_recursive_absolute(actual.get_base_dir())
	var e := img.save_png(actual)
	if e != OK:
		return {"why": error_string(e)}
	return {"actual": actual}


## Peak SNR (dB) of `cur` against `base`, compared at the baseline's size (playtest_tools._peak_snr).
static func _peak_snr(base: Image, cur: Image) -> float:
	var a := base.duplicate() as Image
	var b := cur.duplicate() as Image
	if a.is_compressed():
		a.decompress()
	if b.is_compressed():
		b.decompress()
	a.convert(Image.FORMAT_RGBA8)
	b.convert(Image.FORMAT_RGBA8)
	if b.get_size() != a.get_size():
		b.resize(a.get_width(), a.get_height(), Image.INTERPOLATE_BILINEAR)
	if a.has_method("compute_image_metrics"):
		var m: Variant = a.call("compute_image_metrics", b, false)
		if m is Dictionary and (m as Dictionary).has("peak_snr"):
			return float(m["peak_snr"])
	a.resize(64, 64, Image.INTERPOLATE_BILINEAR)
	b.resize(64, 64, Image.INTERPOLATE_BILINEAR)
	var ad := a.get_data()
	var bd := b.get_data()
	var sum := 0.0
	for i in ad.size():
		var dv := float(int(ad[i]) - int(bd[i]))
		sum += dv * dv
	var mse := sum / float(maxi(1, ad.size()))
	return INF if mse == 0.0 else 10.0 * log(255.0 * 255.0 / mse) / log(10.0)


static func _render_metric(metric: String) -> bool:
	return metric.begins_with("frame_ms_") or metric.begins_with("fps_") or metric == "draw_calls_end"


func _eval_perf(a: Dictionary) -> Dictionary:
	var metric := str(a.get("metric", "")).strip_edges()
	var out := {"type": "perf", "metric": metric}
	var mx: Variant = _num(a.get("max", null))
	var mn: Variant = _num(a.get("min", null))
	var bad := ""
	if a.get("max", null) == null and a.get("min", null) == null:
		bad = "a perf assert on %s needs max and/or min" % metric.left(40)
	elif (a.get("max", null) != null and mx == null) or (a.get("min", null) != null and mn == null):
		bad = "max and min must be numbers"
	elif not PERF_METRICS.has(metric):
		bad = "unknown perf metric '%s' (known: %s)" % [metric.left(40), ", ".join(PackedStringArray(PERF_METRICS))]
	if not bad.is_empty():
		out["status"] = "fail"
		out["detail"] = bad
		return out
	var perf := _perf_summary()
	if perf.is_empty():
		out["status"] = "skip"
		out["detail"] = "no perf capture for this run: no frame of the replay window ran"
		return out
	if DisplayServer.get_name() == "headless" and _render_metric(metric):
		out["status"] = "skip"
		out["detail"] = "the game runs on the headless display server, which renders nothing: %s is not measured there (memory metrics still are)" % metric
		return out
	var value := float(perf.get(metric, 0.0))
	out["value"] = value
	var broken := ""
	if mx != null and value > float(mx):
		broken = "perf %s = %.2f over max %.2f" % [metric, value, float(mx)]
	elif mn != null and value < float(mn):
		broken = "perf %s = %.2f under min %.2f" % [metric, value, float(mn)]
	if not broken.is_empty():
		out["status"] = "fail"
		out["detail"] = broken
		return out
	out["status"] = "pass"
	if mx != null and mn != null:
		out["detail"] = "perf %s = %.2f within min %.2f and max %.2f" % [metric, value, float(mn), float(mx)]
	elif mx != null:
		out["detail"] = "perf %s = %.2f within max %.2f" % [metric, value, float(mx)]
	else:
		out["detail"] = "perf %s = %.2f within min %.2f" % [metric, value, float(mn)]
	return out


## no_overlap, judged on this process's own physics: the same oracle and the same verdict words as the editor's.
func _eval_no_overlap(d: Dictionary) -> Dictionary:
	var out := {"type": "no_overlap"}
	var bad := PhysicsOverlap.spec_error(d)
	if not bad.is_empty():
		out["status"] = "fail"
		out["detail"] = bad
		return out
	if _scene == null or not is_instance_valid(_scene):
		return _gone("no_overlap")
	var reply := PhysicsOverlap.run(_scene.get_tree() if _scene.is_inside_tree() else null, _scene, d, Callable(self, "_resolve_node"))
	out.merge(PhysicsOverlap.judge(reply), true)
	out["type"] = "no_overlap"
	return out


# ---------------------------------------------------------------- perf (mirrors runtime/replay_perf.gd: extend both)

func _perf_tick() -> void:
	if _perf_ms.size() >= PERF_CAP:
		return
	_perf_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_perf_fps.append(Performance.get_monitor(Performance.TIME_FPS))


## Flat numeric summary ({} until something was sampled), the same keys and maths as ReplayPerf.summary().
func _perf_summary() -> Dictionary:
	if _perf_ms.is_empty():
		return {}
	var by_ms := _perf_ms.duplicate()
	by_ms.sort()
	var n := by_ms.size()
	var total := 0.0
	for v in by_ms:
		total += v
	var fps_total := 0.0
	var fps_min := 0.0
	for i in _perf_fps.size():
		fps_total += _perf_fps[i]
		if i == 0 or _perf_fps[i] < fps_min:
			fps_min = _perf_fps[i]
	return {
		"frames": n,
		"frame_ms_min": by_ms[0],
		"frame_ms_avg": total / float(n),
		"frame_ms_p95": by_ms[clampi(int(ceil(float(n) * 0.95)) - 1, 0, n - 1)],
		"frame_ms_max": by_ms[n - 1],
		"fps_min": fps_min,
		"fps_avg": fps_total / float(maxi(1, _perf_fps.size())),
		"memory_static_end": Performance.get_monitor(Performance.MEMORY_STATIC),
		"memory_delta": Performance.get_monitor(Performance.MEMORY_STATIC) - _perf_mem0,
		"orphan_delta": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) - _perf_orphan0,
		"draw_calls_end": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
	}


# ---------------------------------------------------------------- input (local copy of InputCodec.build_event: extend both)

func _build_event(e: Dictionary) -> InputEvent:
	# The engine's synthetic keyboard/mouse device ids (4.7+), reached through ClassDB so 4.2-4.6 still parse this.
	var dev_kb := -1
	var dev_mouse := -1
	if ClassDB.class_has_integer_constant("InputEvent", "DEVICE_ID_KEYBOARD"):
		dev_kb = ClassDB.class_get_integer_constant("InputEvent", "DEVICE_ID_KEYBOARD")
	if ClassDB.class_has_integer_constant("InputEvent", "DEVICE_ID_MOUSE"):
		dev_mouse = ClassDB.class_get_integer_constant("InputEvent", "DEVICE_ID_MOUSE")
	match str(e.get("type", "")):
		"key":
			var k := InputEventKey.new()
			var kc: int = OS.find_keycode_from_string(str(e.get("keycode", "")))
			k.keycode = kc
			k.physical_keycode = kc
			k.pressed = CallArgs.flag(e, "pressed", true)
			var uni: Variant = e.get("unicode", 0)
			if uni is String and (uni as String).length() > 0:
				k.unicode = (uni as String).unicode_at(0)
			else:
				k.unicode = int(uni) if (uni is int or uni is float) else 0
			if dev_kb >= 0:
				k.device = dev_kb
			return k
		"action":
			var a := InputEventAction.new()
			a.action = StringName(str(e.get("action", "")))
			a.pressed = CallArgs.flag(e, "pressed", true)
			a.strength = float(e.get("strength", 1.0)) if a.pressed else 0.0
			return a
		"mouse_button":
			var mb := InputEventMouseButton.new()
			mb.button_index = int(e.get("button", 1))
			mb.pressed = CallArgs.flag(e, "pressed", true)
			mb.position = _vec2(e.get("position", [0, 0]))
			if dev_mouse >= 0:
				mb.device = dev_mouse
			return mb
		"mouse_motion":
			var mm := InputEventMouseMotion.new()
			mm.position = _vec2(e.get("position", [0, 0]))
			mm.relative = _vec2(e.get("relative", [0, 0]))
			if dev_mouse >= 0:
				mm.device = dev_mouse
			return mm
		"joy_button":
			var jb := InputEventJoypadButton.new()
			jb.button_index = int(e.get("button", 0))
			jb.pressed = CallArgs.flag(e, "pressed", true)
			jb.device = int(e.get("device", 0))
			return jb
		"joy_axis":
			var ja := InputEventJoypadMotion.new()
			ja.axis = int(e.get("axis", 0))
			ja.axis_value = clampf(float(e.get("value", 0.0)), -1.0, 1.0)
			ja.device = int(e.get("device", 0))
			return ja
		"touch":
			var st := InputEventScreenTouch.new()
			st.index = int(e.get("index", 0))
			st.position = _vec2(e.get("position", [0, 0]))
			st.pressed = CallArgs.flag(e, "pressed", true)
			return st
		"touch_drag":
			var sd := InputEventScreenDrag.new()
			sd.index = int(e.get("index", 0))
			sd.position = _vec2(e.get("position", [0, 0]))
			sd.relative = _vec2(e.get("relative", [0, 0]))
			return sd
	return null


static func _vec2(v: Variant) -> Vector2:
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	if v is Dictionary:
		return Vector2(float(v.get("x", 0)), float(v.get("y", 0)))
	return Vector2.ZERO


# ---------------------------------------------------------------- small helpers

## Numeric-tolerant equality (playtest_tools._values_equal): JSON numbers are floats, so 3 equals 3.0.
func _values_equal(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		return is_equal_approx(float(a), float(b))
	if a is bool or b is bool:
		return str(a).to_lower() == str(b).to_lower()
	if a is Array and b is Array:
		if (a as Array).size() != (b as Array).size():
			return false
		for i in (a as Array).size():
			if not _values_equal(a[i], b[i]):
				return false
		return true
	if a is Dictionary and b is Dictionary:
		if (a as Dictionary).size() != (b as Dictionary).size():
			return false
		for k in a:
			if not (b as Dictionary).has(k) or not _values_equal(a[k], b[k]):
				return false
		return true
	return str(a) == str(b)


static func _num(v: Variant) -> Variant:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			return float(v)
		TYPE_STRING, TYPE_STRING_NAME:
			var s := str(v).strip_edges()
			if s.is_valid_float() or s.is_valid_int():
				return s.to_float()
	return null


static func _whole(v: Variant) -> Variant:
	var f: Variant = _num(v)
	if f == null or is_nan(float(f)) or is_inf(float(f)) or float(f) != floorf(float(f)):
		return null
	return int(float(f))
