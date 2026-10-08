extends SceneTree
const Gestures := preload("res://scripts/photo_hand_gestures.gd")
const Main := preload("res://scripts/main.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Hand := preload("res://scripts/hand_pointer.gd")
var failures: Array[String] = []
var checks := 0

class Host extends RefCounted:
	var requests := 0
	func open_photo(_uri: String) -> int: requests += 1; return requests
	func cancel_photo(_id: int) -> void: pass
	func release_photo(_id: int) -> void: pass

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func sample(point: Variant, down: bool, pressed: bool = false, released: bool = false) -> Dictionary:
	return {"source": "hand", "tracked": true, "position": point, "down": down, "pressed": pressed, "released": released}

func poll(g: RefCounted, right: Dictionary, left: Dictionary = {}, enabled: bool = true,
	zoom: float = 1.0, scale: float = 1.0, epoch: int = 1) -> Dictionary:
	return g.update({"right_hand": right, "left_hand": left}, enabled, zoom, Basis.IDENTITY, scale, epoch)

func palm(point: Vector3) -> Dictionary:
	var input := sample(point, false)
	input["palm"] = {"tracked":true,"open":true,"eligible":true,"position":point,"provider":"joints","space":Transform3D.IDENTITY}
	return input

func wave(main: Node3D, point: Vector3, direction: int) -> void:
	for i in 20: main._dispatch_hand_input({"right_hand":palm(point)})
	for i in range(1,12): main._dispatch_hand_input({"right_hand":palm(point+Vector3(direction*.017*i,0,0))})

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var g := Gestures.new()
	var origin := Vector3(0.2, 1.3, -0.5)
	check(poll(g, sample(origin, true, true)).consumed == ["right_hand"], "Photo owns a pinch immediately")
	check(poll(g, sample(origin, false, false, true)).actions[0].operation == "tap", "Stationary pinch opens controls")
	for zoom in [.8,1.0,1.04,1.2,2.0]:
		for direction in [-1,1]:
			g = Gestures.new()
			poll(g, sample(origin,true,true), {}, true, zoom)
			var result := poll(g,sample(origin+Vector3(direction*.12,0,0),true), {}, true, zoom)
			check(result.actions.is_empty(), "Held single pinch never moves the picture at any scale")
			var released := poll(g,sample(origin+Vector3(direction*.12,0,0),false,false,true), {}, true, zoom)
			check(released.actions.size() == 1 and released.actions[0].operation == "navigate" and released.actions[0].direction == -direction, "Single pinch swipe navigates at every scale")
	g = Gestures.new()
	# Two hands replace the single-hand candidate without committing its swipe.
	poll(g, sample(origin, true, true))
	var left := origin - Vector3(.3, 0, 0)
	var result := poll(g, sample(origin, true), sample(left, true, true))
	check(result.actions.size() == 1 and is_equal_approx(result.actions[0].value, 1.0), "Joining hand begins at current scale")
	result = poll(g, sample(origin + Vector3(.15,0,0), true), sample(left - Vector3(.15,0,0), true))
	check(is_equal_approx(result.actions[0].value, 2.0), "Physical separation doubles the image")
	result = poll(g, sample(origin, false, false, true), sample(left, true))
	check(result.actions.size() == 1 and result.actions[0].operation == "finish", "Releasing one hand finishes zoom")
	result = poll(g,sample(origin,false),sample(left+Vector3(.03,0,0),true))
	check(result.actions.is_empty(), "Remaining hand after zoom must release before a fresh navigation pinch")
	check(poll(g, sample(origin,false),sample(left+Vector3(.03,0,0),false,false,true)).actions.is_empty(), "Zoom remainder release cannot tap or navigate")
	g = Gestures.new()
	poll(g,sample(origin,true,true)); poll(g,sample(origin,true),sample(left,true,true))
	var lost := sample(origin,false); lost["cancelled"] = true; lost["tracked"] = false
	check(poll(g,lost,sample(left,true)).actions.is_empty(), "Losing one hand cancels the dual gesture without handing over")
	check(poll(g,sample(origin,false),sample(left+Vector3(.08,0,0),true)).actions.is_empty(), "Remaining held hand must release after tracking cancellation")
	poll(g,sample(origin,false),sample(left,false,false,true))
	poll(g, sample(origin, true, true), {}, true, 2.0)
	result = poll(g, sample(origin + Vector3(.12,.03,0), true), {}, true, 2.0)
	check(result.actions.is_empty(), "Magnified image does not pan during a held single pinch")
	result = poll(g,sample(origin+Vector3(.15,0,0),false,false,true),{},true,2.0)
	check(result.actions.size() == 1 and result.actions[0].operation == "navigate" and result.actions[0].direction == -1, "Magnified photo uses the same pinch navigation")
	for interruption in ["menu", "epoch", "position", "tracking", "scale"]:
		g = Gestures.new()
		poll(g, sample(origin, true, true))
		var middle := sample(origin + Vector3(.1,0,0), true)
		if interruption == "position": middle.position = null
		if interruption == "tracking": middle.tracked = false; middle.cancelled = true
		poll(g, middle, {}, interruption != "menu", 1, 2 if interruption == "scale" else 1, 2 if interruption == "epoch" else 1)
		check(poll(g, sample(origin + Vector3(.2,0,0), false, false, true)).actions.is_empty(), "Interrupted gesture cancels without late tap/flip: " + interruption)
	g = Gestures.new()
	check(poll(g, sample(origin, true, true), {}, false).consumed.is_empty(), "Visible menu retains its input ownership")
	check(poll(g, sample(origin, true)).actions.is_empty(), "Closing menu while pinched cannot start a photo gesture")
	poll(g, sample(origin, false))
	poll(g, sample(origin * 2, true, true), {}, true, 1, 2)
	var scaled := poll(g,sample((origin+Vector3(-.12,0,0))*2,false,false,true),{},true,1,2)
	check(scaled.actions.size() == 1 and scaled.actions[0].direction == 1, "World scale preserves physical navigation threshold")
	# Position sampling remains independent of the runtime click recognizer.
	var tracker := XRHandTracker.new()
	tracker.has_tracking_data = true
	tracker.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
	for joint in [XRHandTracker.HAND_JOINT_THUMB_TIP, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP]:
		tracker.set_hand_joint_flags(joint, Hand.POSITION_FLAGS)
		tracker.set_hand_joint_transform(joint, Transform3D(Basis.IDENTITY, origin))
	var space := Transform3D(Basis(Vector3.UP, .5), Vector3(3,0,-2))
	check(Hand.pinch_position(tracker, space, 2).is_equal_approx(space * (origin * 2)), "Physical pinch applies tracking transform and world scale once")
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_THUMB_TIP, 0)
	check(Hand.pinch_position(tracker, space, 1) == null, "Missing position pauses motion recognition")
	await check_main(origin, left)
	for failure in failures: push_error(failure)
	print("Photo hand gestures: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func check_main(origin: Vector3, left: Vector3) -> void:
	var main := Main.new()
	main.settings_path = "user://photo_gestures_%d.cfg" % Time.get_ticks_usec()
	root.add_child(main)
	main.set_process(false)
	main.recent_menu.dismiss(); main.video_menu.dismiss(); main.photo_menu.dismiss()
	main.photo_active = true; main.player_menu = main.photo_menu
	var photo: Node3D = main.photo
	check(photo.auto_depth and not main.video.auto_depth, "Fresh photo viewing defaults to conversion without enabling video conversion")
	photo.auto_depth = false # Input-only fixture; conversion has a separate asynchronous suite.
	photo.history_enabled = false
	photo.platform = Host.new()
	photo.queue.assign([{"uri":"file://gesture-one.png", "title":"gesture-one.png"}, {"uri":"file://gesture-two.png", "title":"gesture-two.png"}])
	photo.index = 0; photo.local_uri = str(photo.queue[0].uri)
	photo.panel.visible = true
	for hand in main.hand_pointers:
		main.hand_pointers[hand].source = "hand"
		main.hand_pointers[hand].ray = [Vector3(0,1.6,0), Vector3.RIGHT]
	check(photo.screen_curve == Photo.DEFAULT_CURVE and photo._flat.size.x > 3.0, "Fresh photo has a large slightly curved default screen")
	main._dispatch_hand_input({"right_hand":sample(origin, true, true)})
	main._dispatch_hand_input({"right_hand":sample(origin - Vector3(.12,0,0), false, false, true)})
	check(photo.pending_index == 1 and main._grab.is_empty() and not main.photo_menu.visible, "Unmagnified pinch swipe navigates without a screen grab")
	var before_wave: int = photo.platform.requests
	wave(main,origin,-1)
	check(photo.platform.requests == before_wave and main.photo_swipe.states.is_empty(), "Palm motion does not navigate")
	photo.pending_index = -1; photo.index = 0
	photo.loading = false
	main._dispatch_hand_input({"right_hand":sample(origin, true, true)})
	main._dispatch_hand_input({"right_hand":sample(origin, true), "left_hand":sample(left, true, true)})
	main._dispatch_hand_input({"right_hand":sample(origin + Vector3(.15,0,0), true), "left_hand":sample(left - Vector3(.15,0,0), true)})
	check(is_equal_approx(photo.screen_scale, 2.0) and not photo.inspect, "Main scales the complete photo without cropping")
	main._dispatch_hand_input({"right_hand":sample(origin, false, false, true), "left_hand":sample(left, false, false, true)})
	var before: Vector3 = photo.flat_pose.origin
	main._dispatch_hand_input({"right_hand":sample(origin, true, true)})
	main._dispatch_hand_input({"right_hand":sample(origin + Vector3(.12,0,0), true)})
	main._dispatch_hand_input({"right_hand":sample(origin + Vector3(.12,0,0), false, false, true)})
	check(photo.flat_pose.origin == before and photo.pending_index == 1, "Enlarged photo switches through pinch swipe without panning")
	main.photo_menu.toggle()
	main._dispatch_hand_input({"right_hand":sample(origin, true, true)})
	main._dispatch_hand_input({"right_hand":sample(origin - Vector3(.15,0,0), false, false, true)})
	check(photo.pending_index == 1 and photo.screen_scale == 2.0, "Menu press/drag cannot become a content gesture")
	main.photo_menu.dismiss()
	main._dispatch_hand_input({"right_hand":sample(origin, true, true)})
	main._dispatch_hand_input({"right_hand":sample(origin, true), "left_hand":sample(left, true, true)})
	main._dispatch_hand_input({"right_hand":sample(origin - Vector3(.075,0,0), true), "left_hand":sample(left + Vector3(.075,0,0), true)})
	check(is_equal_approx(photo.screen_scale, 1.0) and absf(photo.flat_pose.origin.x) < .01, "Two-hand shrink returns to the whole-photo scale")
	main._dispatch_hand_input({"right_hand":sample(origin, false, false, true), "left_hand":sample(left, false, false, true)})
	main._dispatch_hand_input({"right_hand":sample(origin, true, true)})
	main._recenter()
	main._dispatch_hand_input({"right_hand":sample(origin - Vector3(.2,0,0), false, false, true)})
	check(photo.pending_index == 1 and not main.photo_menu.visible, "Recentring during pinch cannot trigger a late swipe or tap")
	photo.set_projection(3)
	main._dispatch_hand_input({"right_hand":sample(origin, true, true)})
	check(main._grab.has("hand") and main.photo_hands.mode.is_empty(), "Panorama retains its original hand grab path")
	main._dispatch_hand_input({"right_hand":sample(origin, false, false, true)})
	photo.set_projection(0); main.photo_menu.dismiss()
	# Complete actual display acceptance to inspect directional transitions and cleanup.
	var image := Image.create(64,32,false,Image.FORMAT_RGBA8); image.fill(Color.RED)
	var result := {"image":image, "thumbnail":image, "info":{}}
	photo._accept(result, {"id":10, "index":0})
	photo._accept(result, {"id":11, "index":1})
	check(is_instance_valid(photo._departing) and photo.panel.position.x > photo.flat_pose.origin.x, "Next picture starts to the right after decode succeeds")
	photo._transition_time = photo.TRANSITION_SECONDS * .5; photo._update_transition()
	check(photo._departing.position.x < photo._departing_pose.origin.x, "Departing picture moves left during next transition")
	photo.finish_transition()
	check(not is_instance_valid(photo._departing) and photo.panel.transform == photo.flat_pose, "Completion releases old texture/mesh and restores final pose")
	photo._accept(result, {"id":12, "index":0})
	check(photo.panel.position.x < photo.flat_pose.origin.x, "Previous picture starts to the left")
	photo.set_projection(3)
	check(not is_instance_valid(photo._departing), "Changing to panorama cancels the flat transition")
	photo._accept(result, {"id":13, "index":1, "unused":true})
	check(not is_instance_valid(photo._departing), "A panorama predecessor does not animate the next picture")
	# Exercise the production sampler with registered optical joints + official select.
	# This fixture checks input, with no skeleton render/import dependency.
	main.input_visuals.free(); main.input_visuals = null
	photo.set_projection(0); photo.set_screen_scale(1.0)
	photo.index = 0; photo.pending_index = -1; photo.loading = false; main.photo_menu.dismiss()
	var optical := XRHandTracker.new()
	optical.name = "/user/hand_tracker/right"
	optical.has_tracking_data = true
	optical.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
	var aim := XRControllerTracker.new()
	aim.name = "/user/fbhandaim/right"
	aim.set_pose("default", Transform3D(Basis.IDENTITY, origin), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	aim.set_input("index_pinch", false)
	var head := XRPositionalTracker.new()
	head.name = "head"
	head.set_pose("default", Transform3D(Basis.IDENTITY, Vector3(0,1.6,0)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	for tracker in [optical, aim, head]: XRServer.add_tracker(tracker)
	for point in [origin, origin - Vector3(.12,0,0)]:
		for joint in [XRHandTracker.HAND_JOINT_THUMB_TIP, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP]:
			optical.set_hand_joint_flags(joint, Hand.POSITION_FLAGS)
			optical.set_hand_joint_transform(joint, Transform3D(Basis.IDENTITY, point))
		if point == origin:
			main._update_hand_input(.014)
			aim.set_input("index_pinch", true)
		main._update_hand_input(.014)
	aim.set_input("index_pinch", false); main._update_hand_input(.014)
	check(photo.pending_index == 1 and main._grab.is_empty(), "Production joint sampling + official pinch navigates even when the aim ray stays stationary")
	for tracker in [optical, aim, head]: XRServer.remove_tracker(tracker)
	photo.close_image()
	check(not is_instance_valid(photo._departing), "Closing releases transition resources")
	main.queue_free()
	await process_frame
