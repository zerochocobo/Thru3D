extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var output := ProjectSettings.globalize_path("res://../../artifacts/audio-popup-visuals")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1280, 1100)
	viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 62
	viewport.add_child(camera)
	var state := {"has_video": true, "title": "旅行记录 · VR180", "duration_ms": 7200000, "position_ms": 1320000,
		"source_uri": "file:///movie.mp4", "bookmark_scope": "render", "bookmark_ready": true, "bookmark_seekable": true,
		"bookmarks": [], "bookmark_revision": 1, "audio_track_id": 1, "audio_tracks": 2}
	var menu := Menu.new(); menu.state_provider = func(): return state
	camera.add_child(menu); menu.toggle()
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language)
		for view in ["empty-bar", "bookmarked-bar", "audio", "dubbing", "long-titles", "silent"]:
			menu._reset_navigation()
			state.bookmarks = [] if view == "empty-bar" else [{"id": "a", "position_ms": 1320000}]
			state.clone_voice = view == "dubbing"
			state.audio_options = [{"value": -1, "label": "Auto"},
				{"value": 1, "label": I18n.t("Track %d") % 1 + " · " + I18n.t("English")},
				{"value": 2, "label": I18n.t("Track %d") % 2 + " · " + I18n.t("Japanese")}, {"value": 0, "label": "Off"}]
			if view == "dubbing": state.audio_options.insert(1, {"value": 4, "label": "Dubbing"})
			if view == "long-titles":
				for index in range(3, 12): state.audio_options.insert(3, {"value": index, "label": "Director commentary / " + "長い音声タイトル".repeat(12)})
			if view == "silent": state.audio_options = [{"value": -1, "label": "Auto"}, {"value": 0, "label": "Off"}]
			if view not in ["empty-bar", "bookmarked-bar"]: menu.choices.opened = "audio_track"
			menu.refresh()
			await process_frame
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var image := viewport.get_texture().get_image()
			if image.save_png(output.path_join(language + "-" + view + ".png")) != OK: failures.append("Save failed")
			for button in menu._buttons:
				if menu.choices.targets.has(button.target):
					var label: Label3D = button.node.get_child(0)
					var width := menu.FONT.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x * label.pixel_size
					if width > button.rect.size.x: failures.append("Choice label overflow: " + language + "-" + view)
			for label in menu._labels:
				if label.render_priority != 32: continue
				for line in label.text.split("\n"):
					if menu.FONT.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x * label.pixel_size > 0.83: failures.append("Popup heading/footer overflow: " + language)
	menu.free(); viewport.free()
	for failure in failures: push_error(failure)
	print("Audio popup visual layouts=24 failures=", failures.size())
	quit(0 if failures.is_empty() else 1)
