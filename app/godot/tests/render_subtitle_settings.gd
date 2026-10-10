extends SceneTree
const Library := preload("res://scripts/library_menu.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("SUBTITLE_SETTINGS_OUTPUT")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 900)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 48
	viewport.add_child(camera)
	var menu := Library.new()
	camera.add_child(menu)
	var state := {"subtitle_distance": 5.0, "subtitle_position": 0.0}
	menu.settings_provider = func(): return state
	menu.toggle()
	menu._activate(Library.NAV_BASE + Library.Section.SETTINGS)
	menu._activate(Library.TAB_BASE + Library.SUBTITLES_TAB)
	for language in ["zh", "en"]:
		preload("res://scripts/i18n.gd").use(language)
		for direction in [0, 1]:
			state.subtitle_direction = direction
			for angle in [-60.0, 0.0, 60.0]:
				state.subtitle_position = angle
				state.subtitle_distance = 0.1 if angle < 0 else (10.0 if angle > 0 else 5.0)
				menu.refresh()
				await process_frame
				await RenderingServer.frame_post_draw
				await RenderingServer.frame_post_draw
				viewport.get_texture().get_image().save_png(output.path_join("settings_%s_direction%d_%d.png" % [language, direction, angle]))
	viewport.queue_free()
	await process_frame
	quit()
