@tool
extends RefCounted

## Project tool modules: MCP tools that live in the GAME's repository, not in this addon.
##
## A project lists its own modules in the project setting beckett/extra_tool_modules (an
## array of res:// paths, or one comma-separated string). Each is a script shaped exactly
## like a built-in module (tools/*.gd): `var server` and `func _register(registry)`. The
## server loads them after its own modules, so a project can teach the agent its game
## (a localization audit, a save-file inspector, a balance probe) without forking Beckett.
##
## What a project module gets, and what it cannot do:
##   * it registers into a guarded registry (Registrar below): a name a built-in module
##     already owns is refused with a warning, never overwritten, so a project cannot
##     shadow screenshot or play_scene with something that behaves differently;
##   * a spec may carry "effort": 1..6, the dial tier that advertises it (default 1, like
##     any unmapped tool). The edition ceiling still applies: Lite refuses a tier-5 tool;
##   * the module runs in the editor with the same trust as any @tool script of the
##     project, which is the trust the project setting itself already carries;
##   * export_filter.gd keeps every listed module out of exported games.
##
## Static and editor-free so the unit suite (and a cold class cache) can drive it.

const PathGuard := preload("res://addons/beckett/core/path_guard.gd")
const Effort := preload("res://addons/beckett/core/effort.gd")

const SETTING := "beckett/extra_tool_modules"
const ADDON_PREFIX := "res://addons/beckett/"
## A project with more modules than this has listed something by mistake.
const MAX_MODULES := 32


## The listed paths, trimmed, de-duplicated, in order. Takes the raw setting value: an
## Array / PackedStringArray, or a String with commas (what a hand edit of project.godot
## most likely holds). Anything else lists nothing.
static func paths_from(value) -> Array:
	var raw: Array = []
	if value is String or value is StringName:
		raw = Array(str(value).split(",", false))
	elif value is Array or value is PackedStringArray:
		raw = Array(value)
	var out: Array = []
	for v in raw:
		var p := str(v).strip_edges()
		if not p.is_empty() and not out.has(p):
			out.append(p)
	return out


## The paths the project setting lists right now.
static func configured() -> Array:
	return paths_from(ProjectSettings.get_setting(SETTING, []))


## "" when `path` may be loaded as a project module, else why not. Existence is checked
## by the loader, so this stays a pure text rule.
static func path_error(path: String) -> String:
	if not path.begins_with("res://"):
		return "must be a res:// path"
	if not path.ends_with(".gd"):
		return "must be a .gd script"
	if path.contains(".."):
		return "must not contain '..'"
	if path.begins_with(ADDON_PREFIX):
		return "is inside the Beckett addon (its own modules load from TOOL_MODULES)"
	for ch in path:
		if ch.unicode_at(0) < 0x20 or ch.unicode_at(0) == 0x7f:
			return "must not contain control characters"
	return ""


## Load every listed module into `registry` for `server`. Returns one report entry per
## listed path, {path, tools:[names]} or {path, error}, for doctor and the editor log.
## `instances` receives the live module objects (their Callables need them kept alive).
static func load_all(paths: Array, registry, server, instances: Array) -> Array:
	Effort.clear_extra_tiers()
	var report: Array = []
	for i in paths.size():
		var path := str(paths[i])
		if i >= MAX_MODULES:
			report.append({"path": path, "error": "more than %d project modules listed; the rest were not loaded" % MAX_MODULES})
			continue
		var err := path_error(path)
		if err.is_empty() and not ResourceLoader.exists(path):
			err = "no such script"
		if not err.is_empty():
			report.append({"path": path, "error": err})
			continue
		var script = load(path)
		if not (script is Script) or not script.can_instantiate():
			report.append({"path": path, "error": "does not compile (open it in the script editor to see why)"})
			continue
		var m = script.new()
		if not m.has_method("_register"):
			report.append({"path": path, "error": "has no _register(registry) method"})
			continue
		if "server" in m:
			m.server = server
		var reg := Registrar.new(registry, path)
		m._register(reg)
		instances.append(m)
		var entry := {"path": path, "tools": reg.accepted}
		if not reg.refused.is_empty():
			entry["refused"] = reg.refused
		report.append(entry)
	return report


## The registry a project module sees: register() only, built-in names protected.
class Registrar:
	extends RefCounted
	var _inner
	var _path: String
	var accepted: Array = []
	var refused: Array = []

	func _init(inner, path: String) -> void:
		_inner = inner
		_path = path

	func register(spec: Dictionary) -> void:
		var name := str(spec.get("name", ""))
		var why := ""
		if name.is_empty() or not spec.has("handler"):
			why = "a tool spec needs a name and a handler"
		elif _inner.has(name):
			why = "the name is already taken"
		elif spec.has("always_load") or spec.has("max_result_chars"):
			why = "always_load and max_result_chars are reserved for Beckett's own tools"
		if not why.is_empty():
			refused.append({"name": name, "why": why})
			push_warning("[beckett] %s: tool '%s' not registered: %s" % [_path, name, why])
			return
		if spec.has("effort"):
			Effort.set_extra_tier(name, int(spec["effort"]))
		var clean := spec.duplicate()
		clean.erase("effort")
		_inner.register(clean)
		accepted.append(name)

	func has(name: String) -> bool:
		return _inner.has(name)
