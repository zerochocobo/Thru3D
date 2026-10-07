extends SceneTree

# Instantiate the real entry scene. No mocked catalog or replacement menu nodes.
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	# English unless a language preview is asked for (QUEST_UI_LANGUAGE=zh).
	preload("res://scripts/i18n.gd").use(OS.get_environment("QUEST_UI_LANGUAGE") if OS.has_environment("QUEST_UI_LANGUAGE") else "en")
	var output := OS.get_environment("QUEST_MAIN_UI_PREVIEW_DIR")
	if output.is_empty():
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var failures: Array[String] = []
	if not main.recent_menu.visible or main.player_menu.visible:
		failures.append("Real startup must show the library only")
	if main.status_label.visible or main.calibration_board.visible:
		failures.append("Diagnostics must be hidden during normal startup")
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if root.get_texture().get_image().save_png(output.path_join("startup.png")) != OK:
		failures.append("Startup screenshot failed")
	main._show_player_menu()
	await process_frame
	if not main.player_menu.visible or main.recent_menu.visible:
		failures.append("Player and library must remain mutually exclusive")
	if main.player_menu.text_snapshot().contains("Press trigger"):
		failures.append("Instruction wall must be absent")
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if root.get_texture().get_image().save_png(output.path_join("empty-player.png")) != OK:
		failures.append("Empty player screenshot failed")
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({
		"state": "passed" if failures.is_empty() else "failed", "failures": failures,
		"scope": "Actual Godot entry scene desktop OpenGL startup; Quest physical rays, binocular compositor and native playback not tested"}, "\t"))
	for failure in failures: push_error(failure)
	main.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
