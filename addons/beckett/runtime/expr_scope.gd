extends RefCounted
## Where an eval_at expression runs, and the names it binds (1.17, Full edition): runtime_call expr= with a node
## (path or selector) or with inputs. mcp_runtime.gd (_eval_cmd) loads this module by path when it is asked for
## eval_at, and a build without it (Lite: pack.ps1 trims it) answers that the feature is Full-only.
##
## scope() picks the base the expression runs on (the node the command names, found and refused the way a
## runtime "call" finds and refuses its target, or the scene root when it names none) and turns `inputs` into the
## names and values Expression.parse and execute take. It never parses or runs the expression: the runtime does,
## after its own unsafe_call check (invariants.gd), which comes before anything here is resolved.
##
## Static module (every function is static), no editor classes: it runs in the game.

const Internals := preload("res://addons/beckett/core/internals.gd")  # Beckett's own runtime is off limits as a base

## Selector fields that name a target (runtime "call" reads the same ones through _resolve_target).
const TARGET_KEYS := ["path", "class", "name", "text"]


## {base, names, values} for the expression of `msg` on runtime `rt`, or {error}. `rt` is the MCPRuntime node: its
## resolver and its miss text are the ones a call uses, so a target that is not there reads "node not found: ...".
static func scope(rt, msg: Dictionary) -> Dictionary:
	var root: Node = rt._root()
	if root == null:
		return {"error": "no current scene"}
	var base: Node = root
	if names_target(msg):
		base = rt._resolve_target(msg)
		if base == null:
			return {"error": rt._not_found(msg)}
	var off := Internals.runtime_refusal(base)
	if not off.is_empty():
		return {"error": off}
	var names := PackedStringArray()
	var values: Array = []
	var raw: Variant = msg.get("inputs", null)
	if raw != null:
		if not (raw is Dictionary):
			return {"error": "inputs must be an object of {name: value}"}
		for k in (raw as Dictionary):
			var nm := str(k)
			var why := name_error(nm)
			if not why.is_empty():
				return {"error": why}
			names.append(nm)
			values.append(_plain_numbers((raw as Dictionary)[k]))
	return {"base": base, "names": names, "values": values}


## Does the command name a node (a path or a selector), or does the expression run on the scene root?
static func names_target(msg: Dictionary) -> bool:
	for k in TARGET_KEYS:
		if not str(msg.get(k, "")).is_empty():
			return true
	return false


## "" when `nm` can be bound as an input, else why not: it is not an identifier, or it already means something in an
## expression (a built-in function, a type, a constant or a keyword), which would win over the input or fail to parse.
## runtime_tools.gd (input_name_error) asks the same before anything is sent.
static func name_error(nm: String) -> String:
	if not nm.is_valid_identifier():
		return "input '%s' is not a name: letters, digits and _, not starting with a digit" % nm.left(40)
	var ex := Expression.new()
	var probe := "\u0001beckett_input"
	if ex.parse(nm, PackedStringArray([nm])) != OK:
		return "input '%s' already means something in an expression (a built-in function, type or keyword): rename it" % nm
	var v: Variant = ex.execute([probe], null, false)
	if ex.has_execute_failed() or typeof(v) != TYPE_STRING or str(v) != probe:
		return "input '%s' already means something in an expression (a constant or keyword): rename it" % nm
	return ""


## A value as it came over the wire, with every whole-number float made an int again: JSON has one number type, and
## an input used as an index or a count must be an int (12 + 1 is 13, not 13.0).
static func _plain_numbers(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			var f: float = v
			if is_finite(f) and f == floorf(f) and absf(f) <= 9007199254740992.0:
				return int(f)
			return f
		TYPE_ARRAY:
			var out: Array = []
			for e in (v as Array):
				out.append(_plain_numbers(e))
			return out
		TYPE_DICTIONARY:
			var d := {}
			for k in (v as Dictionary):
				d[k] = _plain_numbers((v as Dictionary)[k])
			return d
	return v
