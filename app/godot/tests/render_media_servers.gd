extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Test := preload("res://tests/test_media_servers.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	preload("res://scripts/i18n.gd").use("zh")
	var output := OS.get_environment("QUEST_SERVER_PREVIEW_DIR")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400, 1000); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 65; viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu)
	var platform := Test.Platform.new(); menu.attach_platform(platform); menu.toggle()
	menu.section = Menu.Section.MEDIA_SERVER
	var b: RefCounted = menu.server_browser
	b.server = {"id": "preview", "name": "Stash · 客厅 NAS"}
	b.view = "scenes"; b.total = 1545
	var image := Image.create(512, 288, false, Image.FORMAT_RGB8)
	for y in 288:
		for x in 512: image.set_pixel(x, y, Color(0.1 + x / 1300.0, 0.2 + y / 950.0, 0.28 + x / 1600.0))
	var texture := ImageTexture.create_from_image(image)
	for i in 12:
		b.entries.append({"id": str(i + 1), "title": "山川与湖泊 · 全景旅程 %02d" % (i + 1), "duration_ms": 645000 + i * 15000, "uri": "medialib://preview/scene/%d" % (i + 1)})
		b.textures["preview/%d" % (i + 1)] = texture
	b.set_filter("tags", {"id": "12", "name": "自然风光"}, false)
	b.set_filter("tags", {"id": "34", "name": "夜间"}, true)
	b.servers = [{"id": "preview", "name": "客厅 NAS", "provider": "stash", "base": "http://nas:9999"}]
	b.removing = b.servers[0]
	for page in ["scenes", "filters", "candidates", "detail", "servers", "remove_servers", "confirm_remove", "keyboard"]:
		b.view = page
		if page == "candidates":
			b.kind = "tags"; b.candidate_total = 8
			b.candidates = [{"id": "12", "name": "自然风光"}, {"id": "34", "name": "夜间"}, {"id": "56", "name": "高山"}, {"id": "78", "name": "沙漠"}, {"id": "80", "name": "城市"}]
		if page == "detail":
			b.detail = {"id": "1", "title": "山川与湖泊 · 全景旅程", "uri": "medialib://preview/scene/1", "description": "从群山到湖畔，一段安静的全景旅程。", "tags": [{"id": "12", "name": "自然风光"}], "performers": [], "markers": [{"position_ms": 0, "title": "起点"}, {"position_ms": 120000, "title": "湖畔"}]}
		if page == "keyboard": b.keyboard = "search"; b.text = "panorama"
		menu._reset_navigation(); menu.refresh()
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(output.path_join(page + ".png"))
	menu.free(); platform.free(); viewport.queue_free(); await process_frame
	print("media server previews rendered")
	quit()
