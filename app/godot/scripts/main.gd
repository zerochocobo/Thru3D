extends Node3D

const DisplayController := preload("res://scripts/xr_display.gd")
const Board := preload("res://scripts/calibration_board.gd")
const Log := preload("res://scripts/diagnostic_log.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const StickControls := preload("res://scripts/player_stick_controls.gd")
const HandPointer := preload("res://scripts/hand_pointer.gd")
const Geometry := preload("res://scripts/video_geometry.gd")
const LibraryMenu := preload("res://scripts/library_menu.gd")
const SETTINGS_PATH := "user://player_settings.cfg"
const PhotoDisplay := preload("res://scripts/photo_display.gd")
const PhotoMenu := preload("res://scripts/photo_menu.gd")
const ImageInfo := preload("res://scripts/image_info.gd")
const PlayerMenu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
const Background := preload("res://scripts/app_background.gd")
const RVM_PROFILES := ["256x144", "384x216", "512x288", "256x256", "384x384", "512x512", "320x320"]

var display := DisplayController.new()
var status_label: Label3D
var report_timer: Timer
var platform_plugin: Object
var last_request := 0
var android_report: Dictionary = {}
var photo: Node3D
var photo_active := false
var video_menu: Node3D
var photo_menu: Node3D
var video: Node3D
var calibration_board: Node3D
var last_rvm_request := 0
var next_rvm_case := 0
var rvm_report: Dictionary = {}
var rvm_status := "RVM benchmark not run"
var right_controller: XRController3D
var left_controller: XRController3D
var hand_pointers := {}
var hand_marks := {}
var xr_origin: XROrigin3D
var xr_camera: XRCamera3D
var stick_controls := StickControls.new()
var recent_menu: Node3D
var player_menu: Node3D
var settings := ConfigFile.new()
var settings_path := SETTINGS_PATH
var background: Node
var controlled_request := 0
var controlled_report: Dictionary = {}
var controlled_status := "Controlled decoder probe not run"

func _ready() -> void:
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	add_child(world)
	var origin := XROrigin3D.new()
	xr_origin = origin
	origin.name = "XROrigin3D"
	add_child(origin)
	var camera := XRCamera3D.new()
	xr_camera = camera
	camera.name = "XRCamera3D"
	origin.add_child(camera)
	var desktop := OS.get_name() != "Android" or OS.get_cmdline_user_args().has("--mpv-diagnostic-2d")
	if desktop:
		camera.position.y = 1.6
	for hand in ["left_hand", "right_hand"]:
		hand_pointers[hand] = HandPointer.new()
		var mark := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.006
		sphere.height = 0.012
		mark.mesh = sphere
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(0.15, 0.9, 1.0) if hand == "left_hand" else Color(1.0, 0.65, 0.15)
		mark.material_override = material
		mark.visible = false
		origin.add_child(mark)
		hand_marks[hand] = mark
		var controller := XRController3D.new()
		controller.tracker = hand
		controller.pose = "aim"
		controller.button_pressed.connect(_on_controller_button.bind(hand))
		controller.button_released.connect(_on_controller_release.bind(hand))
		origin.add_child(controller)
		if hand == "right_hand":
			right_controller = controller
		else:
			left_controller = controller
	var board := Board.new()
	calibration_board = board
	board.name = "CalibrationBoard"
	add_child(board)
	status_label = Label3D.new()
	status_label.position = Vector3(0, 2.45, -2)
	status_label.font_size = 22
	status_label.pixel_size = 0.003
	status_label.outline_size = 5
	add_child(status_label)
	display.status_changed.connect(_update_status)
	display.status_changed.connect(_on_input_session_changed)
	settings.load(settings_path)
	I18n.use(str(settings.get_value("ui", "language", "auto")))
	# Eye-buffer resolution scale (applies at XR start); a measurement/tuning knob, default 1.
	display.render_scale = clampf(float(settings.get_value("video", "render_scale", 1.0)), 0.5, 1.5)
	display.configure(get_viewport(), world.environment, XRServer.find_interface("OpenXR"), desktop)
	# Long-press of the controller's Meta button recenters the runtime's space; bring the screen
	# and menus in front of the new view, exactly as the in-app Recenter does.
	var openxr := XRServer.find_interface("OpenXR")
	if not desktop and openxr and openxr.has_signal("pose_recentered"):
		openxr.connect("pose_recentered", _on_system_recentered)
	_head_placed = desktop
	# Everyday playback uses the validated default model, including migrated settings.
	if str(settings.get_value("alpha", "model", "fast")) != "fast":
		settings.set_value("alpha", "model", "fast")
		settings.save(settings_path)
	# The video node warms the RVM model when it enters the tree: select the model first.
	if Engine.has_singleton("QuestPlayer"):
		Engine.get_singleton("QuestPlayer").set_rvm_model("fast")
	video = Video.new()
	video.name = "VideoDisplay"
	video.changed.connect(_on_video_changed)
	video.prefer_clone_voice = bool(settings.get_value("audio", "prefer_clone_voice", false))
	video.history_enabled = bool(settings.get_value("library", "history", true))
	video.depth_strength = video.DepthStrength.remembered(float(settings.get_value("video", "depth_strength", 1.0)))
	video.auto_depth = bool(settings.get_value("effects", "auto_3d", false))
	video.load_mode_lock(settings.get_value("video", "mode_lock", {}))
	video.subtitle_distance = float(settings.get_value("subtitles", "distance", 5.0))
	video.color_grade.restore(settings.get_value("video", "color_grade", {}))
	# The flat screen keeps the distance, size and curve the viewer last chose.
	video.screen_distance = clampf(float(settings.get_value("screen", "distance", video.SCREEN_DISTANCE)),
		video.DISTANCE_LIMITS.x, video.DISTANCE_LIMITS.y)
	video.screen_scale = clampf(float(settings.get_value("screen", "scale", 1.0)), video.SCALE_LIMITS.x, video.SCALE_LIMITS.y)
	video.screen_curve = clampf(float(settings.get_value("screen", "curve", 0.0)), 0.0, 1.0)
	add_child(video)
	video.view_camera = camera
	photo = PhotoDisplay.new()
	photo.name = "PhotoDisplay"
	photo.depth_strength = photo.DepthStrength.remembered(float(settings.get_value("photo", "depth_strength", 1.0)))
	photo.auto_depth = video.auto_depth
	photo.load_mode_lock(settings.get_value("photo", "mode_lock", {}))
	photo.catalog = video.recent_files
	photo.history_enabled = video.history_enabled
	photo.changed.connect(_on_photo_changed)
	photo.screen_distance = clampf(float(settings.get_value("photo_screen", "distance", 2.0)), photo.DISTANCE_LIMITS.x, photo.DISTANCE_LIMITS.y)
	photo.screen_scale = clampf(float(settings.get_value("photo_screen", "scale", 1.0)), photo.SCALE_LIMITS.x, photo.SCALE_LIMITS.y)
	photo.screen_curve = clampf(float(settings.get_value("photo_screen", "curve", 0.0)), 0.0, 1.0)
	add_child(photo)
	photo.view_camera = camera
	display.set_foveation(int(settings.get_value("video", "foveation", 0)))
	recent_menu = LibraryMenu.new()
	recent_menu.catalog = video.recent_files
	recent_menu.settings_provider = _library_settings
	recent_menu.chosen.connect(_on_library_chosen)
	recent_menu.player_requested.connect(_show_player_menu)
	recent_menu.setting_changed.connect(_on_setting_changed)
	recent_menu.recenter_requested.connect(_recenter)
	# Menus live in the world: placed in front of the user when shown, they stay put while the head moves.
	add_child(recent_menu)
	if Engine.has_singleton("QuestPlayer"):
		var plugin := Engine.get_singleton("QuestPlayer")
		recent_menu.attach_platform(plugin)
		plugin.set_mpv_output_width(int(settings.get_value("video", "output_width", 0)))
	player_menu = PlayerMenu.new()
	player_menu.state_provider = _menu_state
	player_menu.action_requested.connect(_on_menu_action)
	player_menu.recent_requested.connect(_show_recent_menu)
	player_menu.seek_requested.connect(_on_menu_seek)
	player_menu.volume_requested.connect(_on_menu_volume)
	player_menu.adjustment_requested.connect(_on_playback_adjustment)
	player_menu.adjustment_committed.connect(_save_playback_adjustments)
	player_menu.subtitle_requested.connect(video.set_subtitle_track)
	player_menu.depth_strength_requested.connect(_on_depth_strength.bind(false))
	player_menu.depth_strength_committed.connect(_save_depth_strength)
	add_child(player_menu)
	video_menu = player_menu
	photo_menu = PhotoMenu.new()
	photo_menu.state_provider = photo.snapshot
	photo_menu.queue_provider = func(): return photo.queue
	photo_menu.action_requested.connect(_on_photo_action)
	photo_menu.depth_strength_requested.connect(_on_depth_strength.bind(true))
	photo_menu.depth_strength_committed.connect(_save_depth_strength)
	photo_menu.recent_requested.connect(_show_recent_menu)
	add_child(photo_menu)
	background = Background.new()
	background.choice = str(settings.get_value("appearance", "background", "belfast"))
	background.custom_path = str(settings.get_value("appearance", "custom_path", ""))
	background.custom_title = str(settings.get_value("appearance", "custom_title", ""))
	background.custom_orientation = int(settings.get_value("appearance", "custom_orientation", 1))
	background.yaw = fposmod(float(settings.get_value("appearance", "background_yaw", 0.0)), 360.0)
	background.brightness = clampf(float(settings.get_value("appearance", "background_brightness", 1.0)), 0.5, 1.25)
	background.changed.connect(_on_background_changed)
	background.custom_saved.connect(_on_custom_background_saved)
	add_child(background)
	if Engine.has_singleton("QuestPlayer"):
		platform_plugin = Engine.get_singleton("QuestPlayer")
		if platform_plugin.has_method("set_ui_language"):
			platform_plugin.set_ui_language(I18n.choice)
		platform_plugin.connect("capabilities_ready", _on_capabilities_ready)
		platform_plugin.connect("android_lifecycle", _on_android_lifecycle)
		platform_plugin.connect("rvm_benchmark_result", _on_rvm_result)
		for kind in ["state", "frame", "error"]:
			platform_plugin.connect("controlled_" + kind, _on_controlled_event.bind(kind))
		request_capabilities()
	else:
		Log.record("android_plugin_unavailable", {"desktop_preview": desktop})
	report_timer = Timer.new()
	report_timer.wait_time = 2.0
	report_timer.timeout.connect(_save_report)
	add_child(report_timer)
	report_timer.start()
	_update_status()
	if not OS.get_cmdline_user_args().has("--mpv-diagnostic-2d"):
		_show_recent_menu()
	Log.record("ui_ready", {"library_visible": recent_menu.visible, "player_visible": player_menu.visible,
		"diagnostics_visible": status_label.visible, "calibration_visible": calibration_board.visible,
		"menu_selection": "controller_ray_trigger_or_hand_pinch"})
	Log.record("app_started", {"version": ProjectSettings.get_setting("application/config/version"), "os": OS.get_name()})
	# Source distribution: private capture automation is excluded.

## Desktop preview: dragging with the mouse moves the picture, the wheel zooms immersive views.
func _unhandled_input(event: InputEvent) -> void:
	if _active_menu() or not video or _viewer().local_uri.is_empty():
		return
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		_turn_picture(-event.relative.x * MOUSE_TURN, -event.relative.y * MOUSE_TURN)
	elif event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var forward := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
		if photo_active or _viewer().geometry != Geometry.Geometry.FLAT:
			_viewer().zoom_view(0.05 * forward)
		else:
			_push_screen(0.1 * forward)
			_save_screen()

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB:
			_toggle_player_menu()
			return
		var menu := _active_menu()
		if menu:
			if OS.get_name() == "Android":
				return
			if event.keycode == KEY_ESCAPE:
				menu.dismiss()
			elif menu == recent_menu:
				match event.keycode:
					KEY_UP: recent_menu.move_focus(-1)
					KEY_DOWN: recent_menu.move_focus(1)
					KEY_ENTER: recent_menu.activate_desktop()
			return
		if photo_active:
			match event.keycode:
				KEY_LEFT: if not photo.inspect: photo.navigate(-1)
				KEY_RIGHT: if not photo.inspect: photo.navigate(1)
				KEY_SPACE: photo.toggle_inspect()
				KEY_R: _reset_picture()
				KEY_P: photo.cycle_projection()
				KEY_S: photo.toggle_stereo()
				KEY_E: photo.toggle_eye_order()
				KEY_O: _show_recent_menu()
			return
		match event.keycode:
			KEY_T:
				_toggle_display()
			KEY_R:
				_recenter()
			KEY_D:
				request_capabilities()
			KEY_O:
				_show_recent_menu()
			KEY_SPACE:
				video.toggle_play()
			KEY_S:
				video.toggle_stereo()
			KEY_P:
				video.cycle_projection()
			KEY_LEFT:
				video.seek_relative(-10000)
			KEY_RIGHT:
				video.seek_relative(10000)
			KEY_L:
				video.toggle_loop()
			KEY_M:
				video.toggle_mute()
			KEY_U:
				video.change_volume(10.0)
			KEY_J:
				video.change_volume(-10.0)
			KEY_H:
				video.cycle_audio_track()
			KEY_C:
				video.cycle_subtitle_track()
			KEY_E:
				video.toggle_eye_order()
			KEY_V:
				video.play_calibration_clip()
			KEY_F8:
				_request_rvm_benchmark(false)
			KEY_F9:
				_request_rvm_benchmark(true)
			KEY_F6:
				_request_rvm_benchmark(next_rvm_case % 2 == 1, RVM_PROFILES[next_rvm_case >> 1])
			KEY_F7:
				_request_controlled_probe()

# Menus are ray + trigger only. A list row clicks on release unless the ray dragged to scroll.
# Outside the menus a trigger tap shows/hides the controls; held and moved, it drags the picture.
func _on_controller_release(action: String, hand: String = "") -> void:
	if not _controller_allowed(hand): return
	_on_pointer_release(action, hand)

func _on_pointer_release(action: String, hand: String) -> void:
	if action == "trigger_click" and _ray(hand) == null:
		_cancel_pointer(hand)
		return
	if action == "trigger_click" and not _grab.is_empty() and _grab.hand == hand:
		var grab := _grab
		_grab = {}
		_viewer().set_corner_hover(-1)
		if grab.moved and not grab.has("inspect") and _viewer().geometry == Geometry.Geometry.FLAT:
			_save_screen()
		if not grab.moved:
			if player_menu.visible:
				player_menu.dismiss()
			else:
				_show_player_menu()
		return
	var menu := _active_menu()
	if action != "trigger_click" or not menu or not menu.has_method("release_pointer"):
		return
	var ray: Variant = _ray(hand)
	menu.release_pointer(hand, ray[0] if ray != null else Vector3.ZERO,
		ray[1] if ray != null else Vector3.ZERO, ray != null)

func _on_controller_button(action: String, hand: String = "") -> void:
	if not _controller_allowed(hand): return
	_on_pointer_button(action, hand)

func _on_pointer_button(action: String, hand: String) -> void:
	if action == "menu_button":
		_toggle_player_menu()
		return
	var menu := _active_menu()
	if menu:
		match action:
			"trigger_click":
				# Beside the player controls a tap hides them and a drag moves the picture.
				if not _update_menu_pointer(hand, true) and menu == player_menu:
					var ray: Variant = _ray(hand)
					# A slider owned by the other hand rejects this press; it is not a screen drag.
					if ray != null and menu.ray_hit(ray[0], ray[1]).is_empty(): _begin_grab(hand)
			"by_button": menu.dismiss()
		return
	if photo_active:
		match action:
			"trigger_click":
				if photo.local_uri.is_empty(): _show_recent_menu()
				else: _begin_grab(hand)
			"ax_button": _show_recent_menu()
			"by_button": _recenter()
			"grip_click": photo.toggle_inspect()
			"primary_click":
				if hand == "left_hand": photo.cycle_projection()
				else: _reset_picture()
		return
	match action:
		"trigger_click":
			if _viewer().local_uri.is_empty():
				_show_recent_menu()
			else:
				_begin_grab(hand)
		"by_button":
			_recenter()
		"ax_button":
			_show_recent_menu()
		"grip_click":
			video.toggle_play()
		"primary_click":
			if hand == "left_hand":
				video.cycle_projection()
			else:
				_reset_picture()

## Menus shown at launch are placed before the headset reports a pose (the camera is still at
## the floor origin): once the head is first tracked, recenter and place everything again.
var _head_placed := false

func _head_tracked() -> bool:
	var head := XRServer.get_tracker("head") as XRPositionalTracker
	if not head or not head.has_pose("default"):
		return false
	var pose := head.get_pose("default")
	return pose.has_tracking_data and pose.tracking_confidence != XRPose.XR_TRACKING_CONFIDENCE_NONE

func _on_system_recentered() -> void:
	Log.record("system_recentered")
	_recenter()

func _process(delta: float) -> void:
	_update_hand_input(delta)
	if not _head_placed and _head_tracked():
		_head_placed = true
		_recenter()
	if video and _viewer().local_uri != _screen_uri:
		_screen_uri = _viewer().local_uri
		if not _screen_uri.is_empty():
			_place_screen()
	_update_grab()
	var right := _stick(right_controller)
	var left := _stick(left_controller)
	_update_corner_hover()
	if not _active_menu() and not _grab.is_empty() and not _grab.has("resize") and not _grab.has("inspect") and _viewer().geometry == Geometry.Geometry.FLAT:
		# While the screen is held its hand's stick pushes it away or pulls it closer.
		var held := left if _grab.hand == "left_hand" else right
		if absf(held.y) > STICK_DEADZONE:
			_grab.moved = true
			_push_screen(signf(held.y) * (absf(held.y) - STICK_DEADZONE) / (1.0 - STICK_DEADZONE) * PUSH_SPEED * delta)
	var menu := _active_menu()
	if menu:
		stick_controls.left_latched = true
		stick_controls.right_latched = true
		stick_controls.right_zooming = false
		_update_menu_pointer("left_hand")
		_update_menu_pointer("right_hand")
		# Either stick scrolls a list (never selects); playback shortcuts stay off while a menu is open.
		if menu.has_method("stick_scroll"):
			menu.stick_scroll(left.y if absf(left.y) > absf(right.y) else right.y, delta)
		if menu == player_menu:
			if not player_menu._hover.is_empty():
				_menu_touched_ms = Time.get_ticks_msec()
			elif player_menu.section == 0 and not player_menu._mode_open and (not photo_active or not photo_menu._gallery_open) and (photo_active or video.control.snapshot().get("state", "") == "playing") and Time.get_ticks_msec() - _menu_touched_ms > CONTROLS_HIDE_MS:
				player_menu.dismiss()
		return
	var actions := stick_controls.poll(left, right, video != null and (photo_active or _viewer().geometry != Geometry.Geometry.FLAT))
	if not _grab.is_empty():
		# Holding the picture: only zoom; other stick shortcuts wait for the stick to recenter.
		actions = actions.filter(func(action): return action.operation == "zoom")
	_apply_stick_actions(actions, delta)

func _stick(controller: XRController3D) -> Vector2:
	return controller.get_vector2("primary") if controller and controller.get_is_active() and _controller_allowed(str(controller.tracker)) else Vector2.ZERO

func _hand_tracker(hand: String) -> XRHandTracker:
	return XRServer.get_tracker("/user/hand_tracker/" + ("left" if hand == "left_hand" else "right")) as XRHandTracker

func _input_focused() -> bool:
	return display.preview or display.session_state == "session_focussed"

func _controller_allowed(hand: String) -> bool:
	if not _input_focused(): return false
	# Query current data too: XR input signals may arrive before our process callback.
	return not HandPointer.is_optical(_hand_tracker(hand)) and not (hand_pointers.has(hand) and hand_pointers[hand].source == "hand")

func _controller_ray(hand: String) -> Variant:
	var controller := left_controller if hand == "left_hand" else right_controller
	if not controller or not controller.get_is_active() or not controller.get_has_tracking_data(): return null
	var pose := controller.get_pose()
	if not pose or pose.tracking_confidence == XRPose.XR_TRACKING_CONFIDENCE_NONE: return null
	return [controller.global_position, -controller.global_basis.z]

func _update_hand_input(delta: float) -> void:
	for hand in hand_pointers:
		var sample := {}
		if _input_focused():
			var tracker := _hand_tracker(hand)
			if HandPointer.is_optical(tracker) and xr_camera and xr_origin and _head_tracked():
				sample = HandPointer.sample(tracker, hand, xr_camera.global_transform,
					xr_origin.global_transform * XRServer.get_reference_frame(), XRServer.world_scale)
			elif not HandPointer.is_optical(tracker):
				var ray: Variant = _controller_ray(hand)
				if ray != null: sample = {"source": "controller", "ray": ray}
		var event: Dictionary = hand_pointers[hand].update(sample, delta)
		if event.cancelled: _cancel_pointer(hand)
		if event.pressed: _on_pointer_button("trigger_click", hand)
		if event.released: _on_pointer_release("trigger_click", hand)
		if hand_marks.has(hand):
			var pointer: RefCounted = hand_pointers[hand]
			var mark: MeshInstance3D = hand_marks[hand]
			mark.visible = pointer.source == "hand" and pointer.ray != null and not _active_menu()
			if mark.visible:
				mark.global_position = pointer.ray[0]
				mark.scale = Vector3.ONE * XRServer.world_scale * (0.65 if pointer.down else 1.0)

func _cancel_pointer(hand: String) -> void:
	if not _grab.is_empty() and _grab.hand == hand:
		if _grab.moved and not _grab.has("inspect") and _viewer().geometry == Geometry.Geometry.FLAT: _save_screen()
		_grab = {}
		_viewer().set_corner_hover(-1)
	# Cancellation never becomes a tap, row selection, or fling.
	for menu in [recent_menu, video_menu, photo_menu]:
		if is_instance_valid(menu) and menu.has_method("cancel_pointer"): menu.cancel_pointer(hand)

func _on_input_session_changed() -> void:
	if _input_focused(): return
	for hand in hand_pointers:
		hand_pointers[hand].update({}, 0)
		_cancel_pointer(hand)
		if hand_marks.has(hand): hand_marks[hand].visible = false

func _hand_input_report() -> Dictionary:
	var report := {}
	for hand in hand_pointers:
		var pointer: RefCounted = hand_pointers[hand]
		report[hand] = {"source": pointer.source, "tracked": pointer.ray != null, "pinching": pointer.down}
	return report

# --- dragging the picture -------------------------------------------------------------------

const GRAB_START := 0.035   # radians the ray turns before a trigger press becomes a drag
const MOUSE_TURN := 0.004   # radians per pixel in the desktop preview
const ZOOM_SPEED := 0.6     # sphere radii per second at full deflection
const PUSH_SPEED := 1.5     # metres per second the held flat screen moves at full deflection
const STICK_DEADZONE := 0.2
## Trigger held outside the menus: hand, start/last ray angles (yaw, pitch), moved; a press on a
## flat screen corner adds resize = {corner, start_length, start_scale}.
var _grab := {}

func _eye() -> Vector3:
	if is_instance_valid(_viewer().view_camera) and _viewer().view_camera.is_inside_tree():
		return _viewer().view_camera.global_position
	return Vector3(0, 1.6, 0)

func _ray(hand: String) -> Variant:
	if not _input_focused(): return null
	if hand_pointers.has(hand) and hand_pointers[hand].source == "hand": return hand_pointers[hand].ray
	if HandPointer.is_optical(_hand_tracker(hand)): return null
	return _controller_ray(hand)

## A ray near a flat screen corner shows its bracket: pressing there resizes.
func _update_corner_hover() -> void:
	if not video or not _viewer().has_method("corner_at"):
		return
	var corner := -1
	if _grab.has("resize"):
		corner = int(_grab.resize.corner)
	elif _grab.is_empty() and not recent_menu.visible and not _viewer().local_uri.is_empty() and not (photo_active and photo.inspect):
		for hand in ["right_hand", "left_hand"]:
			var ray: Variant = _ray(hand)
			if ray != null and not (player_menu.visible and player_menu._hover.get(hand, -1) != -1):
				corner = _viewer().corner_at(ray[0], ray[1])
				if corner >= 0:
					break
	_viewer().set_corner_hover(corner)

func _begin_grab(hand: String) -> void:
	if not _grab.is_empty(): return
	var ray: Variant = _ray(hand)
	if ray == null:
		if player_menu.visible:
			player_menu.dismiss()
		return
	var angles := _ray_angles(ray[1])
	_grab = {"hand": hand, "start": angles, "last": angles, "moved": false}
	if photo_active and photo.inspect:
		photo.inspect_ray(ray[0], ray[1])
		_grab["inspect"] = true
		_grab.moved = true
		return
	var corner: int = _viewer().corner_at(ray[0], ray[1])
	var point: Variant = _viewer().screen_point(ray[0], ray[1]) if corner >= 0 else null
	if point != null and Vector2(point.x, point.y).length() > 0.05:
		_grab["resize"] = {"corner": corner, "start_length": Vector2(point.x, point.y).length(), "start_scale": _viewer().screen_scale}

func _update_grab() -> void:
	if _grab.is_empty():
		return
	var ray: Variant = _ray(_grab.hand)
	if ray == null \
		or not video or _viewer().local_uri.is_empty() or recent_menu.visible:
		_grab = {}
		return
	if _grab.has("inspect") and photo.geometry != Geometry.Geometry.FLAT:
		photo.inspect_ray(ray[0], ray[1], true)
		return
	var angles := _ray_angles(ray[1])
	if not _grab.moved:
		var turned: Vector2 = angles - _grab.start
		turned.x = wrapf(turned.x, -PI, PI)
		if turned.length() < GRAB_START:
			return
		_grab.moved = true
	if _grab.has("resize"):
		# The corner follows the ray: the screen grows or shrinks about its centre.
		var point: Variant = _viewer().screen_point(ray[0], ray[1])
		if point != null:
			_viewer().set_screen_scale(float(_grab.resize.start_scale) * Vector2(point.x, point.y).length() / float(_grab.resize.start_length))
		return
	var step: Vector2 = angles - _grab.last
	_grab.last = angles
	_turn_picture(wrapf(step.x, -PI, PI), step.y)

## Yaw (positive left) and pitch (positive up) of a direction.
static func _ray_angles(direction: Vector3) -> Vector2:
	var unit := direction.normalized()
	return Vector2(atan2(-unit.x, -unit.z), asin(clampf(unit.y, -1.0, 1.0)))

## The picture follows the pointer: immersive views turn, the flat screen moves around the head
## at its distance and keeps facing the eyes.
func _turn_picture(yaw: float, pitch: float) -> void:
	if photo_active and photo.inspect:
		photo.pan_content(Vector2(yaw, pitch))
		return
	if _viewer().geometry != Geometry.Geometry.FLAT:
		_viewer().turn_view(yaw, pitch)
		return
	var eye := _eye()
	var offset: Vector3 = _viewer().panel.global_position - eye
	var distance := offset.length()
	if distance < 0.1:
		return
	var angles := _ray_angles(offset) + Vector2(yaw, pitch)
	var facing := Basis(Vector3.UP, angles.x) * Basis(Vector3.RIGHT, clampf(angles.y, -1.3, 1.3))
	_viewer().flat_pose = _viewer().global_transform.affine_inverse() * Transform3D(facing, eye + facing * Vector3(0, 0, -distance))
	_viewer().panel.transform = _viewer().flat_pose

## The flat screen nearer (negative) or farther along the line from the eyes, still facing them.
func _push_screen(amount: float) -> void:
	var eye := _eye()
	var offset: Vector3 = _viewer().panel.global_position - eye
	if offset.length() < 0.1:
		return
	_viewer().set_screen_distance(offset.length() + amount)
	var pose := Transform3D(_viewer().panel.global_basis, eye + offset.normalized() * _viewer().screen_distance)
	_viewer().flat_pose = _viewer().global_transform.affine_inverse() * pose
	_viewer().panel.transform = _viewer().flat_pose

func _save_screen() -> void:
	settings.set_value("photo_screen" if photo_active else "screen", "distance", _viewer().screen_distance)
	settings.set_value("photo_screen" if photo_active else "screen", "scale", _viewer().screen_scale)
	settings.set_value("photo_screen" if photo_active else "screen", "curve", _viewer().screen_curve)
	settings.save(settings_path)

## Right stick press: the picture back in front at its natural size and distance (the curve stays).
func _reset_picture() -> void:
	_viewer().reset_view()
	_viewer().set_screen_distance(_viewer().SCREEN_DISTANCE)
	_viewer().set_screen_scale(1.0)
	_save_screen()
	_recenter()

func _update_menu_pointer(hand: String, pressed: bool = false) -> bool:
	var menu := _active_menu()
	if not menu or hand not in ["left_hand", "right_hand"]:
		return false
	var ray: Variant = _ray(hand)
	var tracked := ray != null
	var origin: Vector3 = ray[0] if tracked else Vector3.ZERO
	var direction: Vector3 = ray[1] if tracked else Vector3.ZERO
	if pressed:
		_menu_touched_ms = Time.get_ticks_msec()
		return menu.press_pointer(hand, origin, direction, tracked)
	menu.update_pointer(hand, origin, direction, tracked)
	return true

const CONTROLS_HIDE_MS := 5000
var _menu_touched_ms := 0

func _viewer() -> Node3D:
	return photo if photo_active and photo else video

func _on_library_chosen(uri: String, title: String) -> void:
	var is_photo: bool = ImageInfo.is_image(uri, title) or recent_menu.is_image_uri(uri)
	recent_menu.dismiss()
	if player_menu: player_menu.dismiss()
	_grab = {}
	stick_controls.left_latched = true; stick_controls.right_latched = true
	if is_photo:
		video.close_video()
		photo_active = true
		player_menu = photo_menu
		photo.open_image(uri, title, recent_menu.image_queue())
		_show_player_menu()
	else:
		photo.close_image()
		photo_active = false
		player_menu = video_menu
		var metadata: Dictionary = recent_menu.server_browser.selection.duplicate(true) if uri.begins_with("medialib://") else {}
		recent_menu.server_browser.selection = {}
		if metadata.get("uri", "") != uri: metadata = {}
		if video.open_library(uri, title, metadata): _show_player_menu()

func _on_photo_changed() -> void:
	if not photo_active: return
	_update_background()
	if player_menu and player_menu.visible: player_menu.refresh_values()
	if calibration_board: calibration_board.visible = false

func _on_photo_action(operation: String) -> void:
	_menu_touched_ms = Time.get_ticks_msec()
	match operation:
		"photo_previous": photo.navigate(-1)
		"photo_next": photo.navigate(1)
		"photo_inspect": photo.toggle_inspect()
		"photo_fit": photo.reset_view(); photo.changed.emit()
		"photo_zoom_in": photo.zoom_view(0.15)
		"photo_zoom_out": photo.zoom_view(-0.15)
		"stop": photo.close_image(); _show_recent_menu()
		"recenter": _recenter()
		"depth":
			if photo.set_depth(not photo.depth_requested): _remember_auto_depth(photo.auto_depth)
		"depth_strength": photo.cycle_depth_strength()
		"projection_0", "projection_1", "projection_2", "projection_3": photo.set_projection(int(operation.right(1)))
		"lock_mode":
			photo.toggle_mode_lock()
			settings.set_value("photo", "mode_lock", photo.mode_lock)
			settings.save(settings_path)
		"stereo_2d": _remember_auto_depth(false); photo.set_depth(false); photo.set_stereo_layout(0)
		"stereo_sbs": photo.set_stereo_layout(1)
		"stereo_tb": photo.set_stereo_layout(2)
		"eyes": photo.toggle_eye_order()
		"fov_180", "fov_190", "fov_200", "fov_220": photo.set_fisheye_fov(int(operation.right(3)))
		"screen_curve": photo.cycle_screen_curve(); _save_screen(); photo.changed.emit()
		"photo_background":
			if background.import_photo(photo.background_source(), photo.display_name):
				_show_recent_menu()
				recent_menu.section = recent_menu.Section.SETTINGS
				recent_menu.tab = recent_menu.BACKGROUND_TAB
				recent_menu.refresh()
		_:
			if operation.begins_with("photo_index_"): photo._select(int(operation.trim_prefix("photo_index_")))

var _screen_uri := ""

## The flat screen and the menus are placed in front of the eyes (yaw only) when a video opens,
## a menu is shown or the view is recentered, and stay put while the head moves. The player
## controls float below the line of sight, over the lower edge of the screen.
func _view_pose(distance: float, drop: float) -> Variant:
	if not is_instance_valid(_viewer().view_camera) or not _viewer().view_camera.is_inside_tree():
		return null # host tests and desktop preview without an XR camera
	var head: Transform3D = _viewer().view_camera.global_transform
	var forward: Vector3 = -head.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD
	return Transform3D(Basis(Vector3.UP, atan2(-forward.x, -forward.z)), head.origin + forward * distance + Vector3(0, -drop, 0))

func _place_screen() -> void:
	var pose: Variant = _view_pose(_viewer().screen_distance, 0.0)
	if pose != null:
		_viewer().flat_pose = _viewer().global_transform.affine_inverse() * pose
		if _viewer().geometry == Geometry.Geometry.FLAT:
			_viewer().panel.transform = _viewer().flat_pose

func _place_menu(menu: Node3D) -> void:
	var drop := 0.45 if menu == player_menu else 0.05
	var pose: Variant = _view_pose(1.4, drop)
	if pose == null:
		menu.position = Vector3(0, 1.45, -1.55)
	else:
		# Below eye level, the controls tilt up to face the eyes.
		menu.global_transform = Transform3D(pose.basis * Basis(Vector3.RIGHT, -atan2(drop, 1.4)), pose.origin)

func _active_menu() -> Node3D:
	if recent_menu and recent_menu.visible:
		return recent_menu
	if player_menu and player_menu.visible:
		return player_menu
	return null

func _toggle_player_menu() -> void:
	if player_menu and player_menu.visible:
		player_menu.dismiss()
	else:
		_show_player_menu()

func _show_player_menu() -> void:
	if recent_menu:
		recent_menu.dismiss()
	if player_menu and not player_menu.visible:
		_place_menu(player_menu)
		_menu_touched_ms = Time.get_ticks_msec()
		player_menu.toggle()

func _show_recent_menu() -> void:
	if player_menu:
		player_menu.dismiss()
	if recent_menu and not recent_menu.visible:
		_place_menu(recent_menu)
		recent_menu.toggle()

func _library_settings() -> Dictionary:
	return {"output_width": int(settings.get_value("video", "output_width", 0)),
		"history": video.history_enabled,
		"subtitle_distance": video.subtitle_distance,
		"background": background.choice if background else "belfast",
		"background_custom": background.has_custom() if background else false,
		"background_title": background.custom_title if background else "",
		"background_yaw": background.yaw if background else 0.0,
		"background_brightness": background.brightness if background else 1.0,
		"background_loading": background.loading if background else false,
		"background_error": background.error if background else "",
		"version": str(ProjectSettings.get_setting("application/config/version", ""))}

func _on_setting_changed(key: String, value: Variant) -> void:
	match key:
		"background":
			if background.select(str(value)): _save_background()
		"background_yaw": background.rotate_sky(); _save_background()
		"background_brightness": background.cycle_brightness(); _save_background()
		"output_width":
			settings.set_value("video", "output_width", int(value))
			settings.save(settings_path)
			if platform_plugin:
				platform_plugin.set_mpv_output_width(int(value))
		"history":
			video.history_enabled = bool(value)
			photo.history_enabled = bool(value)
			settings.set_value("library", "history", bool(value))
			settings.save(settings_path)
		"clear_history":
			video.clear_history()
		"language":
			settings.set_value("ui", "language", str(value))
			settings.save(settings_path)
			I18n.use(str(value))
			if platform_plugin and platform_plugin.has_method("set_ui_language"):
				platform_plugin.set_ui_language(I18n.choice)
			for menu in [recent_menu, player_menu, photo_menu]:
				if menu.visible:
					menu.refresh()
		"subtitle_distance":
			video.subtitle_distance = float(value)
			settings.set_value("subtitles", "distance", video.subtitle_distance)
			settings.save(settings_path)
	Log.record("setting_changed", {"key": key, "value": value})

func _on_menu_action(operation: String) -> void:
	if photo_active:
		_on_photo_action(operation)
		return
	match operation:
		"open_file": _show_recent_menu()
		"play": video.toggle_play()
		"alpha": video.set_alpha(not video.alpha_wanted())
		"depth":
			if video.set_depth(not video.depth_requested): _remember_auto_depth(video.auto_depth)
		"depth_strength":
			video.cycle_depth_strength()
			settings.set_value("video", "depth_strength", video.depth_strength)
			settings.save(settings_path)
		"clone_voice":
			if video.toggle_clone_voice():
				settings.set_value("audio", "prefer_clone_voice", video.prefer_clone_voice)
				settings.save(settings_path)
		"seek_back": video.seek_relative(-10000)
		"seek_forward": video.seek_relative(10000)
		"loop": video.toggle_loop()
		"stop": video.close_video()
		"stereo": video.toggle_stereo()
		"eyes": video.toggle_eye_order()
		"projection": video.cycle_projection()
		"projection_0", "projection_1", "projection_2", "projection_3": video.set_projection(int(operation.right(1)))
		"stereo_2d":
			_remember_auto_depth(false)
			video.set_depth(false) # plain 2D: also ends 2D -> 3D
			video.set_stereo_layout(0)
		"lock_mode":
			video.toggle_mode_lock()
			settings.set_value("video", "mode_lock", video.mode_lock)
			settings.save(settings_path)
		"stereo_sbs": video.set_stereo_layout(1)
		"stereo_tb": video.set_stereo_layout(2)
		"fov_180", "fov_190", "fov_200", "fov_220": video.set_fisheye_fov(int(operation.right(3)))
		"recenter": _recenter()
		"screen_curve":
			video.cycle_screen_curve()
			_save_screen()
		"calibration": video.play_calibration_clip()
		"volume_down": video.change_volume(-10.0)
		"volume_up": video.change_volume(10.0)
		"mute": video.toggle_mute()
		"audio": video.cycle_audio_track()
		"capabilities": request_capabilities()

func _on_menu_seek(position_ms: int) -> void:
	if photo_active: return
	video.seek_absolute(position_ms)

## Muting keeps the level, so unmuting (left stick) brings the sound back where it was.
func _on_menu_volume(volume: float, muted: bool) -> void:
	if photo_active: return
	video.set_audio_options(video.audio_track_id, video.audio_volume if muted else volume, muted)

func _on_depth_strength(strength: float, for_photo: bool) -> void:
	var viewer: Node3D = photo if for_photo else video
	if viewer.set_depth_strength(strength):
		settings.set_value("photo" if for_photo else "video", "depth_strength", viewer.depth_strength)
		_remember_auto_depth(viewer.auto_depth)

func _remember_auto_depth(enabled: bool) -> void:
	if video: video.auto_depth = enabled
	if photo: photo.auto_depth = enabled
	if settings.get_value("effects", "auto_3d", false) != enabled:
		settings.set_value("effects", "auto_3d", enabled)
		settings.save(settings_path)

func _save_depth_strength() -> void:
	# Keep dragging live without writing settings on every pointer movement.
	settings.save(settings_path)

func _menu_state() -> Dictionary:
	if not video:
		return {}
	var details: Dictionary = video.media.playback.get("details", {})
	var text_tracks: Array[Dictionary] = []
	for track in details.get("subtitle_tracks", []):
		if track is Dictionary and Video.SubtitleState.text_codec(str(track.get("codec", ""))):
			text_tracks.append(track)
	return {"has_video": not video.local_uri.is_empty() and video.media.accepts(video.media.session_id),
		"playing": video.requested_play, "playback_state": video.media.state,
		"alpha_requested": video.alpha_wanted(), "alpha_enabled": video.alpha_enabled,
		"loop": video.loop_enabled, "stereo": video.stereo_sbs, "swap_eyes": video.swap_eyes,
		"top_bottom": video.stereo_sbs and video.top_bottom, "fisheye_fov": video.fisheye_fov,
		"projection": ["Flat", "VR180", "Fisheye", "360"][video.geometry], "geometry": video.geometry, "profile": video.profile,
		"mode_lock": video.mode_lock,
		"volume": video.audio_volume, "muted": video.audio_muted,
		"audio_available": details.get("audio_tracks", []).size() > 0,
		"audio_tracks": details.get("audio_tracks", []).size(), "audio_track": _audio_track_name(details),
		"clone_voice": video.clone_voice_track() > 0, "clone_voice_active": video.clone_voice_active(),
		"depth_requested": video.depth_requested, "depth_enabled": video.depth_enabled, "depth_strength": video.depth_strength,
		"screen_curve": video.screen_curve,
		"subtitle_distance": video.subtitle_distance, "color_grade": video.color_grade.snapshot(),
		"grade_values": video.color_grade.values(),
		"depth_error": str(video.media.playback.get("depth_error", "")),
		"text_subtitle_tracks": text_tracks.size(), "subtitle_options": text_tracks,
		"subtitle_track": video.subtitles.requested_track, "source_uri": video.local_uri,
		"title": video.display_name, "source_size": "%s x %s" % [video.media.format.get("width", "?"), video.media.format.get("height", "?")],
		"codec": details.get("codec", "Unknown codec"),
		"position_ms": video.control.observed_position_ms, "duration_ms": video.control.duration_ms,
		"xr_state": "Desktop preview" if display.preview else display.session_state,
		"capabilities_available": platform_plugin != null,
		"error": _menu_error()}

## The selected track's title (external tracks such as the clone voice have one), else its id.
func _audio_track_name(details: Dictionary) -> String:
	var current := str(details.get("audio_track_id", ""))
	for track in details.get("audio_tracks", []):
		if track is Dictionary and str(track.get("id", "")) == current and not str(track.get("title", "")).is_empty():
			return str(track.title)
	return current if not current.is_empty() else "Auto"

func _menu_error() -> String:
	var error: String = video.picker_error if not video.picker_error.is_empty() else video.media.error
	if error.is_empty():
		error = display.error_code
	match error:
		"PERMISSION_LOST", "LOCAL_DOCUMENT_PERMISSION_LOST": error = "File access lost. Select the video again (PERMISSION_LOST)."
		"MISSING", "LOCAL_DOCUMENT_MISSING": error = "Video no longer exists. Select another file (MISSING)."
		"TIMEOUT", "LOCAL_DOCUMENT_TIMEOUT": error = "File access timed out. Try opening again."
		"UNREADABLE": error = "Unable to read the video. Select another file."
	return I18n.t(error)

func _apply_stick_actions(actions: Array[Dictionary], delta: float = 1.0 / 72.0) -> void:
	if photo_active:
		for action in actions:
			if action.operation == "zoom": photo.zoom_picture(float(action.amount) * ZOOM_SPEED * delta)
			elif action.operation == "seek" and not photo.inspect: photo.navigate(int(action.direction))
		return
	for action in actions:
		match action.operation:
			"zoom": video.zoom_view(float(action.amount) * ZOOM_SPEED * delta)
			"seek": video.seek_relative(int(action.direction) * 10000)
			"volume": video.change_volume(float(action.direction) * 10)
			"audio_track": video.cycle_audio_track(int(action.direction))
			"mute": video.toggle_mute()
			"subtitle": video.cycle_subtitle_track(int(action.direction))
			"swap_eyes": video.toggle_eye_order()

func _request_rvm_benchmark(vulkan: bool, profile: String = "256x144") -> void:
	if not platform_plugin:
		rvm_status = "Android RVM benchmark requires Quest"
		_update_status()
		return
	var id: int = platform_plugin.request_rvm_profile_benchmark(vulkan, profile)
	if id <= 0:
		rvm_status = "RVM benchmark busy or unavailable"
	else:
		last_rvm_request = id
		var profile_index := RVM_PROFILES.find(profile)
		next_rvm_case = (profile_index * 2 + (2 if vulkan else 1)) % (RVM_PROFILES.size() * 2)
		rvm_status = "RVM %s %s validation running" % [profile, "Vulkan" if vulkan else "CPU"]
	_update_status()

func _on_rvm_result(id: int, payload: String) -> void:
	if id != last_rvm_request:
		return
	var parser := JSON.new()
	if parser.parse(payload) != OK or not parser.data is Dictionary:
		rvm_status = "RVM benchmark report invalid"
		_update_status()
		return
	rvm_report = parser.data
	rvm_status = "RVM %s %s: %s" % [rvm_report.get("profile_key", rvm_report.get("requested_profile", "?")),
		rvm_report.get("backend", "native"), rvm_report.get("state", "unknown")]
	Log.record("rvm_validation_result", rvm_report)
	_save_report()

func _request_controlled_probe() -> void:
	if not platform_plugin or not video or video.local_uri.is_empty():
		controlled_status = "Select a video or calibration clip first"
		_update_status()
		return
	if controlled_request > 0:
		platform_plugin.close_controlled_video(controlled_request)
	# The probe has a video-only clock. Pause normal audio/video while validating it.
	platform_plugin.set_mpv_playing(video.media.session_id, false)
	controlled_report = {}
	controlled_request = platform_plugin.request_controlled_probe(video.local_uri, 0, video.stereo_sbs,
		"256x256" if video.stereo_sbs else "256x144")
	controlled_status = "Controlled decode probe running" if controlled_request > 0 else "Controlled decode probe unavailable"
	_update_status()

func _on_controlled_event(id: int, payload: String, kind: String) -> void:
	if id != controlled_request:
		return
	var parser := JSON.new()
	if parser.parse(payload) != OK or not parser.data is Dictionary:
		controlled_status = "Controlled probe invalid report"
		return
	controlled_report[kind] = parser.data
	if kind == "frame":
		controlled_status = "Controlled frames: %s | PTS matched | immutable slot" % parser.data.get("captured_frames", 0)
	else:
		controlled_status = "Controlled probe: %s" % parser.data.get("state", parser.data.get("code", "unknown"))
		Log.record("controlled_" + kind, parser.data)
	_update_status()

func _toggle_display() -> void:
	if photo_active: return
	if not video.local_uri.is_empty():
		video.set_alpha(not video.alpha_wanted())
	else:
		background.select("dark" if background.choice == "passthrough" else "passthrough")
		_save_background()
	_save_report()

func _on_video_changed() -> void:
	if photo_active: return
	_update_background()
	_update_status()
	if player_menu and player_menu.visible:
		player_menu.refresh_values()

func _on_background_changed() -> void:
	_update_background()
	if recent_menu and recent_menu.visible and recent_menu.section == recent_menu.Section.SETTINGS and recent_menu.tab == recent_menu.BACKGROUND_TAB:
		recent_menu.refresh()

func _update_background() -> void:
	if not background or not display.environment: return
	var immersive := false
	var alpha := false
	if photo_active and photo:
		immersive = not photo.local_uri.is_empty() and photo.geometry != Geometry.Geometry.FLAT
	elif video:
		var active: bool = video.has_active_presentation()
		alpha = active and (video.alpha_wanted() or video.alpha_enabled)
		immersive = active and video.geometry != Geometry.Geometry.FLAT
	# Alpha temporarily overrides the saved scenery. An explicit passthrough choice
	# also applies behind immersive media, including the unused half of VR180.
	var wants_passthrough: bool = alpha or background.choice == "passthrough"
	display.set_scenery(null if immersive or wants_passthrough else background.ready_sky(), background.yaw)
	var passthrough: bool = wants_passthrough and display.supports_passthrough()
	if display.applied_passthrough != passthrough: display.set_passthrough(passthrough)

func _save_background() -> void:
	settings.set_value("appearance", "background", background.choice)
	settings.set_value("appearance", "background_yaw", background.yaw)
	settings.set_value("appearance", "background_brightness", background.brightness)
	settings.save(settings_path)

func _on_custom_background_saved(path: String, title: String, orientation: int) -> void:
	settings.set_value("appearance", "custom_path", path)
	settings.set_value("appearance", "custom_title", title)
	settings.set_value("appearance", "custom_orientation", orientation)
	settings.set_value("appearance", "background", background.choice)
	settings.save(settings_path)
	if background.choice == "custom" and photo_active: photo.close_image()

func _recenter() -> void:
	if not display.preview:
		XRServer.center_on_hmd(XRServer.RESET_BUT_KEEP_TILT, true)
	# The view moves once the runtime applies the recenter: then bring the screen and menus in front of it.
	if is_inside_tree():
		await get_tree().create_timer(0.15).timeout
	if not _viewer().local_uri.is_empty():
		_place_screen()
	if photo_active and photo.inspect and photo.geometry != Geometry.Geometry.FLAT: photo._place_detail()
	for menu in [recent_menu, player_menu]:
		if menu and menu.visible:
			_place_menu(menu)
	Log.record("recenter_requested")

func request_capabilities() -> void:
	if platform_plugin:
		last_request = platform_plugin.request_capabilities()
		Log.record("capability_probe_requested", {"request_id": last_request})

func _on_capabilities_ready(request_id: int, json_report: String) -> void:
	if request_id != last_request:
		return
	var parsed: Variant = JSON.parse_string(json_report)
	if parsed is Dictionary:
		android_report = parsed
		Log.record("capability_probe_completed", {"request_id": request_id})
	else:
		Log.record("capability_probe_invalid", {"request_id": request_id})
	_save_report()

func _on_android_lifecycle(event: String) -> void:
	Log.record("android_lifecycle", {"event": event})
	if event == "resume":
		request_capabilities()
	elif event == "pause" and video:
		video.checkpoint_playback()

func _save_report() -> void:
	var report := {
		"schema_version": 1,
		"app_version": ProjectSettings.get_setting("application/config/version"),
		"engine": Engine.get_version_info(),
		"captured_unix_seconds": Time.get_unix_time_from_system(),
		"xr": display.capabilities(),
		"android": android_report,
		"stage": "MP04_shared_MPV_RVM_display_development",
		"video_implemented": true,
		"video_device_validation": "pending",
		"media": video.media.snapshot() if video else {},
		"video_layout": video.layout_snapshot() if video else {},
		"active_media": "image" if photo_active else "video",
		"hand_input": _hand_input_report(),
		"background": background.choice if background else "",
		"photo": photo.snapshot() if photo else {},
		"rvm_implemented": true,
		"rvm_benchmark": rvm_report,
		"rvm_video_integrated": true,
		"mpv_rvm_device_validation": "pending",
		"controlled_decode": controlled_report,
	}
	var encoded := JSON.stringify(report, "\t")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://diagnostics"))
	var file := FileAccess.open("user://diagnostics/capabilities_latest.json", FileAccess.WRITE)
	if file:
		file.store_string(encoded)
	if platform_plugin:
		var saved_path: String = platform_plugin.save_capability_report(encoded)
		if saved_path.begins_with("ERROR:"):
			Log.record("capability_report_save_failed", {"reason": saved_path})
	_update_status()

func _update_status() -> void:
	if not status_label:
		return
	var mode := "Passthrough" if display.applied_passthrough else "Opaque"
	var detail := "Desktop preview" if display.preview else display.session_state
	status_label.position.y = 2.45
	status_label.visible = OS.get_cmdline_user_args().has("--show-diagnostics")
	calibration_board.visible = status_label.visible and not (video and video.panel and video.panel.visible)
	if not status_label.visible:
		return
	status_label.text = "Thru3D Media Player - MPV\n%s | %s\nLeft Menu / Tab: player menu\nPoint with a controller and press trigger to select\nA,X / O: open file   Grip / Space: play,pause\nLeft click / P: projection   Right click: reset view\nRight stick / arrows: seek 10s   L: loop\nB / R: recenter   Trigger / T: Alpha,background\nV: fixture" % [mode, detail]
	if video:
		status_label.text += "\n%s | %s | %s | %s\n%s | RVM %s" % [video.display_name.left(42), video.media.state, "SBS" if video.stereo_sbs else "2D", video.layout_snapshot().geometry, "Alpha on" if video.alpha_enabled else ("Preparing Alpha" if video.alpha_requested else "Normal playback"), video.profile]
		status_label.text += "\n" + rvm_status
		status_label.text += "\n" + controlled_status
		status_label.text += "\n%.1f / %.1f s | %s | loop %s" % [video.control.observed_position_ms / 1000.0, video.control.duration_ms / 1000.0, video.control.snapshot().state, "on" if video.loop_enabled else "off"]
		status_label.text += "\nAudio: %s | %.0f%% | %s\nL up/down: volume | L left/right: track" % [str(video.media.playback.get("details", {}).get("audio_track_id", "none")), video.audio_volume, "muted" if video.audio_muted else "on"]
		status_label.text += "\nSubtitles: %s | C: track" % ("off" if video.subtitles.requested_track == 0 else str(video.subtitles.requested_track))
		status_label.text += "\nEyes: %s | E: swap" % ("R/L" if video.swap_eyes else "L/R")
		if not video.picker_error.is_empty():
			status_label.text += "\n" + video.picker_error
		if not video.media.error.is_empty():
			status_label.text += "\n" + video.media.error
	if not display.error_code.is_empty():
		status_label.text += "\n" + display.error_code


func _on_playback_adjustment(key: String, value: Variant) -> void:
	if key == "subtitle_distance":
		video.subtitle_distance = float(value)
	elif key == "grade_preset":
		video.color_grade.select(str(value))
	elif key == "grade_reset":
		video.color_grade.reset_custom()
	else:
		video.color_grade.adjust(key, value)
	video.color_grade.apply(video.material)

func _save_playback_adjustments() -> void:
	settings.set_value("subtitles", "distance", video.subtitle_distance)
	settings.set_value("video", "color_grade", video.color_grade.snapshot())
	settings.save(settings_path)
