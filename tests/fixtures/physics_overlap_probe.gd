extends SceneTree
## Child-engine probe for runtime/physics_overlap.gd, run by tests/unit_tests.gd (_t_physics_overlap_engines) once
## per 3D physics engine, in a project that holds only the oracle and the files it may preload:
##
##   godot --headless --path <fixture project> --script res://probe.gd
##
## It builds small worlds side by side (each case far from the others, so no two cases touch), lets the physics
## run a few frames, asks the oracle about each one and prints one line per case:
##   PROBE ok <case>             the oracle said what this engine's physics says
##   PROBE FAIL <case>: <why>    it did not
##   PROBE done cases=<n> fails=<m> 3d=<the 3D engine this project asked for>
## and exits 1 on any failure. The same cases have to hold on GodotPhysics3D and on Jolt Physics: depths are
## compared with a tolerance that covers the engines' own contact margins, never with one engine's exact number.

const PO_PATH := "res://addons/beckett/runtime/physics_overlap.gd"
const FRAMES_BEFORE := 4      # physics frames before the scan: bodies settle into the broadphase
const TOL_3D := 0.06
const TOL_2D := 0.15

var PO: Script = null
var _cases := 0
var _fails := 0
var _frames := 0
var _done := false
var _w: Dictionary = {}       # case world name -> its root node
var _slot := 0


func _initialize() -> void:
	PO = load(PO_PATH)
	if PO == null:
		print("PROBE FAIL load: %s did not load" % PO_PATH)
		print("PROBE done cases=0 fails=1 3d=%s" % _engine())
		quit(1)
		return
	_pure_cases()
	_build_3d()
	_build_2d()


func _physics_process(_delta: float) -> bool:
	if _done:
		return false
	_frames += 1
	if _frames < FRAMES_BEFORE:
		return false
	_done = true
	_cases_3d()
	_cases_2d()
	print("PROBE done cases=%d fails=%d 3d=%s" % [_cases, _fails, _engine()])
	quit(1 if _fails > 0 else 0)
	return false


func _engine() -> String:
	return str(ProjectSettings.get_setting("physics/3d/physics_engine", ""))


func _check(name: String, cond: bool, info: Variant = "") -> void:
	_cases += 1
	if cond:
		print("PROBE ok %s" % name)
	else:
		_fails += 1
		print("PROBE FAIL %s: %s" % [name, str(info).left(300)])


# ---------------------------------------------------------------- the world builders

## A fresh case world, placed far from every other one.
func _world(name: String, is3d: bool) -> Node:
	var w: Node = Node3D.new() if is3d else Node2D.new()
	w.name = name
	_slot += 1
	if is3d:
		(w as Node3D).position = Vector3(0, 0, _slot * 40.0)
	else:
		(w as Node2D).position = Vector2(0, _slot * 400.0)
	root.add_child(w)
	_w[name] = w
	return w


func _body3(parent: Node, name: String, kind: String, pos: Vector3, shape: Shape3D, extra: Dictionary = {}) -> CollisionObject3D:
	var b: CollisionObject3D
	match kind:
		"static":
			b = StaticBody3D.new()
		"rigid_static":
			var rb := RigidBody3D.new()
			rb.freeze = true
			rb.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
			b = rb
		"area":
			b = Area3D.new()
		_:
			b = CharacterBody3D.new()
	b.name = name
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.disabled = bool(extra.get("disabled", false))
	b.add_child(cs)
	if extra.has("layer"):
		b.collision_layer = int(extra["layer"])
		b.collision_mask = int(extra["mask"])
	parent.add_child(b)
	b.position = pos
	return b


func _body2(parent: Node, name: String, kind: String, pos: Vector2, shape: Shape2D, extra: Dictionary = {}) -> CollisionObject2D:
	var b: CollisionObject2D
	match kind:
		"static":
			b = StaticBody2D.new()
		"area":
			b = Area2D.new()
		_:
			b = CharacterBody2D.new()
	b.name = name
	var cs := CollisionShape2D.new()
	cs.shape = shape
	b.add_child(cs)
	if extra.has("layer"):
		b.collision_layer = int(extra["layer"])
		b.collision_mask = int(extra["mask"])
	parent.add_child(b)
	b.position = pos
	return b


func _box(s: float) -> BoxShape3D:
	var sh := BoxShape3D.new()
	sh.size = Vector3(s, s, s)
	return sh


func _ball(r: float) -> SphereShape3D:
	var sh := SphereShape3D.new()
	sh.radius = r
	return sh


func _rect(s: float) -> RectangleShape2D:
	var sh := RectangleShape2D.new()
	sh.size = Vector2(s, s)
	return sh


func _disc(r: float) -> CircleShape2D:
	var sh := CircleShape2D.new()
	sh.radius = r
	return sh


func _build_3d() -> void:
	var w := _world("Clip3", true)
	_body3(w, "Wall", "static", Vector3.ZERO, _box(2))
	_body3(w, "Hero", "character", Vector3(1.2, 0, 0), _box(2))
	w = _world("Touch3", true)
	_body3(w, "Wall", "static", Vector3.ZERO, _box(2))
	_body3(w, "Hero", "character", Vector3(2.0, 0, 0), _box(2))
	w = _world("Apart3", true)
	_body3(w, "Wall", "static", Vector3.ZERO, _box(2))
	_body3(w, "Hero", "character", Vector3(3.0, 0, 0), _box(2))
	w = _world("Balls3", true)
	_body3(w, "A", "character", Vector3.ZERO, _ball(1))
	_body3(w, "B", "character", Vector3(1.5, 0, 0), _ball(1))
	w = _world("Statics3", true)
	_body3(w, "Floor", "static", Vector3.ZERO, _box(2))
	_body3(w, "Rock", "static", Vector3(1.0, 0, 0), _box(2))
	_body3(w, "Frozen", "rigid_static", Vector3(0, 1.0, 0), _box(2))
	w = _world("Disabled3", true)
	_body3(w, "Wall", "static", Vector3.ZERO, _box(2))
	_body3(w, "Ghost", "character", Vector3(1.0, 0, 0), _box(2), {"disabled": true})
	w = _world("Layers3", true)
	_body3(w, "Wall", "static", Vector3.ZERO, _box(2), {"layer": 4, "mask": 0})
	_body3(w, "Hero", "character", Vector3(1.0, 0, 0), _box(2), {"layer": 2, "mask": 0})
	w = _world("Crowd3", true)
	_body3(w, "Wall", "static", Vector3.ZERO, _box(2))
	for i in 3:
		var h := _body3(w, "Hero%d" % i, "character", Vector3(1.0 + 0.1 * i, 0, -0.5 + 0.5 * i), _box(2))
		h.add_to_group("probe_crowd")
	w = _world("Area3", true)
	_body3(w, "Wall", "static", Vector3.ZERO, _box(2))
	_body3(w, "Trigger", "area", Vector3(0.5, 0, 0), _box(2))
	w = _world("Movers3", true)
	_body3(w, "A", "character", Vector3.ZERO, _box(2))
	_body3(w, "B", "character", Vector3(1.4, 0, 0), _box(2))


func _build_2d() -> void:
	var w := _world("Clip2", false)
	_body2(w, "Hero", "character", Vector2.ZERO, _rect(20))
	_body2(w, "Wall", "static", Vector2(15, 0), _rect(20))
	w = _world("Touch2", false)
	_body2(w, "Hero", "character", Vector2.ZERO, _rect(20))
	_body2(w, "Wall", "static", Vector2(20, 0), _rect(20))
	w = _world("Discs2", false)
	_body2(w, "A", "character", Vector2.ZERO, _disc(10))
	_body2(w, "B", "character", Vector2(15, 0), _disc(10))
	w = _world("Statics2", false)
	_body2(w, "Floor", "static", Vector2.ZERO, _rect(20))
	_body2(w, "Ledge", "static", Vector2(10, 0), _rect(20))
	w = _world("Layers2", false)
	_body2(w, "Hero", "character", Vector2.ZERO, _rect(20), {"layer": 2, "mask": 0})
	_body2(w, "Wall", "static", Vector2(10, 0), _rect(20), {"layer": 4, "mask": 0})
	w = _world("Area2", false)
	_body2(w, "Hero", "character", Vector2.ZERO, _rect(20))
	_body2(w, "Zone", "area", Vector2(5, 0), _rect(20))
	w = _world("Shallow2", false)
	_body2(w, "Hero", "character", Vector2.ZERO, _rect(20))
	_body2(w, "Wall", "static", Vector2(19.8, 0), _rect(20))


# ---------------------------------------------------------------- the cases

func _scan(world: String, spec: Dictionary = {}) -> Dictionary:
	return PO.call("run", self, _w[world], spec, Callable())


func _one_pair(r: Dictionary, a: String, b: String, depth: float, tol: float, space: String) -> bool:
	if r.get("ok", false) != true or not (r.get("pairs") is Array) or (r["pairs"] as Array).size() != 1:
		return false
	var p: Dictionary = r["pairs"][0]
	return str(p["a"]) == a and str(p["b"]) == b and absf(float(p["depth"]) - depth) <= tol and str(p["space"]) == space


func _no_pair(r: Dictionary) -> bool:
	return r.get("ok", false) == true and (r.get("pairs") as Array).is_empty()


func _pure_cases() -> void:
	var n: Dictionary = PO.call("normalize", {})
	_check("normalize_defaults", n["ok"] == true and n["min_depth"] == {"2d": 0.5, "3d": 0.05} and n["max_pairs"] == 20 and n["max_bodies"] == 500, n)
	_check("normalize_refuses", str(PO.call("spec_error", {"min_depth": -1})).contains("min_depth") and str(PO.call("spec_error", {"paths": "Hero"})).contains("paths must be an array"))
	var cd: Dictionary = PO.call("contact_depth", [Vector3(1, 0, 0), Vector3(0.5, 0, 0), Vector3(2, 2, 2), Vector3(2, 2, 2)])
	_check("contact_depth_deepest", is_equal_approx(float(cd["depth"]), 0.5) and cd["a"] == Vector3(1, 0, 0), cd)
	_check("bound_text", PO.call("bound_text", {"2d": 0.5, "3d": 0.05}) == "0.5 (2D) / 0.05 (3D)" and PO.call("bound_text", {"2d": 1.0, "3d": 1.0}) == "1")
	var j: Dictionary = PO.call("judge", {"ok": true, "bodies": 0, "pairs": [], "min_depth": {"2d": 0.5, "3d": 0.05}})
	_check("judge_no_body_blocked", j["status"] == "blocked", j)


func _cases_3d() -> void:
	var r := _scan("Clip3")
	_check("3d_box_clip_pair", _one_pair(r, "Hero", "Wall", 0.8, TOL_3D, "3d"), r)
	_check("3d_box_clip_both_bodies", int(r.get("bodies", -1)) == 2, r)
	var nrm: Array = (r["pairs"][0]["normal"] as Array) if _one_pair(r, "Hero", "Wall", 0.8, TOL_3D, "3d") else []
	_check("3d_box_clip_normal_on_x", nrm.size() == 3 and absf(float(nrm[0])) > 0.9 and absf(float(nrm[1])) < 0.2 and absf(float(nrm[2])) < 0.2, nrm)
	_check("3d_box_clip_judged_fail", str(PO.call("judge", r)["status"]) == "fail" and str(PO.call("judge", r)["detail"]).contains("Hero into Wall"), PO.call("judge", r))
	r = _scan("Touch3")
	_check("3d_box_touching_no_pair", _no_pair(r) and int(r.get("bodies", -1)) == 2, r)
	_check("3d_box_touching_judged_pass", str(PO.call("judge", r)["status"]) == "pass" and str(PO.call("judge", r)["detail"]).contains("2 bodies checked"), PO.call("judge", r))
	r = _scan("Apart3")
	_check("3d_box_apart_no_pair", _no_pair(r), r)
	r = _scan("Balls3")
	_check("3d_spheres_pair", _one_pair(r, "A", "B", 0.5, TOL_3D, "3d"), r)
	r = _scan("Statics3")
	_check("3d_static_pairs_skipped", _no_pair(r) and r.get("skipped") is Dictionary and int(r["skipped"]["static_pairs"]) == 3, r)
	_check("3d_static_pass_says_left_out", str(PO.call("judge", r)["detail"]).contains("left out: 3 static pairs"), PO.call("judge", r))
	r = _scan("Disabled3")
	_check("3d_disabled_shape_skipped", _no_pair(r) and r.get("skipped") is Dictionary and int(r["skipped"]["disabled_shapes"]) == 1, r)
	r = _scan("Layers3")
	_check("3d_layers_that_never_meet", _no_pair(r) and int(r.get("bodies", -1)) == 2, r)
	r = _scan("Clip3", {"min_depth": 1.0})
	_check("3d_min_depth_above_the_clip", _no_pair(r) and r["min_depth"] == {"2d": 1.0, "3d": 1.0}, r)
	r = _scan("Clip3", {"min_depth": 0.5})
	_check("3d_min_depth_below_the_clip", _one_pair(r, "Hero", "Wall", 0.8, TOL_3D, "3d"), r)
	r = _scan("Clip3", {"paths": ["Hero"]})
	_check("3d_paths_scope", _one_pair(r, "Hero", "Wall", 0.8, TOL_3D, "3d") and int(r["bodies"]) == 1, r)
	r = _scan("Clip3", {"paths": ["Wall"]})
	_check("3d_paths_static_subject", _one_pair(r, "Wall", "Hero", 0.8, TOL_3D, "3d") and int(r["bodies"]) == 1, r)
	r = _scan("Clip3", {"paths": ["/root/Clip3/Hero"]})
	_check("3d_absolute_path", _one_pair(r, "Hero", "Wall", 0.8, TOL_3D, "3d"), r)
	r = _scan("Clip3", {"paths": ["Nobody"]})
	_check("3d_missing_path_error", r.get("ok", true) == false and str(r.get("error", "")).begins_with("node not found: Nobody") and PO.call("judge", r)["status"] == "blocked", r)
	r = _scan("Crowd3", {"group": "probe_crowd"})
	_check("3d_group_scope", r.get("ok", false) == true and int(r["bodies"]) == 3 and (r["pairs"] as Array).size() >= 3, r)
	r = _scan("Crowd3", {"group": "probe_nobody"})
	_check("3d_empty_group_error", str(r.get("error", "")).contains("no node matches group 'probe_nobody'"), r)
	r = _scan("Crowd3", {"max_pairs": 1})
	_check("3d_max_pairs_stops", r.get("ok", false) == true and (r["pairs"] as Array).size() == 1 and r.get("truncated", {}).get("pairs", false) == true
		and str(PO.call("judge", r)["detail"]).contains("stopped at max_pairs"), r)
	r = _scan("Crowd3", {"max_bodies": 1})
	_check("3d_max_bodies_cuts_static_last", r.get("ok", false) == true and int(r["bodies"]) == 1 and int(r.get("truncated", {}).get("bodies", 0)) == 3 and str(r["pairs"][0]["a"]) == "Hero0", r)
	var deepest := true
	r = _scan("Crowd3")
	for i in range(1, (r.get("pairs", []) as Array).size()):
		deepest = deepest and float(r["pairs"][i - 1]["depth"]) >= float(r["pairs"][i]["depth"])
	_check("3d_pairs_deepest_first", r.get("ok", false) == true and deepest, r)
	r = _scan("Area3")
	_check("3d_area_is_no_body", _no_pair(r) and int(r.get("bodies", -1)) == 1, r)
	r = _scan("Movers3")
	_check("3d_two_movers_one_pair", _one_pair(r, "A", "B", 0.6, TOL_3D, "3d"), r)
	r = _scan("Clip3", {"min_depth": -2})
	_check("3d_bad_spec_is_an_error", r.get("ok", true) == false and str(r.get("error", "")).contains("min_depth"), r)


func _cases_2d() -> void:
	var r := _scan("Clip2")
	_check("2d_rect_clip_pair", _one_pair(r, "Hero", "Wall", 5.0, TOL_2D, "2d"), r)
	var nrm: Array = (r["pairs"][0]["normal"] as Array) if _one_pair(r, "Hero", "Wall", 5.0, TOL_2D, "2d") else []
	_check("2d_rect_clip_normal_on_x", nrm.size() == 2 and absf(float(nrm[0])) > 0.9, nrm)
	r = _scan("Touch2")
	_check("2d_rect_touching_no_pair", _no_pair(r) and int(r.get("bodies", -1)) == 2, r)
	r = _scan("Discs2")
	_check("2d_discs_pair", _one_pair(r, "A", "B", 5.0, TOL_2D, "2d"), r)
	r = _scan("Statics2")
	_check("2d_static_pair_skipped", _no_pair(r) and int(r.get("skipped", {}).get("static_pairs", 0)) == 1, r)
	r = _scan("Layers2")
	_check("2d_layers_that_never_meet", _no_pair(r), r)
	r = _scan("Area2")
	_check("2d_area_is_no_body", _no_pair(r) and int(r.get("bodies", -1)) == 1, r)
	r = _scan("Shallow2")
	_check("2d_shallow_contact_under_default_bound", _no_pair(r), r)
	r = _scan("Shallow2", {"min_depth": 0})
	_check("2d_shallow_contact_over_zero_bound", _one_pair(r, "Hero", "Wall", 0.2, TOL_2D, "2d"), r)
	r = _scan("Clip2", {"paths": ["Hero"], "min_depth": 4.5})
	_check("2d_paths_and_bound", _one_pair(r, "Hero", "Wall", 5.0, TOL_2D, "2d") and int(r["bodies"]) == 1, r)
