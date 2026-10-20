@tool
extends RefCounted
class_name BeckettQaTools

## The VERIFY half of the play-test loop (L5): assertions an agent can make about a game
## without eyeballing a screenshot. Four tools:
##   assert_node_state   a property of a live node in the RUNNING game, with numeric tolerance
##   assert_screen_text  text that is (or is not) visible on the RUNNING game's UI
##   assert_scene        what a .tscn FILE contains, read from disk (the game need not run)
##   compare_screenshots the running game against a baseline image, as a percent difference
##
## An assertion that does not hold is a RESULT ({passed:false, failures:[...]}), not a tool
## error: the call worked, the game did not. A tool error ({error}) means the check could
## not be made at all (game not running, bad arguments, a path outside the project, the
## debugger paused). Every handler is synchronous (the zero-sidecar rule); the optional
## timeout_ms blocks the editor in MCPJobsScript.poll_until, pumping the bridge, until the
## check passes or the time is up.
##
## Guards come first and need no server: Beckett's own objects are off limits, a scene is a
## read the project confines (PathGuard.check_read) and a baseline is a write it confines
## (PathGuard.write_path_error). Everything that reaches the game uses commands the game
## runtime already understands (see runtime/mcp_runtime.gd _dispatch).

var server  # mcp_server node (exposes .bridge)

const Reflect := preload("res://addons/beckett/core/reflection.gd")  # refusal_for: Beckett's own nodes are off limits
const PathGuard := preload("res://addons/beckett/core/path_guard.gd")  # the scene is a read, the baseline a write
const CallArgs := preload("res://addons/beckett/core/callargs.gd")  # flags arrive as text from lenient clients
const MCPJobsScript := preload("res://addons/beckett/core/jobs.gd")  # poll_until for timeout_ms

const NOT_RUNNING := "game not running (no runtime connection). Call play_scene first, then wait_until condition=game_connected."

## Default absolute tolerance of a numeric comparison (JSON floats, vectors printed to 6 digits).
const DEFAULT_TOLERANCE := 0.001
## compare_screenshots: default pass threshold in percent of the maximum possible difference.
const DEFAULT_THRESHOLD_PCT := 1.0
## Both pictures collapse to this many pixels on a side before they are compared.
const COMPARE_SIDE := 64
## The capture the comparison pulls from the game (a quarter of the pixels per side).
const COMPARE_SCALE := 0.25
## A baseline minted by this tool is capped at this long edge, like a bare screenshot.
const MINT_MAX_DIM := 1280
const MAX_WAIT_MS := 30000
const SHOWN_TEXTS := 20


func _register(registry) -> void:
	registry.register({
		"name": "assert_node_state",
		"description": "Assert a property of a node in the RUNNING game: equals, not_equals, min, max, contains, or exists. Same selectors as runtime_get_property (target path, or class/name/text + nth/under). Numbers and vectors compare with tolerance (default 0.001); \"(1, 2)\", [1,2] and Vector2(1,2) agree. A failed assertion is a result with passed:false and the actual value, not a tool error. timeout_ms waits for it to become true. Details: help(tool=\"assert_node_state\").",
		"help": "Reads the property with the game's own 'get' command (so nested paths like position:x or material_override:shader_parameter/tint work) and checks every expectation you gave. All must hold.\n\nTarget: `target` (or `path`) = node path/name in the running game; or a live selector: class (native or class_name), name (contains), text (contains), nth (default 0), under (scope).\n\nExpectations (at least one):\n  equals       value must match. Numbers use tolerance; vectors/colors may be [x,y,z], \"(x, y, z)\" or \"#rrggbb\"; text and bools compare exactly; an object compares by key (every key you give must match).\n  not_equals   the opposite of equals.\n  min / max    numeric bounds (inclusive).\n  contains     text contains the substring, or an array has the element.\n  exists       true/false: the node is (not) in the live tree. With exists=false no property is read.\n  tolerance    absolute tolerance for numbers (default 0.001).\n  timeout_ms   keep re-checking every 50 ms until it holds or this many ms pass (default 0 = check once, max 30000).\n\nResult: {passed, target, resolved, property, actual, expected..., failures:[...]}. When the target does not exist the assertion FAILS (failures says so); it is a tool error only when the game is not running, is paused in the debugger, or the target is one of Beckett's own nodes.\n\nExamples:\n  {target:\"Player\", property:\"health\", equals:100}\n  {class:\"Label\", name:\"Score\", property:\"text\", contains:\"Score: 3\", timeout_ms:2000}\n  {target:\"Player\", property:\"position\", equals:[320, 180], tolerance:2}\n  {target:\"Boss\", exists:false}",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"target": {"type": "string", "description": "node path/name in the running game (or use class/name/text selectors)"},
			"class": {"type": "string", "description": "selector: class (native or class_name)"},
			"name": {"type": "string", "description": "selector: node name contains"},
			"text": {"type": "string", "description": "selector: visible text contains"},
			"nth": {"type": "integer", "description": "selector: which match (default 0)"},
			"under": {"type": "string", "description": "selector: only search below this node"},
			"property": {"type": "string", "description": "property name or nested path (position:x)"},
			"equals": {"description": "expected value (number, text, bool, [x,y], \"#rrggbb\", object)"},
			"not_equals": {"description": "value it must NOT equal"},
			"min": {"type": "number", "description": "numeric lower bound (inclusive)"},
			"max": {"type": "number", "description": "numeric upper bound (inclusive)"},
			"contains": {"description": "substring of a text value, or an element of an array value"},
			"exists": {"type": "boolean", "description": "assert the node is (true) or is not (false) in the live tree"},
			"tolerance": {"type": "number", "description": "absolute tolerance for numbers (default 0.001)"},
			"timeout_ms": {"type": "integer", "description": "re-check until true or this long (default 0, max 30000)"},
		}},
		"handler": Callable(self, "_assert_node_state"),
	})
	registry.register({
		"name": "assert_screen_text",
		"description": "Assert that text is (or, with absent=true, is not) visible on the RUNNING game's UI: case-insensitive contains over every visible Control's text (Label, Button, RichTextLabel, LineEdit...). Reports the matching controls, and on a miss the texts that ARE on screen. exact=true for whole-text equality, count for an exact match count, path to scope to a subtree, timeout_ms to wait. World-space Label3D text is not covered.",
		"help": "Uses the game's ui_snapshot, so only controls visible in the tree count (a hidden panel's label does not). Text matching is case-insensitive.\n\nArguments:\n  text       what to look for (required)\n  exact      true = a control's whole text must equal it (default false = contains)\n  absent     true = assert nobody shows it (the assertion passes when there is no match)\n  count      the match count must be exactly this (default: at least one, or none with absent)\n  path       only look below this node\n  class      only controls whose class contains this (Button, Label...)\n  timeout_ms re-check every 50 ms until it holds or this many ms pass (default 0, max 30000)\n\nResult: {passed, text, match_count, matches:[{path, class, text}], visible_text:[first 20 texts on screen, on a failure]}. A failed assertion is a result with passed:false; it is a tool error only when the game is not running or is paused in the debugger.\n\nFor non-visual state use assert_node_state; to look at the picture use screenshot.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"text": {"type": "string", "description": "text to look for (case-insensitive)"},
			"exact": {"type": "boolean", "description": "whole-text equality instead of contains (default false)"},
			"absent": {"type": "boolean", "description": "assert the text is NOT on screen"},
			"count": {"type": "integer", "description": "exact number of matching controls"},
			"path": {"type": "string", "description": "only look below this node"},
			"class": {"type": "string", "description": "only controls whose class contains this (Button, Label...)"},
			"timeout_ms": {"type": "integer", "description": "re-check until true or this long (default 0, max 30000)"},
		}, "required": ["text"]},
		"handler": Callable(self, "_assert_screen_text"),
	})
	registry.register({
		"name": "assert_scene",
		"description": "Assert what a .tscn contains, read from DISK (not the open or running scene; the game need not run): nodes that exist or must be absent, their type, script, groups, instanced scene and property values, and signal connections. Compact schema: help(tool=\"assert_scene\"). Property numbers compare with tolerance. Reads are confined to the project.",
		"help": "Loads the scene file, instantiates it (never added to a tree, freed afterwards) and checks what you list. Paths are relative to the scene root: \".\" is the root, \"Player/Sprite2D\" a descendant. Instanced sub-scenes are expanded.\n\nArguments:\n  scene        res:// path of the .tscn/.scn (required)\n  nodes        array, each entry a path string or an object:\n                 {path, type?, script?, groups?, instance_of?, properties?, absent?}\n                 type         native class or class_name (inherited classes count)\n                 script       res:// path of the attached script\n                 groups       array of group names the node must be in\n                 instance_of  res:// path of the sub-scene this node instances\n                 properties   {name: expected} (nested a:b allowed; numbers/vectors/colors compare with tolerance)\n                 absent       true = the node must NOT exist\n  connections  array of {from, signal, to, method?}: a persisted connection must exist (paths relative to the root)\n  tolerance    numeric tolerance (default 0.001)\n\nResult: {scene, passed, checked, failures:[...]}. Failures name the node and say what was expected and found.\n\nExample:\n  {scene:\"res://levels/level1.tscn\", nodes:[\"Player\", {path:\"Player/Sprite2D\", type:\"Sprite2D\"}, {path:\"Hud/Score\", properties:{text:\"0\"}}, {path:\"Debug\", absent:true}], connections:[{from:\"Exit\", signal:\"body_entered\", to:\".\", method:\"_on_exit\"}]}\n\nScenes whose scripts are @tool run those scripts' _init while instantiating; a scene that cannot be loaded or instantiated is a tool error.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"scene": {"type": "string", "description": "res:// path of the .tscn/.scn to inspect on disk"},
			"nodes": {"type": "array", "description": "node paths, or {path, type?, script?, groups?, instance_of?, properties?, absent?}"},
			"connections": {"type": "array", "description": "{from, signal, to, method?} connections the scene must persist"},
			"tolerance": {"type": "number", "description": "absolute tolerance for numbers (default 0.001)"},
		}, "required": ["scene"]},
		"handler": Callable(self, "_assert_scene"),
	})
	registry.register({
		"name": "compare_screenshots",
		"description": "Compare the RUNNING game's current frame with a baseline image and report the difference in percent. A baseline that does not exist yet is minted from the current frame (a first run records it); update=true re-mints it. Passes when diff_pct <= threshold (default 1.0). On a fail the current frame comes back so you can see it. baseline is res:// or user://. Metric and baselines: help(tool=\"compare_screenshots\").",
		"help": "Both pictures go through the same chain: the baseline is resized to the size of a quarter-resolution capture of the game (bilinear), then both are resized to 64x64, and diff_pct = 100 * sum(|a - b|) / (bytes * 255) over the RGBA bytes. Identical frames give 0; a fully different frame approaches 100. A character moving a few pixels is a fraction of a percent, a missing sprite or a broken UI a few percent; tune threshold for your game (default 1.0).\n\nArguments:\n  baseline    res:// or user:// path of the PNG/JPG/WebP baseline (required). No '..', no control characters, no link out of the project.\n  threshold   largest passing diff_pct (default 1.0)\n  update      true = overwrite the baseline with the current frame (accepting an intended visual change)\n\nA missing baseline file is minted from the current frame (long edge capped at 1280) and the call passes with minted:true. screenshot save_to=<path> mints one too, at the size you choose.\n\nResult: {passed, diff_pct, threshold, baseline, minted?, updated?, most_changed_cell?:{row, col, of:\"4x4\"}} plus the current frame as an image when it failed. A game that is not running is a tool error.\n\nFreeze or settle the game first (time_control, wait_until) so animation does not read as a regression.",
		"input_schema": {"type": "object", "properties": {
			"baseline": {"type": "string", "description": "res:// or user:// path of the baseline image (minted when missing)"},
			"threshold": {"type": "number", "description": "largest passing difference in percent (default 1.0)"},
			"update": {"type": "boolean", "description": "overwrite the baseline with the current frame"},
		}, "required": ["baseline"]},
		"handler": Callable(self, "_compare_screenshots"),
	})


# ---------------------------------------------------------------- plumbing

func _connected() -> bool:
	return server != null and server.bridge != null and server.bridge.is_game_connected()


## One command to the game: the raw reply when it answered ok, else {error}. A reply the game
## sent with ok:false keeps its words (check with _is_error).
func _send(cmd: Dictionary, timeout_ms: int = 4000) -> Dictionary:
	if not _connected():
		return {"error": NOT_RUNNING}
	var r: Dictionary = server.bridge.send_command(cmd, timeout_ms)
	if not bool(r.get("ok", false)):
		var out := {"error": str(r.get("error", "%s failed" % str(cmd.get("cmd", "command"))))}
		if r.has("suggestion") and str(r["suggestion"]) != "":
			out["suggestion"] = str(r["suggestion"])
		return out
	return r


static func _is_error(r: Dictionary) -> bool:
	return r.has("error")


## A game reply that says the TARGET is not there: for an assertion that is a failed check, not a
## broken tool (everything else the game says, or the channel says, is a tool error).
static func _is_miss(err: String) -> bool:
	return err.contains("not found") or err.contains("no node matches")


## Selector fields from tool args into a game command (target is the path).
static func _add_target(cmd: Dictionary, args: Dictionary) -> void:
	var path := str(args.get("target", args.get("path", "")))
	if not path.is_empty():
		cmd["path"] = path
	for k in ["class", "name", "text", "nth", "under"]:
		if args.has(k):
			cmd[k] = args[k]


static func _has_selector(args: Dictionary) -> bool:
	if not str(args.get("target", args.get("path", ""))).is_empty():
		return true
	for k in ["class", "name", "text"]:
		if not str(args.get(k, "")).is_empty():
			return true
	return false


static func _tolerance(args: Dictionary) -> float:
	return maxf(0.0, float(args.get("tolerance", DEFAULT_TOLERANCE)))


static func _wait_ms(args: Dictionary) -> int:
	return clampi(int(args.get("timeout_ms", 0)), 0, MAX_WAIT_MS)


## A check that is over: it passed, or it could not be made. Anything else is worth another look.
static func _settled(r: Dictionary) -> bool:
	if r.has("error"):
		return true
	var j: Variant = r.get("json")
	return j is Dictionary and bool((j as Dictionary).get("passed", false))


## Run `check` (-> a handler result) once, then again every 50 ms while it fails, up to timeout_ms.
## Stamps waited_ms into the json of a result that had to wait.
func _retry(timeout_ms: int, check: Callable) -> Dictionary:
	var first: Dictionary = check.call()
	if timeout_ms <= 0 or _settled(first) or not _connected():
		return first
	var last := {"r": first}
	var t0 := Time.get_ticks_msec()
	var tick := func() -> Dictionary:
		var r: Dictionary = check.call()
		last["r"] = r
		return {"done": true} if _settled(r) else {}
	MCPJobsScript.poll_until(timeout_ms, 50, tick, Callable(server.bridge, "poll_once"))
	var res: Dictionary = last["r"]
	var j: Variant = res.get("json")
	if j is Dictionary:
		(j as Dictionary)["waited_ms"] = Time.get_ticks_msec() - t0
	return res


## The reply of a check: json for the structure, text for the one line a person reads.
static func _verdict(passed: bool, body: Dictionary, line: String) -> Dictionary:
	var j := {"passed": passed}
	j.merge(body)
	return {"json": j, "text": ("PASS " if passed else "FAIL ") + line}


# ---------------------------------------------------------------- value comparison

## The numbers inside a value, or [] when it is not made of numbers: a number, a vector, a color, a
## rect, an array of those, or text such as "(1, 2)" and "#ff8800" (the form the game answers in).
static func _nums(v: Variant) -> Array:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			return [float(v)]
		TYPE_VECTOR2, TYPE_VECTOR2I:
			var v2: Vector2 = v
			return [v2.x, v2.y]
		TYPE_VECTOR3, TYPE_VECTOR3I:
			var v3: Vector3 = v
			return [v3.x, v3.y, v3.z]
		TYPE_VECTOR4, TYPE_VECTOR4I:
			var v4: Vector4 = v
			return [v4.x, v4.y, v4.z, v4.w]
		TYPE_COLOR:
			var c: Color = v
			return [c.r, c.g, c.b, c.a]
		TYPE_RECT2, TYPE_RECT2I:
			var r: Rect2 = Rect2(v)
			return [r.position.x, r.position.y, r.size.x, r.size.y]
		TYPE_QUATERNION:
			var q: Quaternion = v
			return [q.x, q.y, q.z, q.w]
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_BYTE_ARRAY:
			return _nums(Array(v))
		TYPE_ARRAY:
			var out: Array = []
			for e in (v as Array):
				var inner := _nums(e)
				if inner.size() != 1:
					return []
				out.append(inner[0])
			return out
		TYPE_STRING, TYPE_STRING_NAME:
			return _nums_of_text(str(v))
	return []


static func _nums_of_text(s: String) -> Array:
	var t := s.strip_edges()
	if t.begins_with("#") and Color.html_is_valid(t):
		var c := Color.html(t)
		return [c.r, c.g, c.b, c.a]
	t = t.trim_prefix("(").trim_suffix(")").trim_prefix("[").trim_suffix("]")
	if t.is_empty():
		return []
	var out: Array = []
	for part in t.split(","):
		var p := part.strip_edges()
		if not p.is_valid_float():
			return []
		out.append(p.to_float())
	return out


## "Looks like a vector or list" for text, so "007" and "7" stay different strings.
static func _listy(s: String) -> bool:
	return s.contains(",") or s.begins_with("(") or s.begins_with("[") or s.begins_with("#")


static func _as_bool(v: Variant) -> int:
	if v is bool:
		return 1 if v else 0
	if v is String or v is StringName:
		match str(v).strip_edges().to_lower():
			"true", "1", "yes":
				return 1
			"false", "0", "no":
				return 0
	if v is int or v is float:
		return 1 if float(v) != 0.0 else 0
	return -1


## Does `actual` (a live value, or what the game sent as JSON) match `expected` (what the caller wrote)?
## Numbers, vectors and colors compare within `tol`; an object matches by the keys the caller gave.
static func _values_match(actual: Variant, expected: Variant, tol: float) -> bool:
	if expected == null:
		return actual == null
	if expected is Dictionary:
		if not (actual is Dictionary):
			return false
		for k in (expected as Dictionary):
			if not (actual as Dictionary).has(k) or not _values_match((actual as Dictionary)[k], (expected as Dictionary)[k], tol):
				return false
		return true
	if expected is bool:
		return _as_bool(actual) == (1 if expected else 0)
	if expected is Array and actual is Array and _nums(expected).is_empty():
		var ea: Array = expected
		var aa: Array = actual
		if ea.size() != aa.size():
			return false
		for i in ea.size():
			if not _values_match(aa[i], ea[i], tol):
				return false
		return true
	if (actual is String or actual is StringName) and (expected is String or expected is StringName):
		if str(actual) == str(expected):
			return true
		if not (_listy(str(actual)) and _listy(str(expected))):
			return false
	var en := _nums(expected)
	var an := _nums(actual)
	if not en.is_empty() and en.size() == an.size():
		for i in en.size():
			if absf(float(en[i]) - float(an[i])) > tol:
				return false
		return true
	if expected is String or expected is StringName:
		return str(actual) == str(expected)
	return actual == expected


## What a value looks like in a failure line: short, and never a wall of text.
static func _shown(v: Variant) -> String:
	var s := JSON.stringify(v) if (v is Dictionary or v is Array) else str(v)
	if v is String:
		s = "\"%s\"" % s
	return s if s.length() <= 120 else s.substr(0, 117) + "..."


## A value as JSON can carry it (a node, a vector or a resource becomes its text).
static func _jsonable(v: Variant) -> Variant:
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return v
		TYPE_ARRAY:
			var out: Array = []
			for e in (v as Array):
				out.append(_jsonable(e))
			return out
		TYPE_DICTIONARY:
			var d := {}
			for k in (v as Dictionary):
				d[str(k)] = _jsonable((v as Dictionary)[k])
			return d
	return str(v)


## The failures of one value against the expectations a caller gave (equals, not_equals, min, max,
## contains). Empty = all hold.
static func _expectation_failures(actual: Variant, args: Dictionary, tol: float, subject: String) -> Array:
	var fails: Array = []
	if args.has("equals") and not _values_match(actual, args["equals"], tol):
		fails.append("%s: expected %s, got %s" % [subject, _shown(args["equals"]), _shown(actual)])
	if args.has("not_equals") and _values_match(actual, args["not_equals"], tol):
		fails.append("%s: expected anything but %s" % [subject, _shown(args["not_equals"])])
	if args.has("min") or args.has("max"):
		var n := _nums(actual)
		if n.size() != 1:
			fails.append("%s: min/max need a number, got %s" % [subject, _shown(actual)])
		else:
			var x := float(n[0])
			if args.has("min") and x < float(args["min"]):
				fails.append("%s: expected >= %s, got %s" % [subject, _shown(args["min"]), _shown(actual)])
			if args.has("max") and x > float(args["max"]):
				fails.append("%s: expected <= %s, got %s" % [subject, _shown(args["max"]), _shown(actual)])
	if args.has("contains"):
		var needle: Variant = args["contains"]
		var held := false
		if actual is Array:
			for e in (actual as Array):
				if _values_match(e, needle, tol):
					held = true
					break
		else:
			held = str(actual).contains(str(needle))
		if not held:
			fails.append("%s: expected it to contain %s, got %s" % [subject, _shown(needle), _shown(actual)])
	return fails


# ---------------------------------------------------------------- assert_node_state

func _assert_node_state(args: Dictionary) -> Dictionary:
	var target := str(args.get("target", args.get("path", "")))
	# One of Beckett's own nodes is not a thing to assert about: refuse before anything is sent.
	var off := Reflect.refusal_for(target)
	if not off.is_empty():
		return {"error": off}
	var prop := str(args.get("property", ""))
	var has_exists := args.has("exists") and args["exists"] != null
	if not _has_selector(args):
		return {"error": "name the node: target (path or name), or a selector class / name / text", "suggestion": "help(tool=\"assert_node_state\") shows examples"}
	var has_expect := false
	for k in ["equals", "not_equals", "min", "max", "contains"]:
		if args.has(k):
			has_expect = true
	if not has_expect and not has_exists:
		return {"error": "give an expectation: equals, not_equals, min, max, contains or exists", "suggestion": "to just read a value use runtime_get_property"}
	if has_expect and prop.is_empty():
		return {"error": "equals / not_equals / min / max / contains check a property: give property=\"...\""}
	if not _connected():
		return {"error": NOT_RUNNING}
	return _retry(_wait_ms(args), func() -> Dictionary: return _node_state_once(args, prop, has_exists))


func _node_state_once(args: Dictionary, prop: String, has_exists: bool) -> Dictionary:
	var tol := _tolerance(args)
	var label := str(args.get("target", args.get("path", "")))
	if label.is_empty():
		label = "selector"
	var body := {"target": label}
	var fails: Array = []
	var want_present := true
	if has_exists:
		want_present = CallArgs.to_bool(args["exists"], true)
		var ex := {"cmd": "exists"}
		_add_target(ex, args)
		var er := _send(ex)
		if _is_error(er):
			return er
		var present := bool(er.get("exists", false))
		body["exists"] = present
		if present != want_present:
			fails.append("%s: expected the node to %s, but it %s" % [label, "exist" if want_present else "be absent", "does not exist" if not present else "exists"])
		if not present or not want_present or prop.is_empty():
			return _verdict(fails.is_empty(), _with_fails(body, fails), _line("%s %s" % [label, "exists" if present else "is absent"], fails))
	var get_cmd := {"cmd": "get", "prop": prop}
	_add_target(get_cmd, args)
	var r := _send(get_cmd)
	if _is_error(r):
		if _is_miss(str(r["error"])):
			fails.append("%s: %s" % [label, str(r["error"])])
			return _verdict(false, _with_fails(body, fails), _line(label, fails))
		return r
	var actual: Variant = r.get("value")
	body["property"] = prop
	body["actual"] = _jsonable(actual)
	body["resolved"] = str(r.get("resolved", ""))
	for k in ["equals", "not_equals", "min", "max", "contains"]:
		if args.has(k):
			body["expected_" + k if k != "equals" else "expected"] = args[k]
	fails.append_array(_expectation_failures(actual, args, tol, "%s.%s" % [label, prop]))
	return _verdict(fails.is_empty(), _with_fails(body, fails), _line("%s.%s = %s" % [label, prop, _shown(actual)], fails))


static func _with_fails(body: Dictionary, fails: Array) -> Dictionary:
	var out := body.duplicate()
	out["failures"] = fails
	return out


static func _line(what: String, fails: Array) -> String:
	return what if fails.is_empty() else "%s (%s)" % [what, "; ".join(PackedStringArray(fails))]


# ---------------------------------------------------------------- assert_screen_text

func _assert_screen_text(args: Dictionary) -> Dictionary:
	var query := str(args.get("text", ""))
	if query.is_empty():
		return {"error": "give text=\"...\" (what should be visible)"}
	if not _connected():
		return {"error": NOT_RUNNING}
	return _retry(_wait_ms(args), func() -> Dictionary: return _screen_text_once(args, query))


func _screen_text_once(args: Dictionary, query: String) -> Dictionary:
	var cmd := {"cmd": "ui_snapshot", "max_nodes": 500, "occlusion": false}
	var scope := str(args.get("path", ""))
	if not scope.is_empty():
		cmd["path"] = scope
	var r := _send(cmd, 10000)
	if _is_error(r):
		if _is_miss(str(r["error"])):
			return _verdict(false, {"text": query, "match_count": 0, "matches": [], "failures": [str(r["error"])]}, "%s: %s" % [query, str(r["error"])])
		return r
	var exact := CallArgs.flag(args, "exact", false)
	var absent := CallArgs.flag(args, "absent", false)
	var cls := str(args.get("class", ""))
	var matches: Array = []
	var visible: Array = []
	for c in r.get("controls", []):
		var d: Dictionary = c
		var t := str(d.get("text", ""))
		if t.is_empty():
			continue
		if not cls.is_empty() and str(d.get("class", "")).findn(cls) == -1 and str(d.get("script", "")).findn(cls) == -1:
			continue
		if visible.size() < SHOWN_TEXTS:
			visible.append(t if t.length() <= 80 else t.substr(0, 77) + "...")
		var hit := t.nocasecmp_to(query) == 0 if exact else t.findn(query) != -1
		if hit:
			matches.append({"path": str(d.get("path", "")), "class": str(d.get("class", "")), "text": t if t.length() <= 200 else t.substr(0, 197) + "..."})
	var fails: Array = []
	var n := matches.size()
	if args.has("count") and args["count"] != null:
		if n != int(args["count"]):
			fails.append("expected %d control(s) showing %s, found %d" % [int(args["count"]), _shown(query), n])
	elif absent:
		if n > 0:
			fails.append("expected %s to be absent, but %d control(s) show it" % [_shown(query), n])
	elif n == 0:
		fails.append("%s is not visible on screen" % _shown(query))
	var body := {"text": query, "match_count": n, "matches": matches.slice(0, 10)}
	if not fails.is_empty():
		body["visible_text"] = visible
		if bool(r.get("truncated", false)):
			body["note"] = "the UI snapshot was capped (500 controls); narrow with path="
	var line := "%s %s" % [_shown(query), "absent" if (absent and n == 0) else "visible x%d" % n]
	return _verdict(fails.is_empty(), _with_fails(body, fails), _line(line, fails))


# ---------------------------------------------------------------- assert_scene

func _assert_scene(args: Dictionary) -> Dictionary:
	var scene := str(args.get("scene", ""))
	if scene.is_empty():
		return {"error": "give scene=\"res://path/to/scene.tscn\""}
	var guard := PathGuard.check_read(scene)
	if guard.has("error"):
		return {"error": str(guard["error"])}
	if not ResourceLoader.exists(scene):
		return {"error": "No scene at %s" % scene, "suggestion": "list_dir / search_files find the .tscn files of the project"}
	var res: Variant = ResourceLoader.load(scene, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if not (res is PackedScene) or not (res as PackedScene).can_instantiate():
		return {"error": "%s did not load as a scene that can be instantiated (a missing script or sub-scene?)" % scene}
	var root: Node = (res as PackedScene).instantiate()
	if root == null:
		return {"error": "%s could not be instantiated" % scene}
	var tol := _tolerance(args)
	var fails: Array = []
	var checked := 0
	var nodes: Variant = args.get("nodes", [])
	if nodes is Array:
		for spec in (nodes as Array):
			checked += 1
			_check_scene_node(root, spec, tol, fails)
	var conns: Variant = args.get("connections", [])
	if conns is Array:
		for spec in (conns as Array):
			checked += 1
			_check_connection(root, spec, fails)
	root.free()
	if checked == 0:
		return {"error": "nothing to check: give nodes=[...] and/or connections=[...]", "suggestion": "help(tool=\"assert_scene\") shows the schema"}
	var line := "%s: %d check(s)" % [scene, checked]
	return PathGuard.noted(_verdict(fails.is_empty(), {"scene": scene, "checked": checked, "failures": fails}, _line(line, fails)), guard)


func _check_scene_node(root: Node, spec: Variant, tol: float, fails: Array) -> void:
	var path := ""
	var want := {}
	if spec is Dictionary:
		want = spec
		path = str(want.get("path", ""))
	else:
		path = str(spec)
	if path.is_empty():
		fails.append("a nodes entry has no path")
		return
	var node := root.get_node_or_null(NodePath(path))
	if CallArgs.flag(want, "absent", false):
		if node != null:
			fails.append("%s: should be absent but exists (%s)" % [path, node.get_class()])
		return
	if node == null:
		fails.append("%s: node not found" % path)
		return
	if want.has("type"):
		var tname := str(want["type"])
		if not (node.is_class(tname) or _script_class_of(node) == tname):
			fails.append("%s: expected type %s, got %s" % [path, tname, _script_class_of(node) if _script_class_of(node) != "" else node.get_class()])
	if want.has("script"):
		var sc: Variant = node.get_script()
		var got := (sc as Script).resource_path if sc is Script else ""
		if got != str(want["script"]):
			fails.append("%s: expected script %s, got %s" % [path, str(want["script"]), got if got != "" else "none"])
	if want.has("instance_of") and node.scene_file_path != str(want["instance_of"]):
		fails.append("%s: expected an instance of %s, got %s" % [path, str(want["instance_of"]), node.scene_file_path if node.scene_file_path != "" else "a plain node"])
	var groups: Variant = want.get("groups", [])
	if groups is Array:
		for g in (groups as Array):
			if not node.is_in_group(str(g)):
				fails.append("%s: not in group %s" % [path, str(g)])
	var props: Variant = want.get("properties", {})
	if props is Dictionary:
		for pname in (props as Dictionary):
			var first := str(pname).split(":")[0]
			if not _has_property(node, first):
				fails.append("%s: has no property %s" % [path, first])
				continue
			var actual: Variant = node.get_indexed(NodePath(str(pname)))
			if not _values_match(actual, (props as Dictionary)[pname], tol):
				fails.append("%s.%s: expected %s, got %s" % [path, str(pname), _shown((props as Dictionary)[pname]), _shown(actual)])


static func _has_property(obj: Object, pname: String) -> bool:
	for p in obj.get_property_list():
		if str(p.get("name", "")) == pname:
			return true
	return false


## The class_name of a node's script, "" when it has none (get_global_name is a 4.3 method: reached by name).
static func _script_class_of(node: Node) -> String:
	var sc: Variant = node.get_script()
	if sc is Script and (sc as Script).has_method("get_global_name"):
		return str((sc as Script).call("get_global_name"))
	return ""


func _check_connection(root: Node, spec: Variant, fails: Array) -> void:
	if not (spec is Dictionary):
		fails.append("a connections entry must be {from, signal, to, method?}")
		return
	var d: Dictionary = spec
	var from_path := str(d.get("from", ""))
	var sig := str(d.get("signal", ""))
	var to_path := str(d.get("to", ""))
	var method := str(d.get("method", ""))
	var label := "%s.%s -> %s%s" % [from_path, sig, to_path, "::" + method if method != "" else ""]
	var src := root.get_node_or_null(NodePath(from_path))
	var dst := root.get_node_or_null(NodePath(to_path))
	if src == null or dst == null:
		fails.append("%s: %s not found" % [label, from_path if src == null else to_path])
		return
	if not src.has_signal(sig):
		fails.append("%s: %s has no signal %s" % [label, from_path, sig])
		return
	for c in src.get_signal_connection_list(sig):
		var cb: Callable = c.get("callable", Callable())
		if cb.get_object() == dst and (method.is_empty() or cb.get_method() == method):
			return
	fails.append("%s: no such connection" % label)


# ---------------------------------------------------------------- compare_screenshots

func _compare_screenshots(args: Dictionary) -> Dictionary:
	var baseline := str(args.get("baseline", ""))
	var werr := PathGuard.write_path_error(baseline)
	if not werr.is_empty():
		return {"error": "baseline %s: %s" % [baseline if baseline != "" else "is empty", werr], "suggestion": "give baseline=\"res://tests/baselines/name.png\" (res:// or user://)"}
	if not _connected():
		return {"error": NOT_RUNNING}
	var threshold := maxf(0.0, float(args.get("threshold", DEFAULT_THRESHOLD_PCT)))
	var update := CallArgs.flag(args, "update", false)
	if update or not FileAccess.file_exists(baseline):
		var minted := _mint(baseline)
		if _is_error(minted):
			return minted
		var verb := "minted" if bool(minted.get("created", false)) else "updated"
		var body := {"diff_pct": 0.0, "threshold": threshold, "baseline": baseline, verb: true}
		return _verdict(true, body, "baseline %s %s from the current frame" % [baseline, verb])
	var shot := _send({"cmd": "screenshot", "scale": COMPARE_SCALE}, 10000)
	if _is_error(shot):
		return shot
	var cur := _decode(str(shot.get("data", shot.get("png", ""))), str(shot.get("mime", "image/png")))
	if cur == null:
		return {"error": "the game's frame could not be decoded"}
	var base := _load_image(baseline)
	if base == null:
		return {"error": "the baseline %s is not a readable PNG/JPG/WebP image" % baseline, "suggestion": "update=true replaces it with the current frame"}
	var a := _small(base, cur.get_width(), cur.get_height())
	var b := _small(cur, 0, 0)
	var diff := _diff_pct(a, b)
	var passed := diff <= threshold
	var out := _verdict(passed, {"diff_pct": snappedf(diff, 0.0001), "threshold": threshold, "baseline": baseline}, "%s differs from the current frame by %.4f%% (threshold %.2f%%)" % [baseline, diff, threshold])
	if not passed:
		var cell := _most_changed_cell(a, b)
		(out["json"] as Dictionary)["most_changed_cell"] = {"row": cell.y, "col": cell.x, "of": "4x4"}
		out["image_base64"] = Marshalls.raw_to_base64(cur.save_png_to_buffer())
		out["image_mime"] = "image/png"
	return out


## Capture the current frame at a size worth keeping and write it to `baseline`.
func _mint(baseline: String) -> Dictionary:
	var full := _send({"cmd": "screenshot", "max_dim": MINT_MAX_DIM}, 10000)
	if _is_error(full):
		return full
	var b64 := str(full.get("data", full.get("png", "")))
	if b64.is_empty():
		return {"error": "the game sent no image data, so no baseline was written"}
	var existed := FileAccess.file_exists(baseline)
	var dir := baseline.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		var derr := DirAccess.make_dir_recursive_absolute(dir)
		if derr != OK:
			return {"error": "cannot create %s: %s" % [dir, error_string(derr)]}
	var f := FileAccess.open(baseline, FileAccess.WRITE)
	if f == null:
		return {"error": "cannot write %s: %s" % [baseline, error_string(FileAccess.get_open_error())]}
	f.store_buffer(Marshalls.base64_to_raw(b64))
	f.close()
	return {"created": not existed}


static func _decode(b64: String, mime: String) -> Image:
	if b64.is_empty():
		return null
	var bytes := Marshalls.base64_to_raw(b64)
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if mime.contains("jpeg") or mime.contains("jpg"):
		err = img.load_jpg_from_buffer(bytes)
	elif mime.contains("webp"):
		err = img.load_webp_from_buffer(bytes)
	else:
		err = img.load_png_from_buffer(bytes)
	if err != OK or img.is_empty():
		return null
	img.convert(Image.FORMAT_RGBA8)
	return img


static func _load_image(path: String) -> Image:
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	var ext := path.get_extension().to_lower()
	var err := ERR_FILE_UNRECOGNIZED
	if ext == "jpg" or ext == "jpeg":
		err = img.load_jpg_from_buffer(bytes)
	elif ext == "webp":
		err = img.load_webp_from_buffer(bytes)
	else:
		err = img.load_png_from_buffer(bytes)
	if err != OK or img.is_empty():
		return null
	img.convert(Image.FORMAT_RGBA8)
	return img


## `img` reduced to COMPARE_SIDE x COMPARE_SIDE. The baseline first travels to the size of the
## capture (`via_w` x `via_h`, bilinear) and only then collapses, because Godot's bilinear resize does
## not pre-filter: a one-step and a two-step downscale of one picture sample different pixels, and a
## baseline taken at full size would not match a quarter-size frame. The capture itself passes 0 x 0.
static func _small(img: Image, via_w: int, via_h: int) -> Image:
	var out := img.duplicate() as Image
	if via_w > 0 and via_h > 0:
		out.resize(via_w, via_h, Image.INTERPOLATE_BILINEAR)
	out.resize(COMPARE_SIDE, COMPARE_SIDE)
	return out


## Percent of the largest possible byte difference between two same-size pictures.
static func _diff_pct(a: Image, b: Image) -> float:
	var ad := a.get_data()
	var bd := b.get_data()
	var n := mini(ad.size(), bd.size())
	if n == 0:
		return 100.0
	var d := 0
	for i in n:
		d += abs(int(ad[i]) - int(bd[i]))
	return 100.0 * float(d) / float(n * 255)


## Which cell of a 4x4 grid (x = column, y = row, from the top left) differs the most.
static func _most_changed_cell(a: Image, b: Image) -> Vector2i:
	var cell := int(COMPARE_SIDE / 4.0)
	var best := Vector2i.ZERO
	var best_sum := -1
	for cy in 4:
		for cx in 4:
			var s := 0
			for y in range(cy * cell, (cy + 1) * cell):
				for x in range(cx * cell, (cx + 1) * cell):
					var pa := a.get_pixel(x, y)
					var pb := b.get_pixel(x, y)
					s += int(absf(pa.r - pb.r) * 255.0) + int(absf(pa.g - pb.g) * 255.0) + int(absf(pa.b - pb.b) * 255.0)
			if s > best_sum:
				best_sum = s
				best = Vector2i(cx, cy)
	return best
