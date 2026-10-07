extends SceneTree

const Geometry := preload("res://scripts/video_geometry.gd")
var failures: Array[String] = []
var results: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("_run")

func _shader(path: String, fixed_uv: bool) -> Shader:
	var code := FileAccess.get_file_as_string(path).replace('#include "res://shaders/video_coordinates.gdshaderinc"', FileAccess.get_file_as_string("res://shaders/video_coordinates.gdshaderinc"))
	code = code.replace("samplerExternalOES", "sampler2D").replace("varying flat int eye_index;", "uniform int test_eye = 0;\nuniform vec2 test_uv = vec2(0.5);\nvarying flat int eye_index;").replace("eye_index = int(VIEW_INDEX);", "eye_index = test_eye;")
	if fixed_uv:
		code = code.replace("vec2 local_uv = eye_uv(UV, media_direction);", "vec2 local_uv = test_uv;")
	var shader := Shader.new()
	shader.code = code
	return shader

func _bilinear(image: Image, uv: Vector2) -> float:
	var p := uv * Vector2(image.get_size()) - Vector2(0.5, 0.5)
	p = p.clamp(Vector2.ZERO, Vector2(image.get_size()) - Vector2.ONE)
	var a := Vector2i(floori(p.x), floori(p.y))
	var b := (a + Vector2i.ONE).min(image.get_size() - Vector2i.ONE)
	return lerpf(lerpf(image.get_pixel(a.x, a.y).r, image.get_pixel(b.x, a.y).r, p.x - a.x), lerpf(image.get_pixel(a.x, b.y).r, image.get_pixel(b.x, b.y).r, p.x - a.x), p.y - a.y)

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
	var independent_rgb: Image = (load("res://media/c04_independent_rgb.png") as Texture2D).get_image()
	var independent_mask: Image = (load("res://media/c04_independent_mask.png") as Texture2D).get_image()
	var material := ShaderMaterial.new()
	material.shader = _shader("res://shaders/video_alpha_oes.gdshader", true)
	quad.material_override = material
	material.set_shader_parameter("source_size", Vector2(1280, 640))
	material.set_shader_parameter("packed_size", Vector2(512, 256))
	material.set_shader_parameter("stereo_sbs", true)
	material.set_shader_parameter("surface_transform", Projection(Vector4(1,0,0,0), Vector4(0,-1,0,0), Vector4(0,0,1,0), Vector4(0,1,0,1)))
	var montage := Image.create(64 * 12, 64 * 5, false, Image.FORMAT_RGBA8)
	var index := 0
	for encoding in [1, 2]:
		material.set_shader_parameter("alpha_encoding", encoding)
		material.set_shader_parameter("video_texture", ImageTexture.create_from_image(independent_rgb if encoding == 1 else packed))
		material.set_shader_parameter("alpha_texture", ImageTexture.create_from_image(independent_mask))
		for eye in [0, 1]:
			material.set_shader_parameter("test_eye", eye)
			for y in [0.25, 0.5, 0.75]:
				for x in [0.1, 0.3, 0.5, 0.7, 0.9]:
					var uv := Vector2(x, y)
					material.set_shader_parameter("test_uv", uv)
					await RenderingServer.frame_post_draw
					await RenderingServer.frame_post_draw
					var rendered := viewport.get_texture().get_image()
					var pixel := rendered.get_pixel(32, 32)
					var expected := _bilinear(independent_mask if encoding == 1 else mask, Vector2(x * 0.5 + eye * 0.5, y))
					if absf(pixel.a - expected) > 0.012:
						failures.append("encoding %d eye %d UV %s alpha %.5f expected %.5f" % [encoding, eye, uv, pixel.a, expected])
					# Both paths retain straight RGB; the framebuffer does one blend multiplication.
					var rgb := Color(224.0/255, 48.0/255, 32.0/255) if eye == 0 else Color(32.0/255, 80.0/255, 224.0/255)
					if maxf(absf(pixel.r - rgb.r * expected), maxf(absf(pixel.g - rgb.g * expected), absf(pixel.b - rgb.b * expected))) > 0.02:
						failures.append("encoding %d eye %d UV %s straight RGB mix incorrect: %s" % [encoding, eye, uv, pixel])
					results.append({"encoding": encoding, "eye": eye, "uv": [x,y], "alpha": pixel.a, "expected": expected, "rgba": pixel.to_html()})
					rendered.convert(Image.FORMAT_RGBA8)
					montage.blit_rect(rendered, Rect2i(0,0,64,64), Vector2i((index % 12) * 64, (index / 12) * 64))
					index += 1
	# Render the real hemisphere from several directions, without the test UV override.
	material.set_shader_parameter("alpha_encoding", 2)
	material.set_shader_parameter("video_texture", ImageTexture.create_from_image(packed))
	for eye in [0, 1]:
		material.set_shader_parameter("test_eye", eye)
		for uv in [Vector2(0.15,0.15), Vector2(0.85,0.15), Vector2(0.15,0.85), Vector2(0.85,0.85)]:
			material.set_shader_parameter("test_uv", uv)
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var pixel := viewport.get_texture().get_image().get_pixel(32,32)
			if pixel.a > 0.01 or maxf(pixel.r, maxf(pixel.g,pixel.b)) > 0.01:
				failures.append("Packed metadata must not be visible: eye %d UV %s" % [eye, uv])
			results.append({"reserved_color":true,"eye":eye,"uv":[uv.x,uv.y],"rgba":pixel.to_html()})
	quad.mesh = Geometry.hemisphere()
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.position = Vector3.ZERO
	camera.fov = 60.0
	var opaque := ShaderMaterial.new()
	opaque.shader = _shader("res://shaders/video_oes.gdshader", false)
	opaque.set_shader_parameter("source_size", Vector2(128,64))
	opaque.set_shader_parameter("stereo_sbs", true)
	opaque.set_shader_parameter("surface_transform", material.get_shader_parameter("surface_transform"))
	var grid := Image.create(128, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in 128:
			grid.set_pixel(x, y, Color((float(x % 64) + 0.5) / 64, (float(y) + 0.5) / 64, 0.0 if x < 64 else 1.0))
	opaque.set_shader_parameter("video_texture", ImageTexture.create_from_image(grid))
	quad.material_override = opaque
	for geometry in [1, 2]:
		opaque.set_shader_parameter("video_geometry", geometry)
		for angles in [Vector2(0,0), Vector2(35,0), Vector2(-35,0), Vector2(0,30), Vector2(0,-30), Vector2(35,30), Vector2(180,0)]:
			camera.rotation = Vector3(deg_to_rad(angles.y), deg_to_rad(angles.x), 0)
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var pixel := viewport.get_texture().get_image().get_pixel(32,32)
			if angles.x == 180 and pixel.a > 0.01:
				failures.append("VR180 must not draw the back hemisphere")
			elif angles.x != 180:
				var expected := Vector2(0.5 - angles.x / 180, 0.5 - angles.y / 180)
				if geometry == 2:
					var yaw := deg_to_rad(angles.x)
					var pitch := deg_to_rad(angles.y)
					var direction := Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
					var radial := acos(-direction.z) / PI
					var axis := Vector2(direction.x, -direction.y)
					expected = Vector2(0.5,0.5) + axis.normalized() * radial
				if pixel.a < 0.99 or absf(pixel.r - expected.x) > 0.012 or absf(pixel.g - expected.y) > 0.012 or pixel.b > 0.01:
					failures.append("Projection %d yaw/pitch %s expected UV %s got %s" % [geometry, angles, expected, pixel])
			results.append({"geometry":geometry, "yaw_pitch":[angles.x,angles.y], "rgba":pixel.to_html()})
	var output := OS.get_environment("QUEST_C04_ALPHA_PATH")
	if output.is_empty():
		output = "user://c04-alpha-preview.png"
	if montage.save_png(output) != OK:
		failures.append("C04 preview save failed")
	var report := FileAccess.open(output + ".json", FileAccess.WRITE)
	if report:
		report.store_string(JSON.stringify({"scope":"Desktop sampler2D emulation of production shader; Android OES/XR not tested", "renderer":RenderingServer.get_video_adapter_name(), "samples":results,"failures":failures}, "\t"))
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("C04 desktop render passed: numeric independent/six-block Alpha, seams and forward hemisphere. Android/XR not tested.")
	quit(0 if failures.is_empty() else 1)
