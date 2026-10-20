@tool
extends RefCounted

## playtest op=run_all since=<git ref>, the selection half (Full, v1.16): which suites a change can reach.
##
## git diff --name-only (plus the untracked files) says what changed since the ref. Each suite depends on the
## closure of its scene: the scene, the scripts and resources it loads, what those scripts preload or load by a
## literal path, the global classes they name, and the folders or name prefixes they spell out (a data-driven
## game lists a folder or builds a file name; everything under it may be loaded). A changed file in a suite's
## closure (or the suite's own file, or its screenshot baseline) selects that suite. What every run loads
## selects every suite: project.godot, an autoload's closure, a resource a project setting names. So does a
## file no resource references (a JSON a script reads by path) and anything past CHANGED_MAX files. Files that
## can never reach a running game (docs, CI config, editor folders, .uid files, Beckett itself) are ignored.
## A suite with no saved scene plays whatever is running: any relevant change selects it.
##
## git runs through OS.execute with its arguments as an array, and the ref is judged (ref_error) before git
## sees it, so a ref can never be an option or smuggle one to a shell.

const Subprocess := preload("res://addons/beckett/core/subprocess.gd")  # was git there at all?
const TestDir := preload("res://addons/beckett/core/test_dir.gd")  # where suite files live

## Changed files checked one by one; past this the change is too wide to place and every suite runs.
const CHANGED_MAX := 4000
const REF_MAX := 200
## Changed files a reason names before it counts the rest.
const REASON_FILES := 4
const UNREACHED_SHOWN := 20
## git's own exit codes (ok, fatal, usage): any other number means git never ran (see Subprocess.not_started).
const GIT_CODES := [0, 128, 129]
## Extensions a dependency walk can see: what a scene or resource refers to, and what a script preloads.
const RESOURCE_KINDS := ["tscn", "scn", "tres", "res", "gd", "gdshader", "gdshaderinc", "shader", "png", "jpg", "jpeg", "webp", "svg",
	"bmp", "tga", "exr", "hdr", "ktx", "dds", "ogg", "wav", "mp3", "glb", "gltf", "fbx", "blend", "obj", "dae", "ttf", "otf", "woff",
	"woff2", "fnt", "font", "material", "mesh", "anim", "theme", "stylebox", "translation"]
## Extensions of files a running game never loads.
const INERT_EXTS := ["md", "markdown", "rst", "adoc", "ps1", "psm1", "sh", "bash", "bat", "cmd", "uid"]
## Names (without extension) of files a running game never loads.
const INERT_NAMES := ["license", "licence", "changelog", "changes", "notice", "authors", "contributors", "copying", "readme"]
## C# sources: their uses are not traced (a class is used by name from anywhere), so a change selects everything.
const UNTRACED_EXTS := ["cs", "csproj", "sln", "props", "targets"]
## Project settings only the editor reads: a resource they name is not something every run loads.
const EDITOR_ONLY_SETTINGS := ["application/", "editor_plugins/", "editor/", "autoload/"]

static var _re_ext: RegEx
static var _re_ext_path: RegEx
static var _re_ext_uid: RegEx
static var _re_literal: RegEx
static var _re_ident: RegEx


# ---------------------------------------------------------------- the ref

## "" when `ref` may go to git as one argument; otherwise why not (the caller puts "since: " in front).
static func ref_error(ref: String) -> String:
	if ref.is_empty():
		return "a git ref is needed (a branch, a tag, a commit, HEAD~3, main..HEAD)"
	if ref.length() > REF_MAX:
		return "a ref must not be more than %d characters long (this one is %d)" % [REF_MAX, ref.length()]
	if ref.begins_with("-"):
		return "a ref must not start with '-': git would read it as an option"
	for i in ref.length():
		var u := ref.unicode_at(i)
		if _is_space(u):
			return "a ref must not contain whitespace (U+%04X): it goes to git as one argument" % u
		if u < 32 or u == 127 or (u >= 0x80 and u <= 0x9F):
			return "a ref must not contain control characters (U+%04X)" % u
		if u == 34 or u == 92:
			return "a ref must not contain quotes or backslashes"
		if u == 36 or u == 96:
			return "a ref must not contain $ or backticks: a shell would run what they hold"
	return ""


static func _is_space(u: int) -> bool:
	return (u >= 9 and u <= 13) or u == 32 or u == 0x85 or u == 0xA0 or u == 0x1680 or (u >= 0x2000 and u <= 0x200B) \
		or u == 0x2028 or u == 0x2029 or u == 0x202F or u == 0x205F or u == 0x3000 or u == 0xFEFF


# ---------------------------------------------------------------- paths

## A path as git prints it, made comparable: no quotes around it, forward slashes, no leading ./.
static func _norm(path: String) -> String:
	var s := path.strip_edges()
	if s.length() >= 2 and s.begins_with("\"") and s.ends_with("\""):
		s = s.substr(1, s.length() - 2)
	s = s.replace("\\", "/")
	while s.begins_with("./"):
		s = s.substr(2)
	return s


## Can this project-relative file never reach a running game?
static func is_inert(rel: String) -> bool:
	var l := _norm(rel).to_lower()
	if l.is_empty():
		return true
	for seg in l.split("/"):
		if seg.begins_with("."):
			return true
	if l.begins_with("addons/beckett/"):
		return true
	if l.ends_with(".report.json") or l.ends_with(".actual.png"):
		return true
	var file := l.get_file()
	if file == "export_presets.cfg" or INERT_EXTS.has(file.get_extension()):
		return true
	return INERT_NAMES.has(file.get_basename()) and (file.get_extension().is_empty() or ["md", "txt"].has(file.get_extension()))


## A kind of file a dependency walk can see (so a change to one that no suite loads reaches nothing).
static func is_resource_kind(res: String) -> bool:
	var ext := res.get_file().get_extension().to_lower()
	return not ext.is_empty() and RESOURCE_KINDS.has(ext)


static func _case_insensitive() -> bool:
	return OS.get_name() == "Windows" or OS.get_name() == "macOS"


## Does a dependency entry cover this path? A file is itself; a folder (ending in /) and the front of a name a
## script builds (no extension) cover everything that starts with them.
static func _covers(dep: String, key: String, ci: bool) -> bool:
	var d := dep.to_lower() if ci else dep
	if d == key:
		return true
	if d.ends_with("/") or (d.get_file().get_extension().is_empty() and d.length() > 6):
		return key.begins_with(d)
	return false


# ---------------------------------------------------------------- the selection (pure)

## Which suites `changed` (project-relative paths) can reach. suites: [{name, deps: Array | null, own: Array}];
## autoload_roots: what every run loads (files, folders, prefixes); capped: `changed` was cut at CHANGED_MAX.
## {mode: "impact" | "all", selected, skipped, reasons: {name: text}, ignored, unreached, unreached_count, why?}.
static func select(changed: Array, suites: Array, autoload_roots: Array, capped: bool = false) -> Dictionary:
	var names: Array = []
	for s in suites:
		names.append(str((s as Dictionary).get("name", "")) if s is Dictionary else str(s))
	if capped:
		return _all(names, "more than %d files changed, too many to place one by one" % CHANGED_MAX, 0)
	if changed.size() > CHANGED_MAX:
		return _all(names, "%d files changed, more than the %d that are placed one by one" % [changed.size(), CHANGED_MAX], 0)
	var ci := _case_insensitive()
	var playtest_dirs := [_k(TestDir.root() + "/playtests/", ci)]
	for s in suites:
		if s is Dictionary and (s as Dictionary).get("own") is Array:
			for o in s["own"]:
				if str(o).to_lower().ends_with(".json"):
					var dir := _k(str(o).get_base_dir() + "/", ci)
					if not playtest_dirs.has(dir):
						playtest_dirs.append(dir)
	var ignored := 0
	var relevant := 0
	var hits := {}
	var unreached: Array = []
	for c in changed:
		var rel := _norm(str(c))
		if rel.is_empty():
			continue
		if is_inert(rel):
			ignored += 1
			continue
		relevant += 1
		if rel.to_lower().ends_with(".import"):
			rel = rel.substr(0, rel.length() - 7)
		var res := "res://" + rel
		var key := _k(res, ci)
		if key == _k("res://project.godot", ci):
			return _all(names, "project.godot changed: it sets up every run (autoloads, input map, physics, rendering)", ignored)
		if UNTRACED_EXTS.has(rel.get_extension().to_lower()):
			return _all(names, "%s changed: C# code is used by class name from anywhere, and its uses are not traced" % rel, ignored)
		for a in autoload_roots:
			if _covers(str(a), key, ci):
				var whole := str(a).ends_with("/") or str(a).get_file().get_extension().is_empty()
				if whole:
					return _all(names, "%s is under %s, which an autoload (or a project setting) spells out: anything there may be loaded in every run" % [res, str(a)], ignored)
				return _all(names, "%s is loaded by an autoload (or named by a project setting), and every run loads those" % res, ignored)
		var reached := false
		for s in suites:
			if not (s is Dictionary):
				continue
			var hit := false
			var deps: Variant = (s as Dictionary).get("deps", null)
			if deps is Array:
				for d in deps:
					if _covers(str(d), key, ci):
						hit = true
						break
			if not hit and (s as Dictionary).get("own") is Array:
				for o in s["own"]:
					if _covers(str(o), key, ci):
						hit = true
						break
			if hit:
				reached = true
				var nm := str((s as Dictionary).get("name", ""))
				if not hits.has(nm):
					hits[nm] = []
				(hits[nm] as Array).append(res)
		if reached:
			continue
		var is_suite_file := false
		if key.ends_with(".json"):
			for pd in playtest_dirs:
				if key.begins_with(str(pd)):
					is_suite_file = true
		if is_resource_kind(res) or is_suite_file:
			unreached.append(res)
			continue
		return _all(names, "%s changed, and it is a file no resource references: a script may read it by path, so any suite may depend on it" % rel, ignored)
	var selected: Array = []
	var skipped: Array = []
	var reasons := {}
	for s in suites:
		var nm := str((s as Dictionary).get("name", "")) if s is Dictionary else str(s)
		var deps: Variant = (s as Dictionary).get("deps", null) if s is Dictionary else null
		if hits.has(nm):
			selected.append(nm)
			reasons[nm] = "changed: " + _list_text(hits[nm])
		elif relevant == 0:
			skipped.append(nm)
			reasons[nm] = "nothing that matters to a run changed"
		elif deps == null:
			selected.append(nm)
			reasons[nm] = "no saved scene: it plays whatever scene is running, so any change may reach it"
		else:
			skipped.append(nm)
			reasons[nm] = "nothing it loads changed"
	return {"mode": "impact", "selected": selected, "skipped": skipped, "reasons": reasons, "ignored": ignored,
		"unreached": unreached.slice(0, UNREACHED_SHOWN), "unreached_count": unreached.size()}


static func _k(path: String, ci: bool) -> String:
	return path.to_lower() if ci else path


static func _all(names: Array, why: String, ignored: int) -> Dictionary:
	var reasons := {}
	for n in names:
		reasons[n] = "all suites: " + why
	return {"mode": "all", "selected": names.duplicate(), "skipped": [], "reasons": reasons, "ignored": ignored,
		"unreached": [], "unreached_count": 0, "why": why}


static func _list_text(files: Array) -> String:
	var shown := PackedStringArray()
	for f in files.slice(0, REASON_FILES):
		shown.append(str(f))
	var text := ", ".join(shown)
	if files.size() > REASON_FILES:
		text += " (+%d more)" % (files.size() - REASON_FILES)
	return text


## What a selection would have skipped, against the verdicts of a run of everything ({name: verdict}).
static func compare(selection: Dictionary, results: Dictionary) -> Dictionary:
	var selected: Array = selection.get("selected", []) if selection.get("selected", []) is Array else []
	var skipped: Array = selection.get("skipped", []) if selection.get("skipped", []) is Array else []
	var checked := 0
	var failed: Array = []
	var blocked: Array = []
	for n in skipped:
		if not results.has(n):
			continue
		checked += 1
		match str(results[n]):
			"fail":
				failed.append(n)
			"blocked":
				blocked.append(n)
	return {"would_run": selected.size(), "would_skip": skipped.size(), "checked": checked,
		"skipped_failed": failed, "skipped_blocked": blocked, "false_negatives": failed.size()}


# ---------------------------------------------------------------- what a suite loads

## Every file (and folder / name prefix) reachable from `roots`, sorted. `memo` keeps each file's direct
## dependencies across calls, so the suites of one run_all walk each file once.
static func closure(roots: Array, global_classes: Dictionary, memo: Dictionary) -> Array:
	var seen := {}
	var stack: Array = []
	for r in roots:
		stack.append(str(r))
	var uid_cache := {}
	while not stack.is_empty():
		var p: String = stack.pop_back()
		if p.is_empty() or seen.has(p):
			continue
		seen[p] = true
		if p.ends_with("/") or p.get_file().get_extension().is_empty():
			continue  # a folder or the front of a name: everything under it counts, nothing in it is walked
		for d in deps_of(p, global_classes, memo, uid_cache):
			if not seen.has(d):
				stack.append(d)
	var out: Array = seen.keys()
	out.sort()
	return out


## A file's direct dependencies: what a scene or resource refers to (its ext_resources), what a script names by
## a literal path (a file, a folder, the front of a template) or by a global class. [] for a file that is gone,
## one outside the project, and anything that refers to nothing (an image).
static func deps_of(path: String, global_classes: Dictionary, memo: Dictionary, uid_cache: Dictionary = {}) -> Array:
	if memo.has(path):
		return memo[path]
	var out: Array = []
	memo[path] = out
	if path.contains("..") or not (path.begins_with("res://") or path.begins_with("user://")) or not FileAccess.file_exists(path):
		return out
	_compile()
	match path.get_extension().to_lower():
		"tscn", "tres":
			for line in FileAccess.get_file_as_string(path).split("\n"):
				if not line.begins_with("[ext_resource"):
					continue
				var dep := ""
				var pm := _re_ext_path.search(line)
				if pm != null:
					dep = pm.get_string(1)
				if (dep.is_empty() or not FileAccess.file_exists(dep)):
					var um := _re_ext_uid.search(line)
					if um != null:
						var up := _uid_cached(um.get_string(1), uid_cache)
						if not up.is_empty():
							dep = up
				_add(out, dep)
		"gd":
			var text := FileAccess.get_file_as_string(path)
			for m in _re_literal.search_all(text):
				var lit := m.get_string(1) if not m.get_string(1).is_empty() else m.get_string(2)
				var lp := _uid_cached(lit, uid_cache) if lit.begins_with("uid://") else _literal_path(lit)
				_add(out, lp)
			if not global_classes.is_empty():
				var named := {}
				for m in _re_ident.search_all(text):
					named[m.get_string(0)] = true
				for cls in named:
					if global_classes.has(cls):
						var cp := str(global_classes[cls])
						if cp != path:
							_add(out, cp)
		"scn", "res":
			for d in ResourceLoader.get_dependencies(path):
				var parts := str(d).split("::")
				var dep := ""
				for part in parts:
					if part.begins_with("res://"):
						dep = part
				if dep.is_empty() and str(parts[0]).begins_with("uid://"):
					dep = _uid_cached(parts[0], uid_cache)
				_add(out, dep)
	return out


static func _add(out: Array, dep: String) -> void:
	if not dep.is_empty() and not dep.contains("..") and not out.has(dep):
		out.append(dep)


static func _uid_cached(text: String, cache: Dictionary) -> String:
	if not cache.has(text):
		cache[text] = uid_path(text)
	return cache[text]


static func _compile() -> void:
	if _re_ext_path != null:
		return
	_re_ext_path = RegEx.create_from_string("\\bpath=\"([^\"]*)\"")
	_re_ext_uid = RegEx.create_from_string("\\buid=\"(uid://[^\"]*)\"")
	_re_literal = RegEx.create_from_string("\"((?:res|uid)://[^\"\\n]*)\"|'((?:res|uid)://[^'\\n]*)'")
	_re_ident = RegEx.create_from_string("\\b[A-Z][A-Za-z0-9_]*\\b")


## What a literal path in a script stands for: the file, the folder, the front of a name it builds (cut at the
## first % or {), or "" when it says nothing ("res://", "res://{dir}/a.tres", '..').
static func _literal_path(text: String) -> String:
	var t := text.strip_edges()
	if not t.begins_with("res://") or t.contains(".."):
		return ""
	var cut := t.length()
	for ch in ["%", "{"]:
		var i := t.find(ch)
		if i >= 0:
			cut = mini(cut, i)
	var head := t.substr(0, cut)
	return "" if head.length() <= "res://".length() else head


## A suite's dependencies: {deps: the closure of its scene (null when it has none: it plays whatever is running),
## own: its file and its project-local screenshot baselines}.
static func suite_deps(doc: Dictionary, suite_file: String, global_classes: Dictionary, memo: Dictionary) -> Dictionary:
	var own: Array = [suite_file]
	var asserts: Variant = doc.get("asserts", [])
	if asserts is Array:
		for a in asserts:
			if not (a is Dictionary) or str((a as Dictionary).get("type", "")).to_lower() != "screenshot":
				continue
			var b := str((a as Dictionary).get("baseline", "")).strip_edges()
			if b.is_empty():
				continue
			if not b.contains("://"):
				b = "%s/baselines/%s" % [TestDir.root(), b if b.get_extension().to_lower() == "png" else b + ".png"]
			if b.begins_with("res://") and not b.contains("..") and not own.has(b):
				own.append(b)
	var scene := str(doc.get("scene", "")).strip_edges() if doc.get("scene") != null else ""
	return {"deps": null if scene.is_empty() else closure([scene], global_classes, memo), "own": own}


## The file a uid:// names, or "" (not a uid, or one this project does not know).
static func uid_path(text: String) -> String:
	var t := text.strip_edges()
	if not t.begins_with("uid://"):
		return ""
	var id := ResourceUID.text_to_id(t)
	if id == ResourceUID.INVALID_ID or not ResourceUID.has_id(id):
		return ""
	return ResourceUID.get_id_path(id)


## The res:// files of the project's autoloads.
static func autoload_roots() -> Array:
	var out: Array = []
	for prop in ProjectSettings.get_property_list():
		var name := str(prop.get("name", ""))
		if not name.begins_with("autoload/"):
			continue
		var p := _setting_path(str(ProjectSettings.get_setting(name, "")).trim_prefix("*"))
		if not p.is_empty() and not out.has(p):
			out.append(p)
	return out


## What every run depends on: the autoloads, and every resource a project setting names (the theme, the bus
## layout, translations), except the settings only the editor reads.
static func global_roots() -> Array:
	var out := autoload_roots()
	for prop in ProjectSettings.get_property_list():
		var name := str(prop.get("name", ""))
		var editor_only := false
		for pre in EDITOR_ONLY_SETTINGS:
			if name.begins_with(pre):
				editor_only = true
		if editor_only or not ProjectSettings.has_setting(name):
			continue
		var v: Variant = ProjectSettings.get_setting(name)
		var values: Array = []
		if v is String or v is StringName:
			values.append(str(v))
		elif v is PackedStringArray or v is Array:
			for e in v:
				if e is String or e is StringName:
					values.append(str(e))
		for s in values:
			var p := _setting_path(s)
			if not p.is_empty() and not out.has(p):
				out.append(p)
	return out


static func _setting_path(value: String) -> String:
	var s := value.strip_edges()
	if s.begins_with("uid://"):
		return uid_path(s)
	if s.begins_with("res://") and s.length() > "res://".length() and not s.contains(".."):
		return s
	return ""


## {class_name: script path} of the project's global classes.
static func global_classes() -> Dictionary:
	var out := {}
	for c in ProjectSettings.get_global_class_list():
		if c is Dictionary:
			out[str((c as Dictionary).get("class", ""))] = str((c as Dictionary).get("path", ""))
	return out


# ---------------------------------------------------------------- git

## What changed in the project folder since `ref`: the diff (edited, added, deleted) and the untracked files,
## relative to the project, nothing outside it. {files, count, capped} or {error}.
static func changed_files(project_dir: String, ref: String, git_exe: String = "git") -> Dictionary:
	var why := ref_error(ref)
	if not why.is_empty():
		return {"error": "since: " + why}
	var top := _git(git_exe, ["-C", project_dir, "rev-parse", "--is-inside-work-tree"])
	if Subprocess.not_started(int(top["rc"]), str(top["text"]), git_exe, GIT_CODES):
		return {"error": "git did not start (%s): since= needs the git command on PATH (install Git, or start the editor from a shell that has it)" % git_exe}
	if int(top["rc"]) != 0 or not _lines(str(top["text"])).has("true"):
		return {"error": "the project folder is not inside a git repository, so since= has nothing to compare with: commit the project to git, or run op=run_all without since"}
	var diff := _git(git_exe, ["-C", project_dir, "-c", "core.quotepath=false", "diff", "--name-only", "--relative", ref, "--"])
	if int(diff["rc"]) != 0:
		var msg := str(diff["text"]).strip_edges()
		if Subprocess.not_started(int(diff["rc"]), msg, git_exe, GIT_CODES):
			return {"error": "git did not start (%s): since= needs the git command on PATH" % git_exe}
		if msg.contains("unknown revision") or msg.contains("bad revision") or msg.contains("ambiguous argument") or msg.contains("bad object") or msg.contains("invalid object"):
			return {"error": "git does not know the ref '%s' (%s): use a branch, a tag, a commit or HEAD~N" % [ref, msg.left(200)]}
		return {"error": "git diff against '%s' failed (exit %d): %s" % [ref, int(diff["rc"]), msg.left(300)]}
	var files: Array = []
	var seen := {}
	var capped := _collect(files, seen, str(diff["text"]), CHANGED_MAX)
	if not capped:
		var untracked := _git(git_exe, ["-C", project_dir, "-c", "core.quotepath=false", "ls-files", "--others", "--exclude-standard"])
		if int(untracked["rc"]) == 0:
			capped = _collect(files, seen, str(untracked["text"]), CHANGED_MAX)
	return {"files": files, "count": files.size(), "capped": capped}


## git with its arguments as an array (no shell). stderr is read only when it failed, for the message: a
## warning on a good run (line endings) is not a changed path.
static func _git(git_exe: String, args: Array) -> Dictionary:
	var out: Array = []
	var rc := OS.execute(git_exe, PackedStringArray(args), out, false)
	if rc != 0 and rc != -1:
		out.clear()
		rc = OS.execute(git_exe, PackedStringArray(args), out, true)
	return {"rc": rc, "text": "\n".join(PackedStringArray(out))}


## Add the paths of git's output to `files` once each (`seen` is shared across the diff and the untracked list),
## in the order met. Keeps cap + 1 at most (one more than the cap is all select() needs) and returns true when
## there were more than that.
static func _collect(files: Array, seen: Dictionary, text: String, cap: int) -> bool:
	for line in text.split("\n"):
		var p := _norm(line)
		if p.is_empty() or seen.has(p):
			continue
		if cap >= 0 and files.size() > cap:
			return true
		seen[p] = true
		files.append(p)
	return false


## The distinct non-empty lines of a short answer, in order.
static func _lines(text: String) -> Array:
	var out: Array = []
	_collect(out, {}, text, -1)
	return out
