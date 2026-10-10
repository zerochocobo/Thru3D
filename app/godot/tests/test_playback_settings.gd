extends SceneTree
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var rates: Array = []
	var accept := true
	func set_mpv_speed(id: int, rate: float) -> bool:
		if not accept: return false
		rates.append([id, rate])
		return true
	func close_mpv_video(_id: int) -> void: pass

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func click(menu: Node3D, target: int) -> bool:
	for button in menu._buttons:
		if button.target == target and button.enabled:
			var point: Vector2 = button.rect.get_center()
			var origin: Vector3 = menu.to_global(Vector3(point.x, point.y, 1))
			menu.press_pointer("right", origin, -menu.global_basis.z, true)
			menu.release_pointer("right", origin, -menu.global_basis.z, true)
			return true
	return false

func drag(menu: Node3D, target: int, fraction: float) -> void:
	var button: Dictionary = menu._buttons.filter(func(row): return row.target == target)[0]
	var point := Vector3(0.03 + 0.6 * fraction, button.rect.get_center().y, 1)
	menu.press_pointer("right", menu.to_global(point), -menu.global_basis.z, true)
	menu.release_pointer("right", menu.to_global(point), -menu.global_basis.z, true)

func button(menu: Node3D, target: int) -> Dictionary:
	return menu._buttons.filter(func(row): return row.target == target)[0]

func reset_shown(menu: Node3D, target: int) -> bool:
	var reset := button(menu, target)
	return reset.enabled and reset.node.visible

func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var main := Main.new()
	main.settings_path = "user://playback-settings-regression.cfg"
	var video := Video.new()
	root.add_child(video)
	video.set_process(false)
	main.video = video
	var host := Host.new()
	video.platform = host
	video.local_uri = "file:///movie.mp4"
	video.media.begin(7)
	video.media.format = {"width": 1920, "height": 1080}
	video.media.playback = {"details": {"pgs_supported": true, "subtitle_tracks": [{"id": 1, "codec": "subrip"}, {"id": 2, "codec": "hdmv_pgs_subtitle"}]}}
	video.flat_pose = Transform3D(Basis(), Vector3(0, 1.6, -2))
	video._apply_geometry()
	video.panel.visible = true
	var menu := Menu.new()
	menu.state_provider = main._menu_state
	menu.adjustment_requested.connect(main._on_playback_adjustment)
	menu.adjustment_committed.connect(main._save_playback_adjustments)
	menu.setting_requested.connect(main._on_player_setting)
	root.add_child(menu)
	menu.set_process(false)
	main.player_menu = menu
	var camera := Camera3D.new()
	camera.position = Vector3(0, 1.6, 0)
	root.add_child(camera)
	video.view_camera = camera
	main._place_menu(menu)
	check(menu.global_basis.is_equal_approx(Basis.IDENTITY), "Below-eye menu remains upright")
	var top_width := camera.unproject_position(menu.to_global(Vector3(0.5, 1, 0))).x - camera.unproject_position(menu.to_global(Vector3(-0.5, 1, 0))).x
	var bottom_width := camera.unproject_position(menu.to_global(Vector3(0.5, 0, 0))).x - camera.unproject_position(menu.to_global(Vector3(-0.5, 0, 0))).x
	check(is_equal_approx(top_width, bottom_width), "Upper popup rows are not compressed by menu tilt")
	menu.toggle()
	check(click(menu, 11) and menu._adjustment == "screen", "Settings opens Screen directly")
	check(is_equal_approx(menu.global_position.y, camera.global_position.y), "Full settings rise to eye level")
	check(menu._adjust_rows.size() == 3 and menu.text_snapshot().contains("Screen size"), "Flat panel includes distance, size and rotation")
	check(not menu.text_snapshot().contains("Audio track") and not menu.text_snapshot().contains("Subtitles") and not menu.text_snapshot().contains("3D depth"), "Screen panel contains no duplicate controls")
	check(not reset_shown(menu, Menu.ROTATION_RESET) and not click(menu, Menu.ROTATION_RESET), "Zero rotation hides and disables reset")
	for scale in [0.4, 1.0, 1.5, 3.0]:
		video.set_screen_scale(scale)
		menu.refresh_values()
		var row: Dictionary = menu._adjust_rows[451]
		var percent: float = scale * 100
		check(is_equal_approx(main._menu_state().screen_scale, percent) and row.label.text == "%d%%" % roundi(percent), "Physical scale, menu state and percentage agree")
		check(is_equal_approx(row.knob.position.x, 0.03 + (percent - 40) / 260 * 0.6), "Screen size thumb matches displayed percentage")
	drag(menu, 451, 0)
	check(is_equal_approx(video.screen_scale, 0.4) and video.screen_distance == 2, "Minimum screen size changes no distance")
	check(menu._adjust_rows[451].label.text == "40%" and is_equal_approx(menu._adjust_rows[451].knob.position.x, 0.03), "Minimum drag displays 40% at the start")
	drag(menu, 451, 1)
	check(video.screen_scale == 3 and is_equal_approx(video._flat.size.x / video._flat.size.y, 16.0 / 9), "Maximum screen size preserves aspect")
	check(menu._adjust_rows[451].label.text == "300%" and is_equal_approx(menu._adjust_rows[451].knob.position.x, 0.63), "Maximum drag displays 300% at the end")
	drag(menu, 452, 1)
	check(video.screen_rotation == 90 and absf(video.panel.global_basis.x.y) > 0.99, "Rotation slider reaches clockwise 90 degrees")
	check(reset_shown(menu, Menu.ROTATION_RESET) and is_equal_approx(button(menu, Menu.ROTATION_RESET).rect.get_center().y, button(menu, 452).rect.get_center().y), "Rotation reset appears on its slider row")
	check(not button(menu, Menu.ROTATION_RESET).rect.intersects(button(menu, 452).rect), "Rotation reset does not overlap slider hit area")
	video.caption.text = "第一行字幕\nSecond subtitle line"
	video.caption.visible = true
	video._place_caption()
	check(video.caption.global_basis.is_equal_approx(Basis.IDENTITY), "Flat subtitle remains horizontal at 90 degrees")
	main._push_screen(1.0)
	check(video.screen_rotation == 90 and video.subtitle_transform().basis.is_equal_approx(Basis.IDENTITY), "Changing distance does not bake or double rotation")
	main._push_screen(-1.0)
	var bottom := video.caption.global_position.y
	main._on_playback_adjustment("subtitle_flat_position", 100)
	video._place_caption()
	check(video.caption.global_position.y > bottom and video.subtitle_position == 0, "Flat position rises without changing VR angle")
	main._on_playback_adjustment("subtitle_size", 200)
	video._place_caption()
	check(video.caption.font_size == 80 and video.caption.outline_size == 16, "Font and outline grow together")
	check(is_equal_approx(video.caption.pixel_size, 0.0016 * video.screen_scale), "Flat text scales with the screen")
	main._save_playback_adjustments()
	var saved := ConfigFile.new()
	check(saved.load(main.settings_path) == OK and saved.get_value("subtitles", "size") == 2 and saved.get_value("subtitles", "flat_position") == 1, "Text size and flat position persist")
	check(click(menu, Menu.ROTATION_RESET) and video.screen_rotation == 0 and video.screen_scale == 3 and video.screen_distance == 2, "Straighten changes only rotation")
	check(not reset_shown(menu, Menu.ROTATION_RESET) and not menu.text_snapshot().contains("Straighten"), "Rotation reset disappears immediately after restoration")
	for geometry in [1, 2, 3]:
		video.geometry = geometry
		video._apply_geometry()
		menu.refresh()
		check(menu._adjust_rows.size() == 1 and menu._adjust_rows[452].key == "screen_rotation", "Immersive mode offers rotation and hides flat controls")
		video.turn_view(0.2, 0.1)
		video.zoom_view(0.1)
		var yaw: float = video.view_yaw
		var pitch: float = video.view_pitch
		var zoom: float = video.view_zoom
		video.screen_rotation = 0
		video._apply_geometry()
		var pose: Transform3D = video.subtitle_transform()
		video.set_screen_rotation(-90)
		menu.refresh_values()
		video._place_caption()
		video._sync_subtitle_surface()
		check(video._subtitle_surface.visible and video._subtitle_surface.global_transform.is_equal_approx(pose), "VR captions keep their pose while the picture rolls")
		check(click(menu, Menu.ROTATION_RESET) and video.view_yaw == yaw and video.view_pitch == pitch and video.view_zoom == zoom, "VR straighten preserves direction and zoom")
	video.geometry = 0
	video._apply_geometry()
	menu.refresh()
	check(click(menu, Menu.PLAYBACK_SETTINGS) and not menu.text_snapshot().contains("Eye order"), "Mono playback settings hide eye order")
	check(not reset_shown(menu, Menu.SPEED_RESET) and not click(menu, Menu.SPEED_RESET), "Default playback rate hides and disables reset")
	for fraction in [0.0, 1.0]:
		drag(menu, 453, fraction)
		check(is_equal_approx(video.playback_speed, (0.25 if fraction == 0 else 3.0)) and host.rates.back() == [7, video.playback_speed], "Speed slider changes actual bridge rate at endpoint")
		check(reset_shown(menu, Menu.SPEED_RESET), "Non-default rate shows reset while dragging")
	check(is_equal_approx(button(menu, Menu.SPEED_RESET).rect.get_center().y, button(menu, 453).rect.get_center().y) and not button(menu, Menu.SPEED_RESET).rect.intersects(button(menu, 453).rect), "Speed reset shares its row without overlapping the rail")
	check(click(menu, Menu.SPEED_RESET) and video.playback_speed == 1.0 and host.rates.back() == [7, 1.0], "Restore 1x reaches bridge")
	check(not reset_shown(menu, Menu.SPEED_RESET) and not menu.text_snapshot().contains("Restore 1×"), "Speed reset disappears immediately at 1x")
	check(not video.set_playback_speed(NAN) and not video.set_playback_speed(0) and not video.set_playback_speed(3.1), "Invalid rates are rejected")
	host.accept = false
	check(not video.set_playback_speed(2) and video.playback_speed == 1, "Rejected native change leaves displayed rate unchanged")
	video.stereo_sbs = true
	menu.refresh()
	check(menu._buttons.any(func(b): return b.node.get_children().any(func(n): return n is Label3D and n.text == "Eye order")), "Flat native stereo retains eye order")
	video.stereo_sbs = false
	click(menu, 10)
	click(menu, 110)
	check(menu.choices.sliders.size() == 2 and menu.text_snapshot().contains("External subtitles must match the video filename."), "Flat CC provides size, vertical position and naming guidance")
	video.subtitles.select(2)
	menu.refresh()
	check(menu.choices.sliders.is_empty(), "PGS preserves source layout and hides text controls")
	video.subtitles.select(1)
	menu.refresh()
	check(menu.choices.sliders.size() == 2, "Text controls return despite PGS also being listed")
	menu.free()
	video.free()
	main.free()
	camera.free()
	for failure in failures: push_error(failure)
	print("Playback settings: %s (%d)" % ["passed" if failures.is_empty() else "failed", checks])
	quit(0 if failures.is_empty() else 1)
