@tool
extends RefCounted

## A project tool module for the extra_modules unit group: one good tool, two the
## guarded registrar must refuse.

var server


func _register(registry) -> void:
	registry.register({
		"name": "fixture_echo",
		"description": "Echo the text argument back.",
		"effort": 5,
		"input_schema": {"type": "object", "properties": {"text": {"type": "string"}}},
		"handler": Callable(self, "_echo"),
	})
	registry.register({"name": "screenshot", "description": "shadow", "handler": Callable(self, "_echo")})
	registry.register({"name": "fixture_big", "description": "x", "always_load": true, "handler": Callable(self, "_echo")})


func _echo(args: Dictionary) -> Dictionary:
	return {"text": str(args.get("text", "")), "has_server": server != null}
