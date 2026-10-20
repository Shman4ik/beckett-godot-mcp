@tool
extends RefCounted
class_name BeckettPlaytestTools

## playtest (L5, Full): saved play-throughs as regression tests.
##
## A suite is a recorded run (input events from record_input, stamped with the physics frame `f`) or a
## ui_do steps flow, plus end-state asserts and per-frame invariants, stored as
## <beckett/test_dir, default res://tests>/playtests/<name>.json. op=run replays it on the RUNNING game and judges it: every assert,
## step and rule gets pass | fail | skip | blocked, and the run gets the verdict pass | fail | blocked
## (blocked: nothing failed, but something could not be judged). op=repeat runs it n times, restarting
## the scene before each run, and reports pass^k: whether EVERY run passed, which steps flipped, and the
## first step that looked different from the first run.
##
## This build carries the core ops (save, run, list, show, repeat). mutate (playtest_mutate.gd), run_all
## (playtest_select.gd) and export_gd (playtest_export.gd + playtest_standalone.gd) are later modules; until
## they are on disk the dispatcher says so instead of pretending.
##
## Every handler is synchronous (the zero-sidecar rule): a window the game runs (a replay, a ui_do flow, a
## scene restart) is opened game-side and the editor blocks in MCPJobsScript.poll_until, pumping the
## bridge. The handlers only use `server.bridge` (send_command, and is_game_connected / poll_once when the
## bridge has them), so the unit suite can drive them against scripted fakes.

const MCPJobsScript := preload("res://addons/beckett/core/jobs.gd")  # poll_until
const CallArgs := preload("res://addons/beckett/core/callargs.gd")  # flags and numbers arrive as text from lenient clients
const PathGuard := preload("res://addons/beckett/core/path_guard.gd")  # suites, reports, baselines and recordings are paths
const Version := preload("res://addons/beckett/core/version.gd")  # the one plugin.cfg reader: suites and reports are stamped
const RuntimeBridgeScript := preload("res://addons/beckett/core/runtime_bridge.gd")  # BREAK_MARK: the debugger-pause answer
const Invariants := preload("res://addons/beckett/runtime/invariants.gd")  # the rule grammar, validated at save
const UiDo := preload("res://addons/beckett/runtime/ui_do.gd")  # inject/state step shapes and the inject time budget
const GameState := preload("res://addons/beckett/runtime/game_state.gd")  # the state step's validator

## The physics overlap oracle behind the no_overlap assert. A later Full module: loaded when it exists,
## and a build without it fails the assert loudly instead of passing it.
const PHYSICS_OVERLAP_PATH := "res://addons/beckett/runtime/physics_overlap.gd"

const TestDir := preload("res://addons/beckett/core/test_dir.gd")
## The suite and baseline folders under the project's test root (project setting beckett/test_dir,
## default res://tests). Read once per module instance, i.e. per editor session.
var PLAYTEST_DIR: String = TestDir.root() + "/playtests"
var BASELINE_DIR: String = TestDir.root() + "/baselines"
## Default peak signal-to-noise threshold (dB) of a screenshot assert: identical frames and a single
## anti-aliasing pixel pass, a recoloured or half-changed frame fails (pinned by the unit suite).
const SNR_DEFAULT := 30.0
## The longest reason a batch keeps for one run. Must hold a whole debugger-pause answer (the longest is
## ~613 characters), so the way on (Continue (F12)) is never cut off.
const BREAK_REASON_CAP := 900
const SCHEMA_MAX := 2
const N_DEFAULT := 5
const N_MAX := 50
const DETAIL_CAP := 200
const TYPE_CAP := 40

const OPS := "save | run | list | show | repeat"
const DEFERRED_OPS := {
	"mutate": "tools/playtest_mutate.gd",
	"run_all": "tools/playtest_select.gd",
	"export_gd": "tools/playtest_export.gd and tools/playtest_standalone.gd",
}
const ASSERT_TYPES := ["node_state", "expr", "screen_text", "screenshot", "perf", "no_overlap"]
const STEP_KINDS := ["click", "type", "wait", "assert", "input"]
const PERF_METRICS := ["frames", "frame_ms_min", "frame_ms_avg", "frame_ms_p95", "frame_ms_max", "fps_min", "fps_avg",
	"memory_static_end", "memory_delta", "orphan_delta", "draw_calls_end"]
const OVERLAP_KEYS := ["paths", "group", "min_depth", "max_pairs", "max_bodies", "budget_ms"]

const NOT_CONNECTED := "game not running/connected: call play_scene, then wait_until condition=game_connected, then playtest op=%s"
const RESET_TEXT := ("the scene was restarted before every run (scene_reload: a fresh instance from its file, its resources read again,"
	+ " held input released). NOT reset: autoloads, saved files, engine singletons and static variables, so a suite that depends on them"
	+ " carries their state from run to run")

## ms budget of one op=repeat call: a run that would not fit is not started (the batch is truncated).
var repeat_cap_ms: int = 45000
## How long a restarted scene may take to come back before the batch gives up on it.
var restart_cap_ms: int = 5000

var server  # mcp_server node; only .bridge is used


func _register(registry) -> void:
	registry.register({
		"name": "playtest",
		"description": "Saved play-throughs as regression tests. op=save stores a suite (record_input events or ui_do steps, end-state asserts, per-frame invariants) in <test dir>/playtests/<name>.json (project setting beckett/test_dir, default res://tests); op=run replays it on the RUNNING game: verdict pass | fail | blocked; op=repeat runs it n times from a scene restart and reports pass^k, flaky steps and the first divergence; op=list, op=show. Not in this build yet: mutate, run_all, export_gd. Grammar: help(tool=\"playtest\").",
		"help": _help_text(),
		"input_schema": {"type": "object", "properties": {
			"op": {"type": "string", "description": "save | run | list | show | repeat (mutate, run_all and export_gd are not in this build yet)"},
			"name": {"type": "string", "description": "suite name (a file stem: letters, digits, _ and -)"},
			"scene": {"type": "string", "description": "op=save: the res:// scene the suite plays (stored; op=run plays the running scene)"},
			"events": {"type": "array", "description": "op=save: recorded input events (record_input op=stop), or a path to its JSON"},
			"steps": {"type": "array", "description": "op=save: ui_do steps (click/type/wait/assert/input/inject/state) instead of events"},
			"asserts": {"type": "array", "description": "op=save: end-state asserts (node_state, expr, screen_text, screenshot, perf, no_overlap)"},
			"invariants": {"type": "array", "description": "op=save: [{name, expr}] rules checked on every physics frame (max 16)"},
			"settle_frames": {"type": "integer", "description": "frames the game runs after the last event before judging (default 4)"},
			"step_timeout_ms": {"type": "integer", "description": "steps suites: per-step timeout (default 5000)"},
			"deterministic": {"type": "boolean", "description": "false replays framed events back to back in real time (default true)"},
			"save_baseline": {"type": "boolean", "description": "op=run: store this run's perf (and screenshot baselines) as the baseline"},
			"report": {"type": "boolean", "description": "op=run: also write <name>.report.json beside the suite"},
			"n": {"type": "integer", "description": "op=repeat: how many runs (1..50, default 5)"},
		}},
		"handler": Callable(self, "_playtest"),
	})


static func _help_text() -> String:
	return "\n".join(PackedStringArray([
		"playtest: a saved run of the game, replayed and judged. Ops in this build: save, run, list, show, repeat.",
		"(mutate, run_all and export_gd come with later modules: the op answers 'not in this build yet'.)",
		"",
		"SAVE  op=save name=walk scene=res://arena.tscn events=[...] | steps=[...] asserts=[...] invariants=[...]",
		"  events: the recording record_input op=stop returns (or a path to the JSON it saved). Events stamped with",
		"  the physics frame f replay frame-exactly in a replay window (deterministic); events without f, or",
		"  deterministic=false, go to the game back to back in real time (plain).",
		"  steps: a ui_do flow instead (click / type / wait / assert / input / inject / state), run game-side frame by",
		"  frame (help(tool=\"ui_do\") has the step grammar). step_timeout_ms (default 5000) is per step.",
		"  op=save refuses a malformed assert, step or invariant and writes nothing. A suite that uses an inject or",
		"  state step, an invariant or no_overlap is saved as schema_version 2; a Beckett that reads only 1 refuses it.",
		"",
		"ASSERTS (judged on the end state, after the run; the game is frozen first):",
		"  {type:\"node_state\", target:\"Player\", property:\"health\", equals:3}   numbers compare with tolerance",
		"  {type:\"expr\", condition:\"get_node('Player').position.x > 50\"}  a GDScript Expression on the scene root;",
		"      use get_node / get_node_or_null ($ is not available). A false one reports the values it read.",
		"  {type:\"screen_text\", text:\"You win\"}   a visible node shows the text",
		"  {type:\"screenshot\", baseline:\"res://tests/baselines/win.png\", threshold:30}   screenshot asserts compare",
		"      the frame by peak SNR (dB, default 30). No baseline yet: this frame is saved as it and the assert skips.",
		"      A failing frame is written next to it as <baseline>.actual.png (through the write rule).",
		"  {type:\"perf\", metric:\"frame_ms_p95\", max:16.7}   (or min) on the replay window's capture: frames,",
		"      frame_ms_min/avg/p95/max, fps_min/avg, memory_static_end, memory_delta, orphan_delta, draw_calls_end.",
		"      A headless game renders nothing, so frame_ms_*, fps_* and draw_calls_end skip there.",
		"  {type:\"no_overlap\", paths?, group?, min_depth?, max_pairs?, max_bodies?}   physics bodies that penetrate;",
		"      needs runtime/physics_overlap.gd, and fails loudly when this build does not have it.",
		"",
		"VERDICTS  every assert, step and rule is pass | fail | skip | blocked:",
		"  fail     it was judged and is wrong (or it is malformed: an expression that does not parse)",
		"  blocked  it never got to a judgement: a node not found, no current scene, a lost connection, a",
		"           game paused in the editor's debugger, an expression that could not run",
		"  skip     not judged on purpose, with why (no perf capture, headless, a flow that stopped early)",
		"  The run: fail if anything failed, else blocked if anything was blocked, else pass; ok is verdict == pass.",
		"  In a steps suite the end-state asserts are only judged when the whole flow passed.",
		"",
		"INVARIANTS  [{name, expr}] checked on EVERY physics frame of a replay window or a steps flow (max 16).",
		"  A violated rule fails the run with first_violation {frame, reads}; a rule that could never be evaluated",
		"  is blocked, not passed. A plain (real-time) replay has no per-frame window: its rules skip.",
		"",
		"INJECT  a step {inject:{set:[{node, property, value}], call:[{node, method, args}], frames:N}} or the flat",
		"  {kind:\"inject\", set, call, frames} patches state in, then lets the game run N frames. The wait for a",
		"  flow adds the stepping time of its inject steps.",
		"STATE (1.16)  a step {state:{node, path, op, value}} (or {kind:\"state\", ...}) judges the state a node",
		"  exposes through _beckett_state(); ops eq ne lt le gt ge contains exists.",
		"",
		"RUN  op=run name=walk [save_baseline=true] [report=true] plays on the RUNNING game as it is (no restart).",
		"  Result: verdict, ok, passed / failed / blocked / skipped, asserts (each with i = its place in the suite;",
		"  invariant results sit there too), mode, replay or step_results, perf.",
		"  PERF BASELINE  save_baseline=true stores this run's perf with a fingerprint of the setup (OS, CPU, GPU,",
		"  renderer, viewport, engine, build, recording). Later runs return perf_diff against it, and",
		"  perf_baseline_comparable: true, false (perf_baseline_mismatch names [baseline, now]) or \"unknown\" (no",
		"  fingerprint). Absolute perf asserts are judged on the run alone. report=true writes <name>.report.json.",
		"",
		"REPEAT  op=repeat name=walk n=5: n runs (1..50), each from a scene restart; one more restart ends the batch.",
		"  pass_all is pass^k: true only when EVERY run passed (pass_rate is the mean). outcomes is each verdict;",
		"  flaky_steps ranks the steps that flipped pass <-> fail (most flips first), flaky_blocked the ones that",
		"  flipped to or from blocked; first_divergence {step, run, vs_run, was, now} is the first step that looked",
		"  different from the first run that had steps. A perf bound broken by a run that measures right after a",
		"  scene restart (loading, shader compiles) is blocked, not a flaky step. The batch stops when the next run",
		"  would not fit the call's time budget (truncated, pass_all false), when the connection is lost, when the",
		"  game is paused in the debugger, or after two runs in a row that timed out (aborted). save_baseline and",
		"  report are ignored. The restart does not reset autoloads, files or engine singletons.",
		"",
		"LIST / SHOW  op=list: every suite with its event, step, assert and invariant counts. op=show name=x: the",
		"  suite file and its last report.",
	]))


# ---------------------------------------------------------------- dispatch

func _playtest(args: Dictionary) -> Dictionary:
	var op := str(args.get("op", "")).strip_edges().to_lower()
	if op == "save":
		return _save(args)
	if op in ["run", "list", "show", "repeat"]:
		var guard := PathGuard.check_read(PLAYTEST_DIR)
		if guard.has("error"):
			return guard
		match op:
			"run":
				return _with_read_note(_run(args), guard)
			"list":
				return _with_read_note(_list(), guard)
			"show":
				return _with_read_note(_show(args), guard)
			_:
				return _with_read_note(_repeat(args), guard)
	if DEFERRED_OPS.has(op):
		return _not_in_build(op)
	return {"error": "unknown op '%s': %s (mutate, run_all and export_gd are not in this build yet)" % [op.left(40), OPS],
		"suggestion": "help(tool=\"playtest\") has the grammar"}


func _not_in_build(op: String) -> Dictionary:
	return {"error": "op=%s is not in this build yet: it needs %s, which this Beckett does not have. This build runs %s." % [op, DEFERRED_OPS[op], OPS],
		"suggestion": "op=repeat measures how stable a suite is; op=run judges it once"}


func _mutate(_args: Dictionary) -> Dictionary:
	return _not_in_build("mutate")


func _run_all(_args: Dictionary) -> Dictionary:
	return _not_in_build("run_all")


func _export_gd(_args: Dictionary) -> Dictionary:
	return _not_in_build("export_gd")


## A reply carrying the outside-read note of the suite folder (nothing when the folder is in the project).
static func _with_read_note(reply: Dictionary, guard: Dictionary) -> Dictionary:
	return PathGuard.noted(reply, guard)


func _beckett_version() -> String:
	return Version.current()


# ---------------------------------------------------------------- verdict helpers (pure)

static func verdict_of(failed: int, blocked: int) -> String:
	if failed > 0:
		return "fail"
	return "blocked" if blocked > 0 else "pass"


static func status_of(result: Variant) -> String:
	if not (result is Dictionary):
		return "fail"
	var s := str((result as Dictionary).get("status", ""))
	if s in ["pass", "fail", "skip", "blocked"]:
		return s
	return "pass" if CallArgs.to_bool((result as Dictionary).get("ok", false)) else "fail"


static func tally_of(results: Array) -> Dictionary:
	var t := {"pass": 0, "fail": 0, "blocked": 0, "skip": 0}
	for r in results:
		var s := status_of(r)
		t[s] = int(t[s]) + 1
	return t


## Did this error stop a judgement (blocked) rather than make one (fail)?
static func is_unjudged(err: String) -> bool:
	if err.is_empty():
		return false
	for needle in ["game not running", "runtime disconnected", "runtime timeout", "node not found", "no node matches",
			"no current scene", "expr exec error", "not found yet", "no scene tree", RuntimeBridgeScript.BREAK_MARK]:
		if err.contains(needle):
			return true
	return false


## The channel itself failed (timeout, lost connection, debugger pause), as opposed to the game answering.
static func is_channel_error(err: String) -> bool:
	return err.contains("runtime timeout") or err.contains("runtime disconnected") or is_break(err)


static func is_break(err: String) -> bool:
	return err.contains(RuntimeBridgeScript.BREAK_MARK)


static func is_disconnect(err: String) -> bool:
	return err.contains("runtime disconnected")


## "; read: a = 1, b = 2" from an eval reply's `reads`, "" when there are none.
static func reads_suffix(reply: Variant) -> String:
	if not (reply is Dictionary):
		return ""
	var reads: Variant = (reply as Dictionary).get("reads", null)
	if not (reads is Dictionary) or (reads as Dictionary).is_empty():
		return ""
	var parts := PackedStringArray()
	for k in reads:
		parts.append("%s = %s" % [str(k), str(reads[k])])
	return "; read: " + ", ".join(parts)


## 2 when the suite uses anything a schema-1 reader would run wrongly (inject or state steps, invariants,
## a no_overlap assert), else 1.
static func schema_for(steps: Variant, invariants: Variant, asserts: Variant = []) -> int:
	if invariants is Array and not (invariants as Array).is_empty():
		return 2
	if steps is Array:
		for s in steps:
			if s is Dictionary and (UiDo.is_inject(s) or UiDo.is_state(s)):
				return 2
	if asserts is Array:
		for a in asserts:
			if a is Dictionary and str((a as Dictionary).get("type", "")).to_lower() == "no_overlap":
				return 2
	return 1


# ---------------------------------------------------------------- perf baseline fingerprint (pure)

## Are two setups' fingerprints alike? {comparable: true | false | "unknown", mismatch: {field: [baseline, now]}}.
## A field one side could not read (missing, null, "") is skipped: it is not evidence of another setup.
static func fingerprint_compare(base: Variant, now: Variant) -> Dictionary:
	if not (base is Dictionary) or (base as Dictionary).is_empty():
		return {"comparable": "unknown", "mismatch": {}}
	var cur: Dictionary = now if now is Dictionary else {}
	var mismatch := {}
	for k in base:
		var b: Variant = base[k]
		if not cur.has(k):
			continue
		var c: Variant = cur[k]
		if b == null or c == null or str(b).is_empty() or str(c).is_empty():
			continue
		if str(b) != str(c):
			mismatch[k] = [b, c]
	return {"comparable": mismatch.is_empty(), "mismatch": mismatch}


static func comparability_note(cmp: Dictionary) -> String:
	var c: Variant = cmp.get("comparable", "unknown")
	if c is bool and c:
		return ""
	if c is bool:
		var parts := PackedStringArray()
		var mm: Dictionary = cmp.get("mismatch", {}) if cmp.get("mismatch", {}) is Dictionary else {}
		for k in mm:
			var pair: Array = mm[k] if mm[k] is Array else [mm[k], ""]
			parts.append("%s %s -> %s" % [str(k), str(pair[0]), str(pair[1]) if pair.size() > 1 else ""])
		return ("PERF BASELINE NOT COMPARABLE: the baseline was measured on another setup (%s), so perf_diff compares unlike numbers."
			+ " Run once with save_baseline=true on this setup to replace it. Absolute perf asserts are not affected.") % ", ".join(parts)
	return ("PERF BASELINE UNVERIFIED: the stored baseline has no fingerprint (saved before 1.16), so nothing says it was measured on this setup."
		+ " Run once with save_baseline=true to stamp it. Absolute perf asserts are not affected.")


## md5 of the recorded run (its events, or its steps): key order does not matter, the asserts are not part of it.
static func suite_hash(doc: Variant) -> String:
	var d: Dictionary = doc if doc is Dictionary else {}
	var body := {}
	if d.get("steps") is Array and not (d["steps"] as Array).is_empty():
		body["steps"] = _canon(d["steps"])
	else:
		body["events"] = _canon(d.get("events", []) if d.get("events", []) is Array else [])
	return JSON.stringify(body, "", true).md5_text()


## Whole floats as ints, so a suite read back from JSON hashes like the one that was written.
static func _canon(v: Variant) -> Variant:
	if v is float and is_finite(v) and v == floorf(v) and absf(v) < 1e15:
		return int(v)
	if v is Array:
		var out: Array = []
		for e in v:
			out.append(_canon(e))
		return out
	if v is Dictionary:
		var o := {}
		for k in v:
			o[str(k)] = _canon(v[k])
		return o
	return v


# ---------------------------------------------------------------- batch maths (pure)

## The batch over runs [{verdict, units: [{id, type, status, detail}], reason?}].
static func aggregate(runs: Array) -> Dictionary:
	var outcomes: Array = []
	var passes := 0
	var fails := 0
	var blocked := 0
	var order: Array = []
	var info := {}
	var ref_run := -1
	for ri in runs.size():
		var rd: Dictionary = runs[ri] if runs[ri] is Dictionary else {}
		var v := str(rd.get("verdict", "blocked"))
		outcomes.append(v)
		if v == "pass":
			passes += 1
		elif v == "fail":
			fails += 1
		else:
			blocked += 1
		var units: Array = rd.get("units", []) if rd.get("units", []) is Array else []
		if ref_run < 0 and not units.is_empty():
			ref_run = ri
		for u in units:
			if not (u is Dictionary):
				continue
			var id := str((u as Dictionary).get("id", ""))
			if not info.has(id):
				order.append(id)
				info[id] = {"type": str((u as Dictionary).get("type", "")), "seq": []}
			(info[id]["seq"] as Array).append({"run": ri, "status": status_of(u), "detail": str((u as Dictionary).get("detail", ""))})
	var steps: Array = []
	var flaky: Array = []
	var flaky_blocked: Array = []
	var first_div: Variant = null
	for idx in order.size():
		var id: String = order[idx]
		var it: Dictionary = info[id]
		var seq: Array = it["seq"]
		var counts := {}
		var examples := {}
		var flips := 0
		var bflips := 0
		var last_judged := ""
		var last_seen := ""
		var ref_e: Variant = null
		for e in seq:
			var s := str(e["status"])
			counts[s] = int(counts.get(s, 0)) + 1
			if not examples.has(s):
				examples[s] = str(e["detail"]).left(DETAIL_CAP)
			if s == "pass" or s == "fail":
				if not last_judged.is_empty() and s != last_judged:
					flips += 1
				last_judged = s
			if s != "skip":
				if not last_seen.is_empty() and s != last_seen and (s == "blocked" or last_seen == "blocked"):
					bflips += 1
				last_seen = s
			if int(e["run"]) == ref_run:
				ref_e = e
		var entry := {"step": id, "type": str(it["type"]), "outcomes": counts, "examples": examples}
		if flips > 0:
			entry["flips"] = flips
			flaky.append({"step": id, "type": str(it["type"]), "flips": flips, "_i": idx})
		if bflips > 0:
			entry["blocked_flips"] = bflips
			flaky_blocked.append({"step": id, "type": str(it["type"]), "flips": bflips, "_i": idx})
		steps.append(entry)
		if first_div == null and ref_e != null:
			for e in seq:
				if int(e["run"]) > ref_run and _diverges(ref_e, e, str(it["type"])):
					first_div = {"step": id, "run": int(e["run"]) + 1, "vs_run": ref_run + 1,
						"was": ("%s: %s" % [ref_e["status"], ref_e["detail"]]).left(DETAIL_CAP),
						"now": ("%s: %s" % [e["status"], e["detail"]]).left(DETAIL_CAP)}
					break
	return {"runs": runs.size(), "passes": passes, "fails": fails, "blocked": blocked,
		"pass_rate": float(passes) / float(runs.size()) if runs.size() > 0 else 0.0,
		"outcomes": outcomes, "steps": steps, "flaky_steps": _ranked(flaky), "flaky_blocked": _ranked(flaky_blocked),
		"first_divergence": first_div}


## Most flips first; a tie keeps the order the steps were first seen in.
static func _ranked(list: Array) -> Array:
	list.sort_custom(func(a, b): return int(a["flips"]) > int(b["flips"]) or (int(a["flips"]) == int(b["flips"]) and int(a["_i"]) < int(b["_i"])))
	for e in list:
		(e as Dictionary).erase("_i")
	return list


## Does this step look different from the reference run? A skip judges nothing; two passes agree; a
## perf detail that differs only in its numbers is the same outcome.
static func _diverges(ref_e: Dictionary, e: Dictionary, type: String) -> bool:
	var a := str(ref_e["status"])
	var b := str(e["status"])
	if a == "skip" or b == "skip":
		return false
	if a != b:
		return true
	if a == "pass":
		return false
	var da := str(ref_e["detail"])
	var db := str(e["detail"])
	if type == "perf":
		var re := RegEx.create_from_string("[0-9][0-9.]*")
		da = re.sub(da, "#", true)
		db = re.sub(db, "#", true)
	return da != db


## One run's result as batch units: invariants first, then the steps of a flow, then the asserts.
static func run_summary(out: Dictionary) -> Dictionary:
	var verdict := str(out["verdict"]) if out.has("verdict") else ("pass" if CallArgs.to_bool(out.get("ok", false)) else "fail")
	var mode := "deterministic" if CallArgs.to_bool(out.get("deterministic", false)) else str(out.get("mode", ""))
	var asserts: Array = out.get("asserts", []) if out.get("asserts", []) is Array else []
	var step_results: Array = out.get("step_results", []) if out.get("step_results", []) is Array else []
	var units: Array = []
	for a in asserts:
		if a is Dictionary and str((a as Dictionary).get("type", "")) == "invariant":
			units.append(_unit("invariant:%s" % str((a as Dictionary).get("name", "")), "invariant", a))
	for k in step_results.size():
		var s: Variant = step_results[k]
		if s is Dictionary:
			units.append(_unit("steps[%d]" % _int_of((s as Dictionary).get("step", k), k), str((s as Dictionary).get("op", "step")), s))
	for k in asserts.size():
		var a: Variant = asserts[k]
		if a is Dictionary and str((a as Dictionary).get("type", "")) != "invariant":
			units.append(_unit("asserts[%d]" % _int_of((a as Dictionary).get("i", k), k), str((a as Dictionary).get("type", "")), a))
	return {"verdict": verdict, "mode": mode, "units": units}


static func _unit(id: String, type: String, r: Dictionary) -> Dictionary:
	var status := status_of(r)
	var detail := str(r.get("detail", ""))
	if r.has("error") and (status != "pass" or detail.is_empty()):
		detail = str(r["error"])
	return {"id": id, "type": type.left(TYPE_CAP), "status": status, "detail": detail.left(DETAIL_CAP)}


# ---------------------------------------------------------------- small helpers

## A whole number from an int, a whole float or digits in text; null for anything else (bools included).
static func _whole(v: Variant) -> Variant:
	match typeof(v):
		TYPE_INT:
			return v
		TYPE_FLOAT:
			if is_finite(v) and v == floorf(v) and absf(v) < 1e15:
				return int(v)
		TYPE_STRING, TYPE_STRING_NAME:
			var s := str(v).strip_edges()
			if s.is_valid_int():
				return s.to_int()
			if s.is_valid_float():
				return _whole(s.to_float())
	return null


static func _int_of(v: Variant, default: int) -> int:
	var w: Variant = _whole(v)
	return int(w) if w != null else default


static func _num(v: Variant) -> Variant:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			return float(v)
		TYPE_STRING, TYPE_STRING_NAME:
			var s := str(v).strip_edges()
			if s.is_valid_float() or s.is_valid_int():
				return s.to_float()
	return null


static func _ok(r: Dictionary) -> bool:
	return CallArgs.to_bool(r.get("ok", false))


static func _err_of(r: Dictionary, what: String) -> String:
	return str(r.get("error", "%s failed" % what)).left(BREAK_REASON_CAP)


## What a failed window command is reported as: the debugger-pause answer whole, anything else prefixed.
static func _fail_text(what: String, err: String) -> String:
	if is_break(err):
		return err.left(BREAK_REASON_CAP)
	return ("%s failed: %s" % [what, err]).left(BREAK_REASON_CAP)


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


## A suite name as a file stem: no folders, no .json, only letters, digits, _ and -.
func _sanitize(name: String) -> String:
	var n := name.strip_edges().replace("\\", "/").get_file()
	if n.to_lower().ends_with(".json"):
		n = n.substr(0, n.length() - 5)
	var out := ""
	for i in n.length():
		var c := n[i]
		var u := n.unicode_at(i)
		if (u >= 48 and u <= 57) or (u >= 65 and u <= 90) or (u >= 97 and u <= 122) or c == "_" or c == "-":
			out += c
		else:
			out += "_"
	return out.left(120)


func _bridge() -> Object:
	if server == null:
		return null
	var b: Variant = server.get("bridge") if server is Object else null
	return b as Object


func _connected() -> bool:
	var b := _bridge()
	if b == null:
		return false
	return not b.has_method("is_game_connected") or CallArgs.to_bool(b.call("is_game_connected"))


## One command to the game: its reply, or {ok:false, error} when there is no channel at all.
func _cmd(cmd: Dictionary, timeout_ms: int = 4000) -> Dictionary:
	var b := _bridge()
	if b == null:
		return {"ok": false, "error": "game not running (no runtime connection). Call play_scene first, then wait_until condition=game_connected."}
	var r: Variant = b.call("send_command", cmd, timeout_ms)
	if r is Dictionary:
		return r
	return {"ok": false, "error": "%s: the game sent no reply" % str(cmd.get("cmd", "command"))}


func _pump() -> Callable:
	var b := _bridge()
	if b != null and b.has_method("poll_once"):
		return Callable(b, "poll_once")
	return Callable()


## Block (pumping the bridge) until `status_cmd` reports the window closed: {reply} | {timeout, reply} | {error, reply}.
func _poll_status(status_cmd: Dictionary, done: Callable, timeout_ms: int, interval_ms: int = 50) -> Dictionary:
	var last := {"reply": {}}
	var tick := func() -> Dictionary:
		var r := _cmd(status_cmd, 2000)
		last["reply"] = r
		if not _ok(r):
			return {"error": _err_of(r, str(status_cmd.get("cmd", "status")))}
		return {"done": true} if CallArgs.to_bool(done.call(r)) else {}
	var res: Dictionary = MCPJobsScript.poll_until(timeout_ms, interval_ms, tick, _pump())
	if res.has("error"):
		return {"error": str(res["error"]), "reply": last["reply"]}
	if res.has("timeout"):
		return {"timeout": true, "reply": last["reply"]}
	return {"reply": last["reply"]}


## Let the game run for `ms` while the editor waits (bridge pumped).
func _hold(ms: int) -> void:
	if ms <= 0:
		return
	MCPJobsScript.poll_until(ms, 10, func() -> Dictionary: return {}, _pump())


static func _tps() -> int:
	return maxi(1, int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60)))


# ---------------------------------------------------------------- suite files

func _store(name: String, doc: Dictionary) -> String:
	var path := "%s/%s.json" % [PLAYTEST_DIR, name]
	var werr := PathGuard.write_path_error(path)
	if not werr.is_empty():
		return werr
	return _write_json(path, doc)


func _write_report(path: String, report: Dictionary) -> String:
	var werr := PathGuard.write_path_error(path)
	if not werr.is_empty():
		return werr
	return _write_json(path, report)


static func _write_json(path: String, data: Variant) -> String:
	var dir := path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		var derr := DirAccess.make_dir_recursive_absolute(dir)
		if derr != OK:
			return "cannot create %s: %s" % [dir, error_string(derr)]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "cannot write %s: %s" % [path, error_string(FileAccess.get_open_error())]
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	return ""


func _load(name: String) -> Dictionary:
	var stem := _sanitize(name)
	if stem.is_empty():
		return {"error": "name a saved suite (playtest op=list shows them)"}
	var path := "%s/%s.json" % [PLAYTEST_DIR, stem]
	var guard := PathGuard.check_read(path)
	if guard.has("error"):
		return guard
	if not FileAccess.file_exists(path):
		return {"error": "no playtest at %s (playtest op=list shows the saved suites; op=save makes one)" % path}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return {"error": "%s is not a playtest suite (expected a JSON object)" % path}
	var doc: Dictionary = parsed
	var sv := _int_of(doc.get("schema_version", 1), 1)
	if sv > SCHEMA_MAX:
		return {"error": "%s has schema_version %d, and this Beckett reads up to %d: it was saved by a newer Beckett, which judges things this one does not know. Update the plugin to run it." % [path, sv, SCHEMA_MAX]}
	return doc


func _suite_names() -> Dictionary:
	var names: Array = []
	var odd: Array = []
	if DirAccess.dir_exists_absolute(PLAYTEST_DIR):
		for f in DirAccess.get_files_at(PLAYTEST_DIR):
			var file := str(f)
			if not file.ends_with(".json") or file.ends_with(".report.json"):
				continue
			var stem := file.substr(0, file.length() - 5)
			if _sanitize(stem) == stem:
				names.append(stem)
			else:
				odd.append(file)
	names.sort()
	return {"names": names, "odd": odd}


# ---------------------------------------------------------------- op=save

func _save(args: Dictionary) -> Dictionary:
	var name := _sanitize(str(args.get("name", "")))
	if name.is_empty():
		return {"error": "op=save needs name: the suite's file stem (letters, digits, _ and -)"}
	var scene := str(args.get("scene", "")).strip_edges() if args.get("scene") != null else ""
	if not scene.is_empty() and (not (scene.begins_with("res://") or scene.begins_with("user://")) or scene.contains("..")):
		return {"error": "scene must be a res:// (or user://) scene of this project, without '..': %s" % scene.left(160)}
	var events: Variant = args.get("events", null)
	if events is String and not (events as String).strip_edges().is_empty():
		var rec := _read_recording((events as String).strip_edges())
		if rec.has("error"):
			return rec
		events = rec["events"]
	var steps: Variant = args.get("steps", null)
	var has_events := events is Array and not (events as Array).is_empty()
	var has_steps := steps is Array and not (steps as Array).is_empty()
	if has_events and has_steps:
		return {"error": "give events (a recorded run) or steps (a ui_do flow), not both"}
	if not has_events and not has_steps:
		return {"error": "op=save needs events (record_input op=stop, or the path of its JSON) or steps (a ui_do flow)"}
	if has_events:
		for i in (events as Array).size():
			if not ((events as Array)[i] is Dictionary):
				return {"error": "events[%d] must be an object (a wire event as record_input returns it)" % i}
	if has_steps:
		var serr := _steps_error(steps as Array)
		if not serr.is_empty():
			return {"error": serr}
	var asserts: Variant = args.get("asserts", [])
	if asserts == null:
		asserts = []
	if not (asserts is Array):
		return {"error": "asserts must be an array of {type, ...} objects"}
	asserts = (asserts as Array).duplicate(true)
	for i in (asserts as Array).size():
		var aerr := _assert_error(asserts[i], i, name)
		if not aerr.is_empty():
			return {"error": aerr}
	var inv := Invariants.normalize(args.get("invariants", null))
	if not CallArgs.to_bool(inv.get("ok", false)):
		return {"error": "invariants: %s" % str(inv.get("error", "do not load"))}
	var rules: Array = inv["items"]
	var doc := {"name": name, "scene": scene, "schema_version": schema_for(steps if has_steps else [], rules, asserts)}
	if has_steps:
		doc["steps"] = steps
	else:
		doc["events"] = events
	doc["asserts"] = asserts
	if not rules.is_empty():
		doc["invariants"] = rules
	for k in ["settle_frames", "step_timeout_ms"]:
		if args.has(k) and args[k] != null:
			var w: Variant = _whole(args[k])
			if w == null or int(w) < 0:
				return {"error": "%s must be a whole number >= 0" % k}
			doc[k] = int(w)
	doc["beckett"] = _beckett_version()
	# A re-save of the same recording keeps its perf baseline: the numbers still describe this run.
	var old := _load(name)
	if not old.has("error") and old.get("perf_baseline") is Dictionary and suite_hash(old) == suite_hash(doc):
		doc["perf_baseline"] = old["perf_baseline"]
	var err := _store(name, doc)
	if not err.is_empty():
		return {"error": "could not save the suite: %s" % err}
	var n_events := (events as Array).size() if has_events else 0
	var n_steps := (steps as Array).size() if has_steps else 0
	var text := "saved playtest '%s' to %s/%s.json: %d events, %d steps, %d asserts, %d invariants (schema %d, mode %s). Run it with playtest op=run name=%s; op=repeat n=5 shows whether it is stable." % [
		name, PLAYTEST_DIR, name, n_events, n_steps, (asserts as Array).size(), rules.size(), int(doc["schema_version"]), _mode_of(doc, {}), name]
	if not scene.is_empty() and not ResourceLoader.exists(scene):
		text += " NOTE: %s does not exist (yet)." % scene
	return {"text": text}


func _read_recording(path: String) -> Dictionary:
	var guard := PathGuard.check_read(path)
	if guard.has("error"):
		return guard
	if not FileAccess.file_exists(path):
		return {"error": "no recording at %s" % path}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var ev: Variant = (parsed as Dictionary).get("events", null) if parsed is Dictionary else parsed
	if not (ev is Array):
		return {"error": "%s is not a recording (expected {events:[...]} or a JSON array)" % path}
	return {"events": ev}


static func _steps_error(steps: Array) -> String:
	for i in steps.size():
		var s: Variant = steps[i]
		if not (s is Dictionary):
			return "steps[%d] must be an object ({click|type|wait|assert|input|inject|state: ...})" % i
		var d: Dictionary = s
		if UiDo.is_inject(d):
			var ie := UiDo.inject_error(UiDo.inject_body(d))
			if not ie.is_empty():
				return "steps[%d]: %s" % [i, ie]
			continue
		if UiDo.is_state(d):
			var se := GameState.spec_error(UiDo.state_body(d))
			if not se.is_empty():
				return "steps[%d]: %s" % [i, se]
			continue
		var known := false
		for k in STEP_KINDS:
			if d.has(k):
				known = true
		if not known:
			return "steps[%d] is not a step: each is one of click, type, wait, assert, input, inject, state (help(tool=\"ui_do\"))" % i
	return ""


## "" when the assert is well formed (filling in a default screenshot baseline), else what is wrong, naming it.
func _assert_error(a: Variant, i: int, suite: String) -> String:
	if not (a is Dictionary):
		return "asserts[%d] must be an object {type, ...}" % i
	var d: Dictionary = a
	var type := str(d.get("type", "")).strip_edges().to_lower()
	var at := "asserts[%d] (%s)" % [i, type]
	match type:
		"node_state":
			if str(d.get("target", "")).strip_edges().is_empty() or str(d.get("property", "")).strip_edges().is_empty() or not d.has("equals"):
				return "%s needs target, property and equals" % at
		"expr":
			var cond := str(d.get("condition", "")).strip_edges()
			if cond.is_empty():
				return "%s needs a condition (a GDScript expression on the scene root)" % at
			var ex := Expression.new()
			if ex.parse(cond) != OK:
				return "%s: the condition does not parse: %s" % [at, ex.get_error_text()]
		"screen_text":
			if str(d.get("text", "")).strip_edges().is_empty():
				return "%s needs text" % at
		"screenshot":
			if str(d.get("baseline", "")).strip_edges().is_empty():
				d["baseline"] = "%s/%s_%d.png" % [BASELINE_DIR, suite, i]
			var b := _baseline_path(d)
			var werr := PathGuard.write_path_error(b)
			if not werr.is_empty():
				return "%s: baseline %s: %s" % [at, b.left(160), werr]
			if b.get_extension().to_lower() != "png":
				return "%s: the baseline must be a .png file" % at
			if d.has("threshold") and _num(d["threshold"]) == null:
				return "%s: threshold must be a number (peak SNR in dB)" % at
		"perf":
			var perr := _perf_spec_error(d)
			if not perr.is_empty():
				return "%s: %s" % [at, perr]
		"no_overlap":
			if not ResourceLoader.exists(PHYSICS_OVERLAP_PATH):
				return "%s: the physics overlap oracle (runtime/physics_overlap.gd) is not part of this build, so the assert could never be judged" % at
			var po: Variant = load(PHYSICS_OVERLAP_PATH)
			if po != null:
				var oerr := str(po.call("spec_error", d))
				if not oerr.is_empty():
					return "%s: %s" % [at, oerr]
		_:
			return "asserts[%d]: unknown type '%s' (%s)" % [i, type.left(40), " | ".join(PackedStringArray(ASSERT_TYPES))]
	return ""


static func _perf_spec_error(a: Dictionary) -> String:
	var metric := str(a.get("metric", "")).strip_edges()
	var has_max := a.has("max") and a["max"] != null
	var has_min := a.has("min") and a["min"] != null
	if not has_max and not has_min:
		return "a perf assert on %s needs max and/or min" % metric
	if (has_max and _num(a["max"]) == null) or (has_min and _num(a["min"]) == null):
		return "max and min must be numbers"
	if not PERF_METRICS.has(metric):
		return "unknown perf metric '%s' (known: %s)" % [metric.left(40), ", ".join(PackedStringArray(PERF_METRICS))]
	return ""


func _baseline_path(a: Dictionary) -> String:
	var b := str(a.get("baseline", "")).strip_edges()
	if b.is_empty() or b.contains("://"):
		return b
	return "%s/%s" % [BASELINE_DIR, b if b.get_extension().to_lower() == "png" else b + ".png"]


# ---------------------------------------------------------------- op=list / op=show

func _list() -> Dictionary:
	var found := _suite_names()
	var out: Array = []
	for n in found["names"]:
		var path := "%s/%s.json" % [PLAYTEST_DIR, str(n)]
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not (parsed is Dictionary):
			out.append({"name": n, "error": "not a JSON object"})
			continue
		var d: Dictionary = parsed
		var row := {"name": n, "scene": str(d.get("scene", "")), "mode": _mode_of(d, {}),
			"events": _count(d.get("events")), "steps": _count(d.get("steps")), "asserts": _count(d.get("asserts")),
			"invariants": _count(d.get("invariants")), "schema_version": _int_of(d.get("schema_version", 1), 1),
			"perf_baseline": d.get("perf_baseline") is Dictionary}
		var rep_path := "%s/%s.report.json" % [PLAYTEST_DIR, str(n)]
		if FileAccess.file_exists(rep_path):
			var rep: Variant = JSON.parse_string(FileAccess.get_file_as_string(rep_path))
			if rep is Dictionary:
				row["last_verdict"] = str((rep as Dictionary).get("verdict", ""))
		out.append(row)
	var res := {"dir": PLAYTEST_DIR, "count": out.size(), "playtests": out}
	if not (found["odd"] as Array).is_empty():
		res["note"] = "%d file(s) in %s are not suites op=save could have written (left out): %s" % [(found["odd"] as Array).size(), PLAYTEST_DIR, ", ".join(PackedStringArray(found["odd"]))]
	return {"json": res}


static func _count(v: Variant) -> int:
	return (v as Array).size() if v is Array else 0


func _show(args: Dictionary) -> Dictionary:
	var name := _sanitize(str(args.get("name", "")))
	if name.is_empty():
		return {"error": "op=show needs name (playtest op=list shows the suites)"}
	var doc := _load(name)
	if doc.has("error"):
		return doc
	var out := {"name": name, "path": "%s/%s.json" % [PLAYTEST_DIR, name], "mode": _mode_of(doc, {}), "suite": doc}
	var rep_path := "%s/%s.report.json" % [PLAYTEST_DIR, name]
	if FileAccess.file_exists(rep_path):
		var rep: Variant = JSON.parse_string(FileAccess.get_file_as_string(rep_path))
		if rep is Dictionary:
			out["last_report"] = rep
	return {"json": out}


# ---------------------------------------------------------------- asserts

func _eval_assert(a: Variant, perf: Dictionary = {}, ctx: Dictionary = {}) -> Dictionary:
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
			return _eval_screenshot(d, ctx)
		"perf":
			var headless := false
			if ctx.has("headless"):
				headless = CallArgs.to_bool(ctx["headless"])
			elif _perf_spec_error(d).is_empty() and not perf.is_empty() and _render_metric(str(d.get("metric", ""))):
				headless = _game_is_headless()
			return _eval_perf_assert(d, perf, headless, CallArgs.to_bool(ctx.get("after_restart", false)))
		"no_overlap":
			return _eval_no_overlap(d)
	return {"type": type.left(TYPE_CAP), "status": "skip", "detail": "unknown assert type '%s' (%s): not judged" % [type.left(40), " | ".join(PackedStringArray(ASSERT_TYPES))]}


## A failed command as an assert result: blocked when it never got to judge, fail when the game judged.
static func _cmd_failure(type: String, what: String, err: String) -> Dictionary:
	return {"type": type, "status": "blocked" if is_unjudged(err) else "fail", "detail": ("%s: %s" % [what, err]).left(BREAK_REASON_CAP)}


func _eval_node_state(d: Dictionary) -> Dictionary:
	var target := str(d.get("target", "")).strip_edges()
	var prop := str(d.get("property", "")).strip_edges()
	if target.is_empty() or prop.is_empty() or not d.has("equals"):
		return {"type": "node_state", "status": "fail", "detail": "node_state needs target, property and equals"}
	var r := _cmd({"cmd": "get", "path": target, "prop": prop})
	var subject := "%s.%s" % [target, prop]
	if not _ok(r):
		return _cmd_failure("node_state", subject, _err_of(r, "get"))
	var v: Variant = r.get("value")
	if _values_equal(v, d["equals"]):
		return {"type": "node_state", "status": "pass", "detail": "%s == %s" % [subject, str(v)]}
	return {"type": "node_state", "status": "fail", "detail": ("%s = %s (expected %s)" % [subject, str(v), str(d["equals"])]).left(DETAIL_CAP)}


func _eval_expr(d: Dictionary) -> Dictionary:
	var cond := str(d.get("condition", "")).strip_edges()
	if cond.is_empty():
		return {"type": "expr", "status": "fail", "detail": "expr needs a condition"}
	var r := _cmd({"cmd": "eval", "expr": cond})
	if not _ok(r):
		return _cmd_failure("expr", cond.left(120), _err_of(r, "eval"))
	if CallArgs.to_bool(r.get("value")):
		return {"type": "expr", "status": "pass", "detail": "%s -> true" % cond.left(160)}
	return {"type": "expr", "status": "fail", "detail": ("%s -> false (want true)" % cond.left(160)) + reads_suffix(r)}


func _eval_screen_text(d: Dictionary) -> Dictionary:
	var text := str(d.get("text", ""))
	if text.strip_edges().is_empty():
		return {"type": "screen_text", "status": "fail", "detail": "screen_text needs text"}
	var r := _cmd({"cmd": "find", "text": text})
	if not _ok(r):
		return _cmd_failure("screen_text", "'%s'" % text.left(80), _err_of(r, "find"))
	var nodes: Array = r.get("nodes", []) if r.get("nodes", []) is Array else []
	if nodes.is_empty():
		return {"type": "screen_text", "status": "fail", "detail": "no visible node shows '%s'" % text.left(80)}
	return {"type": "screen_text", "status": "pass", "detail": "'%s' is shown (%d node(s))" % [text.left(80), nodes.size()]}


static func _render_metric(metric: String) -> bool:
	return metric.begins_with("frame_ms_") or metric.begins_with("fps_") or metric == "draw_calls_end"


## A perf bound on the replay window's capture. `after_restart`: the run started from a scene restart, whose
## first frames load and compile; a bound broken there is blocked (not judged), never a flaky fail.
func _eval_perf_assert(a: Dictionary, perf: Dictionary, headless: bool, after_restart: bool = false) -> Dictionary:
	var metric := str(a.get("metric", "")).strip_edges()
	var out := {"type": "perf", "metric": metric}
	var bad := _perf_spec_error(a)
	if not bad.is_empty():
		out["status"] = "fail"
		out["detail"] = bad
		return out
	if perf.is_empty():
		out["status"] = "skip"
		out["detail"] = "no perf capture for this run: perf is measured over a deterministic replay window (events stamped with f); a plain replay or a steps flow has none"
		return out
	if headless and _render_metric(metric):
		out["status"] = "skip"
		out["detail"] = "the game runs on the headless display server, which renders nothing: %s is not measured there (memory metrics still are)" % metric
		return out
	var v: Variant = _num(perf.get(metric, null))
	if v == null:
		out["status"] = "skip"
		out["detail"] = "this capture has no %s" % metric
		return out
	var value: float = v
	out["value"] = value
	var mx: Variant = _num(a.get("max", null))
	var mn: Variant = _num(a.get("min", null))
	var broken := ""
	if mx != null and value > float(mx):
		broken = "perf %s = %.2f over max %.2f" % [metric, value, float(mx)]
	elif mn != null and value < float(mn):
		broken = "perf %s = %.2f under min %.2f" % [metric, value, float(mn)]
	if broken.is_empty():
		out["status"] = "pass"
		if mx != null and mn != null:
			out["detail"] = "perf %s = %.2f within min %.2f and max %.2f" % [metric, value, float(mn), float(mx)]
		elif mx != null:
			out["detail"] = "perf %s = %.2f within max %.2f" % [metric, value, float(mx)]
		else:
			out["detail"] = "perf %s = %.2f within min %.2f" % [metric, value, float(mn)]
		return out
	if after_restart:
		out["status"] = "blocked"
		out["detail"] = broken + " - not judged: this run measures right after a scene restart (loading, shader compiles), so a broken bound here says nothing about the game"
		return out
	out["status"] = "fail"
	out["detail"] = broken
	return out


func _eval_screenshot(a: Dictionary, ctx: Dictionary = {}) -> Dictionary:
	var out := {"type": "screenshot"}
	var baseline := _baseline_path(a)
	if baseline.is_empty():
		out["status"] = "fail"
		out["detail"] = "a screenshot assert needs baseline: a .png path such as %s/<name>.png" % BASELINE_DIR
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
	var threshold := SNR_DEFAULT
	if a.has("threshold") and _num(a["threshold"]) != null:
		threshold = float(_num(a["threshold"]))
	var r := _cmd({"cmd": "screenshot"}, 8000)
	if not _ok(r):
		out["status"] = "blocked"
		out["detail"] = "could not capture the game's frame: %s" % _err_of(r, "screenshot")
		return out
	var bytes := Marshalls.base64_to_raw(str(r.get("data", r.get("png", ""))))
	var img := Image.new()
	if bytes.is_empty() or img.load_png_from_buffer(bytes) != OK:
		out["status"] = "blocked"
		out["detail"] = "the game's frame did not decode as a PNG"
		return out
	var resave := CallArgs.to_bool(ctx.get("save_baseline", false))
	if resave or not FileAccess.file_exists(baseline):
		var dir := baseline.get_base_dir()
		if not DirAccess.dir_exists_absolute(dir):
			DirAccess.make_dir_recursive_absolute(dir)
		var serr := img.save_png(baseline)
		out["status"] = "skip" if serr == OK else "blocked"
		out["detail"] = ("baseline %s: %s; later runs compare against it" % ["re-saved (save_baseline=true)" if resave else "saved (first run)", baseline]) if serr == OK else "could not save the baseline %s: %s" % [baseline, error_string(serr)]
		return out
	var base := Image.new()
	var bbytes := FileAccess.get_file_as_bytes(baseline)
	if bbytes.is_empty() or base.load_png_from_buffer(bbytes) != OK:
		out["status"] = "fail"
		out["detail"] = "the baseline %s is not a readable PNG" % baseline
		return out
	var snr := _peak_snr(base, img)
	out["peak_snr"] = snr if is_finite(snr) else 999.0
	if snr >= threshold:
		out["status"] = "pass"
		out["detail"] = "peak_snr %.1f dB >= %.1f against %s" % [minf(snr, 999.0), threshold, baseline]
		return out
	out["status"] = "fail"
	var detail := "peak_snr %.1f dB < %.1f: the frame differs from %s" % [snr, threshold, baseline]
	var actual := baseline.get_basename() + ".actual.png"
	var aerr := PathGuard.write_path_error(actual)
	if not aerr.is_empty():
		detail += "; the actual frame was not written: %s" % aerr
	else:
		var e := img.save_png(actual)
		if e == OK:
			out["actual"] = actual
			detail += "; actual: %s" % actual
		else:
			detail += "; the actual frame was not written: %s" % error_string(e)
	out["detail"] = detail
	return out


## Peak SNR (dB) of `cur` against `base`, compared at the baseline's size.
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


func _eval_no_overlap(d: Dictionary) -> Dictionary:
	var out := {"type": "no_overlap"}
	if not ResourceLoader.exists(PHYSICS_OVERLAP_PATH):
		out["status"] = "fail"
		out["detail"] = "the physics overlap oracle (runtime/physics_overlap.gd) is not part of this build, so no_overlap cannot be judged"
		return out
	var po: Variant = load(PHYSICS_OVERLAP_PATH)
	if po == null:
		out["status"] = "fail"
		out["detail"] = "runtime/physics_overlap.gd failed to load"
		return out
	var bad := str(po.call("spec_error", d))
	if not bad.is_empty():
		out["status"] = "fail"
		out["detail"] = bad
		return out
	var cmd := {"cmd": "physics_overlap"}
	for k in OVERLAP_KEYS:
		if d.has(k):
			cmd[k] = d[k]
	var r := _cmd(cmd, 8000)
	if not _ok(r):
		var err := _err_of(r, "physics_overlap")
		if err.contains("unknown cmd"):
			out["status"] = "blocked"
			out["detail"] = "the game's runtime predates the physics_overlap command: update the addon the game runs"
			return out
		if is_unjudged(err) or is_channel_error(err):
			out["status"] = "blocked"
			out["detail"] = "physics_overlap: %s" % err
			return out
	var j: Variant = po.call("judge", r)
	if j is Dictionary:
		out.merge(j, true)
		out["type"] = "no_overlap"
	else:
		out["status"] = "fail"
		out["detail"] = "the overlap oracle gave no judgement"
	return out


# ---------------------------------------------------------------- fingerprint

## The game's half of the fingerprint ({} when it cannot say: no game, or a runtime that predates the command).
func _game_side() -> Dictionary:
	var r := _cmd({"cmd": "fingerprint"}, 2000)
	return r if _ok(r) else {}


func _fingerprint(doc: Dictionary) -> Dictionary:
	return _fingerprint_from(_game_side(), doc)


static func _fingerprint_from(side: Dictionary, doc: Dictionary) -> Dictionary:
	var out := {
		"os": OS.get_name(),
		"cpu": OS.get_processor_name(),
		"engine": str(Engine.get_version_info().get("string", "")),
		"rendering_method": str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
		"viewport": "%dx%d" % [int(ProjectSettings.get_setting("display/window/size/viewport_width", 0)), int(ProjectSettings.get_setting("display/window/size/viewport_height", 0))],
		"suite": suite_hash(doc),
	}
	for k in ["gpu", "gpu_vendor", "display", "rendering_driver", "build"]:
		if side.has(k) and side[k] != null:
			out[k] = str(side[k])
	return out


func _game_is_headless() -> bool:
	return str(_game_side().get("display", "")).to_lower() == "headless"


func _perf_diff(base: Dictionary, now: Dictionary) -> Dictionary:
	var out := {}
	for k in base:
		if not now.has(k):
			continue
		var b: Variant = base[k]
		var n: Variant = now[k]
		if not ((b is int or b is float) and (n is int or n is float)):
			continue
		var e := {"base": float(b), "now": float(n), "delta": float(n) - float(b)}
		if float(b) != 0.0:
			e["delta_pct"] = (float(n) - float(b)) / absf(float(b)) * 100.0
		out[k] = e
	return out


# ---------------------------------------------------------------- one run

static func _mode_of(doc: Dictionary, args: Dictionary) -> String:
	if doc.get("steps") is Array and not (doc["steps"] as Array).is_empty():
		return "steps"
	if not CallArgs.flag(args, "deterministic", true):
		return "plain"
	if doc.get("events") is Array:
		for e in doc["events"]:
			if e is Dictionary and (e as Dictionary).has("f"):
				return "deterministic"
	return "plain"


## The wait cap of a steps flow: every step's timeout, 3 s on top, and the stepping time of its inject steps;
## never more than a minute.
func _steps_cap_ms(args: Dictionary, steps: Array) -> int:
	var sto := maxi(100, _int_of(args.get("step_timeout_ms", 5000), 5000))
	return mini(60000, steps.size() * sto + 3000 + _inject_time_ms(steps))


func _inject_time_ms(steps: Array) -> int:
	var tps := _tps()
	var total := 0
	for s in steps:
		if not (s is Dictionary) or not UiDo.is_inject(s):
			continue
		var body: Variant = UiDo.inject_body(s)
		var frames := 1
		if body is Dictionary:
			var f: Variant = (body as Dictionary).get("frames", 1)
			if f is int or f is float:
				frames = int(f)
		total += UiDo.inject_budget_ms(frames, tps, 1.0)
	return total


## Replay or play the suite once on the game as it is, then judge it. {json: R} or {error} when the run
## could not happen at all (a window the game refused, a lost channel, a debugger pause).
## opts: unfreeze_first (op=run: a plain/steps suite needs a running game), after_restart (op=repeat),
## compare_baseline + save_baseline + name (op=run's perf baseline).
func _run_doc(doc: Dictionary, args: Dictionary, opts: Dictionary) -> Dictionary:
	var mode := _mode_of(doc, args)
	var events: Array = doc.get("events", []) if doc.get("events", []) is Array else []
	var steps: Array = doc.get("steps", []) if doc.get("steps", []) is Array else []
	if mode != "steps" and events.is_empty():
		return {"error": "the suite has no events and no steps: nothing to play (re-save it with op=save)"}
	var inv := Invariants.normalize(doc.get("invariants", null))
	if not CallArgs.to_bool(inv.get("ok", false)):
		return {"error": "the suite's invariants do not load: %s" % str(inv.get("error", ""))}
	var rules: Array = inv["items"]
	var settle_given: Variant = args.get("settle_frames", doc.get("settle_frames", null))
	var settle := clampi(_int_of(settle_given, 4), 0, 600)
	var after_restart := CallArgs.to_bool(opts.get("after_restart", false))
	var R := {"name": str(doc.get("name", opts.get("name", ""))), "mode": mode, "deterministic": mode == "deterministic"}
	var perf := {}
	var game_inv: Variant = null
	var stopped := ""
	var step_results: Array = []
	if mode != "deterministic" and CallArgs.to_bool(opts.get("unfreeze_first", false)):
		_cmd({"cmd": "tc_unfreeze"}, 2000)
	if mode == "deterministic":
		var open_cmd := {"cmd": "replay_open", "events": events, "settle_frames": settle}
		if not rules.is_empty():
			open_cmd["invariants"] = rules
		var o := _cmd(open_cmd)
		if not _ok(o):
			return {"error": _fail_text("replay_open", _err_of(o, "replay_open"))}
		var last_f := 0
		for e in events:
			if e is Dictionary:
				last_f = maxi(last_f, _int_of((e as Dictionary).get("f", 0), 0))
		var cap := clampi(int(float(last_f + settle) * 2000.0 / float(_tps())) + 5000, 2000, 300000)
		var w := _poll_status({"cmd": "replay_status"}, func(s: Dictionary) -> bool: return not CallArgs.to_bool(s.get("replaying", true)), cap)
		if w.has("error"):
			return {"error": _fail_text("replay_status", str(w["error"]))}
		var st: Dictionary = (w["reply"] as Dictionary).duplicate()
		st.erase("ok")
		st.erase("_id")
		if w.has("timeout"):
			return {"error": "the replay window was still open after %d ms (%d of %d events injected): the game is not stepping (runtime timeout of the window)" % [cap, _int_of(st.get("injected", 0), 0), _int_of(st.get("total_events", events.size()), events.size())]}
		perf = st.get("perf", {}) if st.get("perf", {}) is Dictionary else {}
		if st.has("invariants"):
			game_inv = st["invariants"]
			st.erase("invariants")
		R["replay"] = st
	elif mode == "plain":
		var dispatched := 0
		var batches := _plain_batches(events)
		var t_prev := -1.0
		for b in batches:
			var t: float = b[0]
			if t_prev >= 0.0 and t > t_prev:
				_hold(mini(int(t - t_prev), 60000))
			t_prev = t
			var r := _cmd({"cmd": "input", "events": b[1]})
			if not _ok(r):
				return {"error": _fail_text("input", _err_of(r, "input"))}
			dispatched += _int_of(r.get("dispatched", 0), 0)
		_hold(int(float(settle) * 1000.0 / float(_tps())))
		_cmd({"cmd": "tc_freeze"}, 2000)
		R["replay"] = {"events": events.size(), "dispatched": dispatched}
	else:
		var sto := maxi(100, _int_of(args.get("step_timeout_ms", doc.get("step_timeout_ms", 5000)), 5000))
		var open_ui := {"cmd": "ui_do_open", "steps": steps, "step_timeout_ms": sto}
		if settle_given != null:
			open_ui["settle_frames"] = settle
		if not rules.is_empty():
			open_ui["invariants"] = rules
		var o2 := _cmd(open_ui)
		if not _ok(o2):
			return {"error": _fail_text("ui_do_open", _err_of(o2, "ui_do_open"))}
		var cap2 := _steps_cap_ms({"step_timeout_ms": sto}, steps)
		var w2 := _poll_status({"cmd": "ui_do_status"}, func(s: Dictionary) -> bool: return CallArgs.to_bool(s.get("done", not CallArgs.to_bool(s.get("active", true)))), cap2)
		if w2.has("error"):
			return {"error": _fail_text("ui_do_status", str(w2["error"]))}
		var st2: Dictionary = w2["reply"]
		if w2.has("timeout"):
			_cmd({"cmd": "ui_do_abort"}, 2000)
		_cmd({"cmd": "tc_freeze"}, 2000)
		var results: Array = st2.get("results", []) if st2.get("results", []) is Array else []
		for k in results.size():
			if results[k] is Dictionary:
				var rr: Dictionary = (results[k] as Dictionary).duplicate()
				rr["status"] = status_of(results[k])
				if not rr.has("step"):
					rr["step"] = k
				step_results.append(rr)
		if w2.has("timeout"):
			step_results.append({"step": _int_of(st2.get("current", step_results.size()), step_results.size()), "op": "flow", "ok": false, "status": "blocked",
				"error": "the flow was still running after %d ms and was aborted" % cap2})
		for sr in step_results:
			if str(sr["status"]) != "pass":
				stopped = "stopped at step %d (%s)" % [_int_of(sr.get("step", 0), 0), str(sr["status"])]
				break
		if stopped.is_empty() and step_results.size() < steps.size():
			stopped = "stopped after %d of %d steps" % [step_results.size(), steps.size()]
		if st2.has("invariants"):
			game_inv = st2["invariants"]
		R["step_results"] = step_results
		R["steps_failed"] = not stopped.is_empty() or CallArgs.to_bool(st2.get("failed", false))
	# The game's own side of the fingerprint, only when something measured is judged or kept.
	var asserts: Array = doc.get("asserts", []) if doc.get("asserts", []) is Array else []
	var save_baseline := CallArgs.to_bool(opts.get("save_baseline", false))
	var compare := CallArgs.to_bool(opts.get("compare_baseline", false))
	var side := {}
	var wants_perf := false
	for a in asserts:
		if a is Dictionary and str((a as Dictionary).get("type", "")).to_lower() == "perf":
			wants_perf = true
	if not perf.is_empty() and (wants_perf or (compare and (save_baseline or doc.get("perf_baseline") is Dictionary))):
		side = _game_side()
	var ctx := {"headless": str(side.get("display", "")).to_lower() == "headless", "after_restart": after_restart, "save_baseline": save_baseline}
	var judged: Array = []
	for i in asserts.size():
		var res: Dictionary
		if not stopped.is_empty():
			res = {"type": str((asserts[i] as Dictionary).get("type", "?")) if asserts[i] is Dictionary else "?", "status": "skip",
				"detail": "not evaluated: the flow %s, so the end state is not the one the suite judges" % stopped}
		else:
			res = _eval_assert(asserts[i], perf, ctx)
		res["i"] = i
		judged.append(res)
	var inv_out: Array = []
	if not rules.is_empty():
		if mode == "plain":
			for rule in rules:
				inv_out.append({"type": "invariant", "name": rule["name"], "expr": rule["expr"], "status": "skip",
					"detail": "not checked: a plain (real-time) replay has no per-frame window to check a rule in; record with frame stamps (record_input) or use a steps suite"})
		elif game_inv is Array and not (game_inv as Array).is_empty():
			for g in game_inv:
				if g is Dictionary:
					var gd: Dictionary = (g as Dictionary).duplicate()
					gd["type"] = "invariant"
					gd["status"] = status_of(g)
					inv_out.append(gd)
		else:
			for rule in rules:
				inv_out.append({"type": "invariant", "name": rule["name"], "expr": rule["expr"], "status": "blocked",
					"detail": "the game reported no result for this rule: its Beckett runtime is older than this editor's (it does not check invariants), so nothing was judged; update the addon the game runs"})
	var units: Array = inv_out + judged
	R["asserts"] = units
	var t := tally_of(units + step_results)
	R["passed"] = t["pass"]
	R["failed"] = t["fail"]
	R["blocked"] = t["blocked"]
	R["skipped"] = t["skip"]
	R["verdict"] = verdict_of(int(t["fail"]), int(t["blocked"]))
	R["ok"] = R["verdict"] == "pass"
	if not perf.is_empty():
		R["perf"] = perf
	var notes: Array = []
	if compare:
		if not perf.is_empty():
			var fp_now := _fingerprint_from(side, doc)
			if save_baseline:
				var pb := perf.duplicate()
				pb["fingerprint"] = fp_now
				var doc2 := doc.duplicate(true)
				doc2["perf_baseline"] = pb
				var serr := _store(_sanitize(str(opts.get("name", doc.get("name", "")))), doc2)
				R["baseline"] = ("saved: this run's perf (%d metrics) is the baseline, with this setup's fingerprint" % perf.size()) if serr.is_empty() else "not saved: %s" % serr
			elif doc.get("perf_baseline") is Dictionary:
				var base: Dictionary = (doc["perf_baseline"] as Dictionary).duplicate()
				var bfp: Variant = base.get("fingerprint", null)
				base.erase("fingerprint")
				R["perf_diff"] = _perf_diff(base, perf)
				var cmp := fingerprint_compare(bfp, fp_now)
				R["perf_baseline_comparable"] = cmp["comparable"]
				R["perf_baseline_mismatch"] = cmp["mismatch"]
				var cn := comparability_note(cmp)
				notes.append(cn if not cn.is_empty() else "perf_diff compares this run with the stored baseline, measured on this same setup")
		elif save_baseline:
			R["baseline"] = "not saved: this run measured no perf (only a deterministic replay window does)"
	if not notes.is_empty():
		R["note"] = " ".join(PackedStringArray(notes))
	return {"json": R}


## Plain events grouped by their recorded time t (ms): [[t, [events]], ...]; events without t go together.
static func _plain_batches(events: Array) -> Array:
	var out: Array = []
	for e in events:
		if not (e is Dictionary):
			continue
		var t: Variant = _num((e as Dictionary).get("t", null))
		var tf: float = float(t) if t != null else 0.0
		if not out.is_empty() and (t == null or is_equal_approx(float(out[out.size() - 1][0]), tf)):
			(out[out.size() - 1][1] as Array).append(e)
		else:
			out.append([tf, [e]])
	return out


# ---------------------------------------------------------------- op=run

func _run(args: Dictionary) -> Dictionary:
	var name := _sanitize(str(args.get("name", "")))
	if name.is_empty():
		return {"error": "op=run needs name: the saved suite to run (playtest op=list shows them)"}
	var doc := _load(name)
	if doc.has("error"):
		return doc
	if not _connected():
		return {"error": NOT_CONNECTED % "run"}
	var save_baseline := CallArgs.flag(args, "save_baseline")
	var rr := _run_doc(doc, args, {"unfreeze_first": true, "compare_baseline": true, "save_baseline": save_baseline, "name": name})
	if rr.has("error"):
		return {"error": str(rr["error"])}
	var R: Dictionary = rr["json"]
	if CallArgs.flag(args, "report"):
		var rep := _report_of(name, R)
		var path := "%s/%s.report.json" % [PLAYTEST_DIR, name]
		var werr := _write_report(path, rep)
		R["report"] = rep
		if werr.is_empty():
			R["report_path"] = path
		else:
			R["report_error"] = werr
	return {"json": R}


func _report_of(name: String, R: Dictionary) -> Dictionary:
	var failures: Array = []
	for u in run_summary(R)["units"]:
		if str(u["status"]) == "fail" or str(u["status"]) == "blocked":
			failures.append(u)
	var rep := {"suite": name, "verdict": R["verdict"], "ok": R["ok"], "mode": R["mode"],
		"totals": {"passed": R["passed"], "failed": R["failed"], "blocked": R["blocked"], "skipped": R["skipped"]},
		"failures": failures, "beckett": _beckett_version(), "at": Time.get_datetime_string_from_system(true)}
	for k in ["perf_baseline_comparable", "perf_baseline_mismatch", "perf_diff"]:
		if R.has(k):
			rep[k] = R[k]
	return rep


# ---------------------------------------------------------------- op=repeat

## Restart the current scene from its file and wait for the fresh one: {ok} or {error}.
func _restart() -> Dictionary:
	var r := _cmd({"cmd": "scene_reload"})
	var old_id := 0
	if _ok(r):
		old_id = _int_of(r.get("old_id", 0), 0)
	elif not CallArgs.to_bool(r.get("pending", false)):
		return {"error": _err_of(r, "scene_reload")}
	var last := {"why": ""}
	var tick := func() -> Dictionary:
		var s := _cmd({"cmd": "scene_state"}, 2000)
		if not _ok(s):
			var e := _err_of(s, "scene_state")
			if is_break(e) or is_disconnect(e) or e.begins_with("game not running"):
				return {"error": e}
			last["why"] = e  # a heavy scene blocks the game while it loads: a timed-out poll is waited out
			return {}
		var id := _int_of(s.get("id", 0), 0)
		if CallArgs.to_bool(s.get("ready", false)) and id != 0 and id != old_id:
			return {"up": true}
		return {}
	var res: Dictionary = MCPJobsScript.poll_until(maxi(1, restart_cap_ms), 20, tick, _pump())
	if res.has("error"):
		return {"error": str(res["error"])}
	if res.has("timeout"):
		var why := str(last["why"])
		return {"error": "the restarted scene did not come back within %d ms%s" % [restart_cap_ms, (" (last answer: %s)" % why.left(200)) if not why.is_empty() else ""]}
	return {"ok": true}


func _repeat(args: Dictionary) -> Dictionary:
	var name := _sanitize(str(args.get("name", "")))
	if name.is_empty():
		return {"error": "op=repeat needs name: the saved suite to run (playtest op=list shows them)"}
	var doc := _load(name)
	if doc.has("error"):
		return doc
	var notes: Array = []
	var n := N_DEFAULT
	if args.get("n") != null:
		var w: Variant = _whole(args["n"])
		if w == null or int(w) < 1:
			return {"error": "n must be a whole number from 1 to %d (got %s)" % [N_MAX, str(args["n"]).left(40)]}
		n = int(w)
		if n > N_MAX:
			notes.append("n=%d capped at %d" % [n, N_MAX])
			n = N_MAX
	var mode := _mode_of(doc, args)
	if mode != "steps" and not (doc.get("events") is Array and not (doc["events"] as Array).is_empty()):
		return {"error": "the suite has no events and no steps: nothing to play (re-save it with op=save)"}
	if not _connected():
		return {"error": NOT_CONNECTED % "repeat"}
	var run_args := args.duplicate()
	for k in ["save_baseline", "report"]:
		if CallArgs.flag(args, k):
			notes.append("%s is ignored by op=repeat (a batch keeps no baseline and writes no report: use op=run %s=true)" % [k, k])
		run_args.erase(k)
	var runs: Array = []
	var run_errors: Array = []
	var aborted := ""
	var truncated := false
	var timeouts_in_row := 0
	var t0 := Time.get_ticks_msec()
	var longest := 0
	for i in range(1, n + 1):
		if i > 1 and (Time.get_ticks_msec() - t0) + longest > repeat_cap_ms:
			truncated = true
			break
		var t_run := Time.get_ticks_msec()
		var rs := _restart()
		if rs.has("error") and i == 1 and is_channel_error(str(rs["error"])) and not is_break(str(rs["error"])):
			rs = _restart()  # one transient timeout on the very first restart is retried
		if rs.has("error"):
			var e := str(rs["error"]).left(BREAK_REASON_CAP)
			if i == 1:
				if is_break(e):
					return {"error": e}
				return {"error": "op=repeat cannot restart the scene between runs: %s. Every run has to start from the same fresh scene, so no run was made. A scene built in code has no file to restart from: stop_scene, play_scene a scene file and repeat, or judge a single run with playtest op=run." % e,
					"suggestion": "get_play_state shows what the game is playing"}
			aborted = "the scene restart before run %d failed, so the batch stops here: %s" % [i, e]
			break
		if mode != "deterministic":
			_cmd({"cmd": "tc_unfreeze"}, 2000)  # the restart leaves the scene frozen; a real-time run needs it running
		var rr := _run_doc(doc, run_args, {"after_restart": true, "name": name})
		if rr.has("error"):
			var e2 := str(rr["error"]).left(BREAK_REASON_CAP)
			runs.append({"verdict": "blocked", "units": [], "reason": e2})
			run_errors.append({"run": i, "error": e2})
			if is_break(e2):
				aborted = "run %d met the game paused in the debugger, so the batch stops here (a pause is never retried): %s" % [i, e2]
				break
			if is_disconnect(e2) or e2.contains("game not running"):
				aborted = "the connection was lost during run %d, so the batch stops here: %s" % [i, e2]
				break
			if is_channel_error(e2):
				timeouts_in_row += 1
				if timeouts_in_row >= 2:
					aborted = "two runs in a row timed out (runs %d and %d): the game stopped answering, so the batch stops here" % [i - 1, i]
					break
			else:
				timeouts_in_row = 0
		else:
			timeouts_in_row = 0
			var R: Dictionary = rr["json"]
			runs.append({"verdict": str(R["verdict"]), "units": run_summary(R)["units"]})
		longest = maxi(longest, Time.get_ticks_msec() - t_run)
	if aborted.is_empty():
		# One more restart, so a following op=run does not start where the last run ended.
		var fin := _restart()
		if fin.has("error"):
			notes.append("the restart that ends the batch failed (%s): the game is where the last run left it" % str(fin["error"]).left(300))
		elif mode != "deterministic":
			_cmd({"cmd": "tc_unfreeze"}, 2000)
	var agg := aggregate(runs)
	var out := {"name": name, "runs": agg["runs"], "requested": n, "passes": agg["passes"], "fails": agg["fails"], "blocked": agg["blocked"],
		"pass_rate": agg["pass_rate"], "verdict": verdict_of(int(agg["fails"]), int(agg["blocked"])), "outcomes": agg["outcomes"],
		"steps": agg["steps"], "flaky_steps": agg["flaky_steps"], "first_divergence": agg["first_divergence"], "mode": mode, "reset": RESET_TEXT}
	out["pass_all"] = not truncated and aborted.is_empty() and int(agg["runs"]) == n and int(agg["passes"]) == n
	if not (agg["flaky_blocked"] as Array).is_empty():
		out["flaky_blocked"] = agg["flaky_blocked"]
	if truncated:
		out["truncated"] = true
		notes.append("stopped after %d of %d runs: the next run would not fit this call's time budget (%d ms), so pass^%d was not shown; call op=repeat again with a smaller n" % [runs.size(), n, repeat_cap_ms, n])
	if not aborted.is_empty():
		out["aborted"] = aborted
	if not run_errors.is_empty():
		out["run_errors"] = run_errors
	if not notes.is_empty():
		out["note"] = "; ".join(PackedStringArray(notes))
	return {"json": out}
