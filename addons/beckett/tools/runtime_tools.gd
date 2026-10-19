@tool
extends RefCounted
class_name BeckettRuntimeTools

## The DRIVE half of the play-test loop (L5): the agent plays the RUNNING game —
## injects input, clicks UI and 3D objects, types into fields, drags and scrolls,
## writes live properties and calls live methods, records and replays input, and
## freezes / frame-steps the simulation. The READ half lives in
## runtime_observe_tools.gd (a core module).
##
## Local edition: this file is our own implementation, written against the MIT game
## runtime (runtime/mcp_runtime.gd), which already understands every command used
## here. Its presence is also the sentinel core/mcp_server.gd and core/runtime_bridge.gd
## look for (SENTINEL_FULL_MODULE / FULL_SENTINEL): with it on disk the effort dial goes
## to 6 and the bridge sends the drive commands. Core files stay untouched, so upstream
## Lite releases merge in without conflicts.
##
## Every handler is synchronous (the zero-sidecar rule): a call that has to wait for the
## game (a typing stream, a ui_do flow, a replay, a frame step) opens a window game-side
## and blocks the editor in MCPJobsScript.poll_until, pumping the bridge, until the
## window closes or its deadline passes.

var server  # mcp_server node (exposes .bridge)

const MCPJobsScript := preload("res://addons/beckett/core/jobs.gd")  # poll_until
const CallArgs := preload("res://addons/beckett/core/callargs.gd")  # flags arrive as text from lenient clients
const PathGuard := preload("res://addons/beckett/core/path_guard.gd")  # recordings and shaders are paths the caller names

const NOT_RUNNING := "game not running (no runtime connection). Call play_scene first, then wait_until condition=game_connected."

## Selector fields every node-targeting tool accepts (same set as runtime_observe_tools).
const SELECTOR_PROPS := {
	"path": {"type": "string", "description": "node path in the running game (name, relative, or /root/...)"},
	"class": {"type": "string", "description": "selector: class (native or class_name)"},
	"name": {"type": "string", "description": "selector: node name contains"},
	"text": {"type": "string", "description": "selector: visible text contains"},
	"nth": {"type": "integer", "description": "selector: which match (default 0)"},
	"under": {"type": "string", "description": "selector: only search below this node"},
}


func _register(registry) -> void:
	registry.register({
		"name": "simulate_input",
		"description": "Inject input into the RUNNING game: a list of wire events (key, action, mouse_button, mouse_motion, joy_button, joy_axis, touch, touch_drag), or tap={action|keycode, hold_ms} for a press-hold-release. Event shapes: help(tool=\"simulate_input\"). For frame-exact input use time_control op=step inputs_per_frame.",
		"help": "events: an array of wire events, dispatched in order in ONE game frame through Input.parse_input_event (so both _input callbacks and Input.is_action_pressed see them). Every field is optional:\n  {type:\"key\", keycode:\"Right\", pressed:true, unicode?}   keycode is the key NAME (OS.find_keycode_from_string: \"A\", \"Space\", \"Enter\", \"Escape\", \"Up\", \"F1\"...). unicode (codepoint or 1-char string) makes the key carry text.\n  {type:\"action\", action:\"jump\", pressed:true, strength:1.0}\n  {type:\"mouse_button\", button:1, position:[x,y], pressed:true}   1=left 2=right 3=middle 4/5=wheel\n  {type:\"mouse_motion\", position:[x,y], relative:[dx,dy]}\n  {type:\"joy_button\", button:0, pressed:true, device:0}\n  {type:\"joy_axis\", axis:0, value:-1..1, device:0}\n  {type:\"touch\", index:0, position:[x,y], pressed:true}\n  {type:\"touch_drag\", index:0, position:[x,y], relative:[dx,dy]}\n\nA press with no release stays held (Input.is_action_pressed stays true) until you send pressed:false. A scene restart releases everything held.\n\ntap={action:\"jump\"} or tap={keycode:\"Space\"}, hold_ms (default 100): press, let the game run for hold_ms, release. The editor blocks for the hold; the game keeps running frames in its own process.\n\nMouse positions are in the game's input space. To click UI prefer click_control (it pushes into the viewport in GUI space and checks hidden/disabled/occluded); for 3D picking use click_node3d / click_world.\n\nFrame-exact input (\"hold right for exactly 30 physics frames\"): time_control op=step frames=30 inputs_per_frame=[[press...], [], ..., [release...]].",
		"input_schema": {"type": "object", "properties": {
			"events": {"type": "array", "description": "wire events to dispatch in order (help lists the shapes)"},
			"tap": {"type": "object", "description": "{action|keycode, hold_ms?}: press, hold, release"},
		}},
		"handler": Callable(self, "_simulate_input"),
	})
	registry.register({
		"name": "click_button_by_text",
		"description": "Press a Button in the RUNNING game by its visible text (contains match; emits 'pressed' like a real click, refuses disabled buttons). nth picks among matches, under= scopes the search, all=true lists the matches without clicking.",
		"input_schema": {"type": "object", "properties": {
			"text": {"type": "string", "description": "button text contains"},
			"nth": {"type": "integer", "description": "which match (default 0)"},
			"under": {"type": "string", "description": "only search below this node"},
			"all": {"type": "boolean", "description": "list the matches instead of clicking"},
		}, "required": ["text"]},
		"handler": Callable(self, "_click_button_by_text"),
	})
	registry.register({
		"name": "click_control",
		"description": "Click any Control in the RUNNING game at its center, pushed into the viewport in GUI space (works through stretch/content scale). Target by path or selector (class/name/text/nth/under; bare text means a button). Reports clicked:false with the reason when the control is hidden, disabled, clipped or occluded instead of faking a hit; scrolls clipped controls into view.",
		"input_schema": {"type": "object", "properties": _with_selector({
			"button": {"type": "integer", "description": "mouse button (default 1 = left)"},
		})},
		"handler": Callable(self, "_click_control"),
	})
	registry.register({
		"name": "click_node3d",
		"description": "Click a 3D node in the RUNNING game: projects its visible center through the active Camera3D and injects hover+press+release there, for games that pick with CollisionObject3D input events or a camera raycast. Says so when the point is behind the camera or off-screen.",
		"input_schema": {"type": "object", "properties": _with_selector({
			"button": {"type": "integer", "description": "mouse button (default 1 = left)"},
		})},
		"handler": Callable(self, "_click_node3d"),
	})
	registry.register({
		"name": "click_world",
		"description": "Click a 3D WORLD position [x,y,z] in the RUNNING game (unprojected through the active Camera3D): ground targets, move-to clicks, RTS selection.",
		"input_schema": {"type": "object", "properties": {
			"position": {"type": "array", "description": "[x, y, z] world position"},
			"button": {"type": "integer", "description": "mouse button (default 1 = left)"},
		}, "required": ["position"]},
		"handler": Callable(self, "_click_world"),
	})
	registry.register({
		"name": "scroll",
		"description": "Mouse-wheel scroll in the RUNNING game at a Control (path/selector) or at position=[x,y] (GUI space). amount>0 scrolls down, <0 up; |amount| is the number of notches.",
		"input_schema": {"type": "object", "properties": _with_selector({
			"position": {"type": "array", "description": "[x, y] in GUI space instead of a target"},
			"amount": {"type": "integer", "description": "notches; >0 down, <0 up (default 1)"},
		})},
		"handler": Callable(self, "_scroll"),
	})
	registry.register({
		"name": "drag",
		"description": "Press, glide and release in the RUNNING game: sliders, drag-and-drop, camera pans. from/to are [x,y] in GUI space, or from_path/to_path name Controls whose centers are used. steps = interpolated motion events (default 8).",
		"input_schema": {"type": "object", "properties": {
			"from": {"type": "array", "description": "[x, y] start (GUI space)"},
			"to": {"type": "array", "description": "[x, y] end (GUI space)"},
			"from_path": {"type": "string", "description": "start at this Control's center"},
			"to_path": {"type": "string", "description": "end at this Control's center"},
			"button": {"type": "integer", "description": "mouse button (default 1)"},
			"steps": {"type": "integer", "description": "motion events between press and release (1..60, default 8)"},
		}},
		"handler": Callable(self, "_drag"),
	})
	registry.register({
		"name": "get_control_rect",
		"description": "Where a Control of the RUNNING game is: gui_rect/gui_center (what click/drag/scroll take) and screen_rect/screen_center (screenshot pixels, stretch included).",
		"readonly": true,
		"input_schema": {"type": "object", "properties": _with_selector({})},
		"handler": Callable(self, "_get_control_rect"),
	})
	registry.register({
		"name": "find_ui_elements",
		"description": "List the interactive Controls of the RUNNING game (buttons, fields, sliders, toggles...) with path, class, text, rect and state, filtered by text and/or class. Cheaper than ui_snapshot when you only need click targets; feed a path into click_control.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"text": {"type": "string", "description": "text contains (case-insensitive)"},
			"class": {"type": "string", "description": "class contains, e.g. Button, LineEdit"},
			"path": {"type": "string", "description": "subtree root to scope the search"},
			"include_disabled": {"type": "boolean", "description": "keep disabled controls (default true)"},
			"max": {"type": "integer", "description": "cap on results (default 50)"},
		}},
		"handler": Callable(self, "_find_ui_elements"),
	})
	registry.register({
		"name": "type_text",
		"description": "Type text into a LineEdit/TextEdit/SpinBox of the RUNNING game as real key events (signals, filters and max_length all apply). Target by path or selector. clear (default true) empties it first, submit presses Enter, per_frame=true sends one character per frame for handlers that react per keystroke. Returns text_after.",
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string", "description": "the text field (name, relative, or /root/...)"},
			"class": {"type": "string"}, "name": {"type": "string"},
			"nth": {"type": "integer"}, "under": {"type": "string"},
			"text": {"type": "string", "description": "what to type (\\n = Enter)"},
			"clear": {"type": "boolean", "description": "empty the field first (default true)"},
			"submit": {"type": "boolean", "description": "press Enter after typing"},
			"per_frame": {"type": "boolean", "description": "one character per frame"},
			"timeout_ms": {"type": "integer", "description": "per_frame wait cap (default 10000)"},
		}, "required": ["text"]},
		"handler": Callable(self, "_type_text"),
	})
	registry.register({
		"name": "ui_do",
		"description": "Run a whole UI flow in the RUNNING game in ONE call: steps of click / type / wait / assert / input / inject / state, executed game-side frame by frame with auto-wait per step, stop on the first failure. Each step result has status pass | fail | blocked. Step grammar: help(tool=\"ui_do\").",
		"help": "steps: an array; each step is ONE of:\n  {click: \"Start\"} or {click: {path|class|name|text|nth|under}}   click_control semantics (bare text = a button)\n  {type: {path|class|name..., text, clear?, submit?}}             type_text semantics\n  {wait: {ms: 500}} | {wait: {node: \"HUD/Score\"}} | {wait: {condition: \"get_node('Player').is_on_floor()\"}}\n  {assert: {condition: \"expr\"}} | {assert: {node, property, equals}}   EVENTUALLY: polls until true or the step times out\n  {input: {events: [...]}}                                        raw simulate_input events\n  {inject: {set: [{node, property, value}], call: [{node, method, args}], frames: N}}   patch state IN (sets before calls, once all targets exist), then let the game run N frames (default 1) before the next step\n  {state: {node, path, op, value}}                                assert on the game-owned state a node exposes through _beckett_state() (get_remote_tree help explains the convention)\nAny step may carry timeout_ms (default step_timeout_ms, 5000).\n\nConditions are GDScript Expressions evaluated with the current scene root as `self`: get_node('Player').health > 0, $... is not available, use get_node / get_node_or_null.\n\nEvery step auto-waits: a control that is not clickable yet (hidden, disabled, occluded, not built yet), a field that is not there yet, a false condition just retries next frame until the step's timeout.\n\nStep status:\n  pass     the step did what it says (an assert held)\n  fail     an assert was evaluated and stayed false until the timeout, or the step is malformed\n  blocked  the step never got to a judgement: its target never appeared, a control never became clickable, a wait timed out, an inject could not be applied\n\nsettle_frames (default 2): frames between steps for the UI to react. invariants: optional rule list checked on every physics frame while the flow runs (runtime/invariants.gd grammar), reported once at the end.\n\nThe call returns when the flow ends or timeout_ms (default: steps x step timeout + 5 s, max 120 s) passes; on timeout the flow is aborted game-side.",
		"input_schema": {"type": "object", "properties": {
			"steps": {"type": "array", "description": "click/type/wait/assert/input/inject/state step objects (help lists the grammar)"},
			"step_timeout_ms": {"type": "integer", "description": "default per-step timeout (default 5000)"},
			"settle_frames": {"type": "integer", "description": "frames between steps (default 2)"},
			"invariants": {"type": "array", "description": "rules checked every frame while the flow runs"},
			"timeout_ms": {"type": "integer", "description": "overall cap for this call (max 120000)"},
		}, "required": ["steps"]},
		"handler": Callable(self, "_ui_do"),
	})
	registry.register({
		"name": "ui_audit",
		"description": "Deterministic layout QA of the RUNNING game's UI: interactive controls that are off-screen, zero-size, overlapping each other, below a touch-size floor or unreachable by keyboard, and text that no longer fits its control. Read-only, rect math instead of vision.",
		"readonly": true,
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string", "description": "subtree root to audit (default: the whole tree)"},
			"touch_min": {"type": "number", "description": "minimum touch target size in px (0 = off)"},
			"overlap_min_ratio": {"type": "number", "description": "overlap ratio that counts (default 0.25)"},
			"max": {"type": "integer", "description": "cap on issues (default 100)"},
		}},
		"handler": Callable(self, "_ui_audit"),
	})
	registry.register({
		"name": "record_input",
		"description": "Record the physical input the RUNNING game receives (keys, mouse, joypad, touch: a human playing, or injected key/mouse events; synthetic actions are not recorded). op=start begins, op=stop returns the events stamped with physics frame f; save_to writes JSON for replay_input path=.",
		"input_schema": {"type": "object", "properties": {
			"op": {"type": "string", "description": "start | stop"},
			"save_to": {"type": "string", "description": "op=stop: write the recording here (res:// or user://, .json)"},
			"max_events": {"type": "integer", "description": "op=stop: cap on events returned inline (default 200)"},
		}, "required": ["op"]},
		"handler": Callable(self, "_record_input"),
	})
	registry.register({
		"name": "replay_input",
		"description": "Replay recorded input into the RUNNING game frame-exactly: each event fires on its recorded physics frame f. Give events inline or path= a record_input JSON. The game is left FROZEN at the end so you can inspect it; unfreeze=true resumes it. Optional invariants are checked every frame.",
		"input_schema": {"type": "object", "properties": {
			"events": {"type": "array", "description": "recorded events (each with f = physics frame)"},
			"path": {"type": "string", "description": "a record_input JSON file instead of events"},
			"settle_frames": {"type": "integer", "description": "frames to run after the last event (default 4)"},
			"invariants": {"type": "array", "description": "rules checked every frame of the replay"},
			"unfreeze": {"type": "boolean", "description": "resume the game when the replay ends (default false)"},
			"timeout_ms": {"type": "integer", "description": "wait cap (default 60000, max 300000)"},
		}},
		"handler": Callable(self, "_replay_input"),
	})
	registry.register({
		"name": "time_control",
		"description": "Deterministic time for the RUNNING game: op=freeze | unfreeze | step (advance exactly N physics frames, optional inputs_per_frame) | step_until (run until a GDScript condition holds, then freeze) | time_scale (value 0.01..10) | status. Details: help(tool=\"time_control\").",
		"help": "op=freeze           pause the SceneTree (the runtime keeps answering)\nop=unfreeze         resume\nop=step frames=N    from any state: pause, run exactly N unpaused physics frames, pause again. Returns frames run and physics_frames_before/after.\n  inputs_per_frame=[[ev, ev], [], [ev]]   batch i fires on tick i of the window (simulate_input wire events). A batch longer than frames grows the window.\nop=step_until condition=\"get_node('Player').position.y > 500\"   run until the expression is true, then pause. max_frames caps frames (0 = no cap), timeout_sec caps wall time (default 10, max 120). Returns the terminator (condition | max_frames | timeout) and the last condition value. An already-true condition returns at once with frames=0.\nop=time_scale value=0.25   Engine.time_scale, clamped to 0.01..10 (0 is refused: use freeze)\nop=status           paused, time_scale, physics frame counter, whether a step window is open\n\nConditions are GDScript Expressions with the current scene root as self.\n\nThis is not the editor debugger's Suspend: the game's script debugger is untouched, this pauses the SceneTree.",
		"input_schema": {"type": "object", "properties": {
			"op": {"type": "string", "description": "freeze | unfreeze | step | step_until | time_scale | status"},
			"frames": {"type": "integer", "description": "op=step: physics frames to run (default 1)"},
			"inputs_per_frame": {"type": "array", "description": "op=step: per-tick arrays of input events"},
			"condition": {"type": "string", "description": "op=step_until: GDScript expression"},
			"max_frames": {"type": "integer", "description": "op=step_until: frame cap (0 = none)"},
			"timeout_sec": {"type": "number", "description": "op=step_until: wall-time cap (default 10)"},
			"value": {"type": "number", "description": "op=time_scale: 0.01..10"},
		}, "required": ["op"]},
		"handler": Callable(self, "_time_control"),
	})
	registry.register({
		"name": "reload_shader",
		"description": "Hot-swap an edited .gdshader into the RUNNING game: reloads it from disk past the cache and assigns it to every live ShaderMaterial using it. Compile errors appear in game_logs on the next frame; take a screenshot to see the result.",
		"input_schema": {"type": "object", "properties": {
			"path": {"type": "string", "description": "res:// path of the .gdshader"},
		}, "required": ["path"]},
		"handler": Callable(self, "_reload_shader"),
	})
	registry.register({
		"name": "runtime_call",
		"description": "Call a method on a LIVE node of the RUNNING game and return its result (arguments coerced to the method's types; node paths as arguments resolve to nodes). Target by path or selector.",
		"input_schema": {"type": "object", "properties": _with_selector({
			"method": {"type": "string", "description": "method name"},
			"args": {"type": "array", "description": "arguments (vectors as [x,y], colors as \"#rrggbb\")"},
		}), "required": ["method"]},
		"handler": Callable(self, "_runtime_call"),
	})
	registry.register({
		"name": "runtime_set_property",
		"description": "Write a property on a LIVE node of the RUNNING game and read it back: reports before/after, says when the engine clamped it, and fails when the write did not stick (read-only, or game code rewrites it each frame). Nested paths like environment:fog_density work.",
		"input_schema": {"type": "object", "properties": _with_selector({
			"property": {"type": "string", "description": "property name or nested path (a:b:c)"},
			"value": {"description": "new value (vectors as [x,y,z], colors as \"#rrggbb\", enums as int)"},
		}), "required": ["property", "value"]},
		"handler": Callable(self, "_runtime_set"),
	})


# ---------------------------------------------------------------- helpers

static func _with_selector(extra: Dictionary) -> Dictionary:
	var out := SELECTOR_PROPS.duplicate(true)
	out.merge(extra, true)
	return out


## Copy path + selector fields from tool args into a bridge cmd (twin of the helper in
## runtime_observe_tools.gd, so both halves accept the same targets).
func _add_target(cmd: Dictionary, args: Dictionary) -> void:
	for k in ["path", "class", "name", "text", "nth", "under"]:
		if args.has(k):
			cmd[k] = args[k]


func _connected() -> bool:
	return server.bridge != null and server.bridge.is_game_connected()


## Send one command: the raw reply when the game answered ok, else an {error[, suggestion]}
## handler result (check with _is_error).
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


## The game's reply as a JSON result, minus the transport fields.
static func _as_json(r: Dictionary) -> Dictionary:
	var out := r.duplicate()
	out.erase("ok")
	out.erase("_id")
	return {"json": out}


## Block the editor (pumping the bridge) until `status_cmd` reports the window closed.
## `done` decides from a status reply; returns {"reply": last} or {"timeout": true, "reply": last}.
func _poll_window(status_cmd: Dictionary, done: Callable, timeout_ms: int, interval_ms: int = 50) -> Dictionary:
	var last := {"reply": {}}
	var tick := func() -> Dictionary:
		var r: Dictionary = server.bridge.send_command(status_cmd, 2000)
		last["reply"] = r
		if not bool(r.get("ok", false)):
			return {"error": str(r.get("error", "status poll failed"))}
		return {"done": true} if bool(done.call(r)) else {}
	var res: Dictionary = MCPJobsScript.poll_until(timeout_ms, interval_ms, tick, Callable(server.bridge, "poll_once"))
	if res.has("error"):
		return {"error": res["error"], "reply": last["reply"]}
	if res.has("timeout"):
		return {"timeout": true, "reply": last["reply"]}
	return {"reply": last["reply"]}


## Let the game run for `ms` while the editor waits (bridge pumped).
func _hold(ms: int) -> void:
	MCPJobsScript.poll_until(ms, 20, func() -> Dictionary: return {}, Callable(server.bridge, "poll_once"))


# ---------------------------------------------------------------- input

func _simulate_input(args: Dictionary) -> Dictionary:
	var tap: Variant = args.get("tap", null)
	if tap is Dictionary:
		return _tap(tap as Dictionary)
	var events: Variant = args.get("events", null)
	if not (events is Array) or (events as Array).is_empty():
		return {"error": "give events=[...] (wire events) or tap={action|keycode, hold_ms}", "suggestion": "help(tool=\"simulate_input\") lists the event shapes"}
	var r := _send({"cmd": "input", "events": events})
	if _is_error(r):
		return r
	var n := int(r.get("dispatched", 0))
	var text := "dispatched %d of %d event(s)" % [n, (events as Array).size()]
	if n < (events as Array).size():
		text += " — the rest were not recognised (check type and field names: help(tool=\"simulate_input\"))"
	return {"text": text}


func _tap(tap: Dictionary) -> Dictionary:
	var ev := {}
	if tap.has("action"):
		ev = {"type": "action", "action": str(tap["action"])}
	elif tap.has("keycode") or tap.has("key"):
		ev = {"type": "key", "keycode": str(tap.get("keycode", tap.get("key", "")))}
	else:
		return {"error": "tap needs action or keycode"}
	var hold: int = clampi(int(tap.get("hold_ms", 100)), 0, 30000)
	var down := ev.duplicate()
	down["pressed"] = true
	var r := _send({"cmd": "input", "events": [down]})
	if _is_error(r):
		return r
	if int(r.get("dispatched", 0)) == 0:
		return {"error": "the game did not accept the event %s" % JSON.stringify(down)}
	if hold > 0:
		_hold(hold)
	var up := ev.duplicate()
	up["pressed"] = false
	r = _send({"cmd": "input", "events": [up]})
	if _is_error(r):
		return {"error": "pressed, but the release failed (%s): the input may still be held" % str(r["error"])}
	return {"text": "tapped %s for %d ms" % [str(ev.get("action", ev.get("keycode", ""))), hold]}


# ---------------------------------------------------------------- clicks

func _click_button_by_text(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "click_text", "text": str(args.get("text", ""))}
	for k in ["nth", "under", "all", "class"]:
		if args.has(k):
			cmd[k] = args[k]
	var r := _send(cmd)
	if _is_error(r):
		return r
	return _as_json(r)


func _click_control(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "click_control"}
	_add_target(cmd, args)
	if args.has("button"):
		cmd["button"] = args["button"]
	var r := _send(cmd)
	if _is_error(r):
		return r
	return _as_json(r)


func _click_node3d(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "click_node3d"}
	_add_target(cmd, args)
	if args.has("button"):
		cmd["button"] = args["button"]
	var r := _send(cmd)
	if _is_error(r):
		return r
	return _as_json(r)


func _click_world(args: Dictionary) -> Dictionary:
	var r := _send({"cmd": "click_world", "position": args.get("position", []), "button": int(args.get("button", 1))})
	if _is_error(r):
		return r
	return _as_json(r)


func _scroll(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "scroll", "amount": int(args.get("amount", 1))}
	if args.has("position"):
		cmd["position"] = args["position"]
	else:
		_add_target(cmd, args)
	var r := _send(cmd)
	if _is_error(r):
		return r
	return _as_json(r)


func _drag(args: Dictionary) -> Dictionary:
	var from: Variant = args.get("from", null)
	var to: Variant = args.get("to", null)
	if args.has("from_path"):
		var c := _center_of(str(args["from_path"]))
		if c.has("error"):
			return c
		from = c["center"]
	if args.has("to_path"):
		var c2 := _center_of(str(args["to_path"]))
		if c2.has("error"):
			return c2
		to = c2["center"]
	if not (from is Array and to is Array):
		return {"error": "drag needs from/to as [x, y], or from_path/to_path naming Controls"}
	var cmd := {"cmd": "drag", "from": from, "to": to}
	for k in ["button", "steps"]:
		if args.has(k):
			cmd[k] = args[k]
	var r := _send(cmd)
	if _is_error(r):
		return r
	return _as_json(r)


func _center_of(path: String) -> Dictionary:
	var r := _send({"cmd": "control_rect", "path": path})
	if _is_error(r):
		return r
	var rect: Dictionary = r.get("rect", {})
	return {"center": rect.get("gui_center", [0, 0])}


func _get_control_rect(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "control_rect"}
	_add_target(cmd, args)
	var r := _send(cmd)
	if _is_error(r):
		return r
	return {"json": r.get("rect", {})}


func _find_ui_elements(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "ui_snapshot", "interactive_only": true, "occlusion": false}
	if args.has("path"):
		cmd["path"] = args["path"]
	var r := _send(cmd, 10000)
	if _is_error(r):
		return r
	var text_q := str(args.get("text", "")).to_lower()
	var class_q := str(args.get("class", "")).to_lower()
	var keep_disabled := CallArgs.flag(args, "include_disabled", true)
	var cap: int = clampi(int(args.get("max", 50)), 1, 500)
	var found: Array = []
	var total := 0
	for c in _controls_of(r):
		if not (c is Dictionary):
			continue
		var d := c as Dictionary
		if not text_q.is_empty():
			var hay := (str(d.get("text", "")) + " " + str(d.get("placeholder", "")) + " " + str(d.get("tooltip", ""))).to_lower()
			if not hay.contains(text_q):
				continue
		if not class_q.is_empty() and not (str(d.get("class", "")).to_lower().contains(class_q) or str(d.get("script", "")).to_lower().contains(class_q)):
			continue
		if not keep_disabled and bool(d.get("disabled", false)):
			continue
		total += 1
		if found.size() < cap:
			found.append(d)
	var out := {"elements": found, "count": found.size()}
	if total > found.size():
		out["truncated"] = true
		out["total"] = total
	return {"json": out}


## The control list of a ui_snapshot reply, whatever key the walker files it under.
static func _controls_of(snap: Dictionary) -> Array:
	for k in ["controls", "nodes", "elements"]:
		if snap.get(k) is Array:
			return snap[k]
	return []


# ---------------------------------------------------------------- typing

func _type_text(args: Dictionary) -> Dictionary:
	var target := {}
	for k in ["path", "class", "name", "nth", "under"]:
		if args.has(k):
			target[k] = args[k]
	var reentered := _ensure_editing(target)
	var cmd := {"cmd": "type_text", "text": str(args.get("text", ""))}
	cmd.merge(target)
	for k in ["clear", "submit", "per_frame"]:
		if args.has(k):
			cmd[k] = args[k]
	var r := _send(cmd)
	if _is_error(r):
		return r
	if not bool(r.get("per_frame", false)):
		var res := _as_json(r)
		if reentered:
			res["json"]["note"] = "entered the LineEdit's edit mode before typing (Godot 4.4+ can leave a focused LineEdit not editing, e.g. after a submit, and then drops every key)"
		if int(r.get("typed", 0)) > 0 and r.has("text_after") and not str(r["text_after"]).contains(str(args.get("text", "")).replace("\n", "")):
			res["json"]["warning"] = "the field does not contain what was typed: it filtered, capped or ignored the keys"
		return res
	var timeout: int = clampi(int(args.get("timeout_ms", 10000)), 100, 120000)
	var w := _poll_window({"cmd": "type_status"}, func(s: Dictionary) -> bool: return bool(s.get("done", false)), timeout, 30)
	if w.has("error"):
		return {"error": str(w["error"])}
	var st: Dictionary = w["reply"]
	var out := st.duplicate()
	out.erase("ok")
	out.erase("_id")
	if w.has("timeout"):
		out["warning"] = "still typing after %d ms (%d typed); poll again with a fresh type_text call or raise timeout_ms" % [timeout, int(st.get("typed", 0))]
	return {"json": out}


## Godot 4.4+ LineEdit has an edit mode separate from focus: after text_submitted it keeps
## focus but stops editing (unless keep_editing_on_text_submit), and the runtime's
## grab_focus() is then a no-op, so every key of the next type_text is dropped. Re-enter edit
## mode first. Only LineEdit answers is_editing (TextEdit and older engines do not), and a
## failed probe changes nothing. True when edit mode had to be re-entered.
func _ensure_editing(target: Dictionary) -> bool:
	var probe := {"cmd": "call", "method": "is_editing", "args": []}
	probe.merge(target)
	var r: Dictionary = server.bridge.send_command(probe)
	if not bool(r.get("ok", false)) or not (r.get("result") is bool) or bool(r["result"]):
		return false
	var edit := {"cmd": "call", "method": "edit", "args": []}
	edit.merge(target)
	return bool(server.bridge.send_command(edit).get("ok", false))


# ---------------------------------------------------------------- ui_do / ui_audit

func _ui_do(args: Dictionary) -> Dictionary:
	var steps: Variant = args.get("steps", null)
	if not (steps is Array) or (steps as Array).is_empty():
		return {"error": "steps must be a non-empty array", "suggestion": "help(tool=\"ui_do\") lists the step grammar"}
	var cmd := {"cmd": "ui_do_open", "steps": steps}
	for k in ["step_timeout_ms", "settle_frames", "invariants"]:
		if args.has(k):
			cmd[k] = args[k]
	var r := _send(cmd)
	if _is_error(r):
		return r
	var step_to: int = maxi(100, int(args.get("step_timeout_ms", 5000)))
	var default_total: int = (steps as Array).size() * step_to + 5000
	var timeout: int = clampi(int(args.get("timeout_ms", default_total)), 500, 120000)
	var w := _poll_window({"cmd": "ui_do_status"}, func(s: Dictionary) -> bool: return not bool(s.get("active", true)), timeout)
	if w.has("error"):
		return {"error": str(w["error"])}
	var st: Dictionary = w["reply"]
	var out := st.duplicate()
	out.erase("ok")
	out.erase("_id")
	if w.has("timeout"):
		server.bridge.send_command({"cmd": "ui_do_abort"}, 2000)
		out["aborted"] = true
		out["warning"] = "the flow was still running after %d ms and was aborted at step %d" % [timeout, int(st.get("current", 0))]
	out["passed"] = not bool(out.get("failed", false)) and not out.has("aborted")
	return {"json": out}


func _ui_audit(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "ui_audit"}
	for k in ["path", "touch_min", "overlap_min_ratio", "max"]:
		if args.has(k):
			cmd[k] = args[k]
	var r := _send(cmd, 10000)
	if _is_error(r):
		return r
	return _as_json(r)


# ---------------------------------------------------------------- record / replay

func _record_input(args: Dictionary) -> Dictionary:
	var op := str(args.get("op", "")).to_lower()
	match op:
		"start":
			var r := _send({"cmd": "record_start"})
			if _is_error(r):
				return r
			return {"text": "recording input; play (or inject), then record_input op=stop"}
		"stop":
			var save_to := str(args.get("save_to", ""))
			if not save_to.is_empty():
				var werr: String = PathGuard.write_path_error(save_to)
				if not werr.is_empty():
					return {"error": werr}
			var r := _send({"cmd": "record_stop"})
			if _is_error(r):
				return r
			var events: Array = r.get("events", [])
			var out := {"count": events.size()}
			if not save_to.is_empty():
				var saved := _save_json(save_to, {"beckett_recording": 1, "events": events})
				if not saved.is_empty():
					return {"error": "recorded %d event(s) but could not save %s: %s" % [events.size(), save_to, saved]}
				out["saved_to"] = save_to
			var cap: int = clampi(int(args.get("max_events", 200)), 0, 5000)
			out["events"] = events.slice(0, cap)
			if events.size() > cap:
				out["events_truncated"] = true
			return {"json": out}
	return {"error": "op must be start or stop"}


func _save_json(path: String, data: Variant) -> String:
	var dir := path.get_base_dir()
	if not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
		var derr := DirAccess.make_dir_recursive_absolute(dir)
		if derr != OK:
			return "cannot create %s: %s" % [dir, error_string(derr)]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return error_string(FileAccess.get_open_error())
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	return ""


func _replay_input(args: Dictionary) -> Dictionary:
	var events: Variant = args.get("events", null)
	var guard := {}
	if args.has("path"):
		var path := str(args["path"])
		guard = PathGuard.check_read(path)
		if guard.has("error"):
			return guard
		if not FileAccess.file_exists(path):
			return {"error": "no recording at %s" % path}
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			events = (parsed as Dictionary).get("events", null)
		elif parsed is Array:
			events = parsed
		if not (events is Array):
			return {"error": "%s is not a recording (expected {events:[...]} or a JSON array)" % path}
	if not (events is Array):
		return {"error": "give events=[...] or path= a record_input JSON"}
	var cmd := {"cmd": "replay_open", "events": events}
	for k in ["settle_frames", "invariants"]:
		if args.has(k):
			cmd[k] = args[k]
	var r := _send(cmd)
	if _is_error(r):
		return r
	var timeout: int = clampi(int(args.get("timeout_ms", 60000)), 500, 300000)
	var w := _poll_window({"cmd": "replay_status"}, func(s: Dictionary) -> bool: return not bool(s.get("replaying", true)), timeout)
	if w.has("error"):
		return {"error": str(w["error"])}
	var st: Dictionary = w["reply"]
	var out := st.duplicate()
	out.erase("ok")
	out.erase("_id")
	out["end_frame"] = r.get("end_frame", 0)
	if w.has("timeout"):
		out["warning"] = "replay still running after %d ms (%d of %d events injected)" % [timeout, int(st.get("injected", 0)), int(st.get("total_events", 0))]
	elif CallArgs.flag(args, "unfreeze"):
		server.bridge.send_command({"cmd": "tc_unfreeze"}, 2000)
		out["paused"] = false
	else:
		out["note"] = "the game is frozen where the replay ended; time_control op=unfreeze resumes it"
	return PathGuard.noted({"json": out}, guard)


# ---------------------------------------------------------------- time control

func _time_control(args: Dictionary) -> Dictionary:
	var op := str(args.get("op", "status")).to_lower()
	match op:
		"status":
			return _tc_simple({"cmd": "tc_status"})
		"freeze":
			return _tc_simple({"cmd": "tc_freeze"})
		"unfreeze":
			return _tc_simple({"cmd": "tc_unfreeze"})
		"time_scale":
			if not args.has("value"):
				return {"error": "op=time_scale needs value (0.01..10)"}
			return _tc_simple({"cmd": "tc_time_scale", "value": float(args["value"])})
		"step":
			var cmd := {"cmd": "tc_step", "frames": maxi(1, int(args.get("frames", 1)))}
			if args.get("inputs_per_frame") is Array:
				cmd["inputs_per_frame"] = args["inputs_per_frame"]
			return _tc_window(cmd, 120000)
		"step_until":
			var cond := str(args.get("condition", "")).strip_edges()
			if cond.is_empty():
				return {"error": "op=step_until needs condition (a GDScript expression)"}
			var tsec: float = clampf(float(args.get("timeout_sec", 10.0)), 0.1, 120.0)
			var cmd2 := {"cmd": "tc_step_until", "condition": cond, "timeout_sec": tsec, "max_frames": maxi(0, int(args.get("max_frames", 0)))}
			return _tc_window(cmd2, int(tsec * 1000.0) + 5000)
	return {"error": "unknown op '%s'" % op, "suggestion": "freeze | unfreeze | step | step_until | time_scale | status"}


func _tc_simple(cmd: Dictionary) -> Dictionary:
	var r := _send(cmd)
	if _is_error(r):
		return r
	return _as_json(r)


func _tc_window(cmd: Dictionary, timeout_ms: int) -> Dictionary:
	var r := _send(cmd)
	if _is_error(r):
		return r
	if not bool(r.get("started", false)):
		return _as_json(r)  # step_until whose condition was already true: closed with 0 frames
	var w := _poll_window({"cmd": "tc_step_status"}, func(s: Dictionary) -> bool: return not bool(s.get("in_step", true)), timeout_ms, 20)
	if w.has("error"):
		return {"error": str(w["error"])}
	var st: Dictionary = w["reply"]
	var out := st.duplicate()
	out.erase("ok")
	out.erase("_id")
	if r.has("note"):
		out["note"] = r["note"]
	if str(cmd.get("cmd", "")) == "tc_step_until":
		out.erase("inputs_injected")  # the runtime does not reset this counter for step_until: it is the last step's
	if w.has("timeout"):
		out["warning"] = "the step window was still open after %d ms; time_control op=freeze closes it" % timeout_ms
	return {"json": out}


# ---------------------------------------------------------------- live writes

func _reload_shader(args: Dictionary) -> Dictionary:
	var path := str(args.get("path", ""))
	var guard := PathGuard.check_read(path)
	if guard.has("error"):
		return guard
	var r := _send({"cmd": "reload_shader", "path": path}, 10000)
	if _is_error(r):
		return r
	return PathGuard.noted(_as_json(r), guard)


func _runtime_call(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "call", "method": str(args.get("method", "")), "args": args.get("args", [])}
	_add_target(cmd, args)
	var r := _send(cmd, 10000)
	if _is_error(r):
		return r
	return _as_json(r)


func _runtime_set(args: Dictionary) -> Dictionary:
	var cmd := {"cmd": "set", "prop": str(args.get("property", "")), "value": args.get("value")}
	_add_target(cmd, args)
	var r := _send(cmd)
	if _is_error(r):
		return r
	return _as_json(r)
