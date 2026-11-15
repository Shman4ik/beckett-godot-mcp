extends RefCounted
## Where the drive tools aim (1.17, Full edition; pack.ps1 trims this file from Lite). mcp_runtime loads it by path
## (DRIVE_AIM_PATH) and calls these statics on the script:
##   click_route          the push point of a click or a wheel notch at a control: its GUI center carried up its route
##   press_focus_refusal  why a press for that route would go to another embedded window (the focused one), or ""
##   point_focus_refusal  the same for a bare GUI point (scroll position=)
##   focused_window       the embedded window that holds focus in a viewport
##   gui_to_window        an event from the root's GUI space to window pixels, for Input.parse_input_event
## The focus rule is Godot's Viewport._sub_windows_forward_input: only a LEFT press picks the embedded window under it
## (and focuses it, or drops focus when it hits none); every other press, a wheel notch included, and every motion go
## to the focused window, wherever they were aimed. Static and stateless; the spaces are ui_inspect.gd's
## ("coordinate spaces").

const UiInspect := preload("res://addons/beckett/runtime/ui_inspect.gd")

const _BUTTON_NAMES := {
	MOUSE_BUTTON_RIGHT: "right press",
	MOUSE_BUTTON_MIDDLE: "middle press",
	MOUSE_BUTTON_WHEEL_UP: "wheel notch",
	MOUSE_BUTTON_WHEEL_DOWN: "wheel notch",
	MOUSE_BUTTON_WHEEL_LEFT: "wheel notch",
	MOUSE_BUTTON_WHEEL_RIGHT: "wheel notch",
	MOUSE_BUTTON_XBUTTON1: "extra-button press",
	MOUSE_BUTTON_XBUTTON2: "extra-button press",
}


## A click at ctrl: UiInspect.route() from ctrl's viewport, plus
##   local  ctrl's GUI center in its own viewport (what hit_along takes)
##   at     that center in the GUI space of the viewport the route lands in (rt.vp): the point pushed there
## The route's why/block/direct/hops come along as they are: a why means no click from the screen gets through.
static func click_route(ctrl: Control, scene_root: Node) -> Dictionary:
	var rt := UiInspect.route(ctrl.get_viewport(), scene_root)
	var local := UiInspect.gui_center(ctrl)
	rt["local"] = local
	rt["at"] = (rt["xf"] as Transform2D) * local
	return rt


## The visible embedded window in vp that has focus (the top-most one when several claim it), or null. Internal ones
## count: an OptionButton's open dropdown is an internal PopupMenu.
static func focused_window(vp: Viewport) -> Window:
	if vp == null or not vp.gui_embed_subwindows:
		return null
	var wins := UiInspect.collect_windows(vp)
	for i in range(wins.size() - 1, -1, -1):
		var w: Window = wins[i]
		if w.has_focus():
			return w
	return null


## Why a press of `button` pushed along rt (a click_route) would not reach its target, or "". A left press moves focus
## to what it lands on, so it is never refused. Any other goes, at each level from rt.vp down, to that level's focused
## window: fine when it is the window the route goes through, refused when it is another one.
static func press_focus_refusal(rt: Dictionary, button: int, scene_root: Node) -> String:
	if button == MOUSE_BUTTON_LEFT:
		return ""
	var hops: Array = rt.get("hops", [])
	var level: Viewport = rt.get("vp")
	var k := hops.size() - 1
	while level != null:
		var fw := focused_window(level)
		var hop: Dictionary = hops[k] if k >= 0 else {}
		if fw != null and (hop.is_empty() or hop["via"] != fw):
			return _refusal(fw, button, scene_root)
		if hop.is_empty():
			break
		level = hop["vp"]
		k -= 1
	return ""


## The same for a bare point p in vp's GUI space (scroll position=): the focused window gets the press at p, so a point
## inside it reaches what is drawn there and is fine; a point outside it reaches nothing and is refused.
static func point_focus_refusal(vp: Viewport, p: Vector2, button: int, scene_root: Node) -> String:
	if button == MOUSE_BUTTON_LEFT:
		return ""
	var fw := focused_window(vp)
	if fw == null or Rect2(Vector2(fw.position), Vector2(fw.size)).has_point(p):
		return ""
	return _refusal(fw, button, scene_root)


static func _refusal(fw: Window, button: int, scene_root: Node) -> String:
	var what: String = _BUTTON_NAMES.get(button, "press of button %d" % button)
	return "%s has focus: Godot hands a %s to the focused window wherever it is aimed, so it would not reach the target; close %s first (or left-click to move focus)" \
		% [UiInspect.path_of(fw, scene_root), what, UiInspect.path_of(fw, scene_root)]


## An event from vp's GUI space to window pixels (vp's final transform: the content-scale stretch, the KEEP margins,
## the window's own scale), which is what Input.parse_input_event takes. A mouse event's global_position follows its
## position (xformed_by leaves it behind), and a motion's relative and velocity are scaled with it. An event without a
## position (keys, actions, joypad) comes back as it is.
static func gui_to_window(ev: InputEvent, vp: Viewport) -> InputEvent:
	if ev == null or vp == null:
		return ev
	if not (ev is InputEventMouse or ev is InputEventScreenTouch or ev is InputEventScreenDrag or ev is InputEventGesture):
		return ev
	var out := ev.xformed_by(vp.get_final_transform())
	if out is InputEventMouse:
		var m := out as InputEventMouse
		m.global_position = m.position
	return out
