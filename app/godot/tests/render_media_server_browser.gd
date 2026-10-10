extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_media_servers.gd")
const Test := preload("res://tests/test_media_server_browser.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("QUEST_SERVER_PREVIEW_DIR")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 65; viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu)
	var platform := Fixture.Platform.new(); menu.attach_platform(platform); menu.toggle(); menu.section = Menu.Section.MEDIA_SERVER
	var b: RefCounted = menu.server_browser; b.server = {"id": "profile", "name": "DENNIS-NEW", "provider": "emby"}; b.capabilities = Test.CAPS; b.library_id = "lib1"; b.total = 250; b.end_reached = false; b.loaded_page = 1
	var movies: Array = []
	var names := ["远山来信", "蓝色时刻", "深海回声", "月面航行", "夜行列车", "北境之光", "城市边缘", "荒野之路"]
	for i in 8:
		var node := {"id": str(i + 1), "title": names[i], "uri": "medialib://profile/scene/%d" % (i + 1), "duration_ms": 6540000, "position_ms": 2322000 if i == 1 else 0, "tags": [{"id": "自然", "name": "自然"}], "genres": [{"id": "纪录", "name": "纪录"}], "markers": [{"title": "起点", "position_ms": 0}, {"title": "山间", "position_ms": 180000}]}
		movies.append(node)
		var image := Image.create(256, 360, false, Image.FORMAT_RGB8)
		var hue := 0.48 + i * 0.055
		for y in 360:
			for x in 256:
				var color := Color.from_hsv(fmod(hue, 1.0), 0.42, 0.40 - float(y) / 1300.0)
				var d := Vector2(x - 140, y - 107).length()
				if d < 65: color = color.lerp(Color.from_hsv(fmod(hue + 0.15, 1.0), 0.21, 0.8), (1.0 - d / 65.0) * 0.8)
				if y > 230 + sin(float(x) / 40.0 + i) * 29: color = color.darkened(0.45)
				image.set_pixel(x, y, color)
		b.textures["profile/%d" % (i + 1)] = ImageTexture.create_from_image(image)
	b.home_data = {"recent": movies.slice(0, 4), "resume": [movies[1]], "libraries": [{"id": "lib1", "title": "Movies"}]}
	for language in ["zh", "en"]:
		preload("res://scripts/i18n.gd").use(language)
		for page in ["home", "scenes", "facets", "folders", "detail", "filters", "favorites"]:
			b.view = page; b.query = {"page": 1, "q": "", "all_tags": true}; b.folder_path.clear(); b.entries = movies.duplicate(true); b.candidates = []; b.detail = {}
			if page == "facets": b.kind = "genres"; b.candidate_total = 33; b.candidates = [{"id": "纪录", "name": "纪录", "count": 18}, {"id": "剧情", "name": "剧情", "count": 22}, {"id": "科幻", "name": "科幻", "count": 12}, {"id": "冒险", "name": "冒险", "count": 6}, {"id": "动画", "name": "动画", "count": 7}, {"id": "自然", "name": "自然", "count": 9}, {"id": "音乐", "name": "音乐", "count": 4}]
			if page == "folders": b.view = "scenes"; b.query.mode = "folders"; b.entries = [{"id": "folder1", "title": "VR影像", "container": true, "has_cover": false, "child_count": 21}, {"id": "folder2", "title": "电影", "container": true, "has_cover": false, "child_count": 20}, {"id": "folder3", "title": "纪录片", "container": true, "has_cover": false, "child_count": 10}] + movies.slice(0, 1)
			if page == "detail": b.detail = movies[1].duplicate(true); b.detail.description = "当暮色落在城市边缘，一场安静的旅程缓缓展开。"
			if page == "favorites": b.view = "scenes"; b.query.favorites = true; b.entries = []; b.total = 0
			else: b.total = 250
			menu._reset_navigation(); menu.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join(language + "-" + page + ".png"))
	menu.free(); platform.free(); viewport.queue_free(); await process_frame; print("common media server previews rendered"); quit()
