extends SceneTree
## 2D->3D shader math on desktop OpenGL: a near map in the pair's mask shifts each eye's color
## sampling horizontally, near content toward the nose (left eye right, right eye left), far away
## from it. The eye is forced through a uniform; XR multiview and Android are not tested.

const WIDTH := 256
const SHIFT := 0.2
const CONVERGENCE := 0.35

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(WIDTH, 128)
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
	quad.mesh.size = Vector2(4, 2)
	viewport.add_child(quad)
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	# Color: a horizontal ramp, so the rendered red value tells which source column was read.
	var color := Image.create(WIDTH, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in WIDTH:
			color.set_pixel(x, y, Color(float(x) / (WIDTH - 1), 0.0, 0.0))
	# Mask: model 64x32 per eye, both halves equal. Top half near (1), bottom half far (0).
	var mask := Image.create(128, 32, false, Image.FORMAT_R8)
	for y in 32:
		for x in 128:
			mask.set_pixel(x, y, Color(1.0 if y < 16 else 0.0, 0, 0))
	var shader := Shader.new()
	shader.code = FileAccess.get_file_as_string("res://shaders/video_rvm_pair.gdshader") \
		.replace('#include "res://shaders/video_coordinates.gdshaderinc"', FileAccess.get_file_as_string("res://shaders/video_coordinates.gdshaderinc")) \
		.replace("varying flat int eye_index;", "uniform int test_eye = 0;\nvarying flat int eye_index;") \
		.replace("eye_index = int(VIEW_INDEX);", "eye_index = test_eye;")
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("color_texture", ImageTexture.create_from_image(color))
	material.set_shader_parameter("alpha_texture", ImageTexture.create_from_image(mask))
	material.set_shader_parameter("alpha_enabled", false)
	material.set_shader_parameter("source_size", Vector2(WIDTH, 64))
	material.set_shader_parameter("model_size", Vector2(64, 32))
	material.set_shader_parameter("depth_shift", SHIFT)
	material.set_shader_parameter("depth_convergence", CONVERGENCE)
	quad.material_override = material
	var reference := await _row_values(viewport, material, false, 0)
	# Rows: 32 lies in the near half, 96 in the far half. Column 128 is far from the edges.
	for eye in 2:
		var shifted := await _row_values(viewport, material, true, eye)
		for row in [32, 96]:
			var near := 1.0 if row == 32 else 0.0
			var side := 1.0 if eye == 0 else -1.0
			var expected := -side * (near - CONVERGENCE) * SHIFT * 0.5 * WIDTH
			var source := _locate(reference[row], shifted[row][128])
			var actual := source - 128.0
			if absf(actual - expected) > 2.0:
				failures.append("eye %d row %d: source offset %.1f px, expected %.1f" % [eye, row, actual, expected])
	for failure in failures:
		push_error(failure)
	print("Depth parallax desktop render: %s (%d failures). XR multiview and Android not tested." % ["passed" if failures.is_empty() else "FAILED", failures.size()])
	quit(0 if failures.is_empty() else 1)

func _row_values(viewport: SubViewport, material: ShaderMaterial, depth: bool, eye: int) -> Dictionary:
	material.set_shader_parameter("depth_enabled", depth)
	material.set_shader_parameter("test_eye", eye)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.convert(Image.FORMAT_RGB8)
	var rows := {}
	for row in [32, 96]:
		var values: Array[float] = []
		for x in WIDTH:
			values.append(image.get_pixel(x, row).r)
		rows[row] = values
	return rows

## Column of the unshifted render whose red matches value (sub-pixel, the ramp is monotonic).
func _locate(row: Array, value: float) -> float:
	for x in range(1, row.size()):
		if row[x] >= value:
			var low: float = row[x - 1]
			var span: float = maxf(1e-6, row[x] - low)
			return x - 1 + clampf((value - low) / span, 0.0, 1.0)
	return float(row.size() - 1)
