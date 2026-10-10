extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Platform := preload("res://tests/test_media_servers.gd").Platform
const I18n := preload("res://scripts/i18n.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("QUEST_PLEX_PREVIEW_DIR")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	for language in ["zh", "en", "ja"]:
		I18n.use(language)
		var menu := Menu.new(); camera.add_child(menu)
		var platform := Platform.new(); menu.attach_platform(platform); menu.visible = true; menu.section = Menu.Section.MEDIA_SERVER
		var panel: RefCounted = menu.account_panel
		for page in ["choose", "form", "link", "pending", "checking", "expired", "servers"]:
			panel.open("server")
			if page != "choose":
				panel.start("server", "plex"); panel.data.fields.base = "http://192.168.31.185:32400"
			if page in ["link", "pending", "checking", "expired"]:
				panel.view = "plex_link"; panel.data.result = {"code":"ABCD","link":"plex.tv/link"}
				if page == "pending": panel.data.error = "Pairing not completed"
				if page == "checking": panel.data.busy = true
				if page == "expired": panel.data.error = "Pairing code expired"; panel.data.pairing_expired = true
			if page == "servers": panel.view = "plex_servers"; panel.items = [{"id":"one","name":"Living room"},{"id":"two","name":"Remote NAS"}]
			panel.paused = true; menu.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join(language + "-" + page + ".png"))
		menu.free(); platform.free()
	viewport.queue_free(); await process_frame
	print("Plex account previews rendered")
	quit()
