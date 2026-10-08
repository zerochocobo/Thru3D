extends RefCounted
## Content ownership lasts until release, including after UI/tracking/content cancellation.
const HANDS := ["left_hand", "right_hand"]
const SWIPE_METRES := 0.09
const MOVE_METRES := 0.015
const MIN_SPAN := 0.08
var owners := {}
var mode := ""
var hand := ""
var start: Variant = null
var last: Variant = null
var basis := Basis.IDENTITY
var world_scale := 1.0
var start_span := 0.0
var start_zoom := 1.0
var moved := false
var epoch := -1

func cancel() -> void:
	mode = ""
	start = null
	last = null
	moved = false

func _point(inputs: Dictionary, side: String) -> Variant:
	var point: Variant = inputs.get(side, {}).get("position")
	return point if point is Vector3 and point.is_finite() else null

func update(inputs: Dictionary, enabled: bool, zoom: float,
		head_basis: Basis, scale: float, content_epoch: int) -> Dictionary:
	var consumed: Array = owners.keys()
	var actions: Array[Dictionary] = []
	if content_epoch != epoch:
		cancel()
		epoch = content_epoch
	enabled = enabled and is_finite(scale) and scale > 0 and head_basis.is_finite()
	if not enabled: cancel()
	for side in HANDS:
		var sample: Dictionary = inputs.get(side, {})
		if sample.get("cancelled", false) or sample.get("source", "none") != "hand" or not sample.get("tracked", false):
			if owners.has(side): cancel()
			owners.erase(side)
			continue
		if enabled and sample.get("pressed", false) and not owners.has(side):
			owners[side] = true
			if side not in consumed: consumed.append(side)
			if mode.is_empty() and owners.size() == 1:
				mode = "single"
				hand = side
				start = _point(inputs, side)
				last = start
				# Freeze the axes at gesture start; head turns do not become swipes.
				var forward := -head_basis.z
				forward.y = 0
				if forward.length_squared() < 0.001: cancel(); continue
				basis = Basis(forward.normalized().cross(Vector3.UP), Vector3.UP, -forward.normalized())
				world_scale = scale
				moved = false
			elif mode == "single" and side != hand:
				var left: Variant = _point(inputs, HANDS[0])
				var right: Variant = _point(inputs, HANDS[1])
				if left == null or right == null: cancel(); continue
				start_span = left.distance_to(right) / scale
				if start_span < MIN_SPAN: cancel(); continue
				mode = "dual"
				start_zoom = zoom
	if mode == "dual":
		var left: Variant = _point(inputs, HANDS[0])
		var right: Variant = _point(inputs, HANDS[1])
		if not inputs.get(HANDS[0], {}).get("down", false) or not inputs.get(HANDS[1], {}).get("down", false):
			actions.append({"operation": "finish"})
			cancel()
			# Finish and release the two-hand gesture before starting a new swipe.
		elif left == null or right == null or not is_equal_approx(scale, world_scale):
			cancel()
		else:
			var span: float = left.distance_to(right) / world_scale
			if span < MIN_SPAN * 0.5: cancel()
			else: actions.append({"operation": "zoom", "value": start_zoom * span / start_span})
	elif mode == "single":
		var sample: Dictionary = inputs.get(hand, {})
		var point: Variant = _point(inputs, hand)
		if not is_equal_approx(scale, world_scale) or ((start == null) != (point == null)):
			cancel()
		else:
			var offset: Vector3 = Vector3.ZERO if start == null or point == null else basis.inverse() * (point - start) / world_scale
			if offset.length() >= MOVE_METRES: moved = true
			last = point
			if sample.get("released", false):
				if not moved: actions.append({"operation": "tap"})
				elif absf(offset.x) >= SWIPE_METRES and absf(offset.x) > maxf(absf(offset.y), absf(offset.z)) * 1.5:
					actions.append({"operation": "navigate", "direction": 1 if offset.x < 0 else -1, "hand": hand})
				cancel()
	for side in HANDS:
		if not inputs.get(side, {}).get("down", false): owners.erase(side)
	return {"consumed": consumed, "actions": actions}
