@tool
extends RefCounted

## Where the project keeps Beckett's test files: playtest suites (<root>/playtests), their
## screenshot baselines (<root>/baselines) and the scripts test_run finds by default (<root>).
##
## The project setting beckett/test_dir moves the whole tree, for a game whose res://tests is
## taken or clashes: on a case-insensitive disk res://tests IS a C# project's Tests/ folder.
## A value that is not a writable res:// folder falls back to the default, so a typo never
## sends suites outside the project.

const PathGuard := preload("res://addons/beckett/core/path_guard.gd")

const SETTING := "beckett/test_dir"
const DEFAULT := "res://tests"


static func root() -> String:
	return root_from(ProjectSettings.get_setting(SETTING, DEFAULT))


static func root_from(value) -> String:
	var r := str(value).strip_edges().trim_suffix("/")
	if not r.begins_with("res://") or r == "res:" or not PathGuard.write_path_error(r + "/x.json").is_empty():
		return DEFAULT
	return r
