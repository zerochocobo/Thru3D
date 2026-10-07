extends SceneTree

var failures: Array[String] = []
var results: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(128, 128)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.position.z = 2.0
	viewport.add_child(camera)
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	quad.mesh.size = Vector2(2, 2)
	viewport.add_child(quad)
	var image := Image.create(128, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in 128:
			image.set_pixel(x, y, (Color.RED if y < 32 else Color.YELLOW) if x < 64 else (Color.BLUE if y < 32 else Color.CYAN))
	var shader := Shader.new()
	# Desktop validates shader coordinate math with an ordinary texture.
	# This does not test Android OES sampling, codec output or XR stereo.
	shader.code = FileAccess.get_file_as_string("res://shaders/video_oes.gdshader") \
		.replace('#include "res://shaders/video_coordinates.gdshaderinc"', FileAccess.get_file_as_string("res://shaders/video_coordinates.gdshaderinc")) \
		.replace("samplerExternalOES", "sampler2D") \
		.replace("varying flat int eye_index;", "uniform int test_eye = 0;\nvarying flat int eye_index;") \
		.replace("eye_index = int(VIEW_INDEX);", "eye_index = test_eye;")
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("video_texture", ImageTexture.create_from_image(image))
	quad.material_override = material
	var flip := Projection(Vector4(1,0,0,0), Vector4(0,-1,0,0), Vector4(0,0,1,0), Vector4(0,1,0,1))
	var crop := Projection(Vector4(0.5,0,0,0), Vector4(0,-1,0,0), Vector4(0,0,1,0), Vector4(0.5,1,0,1))
	var cases := [
		{"name": "2d", "sbs": false, "eye": 0, "swap": false, "rotation": 0, "matrix": flip, "expected": [Color.RED, Color.BLUE, Color.YELLOW, Color.CYAN]},
		{"name": "left", "sbs": true, "eye": 0, "swap": false, "rotation": 0, "matrix": flip, "expected": [Color.RED, Color.RED, Color.YELLOW, Color.YELLOW]},
		{"name": "right", "sbs": true, "eye": 1, "swap": false, "rotation": 0, "matrix": flip, "expected": [Color.BLUE, Color.BLUE, Color.CYAN, Color.CYAN]},
		{"name": "swapped", "sbs": true, "eye": 0, "swap": true, "rotation": 0, "matrix": flip, "expected": [Color.BLUE, Color.BLUE, Color.CYAN, Color.CYAN]},
		{"name": "crop", "sbs": false, "eye": 0, "swap": false, "rotation": 0, "matrix": crop, "expected": [Color.BLUE, Color.BLUE, Color.CYAN, Color.CYAN]},
		{"name": "rotation90", "sbs": false, "eye": 0, "swap": false, "rotation": 90, "matrix": flip, "expected": [Color.YELLOW, Color.RED, Color.CYAN, Color.BLUE]},
	]
	var montage := Image.create(128 * cases.size(), 128, false, Image.FORMAT_RGB8)
	var points := [Vector2i(32,32), Vector2i(96,32), Vector2i(32,96), Vector2i(96,96)]
	for index in cases.size():
		var entry: Dictionary = cases[index]
		material.set_shader_parameter("stereo_sbs", entry.sbs)
		material.set_shader_parameter("swap_eyes", entry.swap)
		material.set_shader_parameter("test_eye", entry.eye)
		material.set_shader_parameter("rotation_degrees", entry.rotation)
		material.set_shader_parameter("surface_transform", entry.matrix)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var rendered := viewport.get_texture().get_image()
		rendered.convert(Image.FORMAT_RGB8)
		var samples: Array[String] = []
		for sample in points.size():
			var actual := rendered.get_pixelv(points[sample])
			var expected: Color = entry.expected[sample]
			samples.append(actual.to_html())
			if maxf(absf(actual.r - expected.r), maxf(absf(actual.g - expected.g), absf(actual.b - expected.b))) > 0.03:
				failures.append("%s sample %d: expected %s got %s" % [entry.name, sample, expected.to_html(), actual.to_html()])
		montage.blit_rect(rendered, Rect2i(0,0,128,128), Vector2i(index * 128, 0))
		results.append({"case": entry.name, "samples_rgba": samples})
	var output := OS.get_environment("QUEST_VIDEO_UV_PATH")
	if output.is_empty():
		output = "user://video-uv-preview.png"
	if montage.save_png(output) != OK:
		failures.append("Could not save texture math preview")
	var report := FileAccess.open(output + ".json", FileAccess.WRITE)
	if report:
		report.store_string(JSON.stringify({"scope": "Desktop texture math emulation; Android OES and XR not tested", "renderer": RenderingServer.get_video_adapter_name(), "cases": results, "failures": failures}, "\t"))
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("C03 OpenGL texture math passed: 2D, both eye rectangles, swap, crop and rotation. Android OES and XR not tested.")
	quit(0 if failures.is_empty() else 1)
