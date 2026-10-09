extends SceneTree
const Hand := preload("res://scripts/hand_pointer.gd")
const Main := preload("res://scripts/main.gd")
const Library := preload("res://scripts/library_menu.gd")
const Player := preload("res://scripts/player_menu.gd")
var checks := 0
var failures: Array[String] = []
var picks := 0
var seeks: Array[int] = []

class Catalog extends RefCounted:
	func list_recent() -> Array[Dictionary]:
		var entries: Array[Dictionary] = []
		for i in 40: entries.append({"uri": "content://hand/%d" % i, "title": "Video %d" % i, "position_ms": 0})
		return entries

class Viewer extends Node3D:
	var local_uri := "content://hand/video"
	var geometry := 1
	var view_camera: XRCamera3D
	var turned := Vector2.ZERO
	func corner_at(_origin: Vector3, _direction: Vector3) -> int: return -1
	func set_corner_hover(_corner: int) -> void: pass
	func turn_view(yaw: float, pitch: float) -> void: turned += Vector2(yaw, pitch)

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func sample(ratio: float) -> Dictionary:
	return {"source": "hand", "ray": [Vector3(0, 1.2, -0.4), Vector3.FORWARD], "ratio": ratio}

func settle(pointer: RefCounted, value: Dictionary) -> Dictionary:
	var result := {"pressed": false, "released": false, "cancelled": false}
	for i in 6:
		var event: Dictionary = pointer.update(value, 1.0 / 72)
		for key in result: result[key] = result[key] or event[key]
	return result

func make_tracker() -> XRHandTracker:
	var tracker := XRHandTracker.new()
	tracker.name = "/user/hand_tracker/right"
	tracker.has_tracking_data = true
	tracker.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
	var points := [Vector3(0.16, 1.42, -0.4), Vector3(0.18, 1.42, -0.4), Vector3(0.13, 1.40, -0.38), Vector3(0.20, 1.40, -0.38)]
	for i in Hand.JOINTS.size():
		tracker.set_hand_joint_flags(Hand.JOINTS[i], Hand.POSITION_FLAGS)
		tracker.set_hand_joint_transform(Hand.JOINTS[i], Transform3D(Basis.IDENTITY, points[i]))
	return tracker

func move_hand(tracker: XRHandTracker, center: Vector3, ratio: float) -> void:
	var points := [center - Vector3(0.07 * ratio * 0.5, 0, 0), center + Vector3(0.07 * ratio * 0.5, 0, 0), center - Vector3(0.035, 0, 0), center + Vector3(0.035, 0, 0)]
	for i in Hand.JOINTS.size(): tracker.set_hand_joint_transform(Hand.JOINTS[i], Transform3D(Basis.IDENTITY, points[i]))

func frames(main: Node3D, tracker: XRHandTracker, center: Vector3, ratio: float) -> void:
	move_hand(tracker, center, ratio)
	for frame in 8:
		main._update_hand_input(1.0 / 72)
		main._update_menu_pointer("right_hand")
		main._update_grab()

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	check_runtime_input()
	var pointer := Hand.new()
	check(not settle(pointer, sample(0.1)).pressed, "Already pinched on acquisition does not click")
	settle(pointer, sample(0.8))
	check(pointer.armed, "Open hand arms input")
	check(not pointer.update(sample(0.1), 0.014).pressed, "Single-frame pinch noise ignored")
	settle(pointer, sample(0.8))
	check(settle(pointer, sample(0.1)).pressed and pointer.down, "Stable pinch presses")
	check(not settle(pointer, sample(0.1)).pressed, "Held pinch does not repeat")
	check(not settle(pointer, sample(0.35)).released and pointer.down, "Hysteresis ignores threshold jitter")
	check(settle(pointer, sample(0.8)).released and not pointer.down, "Stable opening releases")
	settle(pointer, sample(0.1))
	var lost := pointer.update({"source": "hand"}, 0.014)
	check(lost.cancelled and not lost.released and pointer.ray == null, "Loss cancels without release activation")
	check(not settle(pointer, sample(0.1)).pressed, "Reacquiring pinched hand requires open")
	settle(pointer, sample(0.8))
	settle(pointer, sample(0.1))
	var switched := pointer.update({"source": "controller", "ray": [Vector3.ZERO, Vector3.FORWARD]}, 0.014)
	check(switched.cancelled and not switched.released and not pointer.down, "Controller takeover cancels pinch")
	check(not settle(pointer, sample(0.1)).pressed, "Controller to hand requires open")
	var other := Hand.new()
	settle(other, sample(0.8))
	check(settle(other, sample(0.1)).pressed and not pointer.down, "Hands have independent state")
	pointer.update(sample(0.8), 0.014)
	check(pointer.update(sample(NAN), 0.014).cancelled and pointer.ray == null, "NaN data cannot click")
	var tracker := make_tracker()
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	var data := Hand.sample(tracker, "right_hand", head, Transform3D.IDENTITY, 1)
	check(data.has("ray") and is_equal_approx(data.ratio, 2.0 / 7), "Real XRHandTracker supplies scale-normalized pinch")
	check(data.ray[1].dot(Vector3.FORWARD) > 0.99, "Shoulder ray points forwards")
	var space := Transform3D(Basis(Vector3.UP, 0.6), Vector3(3, 0, -2))
	var transformed := Hand.sample(tracker, "right_hand", space * Transform3D(Basis.IDENTITY, head.origin * 2), space, 2)
	check(transformed.ray[0].is_equal_approx(space * (data.ray[0] * 2)), "World scale and recenter applied once")
	check(is_equal_approx(transformed.ratio, data.ratio), "Pinch threshold independent of world scale")
	tracker.set_hand_joint_flags(Hand.JOINTS[0], XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
	check(not Hand.sample(tracker, "right_hand", head, Transform3D.IDENTITY, 1).has("ray"), "Stale tip without POSITION_TRACKED rejected")
	tracker.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER
	check(not Hand.is_optical(tracker), "Controller-inferred skeleton is not bare hand")
	tracker.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNKNOWN
	check(Hand.is_optical(tracker), "Missing data-source extension supported")
	tracker.has_tracking_data = false
	check(not Hand.is_optical(tracker), "Inactive hand never owns input")
	var library := Library.new()
	library.catalog = Catalog.new()
	library.chosen.connect(func(_uri: String, _title: String): picks += 1)
	root.add_child(library)
	library.toggle()
	# Scrolling remains a library-list interaction; Recent now uses page buttons.
	library.section = Library.Section.LOCAL
	library._local_entries = library.catalog.list_recent()
	library.refresh()
	var direction := -library.global_basis.z
	var row := library.to_global(Vector3(-0.36, Library.GRID_TOP - Library.TILE_SIZE.y * 0.5, 1))
	check(library.press_pointer("right_hand", row, direction, true), "Pinch ray starts list selection")
	library.cancel_pointer("right_hand")
	library.release_pointer("right_hand", row, direction, true)
	check(picks == 0 and library._drag.is_empty() and library._fling == 0, "Cancelled row cannot click or fling")
	library.press_pointer("right_hand", row, direction, true)
	library.press_pointer("left_hand", row, direction, true)
	check(library._drag.hand == "right_hand", "Second hand cannot steal drag")
	library.release_pointer("left_hand", row, direction, true)
	check(picks == 0, "Other hand release does not select")
	library.release_pointer("right_hand", row, direction, true)
	check(picks == 1, "Owner release selects once")
	library.toggle()
	library.press_pointer("right_hand", row, direction, true)
	library.update_pointer("right_hand", row + Vector3.UP * 0.5, direction, true)
	check(library.scroll > 0, "Held pinch scrolls list")
	library.cancel_pointer("right_hand")
	check(picks == 1 and library._fling == 0, "Cancelled scrolling does not select or fling")
	var player := Player.new()
	player.state_provider = func(): return {"has_video": true, "duration_ms": 100000, "position_ms": 20000, "seekable": true}
	player.seek_requested.connect(func(value: int): seeks.append(value))
	root.add_child(player)
	player.toggle()
	var seek_button: Dictionary = player._buttons.filter(func(b): return b.target == Player.SEEK)[0]
	var seek_origin: Vector3 = seek_button.node.global_position + Vector3(0, 0, 1)
	check(player.press_pointer("right_hand", seek_origin, Vector3.FORWARD, true), "Timeline pinch accepted")
	check(seeks.is_empty(), "Timeline press only previews the target")
	player.update_pointer("right_hand", seek_origin + Vector3(0.3, 0, 0), Vector3.FORWARD, true)
	var final_seek := player._seek_preview
	player.release_pointer("right_hand", seek_origin, Vector3.FORWARD, true)
	check(seeks == [final_seek] and final_seek > player._seek_start, "Timeline drag commits only its final destination on release")
	player.press_pointer("right_hand", seek_origin, Vector3.FORWARD, true)
	var before := seeks.size()
	player.update_pointer("right_hand", seek_origin + Vector3(0.3, 0, 0), Vector3.FORWARD, true)
	player.cancel_pointer("right_hand")
	check(seeks.size() == before and player._seek_hand.is_empty(), "Loss cancels pending seek")
	var main := Main.new()
	main.recent_menu = library
	main.player_menu = player
	main.video_menu = player
	main.hand_pointers["right_hand"] = other
	tracker = make_tracker()
	XRServer.add_tracker(tracker)
	check(not main._controller_allowed("right_hand"), "Optical tracker suppresses duplicate controller buttons")
	# Feed real registered trackers through Main's frame sampler and production menu dispatch.
	var head_tracker := XRPositionalTracker.new()
	head_tracker.name = "head"
	head_tracker.type = XRServer.TRACKER_HEAD
	head_tracker.set_pose("default", head, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	XRServer.add_tracker(head_tracker)
	main.xr_origin = XROrigin3D.new()
	root.add_child(main.xr_origin)
	main.xr_camera = XRCamera3D.new()
	main.xr_origin.add_child(main.xr_camera)
	main.xr_camera.transform = head
	library.cancel_pointer("right_hand")
	library.scroll = 0
	library.refresh()
	if not library.visible: library.toggle()
	var target := row - Vector3(0, 0, 1)
	var center := Vector3(0.16, 1.42, 0).lerp(target, 0.3)
	var initial_picks := picks
	for ratio in [0.8, 0.1, 0.8]:
		frames(main, tracker, center, ratio)
	check(picks == initial_picks + 1, "Registered XR hand pinch dispatch selects a library row exactly once")
	var viewer := Viewer.new()
	viewer.view_camera = main.xr_camera
	main.video = viewer
	library.dismiss()
	player.dismiss()
	center = Vector3(0.16, 1.65, -0.4)
	frames(main, tracker, center, 0.8)
	frames(main, tracker, center, 0.1)
	frames(main, tracker, center, 0.8)
	check(player.visible and main._grab.is_empty(), "Pinch tap without menu opens player controls")
	frames(main, tracker, center, 0.1)
	frames(main, tracker, center, 0.8)
	check(not player.visible, "Pinch outside controls hides them")
	frames(main, tracker, center, 0.1)
	frames(main, tracker, center + Vector3(0.12, 0, 0), 0.1)
	frames(main, tracker, center + Vector3(0.12, 0, 0), 0.8)
	check(viewer.turned.length() > 0.01 and not player.visible, "Held pinch moves picture without opening controls on release")
	# Follow the actual Vendors tracker contract through Main, even when joint flags
	# cannot support the fallback. No middle finger pose participates in selection.
	var aim := make_aim()
	XRServer.add_tracker(aim)
	for joint in Hand.JOINTS: tracker.set_hand_joint_flags(joint, 0)
	var native_target := row - Vector3(0, 0, 1)
	var native_pose := Transform3D(Basis(Quaternion(Vector3.FORWARD, (native_target - center).normalized())), center)
	aim.set_pose("default", native_pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_LOW)
	library.toggle()
	initial_picks = picks
	for pinch in [false, true, false]:
		aim.set_input("index_pinch", pinch)
		for frame in 2:
			main._update_hand_input(1.0 / 72)
			main._update_menu_pointer("right_hand")
	check(picks == initial_picks + 1 and other.provider == "meta_aim", "Official Quest aim and pinch dispatch select once without joint-distance recognition")
	check(not main._controller_allowed("right_hand"), "Official pinch cannot double-dispatch the emulated trigger")
	XRServer.remove_tracker(aim)
	var action_hand := make_action_hand(Hand.HAND_PROFILES[0])
	XRServer.add_tracker(action_hand)
	action_hand.set_pose("aim", native_pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	if not library.visible: library.toggle()
	initial_picks = picks
	for pinch in [false, true, false]:
		action_hand.set_input("trigger_click", pinch)
		for frame in 2:
			main._update_hand_input(1.0 / 72)
			main._update_menu_pointer("right_hand")
	check(picks == initial_picks + 1 and other.provider == "hand_profile", "Runtime hand interaction aim/select dispatch also selects exactly once")
	tracker.has_tracking_data = false
	if not library.visible: library.toggle()
	initial_picks = picks
	for pinch in [false, true, false]:
		action_hand.set_input("trigger_click", pinch)
		for frame in 2:
			main._update_hand_input(1.0 / 72)
			main._update_menu_pointer("right_hand")
	check(picks == initial_picks + 1 and other.ray != null, "Tracked runtime aim/select remains usable without skeletal tracking")
	action_hand.invalidate_pose("aim")
	main._update_hand_input(1.0 / 72)
	check(other.ray == null and not main._controller_allowed("right_hand"), "Lost runtime aim cancels input without falling back to an emulated controller")
	XRServer.remove_tracker(action_hand)
	# Exercise physical PICO and core fallback controllers through the actual node signals.
	var controller_node := XRController3D.new()
	controller_node.tracker = "right_hand"
	controller_node.pose = "aim"
	controller_node.button_pressed.connect(main._on_controller_button.bind("right_hand"))
	controller_node.button_released.connect(main._on_controller_release.bind("right_hand"))
	main.xr_origin.add_child(controller_node)
	main.right_controller = controller_node
	for profile in ["/interaction_profiles/bytedance/pico4_controller", "/interaction_profiles/bytedance/pico_neo3_controller",
		"/interaction_profiles/bytedance/pico4s_controller", Hand.SIMPLE_PROFILE]:
		var physical := make_action_hand(profile)
		physical.set_pose("aim", native_pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		XRServer.add_tracker(physical)
		await process_frame
		main._update_hand_input(1.0 / 72)
		check(main._controller_allowed("right_hand") and main._ray("right_hand") != null, "Physical controller retains its aim ray: " + profile)
		if not library.visible: library.toggle()
		initial_picks = picks
		physical.set_input("trigger_click", true)
		physical.set_input("trigger_click", false)
		check(picks == initial_picks + 1, "Physical controller trigger selects exactly once: " + profile)
		physical.invalidate_pose("aim")
		main._update_hand_input(1.0 / 72)
		check(main._ray("right_hand") == null, "Lost physical aim hides its ray: " + profile)
		XRServer.remove_tracker(physical)
	main.right_controller = null
	controller_node.free()
	tracker.has_tracking_data = true
	library.dismiss()
	player.dismiss()
	var left_optical := make_tracker()
	left_optical.name = "/user/hand_tracker/left"
	var left_aim := make_aim()
	left_aim.name = "/user/fbhandaim/left"
	XRServer.add_tracker(left_optical)
	XRServer.add_tracker(left_aim)
	main.hand_pointers["left_hand"] = Hand.new()
	main._update_hand_input(1.0 / 72)
	left_aim.set_input("menu_gesture", true)
	left_aim.set_input("menu_pressed", true)
	left_aim.set_input("index_pinch", true)
	main._update_hand_input(1.0 / 72)
	check(player.visible and main._grab.is_empty(), "Left official palm menu pinch opens controls without a picture grab")
	main._update_hand_input(1.0 / 72)
	check(player.visible, "Holding left official menu pinch cannot toggle twice")
	left_aim.set_input("menu_pressed", false)
	main._update_hand_input(1.0 / 72)
	left_aim.set_input("menu_pressed", true)
	main._update_hand_input(1.0 / 72)
	check(not player.visible, "Second official menu pinch closes controls")
	XRServer.remove_tracker(left_aim)
	XRServer.remove_tracker(left_optical)
	main.hand_pointers.erase("left_hand")
	main._grab = {"hand": "right_hand", "moved": false}
	other.ray = null
	main._on_pointer_release("trigger_click", "right_hand")
	check(main._grab.is_empty() and not player.visible, "Release arriving after tracking loss cancels instead of opening controls")
	viewer.free()
	XRServer.remove_tracker(head_tracker)
	main.xr_origin.free()
	if not library.visible: library.toggle()
	library.press_pointer("right_hand", row, direction, true)
	main.display.preview = false
	main.display.session_state = "session_visible"
	main._on_input_session_changed()
	check(library._drag.is_empty() and other.ray == null and not main._controller_allowed("right_hand"), "System UI focus loss cancels input")
	XRServer.remove_tracker(tracker)
	main.free()
	library.free()
	player.free()
	for failure in failures: push_error(failure)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://../../artifacts/hand-input"))
	FileAccess.open("res://../../artifacts/hand-input/verification.json", FileAccess.WRITE).store_string(JSON.stringify({"checks": checks, "failures": failures, "physical_tracking": "not_verified"}, "\t"))
	print("Hand pointer checks: %s (%d)" % ["passed" if failures.is_empty() else "FAILED", checks])
	quit(0 if failures.is_empty() else 1)

func make_aim() -> XRControllerTracker:
	var aim := XRControllerTracker.new()
	aim.name = "/user/fbhandaim/right"
	aim.set_pose("default", Transform3D(Basis.IDENTITY, Vector3(0.2, 1.3, -0.5)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_LOW)
	aim.set_input("index_pinch", false)
	aim.set_input("index_pinch_strength", 0.0)
	return aim

func make_action_hand(profile: String) -> XRControllerTracker:
	var tracker := XRControllerTracker.new()
	tracker.name = "right_hand"
	tracker.set_tracker_profile(profile)
	tracker.set_pose("aim", Transform3D(Basis.IDENTITY, Vector3(0.2, 1.3, -0.5)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	tracker.set_input("trigger_click", false)
	return tracker

func check_runtime_input() -> void:
	check(ProjectSettings.get_setting("xr/openxr/extensions/meta/hand_tracking_aim", false), "Meta official aim enabled")
	check(ProjectSettings.get_setting("xr/openxr/extensions/hand_interaction_profile", false), "Standard hand interaction enabled")
	var optical := make_tracker()
	var aim := make_aim()
	var pointer := Hand.new()
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	for joint in Hand.JOINTS: optical.set_hand_joint_flags(joint, 0)
	for middle in [Vector3(0.2, 1.7, -0.5), Vector3(0.2, 1.4, -0.65), Vector3(0.2, 1.3, -0.5)]:
		optical.set_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP, Transform3D(Basis.IDENTITY, middle))
		var data := Hand.sample(optical, "right_hand", head, Transform3D.IDENTITY, 1, aim)
		check(data.has("ray") and data.provider == "meta_aim" and not data.pinched, "Official selection independent of middle finger and fallback joint validity")
	var space := Transform3D(Basis(Vector3.UP, 0.6), Vector3(3, 0, -2))
	var data := Hand.runtime_sample(aim, space, 2, true)
	check(data.ray[0].is_equal_approx(space * (aim.get_pose("default").transform.origin * 2)), "Official aim world scale/recenter applied once")
	check(data.ray[1].is_equal_approx(space.basis * Vector3.FORWARD), "Official ray orientation preserved")
	aim.set_input("index_pinch", true)
	check(not pointer.update(Hand.runtime_sample(aim, Transform3D.IDENTITY, 1, true), 0.014).pressed, "Acquiring a pinched runtime hand does not click")
	aim.set_input("index_pinch", false)
	pointer.update(Hand.runtime_sample(aim, Transform3D.IDENTITY, 1, true), 0.014)
	check(pointer.armed, "Runtime unselected state rearms")
	aim.set_input("index_pinch", true)
	check(pointer.update(Hand.runtime_sample(aim, Transform3D.IDENTITY, 1, true), 0.014).pressed, "Runtime select takes effect without an extra 60ms delay")
	check(not pointer.update(Hand.runtime_sample(aim, Transform3D.IDENTITY, 1, true), 0.014).pressed, "Held runtime selection does not repeat")
	aim.set_input("index_pinch", false)
	check(pointer.update(Hand.runtime_sample(aim, Transform3D.IDENTITY, 1, true), 0.014).released, "Runtime unselect releases immediately")
	var moved := aim.get_pose("default").transform
	moved.origin.x += 0.12
	aim.set_pose("default", moved, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_LOW)
	pointer.update(Hand.runtime_sample(aim, Transform3D.IDENTITY, 1, true), 0.014)
	check(pointer.ray[0].is_equal_approx(moved.origin), "Runtime aim is not smoothed a second time")
	aim.set_input("index_pinch", true)
	pointer.update(Hand.runtime_sample(aim, Transform3D.IDENTITY, 1, true), 0.014)
	aim.set_pose("default", moved, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_NONE)
	data = Hand.sample(optical, "right_hand", head, Transform3D.IDENTITY, 1, aim)
	var event := pointer.update(data, 0.014)
	check(data.provider == "meta_aim" and not data.has("ray") and event.cancelled and not event.released, "Invalid official pose cancels without switching to joint recognition")
	aim.set_pose("default", moved, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_LOW)
	check(not pointer.update(Hand.runtime_sample(aim, Transform3D.IDENTITY, 1, true), 0.014).pressed, "Official tracking recovery still requires unselect before select")
	aim.set_input("index_pinch", false)
	pointer.update(Hand.runtime_sample(aim, Transform3D.IDENTITY, 1, true), 0.014)
	aim.set_input("index_pinch", true)
	pointer.update(Hand.runtime_sample(aim, Transform3D.IDENTITY, 1, true), 0.014)
	aim.set_input("system_gesture", true)
	event = pointer.update(Hand.runtime_sample(aim, Transform3D.IDENTITY, 1, true), 0.014)
	check(event.cancelled and not event.released and pointer.ray == null, "System palm gesture cancels application selection and drag")
	aim.set_input("system_gesture", false)
	aim.set_input("menu_gesture", true)
	aim.set_input("menu_pressed", true)
	event = pointer.update(Hand.runtime_sample(aim, Transform3D.IDENTITY, 1, true), 0.014)
	check(event.menu and not event.pressed and pointer.ray == null, "Official menu gesture emits menu rather than content selection")
	check(not pointer.update(Hand.runtime_sample(aim, Transform3D.IDENTITY, 1, true), 0.014).menu, "Held official menu event does not repeat")
	aim.set_input("menu_gesture", false)
	aim.set_input("menu_pressed", false)
	check(not Hand.runtime_sample(aim, Transform3D.IDENTITY, NAN, true).has("ray"), "Invalid world scale cannot produce runtime ray")
	var nonfinite := moved
	nonfinite.origin.x = NAN
	aim.set_pose("default", nonfinite, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_LOW)
	check(not Hand.runtime_sample(aim, Transform3D.IDENTITY, 1, true).has("ray"), "Nonfinite official aim is rejected")
	for profile in Hand.HAND_PROFILES + [Hand.SIMPLE_PROFILE]:
		var interaction := make_action_hand(profile)
		data = Hand.sample(optical, "right_hand", head, Transform3D.IDENTITY, 1, null, interaction)
		check(data.provider == "hand_profile" and data.has("ray"), "Optical hand uses runtime profile: " + profile)
		interaction.set_input("trigger_click", true)
		check(Hand.sample(optical, "right_hand", head, Transform3D.IDENTITY, 1, null, interaction).pinched, "Mapped runtime selection overrides joint distances: " + profile)
	var controller := make_action_hand("/interaction_profiles/oculus/touch_controller")
	check(Hand.sample(optical, "right_hand", head, Transform3D.IDENTITY, 1, null, controller).provider == "joints", "Physical controller profile cannot provide native hand selection")
	optical.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER
	check(Hand.sample(optical, "right_hand", head, Transform3D.IDENTITY, 1, aim).is_empty(), "Controller-inferred skeleton cannot use stale runtime hand aim")
	var invalid := make_aim()
	invalid.set_input("index_pinch", 0.0)
	check(not Hand.runtime_sample(invalid, Transform3D.IDENTITY, 1, true).has("ray"), "Missing boolean runtime selection fails closed")
	pointer = Hand.new()
	pointer.update({"source":"hand", "provider":"meta_aim", "ray":[Vector3.ZERO, Vector3.FORWARD], "pinched":false}, 0.014)
	pointer.update({"source":"hand", "provider":"meta_aim", "ray":[Vector3.ZERO, Vector3.FORWARD], "pinched":true}, 0.014)
	event = pointer.update({"source":"hand", "provider":"hand_profile", "ray":[Vector3.ZERO, Vector3.FORWARD], "pinched":true}, 0.014)
	check(event.cancelled and not event.released and not event.pressed and not pointer.down, "Recognizer transition mid-pinch cancels and waits for opening")
	var action_map := load("res://openxr_action_map.tres") as OpenXRActionMap
	for profile in Hand.HAND_PROFILES:
		var matches := action_map.interaction_profiles.filter(func(p): return p.interaction_profile_path == profile)
		check(matches.size() == 1, "Runtime hand profile declared once: " + profile)
		if matches.is_empty(): continue
		for side in ["left", "right"]:
			var path: String = "/user/hand/" + side + ("/input/pinch_ext/value" if profile == Hand.HAND_PROFILES[0] else "/input/select/value")
			check(matches[0].bindings.any(func(b): return b.action.resource_name == "trigger_click" and b.binding_path == path), "Both runtime hand selects mapped: " + path)
