extends SceneTree
## Render the real photo shader at a fixed display size while varying source resolution.
## This tests disparity units only; forced eyes do not verify XR multiview or model quality.

const WIDTH := 1024
var viewport: SubViewport
var material: ShaderMaterial
var failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func _centre(eye: int) -> float:
	material.set_shader_parameter("test_eye", eye)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var weight := 0.0
	var weighted_x := 0.0
	for x in WIDTH:
		var value := image.get_pixel(x, 128).r
		weight += value
		weighted_x += x * value
	if weight < 10.0: failures.append("Missing white marker")
	return weighted_x / maxf(1.0, weight)

func _run() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(WIDTH, 256)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.size = 1.0
	camera.position.z = 2.0
	viewport.add_child(camera)
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	quad.mesh.size = Vector2(4, 1)
	viewport.add_child(quad)
	material = ShaderMaterial.new()
	material.shader = load("res://shaders/photo.gdshader")
	quad.material_override = material
	var near := Image.create(99, 140, false, Image.FORMAT_RF)
	near.fill(Color(1, 0, 0))
	material.set_shader_parameter("depth_texture", ImageTexture.create_from_image(near))
	material.set_shader_parameter("photo_depth", true)
	var results: Array[Dictionary] = []
	for source_width in [256, 1024, 4096]:
		var source := Image.create(source_width, 64, false, Image.FORMAT_RGB8)
		source.fill(Color.BLACK)
		source.fill_rect(Rect2i(source_width * 15 / 32, 0, source_width / 16, 64), Color.WHITE)
		source.generate_mipmaps()
		material.set_shader_parameter("photo_texture", ImageTexture.create_from_image(source))
		material.set_shader_parameter("source_size", Vector2(source_width, 64))
		for strength in [0.0, 1.0, 2.0]:
			material.set_shader_parameter("depth_strength", strength)
			var left := await _centre(0)
			var right := await _centre(1)
			var actual := left - right
			var expected: float = WIDTH * 0.035 * 0.65 * strength
			results.append({"source_width": source_width, "strength": strength, "display_disparity_px": actual, "expected_px": expected})
			if absf(actual - expected) > 1.0:
				failures.append("%d pixels / %.1f strength: %.3f != %.3f" % [source_width, strength, actual, expected])
	# A marker whose near/far classification changes if the 518px letterbox rect is ignored.
	var portrait_depth := Image.create(518,518,false,Image.FORMAT_RF)
	portrait_depth.fill(Color(0,0,0))
	portrait_depth.fill_rect(Rect2i(168,0,274,518),Color(1,0,0))
	var marker := Image.create(1024,64,false,Image.FORMAT_RGB8)
	marker.fill(Color.BLACK)
	marker.fill_rect(Rect2i(288,0,64,64),Color.WHITE)
	material.set_shader_parameter("photo_texture",ImageTexture.create_from_image(marker))
	material.set_shader_parameter("source_size",Vector2(1024,64))
	material.set_shader_parameter("depth_texture",ImageTexture.create_from_image(portrait_depth))
	material.set_shader_parameter("depth_rect",Vector4(76.0/518,0,366.0/518,1))
	material.set_shader_parameter("depth_strength",1.0)
	var portrait_left := await _centre(0)
	var portrait_right := await _centre(1)
	var portrait_shift := portrait_left-portrait_right
	results.append({"profile":"518x518 portrait rect", "display_disparity_px":portrait_shift, "expected_px":23.296})
	if absf(portrait_shift-23.296)>1.0: failures.append("High-resolution content rect sampled the padding or wrong depth")
	# Generated pairs already contain the video warp. Do not warp them a second time in this shader.
	var pair := Image.create(256,64,false,Image.FORMAT_RGB8)
	pair.fill(Color.BLACK)
	pair.fill_rect(Rect2i(40,0,8,64),Color.WHITE)
	pair.fill_rect(Rect2i(128+80,0,8,64),Color.WHITE)
	pair.generate_mipmaps()
	material.set_shader_parameter("stereo_texture",ImageTexture.create_from_image(pair))
	material.set_shader_parameter("generated_size",Vector2(128,64))
	material.set_shader_parameter("photo_stereo",true)
	for zoom in [1.0,2.0]:
		material.set_shader_parameter("content_zoom",zoom)
		for strength in [0.0,2.0]:
			material.set_shader_parameter("depth_strength",strength)
			var left := await _centre(0); var right := await _centre(1)
			var expected: float = -320.0 * zoom
			results.append({"profile":"generated pair", "zoom":zoom, "shader_strength":strength,"display_disparity_px":left-right,"expected_px":expected})
			if absf(left-right-expected)>1.0: failures.append("Generated pair changed eye order, cropping or was warped twice")
	var output := ProjectSettings.globalize_path("res://../../artifacts/photo-depth-xz")
	DirAccess.make_dir_recursive_absolute(output)
	var file := FileAccess.open(output.path_join("shader-resolution.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": results, "failures": failures, "scope": "Desktop OpenGL real photo shader; fixed display size, forced eyes"}, "\t"))
	file.close()
	viewport.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("Photo depth source-resolution render: %d checks, %d failures" % [results.size(), failures.size()])
	quit(0 if failures.is_empty() else 1)
