extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const CloudTest := preload("res://tests/test_cloud_accounts.gd")
const ServerTest := preload("res://tests/test_media_servers.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("QUEST_ACCOUNT_PREVIEW_DIR")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400, 1000); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 65; viewport.add_child(camera)
	for language in ["en", "zh", "zh_Hant", "ja"]:
		preload("res://scripts/i18n.gd").use(language)
		var menu := Menu.new(); camera.add_child(menu)
		var platform := CloudTest.Platform.new(); menu.attach_platform(platform); menu.toggle()
		menu.section = Menu.Section.CLOUD
		menu._cloud_entries = [{"id": "/first", "title": "115 · 家庭影音", "container": true}, {"id": "/second", "title": "Baidu · 旅行相册", "container": true}]
		for mode in ["", "remove", "confirm"]:
			menu.cloud_accounts.mode = mode
			menu.cloud_accounts.removing = menu._cloud_entries[0]
			menu.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join(language + "-cloud-" + ("list" if mode.is_empty() else mode) + ".png"))
		menu.cloud_accounts.reset()
		menu._cloud_stack = [{"id": "/first", "title": "115 · 家庭影音"}, {"id": "/first/videos", "title": "很长的目录名称 · 全景旅行视频"}, {"id": "/first/videos/2026", "title": "Another very long nested folder name"}]
		menu.refresh()
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(output.path_join(language + "-cloud-folder.png"))
		menu.free(); platform.free()
		menu = Menu.new(); camera.add_child(menu)
		var servers := ServerTest.Platform.new(); menu.attach_platform(servers); menu.toggle()
		menu.section = Menu.Section.MEDIA_SERVER
		menu.server_browser.servers = [{"id": "emby", "name": "Emby · 客厅 NAS", "provider": "emby"}]
		menu.refresh()
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(output.path_join(language + "-servers.png"))
		menu.free(); servers.free()
	viewport.queue_free(); await process_frame
	print("account management previews rendered")
	quit()
