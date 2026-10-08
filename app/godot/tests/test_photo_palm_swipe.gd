extends SceneTree
const Swipe := preload("res://scripts/photo_palm_swipe.gd")
const Hand := preload("res://scripts/hand_pointer.gd")
const Main := preload("res://scripts/main.gd")
var failures: Array[String] = []
var checks := 0
const HEAD := Transform3D(Basis.IDENTITY, Vector3(0,1.6,0))
const START := Vector3(.2,1.3,-.5)
const DT := 1.0 / 72.0

class Host extends RefCounted:
	var requests := 0
	func open_photo(_uri: String) -> int: requests += 1; return requests
	func cancel_photo(_id: int) -> void: pass
	func release_photo(_id: int) -> void: pass

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func palm(point: Vector3, open: bool = true) -> Dictionary:
	return {"source":"hand", "tracked":false, "down":false,
		"palm":{"tracked":true,"open":open,"eligible":open,"position":point,"provider":"joints","space":Transform3D.IDENTITY}}

func poll(g: RefCounted, input: Dictionary, enabled: bool = true, busy: bool = false,
		head: Transform3D = HEAD, scale: float = 1, epoch: int = 1) -> Array:
	return g.update({"right_hand":input},enabled,busy,head,scale,epoch,DT)

func arm(g: RefCounted, point: Vector3 = START, scale: float = 1, epoch: int = 1) -> void:
	var head := HEAD; head.origin *= scale
	for i in 24: poll(g,palm(point),true,false,head,scale,epoch)

func sweep(g: RefCounted, point: Vector3, direction: int, scale: float = 1, epoch: int = 1) -> Array:
	var result: Array = []
	var head := HEAD; head.origin *= scale
	for i in range(1,12): result.append_array(poll(g,palm(point+Vector3(direction*.017*i*scale,0,0)),true,false,head,scale,epoch))
	return result

func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	for direction in [-1,1]:
		var g := Swipe.new(); arm(g)
		var idle: Array = []
		for i in 80: idle.append_array(poll(g,palm(START)))
		check(idle.is_empty(), "Long stationary open-hand hold does not navigate or prevent the next sweep")
		var actions := sweep(g,START,direction)
		check(actions.size() == 1 and actions[0].direction == -direction, "One deliberate palm sweep navigates once in its direction")
		var end := START + Vector3(direction*.187,0,0)
		for i in 50: poll(g,palm(end),true,false,HEAD,1,2)
		check(sweep(g,end,-direction,1,2).is_empty(), "Returning after pausing at the endpoint cannot flip back, even across content epoch")
		arm(g,START,1,2)
		check(sweep(g,START,direction,1,2).size() == 1, "Stable return to origin rearms the next intentional sweep")
	# Close/open is a second deliberate rearming path, without needing the original position.
	var continuous := Swipe.new()
	check(sweep(continuous,START,-1).size() == 1, "Opening while already sweeping works without a stationary hover")
	continuous = Swipe.new(); arm(continuous)
	var turned := palm(START); turned.palm.eligible = false
	poll(continuous,turned)
	check(sweep(continuous,START,-1).size() == 1, "A brief pose excursion can recover without closing the hand")
	continuous = Swipe.new(); arm(continuous); poll(continuous,palm(START),false)
	check(sweep(continuous,START,-1).size() == 1, "Closing the menu allows a fresh sweep without requiring a fist")
	continuous = Swipe.new(); arm(continuous); continuous.cancel()
	check(sweep(continuous,START,-1).size() == 1, "Focus recovery cancels old movement but permits a new deliberate sweep")
	var g := Swipe.new(); arm(g); sweep(g,START,-1)
	var end := START - Vector3(.187,0,0)
	for i in 12: poll(g,palm(end,false))
	arm(g,end)
	check(sweep(g,end,1).size() == 1, "Tracked close/open rearms at the new hand position")
	for reason in ["menu","pinch","system","tracking","provider","space","head","body","teleport"]:
		g = Swipe.new(); arm(g)
		for i in range(1,4): poll(g,palm(START-Vector3(.017*i,0,0)))
		var input := palm(START-Vector3(.08,0,0))
		var head := HEAD
		if reason == "system": input.palm.blocked = true
		if reason == "tracking": input.palm.tracked = false
		if reason == "provider": input.palm.provider = "meta_aim"
		if reason == "space": input.palm.space = Transform3D(Basis.IDENTITY,Vector3.ONE)
		if reason == "head": head.basis = Basis(Vector3.UP,.5)
		if reason == "body": head.origin.x += .1
		if reason == "teleport": input.palm.position.x -= .3
		check(poll(g,input,reason != "menu",reason == "pinch",head).is_empty(), "Interruption cannot commit a wave: "+reason)
		var recovery: Array = []
		for i in range(1,7): recovery.append_array(poll(g,palm(START-Vector3(.08+.017*i,0,0))))
		check(recovery.is_empty(), "Interrupted trajectory cannot finish using distance travelled before recovery: "+reason)
	# Loss at the endpoint cannot erase the return lock.
	g = Swipe.new(); arm(g); sweep(g,START,-1)
	for i in 20: poll(g,{})
	arm(g,end)
	check(sweep(g,end,1).is_empty(), "Tracking recovery preserves shot return lock")
	g.cancel()
	for i in 20: poll(g,{})
	arm(g,end)
	check(sweep(g,end,1).is_empty(), "System cancellation plus tracking loss cannot bypass rearming")
	for vector in [Vector3(0,.017,0),Vector3(0,0,.017),Vector3(-.002,0,0)]:
		g = Swipe.new(); arm(g)
		var actions: Array = []
		for i in range(1,90): actions.append_array(poll(g,palm(START+vector*i)))
		check(actions.is_empty(), "Vertical, depth and slow drift do not count as a lateral wave")
	g = Swipe.new(); arm(g,START*2,2)
	check(sweep(g,START*2,-1,2).size() == 1, "World scaling preserves the physical palm threshold")
	check_sampling()
	await check_main_sampling()
	for failure in failures: push_error(failure)
	print("Photo palm swipe: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)

func tracker_at(point: Vector3, left: bool = false) -> XRHandTracker:
	var tracker := XRHandTracker.new()
	tracker.name = "/user/hand_tracker/left" if left else "/user/hand_tracker/right"
	tracker.has_tracking_data = true
	tracker.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
	var positions := {XRHandTracker.HAND_JOINT_PALM:Vector3.ZERO, XRHandTracker.HAND_JOINT_WRIST:Vector3(0,-.045,0),
		XRHandTracker.HAND_JOINT_THUMB_TIP:Vector3(-.09,.025,0)}
	for i in 4:
		var x: float = [-.025,0,.025,.045][i]
		var heights: Array = [.03,.075,.12] if i < 3 else [.025,.06,.10]
		for j in 3: positions[Hand.OPEN_FINGERS[i][j]] = Vector3(x,float(heights[j]),0)
	for joint in positions:
		var local: Vector3 = positions[joint]
		if left: local.x = -local.x
		tracker.set_hand_joint_flags(joint,Hand.POSITION_FLAGS)
		tracker.set_hand_joint_transform(joint,Transform3D(Basis.IDENTITY,point+local))
	return tracker

func check_sampling() -> void:
	for left in [false,true]:
		var tracker := tracker_at(START,left)
		var side := "left_hand" if left else "right_hand"
		var sample := Hand.palm_sample(tracker,side,HEAD,Transform3D.IDENTITY,1)
		check(sample.get("eligible",false), "Optical open palm accepted on both hands")
		var space := Transform3D(Basis(Vector3.UP,.4),Vector3(3,0,-2))
		var head := Transform3D(space.basis,space*(HEAD.origin*2))
		sample = Hand.palm_sample(tracker,side,head,space,2)
		check(sample.get("eligible",false) and sample.position.is_equal_approx(space*(START*2)), "Palm world transform and scale applied once")
		var aim := XRControllerTracker.new(); aim.set_input("index_pinch",false)
		check(Hand.palm_sample(tracker,side,HEAD,Transform3D.IDENTITY,1,aim).get("eligible",false), "Open-palm sampling does not require an aim pose")
		aim.set_input("system_gesture",true)
		check(not Hand.palm_sample(tracker,side,HEAD,Transform3D.IDENTITY,1,aim).eligible, "Runtime system gesture blocks palm swipe")
		aim.set_input("system_gesture",false); aim.set_input("index_pinch",true)
		check(not Hand.palm_sample(tracker,side,HEAD,Transform3D.IDENTITY,1,aim).eligible, "Official pinch has priority over open pose")
		aim.set_input("index_pinch",false); aim.set_input("menu_pressed",true)
		check(not Hand.palm_sample(tracker,side,HEAD,Transform3D.IDENTITY,1,aim).eligible, "Official menu press blocks palm swipe without an aim pose")
		tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP,Transform3D(Basis.IDENTITY,START+Vector3(0,.02,0)))
		check(Hand.palm_sample(tracker,side,HEAD,Transform3D.IDENTITY,1).open, "One relaxed or partly occluded finger still allows an open-hand sweep")
		tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_RING_FINGER_TIP,Transform3D(Basis.IDENTITY,START+Vector3(.025,.02,0)))
		check(not Hand.palm_sample(tracker,side,HEAD,Transform3D.IDENTITY,1).open, "A mostly closed hand rejects the open-palm pose")
		tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_WRIST,0)
		check(Hand.palm_sample(tracker,side,HEAD,Transform3D.IDENTITY,1).is_empty(), "Missing tracked joints cancel the palm pose")
	for point in [Vector3(.2,1.3,.2), Vector3(1.2,1.3,-.5),Vector3(.2,.5,-.5)]:
		check(not Hand.palm_sample(tracker_at(point),"right_hand",HEAD,Transform3D.IDENTITY,1).eligible,"Out-of-body gesture region rejects swipe")
	var controller := tracker_at(START); controller.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER
	check(Hand.palm_sample(controller,"right_hand",HEAD,Transform3D.IDENTITY,1).is_empty(),"Controller-inferred skeleton cannot wave")

func check_main_sampling() -> void:
	var main := Main.new(); main.settings_path = "user://palm_main_%d.cfg" % Time.get_ticks_usec()
	root.add_child(main); main.set_process(false)
	main.input_visuals.free(); main.input_visuals = null
	main.recent_menu.dismiss(); main.video_menu.dismiss(); main.photo_menu.dismiss()
	main.photo_active = true; main.player_menu = main.photo_menu
	main.photo.auto_depth = false; main.photo.platform = Host.new()
	main.photo.queue.assign([{"uri":"file://palm-one.png","title":"palm-one.png"},{"uri":"file://palm-two.png","title":"palm-two.png"}])
	main.photo.index = 0; main.photo.local_uri = "file://palm-one.png"; main.photo.panel.visible = true
	main.xr_camera.global_transform = HEAD
	var optical := tracker_at(START)
	var aim := XRControllerTracker.new(); aim.name = "/user/fbhandaim/right"; aim.set_input("index_pinch",false)
	var head := XRPositionalTracker.new(); head.name = "head"
	head.set_pose("default",HEAD,Vector3.ZERO,Vector3.ZERO,XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	for tracker in [optical,aim,head]: XRServer.add_tracker(tracker)
	for i in 24: main._update_hand_input(DT)
	for i in range(1,12):
		var moved := tracker_at(START-Vector3(.017*i,0,0))
		for joint in range(XRHandTracker.HAND_JOINT_MAX):
			optical.set_hand_joint_flags(joint,moved.get_hand_joint_flags(joint))
			optical.set_hand_joint_transform(joint,moved.get_hand_joint_transform(joint))
		main._update_hand_input(DT)
	check(main.photo.pending_index == -1 and main.photo_swipe.states.is_empty(), "Production palm navigation is disabled")
	main.photo.set_projection(3); main.photo.loading = false; main.photo.pending_index = -1; main.photo_menu.dismiss()
	main.photo_swipe = Swipe.new()
	for i in 24: main._update_hand_input(DT)
	for i in range(1,12):
		var moved := tracker_at(START+Vector3(.017*i,0,0))
		for joint in range(XRHandTracker.HAND_JOINT_MAX):
			optical.set_hand_joint_flags(joint,moved.get_hand_joint_flags(joint))
			optical.set_hand_joint_transform(joint,moved.get_hand_joint_transform(joint))
		main._update_hand_input(DT)
	check(main.photo.pending_index == -1 and main.photo_swipe.states.is_empty(), "Panorama never samples or consumes the new wave gesture")
	for tracker in [optical,aim,head]: XRServer.remove_tracker(tracker)
	main.queue_free(); await process_frame
