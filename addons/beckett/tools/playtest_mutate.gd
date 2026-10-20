@tool
extends RefCounted

## playtest op=mutate, the planner half (Full, v1.16): which faults a suite should notice.
##
## A suite that passes says the game did what it checks. It does not say the checks would notice the game
## doing something else. op=mutate answers that: it reads what the suite looks at (the nodes and properties
## its asserts, rules and steps name), plans small faults on exactly those (a number zeroed, negated or set
## to 1, a bool flipped, a node's processing disabled, the scene's declared signal connection cut), and the
## handler (playtest_tools._mutate) runs the suite once per fault from a scene restart. A fault the suite
## fails or blocks on is killed; one it still passes on survived: no assertion notices that change.
##
## Everything here is pure (no game, no editor state), so the unit suite pins it. The handler does the
## commands: `get` for the values a fault starts from, `set` to write it in (the same command the inject
## step uses) and back, and `eval` of connected_expr / disconnect_expr for the connection.

const Invariants := preload("res://addons/beckett/runtime/invariants.gd")  # operands_of: where a condition reads
const UiDo := preload("res://addons/beckett/runtime/ui_do.gd")  # inject/state step shapes
const CallArgs := preload("res://addons/beckett/core/callargs.gd")  # a bool read back from a suite may be text

## The longest survivor hint (a node path comes from a suite file and can be any length).
const HINT_MAX := 240
## The units one fault lists as reading its target.
const MAX_READS := 8
## A condition longer than this is not read for targets: it is not the plain comparison a fault is planned from.
const REFS_MAX_LEN := 1000
## The runtime's own nodes (the autoload and the node it adds), by last name, lower case. A fault there would
## break the channel the run is judged through, so they are never a target, however the path is spelled.
const RUNTIME_NAMES := ["beckettruntime", "beckettruntimeimpl", "beckett"]
const PROCESS_MODE_DISABLED := 4
const PROCESS_MODE_NAMES := ["inherit", "pausable", "when_paused", "always", "disabled"]
const KEYWORDS := ["true", "false", "null", "self", "and", "or", "not", "in"]

static var _re_node: RegEx
static var _re_chain: RegEx
static var _re_call_tail: RegEx
static var _re_bare: RegEx


# ---------------------------------------------------------------- reading a suite

## The plain reads of a condition: [{node, property}], one per operand of its comparisons that is a node
## lookup (get_node / get_node_or_null with a literal path, then an optional property chain) or a bare name
## (a property of the scene root, node "."). A chain a.b becomes the property path a:b; a method call on
## a node names the node only (property ""). Arithmetic, constants and literals read nothing.
static func refs_in(expr: String) -> Array:
	var src := expr.strip_edges()
	if src.is_empty() or src.length() > REFS_MAX_LEN:
		return []
	_compile()
	var out: Array = []
	for operand in Invariants.operands_of(src):
		var r := _ref_of(str(operand))
		if not r.is_empty():
			out.append(r)
	return out


static func _compile() -> void:
	if _re_node != null:
		return
	_re_node = RegEx.create_from_string("^get_node(?:_or_null)?\\(\\s*(?:'([^'\\\\]*)'|\"([^\"\\\\]*)\")\\s*\\)(.*)$")
	_re_chain = RegEx.create_from_string("^(?:\\.[A-Za-z_][A-Za-z0-9_]*)+$")
	_re_call_tail = RegEx.create_from_string("^(?:\\.[A-Za-z_][A-Za-z0-9_]*)*\\.[A-Za-z_][A-Za-z0-9_]*\\s*\\([^()]*\\)$")
	_re_bare = RegEx.create_from_string("^[a-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*$")


static func _ref_of(operand: String) -> Dictionary:
	var s := operand.strip_edges()
	var m := _re_node.search(s)
	if m != null:
		var node := m.get_string(1) if not m.get_string(1).is_empty() else m.get_string(2)
		var rest := m.get_string(3).strip_edges()
		if rest.is_empty() or _re_call_tail.search(rest) != null:
			return {"node": node, "property": ""}
		if _re_chain.search(rest) != null:
			return {"node": node, "property": rest.substr(1).replace(".", ":")}
		return {}
	if _re_bare.search(s) != null:
		var parts := s.split(".")
		if KEYWORDS.has(parts[0]):
			return {}
		return {"node": ".", "property": ":".join(parts)}
	return {}


## What a suite looks at: {props: [{node, property, reads}], nodes: [{node, reads}]}, each in the order the
## suite first names it, `reads` the ids its run reports them under (asserts[i], invariant:<name>, steps[i]).
## An inject names its target nodes but not the properties it writes (the step would overwrite a fault there);
## a state step names its node (its keys are not properties). The scene root is never a node target (disabling
## it freezes everything), and neither is the runtime's own node.
static func targets_of(doc: Variant) -> Dictionary:
	var acc := {"props": [], "nodes": [], "pi": {}, "ni": {}}
	var d: Dictionary = doc if doc is Dictionary else {}
	var asserts: Array = d.get("asserts", []) if d.get("asserts", []) is Array else []
	for i in asserts.size():
		var a: Variant = asserts[i]
		if not (a is Dictionary):
			continue
		var unit := "asserts[%d]" % i
		match str((a as Dictionary).get("type", "")).strip_edges().to_lower():
			"node_state":
				_note(acc, str((a as Dictionary).get("target", "")), str((a as Dictionary).get("property", "")), unit)
			"expr":
				_note_expr(acc, str((a as Dictionary).get("condition", "")), unit)
	var invs: Array = d.get("invariants", []) if d.get("invariants", []) is Array else []
	for i in invs.size():
		var r: Variant = invs[i]
		if not (r is Dictionary):
			continue
		var nm := str((r as Dictionary).get("name", "")).strip_edges()
		if nm.is_empty():
			nm = "inv%d" % (i + 1)
		_note_expr(acc, str((r as Dictionary).get("expr", "")), "invariant:%s" % nm)
	var steps: Array = d.get("steps", []) if d.get("steps", []) is Array else []
	for i in steps.size():
		var s: Variant = steps[i]
		if not (s is Dictionary):
			continue
		var unit := "steps[%d]" % i
		var sd: Dictionary = s
		if UiDo.is_inject(sd):
			var body: Variant = UiDo.inject_body(sd)
			if body is Dictionary:
				for k in ["set", "call"]:
					var list: Variant = (body as Dictionary).get(k, [])
					if list is Array:
						for e in list:
							if e is Dictionary:
								_note(acc, str((e as Dictionary).get("node", "")), "", unit)
			continue
		if UiDo.is_state(sd):
			var sb: Variant = UiDo.state_body(sd)
			if sb is Dictionary:
				_note(acc, str((sb as Dictionary).get("node", "")), "", unit)
			continue
		for k in ["assert", "wait"]:
			var b: Variant = sd.get(k, null)
			if not (b is Dictionary):
				continue
			var bd: Dictionary = b
			if bd.has("node"):
				_note(acc, str(bd["node"]), str(bd.get("property", "")) if k == "assert" else "", unit)
			for ck in ["condition", "expr"]:
				if bd.has(ck):
					_note_expr(acc, str(bd[ck]), unit)
	return {"props": acc["props"], "nodes": acc["nodes"]}


static func _note_expr(acc: Dictionary, expr: String, unit: String) -> void:
	for r in refs_in(expr):
		_note(acc, str(r["node"]), str(r["property"]), unit)


static func _note(acc: Dictionary, node: String, property: String, unit: String) -> void:
	var n := node.strip_edges()
	var p := property.strip_edges()
	if n.is_empty():
		n = "."
	if is_runtime_path(n):
		return
	if not p.is_empty():
		var key := "%s|%s" % [n, p]
		if not (acc["pi"] as Dictionary).has(key):
			var e := {"node": n, "property": p, "reads": []}
			(acc["props"] as Array).append(e)
			acc["pi"][key] = e
		_add_read(acc["pi"][key], unit)
	if is_root(n):
		return
	if not (acc["ni"] as Dictionary).has(n):
		var ne := {"node": n, "reads": []}
		(acc["nodes"] as Array).append(ne)
		acc["ni"][n] = ne
	_add_read(acc["ni"][n], unit)


static func _add_read(entry: Dictionary, unit: String) -> void:
	if not (entry["reads"] as Array).has(unit):
		(entry["reads"] as Array).append(unit)


## The scene root (the base every path of a suite is resolved from).
static func is_root(node: String) -> bool:
	var n := node.strip_edges()
	return n.is_empty() or n == "." or n == "./"


## Does this path name the runtime's own node (or its child)? Judged by the last name, so every spelling counts:
## absolute or relative, with '.' / '..' / a trailing slash, any case, a :property suffix.
static func is_runtime_path(path: String) -> bool:
	var p := path.strip_edges()
	var colon := p.find(":")
	if colon >= 0:
		p = p.substr(0, colon)
	var last := ""
	for seg in p.to_lower().split("/"):
		if seg.is_empty() or seg == ".":
			continue
		last = seg
	return RUNTIME_NAMES.has(last)


# ---------------------------------------------------------------- the faults

## The faults a value has: a bool is flipped, a number zeroed and negated, a 0 set to 1. Anything else (text,
## null, arrays, NaN, inf) has none.
static func operators_for(v: Variant) -> Array:
	if v is bool:
		return ["flip"]
	if v is int or v is float:
		if not is_finite(float(v)):
			return []
		return ["one"] if float(v) == 0.0 else ["zero", "negate"]
	return []


static func mutated(op: String, v: Variant) -> Variant:
	match op:
		"flip":
			return not CallArgs.to_bool(v)
		"zero":
			return 0
		"one":
			return 1
		"negate":
			return -v if (v is int or v is float) else v
	return v


## A value the way a person writes it: 3 not 3.0, 61.25, true.
static func fmt(v: Variant) -> String:
	if v is bool:
		return "true" if v else "false"
	if v is float and is_finite(v) and v == floorf(v) and absf(v) < 1e15:
		return str(int(v))
	return str(v)


## A node path as a fault names it: the scene root is "root".
static func label(node: String) -> String:
	return "root" if is_root(node) else node.strip_edges()


static func prop_label(node: String, property: String) -> String:
	return "%s.%s" % [label(node), property]


static func connection_label(c: Dictionary) -> String:
	return "%s.%s -> %s.%s" % [label(str(c.get("source", ""))), str(c.get("signal", "")), label(str(c.get("target", ""))), str(c.get("method", ""))]


## The faults, breadth first: the first fault of every property, then every node's disable, then the cut
## connection, then the second fault of every property. cands = {props: [{node, property, reads, value}],
## nodes: [{node, reads, process_mode}], connection: {source, signal, target, method, reads} | {}}.
## Each fault: {id, kind (set | disable | disconnect), target, operator, change, to, reads, ...}.
static func plan(cands: Dictionary) -> Array:
	var out: Array = []
	var props: Array = cands.get("props", []) if cands.get("props", []) is Array else []
	var nodes: Array = cands.get("nodes", []) if cands.get("nodes", []) is Array else []
	var conn: Dictionary = cands.get("connection", {}) if cands.get("connection", {}) is Dictionary else {}
	var ops: Array = []
	var rounds := 0
	for p in props:
		var o := operators_for((p as Dictionary).get("value", null)) if p is Dictionary else []
		ops.append(o)
		rounds = maxi(rounds, o.size())
	for r in maxi(rounds, 1):
		for i in props.size():
			if r < (ops[i] as Array).size():
				out.append(_prop_fault(props[i], str(ops[i][r])))
		if r > 0:
			continue
		for n in nodes:
			if not (n is Dictionary):
				continue
			var pm := _pm_of((n as Dictionary).get("process_mode", 0))
			if pm == PROCESS_MODE_DISABLED:
				continue
			out.append({"kind": "disable", "operator": "disable", "node": str(n["node"]), "property": "process_mode",
				"target": label(str(n["node"])), "from": pm, "to": PROCESS_MODE_DISABLED,
				"change": "process_mode %s -> disabled" % PROCESS_MODE_NAMES[pm], "reads": _reads(n)})
		if not str(conn.get("source", "")).is_empty() and not str(conn.get("signal", "")).is_empty():
			out.append({"kind": "disconnect", "operator": "disconnect", "target": connection_label(conn), "connection": conn,
				"change": "connected -> cut", "reads": _reads(conn)})
	for i in out.size():
		out[i]["id"] = i
	return out


static func _prop_fault(p: Dictionary, op: String) -> Dictionary:
	var v: Variant = p.get("value", null)
	var to: Variant = mutated(op, v)
	return {"kind": "set", "operator": op, "node": str(p["node"]), "property": str(p["property"]),
		"target": prop_label(str(p["node"]), str(p["property"])), "from": v, "to": to,
		"change": "%s -> %s" % [fmt(v), fmt(to)], "reads": _reads(p)}


static func _reads(d: Dictionary) -> Array:
	var r: Variant = d.get("reads", [])
	return (r as Array).slice(0, MAX_READS) if r is Array else []


static func _pm_of(v: Variant) -> int:
	if v is int or v is float:
		return clampi(int(v), 0, PROCESS_MODE_NAMES.size() - 1)
	return 0


# ---------------------------------------------------------------- outcomes

## What a survivor says: the change no assertion noticed, and (at most three of) the units that read it.
static func hint_of(f: Dictionary) -> String:
	var target := str(f.get("target", ""))
	var text: String
	match str(f.get("operator", "")):
		"disable":
			text = "no assertion notices %s being disabled" % target
		"disconnect":
			text = "no assertion notices %s being cut" % target
		_:
			text = "no assertion notices %s = %s" % [target, fmt(f.get("to", null))]
	var reads: Array = f.get("reads", []) if f.get("reads", []) is Array else []
	if not reads.is_empty():
		var shown := PackedStringArray()
		for r in reads.slice(0, 3):
			shown.append(str(r))
		text += " (read by %s%s)" % [", ".join(shown), ", ..." if reads.size() > 3 else ""]
	return text.left(HINT_MAX)


## killed / (killed + survived), 4 decimals; null when nothing was judged.
static func score_of(killed: int, survived: int) -> Variant:
	var judged := killed + survived
	if judged <= 0:
		return null
	return float(roundi(float(killed) / float(judged) * 10000.0)) / 10000.0


## "id: detail" of the unit that did not pass (fail or blocked): one that reads the faulted value when there
## is one (a run a frame off fails a position assert whatever was faulted), else the first. "" when all passed.
static func first_problem(units: Array, prefer_ids: Array = []) -> String:
	var first: Variant = null
	for u in units:
		if not (u is Dictionary):
			continue
		var s := str((u as Dictionary).get("status", ""))
		if s != "fail" and s != "blocked":
			continue
		if prefer_ids.has(str((u as Dictionary).get("id", ""))):
			return _problem_text(u)
		if first == null:
			first = u
	return _problem_text(first) if first != null else ""


static func _problem_text(u: Dictionary) -> String:
	return "%s: %s" % [str(u.get("id", "")), str(u.get("detail", ""))]


## killed (the suite failed or was blocked with the fault in), survived (it passed), or inconclusive (the run
## ended before anything was judged: it says nothing about the suite).
static func outcome_of(run: Dictionary) -> String:
	var v := str(run.get("verdict", "blocked"))
	var units: Variant = run.get("units", [])
	if v != "pass" and (not (units is Array) or (units as Array).is_empty()):
		return "inconclusive"
	return "survived" if v == "pass" else "killed"


# ---------------------------------------------------------------- the declared connection

## The scene file's first declared signal connection that can be matched at runtime (no binds, no unbinds),
## preferring one on a node the suite names: {source, signal, target, method, reads} (paths relative to the
## scene root), or {} for no scene, a missing one or one outside the project.
static func connection_of(scene_path: String, preferred_nodes: Array) -> Dictionary:
	var p := scene_path.strip_edges()
	if p.is_empty() or p.contains("..") or not (p.begins_with("res://") or p.begins_with("user://")):
		return {}
	if not (ResourceLoader.exists(p) or FileAccess.file_exists(p)):
		return {}
	var packed := ResourceLoader.load(p, "PackedScene") as PackedScene
	if packed == null:
		return {}
	var st := packed.get_state()
	var first := {}
	for i in st.get_connection_count():
		if not st.get_connection_binds(i).is_empty():
			continue
		if st.has_method("get_connection_unbinds") and int(st.call("get_connection_unbinds", i)) != 0:
			continue
		var c := {"source": str(st.get_connection_source(i)), "signal": str(st.get_connection_signal(i)),
			"target": str(st.get_connection_target(i)), "method": str(st.get_connection_method(i)), "reads": []}
		if is_runtime_path(str(c["source"])) or is_runtime_path(str(c["target"])):
			continue
		for n in preferred_nodes:
			if n is Dictionary and (_same_node(str((n as Dictionary).get("node", "")), str(c["source"])) or _same_node(str((n as Dictionary).get("node", "")), str(c["target"]))):
				c["reads"] = _reads(n)
				return c
		if first.is_empty():
			first = c
	return first


static func _same_node(named: String, scene_rel: String) -> bool:
	var a := named.strip_edges().trim_suffix("/")
	var b := scene_rel.strip_edges().trim_suffix("/")
	if a.is_empty() or is_root(a) or is_root(b):
		return false
	return a == b or a.get_file() == b.get_file()


## An Expression (run with the scene root as its base) that is true while the connection is live.
static func connected_expr(c: Dictionary) -> String:
	return "get_node(%s).is_connected(%s, Callable(get_node(%s), %s))" % [_q(str(c.get("source", ""))), _q(str(c.get("signal", ""))), _q(str(c.get("target", ""))), _q(str(c.get("method", "")))]


## An Expression that cuts the connection and answers true (disconnect returns nothing; a falsy answer would be
## evaluated again by the runtime to report what it read).
static func disconnect_expr(c: Dictionary) -> String:
	return "get_node(%s).disconnect(%s, Callable(get_node(%s), %s)) == null" % [_q(str(c.get("source", ""))), _q(str(c.get("signal", ""))), _q(str(c.get("target", ""))), _q(str(c.get("method", "")))]


static func _q(s: String) -> String:
	return "'%s'" % s.replace("\\", "\\\\").replace("'", "\\'")
