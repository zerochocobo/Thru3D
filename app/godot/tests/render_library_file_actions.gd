extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("LIBRARY_ACTIONS_PREVIEW_DIR")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1400,900); viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu)
	var platform := preload("res://tests/test_library_file_actions.gd").Platform.new(); menu.attach_platform(platform)
	menu.visible = true
	for language in ["zh","en"]:
		menu.I18n.use(language)
		for view in ["settings", "disabled", "enabled", "edit", "sort", "cloud_sort", "folder", "cloud_folder", "cloud_file", "rename_input", "rename_preview"]:
			menu.file_actions.reset(); menu.file_actions.set_enabled(view != "disabled" and view != "settings")
			menu.section = Menu.Section.LOCAL; menu._local_all_files = true
			menu._local_stack = [{"id":"/storage/emulated/0/Movies", "title":"视频 Movies"}]
			menu._local_entries = [
				{"title":"旅行 2026.mp4","uri":"file:///storage/emulated/0/Movies/travel.mp4","size":104857600,"modified":100,"can_delete":true},
				{"id":"/storage/emulated/0/Movies/concert","title":"演唱会","container":true,"delete_uri":"file:///storage/emulated/0/Movies/concert","can_delete":true},
				{"title":"教程 02.mp4","uri":"file:///storage/emulated/0/Movies/tutorial02.mp4","size":30000000,"modified":200,"can_delete":false}]
			if view == "settings": menu.section = Menu.Section.SETTINGS; menu.tab = Menu.GENERAL_TAB
			if view == "cloud_sort":
				menu.section = Menu.Section.CLOUD; menu._cloud_stack = [{"id":"/account","title":"Cloud"}]
				menu._cloud_entries = [{"title":"Cloud.mp4","uri":"cloud://account/Cloud.mp4","size":1000,"modified":100}]
			menu.refresh()
			if view == "edit": menu.file_actions.editing = true; menu.file_actions.selected = "file:///storage/emulated/0/Movies/travel.mp4"
			if view in ["sort", "cloud_sort"]: menu.file_actions.modal = "sort"
			if view == "folder":
				menu.file_actions.modal = "delete"; menu.file_actions.plan_ready = true
				menu.file_actions.target = {"title":"演唱会","uri":"file:///storage/emulated/0/Movies/concert","folder":true,"files":25,"folders":3}
			if view.begins_with("rename"):
				menu.file_actions.rename.open(menu._entry_row(menu._local_entries[0]))
				if view == "rename_preview":
					menu.file_actions.rename.phase = "preview"
					menu.file_actions.rename.moves = [{"from":"旅行 2026.mp4","to":"日本旅行.mp4"}, {"from":"旅行 2026.zh.srt","to":"日本旅行.zh.srt"}, {"from":"旅行 2026.si.mix.m4a","to":"日本旅行.si.mix.m4a"}]

			if view in ["cloud_folder", "cloud_file"]:
				menu.section = Menu.Section.CLOUD; menu._cloud_stack = [{"id":"/account","title":"115 Open"}]
				menu.file_actions.modal = "delete"; menu.file_actions.plan_ready = true
				menu.file_actions.target = {"title":"旅行 2026" if view == "cloud_folder" else "演唱会.mp4","uri":"cloud://account/旅行","folder":view == "cloud_folder","delete_effect":"recycle","cloud_id":"9","files":25,"folders":3}
			menu._draw()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			var image := viewport.get_texture().get_image()
			image.save_png(output.path_join(language + "-" + view + ".png"))
	menu.queue_free(); viewport.queue_free(); await process_frame; platform.free()
	print("Library file action previews: 22 frames")
	quit(0)
