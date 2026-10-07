extends SceneTree

const Menu := preload("res://scripts/recent_menu.gd")

class Catalog extends RefCounted:
	func list_recent() -> Array[Dictionary]:
		var rows: Array[Dictionary] = []
		for index in 32:
			rows.append({"uri": "content://preview/video%d" % index,
				"title": "中文字幕 😀 旅行记录" if index == 0 else ("界".repeat(42) if index == 1 else "Video %02d / very long filename to check the menu bounds.mp4" % index),
				"position_ms": 123000 + index * 1000})
		return rows

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	# English unless a language preview is asked for (QUEST_UI_LANGUAGE=zh).
	preload("res://scripts/i18n.gd").use(OS.get_environment("QUEST_UI_LANGUAGE") if OS.has_environment("QUEST_UI_LANGUAGE") else "en")
	var output := OS.get_environment("QUEST_RECENT_PREVIEW_DIR")
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
	menu.catalog = Catalog.new()
	camera.add_child(menu)
	menu.toggle()
	var snapshots: Dictionary = {}
	var failures: Array[String] = []
	var overflow_pixels: Dictionary = {}
	for focus in [0, 2, 32]:
		menu.focus_index = focus
		menu.page = focus / Menu.PAGE_SIZE
		menu.refresh()
		var row_y: float = 0.25 - (int(focus) % Menu.PAGE_SIZE) * 0.087
		menu.update_pointer("right_hand", menu.to_global(Vector3(0.6, row_y, 0.1)), -menu.global_basis.z, true)
		await process_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		var top_left := camera.unproject_position(menu.to_global(Vector3(-0.775, 0.54, 0)))
		var bottom_right := camera.unproject_position(menu.to_global(Vector3(0.775, -0.54, 0)))
		var overflow := 0
		for y in image.get_height():
			for x in image.get_width():
				if x >= top_left.x and x <= bottom_right.x and y >= top_left.y and y <= bottom_right.y:
					continue
				var pixel := image.get_pixel(x, y)
				if minf(pixel.r, minf(pixel.g, pixel.b)) > 0.8:
					overflow += 1
		overflow_pixels[str(focus)] = overflow
		if overflow != 0:
			failures.append("Text pixels outside backdrop at focus %d: %d" % [focus, overflow])
		if image.save_png(output.path_join("focus_%d.png" % focus)) != OK:
			quit(1)
			return
		snapshots[str(focus)] = menu.text_snapshot()
	var report := {"state": "passed" if failures.is_empty() else "failed", "snapshots": snapshots,
		"overflow_white_pixels": overflow_pixels, "failures": failures,
		"scope": "Actual production pointer menu/buttons/hover/dot desktop OpenGL rendering with mock catalog; physical Quest glyphs/input/XR pending"}
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	viewport.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
