extends SceneTree
const Visuals := preload("res://scripts/input_visuals.gd")
var failures: Array[String] = []
var checks := 0

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var origin := XROrigin3D.new()
	root.add_child(origin)
	var visuals := Visuals.new()
	visuals.use_runtime_models = false
	origin.add_child(visuals)
	var controllers := []
	var trackers := []
	for side in ["left", "right"]:
		var controller := XRControllerTracker.new()
		controller.name = side + "_hand"
		controller.set_pose("grip", Transform3D(Basis.IDENTITY, Vector3(0.2, 1.3, -0.4)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		controller.set_pose("aim", Transform3D(Basis.IDENTITY, Vector3(0.2, 1.3, -0.6)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		XRServer.add_tracker(controller)
		controllers.append(controller)
		var tracker := XRHandTracker.new()
		tracker.name = "/user/hand_tracker/" + side
		tracker.hand = XRPositionalTracker.TRACKER_HAND_LEFT if side == "left" else XRPositionalTracker.TRACKER_HAND_RIGHT
		tracker.has_tracking_data = false
		XRServer.add_tracker(tracker)
		trackers.append(tracker)
	await process_frame
	visuals.update_visibility(true)
	for hand in visuals.hands:
		var entry: Dictionary = visuals.hands[hand]
		check(entry.controller_gate.visible and not entry.hand_gate.visible, hand + " shows controller only")
		check(entry.grip.pose == "grip", "Model uses grip rather than ray aim")
		check(visuals._has_mesh(entry.fallback), "Runtime-free controller has geometry")
		var skeleton := visuals._find_skeleton(entry.hand_fallback)
		check(skeleton != null and skeleton.get_bone_count() >= 26, "Fallback hand is fully rigged")
		check(skeleton.get_child(skeleton.get_child_count() - 1) is XRHandModifier3D, "Fallback hand has tracked skeleton modifier")
		check(visuals._has_mesh(entry.hand_fallback), "Fallback hand has skinned geometry")
	# Optical tracking wins even while emulated controller poses remain valid.
	trackers[1].has_tracking_data = true
	trackers[1].hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
	visuals.update_visibility(true)
	check(visuals.hands.right_hand.hand_gate.visible and not visuals.hands.right_hand.controller_gate.visible, "Optical hand suppresses controller duplicate")
	check(visuals.hands.left_hand.controller_gate.visible, "Other hand ownership is independent")
	visuals.update_visibility(false)
	check(not visuals.hands.left_hand.controller_gate.visible and not visuals.hands.right_hand.hand_gate.visible, "Lost focus hides both input sources")
	trackers[1].has_tracking_data = false
	controllers[1].invalidate_pose("grip")
	visuals.update_visibility(true)
	check(not visuals.hands.right_hand.hand_gate.visible and not visuals.hands.right_hand.controller_gate.visible, "Tracking loss hides stale geometry")
	trackers[0].has_tracking_data = true
	trackers[0].hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER
	visuals.update_visibility(true)
	check(visuals.hands.left_hand.controller_gate.visible and not visuals.hands.left_hand.hand_gate.visible, "Controller-inferred joints do not replace controller model")
	# Runtime assets replace fallback only after actual mesh geometry is present.
	var runtime := Node3D.new()
	visuals.hands.left_hand.grip.add_child(runtime)
	visuals.hands.left_hand.ext = runtime
	visuals.update_visibility(true)
	check(visuals.hands.left_hand.fallback.visible, "Empty runtime scene retains fallback")
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	runtime.add_child(mesh)
	visuals.update_visibility(true)
	check(not visuals.hands.left_hand.fallback.visible and runtime.visible, "Loaded runtime geometry replaces fallback")
	runtime.remove_child(mesh)
	mesh.free()
	visuals.update_visibility(true)
	check(visuals.hands.left_hand.fallback.visible, "Runtime removal restores fallback")
	for tracker in controllers + trackers: XRServer.remove_tracker(tracker)
	origin.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("Input visuals: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
