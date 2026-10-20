extends RefCounted
## The physics overlap oracle (v1.16 M5d): which physics bodies of a running scene penetrate each other, and
## how deep. It sits behind the playtest assert {type:"no_overlap"}: the editor asks the game through the
## runtime command physics_overlap (mcp_runtime.gd), the headless runner (playtest_runner.gd) asks this module
## directly. A player stuck in a wall, a crate sunk into the floor, two enemies spawned inside each other:
## every end-state assert can pass while that is on screen, and this is the check that sees it.
##
## How: every body in scope (the scene, or the nodes `paths` / `group` name, and everything below them) asks
## the physics space which bodies its shapes touch (intersect_shape), then how deep each one goes
## (collide_shape against that body alone: its contact pairs, the deepest pair wins). The engine's own
## collision code does the geometry, so a scene is judged the way its physics engine (GodotPhysics or Jolt)
## sees it, not by a model of it.
##
## What counts:
##  * a pair deeper than min_depth: 0.5 px in 2D and 0.05 m in 3D by default. Resting contact is not zero
##    in either engine (solver slop, Jolt's convex radius, a character's safe margin), so "touching" must not
##    read as a clip; one number given applies to both dimensions.
##  * physics bodies only (Area2D/3D are triggers: overlapping them is their job), on layers that interact
##    (either body's mask holds the other's layer). Two static bodies are never measured (level geometry
##    built to overlap), and a disabled shape is not there: both are counted under `skipped`, so a pass says
##    what it left out.
##  * a scan cut short (max_bodies, the time or query budget, a scene too large to walk) with nothing found
##    is not a pass: judge() calls it blocked.
##
## Static module (every function is static), no editor classes: it runs in the game, in the headless runner's
## child projects and in the editor (judge, spec_error). It preloads only game_state.gd.

const GameState := preload("res://addons/beckett/runtime/game_state.gd")  # path_of: a body named the way the runtime resolves it

const DEPTH_2D := 0.5
const DEPTH_3D := 0.05
const DEPTH_MAX := 1000000.0
const PAIRS_DEFAULT := 20
const PAIRS_MAX := 200
const BODIES_DEFAULT := 500
const BODIES_MAX := 2000
const BUDGET_DEFAULT_MS := 1500
const BUDGET_MAX_MS := 60000
const PATHS_MAX := 64
const PATH_CHARS := 200
const GROUP_CHARS := 200
## Nodes looked at to find the bodies, and physics queries spent on one scan: a runaway scene ends the
## scan (truncated) instead of stalling the game for seconds.
const WALK_MAX := 100000
const QUERIES_MAX := 20000
## Results asked of one shape query (bodies touched, contact pairs).
const HITS_PER_QUERY := 32
## Pairs a verdict spells out; the rest are counted and carried in `pairs`.
const SPELLED_OUT := 3


# ---------------------------------------------------------------- the spec

## A no_overlap spec (the assert, or the runtime command) with its defaults filled in:
## {ok: true, paths, group, min_depth: {"2d", "3d"}, min_depth_given, max_pairs, max_bodies, budget_ms}
## or {ok: false, error} naming the field. Keys it does not know (type, a note) are ignored.
static func normalize(spec: Variant) -> Dictionary:
	var d: Dictionary = spec if spec is Dictionary else {}
	var out := {"ok": true, "paths": [], "group": "", "min_depth": {"2d": DEPTH_2D, "3d": DEPTH_3D}, "min_depth_given": false,
		"max_pairs": PAIRS_DEFAULT, "max_bodies": BODIES_DEFAULT, "budget_ms": BUDGET_DEFAULT_MS}
	var md: Variant = d.get("min_depth", null)
	if md != null:
		var depth_err := "min_depth must be a number from 0 to %d: how deep two bodies may overlap, in pixels (2D) or meters (3D)" % int(DEPTH_MAX)
		if md is Dictionary:
			var both := {"2d": DEPTH_2D, "3d": DEPTH_3D}
			for k in md:
				var key := str(k).strip_edges().to_lower()
				if not (key in ["2d", "3d"]):
					return _bad("min_depth as an object takes only the keys 2d and 3d (got '%s')" % str(k).left(20))
				var dv: Variant = _depth(md[k])
				if dv == null:
					return _bad(depth_err)
				both[key] = dv
			out["min_depth"] = both
		else:
			var v: Variant = _depth(md)
			if v == null:
				return _bad(depth_err)
			out["min_depth"] = {"2d": v, "3d": v}
		out["min_depth_given"] = true
	for f in [["max_pairs", 1, PAIRS_MAX, PAIRS_DEFAULT], ["max_bodies", 1, BODIES_MAX, BODIES_DEFAULT], ["budget_ms", 0, BUDGET_MAX_MS, BUDGET_DEFAULT_MS]]:
		var raw: Variant = d.get(str(f[0]), null)
		if raw == null:
			continue
		var w: Variant = _whole(raw)
		if w == null or int(w) < int(f[1]) or int(w) > int(f[2]):
			return _bad("%s must be a whole number from %d to %d" % [f[0], f[1], f[2]])
		out[str(f[0])] = int(w)
	var p: Variant = d.get("paths", null)
	if p != null:
		if not (p is Array or p is PackedStringArray):
			return _bad("paths must be an array of node paths (got %s)" % type_string(typeof(p)))
		var list: Array = Array(p)
		if list.size() > PATHS_MAX:
			return _bad("paths: at most %d node paths (got %d)" % [PATHS_MAX, list.size()])
		var paths: Array = []
		for i in list.size():
			var e: Variant = list[i]
			var s := str(e).strip_edges() if (e is String or e is StringName) else ""
			if s.is_empty() or s.length() > PATH_CHARS:
				return _bad("paths[%d] must be a non-empty node path of at most %d characters" % [i, PATH_CHARS])
			paths.append(s)
		out["paths"] = paths
	var g: Variant = d.get("group", null)
	if g != null:
		if not (g is String or g is StringName):
			return _bad("group must be a string: the name of a node group")
		var gs := str(g).strip_edges()
		if gs.length() > GROUP_CHARS:
			return _bad("group must be at most %d characters" % GROUP_CHARS)
		out["group"] = gs
	return out


## "" for a spec normalize accepts, else why not (playtest op=save refuses a malformed assert with it).
static func spec_error(spec: Variant) -> String:
	var n := normalize(spec)
	return "" if n.get("ok", false) == true else str(n.get("error", "malformed no_overlap spec"))


static func _bad(why: String) -> Dictionary:
	return {"ok": false, "error": why}


## A depth bound from a number or numeric text: finite, 0..DEPTH_MAX; null for anything else (bools too).
static func _depth(v: Variant) -> Variant:
	var f: float
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			f = float(v)
		TYPE_STRING, TYPE_STRING_NAME:
			var s := str(v).strip_edges()
			if not (s.is_valid_float() or s.is_valid_int()):
				return null
			f = s.to_float()
		_:
			return null
	if is_nan(f) or is_inf(f) or f < 0.0 or f > DEPTH_MAX:
		return null
	return f


## A whole number from an int, a whole float or digits in text; null for anything else (bools included).
static func _whole(v: Variant) -> Variant:
	match typeof(v):
		TYPE_INT:
			return v
		TYPE_FLOAT:
			var f: float = v
			if not is_nan(f) and not is_inf(f) and f == floorf(f) and absf(f) < 1e15:
				return int(f)
		TYPE_STRING, TYPE_STRING_NAME:
			var s := str(v).strip_edges()
			if s.is_valid_int():
				return s.to_int()
			if s.is_valid_float():
				return _whole(s.to_float())
	return null


# ---------------------------------------------------------------- the maths (pure)

## The deepest contact in collide_shape's answer: consecutive (point on the query shape, point on the other
## body) pairs; the distance between the two points of a pair is how far the shapes overlap there. A pair
## whose points coincide is touching, not overlapping; an odd point left at the end is ignored.
## {depth: 0.0, a: null, b: null} when nothing overlaps.
static func contact_depth(points: Variant) -> Dictionary:
	var best := {"depth": 0.0, "a": null, "b": null}
	if not (points is Array or points is PackedVector2Array or points is PackedVector3Array):
		return best
	var n: int = points.size()
	var i := 0
	while i + 1 < n:
		var a: Variant = points[i]
		var b: Variant = points[i + 1]
		i += 2
		var d := 0.0
		if a is Vector2 and b is Vector2:
			d = (a as Vector2).distance_to(b)
		elif a is Vector3 and b is Vector3:
			d = (a as Vector3).distance_to(b)
		else:
			continue
		if d > float(best["depth"]):
			best = {"depth": d, "a": a, "b": b}
	return best


## The unit direction of a contact, (a - b) / depth; null when there is no contact.
static func contact_normal(a: Variant, b: Variant, depth: float) -> Variant:
	if a == null or b == null or depth <= 0.0:
		return null
	if (a is Vector2 and b is Vector2) or (a is Vector3 and b is Vector3):
		return (a - b) / depth
	return null


## Do two bodies collide at all? Either one's mask holding the other's layer is enough.
static func interacts(layer_a: int, mask_a: int, layer_b: int, mask_b: int) -> bool:
	return (mask_a & layer_b) != 0 or (mask_b & layer_a) != 0


## One key per pair of bodies, whichever is asked first.
static func pair_key(id_a: int, id_b: int) -> String:
	return "%d:%d" % [mini(id_a, id_b), maxi(id_a, id_b)]


## A vector as a short array of numbers rounded to 3 decimals ([] for anything that is not a vector).
static func vec_out(v: Variant) -> Array:
	if v is Vector2 or v is Vector2i:
		return [snappedf(v.x, 0.001), snappedf(v.y, 0.001)]
	if v is Vector3 or v is Vector3i:
		return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]
	return []


## The bound a verdict names: "0.5 (2D) / 0.05 (3D)", one number when both dimensions share it.
static func bound_text(min_depth: Variant) -> String:
	if not (min_depth is Dictionary) or not (min_depth as Dictionary).has("2d") or not (min_depth as Dictionary).has("3d"):
		return "the bound"
	var a := float(min_depth["2d"])
	var b := float(min_depth["3d"])
	if is_equal_approx(a, b):
		return short_num(a)
	return "%s (2D) / %s (3D)" % [short_num(a), short_num(b)]


## A number for a sentence: at most 3 decimals, no trailing zeros ("0.5", "5", "0.05").
static func short_num(f: float) -> String:
	var s := "%.3f" % f
	while s.contains(".") and (s.ends_with("0") or s.ends_with(".")):
		s = s.left(s.length() - 1)
	return "0" if s == "-0" else s


# ---------------------------------------------------------------- the verdict

## A reply of run() (or of the runtime command) as an assert result {status, detail, pairs?}: pass when the
## whole scan ran and nothing penetrates; fail with the pairs; blocked when nothing could be judged (no body,
## a path or group that names nothing, a scan cut short before it found anything).
static func judge(reply: Variant) -> Dictionary:
	if not (reply is Dictionary):
		return {"status": "fail", "detail": "the overlap query gave no answer"}
	var r: Dictionary = reply
	if r.get("ok", false) != true:
		var err := str(r.get("error", ""))
		if err.is_empty():
			return {"status": "fail", "detail": "the overlap query failed"}
		for needle in ["node not found", "no node matches group", "no current scene", "the physics space is not accessible"]:
			if err.contains(needle):
				return {"status": "blocked", "detail": err}
		return {"status": "fail", "detail": err}
	var bound := bound_text(r.get("min_depth", null))
	var bodies := int(r.get("bodies", 0))
	var pairs: Array = r.get("pairs", []) if r.get("pairs", []) is Array else []
	var truncated: Dictionary = r.get("truncated", {}) if r.get("truncated", {}) is Dictionary else {}
	if not pairs.is_empty():
		var parts := PackedStringArray()
		for i in mini(SPELLED_OUT, pairs.size()):
			var pr: Variant = pairs[i]
			if pr is Dictionary:
				parts.append("%s into %s, %s deep" % [str(pr.get("a", "?")), str(pr.get("b", "?")), short_num(float(pr.get("depth", 0.0)))])
		var detail := "%d pair(s) penetrate more than %s: %s" % [pairs.size(), bound, "; ".join(parts)]
		if pairs.size() > SPELLED_OUT:
			detail += " (+%d more listed)" % (pairs.size() - SPELLED_OUT)
		if truncated.get("pairs", false) == true:
			detail += "; the scan stopped at max_pairs, so there may be more"
		return {"status": "fail", "detail": detail, "pairs": pairs}
	if not truncated.is_empty():
		var why := PackedStringArray()
		if truncated.has("bodies"):
			why.append("%d bodies were not reached (max_bodies)" % int(truncated["bodies"]))
		if truncated.get("time", false) == true:
			why.append("the time budget ran out (budget_ms)")
		if truncated.get("queries", false) == true:
			why.append("the query budget ran out")
		if truncated.get("walk", false) == true:
			why.append("the scene is too large to walk")
		if why.is_empty():
			why.append("the scan was cut short")
		return {"status": "blocked", "detail": "nothing found in %d bodies checked, but the scan did not finish: %s; nothing was judged" % [bodies, ", ".join(why)]}
	if bodies <= 0:
		return {"status": "blocked", "detail": "no physics body was found to check (Area nodes are not bodies), so nothing was judged"}
	var detail := "%d bodies checked, no pair penetrates more than %s" % [bodies, bound]
	var skipped: Variant = r.get("skipped", null)
	if skipped is Dictionary and not (skipped as Dictionary).is_empty():
		detail += "; left out: %d static pairs, %d disabled shapes" % [int(skipped.get("static_pairs", 0)), int(skipped.get("disabled_shapes", 0))]
	return {"status": "pass", "detail": detail}


# ---------------------------------------------------------------- the scan (needs the physics server)

## Scan the bodies `msg` (a no_overlap spec) names below `root` (the scene) and report the pairs deeper than
## the bound. `resolver.call(path)` returns the Node a path names, or null (the runtime's own resolver, so a
## spec names nodes the way every other command does); without one, paths resolve from `root`.
## Call it outside the physics step (a command handler, _physics_process): the space is locked during it.
static func run(tree: SceneTree, root: Node, msg: Dictionary, resolver: Callable = Callable()) -> Dictionary:
	var spec := normalize(msg)
	if spec.get("ok", false) != true:
		return {"ok": false, "error": str(spec.get("error", "malformed no_overlap spec"))}
	if root == null or not is_instance_valid(root):
		return {"ok": false, "error": "no current scene"}
	# The scope is found without the tree (a path that names nothing, a scene with no body: answered as such);
	# only a body that is in the tree has a physics space to ask.
	if tree == null:
		tree = root.get_tree()
	var t0 := Time.get_ticks_msec()
	var scopes: Array = []
	for p in (spec["paths"] as Array):
		var n := _resolve(root, resolver, str(p))
		if n == null:
			return {"ok": false, "error": "node not found: %s" % str(p)}
		scopes.append(n)
	var group := str(spec["group"])
	if not group.is_empty():
		var members: Array = []
		for m in (tree.get_nodes_in_group(group) if tree != null else []):
			if m is Node and is_instance_valid(m):
				members.append(m)
		if members.is_empty():
			return {"ok": false, "error": "no node matches group '%s'" % group}
		scopes.append_array(members)
	if scopes.is_empty():
		scopes.append(root)
	var walk := {"left": WALK_MAX, "cut": false}
	var bodies: Array = []
	var seen := {}
	for s in scopes:
		_collect(s, bodies, seen, walk)
	var truncated := {}
	if walk["cut"] == true:
		truncated["walk"] = true
	# Moving bodies first: a pair is reported from the body that clips (Hero into Wall), and when max_bodies
	# cuts the list it is level geometry that is left out, not the bodies that move.
	var moving: Array = []
	var still: Array = []
	for b in bodies:
		(still if _is_static(b) else moving).append(b)
	bodies = moving + still
	var max_bodies := int(spec["max_bodies"])
	if bodies.size() > max_bodies:
		truncated["bodies"] = bodies.size() - max_bodies
		bodies = bodies.slice(0, max_bodies)
	var scan := {"root": root, "min_depth": spec["min_depth"], "max_pairs": int(spec["max_pairs"]), "queries": 0,
		"static_pairs": 0, "disabled_shapes": 0, "pairs": {}, "static_seen": {}, "full": false}
	var budget := int(spec["budget_ms"])
	var checked := 0
	for bi in bodies.size():
		var left := bodies.size() - bi
		if budget > 0 and Time.get_ticks_msec() - t0 > budget:
			truncated["time"] = true
			truncated["bodies"] = int(truncated.get("bodies", 0)) + left
			break
		if int(scan["queries"]) >= QUERIES_MAX:
			truncated["queries"] = true
			truncated["bodies"] = int(truncated.get("bodies", 0)) + left
			break
		var a: Variant = bodies[bi]
		if not is_instance_valid(a) or not (a as Node).is_inside_tree():
			continue
		var err := _scan_body(a as Object, scan)
		if not err.is_empty():
			return {"ok": false, "error": err}
		checked += 1
		if scan["full"] == true:
			truncated["pairs"] = true
			break
	var list: Array = (scan["pairs"] as Dictionary).values()
	list.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return float(x["depth"]) > float(y["depth"]))
	var out := {"ok": true, "bodies": checked, "pairs": list, "queries": int(scan["queries"]), "min_depth": spec["min_depth"]}
	if int(scan["static_pairs"]) > 0 or int(scan["disabled_shapes"]) > 0:
		out["skipped"] = {"static_pairs": int(scan["static_pairs"]), "disabled_shapes": int(scan["disabled_shapes"])}
	if not truncated.is_empty():
		out["truncated"] = truncated
	return out


static func _resolve(root: Node, resolver: Callable, path: String) -> Node:
	if resolver.is_valid():
		var r: Variant = resolver.call(path)
		return r as Node if r is Node and is_instance_valid(r) else null
	if path.is_empty() or path == ".":
		return root
	if path.begins_with("/"):
		return root.get_tree().root.get_node_or_null(NodePath(path)) if root.is_inside_tree() else null
	var n := root.get_node_or_null(NodePath(path))
	if n == null:
		n = root.find_child(path, true, false)
	return n


## Every physics body at or below `node` (pre-order, the scene's own order), once each.
static func _collect(node: Node, out: Array, seen: Dictionary, walk: Dictionary) -> void:
	var stack: Array = [node]
	while not stack.is_empty():
		if int(walk["left"]) <= 0:
			walk["cut"] = true
			return
		walk["left"] = int(walk["left"]) - 1
		var n: Node = stack.pop_back()
		if (n is PhysicsBody2D or n is PhysicsBody3D) and not seen.has(n.get_instance_id()):
			seen[n.get_instance_id()] = true
			out.append(n)
		var kids := n.get_children()
		for i in range(kids.size() - 1, -1, -1):
			stack.append(kids[i])


## Ask the space about every enabled shape of one body (a CollisionObject2D or 3D: both have the same shape
## owner API, so `a` is reached untyped); "" or the error that stops the scan.
static func _scan_body(a: Object, scan: Dictionary) -> String:
	var is2d := a is CollisionObject2D
	var world: Variant = a.call("get_world_2d") if is2d else a.call("get_world_3d")
	var space: Object = world.direct_space_state if world != null else null
	if space == null:
		return "the physics space is not accessible right now (%s has no direct space state: the physics step may be running, or the body is in no world)" % str(a.get("name"))
	for own in (a.call("get_shape_owners") as PackedInt32Array):
		var count := int(a.call("shape_owner_get_shape_count", own))
		if a.call("is_shape_owner_disabled", own) == true:
			scan["disabled_shapes"] = int(scan["disabled_shapes"]) + count
			continue
		var xform: Variant = a.get("global_transform") * a.call("shape_owner_get_transform", own)
		for si in count:
			if int(scan["queries"]) >= QUERIES_MAX or scan["full"] == true:
				return ""
			var shape: Variant = a.call("shape_owner_get_shape", own, si)
			if shape == null:
				continue
			var params: Object = PhysicsShapeQueryParameters2D.new() if is2d else PhysicsShapeQueryParameters3D.new()
			params.set("shape", shape)
			params.set("transform", xform)
			params.set("collision_mask", 0xFFFFFFFF)
			params.set("collide_with_areas", false)
			params.set("collide_with_bodies", true)
			_query_shape(a, is2d, params, space, scan)
	return ""


## One shape of body `a`: which bodies it touches (intersect_shape), then how deep each one goes
## (collide_shape against that body alone, every other body it touched excluded).
static func _query_shape(a: Object, is2d: bool, params: Object, space: Object, scan: Dictionary) -> void:
	var self_rid: RID = a.call("get_rid")
	var ex: Array[RID] = [self_rid]
	params.set("exclude", ex)
	var hits: Array = space.call("intersect_shape", params, HITS_PER_QUERY)
	scan["queries"] = int(scan["queries"]) + 1
	var md: Dictionary = scan["min_depth"]
	var bound := float(md["2d"] if is2d else md["3d"])
	var root: Node = scan["root"]
	for h in hits:
		if not (h is Dictionary):
			continue
		var b: Variant = (h as Dictionary).get("collider", null)
		if b == null or not is_instance_valid(b) or b == a or not (b is PhysicsBody2D or b is PhysicsBody3D):
			continue
		var key := pair_key(a.get_instance_id(), (b as Object).get_instance_id())
		if _is_static(a) and _is_static(b):
			if not (scan["static_seen"] as Dictionary).has(key):
				scan["static_seen"][key] = true
				scan["static_pairs"] = int(scan["static_pairs"]) + 1
			continue
		if not interacts(int(a.get("collision_layer")), int(a.get("collision_mask")), int(b.get("collision_layer")), int(b.get("collision_mask"))):
			continue
		if int(scan["queries"]) >= QUERIES_MAX:
			return
		var only: Array[RID] = [self_rid]
		for o in hits:
			if o is Dictionary and (o as Dictionary).get("collider", null) != b and (o as Dictionary).get("rid", null) is RID:
				only.append((o as Dictionary)["rid"])
		params.set("exclude", only)
		var points: Variant = space.call("collide_shape", params, HITS_PER_QUERY)
		scan["queries"] = int(scan["queries"]) + 1
		var c := contact_depth(points)
		var depth := float(c["depth"])
		if c["a"] == null or depth <= bound:
			continue
		var pairs: Dictionary = scan["pairs"]
		if pairs.has(key):
			if depth > float(pairs[key]["depth"]):
				pairs[key]["depth"] = snappedf(depth, 0.0001)
				pairs[key]["normal"] = vec_out(contact_normal(c["a"], c["b"], depth))
				pairs[key]["at"] = vec_out(c["a"])
			continue
		if pairs.size() >= int(scan["max_pairs"]):
			scan["full"] = true
			return
		pairs[key] = {"a": _name(a as Node, root), "b": _name(b as Node, root), "depth": snappedf(depth, 0.0001),
			"normal": vec_out(contact_normal(c["a"], c["b"], depth)), "at": vec_out(c["a"]), "space": "2d" if is2d else "3d"}


## Level geometry: a static body that does not move (an AnimatableBody moves, a frozen static RigidBody does not).
static func _is_static(n: Variant) -> bool:
	if n is AnimatableBody2D or n is AnimatableBody3D:
		return false
	if n is StaticBody2D or n is StaticBody3D:
		return true
	if n is RigidBody2D:
		return (n as RigidBody2D).freeze and (n as RigidBody2D).freeze_mode == RigidBody2D.FREEZE_MODE_STATIC
	if n is RigidBody3D:
		return (n as RigidBody3D).freeze and (n as RigidBody3D).freeze_mode == RigidBody3D.FREEZE_MODE_STATIC
	return false


## A body's name in a reply: its path from the scene root (the scene root by its own name), or its absolute
## /root/... path when it is outside the scene; both resolve through the runtime's resolver.
static func _name(n: Node, root: Node) -> String:
	if n == root:
		return str(root.name)
	return GameState.path_of(n, root)
