extends SceneTree
const Player := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const I18n := preload("res://scripts/i18n.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var output := ProjectSettings.globalize_path("res://../../artifacts/seek-policy/visuals")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1400, 1100); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 56; viewport.add_child(camera)
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language)
		var library := Library.new()
		library.section = Library.Section.SETTINGS; library.tab = Library.VIDEO_TAB
		library.settings_provider = func(): return {"seek_mode": "speed"}
		camera.add_child(library); library.toggle(); library.set_process(false)
		library.position = Vector3(0, -0.1, -1.8)
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(output.path_join(language + "-global.png"))
		if language in ["zh", "en"]:
			for tab in [Library.GENERAL_TAB, Library.DISPLAY_TAB, Library.SUBTITLES_TAB, Library.BACKGROUND_TAB]:
				library.tab = tab; library.refresh()
				await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
				viewport.get_texture().get_image().save_png(output.path_join(language + "-settings-%d.png" % tab))
			library.tab = Library.GENERAL_TAB; library.refresh()
			for target in library.choices.targets:
				if library.choices.targets[target].kind == "open": library.choices.action(target); break
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join(language + "-dropdown.png"))
		library.free()
		var state := {"has_video": true, "duration_ms": 7200000, "position_ms": 60000, "seek_mode": "speed",
			"bookmark_seek_mode": "exact", "bookmark_scope": "render", "bookmark_revision": 1,
			"bookmark_ready": true, "bookmark_seekable": true, "bookmarks": []}
		for index in 5: state.bookmarks.append({"id": str(index), "position_ms": 60000 + index * 300000})
		var player := Player.new()
		player.state_provider = func(): return state
		camera.add_child(player); player.toggle(); player.set_process(false)
		player.position = Vector3(0, -0.1, -1.8)
		player.section = 1; player.refresh()
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(output.path_join(language + "-player.png"))
		player.section = 0; player.bookmarks.opened = true; player.refresh()
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(output.path_join(language + "-bookmarks.png"))
		player.free()
	viewport.free()
	print("Seek precision visual previews saved: ", output)
	quit()
