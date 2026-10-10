extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_dlna_menu.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("QUEST_DLNA_PREVIEW_DIR")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 65; viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu)
	var platform := Fixture.Platform.new(); menu.attach_platform(platform); menu.toggle(); menu.section = Menu.Section.DLNA
	menu._dlna_servers = platform.servers.duplicate(true)
	for language in ["zh", "en"]:
		preload("res://scripts/i18n.gd").use(language)
		for page in ["servers", "add", "edit", "error"]:
			menu._editor = {}; menu._dlna_server = ""; menu.status = ""
			if page != "servers": menu._open_editor({} if page == "add" else platform.servers[0])
			if page == "error": menu.status = "DLNA server unavailable; check the address and port"
			menu.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join(language + "-" + page + ".png"))
	menu.free(); platform.free(); viewport.queue_free(); await process_frame; print("DLNA menu previews rendered"); quit()
