extends SceneTree

const Menu := preload("res://scripts/player_menu.gd")
var state := {"has_video": true, "geometry": 1, "playing": true, "playback_state": "playing", "alpha_requested": true,
	"alpha_enabled": false, "stereo": true, "swap_eyes": false, "projection": "Fisheye", "profile": "512x512",
	"volume": 90, "muted": false, "audio_available": true, "audio_tracks": 2, "audio_track": 2,
	"text_subtitle_tracks": 2, "subtitle_track": 3, "capabilities_available": true,
	"subtitle_options": [{"id": 1, "codec": "subrip", "title": "旅行记录.zh-CN.srt"},
		{"id": 3, "codec": "ass", "title": "旅行记录.双语.ass"}, {"id": 8, "codec": "webvtt", "title": "Travel.journal.en.vtt"},
		{"id": 11, "codec": "subrip", "title": "旅行记录.导演评论.srt"}],
	"title": "中文字幕 😀 旅行记录 " + "界".repeat(40), "source_size": "3840 x 1920", "codec": "hevc",
	"position_ms": 123456, "duration_ms": 600000, "xr_state": "focused", "error": "PERMISSION_LOST: Please select the video again."}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	# English unless a language preview is asked for (QUEST_UI_LANGUAGE=zh).
	preload("res://scripts/i18n.gd").use(OS.get_environment("QUEST_UI_LANGUAGE") if OS.has_environment("QUEST_UI_LANGUAGE") else "en")
	var output := OS.get_environment("QUEST_PLAYER_MENU_PREVIEW_DIR")
	if output.is_empty():
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 900)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 48
	viewport.add_child(camera)
	var menu := Menu.new()
	menu.state_provider = func(): return state
	camera.add_child(menu)
	menu.toggle()
	var snapshots: Dictionary = {}
	var overflow_pixels: Dictionary = {}
	var failures: Array[String] = []
	for section in Menu.TABS.size():
		menu.section = section
		menu.refresh()
		var hover_rect: Rect2 = menu._buttons[mini(5, menu._buttons.size() - 1)].rect
		var hover_centre := hover_rect.get_center()
		menu.update_pointer("left_hand", menu.to_global(Vector3(hover_centre.x, hover_centre.y, 0.1)), -menu.global_basis.z, true)
		await process_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		var top_left := camera.unproject_position(menu.to_global(Vector3(-0.775, 0.54, 0)))
		var bottom_right := camera.unproject_position(menu.to_global(Vector3(0.775, -0.54, 0)))
		# The battery and clock pill sits under the panel on purpose.
		var pill: Node3D = menu.device_status
		var half: Vector2 = pill._pill.mesh.size / 2
		var pill_min := camera.unproject_position(pill.to_global(Vector3(-half.x, half.y, 0)))
		var pill_max := camera.unproject_position(pill.to_global(Vector3(half.x, -half.y, 0)))
		var overflow := 0
		for y in image.get_height():
			for x in image.get_width():
				if x >= top_left.x and x <= bottom_right.x and y >= top_left.y and y <= bottom_right.y:
					continue
				if x >= pill_min.x and x <= pill_max.x and y >= pill_min.y and y <= pill_max.y:
					continue
				var pixel := image.get_pixel(x, y)
				if minf(pixel.r, minf(pixel.g, pixel.b)) > 0.8: overflow += 1
		overflow_pixels[str(section)] = overflow
		if overflow != 0: failures.append("Text outside backdrop at section %d: %d" % [section, overflow])
		if image.save_png(output.path_join("section_%d.png" % section)) != OK:
			quit(1)
			return
		snapshots[str(section)] = menu.text_snapshot()
	menu.section = 1
	for detail in ["subtitle_distance", "color_grade"]:
		menu._adjustment = detail
		for page in (3 if detail == "color_grade" else 1):
			menu._grade_page = page
			menu.refresh()
			await process_frame
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join("%s_%d.png" % [detail, page]))
	menu._adjustment = ""
	state.error = ""
	state.title = "Travel journal · VR180"
	state.alpha_enabled = true
	menu.section = 0
	menu.refresh()
	menu.update_pointer("left_hand", Vector3.ZERO, Vector3.ZERO, false)
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output.path_join("playback.png"))
	# Flat 2D source: depth is a first-level control beside Alpha, with the picker closed.
	state.title = "Travel journal · 2D"
	state.geometry = 0
	state.stereo = false
	state.alpha_requested = false
	state.alpha_enabled = false
	state["depth_requested"] = true
	state["depth_enabled"] = true
	menu.refresh()
	var depth_rect: Rect2 = menu._buttons.filter(func(b): return b.target == 112)[0].rect
	menu.update_pointer("left_hand", menu.to_global(Vector3(depth_rect.get_center().x, depth_rect.get_center().y, 0.1)), -menu.global_basis.z, true)
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output.path_join("playback_depth.png"))
	state.title = "Travel journal · VR180"
	state.geometry = 1
	state.stereo = true
	state.alpha_requested = true
	state.alpha_enabled = true
	state["depth_requested"] = false
	state["depth_enabled"] = false
	# Video mode grid open, a ray resting on the Alpha button: its name shows above it.
	menu._mode_open = true
	menu.refresh()
	var alpha_rect: Rect2 = menu._buttons.filter(func(b): return b.target == 104)[0].rect
	menu.update_pointer("left_hand", menu.to_global(Vector3(alpha_rect.get_center().x, alpha_rect.get_center().y, 0.1)), -menu.global_basis.z, true)
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output.path_join("playback_modes.png"))
	if not menu._tooltip or not menu._tooltip.visible or menu._tooltip.get_child(0).text != "Alpha":
		failures.append("Hovered bar icon shows its name")
	# Fisheye: lens angles under the layouts; a top-bottom source lit.
	state["geometry"] = 2
	state["stereo"] = true
	state["top_bottom"] = true
	state["fisheye_fov"] = 200
	state["mode_lock"] = {"geometry": 2, "layout": 2, "depth": false, "fisheye_fov": 200} # lock marks on Fisheye and 3D TB
	menu.refresh()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output.path_join("playback_modes_fisheye.png"))
	if menu._buttons.filter(func(b): return b.target >= menu.MODE_LENS and b.target < menu.MODE_LENS + 4).size() != 4:
		failures.append("Fisheye shows four lens angles")
	menu._mode_open = false
	# Volume slider raised from the sound icon.
	state["volume"] = 35
	menu._volume_open = true
	menu.refresh()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output.path_join("playback_volume.png"))
	if menu._buttons.filter(func(b): return b.target == menu.VOLUME).size() != 1:
		failures.append("Sound icon raises the volume slider")
	menu._volume_open = false
	menu._activate(110)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output.path_join("subtitles-selected.png"))
	if menu._subtitle_ids.values() != [0, 1, 3, 8]: failures.append("Subtitle picker must show Off and real IDs")
	state.subtitle_track = 0
	menu.refresh_values()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output.path_join("subtitles-off.png"))
	menu._activate(110)
	menu.section = 1
	menu.refresh()
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output.path_join("settings-simplified.png"))
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({
		"state": "passed" if failures.is_empty() else "failed", "snapshots": snapshots,
		"overflow_white_pixels": overflow_pixels, "failures": failures,
		"scope": "Production player menu desktop OpenGL rendering with supplied state; Quest pixels and physical input unverified"}, "\t"))
	for failure in failures: push_error(failure)
	viewport.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
