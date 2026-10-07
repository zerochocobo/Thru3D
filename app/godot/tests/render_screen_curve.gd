extends SceneTree

## Desktop OpenGL render of the flat screen: plain, then curved round the eyes with a corner bracket.
## A curved screen of the same size reaches wider across the view (its sides come closer).

const Video := preload("res://scripts/mpv_video_display.gd")
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("QUEST_SCREEN_PREVIEW_DIR")
	var viewport := SubViewport.new()
	viewport.size = Vector2i(640, 360)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.position = Vector3(0, 1.6, 0)
	viewport.add_child(camera)
	var video := Video.new()
	viewport.add_child(video)
	video.view_camera = camera
	video.set_process(false)
	var color := Image.create(2, 2, false, Image.FORMAT_RGB8)
	color.fill(Color(0.1, 0.4, 0.7))
	var alpha := Image.create(2, 2, false, Image.FORMAT_R8)
	alpha.fill(Color.BLACK)
	video.material.set_shader_parameter("color_texture", ImageTexture.create_from_image(color))
	video.material.set_shader_parameter("alpha_texture", ImageTexture.create_from_image(alpha))
	video.material.set_shader_parameter("source_size", Vector2(2, 2))
	video.material.set_shader_parameter("model_size", Vector2(2, 2))
	video.material.set_shader_parameter("alpha_enabled", false)
	video._screen_base = Vector2(1.6, 0.9)
	video.set_screen_scale(1.0)
	video.flat_pose = Transform3D(Basis(), Vector3(0, 1.6, -2))
	video._apply_geometry()
	video.panel.visible = true
	var widths: Array[int] = []
	for step in ["flat", "curved"]:
		if step == "curved":
			video.set_screen_curve(1.0)
			video.set_corner_hover(1)
		await process_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		if not output.is_empty():
			DirAccess.make_dir_recursive_absolute(output)
			image.save_png(output.path_join(step + ".png"))
		var width := 0
		for x in 640:
			var p := image.get_pixel(x, 180)
			if p.b > 0.5 and p.r < 0.3:
				width += 1
		widths.append(width)
		if step == "curved":
			# The bracket sits just outside the top-right corner: white pixels in that quadrant.
			var white := 0
			for y in range(0, 180):
				for x in range(320, 640):
					var p := image.get_pixel(x, y)
					if minf(p.r, minf(p.g, p.b)) > 0.8:
						white += 1
			if white < 20:
				failures.append("Corner bracket not drawn: %d white pixels" % white)
	if widths[0] < 100 or widths[1] <= widths[0] + 5:
		failures.append("Curved screen must reach wider than the flat one: %s" % [widths])
	viewport.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	print("Screen curve render: %s %s" % ["passed" if failures.is_empty() else "failed", widths])
	quit(0 if failures.is_empty() else 1)
