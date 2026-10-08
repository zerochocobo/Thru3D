extends RefCounted

var left_latched := false
var right_latched := false
## The right stick is zooming an immersive view: it stays zoom until it returns to center.
var right_zooming := false

## UI captures own the input until each stick returns to center.
func suspend() -> void:
	left_latched = true
	right_latched = true
	right_zooming = false

# One command per deflection; return to center before changing direction/action.
# With [zoom] (immersive views) the right stick's up/down zooms continuously instead of volume.
func poll(left: Vector2, right: Vector2, zoom: bool = false) -> Array[Dictionary]:
	var actions: Array[Dictionary] = []
	for hand in ["left", "right"]:
		var stick: Vector2 = left if hand == "left" else right
		if not is_finite(stick.x) or not is_finite(stick.y):
			continue
		if stick.length() < 0.3:
			if hand == "left":
				left_latched = false
			else:
				right_latched = false
				right_zooming = false
			continue
		if hand == "right" and zoom and (right_zooming or (not right_latched and absf(stick.y) >= absf(stick.x))):
			right_zooming = true
			right_latched = true
			actions.append({"operation": "zoom", "amount": stick.y})
			continue
		var latched := left_latched if hand == "left" else right_latched
		if latched:
			continue
		# Cardinal pushes only: a diagonal does nothing (a stray diagonal once swapped the eyes).
		# Left up/down is the volume (up also unmutes); mute lives on the menu's volume slider.
		var action: Dictionary = {}
		if absf(stick.x) > 0.75 and absf(stick.y) < 0.3:
			var direction := 1 if stick.x > 0 else -1
			action = {"operation": "seek", "hand": hand, "direction": direction,
				"delta_ms": direction * (20000 if hand == "left" else 10000)}
		elif absf(stick.y) > 0.75 and absf(stick.x) < 0.3:
			action = {"operation": "volume", "direction": 1 if stick.y > 0 else -1}
		if not action.is_empty():
			actions.append(action)
			if hand == "left":
				left_latched = true
			else:
				right_latched = true
	return actions
