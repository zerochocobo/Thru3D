extends SceneTree
const Menu := preload("res://scripts/photo_menu.gd")
var checks := 0
var failures: Array[String] = []

class InputMain extends "res://scripts/main.gd":
	var rays := {}
	func _ray(hand: String) -> Variant:
		return rays[hand] if rays.has(hand) else super._ray(hand)

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func hand_event(down: bool, pressed: bool = false, released: bool = false) -> Dictionary:
	return {"source":"hand", "tracked":true, "down":down, "pressed":pressed, "released":released, "position":Vector3(0,1.4,-0.4)}

func _run() -> void:
	var main := InputMain.new()
	main.settings_path = "user://photo-inspect-input-%d.cfg" % Time.get_ticks_usec()
	root.add_child(main); main.set_process(false)
	main.photo.set_process(false); main.photo_menu.set_process(false)
	main.photo_active = true; main.player_menu = main.photo_menu
	main.recent_menu.dismiss(); main.video_menu.dismiss()
	var photo: Node3D = main.photo
	var menu: Node3D = main.photo_menu
	photo.history_enabled = false; photo.auto_depth = false
	photo.queue.assign([{"uri":"file://inspect-one.png", "title":"one.png"}, {"uri":"file://inspect-two.png", "title":"two.png"}])
	photo.index = 0; photo.local_uri = str(photo.queue[0].uri)
	var image := Image.create(256,128,false,Image.FORMAT_RGB8); image.fill(Color.WHITE)
	photo._texture = ImageTexture.create_from_image(image); photo._size = Vector2(256,128)
	photo.material.set_shader_parameter("photo_texture",photo._texture)
	photo._detail_material.set_shader_parameter("photo_texture",photo._texture)
	photo.set_screen_curve(0); photo._apply_geometry(); photo.panel.visible = true
	main._place_screen()
	menu.toggle(); menu._activate(Menu.PHOTO_ADJUST)
	var y: float = menu._adjust_rows[452].knob.position.y
	menu.press_pointer("right_hand", menu.to_global(Vector3(0.03,y,1)), -menu.global_basis.z,true)
	menu.update_pointer("right_hand",menu.to_global(Vector3(0.63,y,1)),-menu.global_basis.z,true)
	check(photo.inspect_magnification == 8 and not photo.inspect and not photo._detail.visible and menu.visible,
		"Dragging default magnification never opens the window or dismisses settings")
	menu.release_pointer("right_hand",Vector3.ZERO,Vector3.ZERO,false)
	var stored := ConfigFile.new(); stored.load(main.settings_path)
	check(stored.get_value("photo_screen","magnification") == 8, "Default persists after slider release")
	menu._activate(Menu.PHOTO_ADJUST_BACK)
	var icon: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.PHOTO_INSPECT)[0]
	main.rays["right_hand"] = [icon.node.global_position + Vector3(0,0,1), -menu.global_basis.z]
	menu.update_pointer("right_hand",main.rays.right_hand[0],main.rays.right_hand[1],true)
	check(menu._tooltip.visible and menu._tooltip.get_child(0).text.contains("8.0×"), "Actual hovered icon shows remembered default")
	check(not menu._buttons.any(func(b): return b.target in [Menu.PHOTO_PLUS, Menu.PHOTO_MINUS]), "Photo bar has no live magnifier zoom controls")
	main._on_pointer_button("trigger_click","right_hand")
	check(photo.inspect and photo.magnification == 8 and photo._detail.visible and not menu.visible, "Icon trigger opens fixed default and clears the menu")
	main._on_pointer_release("trigger_click","right_hand")
	check(photo.inspect, "Releasing the opening trigger does not close the window")
	var original_pose: Transform3D = photo.panel.global_transform
	var original_size: Vector2 = photo._flat.size
	for u in [0.2,0.8]:
		var target: Vector3 = photo.panel.to_global(Vector3((u-0.5)*photo._flat.size.x,0,0))
		main.rays["right_hand"] = [main._eye()+Vector3(0.1,-0.1,0), (target-main._eye()-Vector3(0.1,-0.1,0)).normalized()]
		main.rays["left_hand"] = [main._eye(),Vector3.RIGHT]
		main._update_photo_inspect()
		check(is_equal_approx(photo.crop_center.x,u) and photo._inspect_line.visible and photo._inspect_dot.visible,
			"Moving the owning ray samples the actual source and shows a target")
		check(photo._inspect_dot.global_position.is_equal_approx(target), "Reticle sits at the selected image point")
		check(photo.panel.global_transform == original_pose and photo._flat.size == original_size, "Live inspection preserves the original image")
	main._process_sticks(Vector2(0,1),Vector2(0,1),1)
	main._apply_stick_actions([{"operation":"zoom","amount":1.0}],1)
	photo.set_hand_scale(6); photo.zoom_view(100)
	var wheel := InputEventMouseButton.new(); wheel.button_index = MOUSE_BUTTON_WHEEL_UP; wheel.pressed = true
	main._unhandled_input(wheel)
	check(photo.magnification == 8 and photo.inspect_magnification == 8 and photo.screen_scale == 1,
		"Sticks, wheel and hand scaling cannot change the visible window or saved default")
	photo.set_inspect_magnification(3)
	check(photo.magnification == 8 and photo.inspect_magnification == 3, "A parameter update affects only the next opening")
	main._on_pointer_button("trigger_click","right_hand")
	check(not photo.inspect and not photo._detail.visible and not photo._inspect_line.visible and menu.visible,
		"Next trigger closes window and aiming ray, returning to controls")
	main._on_pointer_button("trigger_click","right_hand")
	check(not photo.inspect, "A held/repeated close press cannot reopen the icon")
	main._on_pointer_release("trigger_click","right_hand")
	check(main._inspect_blocked.is_empty() and not photo.inspect, "Close release is consumed without activating a menu item")
	main._toggle_photo_inspect("right_hand")
	check(photo.magnification == 3, "Reopening uses the new default")
	main._on_pointer_button("by_button","right_hand")
	check(not photo.inspect and photo.inspect_magnification == 3, "Cancel button closes without changing the default")
	main._toggle_photo_inspect("right_hand")
	var escape := InputEventKey.new(); escape.keycode = KEY_ESCAPE; escape.pressed = true
	main._unhandled_key_input(escape)
	check(not photo.inspect, "Desktop cancel also closes the window")
	# Simultaneous closing pinches are consumed until both hands release.
	main._toggle_photo_inspect("right_hand")
	main._dispatch_hand_input({"right_hand":hand_event(true,true), "left_hand":hand_event(true,true)})
	check(not photo.inspect and main.photo_hands.mode.is_empty() and main._inspect_blocked.size() == 2,
		"Pinch closes immediately and captures both held hands")
	menu.dismiss()
	for sample in [hand_event(true),hand_event(false,false,true)]:
		main._dispatch_hand_input({"right_hand":sample,"left_hand":sample})
	check(photo.index == 0 and photo.pending_index == -1 and photo.screen_scale == 1 and not menu.visible and main._inspect_blocked.is_empty(),
		"Closing pinch movement/release cannot turn into scale, navigation or a menu tap")
	main._unhandled_input(wheel)
	check(photo.inspect and photo.magnification == 3 and main._inspect_desktop_ray != null,
		"Desktop wheel opens the configured default through the same inspection state")
	main._close_photo_inspect(); menu.dismiss()
	# Use the actual Meta hand aim/select pipeline without joint positions.
	main.rays.clear()
	main.input_visuals.free(); main.input_visuals = null # This fixture validates aim/select without a hand skeleton.
	var optical := XRHandTracker.new(); optical.name = "/user/hand_tracker/right"
	optical.has_tracking_data = true; optical.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
	var aim := XRControllerTracker.new(); aim.name = "/user/fbhandaim/right"
	aim.set_pose("default",Transform3D(Basis.IDENTITY,Vector3(0.1,1.4,-0.4)),Vector3.ZERO,Vector3.ZERO,XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	aim.set_input("index_pinch",false)
	var head := XRPositionalTracker.new(); head.name = "head"
	head.set_pose("default",Transform3D(Basis.IDENTITY,Vector3(0,1.6,0)),Vector3.ZERO,Vector3.ZERO,XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	for tracker in [optical,aim,head]: XRServer.add_tracker(tracker)
	for geometry in [0,3]:
		photo.set_projection(geometry)
		main._update_hand_input(0.014)
		main._toggle_photo_inspect("right_hand")
		main._update_photo_inspect()
		check(photo.inspect and main.hand_pointers.right_hand.provider == "meta_aim" and photo._inspect_line.visible and photo._inspect_dot.visible,
			"Native hand aim visibly targets the magnifier in projection %d" % geometry)
		var before: Transform3D = photo.panel.global_transform
		if geometry == 0:
			aim.set_pose("default",Transform3D(Basis.IDENTITY,Vector3(0.1,1.4,-0.4)),Vector3.ZERO,Vector3.ZERO,XRPose.XR_TRACKING_CONFIDENCE_NONE)
			main._update_hand_input(0.014); main._update_photo_inspect()
			check(photo.inspect and not photo._inspect_line.visible and not photo._inspect_dot.visible, "Lost native tracking clears the stale pointing ray")
			aim.set_pose("default",Transform3D(Basis.IDENTITY,Vector3(0.1,1.4,-0.4)),Vector3.ZERO,Vector3.ZERO,XRPose.XR_TRACKING_CONFIDENCE_HIGH)
			main._update_hand_input(0.014)
		aim.set_input("index_pinch",true); main._update_hand_input(0.014)
		check(not photo.inspect and photo.panel.global_transform.is_equal_approx(before) and photo.inspect_magnification == 3,
			"Native pinch closes flat/panorama without moving its image or changing default")
		aim.set_input("index_pinch",false); main._update_hand_input(0.014)
		check(main._inspect_blocked.is_empty() and not photo.inspect, "Native release cannot reopen the magnifier")
		menu.dismiss()
	for tracker in [optical,aim,head]: XRServer.remove_tracker(tracker)
	main.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Photo inspect input: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
