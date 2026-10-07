extends SceneTree
## MPV pair shader on desktop OpenGL: top-bottom stereo picks the top half for the left eye and
## the bottom half for the right; a fisheye lens angle maps directions to the lens circle and
## leaves directions beyond it black. Eye and view direction are forced through uniforms.

const PALETTE := [Color(1, 0, 0), Color(1, 0.5, 0), Color(1, 1, 0), Color(0, 1, 0), Color(0, 1, 1),
	Color(0, 0, 1), Color(0.5, 0, 1), Color(1, 0, 1), Color(1, 1, 1), Color(0.5, 0.5, 0.5)]

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(16, 16)
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
	var code := FileAccess.get_file_as_string("res://shaders/video_rvm_pair.gdshader") \
		.replace('#include "res://shaders/video_coordinates.gdshaderinc"', FileAccess.get_file_as_string("res://shaders/video_coordinates.gdshaderinc")) \
		.replace("varying flat int eye_index;", "uniform int test_eye = 0;\nuniform vec3 test_direction = vec3(0.0, 0.0, -1.0);\nvarying flat int eye_index;") \
		.replace("eye_index = int(VIEW_INDEX);", "eye_index = test_eye;") \
		.replace("media_direction = VERTEX;", "media_direction = test_direction;")
	var shader := Shader.new()
	shader.code = code
	var material := ShaderMaterial.new()
	material.shader = shader
	quad.material_override = material
	material.set_shader_parameter("alpha_enabled", false)
	# Top-bottom: top half red, bottom half blue; flat screen, centre of each eye.
	var stacked := Image.create(64, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in 64:
			stacked.set_pixel(x, y, Color.RED if y < 32 else Color.BLUE)
	material.set_shader_parameter("color_texture", ImageTexture.create_from_image(stacked))
	material.set_shader_parameter("source_size", Vector2(64, 64))
	material.set_shader_parameter("stereo_sbs", true)
	material.set_shader_parameter("top_bottom", true)
	for case in [[0, false, Color.RED], [1, false, Color.BLUE], [0, true, Color.BLUE], [1, true, Color.RED]]:
		material.set_shader_parameter("test_eye", case[0])
		material.set_shader_parameter("swap_eyes", case[1])
		var got := await _centre(viewport)
		if _distance(got, case[2]) > 0.1:
			failures.append("Top-bottom eye %d swap %s: %s, expected %s" % [case[0], case[1], got, case[2]])
	# Fisheye: ten vertical stripes across a mono circle frame; a direction 80 degrees right of
	# forward lands at radius 80/(fov/2) of the circle.
	var stripes := Image.create(100, 100, false, Image.FORMAT_RGB8)
	for y in 100:
		for x in 100:
			stripes.set_pixel(x, y, PALETTE[x / 10])
	material.set_shader_parameter("color_texture", ImageTexture.create_from_image(stripes))
	material.set_shader_parameter("source_size", Vector2(100, 100))
	material.set_shader_parameter("stereo_sbs", false)
	material.set_shader_parameter("top_bottom", false)
	material.set_shader_parameter("video_geometry", 2)
	for case in [[180, 80.0, 9], [220, 80.0, 8], [200, 75.0, 8], [180, 100.0, -1], [220, 100.0, 9]]:
		material.set_shader_parameter("fisheye_fov", float(case[0]))
		var angle := deg_to_rad(float(case[1]))
		material.set_shader_parameter("test_direction", Vector3(sin(angle), 0.0, -cos(angle)))
		var got := await _centre(viewport)
		var expected: Color = Color.BLACK if int(case[2]) < 0 else PALETTE[int(case[2])]
		if _distance(got, expected) > 0.1:
			failures.append("Fisheye %d at %d degrees: %s, expected stripe %d" % [case[0], int(case[1]), got, case[2]])
	for failure in failures:
		push_error(failure)
	print("Layout and lens render: %s (%d failures). XR and Android not tested." % ["passed" if failures.is_empty() else "FAILED", failures.size()])
	quit(0 if failures.is_empty() else 1)

func _centre(viewport: SubViewport) -> Color:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image().get_pixel(8, 8)

func _distance(a: Color, b: Color) -> float:
	return maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b)))
