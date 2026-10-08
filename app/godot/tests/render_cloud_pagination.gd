extends SceneTree

const Menu := preload("res://scripts/library_menu.gd")
const Test := preload("res://tests/test_cloud_pagination.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("QUEST_CLOUD_PREVIEW_DIR")
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
	var platform := Test.Platform.new()
	var menu := Menu.new()
	camera.add_child(menu)
	menu.attach_platform(platform)
	menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.CLOUD)
	platform.respond(1)
	menu._choose(menu.rows[0])
	platform.respond(2, 10001)
	for language in ["en", "zh", "zh_Hant", "ja"]:
		preload("res://scripts/i18n.gd").use(language)
		for state in ["first", "middle", "error", "last"]:
			menu._cloud_page = 0 if state == "first" else (208 if state == "last" else 100)
			menu._cloud_next = -1 if state == "last" else (menu._cloud_page + 1) * 48
			menu.status = "Cloud connection failed" if state == "error" else ""
			menu.refresh()
			await process_frame
			await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join("%s-%s.png" % [language, state]))
	menu.queue_free()
	viewport.queue_free()
	platform.free()
	print("Cloud pagination rendered: 16 previews")
	quit()
