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
