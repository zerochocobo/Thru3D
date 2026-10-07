extends SceneTree

func _initialize() -> void:
	call_deferred("_render")

func _render() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var scene := load("res://scenes/main.tscn") as PackedScene
	var main := scene.instantiate()
	viewport.add_child(main)
	# The production launcher opens the library and hides diagnostics. Explicitly isolate
	# the calibration board instead of sampling the launcher at the board's coordinates.
	main.set_process(false)
	main.recent_menu.dismiss()
	main.status_label.visible = false
	main.calibration_board.visible = true
	main.background.select("dark")
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var output := OS.get_environment("QUEST_PREVIEW_PATH")
	if output.is_empty() or image.is_empty():
		push_error("Preview path or image is empty")
		quit(1)
		return
	var error := image.save_png(output)
	print("Calibration preview saved: ", output, " result=", error)
	var samples: Array[Dictionary] = []
	var board := viewport.get_child(0).get_node("CalibrationBoard")
	var camera := viewport.get_camera_3d()
	var previous_green := -1.0
	for index in 5:
		var card := board.get_node("Alpha%d" % index) as MeshInstance3D
		var pixel := Vector2i(camera.unproject_position(card.global_position))
		var color := image.get_pixelv(pixel)
		samples.append({"alpha": index * 0.25, "pixel": [pixel.x, pixel.y], "rgba": [color.r, color.g, color.b, color.a]})
		if color.g <= previous_green + 0.05:
			push_error("Alpha card brightness must increase at each step")
			error = ERR_INVALID_DATA
		previous_green = color.g
	var evidence := FileAccess.open(output.get_basename() + ".json", FileAccess.WRITE)
	if evidence:
		evidence.store_string(JSON.stringify({"scope": "desktop_opaque_OpenGL_calibration", "device_passthrough_tested": false, "samples": samples}, "\t"))
	viewport.queue_free()
	await process_frame
	quit(0 if error == OK else 1)

