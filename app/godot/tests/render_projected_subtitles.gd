extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
var failures: Array[String] = []
func centroid(image: Image) -> Vector2:
	var mass := 0.0
	var total := Vector2.ZERO
	for y in range(380, 565):
		for x in range(380, 930):
			var c := image.get_pixel(x, y)
			var w := maxf(0, minf(c.r, minf(c.g, c.b)) - 0.4)
			mass += w; total += Vector2(x, y) * w
	if mass < 2: failures.append("Projected text is missing")
	return total / maxf(mass, 0.001)
func _initialize(): call_deferred("_run")
func _run():
	var output := OS.get_environment("PROJECTED_SUBTITLE_OUTPUT")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var head := Camera3D.new()
	viewport.add_child(head)
	head.position.y = 1.6
	var eye := Camera3D.new()
	eye.fov = 90
	viewport.add_child(eye)
	eye.position.y = 1.6
	eye.make_current()
	var video := Video.new()
	viewport.add_child(video)
	video.set_process(false)
	video.view_camera = head
	video.caption.visible = true
	video.caption.text = "I"
	var shader := Shader.new()
	var source: String = load("res://shaders/video_rvm_pair.gdshader").code
	shader.code = source.replace("void vertex() {", "uniform int probe_eye = 0;\nvoid vertex() {").replace("eye_index = int(VIEW_INDEX);", "eye_index = probe_eye;")
	video.material.shader = shader
	var colour := Image.create(2, 2, false, Image.FORMAT_RGB8); colour.fill(Color(0.1, 0.2, 0.35))
	var alpha := Image.create(2, 2, false, Image.FORMAT_R8); alpha.fill(Color.BLACK)
	video.material.set_shader_parameter("color_texture", ImageTexture.create_from_image(colour))
	video.material.set_shader_parameter("alpha_texture", ImageTexture.create_from_image(alpha))
	video.material.set_shader_parameter("source_size", Vector2(2, 2))
	video.material.set_shader_parameter("model_size", Vector2(2, 2))
	video.material.set_shader_parameter("sharpness", 0)
	var samples: Array[Dictionary] = []
	var motion_samples: Array[Dictionary] = []
	for geometry in [1, 2, 3]:
		video.geometry = geometry
		video._apply_geometry()
		video.panel.visible = true
		for distance in [0.5, 2.0, 20.0]:
			video.subtitle_distance = distance
			video._place_caption()
			var centers: Array[Vector2] = []
			for index in 2:
				eye.position.x = (index - 0.5) * 0.063
				video.material.set_shader_parameter("probe_eye", index)
				video.material.set_shader_parameter("alpha_enabled", geometry == 2)
				await process_frame
				await RenderingServer.frame_post_draw
				await RenderingServer.frame_post_draw
				var pixels := viewport.get_texture().get_image()
				centers.append(centroid(pixels))
				if distance == 20: pixels.save_png(output.path_join("geometry%d_eye%d.png" % [geometry,index]))
			var angle := 2.0 * atan(0.063 / (2.0 * distance))
			# Reference source-longitude shift, plus the shared video's 50m projection surface.
			var expected := 360.0 * (tan(angle) + 0.063 / (50.0 * cos(video.CAPTION_DROP)))
			var actual := centers[0].x - centers[1].x
			var expected_y := 360.0 * tan(video.CAPTION_DROP) * (1.0 - 1.0 / cos(angle))
			var actual_y := centers[0].y - centers[1].y
			if absf(actual - expected) > 0.9 or absf(actual_y - expected_y) > 0.4: failures.append("Geometry/parallax mismatch")
			samples.append({"geometry":geometry,"distance_m":distance,"actual_pixels":actual,"expected_pixels":expected,"vertical_pixels":actual_y,"expected_vertical_pixels":expected_y})
		# Keep a spectator eye fixed and vary the pose supplied to production caption placement.
		# Following the head would move actual glyph pixels against the stationary video here.
		video.material.set_shader_parameter("probe_eye", 0)
		eye.position.x = -0.0315
		head.transform = Transform3D(Basis(), Vector3(0, 1.6, 0))
		video._place_caption()
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var baseline := centroid(viewport.get_texture().get_image())
		var anchor: Basis = video.material.get_shader_parameter("subtitle_anchor_inverse")
		for pose in [Vector3(0, 60, 0), Vector3(0, -60, 0), Vector3(35, 0, 0), Vector3(-35, 0, 0), Vector3(0, 0, 40), Vector3(20, -45, -30)]:
			head.rotation = pose * PI / 180.0
			head.position = Vector3(0.2, 1.75, 0.1)
			for frame in 12:
				video._place_caption()
				await process_frame
			await RenderingServer.frame_post_draw
			var shift := centroid(viewport.get_texture().get_image()).distance_to(baseline)
			var current: Basis = video.material.get_shader_parameter("subtitle_anchor_inverse")
			if shift > 0.15 or not current.is_equal_approx(anchor): failures.append("Head pose moves caption relative to video")
			motion_samples.append({"geometry":geometry,"head_rotation_degrees":[pose.x,pose.y,pose.z],"glyph_shift_pixels":shift})
		# A video adjustment must carry its captions with it; the local anchor stays unchanged.
		video.turn_view(0.1, 0.05)
		video.zoom_view(0.1)
		video._place_caption()
		var adjusted: Basis = video.material.get_shader_parameter("subtitle_anchor_inverse")
		if not adjusted.is_equal_approx(anchor): failures.append("Video adjustment changes local caption anchor")
		video.reset_view()
		head.transform = Transform3D(Basis(), Vector3(0, 1.6, 0))
		video._center_on_view()
	video.projected_subtitles.clear(video.material)
	video.material.set_shader_parameter("alpha_enabled", true)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var dark := viewport.get_texture().get_image()
	var bright := 0
	for y in range(380,565):
		for x in range(380,930):
			var c := dark.get_pixel(x,y)
			if minf(c.r,minf(c.g,c.b))>0.8: bright+=1
	if bright != 0: failures.append("CC Off leaves projected glyphs")
	var report := {"state":"passed" if failures.is_empty() else "failed","samples":samples,"motion_samples":motion_samples,"failures":failures,"scope":"Production video shader + actual glyph pixels, two desktop eye cameras and head pose changes; native XR acceptance remains separate"}
	FileAccess.open(output.path_join("verification.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print(JSON.stringify(report))
	viewport.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
