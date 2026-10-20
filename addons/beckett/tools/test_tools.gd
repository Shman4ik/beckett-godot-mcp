@tool
extends RefCounted
class_name BeckettTestTools

## test_run (L5): run the project's own test scripts from the editor, no game needed.
##
## A test script is a GDScript with `@tool` on its first line, usually `extends BeckettTestCase`
## (runtime/mcp_test.gd: NON-aborting assertions that record a failure instead of stopping
## the run, so one call reports every problem). Every method named test_* that takes no
## arguments is a test. The whole thing is synchronous (the zero-sidecar rule): the editor runs
## the tests in-process, one after another, and answers when they are done.
##
## Reads are confined to the project like every other tool: the script and the folder are
## paths the caller names (PathGuard.check_read), and a folder walk does not follow a link
## that leads out of the project (PathGuard.walk_skip; what it left out is listed in
## skipped_links).

var server  # mcp_server node (unused: tests run in the editor process)

const PathGuard := preload("res://addons/beckett/core/path_guard.gd")  # script and path are reads the caller names

const DEFAULT_DIR := "res://tests"
const _SKIP_DIRS := [".godot", ".git", ".import"]
const MAX_SCRIPTS := 200
## Most result rows a reply carries; failures always come first.
const MAX_ROWS := 300
const MAX_FAILURE_LINES := 20


func _register(registry) -> void:
	registry.register({
		"name": "test_run",
		"description": "Run GDScript test scripts in the editor (no game needed) and report every test: passed, failed, why. A test script is a @tool script whose test_* methods use BeckettTestCase's non-aborting assertions. script = one file, path = a folder (or file) searched for test_*.gd / *_test.gd (default res://tests). filter = test name contains. Writing tests and what a script may do: help(tool=\"test_run\").",
		"help": "Test scripts run INSIDE the editor process, so they must start with @tool. The usual shape:\n\n  @tool\n  extends BeckettTestCase\n\n  func test_damage_is_clamped() -> void:\n      var hp := Health.new()\n      hp.hit(500)\n      assert_eq(hp.value, 0, \"hit() clamps at zero\")\n      assert_true(hp.is_dead())\n\nBeckettTestCase (addons/beckett/runtime/mcp_test.gd) records a failure instead of aborting: assert_true, assert_false, assert_eq, assert_ne, assert_null, assert_not_null, assert_almost_eq(a, b, tol), fail(msg). Do NOT use the engine's assert(): a failing one halts the editor's debugger.\n\nWithout the base class a test method may return text, an array of texts or false to report failures; any other return value is a pass.\n\nWhat runs: every method named test_* that takes no arguments, in name order. Optional before_all / before_each / after_each / after_all methods run around them. Tests are synchronous (no await). A script that is not @tool, does not compile, or cannot be instantiated is reported as a script error, not skipped.\n\nArguments:\n  script    res:// path (or absolute path inside the project) of ONE test script\n  path      a folder searched recursively for test_*.gd and *_test.gd, or one script (default res://tests)\n  filter    only tests whose name contains this (case-insensitive)\n\nResult: {ok, scripts, tests, passed, failed, script_errors, results:[{script, test, ok, failures:[...], ms}], skipped_links?}. Failing rows come first; passing rows are kept short when there are many.\n\nLimits: a runtime error INSIDE a test (null call, bad index) is printed to the editor's Output and the test still reads as passed, so assert the things you care about. Tests that need the running game belong in playtest or the assert_* tools, not here.",
		"input_schema": {"type": "object", "properties": {
			"script": {"type": "string", "description": "one test script to run (res:// path or absolute path inside the project)"},
			"path": {"type": "string", "description": "folder searched for test_*.gd / *_test.gd, or one script (default res://tests)"},
			"filter": {"type": "string", "description": "only tests whose name contains this (case-insensitive)"},
		}},
		"handler": Callable(self, "_test_run"),
	})


# ---------------------------------------------------------------- the handler

func _test_run(args: Dictionary) -> Dictionary:
	var scripts: Array = []
	var skipped: Array = []  # links out of the project that the walk left alone
	var notes: Array = []  # outside-read notes, when the owner allowed one
	var memo := {}
	var given := false
	if args.has("script") and str(args["script"]) != "":
		given = true
		var g := PathGuard.check_read(str(args["script"]))
		if g.has("error"):
			return {"error": str(g["error"])}
		if g.has("note"):
			notes.append(g)
		var one := _local(str(args["script"]))
		if not FileAccess.file_exists(one):
			return {"error": "No test script at %s" % one}
		scripts.append(one)
	if args.has("path") and str(args["path"]) != "":
		given = true
		var g2 := PathGuard.check_read(str(args["path"]))
		if g2.has("error"):
			return {"error": str(g2["error"])}
		if g2.has("note"):
			notes.append(g2)
		var where := _local(str(args["path"]))
		if DirAccess.open(where) != null:
			_collect(where, scripts, skipped, memo)
		elif FileAccess.file_exists(where):
			scripts.append(where)
		else:
			return {"error": "No test script or folder at %s" % where}
	if not given:
		if DirAccess.open(DEFAULT_DIR) == null:
			return {"error": "No %s folder to search. Pass script=<one test script> or path=<folder>." % DEFAULT_DIR, "suggestion": "help(tool=\"test_run\") shows how to write a test script"}
		_collect(DEFAULT_DIR, scripts, skipped, memo)
	var uniq: Array = []
	for s in scripts:
		if not uniq.has(s):
			uniq.append(s)
	if uniq.is_empty():
		return {"error": "No test scripts found (files named test_*.gd or *_test.gd).", "suggestion": "help(tool=\"test_run\") shows how to write a test script"}
	if uniq.size() > MAX_SCRIPTS:
		uniq = uniq.slice(0, MAX_SCRIPTS)
	var filter := str(args.get("filter", ""))

	var rows: Array = []
	var tests := 0
	var passed := 0
	var failed := 0
	var script_errors := 0
	for path in uniq:
		var run := _run_script(str(path), filter)
		if run.has("error"):
			script_errors += 1
			rows.append({"script": path, "test": "", "ok": false, "failures": [str(run["error"])]})
			continue
		for t in run["tests"]:
			tests += 1
			if bool(t["ok"]):
				passed += 1
			else:
				failed += 1
			rows.append(t)
	var ok := failed == 0 and script_errors == 0
	var out_rows := _ordered_rows(rows)
	var summary := {
		"ok": ok, "scripts": uniq.size(), "tests": tests, "passed": passed, "failed": failed,
		"script_errors": script_errors, "results": out_rows,
	}
	if out_rows.size() < rows.size():
		summary["results_truncated"] = rows.size() - out_rows.size()
	summary.merge(PathGuard.skipped_note(skipped))
	var reply := {"json": summary, "text": _text(summary, rows)}
	for g3 in notes:
		reply = PathGuard.noted(reply, g3)
	return reply


## A path as the engine knows it: an absolute path inside the project becomes res://.
static func _local(p: String) -> String:
	if p.begins_with("res://") or p.begins_with("user://") or p.begins_with("uid://"):
		return p
	return ProjectSettings.localize_path(p)


static func _is_test_file(name: String) -> bool:
	if name.get_extension().to_lower() != "gd":
		return false
	var base := name.get_basename()
	return base.begins_with("test_") or base.ends_with("_test")


## Every test script below `dir`, left to right, never through a link that leaves the project.
func _collect(dir: String, out: Array, skipped: Array, memo: Dictionary) -> void:
	if out.size() >= MAX_SCRIPTS:
		return
	var da := DirAccess.open(dir)
	if da == null:
		return
	var folders: Array = []
	var files: Array = []
	da.list_dir_begin()
	var e := da.get_next()
	while e != "":
		if e != "." and e != "..":
			if da.current_is_dir():
				if not _SKIP_DIRS.has(e):
					folders.append(e)
			elif _is_test_file(e):
				files.append(e)
		e = da.get_next()
	da.list_dir_end()
	files.sort()
	folders.sort()
	for f in files:
		var full := dir.path_join(str(f))
		if PathGuard.walk_skip(full, memo):
			skipped.append(full)
		else:
			out.append(full)
	for d in folders:
		var sub := dir.path_join(str(d))
		if PathGuard.walk_skip(sub, memo):
			skipped.append(sub)
		else:
			_collect(sub, out, skipped, memo)


# ---------------------------------------------------------------- running one script

## {tests: [row...]} or {error} when the script as a whole could not be run.
func _run_script(path: String, filter: String) -> Dictionary:
	var res: Variant = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
	if not (res is GDScript):
		return {"error": "%s did not load as a GDScript (does it have a parse error? validate_script shows it)" % path}
	var script: GDScript = res
	if not script.can_instantiate():
		return {"error": "%s does not compile, so it cannot run (validate_script shows the error)" % path}
	if not script.is_tool():
		return {"error": "%s is not a @tool script: the editor only runs @tool scripts. Put @tool on its first line." % path}
	var names := _test_names(script, filter)
	var inst: Variant = script.new()
	if inst == null or not (inst is Object):
		return {"error": "%s could not be instantiated (does its _init take arguments?)" % path}
	var obj: Object = inst
	var rows: Array = []
	_call_hook(obj, "before_all")
	for tname in names:
		rows.append(_run_test(obj, path, str(tname)))
	_call_hook(obj, "after_all")
	if not (obj is RefCounted):
		obj.free()
	return {"tests": rows}


## The test_* methods of a script that take no arguments, sorted, filtered by name.
static func _test_names(script: GDScript, filter: String) -> Array:
	var names: Array = []
	for m in script.get_script_method_list():
		var n := str(m.get("name", ""))
		if not n.begins_with("test_"):
			continue
		var needed := (m.get("args", []) as Array).size() - (m.get("default_args", []) as Array).size()
		if needed > 0:
			continue
		if not filter.is_empty() and n.findn(filter) == -1:
			continue
		if not names.has(n):
			names.append(n)
	names.sort()
	return names


static func _call_hook(obj: Object, hook: String) -> void:
	if obj.has_method(hook):
		obj.call(hook)


func _run_test(obj: Object, path: String, tname: String) -> Dictionary:
	if obj.has_method("_mcp_reset"):
		obj.call("_mcp_reset")
	_call_hook(obj, "before_each")
	var t0 := Time.get_ticks_usec()
	var ret: Variant = obj.call(tname)
	var ms := snappedf((Time.get_ticks_usec() - t0) / 1000.0, 0.1)
	_call_hook(obj, "after_each")
	var failures: Array = []
	if obj.has_method("_mcp_get_failures"):
		for f in obj.call("_mcp_get_failures"):
			failures.append(str(f))
	if ret is String and not (ret as String).is_empty():
		failures.append(ret)
	elif ret is bool and not ret:
		failures.append("returned false")
	elif ret is Array:
		for f in (ret as Array):
			failures.append(str(f))
	return {"script": path, "test": tname, "ok": failures.is_empty(), "failures": failures, "ms": ms}


# ---------------------------------------------------------------- the reply

## Failures first (they are what the caller reads); past MAX_ROWS the passing rows are the ones cut.
static func _ordered_rows(rows: Array) -> Array:
	var bad: Array = []
	var good: Array = []
	for r in rows:
		if bool(r["ok"]):
			good.append({"script": r["script"], "test": r["test"], "ok": true, "ms": r["ms"]})
		else:
			bad.append(r)
	var out := bad.duplicate()
	out.append_array(good.slice(0, maxi(0, MAX_ROWS - bad.size())))
	return out


static func _text(summary: Dictionary, rows: Array) -> String:
	var head := "%s test_run: %d test(s) in %d script(s): %d passed, %d failed" % [
		"PASS" if bool(summary["ok"]) else "FAIL", int(summary["tests"]), int(summary["scripts"]), int(summary["passed"]), int(summary["failed"])]
	if int(summary["script_errors"]) > 0:
		head += ", %d script(s) could not run" % int(summary["script_errors"])
	var lines: Array = [head]
	var shown := 0
	for r in rows:
		if bool(r["ok"]):
			continue
		if shown >= MAX_FAILURE_LINES:
			lines.append("... and more failures (see results)")
			break
		shown += 1
		var why := "; ".join(PackedStringArray(r["failures"]))
		if str(r["test"]) == "":
			lines.append("  ERROR %s" % why)  # a script-level failure already names its script
		else:
			lines.append("  FAIL %s::%s: %s" % [str(r["script"]).get_file(), str(r["test"]), why])
	return "\n".join(PackedStringArray(lines))
