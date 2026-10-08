extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
var checks := 0
var failures: Array[String] = []

class InputMain extends "res://scripts/main.gd":
	var test_ray: Variant
	func _ray(_hand: String) -> Variant: return test_ray

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var main := InputMain.new()
	main.settings_path = "user://flat-screen-test.cfg"
	var video := Video.new()
	root.add_child(video)
	video.set_process(false)
	main.video = video
	video.local_uri = "file:///flat-test.mp4"
	video.media.begin(1)
	video.media.format = {"width": 1920, "height": 1080}
	var menu := Menu.new()
	menu.state_provider = main._menu_state
	menu.adjustment_requested.connect(main._on_playback_adjustment)
	menu.adjustment_committed.connect(main._save_playback_adjustments)
	root.add_child(menu)
	menu.set_process(false)
	main.player_menu = menu
	main.recent_menu = Node3D.new()
	main.recent_menu.visible = false
	var eye := Vector3(0, 1.6, 0)
	for mode in ["2d", "sbs", "tb", "depth", "warped_depth"]:
		video.stereo_sbs = mode in ["sbs", "tb"]
		video.top_bottom = mode == "tb"
		video.depth_requested = mode in ["depth", "warped_depth"]
		video.depth_enabled = video.depth_requested
		video._binding.warped = mode == "warped_depth"
		for curve in [0.0, 0.7]:
			video.screen_curve = curve
			video.screen_distance = 2.0
			video.screen_scale = 1.0
			video.flat_pose = Transform3D(Basis(), eye + Vector3(0, 0, -2))
			video._apply_geometry()
			video.panel.visible = true
			var size: Vector2 = video._flat.size
			menu.toggle() if not menu.visible else menu.refresh()
			main.test_ray = [eye, Vector3.FORWARD]
			main._on_pointer_button("trigger_click", "right_hand")
			check(not menu.visible and main._grab.get("hid_menu", false), "%s screen press closes controls" % mode)
			main._update_flat_grab_stick(Vector2(0, 1), Vector2.ZERO, 0.4)
			check(video.screen_scale == 1.0, "Other hand cannot scale held screen")
			main._update_flat_grab_stick(Vector2.ZERO, Vector2(0, 1), 0.4)
			check(video.screen_scale > 1.0 and video.screen_distance == 2.0, "%s held up grows at fixed distance" % mode)
			var grown: float = video.screen_scale
			video._apply_geometry() # Next native frame must retain the new mesh and pose.
			check(video._flat.size.is_equal_approx(size * grown), "%s presented frame preserves size" % mode)
			main._update_flat_grab_stick(Vector2.ZERO, Vector2(0, -1), 0.4)
			check(is_equal_approx(video.screen_scale, 1), "%s down shrinks symmetrically" % mode)
			main._on_pointer_release("trigger_click", "right_hand")
			check(main._grab.is_empty() and not menu.visible, "Release finishes without reopening controls")
			for corner in [0, 1]:
				video.set_screen_scale(1)
				var hit: Vector3 = video.panel.to_global(video.screen_corner(corner))
				main.test_ray = [eye, (hit - eye).normalized()]
				main._begin_grab("right_hand")
				check(main._grab.has("resize"), "%s curve %s corner %s begins resize" % [mode, curve, corner])
				main._update_corner_hover()
				check(video._handles[corner].visible, "Active corner bracket is visible")
				main.test_ray = [eye, (video.panel.to_global(Vector3(video.screen_corner(corner).x * 1.5, video.screen_corner(corner).y * 1.5, 0)) - eye).normalized()]
				main._update_grab()
				check(video.screen_scale > 1 and video.screen_distance == 2, "%s corner grows without moving distance" % mode)
				main._on_pointer_release("trigger_click", "right_hand")
			video.set_screen_scale(1)
			main._grab = {"hand": "right_hand", "moved": false}
			menu.toggle()
			main._update_flat_grab_stick(Vector2.ZERO, Vector2(0, 1), 1)
			check(video.screen_scale == 1, "Open menu blocks held stick playback action")
			main._grab = {}
			menu.section = 1
			menu.refresh()
			menu._activate(100 + Menu.OPERATIONS[1].find("screen_distance"))
			check(menu._adjustment == "screen_distance", "%s opens distance editor" % mode)
			menu.press_pointer("right_hand", menu.to_global(Vector3(0.63, 0.17, 1)), -menu.global_basis.z, true)
			check(video.screen_distance == 8 and is_equal_approx(video.panel.global_position.distance_to(eye), 8) and video.screen_scale == 1, "Distance slider moves screen without scaling")
			menu.release_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, true)
			var saved := ConfigFile.new()
			check(saved.load(main.settings_path) == OK and saved.get_value("screen", "distance") == 8, "Distance saves on release")
			menu._activate(421)
			check(video.screen_distance == 2, "2m preset restores default distance")
			menu.dismiss()
	main._grab = {"hand": "right_hand", "moved": false}
	main._update_flat_grab_stick(Vector2.ZERO, Vector2(0, 1), 10)
	check(video.screen_scale == video.SCALE_LIMITS.y, "Upper scale limit")
	main._update_flat_grab_stick(Vector2.ZERO, Vector2(0, -1), 10)
	check(video.screen_scale == video.SCALE_LIMITS.x, "Lower scale limit")
	main._grab = {}
	video.geometry = 1
	menu.toggle()
	menu.section = 1
	menu.refresh()
	menu._activate(100 + Menu.OPERATIONS[1].find("screen_distance"))
	check(menu._adjustment.is_empty() and not menu._enabled("screen_distance"), "Immersive projection disables flat distance")
	main._on_playback_adjustment("screen_distance", 5)
	check(video.screen_distance == 2, "Immersive adjustment cannot change flat screen")
	menu.free()
	main.recent_menu.free()
	main.free()
	video.free()
	for failure in failures: push_error(failure)
	print("Flat screen controls: %s (%d)" % ["passed" if failures.is_empty() else "failed", checks])
	quit(0 if failures.is_empty() else 1)
