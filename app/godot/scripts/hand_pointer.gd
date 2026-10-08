extends RefCounted
## Prefer the runtime's hand aim/select; joint recognition is a portability fallback.
## All distances below are in tracking-space metres; only the output ray is world-scaled.
const POSITION_FLAGS := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED
const JOINTS := [XRHandTracker.HAND_JOINT_THUMB_TIP, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
	XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL]
const PRESS_RATIO := 0.28
const RELEASE_RATIO := 0.46
const SETTLE_SECONDS := 0.06
var source := "none"
var provider := "none"
var ray: Variant = null
var down := false
var armed := false
var _settled := 0.0
var _menu_down := false

const HAND_PROFILES := ["/interaction_profiles/ext/hand_interaction_ext", "/interaction_profiles/microsoft/hand_interaction"]
const SIMPLE_PROFILE := "/interaction_profiles/khr/simple_controller"

static func is_hand_profile(tracker: XRPositionalTracker, allow_simple: bool = false) -> bool:
	return tracker != null and (tracker.get_tracker_profile() in HAND_PROFILES or
		(allow_simple and tracker.get_tracker_profile() == SIMPLE_PROFILE))

## Godot Vendors exposes XR_FB_hand_tracking_aim on a dedicated tracker (default pose).
## Action profiles expose the runtime's mapped aim and trigger_click on left/right_hand.
static func runtime_sample(tracker: XRPositionalTracker, space: Transform3D, scale: float, meta: bool) -> Dictionary:
	var result := {"source": "hand", "provider": "meta_aim" if meta else "hand_profile"}
	if tracker == null: return result
	var selected: Variant = tracker.get_input("index_pinch" if meta else "trigger_click")
	if not selected is bool: return result
	result["pinched"] = selected
	if meta:
		result["menu_pressed"] = tracker.get_input("menu_pressed") == true
		# Palm-facing system/menu gestures own the hand: never select or drag content.
		if tracker.get_input("system_gesture") == true or tracker.get_input("menu_gesture") == true:
			return result
	var pose_name := "default" if meta else "aim"
	if not tracker.has_pose(pose_name): return result
	var pose := tracker.get_pose(pose_name)
	if not pose.has_tracking_data or pose.tracking_confidence == XRPose.XR_TRACKING_CONFIDENCE_NONE: return result
	var transform := pose.transform
	if not transform.is_finite() or not space.is_finite() or not is_finite(scale) or scale <= 0: return result
	var direction := space.basis * -transform.basis.z
	if direction.length_squared() < 0.001: return result
	result["ray"] = [space * (transform.origin * scale), direction.normalized()]
	return result

static func is_optical(tracker: XRHandTracker) -> bool:
	return tracker != null and tracker.has_tracking_data and tracker.hand_tracking_source in [
		XRHandTracker.HAND_TRACKING_SOURCE_UNKNOWN, XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED]

## Motion gestures need the physical pinch, not the origin of the runtime's aim ray.
## Missing joints must not invalidate the independent official click/select path.
static func pinch_position(tracker: XRHandTracker, space: Transform3D, scale: float) -> Variant:
	if not is_optical(tracker) or not space.is_finite() or not is_finite(scale) or scale <= 0: return null
	var point := Vector3.ZERO
	for joint in [XRHandTracker.HAND_JOINT_THUMB_TIP, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP]:
		if tracker.get_hand_joint_flags(joint) & POSITION_FLAGS != POSITION_FLAGS: return null
		var tip := tracker.get_hand_joint_transform(joint).origin
		if not tip.is_finite(): return null
		point += tip * 0.5
	return space * (point * scale)

const OPEN_FINGERS := [
	[XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_RING_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP]]

## Palm motion uses optical joints independently of the optional pointing/aim pose.
static func palm_sample(tracker: XRHandTracker, hand: String, head: Transform3D, space: Transform3D, scale: float,
		meta_aim: XRPositionalTracker = null, interaction: XRPositionalTracker = null) -> Dictionary:
	if not is_optical(tracker) or not head.is_finite() or not space.is_finite() or not is_finite(scale) or scale <= 0: return {}
	var required := [XRHandTracker.HAND_JOINT_PALM, XRHandTracker.HAND_JOINT_WRIST, XRHandTracker.HAND_JOINT_THUMB_TIP,
		OPEN_FINGERS[0][0], OPEN_FINGERS[0][2], OPEN_FINGERS[3][0]]
	var points := {}
	for joint in required:
		if tracker.get_hand_joint_flags(joint) & POSITION_FLAGS != POSITION_FLAGS: return {}
		var point := tracker.get_hand_joint_transform(joint).origin
		if not point.is_finite(): return {}
		points[joint] = point
	var index: Vector3 = points[OPEN_FINGERS[0][0]]
	var pinky: Vector3 = points[OPEN_FINGERS[3][0]]
	var width := index.distance_to(pinky)
	if width < 0.035 or width > 0.13: return {}
	var wrist: Vector3 = points[XRHandTracker.HAND_JOINT_WRIST]
	var extended := 0
	for finger in OPEN_FINGERS:
		var valid := true
		for joint in finger:
			if tracker.get_hand_joint_flags(joint) & POSITION_FLAGS != POSITION_FLAGS:
				valid = false; break
			var point := tracker.get_hand_joint_transform(joint).origin
			if not point.is_finite(): valid = false; break
			points[joint] = point
		if not valid: continue
		var root: Vector3 = points[finger[0]]; var middle: Vector3 = points[finger[1]]; var tip: Vector3 = points[finger[2]]
		if (middle-root).length() >= 0.006 and (tip-middle).length() >= 0.006 \
			and (middle-root).normalized().dot((tip-middle).normalized()) >= 0.35 \
			and tip.distance_to(wrist) >= root.distance_to(wrist) + width * 0.30: extended += 1
	# A relaxed open hand often has a bent/partly occluded little finger.
	var open := extended >= 3
	var pinched: bool = points[XRHandTracker.HAND_JOINT_THUMB_TIP].distance_to(points[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP]) < width * 0.3
	var blocked := false
	var provider := "joints"
	if meta_aim != null:
		provider = "meta_aim"
		pinched = pinched or meta_aim.get_input("index_pinch") == true
		blocked = meta_aim.get_input("system_gesture") == true or meta_aim.get_input("menu_gesture") == true or meta_aim.get_input("menu_pressed") == true
	elif is_hand_profile(interaction, true):
		provider = "hand_profile"
		pinched = pinched or interaction.get_input("trigger_click") == true
	var position: Vector3 = space * (points[XRHandTracker.HAND_JOINT_PALM] * scale)
	var normal: Vector3 = space.basis * (index-pinky).cross(points[XRHandTracker.HAND_JOINT_PALM]-wrist)
	if hand == "left_hand": normal = -normal
	var forward := -head.basis.z; forward.y = 0
	if forward.length_squared() < 0.001 or normal.length_squared() < 0.000001: return {}
	forward = forward.normalized()
	var right := forward.cross(Vector3.UP)
	var offset := (position-head.origin) / scale
	var in_front := offset.dot(forward) >= 0.08 and offset.dot(forward) <= 1.1 \
		and absf(offset.dot(right)) <= 0.8 and offset.y >= -0.8 and offset.y <= 0.4
	var facing_dot := normal.normalized().dot((head.origin-position).normalized())
	# Side-on sweeps are natural too; runtime system gestures retain priority.
	var facing := facing_dot < 0.65
	return {"tracked": true, "open": open, "pinched": pinched, "blocked": blocked,
		"eligible": in_front and facing and open and not pinched and not blocked,
		"position": position, "provider": provider, "space": space,
		"extended": extended, "in_front": in_front, "facing_dot": facing_dot}

static func sample(tracker: XRHandTracker, hand: String, head: Transform3D, space: Transform3D, scale: float,
		meta_aim: XRPositionalTracker = null, interaction: XRPositionalTracker = null) -> Dictionary:
	if not is_optical(tracker): return {}
	# A temporarily invalid official pose cancels, rather than changing recognizer mid-pinch.
	if meta_aim != null: return runtime_sample(meta_aim, space, scale, true)
	if is_hand_profile(interaction, true): return runtime_sample(interaction, space, scale, false)
	# Preserve optical ownership on invalid joints; never fall back to an emulated trigger.
	var result := {"source": "hand", "provider": "joints"}
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
	var next_provider := str(input.get("provider", "joints" if next_source == "hand" else next_source))
	var native := next_source == "hand" and next_provider in ["meta_aim", "hand_profile"]
	var next_ray: Variant = input.get("ray")
	var ratio := float(input.get("ratio", INF))
	if next_ray != null and (not next_ray[0].is_finite() or not next_ray[1].is_finite() or next_ray[1].length_squared() < 0.001):
		next_ray = null
	if next_source == "hand" and ((native and not input.get("pinched") is bool) or (not native and not is_finite(ratio))): next_ray = null
	var changed := next_source != source or next_provider != provider
	var cancelled := changed or (ray != null and next_ray == null)
	if cancelled:
		down = false
		armed = false
		_settled = 0
	source = next_source
	provider = next_provider
	var was_tracked := ray != null
	if next_ray != null and source == "hand" and not native and was_tracked and not changed:
		var blend := 1.0 - exp(-25.0 * clampf(delta, 0, 0.1))
		ray = [ray[0].lerp(next_ray[0], blend), ray[1].lerp(next_ray[1], blend).normalized()]
	else:
		ray = next_ray
	var menu_down: bool = native and next_provider == "meta_aim" and input.get("menu_pressed", false) == true
	var event := {"pressed": false, "released": false, "cancelled": cancelled,
		"menu": menu_down and not _menu_down and not changed}
	_menu_down = menu_down
	if source != "hand" or ray == null: return event
	if native:
		# Runtime selection is already recognized/debounced. Do not add joint thresholds,
		# the fallback's 60ms delay, or another ray filter to the official result.
		var pinched: bool = input.pinched
		if not armed:
			if not pinched: armed = true
		elif pinched != down:
			down = pinched
			event["pressed" if down else "released"] = true
		return event
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
