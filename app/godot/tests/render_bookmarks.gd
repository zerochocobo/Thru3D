extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	preload("res://scripts/i18n.gd").use("zh")
	var output := ProjectSettings.globalize_path("res://../../artifacts/bookmarks-visuals")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 1100)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 56
	viewport.add_child(camera)
	var markers: Array = []
	for i in 20: markers.append({"id": str(i), "position_ms": i * 310000 + 60000, "created_at_ms": 1})
	var state := {"has_video": true, "title": "旅行记录 · VR180", "duration_ms": 7200000, "position_ms": 1320000,
		"bookmark_scope": "render", "bookmarks": markers, "bookmark_ready": true, "bookmark_seekable": true, "bookmark_revision": 1}
	var menu := Menu.new()
	menu.state_provider = func(): return state
	menu.bookmark_requested.connect(func(operation, _id, _scope):
		if operation == "delete":
			state.bookmark_undo = true
			menu.bookmarks.notify("已删除"))
	camera.add_child(menu); menu.toggle()
	for mode in ["timeline", "cluster", "list", "undo", "empty"]:
		menu.bookmarks.reset()
		if mode == "cluster": menu.bookmarks.subset = ["0", "1"]; menu.bookmarks.opened = true
		elif mode in ["list", "undo", "empty"]: menu.bookmarks.opened = true
		if mode == "undo": state.bookmark_undo = true; menu.bookmarks.notice = "已删除"; menu.bookmarks.notice_until = Time.get_ticks_msec() + 3000
		if mode == "empty": state.bookmarks = []; state.bookmark_undo = false
		menu.refresh()
		await process_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(output.path_join(mode + ".png"))
	menu.free(); viewport.free()
	print("Bookmark visual previews saved: ", output)
	quit()
