extends RefCounted
## OpenXR joint-only input: shared by Quest and PICO, independent of vendor aim profiles.
## All distances below are in tracking-space metres; only the output ray is world-scaled.
const POSITION_FLAGS := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED
const JOINTS := [XRHandTracker.HAND_JOINT_THUMB_TIP, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
	XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL]
const PRESS_RATIO := 0.28
const RELEASE_RATIO := 0.46
const SETTLE_SECONDS := 0.06
var source := "none"
var ray: Variant = null
var down := false
var armed := false
var _settled := 0.0

static func is_optical(tracker: XRHandTracker) -> bool:
	return tracker != null and tracker.has_tracking_data and tracker.hand_tracking_source in [
		XRHandTracker.HAND_TRACKING_SOURCE_UNKNOWN, XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED]

static func sample(tracker: XRHandTracker, hand: String, head: Transform3D, space: Transform3D, scale: float) -> Dictionary:
	if not is_optical(tracker): return {}
	# Preserve optical ownership on invalid joints; never fall back to an emulated trigger.
	var result := {"source": "hand"}
	var points: Array[Vector3] = []
	for joint in JOINTS:
		if tracker.get_hand_joint_flags(joint) & POSITION_FLAGS != POSITION_FLAGS: return result
		var point := tracker.get_hand_joint_transform(joint).origin
		if not point.is_finite(): return result
		points.append(point)
	var width := points[2].distance_to(points[3])
	if width < 0.025 or width > 0.14: return result
	var pinch := (points[0] + points[1]) * 0.5
	var position := space * (pinch * scale)
	# A shoulder-to-pinch ray stays stable while fingers close, including on runtimes
	# without hand aim. Head yaw defines the shoulder; looking down does not tilt it.
	var forward := -head.basis.z
	forward.y = 0
	if forward.length_squared() < 0.001: return result
	forward = forward.normalized()
	var right := forward.cross(Vector3.UP)
	var shoulder := head.origin + right * (0.16 if hand == "right_hand" else -0.16) * scale - Vector3.UP * 0.18 * scale
	var direction := position - shoulder
	# Resting hands and hands behind the head must not accidentally open the player.
	if not position.is_finite() or direction.length() < 0.12 * scale or (position - head.origin).dot(forward) < 0.08 * scale:
		return result
	result["ray"] = [position, direction.normalized()]
	result["ratio"] = points[0].distance_to(points[1]) / clampf(width, 0.045, 0.10)
	return result

func update(input: Dictionary, delta: float) -> Dictionary:
	var next_source := str(input.get("source", "none"))
	var next_ray: Variant = input.get("ray")
	var ratio := float(input.get("ratio", INF))
	if next_ray != null and (not next_ray[0].is_finite() or not next_ray[1].is_finite() or next_ray[1].length_squared() < 0.001):
		next_ray = null
	if next_source == "hand" and not is_finite(ratio): next_ray = null
	var changed := next_source != source
	var cancelled := changed or (ray != null and next_ray == null)
	if cancelled:
		down = false
		armed = false
		_settled = 0
	source = next_source
	var was_tracked := ray != null
	if next_ray != null and source == "hand" and was_tracked and not changed:
		var blend := 1.0 - exp(-25.0 * clampf(delta, 0, 0.1))
		ray = [ray[0].lerp(next_ray[0], blend), ray[1].lerp(next_ray[1], blend).normalized()]
	else:
		ray = next_ray
	var event := {"pressed": false, "released": false, "cancelled": cancelled}
	if source != "hand" or ray == null: return event
	# Reacquisition while pinching cannot activate anything. First open, then pinch.
	var opening := ratio >= RELEASE_RATIO
	var closing := ratio <= PRESS_RATIO
	if (not armed and opening) or (armed and not down and closing) or (down and opening):
		_settled += clampf(delta, 0, 0.035)
		if _settled >= SETTLE_SECONDS:
			_settled = 0
			if not armed:
				armed = true
			elif down:
				down = false
				event.released = true
			else:
				down = true
				event.pressed = true
	else:
		_settled = 0
	return event
