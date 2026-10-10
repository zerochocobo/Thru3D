extends SceneTree

## Desktop OpenGL render of the library menu in each section, with a text-overflow guard.
const Menu := preload("res://scripts/library_menu.gd")
const Test := preload("res://tests/test_library_menu.gd")

class Catalog extends RefCounted:
	func list_recent() -> Array[Dictionary]:
		var rows: Array[Dictionary] = []
		for index in 9:
			rows.append({"uri": "smb://s/%d.mp4" % index, "title": "[180 VR] 舞台演出 第%d场 - very long file name for bounds.mp4" % index,
				"position_ms": 61000 * index})
		return rows

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	# English unless a language preview is asked for (QUEST_UI_LANGUAGE=zh).
	preload("res://scripts/i18n.gd").use(OS.get_environment("QUEST_UI_LANGUAGE") if OS.has_environment("QUEST_UI_LANGUAGE") else "en")
	var output := OS.get_environment("QUEST_LIBRARY_PREVIEW_DIR")
	if output.is_empty():
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1400, 900)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 60
	viewport.add_child(camera)
	var platform := Test.FakePlatform.new()
	var menu := Menu.new()
	menu.catalog = Catalog.new()
	menu.settings_provider = func(): return {"profile": "320x320", "profiles": ["320x320", "384x216", "512x512"], "output_width": 0, "version": ProjectSettings.get_setting("application/config/version"), "display_quality_pending": true}
	camera.add_child(menu)
	menu.attach_platform(platform)
	menu.storage_eject_requested.connect(func(volume): menu.finish_storage_release(volume.id))
	menu.toggle()
	var failures: Array[String] = []
	var steps := [["recent", []], ["local_all", [Menu.NAV_BASE + Menu.Section.LOCAL]], ["local_folder", [Menu.ROW_BASE]],
		["local_usb", [Menu.USB_STORAGE]], ["local_usb_eject", [Menu.EJECT_STORAGE]],
		["smb", [Menu.NAV_BASE + Menu.Section.SMB, Menu.REFRESH]], ["smb_share", [Menu.ROW_BASE, Menu.ROW_BASE]],
		["smb_editor", [Menu.BACK, Menu.BACK, Menu.ADD, Menu.KEY_BASE + 1, Menu.KEY_BASE + 9]],
		["dlna", [Menu.CANCEL, Menu.NAV_BASE + Menu.Section.DLNA]], ["cloud", [Menu.NAV_BASE + Menu.Section.CLOUD]],
		["cloud_folder", [Menu.ROW_BASE]], ["settings", [Menu.NAV_BASE + Menu.Section.SETTINGS]], ["video", [Menu.TAB_BASE + Menu.VIDEO_TAB]], ["subtitles", [Menu.TAB_BASE + Menu.SUBTITLES_TAB]], ["about", [Menu.TAB_BASE + Menu.ABOUT_TAB]],
		["language", [Menu.TAB_BASE + Menu.GENERAL_TAB]], ["display", [Menu.TAB_BASE + Menu.DISPLAY_TAB]], ["credits", [Menu.TAB_BASE + Menu.ABOUT_TAB, Menu.ABOUT_HOME, Menu.ROW_BASE + 5]], ["credits_end", []]]
	if OS.get_environment("QUEST_ABOUT_PREVIEW_ONLY") == "1":
		steps = [["about", [Menu.NAV_BASE + Menu.Section.SETTINGS, Menu.TAB_BASE + Menu.ABOUT_TAB]],
			["language", [Menu.TAB_BASE + Menu.GENERAL_TAB]], ["display", [Menu.TAB_BASE + Menu.DISPLAY_TAB]], ["credits", [Menu.TAB_BASE + Menu.ABOUT_TAB, Menu.ABOUT_HOME, Menu.ROW_BASE + 5]], ["credits_end", []]]
	if OS.get_environment("QUEST_MODELS_PREVIEW_ONLY") == "1":
		steps = [["settings", [Menu.NAV_BASE + Menu.Section.SETTINGS]], ["subtitles", [Menu.TAB_BASE + Menu.SUBTITLES_TAB]],
			["background", [Menu.TAB_BASE + Menu.BACKGROUND_TAB]], ["about", [Menu.TAB_BASE + Menu.ABOUT_TAB]],
			["language", [Menu.TAB_BASE + Menu.GENERAL_TAB]], ["display", [Menu.TAB_BASE + Menu.DISPLAY_TAB]], ["credits", [Menu.TAB_BASE + Menu.ABOUT_TAB, Menu.ABOUT_HOME, Menu.ROW_BASE + 5]], ["credits_end", []]]
	if OS.get_environment("QUEST_STORAGE_PREVIEW_ONLY") == "1":
		steps = [["local_all",[Menu.NAV_BASE+Menu.Section.LOCAL]],["local_folder",[Menu.ROW_BASE]],
			["local_usb",[Menu.USB_STORAGE]],["local_usb_eject",[Menu.EJECT_STORAGE]]]
	for step in steps:
		for target in step[1]:
			menu._activate(target)
			await process_frame
			await process_frame
		if step[0] == "credits_end":
			menu.scroll = menu._max_scroll()
			menu._draw()
		menu.update_pointer("right_hand", menu.to_global(Vector3(0.47,0.46,0.1) if str(step[0]).begins_with("local_usb") else Vector3(0.2,0.33,0.1)), -menu.global_basis.z, true)
		await process_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		# Bounds: the browser panel with the round actions and status pill under it, and the angled navigation column.
		var corners: Array[Vector3] = [menu.to_global(Vector3(-0.6, 0.57, 0)), menu.to_global(Vector3(0.87, -0.76, 0))]
		for corner in [Vector3(-0.22, 0.57, 0), Vector3(0.22, -0.57, 0), Vector3(-0.22, -0.57, 0), Vector3(0.22, 0.57, 0)]:
			corners.append(menu._side.to_global(corner))
		var top_left := Vector2(INF, INF)
		var bottom_right := Vector2(-INF, -INF)
		for corner in corners:
			var pixel := camera.unproject_position(corner)
			top_left = top_left.min(pixel)
			bottom_right = bottom_right.max(pixel)
		var overflow := 0
		for y in image.get_height():
			for x in image.get_width():
				if x >= top_left.x and x <= bottom_right.x and y >= top_left.y and y <= bottom_right.y:
					continue
				var pixel := image.get_pixel(x, y)
				if minf(pixel.r, minf(pixel.g, pixel.b)) > 0.8:
					overflow += 1
		if overflow != 0:
			failures.append("Text outside the panel in %s: %d px" % [step[0], overflow])
		image.save_png(output.path_join("%s.png" % step[0]))
	var report := {"state": "passed" if failures.is_empty() else "failed", "failures": failures}
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	menu.queue_free()
	viewport.queue_free()
	await process_frame
	platform.free()
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
