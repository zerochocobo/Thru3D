extends SceneTree

const Menu := preload("res://scripts/recent_menu.gd")
const Main := preload("res://scripts/main.gd")
var checks := 0
var failures: Array[String] = []
var selected: Array[String] = []
var opened := 0

class Catalog extends RefCounted:
	func list_recent() -> Array[Dictionary]:
		var entries: Array[Dictionary] = []
		for index in 32:
			entries.append({"uri": "content://pointer/%d" % index, "title": "File %d" % index, "position_ms": 1000})
		return entries

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)

func target_origin(menu: Node3D, x: float, y: float, z: float = 1.0) -> Vector3:
	return menu.to_global(Vector3(x, y, z))

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	preload("res://scripts/i18n.gd").use("en") # text checks are written in English
	var menu := Menu.new()
	menu.catalog = Catalog.new()
	menu.chosen.connect(func(uri: String): selected.append(uri))
	menu.choose_file.connect(func(): opened += 1)
	root.add_child(menu)
	menu.toggle()
	var direction := -menu.global_basis.z
	var row := target_origin(menu, 0, 0.163)
	check(menu.ray_hit(row, direction).target == 1, "Ray selects actual row geometry")
	check(menu.ray_hit(target_origin(menu, 0.699, 0.2865), direction).is_empty(), "Transparent rounded row corner cannot activate its rectangular bounds")
	menu.update_pointer("left_hand", row, direction, true)
	check(selected.is_empty() and menu._hover.left_hand == 1 and menu._pointers.left_hand.dot.visible, "Hover displays dot without activating")
	check(not menu.press_pointer("right_hand", target_origin(menu, 1, 0.163), direction, true), "Other hand miss cannot activate left hover")
	check(not menu.press_pointer("left_hand", target_origin(menu, 1, 0.163), direction, true), "Trigger recomputes moved ray instead of stale hover")
	menu.update_pointer("left_hand", row, direction, false)
	check(menu._hover.left_hand == Menu.NONE and not menu._pointers.left_hand.line.visible and not menu._pointers.left_hand.dot.visible, "Tracking loss clears hover and visuals")
	check(not menu.press_pointer("left_hand", row, direction, false), "Untracked controller cannot click")
	for sample in [[row, Vector3.ZERO], [row, Vector3(INF, 0, -1)], [Vector3(NAN, 0, 0), direction],
		[row, menu.global_basis.x], [row, -direction], [target_origin(menu, 0, 0.163, -1), -direction],
		[target_origin(menu, 0, 0.163, 6), direction], [target_origin(menu, 0, 0.206), direction],
		[target_origin(menu, -0.5, -0.415), direction]]:
		check(menu.ray_hit(sample[0], sample[1]).is_empty(), "Invalid/parallel/rear/far/gap/disabled button rejects ray")
	menu.rotation = Vector3(0.2, 0.7, -0.1)
	menu.position = Vector3(2, 3, -4)
	direction = -menu.global_basis.z
	row = target_origin(menu, 0, 0.163)
	check(menu.ray_hit(row, direction).target == 1, "World transformed menu keeps correct hit")
	check(menu.press_pointer("left_hand", row, direction, true) and selected == ["content://pointer/0"] and not menu.visible, "Correct hand emits exact URI and closes once")
	check(not menu.press_pointer("left_hand", row, direction, true) and selected.size() == 1, "Closed menu rejects repeated activation")
	menu.toggle()
	for expected in range(1, 5):
		check(menu.press_pointer("right_hand", target_origin(menu, 0, -0.415), direction, true) and menu.page == expected, "Point-and-trigger next reaches page %d" % expected)
	check(menu.ray_hit(target_origin(menu, 0, -0.415), direction).is_empty(), "Last page disables next")
	check(menu.press_pointer("left_hand", target_origin(menu, -0.5, -0.415), direction, true) and menu.page == 3, "Previous is selected by pointer")
	menu.page = 4
	menu.refresh()
	check(menu.press_pointer("right_hand", target_origin(menu, 0, -0.011), direction, true) and selected.back() == "content://pointer/30", "Last page row maps to exact catalog entry")
	menu.toggle()
	check(menu.press_pointer("left_hand", target_origin(menu, 0.5, -0.415), direction, true) and not menu.visible and opened == 0, "Pointer close does not open a file")
	menu.toggle()
	check(menu.press_pointer("left_hand", target_origin(menu, 0, 0.25), direction, true) and opened == 1, "Pointer open-file emits once")
	# Use real XRController3D and registered Godot trackers with synthetic poses.
	# This validates engine/Main dispatch, not physical Quest tracking.
	menu.rotation = Vector3.ZERO
	menu.position = Vector3(0, -0.03, -1.55)
	menu.toggle()
	var main := Main.new() # Keep outside tree to avoid starting the actual player.
	main.recent_menu = menu
	var origin := XROrigin3D.new()
	root.add_child(origin)
	var trackers: Array[XRControllerTracker] = []
	for hand in ["left_hand", "right_hand"]:
		var tracker := XRControllerTracker.new()
		tracker.type = XRServer.TRACKER_CONTROLLER
		tracker.name = hand
		tracker.set_pose("aim", Transform3D(Basis.IDENTITY, target_origin(menu, 0, 0.163)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		tracker.set_input("primary", Vector2(0, -1))
		XRServer.add_tracker(tracker)
		trackers.append(tracker)
		var controller := XRController3D.new()
		controller.tracker = hand
		controller.pose = "aim"
		controller.button_pressed.connect(main._on_controller_button.bind(hand))
		origin.add_child(controller)
		if hand == "left_hand": main.left_controller = controller
		else: main.right_controller = controller
	await process_frame
	for tracker in trackers:
		tracker.set_pose("aim", tracker.get_pose("aim").transform, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	for _frame in 100:
		main._process(1.0 / 72.0)
	check(menu.page == 0 and menu.focus_index == 0 and menu._hover.left_hand == 1 and menu._hover.right_hand == 1, "Held real tracker axes never navigate menu; both rays hover independently")
	trackers[0].set_input("ax_button", true)
	check(menu.visible and selected.size() == 2, "A/X cannot select menu focus")
	trackers[0].invalidate_pose("aim")
	trackers[0].set_input("trigger_click", true)
	check(menu.visible and selected.size() == 2, "Actual tracking loss blocks Main trigger dispatch")
	trackers[1].set_input("trigger_click", true)
	check(not menu.visible and selected.size() == 3 and selected.back() == "content://pointer/0", "Tracked other controller button signal selects its ray")
	for tracker in trackers: XRServer.remove_tracker(tracker)
	origin.free()
	main.free()
	menu.free()
	var output := ProjectSettings.globalize_path("res://../../artifacts/recent-pointer-host")
	DirAccess.make_dir_recursive_absolute(output)
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({"state": "passed" if failures.is_empty() else "failed", "checks": checks, "failures": failures,
		"scope": "Production menu geometry/render state and real Godot XRController3D/Main dispatch using synthetic trackers; physical Quest pointing unverified"}, "\t"))
	for failure in failures: push_error(failure)
	print("Recent pointer host checks: %s (%d)" % ["passed" if failures.is_empty() else "failed", checks])
	quit(0 if failures.is_empty() else 1)
