extends RefCounted
## One deliberate palm sweep, followed by return to its origin or close/open to rearm.
const HANDS := ["right_hand", "left_hand"]
const READY_SECONDS := 0.07
const STABLE_METRES := 0.02
const SWIPE_METRES := 0.16
const MIN_SPEED := 0.25
const MAX_SECONDS := 0.8
const RETURN_METRES := 0.06
const CLOSE_SECONDS := 0.12
var states := {}
var epoch := -1

func cancel() -> void:
	for side in states.keys():
		if states[side].phase not in ["locked", "returning", "blocked"]:
			states.erase(side)
			continue
		states[side].phase = "blocked"
		states[side].released = false
		states[side].closed = 0.0

func _settle(sample: Dictionary, head: Transform3D, scale: float) -> Dictionary:
	var forward := -head.basis.z; forward.y = 0
	return {"phase":"settling", "anchor":sample.position, "last":sample.position, "stable":0.0, "age":0.0,
		"basis":Basis(forward.normalized().cross(Vector3.UP),Vector3.UP,-forward.normalized()), "head":head,
		"scale":scale, "provider":sample.get("provider", "joints"), "space":sample.get("space", Transform3D.IDENTITY),
		"closed":0.0, "released":false}

func update(inputs: Dictionary, enabled: bool, pinch_busy: bool, head: Transform3D, scale: float,
		content_epoch: int, delta: float) -> Array[Dictionary]:
	var actions: Array[Dictionary] = []
	if content_epoch != epoch:
		# Keep the shot's return lock across the very navigation it triggered.
		for side in states.keys():
			if states[side].phase != "locked": states.erase(side)
		epoch = content_epoch
	var dt := clampf(delta, 0.0, 0.05)
	enabled = enabled and head.is_finite() and is_finite(scale) and scale > 0 \
		and Vector2(head.basis.z.x, head.basis.z.z).length_squared() > 0.001
	for side in HANDS:
		var sample: Dictionary = inputs.get(side, {}).get("palm", {})
		var tracked: bool = inputs.get(side, {}).get("source", "none") == "hand" and sample.get("tracked", false) \
			and sample.get("position") is Vector3 and sample.position.is_finite()
		if not enabled or pinch_busy or sample.get("blocked", false):
			if states.has(side):
				var held: Dictionary = states[side]
				if held.phase not in ["locked", "returning", "blocked"]:
					states.erase(side)
					continue
				held.phase = "blocked"
				if pinch_busy or sample.get("pinched", false): held.released = true
				elif tracked and not sample.get("open", false):
					held.closed += dt
					if held.closed >= CLOSE_SECONDS: held.released = true
			continue
		if not tracked:
			if states.has(side) and states[side].phase not in ["locked","blocked"]: states.erase(side)
			continue
		if not states.has(side):
			if sample.get("eligible", false): states[side] = _settle(sample, head, scale)
			continue
		var state: Dictionary = states[side]
		if sample.get("provider", "joints") != state.provider or sample.get("space", Transform3D.IDENTITY) != state.space or not is_equal_approx(scale, state.scale):
			state.phase = "blocked"; state.released = false; state.closed = 0.0
			state.provider = sample.get("provider", "joints"); state.space = sample.get("space", Transform3D.IDENTITY); state.scale = scale
		if not sample.get("open", false) or sample.get("pinched", false):
			state.closed += dt
			if state.closed >= CLOSE_SECONDS: state.released = true
			if state.phase not in ["locked","blocked"]: state.phase = "blocked"
			continue
		state.closed = 0.0
		if not sample.get("eligible", false):
			# A brief turn/region excursion cancels only the pending trajectory.
			# The return lock after a successful swipe must still survive it.
			if state.phase not in ["locked","blocked"]: states.erase(side)
			continue
		var point: Vector3 = sample.position
		if state.phase in ["locked","blocked"]:
			var returned: bool = state.phase == "locked" and point.distance_to(state.anchor) / scale <= RETURN_METRES
			if not state.released and not returned: continue
			states[side] = _settle(sample, head, scale)
			if returned and not state.released: states[side].phase = "returning"
			continue
		var offset: Vector3 = state.basis.inverse() * (point-state.anchor) / scale
		if point.distance_to(state.last) / scale > 0.08:
			states[side] = _settle(sample, head, scale)
			continue
		state.last = point
		if state.phase == "returning":
			# Finish the return stroke before accepting a new sweep from this origin.
			if offset.length() > STABLE_METRES:
				state.anchor = point; state.stable = 0.0
			else:
				state.stable += dt
				if state.stable >= READY_SECONDS:
					state.phase = "ready"; state.anchor = point; state.head = head; state.age = 0.0
			continue
		if state.phase == "settling":
			# Validate consecutive open-hand frames, retaining motion during arming.
			# Requiring a still hover here made ordinary continuous sweeps impossible.
			state.stable += dt
			state.age += dt
			if state.stable < READY_SECONDS: continue
			state.phase = "ready"
		if state.phase == "ready":
			if offset.length() <= STABLE_METRES:
				state.age = 0.0; state.head = head
				continue
			state.phase = "moving"
		state.age += dt
		if head.origin.distance_to(state.head.origin) / scale > 0.06 or head.basis.z.dot(state.head.basis.z) < cos(deg_to_rad(15.0)) \
			or state.age > MAX_SECONDS or delta > 0.1:
			states[side] = _settle(sample, head, scale)
			continue
		if absf(offset.y) > 0.08 or absf(offset.z) > 0.1:
			states[side] = _settle(sample, head, scale)
			continue
		if absf(offset.x) >= SWIPE_METRES and absf(offset.x) > maxf(absf(offset.y),absf(offset.z)) * 1.8 \
			and absf(offset.x) / maxf(dt, state.age) >= MIN_SPEED:
			state.phase = "locked"; state.released = false
			actions.append({"operation":"navigate", "direction":1 if offset.x < 0 else -1, "hand":side})
			for other in states:
				if other != side: states[other].phase = "blocked"; states[other].released = false
			return actions
	return actions
