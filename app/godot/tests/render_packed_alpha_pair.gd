extends SceneTree
## MPV pair shader decoding an alpha-packed fisheye frame (DeoVR six-block mask, PTMediaServer
## "_FISHEYE_F180_alpha") against the C04 packer oracle. Desktop OpenGL; XR and Android not tested.

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _bilinear(image: Image, uv: Vector2) -> float:
	var p := uv * Vector2(image.get_size()) - Vector2(0.5, 0.5)
	p = p.clamp(Vector2.ZERO, Vector2(image.get_size()) - Vector2.ONE)
	var a := Vector2i(floori(p.x), floori(p.y))
	var b := (a + Vector2i.ONE).min(image.get_size() - Vector2i.ONE)
	return lerpf(lerpf(image.get_pixel(a.x, a.y).r, image.get_pixel(b.x, a.y).r, p.x - a.x),
		lerpf(image.get_pixel(a.x, b.y).r, image.get_pixel(b.x, b.y).r, p.x - a.x), p.y - a.y)

func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(65, 65)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
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
	var packed: Image = (load("res://media/c04_alpha_f180_rgb.png") as Texture2D).get_image()
	var mask: Image = (load("res://media/c04_packed_mask_oracle.png") as Texture2D).get_image()
	var code := FileAccess.get_file_as_string("res://shaders/video_rvm_pair.gdshader") \
		.replace('#include "res://shaders/video_coordinates.gdshaderinc"', FileAccess.get_file_as_string("res://shaders/video_coordinates.gdshaderinc")) \
		.replace("varying flat int eye_index;", "uniform int test_eye = 0;\nuniform vec2 test_uv = vec2(0.5);\nvarying flat int eye_index;") \
		.replace("eye_index = int(VIEW_INDEX);", "eye_index = test_eye;") \
		.replace("vec2 shown_uv = eye_uv(UV, media_direction);", "vec2 shown_uv = test_uv;")
	var shader := Shader.new()
	shader.code = code
	var material := ShaderMaterial.new()
	material.shader = shader
	quad.material_override = material
	material.set_shader_parameter("color_texture", ImageTexture.create_from_image(packed))
	material.set_shader_parameter("source_size", Vector2(1280, 640))
	material.set_shader_parameter("packed_size", Vector2(512, 256))
	material.set_shader_parameter("stereo_sbs", true)
	material.set_shader_parameter("alpha_enabled", false)
	material.set_shader_parameter("packed_alpha", true)
	var checked := 0
	for eye in [0, 1]:
		material.set_shader_parameter("test_eye", eye)
		for y in [0.25, 0.5, 0.75]:
			for x in [0.1, 0.3, 0.5, 0.7, 0.9]:
				material.set_shader_parameter("test_uv", Vector2(x, y))
				await RenderingServer.frame_post_draw
				await RenderingServer.frame_post_draw
				var pixel := viewport.get_texture().get_image().get_pixel(32, 32)
				var expected := _bilinear(mask, Vector2(x * 0.5 + eye * 0.5, y))
				checked += 1
				if absf(pixel.a - expected) > 0.012:
					failures.append("eye %d UV (%.1f, %.1f) alpha %.4f expected %.4f" % [eye, x, y, pixel.a, expected])
	# RVM matte: transparent where Alpha is 0 (the decoder image is not read there), opaque with
	# the source colour where Alpha is 1, and partial Alpha at the edge keeps its value.
	var matte := Image.create(64, 64, false, Image.FORMAT_R8)
	matte.fill_rect(Rect2i(0, 32, 64, 32), Color(1, 1, 1))
	material.set_shader_parameter("packed_alpha", false)
	material.set_shader_parameter("alpha_enabled", true)
	material.set_shader_parameter("alpha_texture", ImageTexture.create_from_image(matte))
	material.set_shader_parameter("model_size", Vector2(32, 64))
	material.set_shader_parameter("model_content_rect", Vector4(0, 0, 1, 1))
	material.set_shader_parameter("test_eye", 0)
	for case in [[0.15, 0.0], [0.85, 1.0], [0.5, 0.5]]:
		material.set_shader_parameter("test_uv", Vector2(0.3, case[0]))
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var shown := viewport.get_texture().get_image().get_pixel(32, 32)
		checked += 1
		if case[1] == 0.0 and shown.a > 0.004:
			failures.append("Matte 0 must be transparent: %.4f" % shown.a)
		elif case[1] == 1.0:
			var source := packed.get_pixel(int(0.15 * packed.get_width()), int(case[0] * packed.get_height()))
			if shown.a < 0.99 or Vector3(shown.r - source.r, shown.g - source.g, shown.b - source.b).length() > 0.08:
				failures.append("Matte 1 must show the source colour: %s vs %s" % [shown, source])
		elif case[1] == 0.5 and (shown.a < 0.2 or shown.a > 0.8):
			failures.append("Matte edge keeps partial Alpha: %.4f" % shown.a)
	material.set_shader_parameter("alpha_enabled", false)
	# Off: the same frame is opaque.
	material.set_shader_parameter("packed_alpha", false)
	material.set_shader_parameter("test_uv", Vector2(0.1, 0.25))
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if viewport.get_texture().get_image().get_pixel(32, 32).a < 0.99:
		failures.append("Packed alpha off must be opaque")
	for failure in failures:
		push_error(failure)
	print("Packed alpha pair render: %s (%d samples, %d failures). XR and Android not tested." % [
		"passed" if failures.is_empty() else "FAILED", checked, failures.size()])
	quit(0 if failures.is_empty() else 1)
