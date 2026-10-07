extends SceneTree
const Grade := preload("res://scripts/color_grade.gd")
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func sample(viewport: SubViewport) -> Color:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image().get_pixel(32, 32)

func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(64, 64)
	viewport.transparent_bg = true
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.position.z = 2
	viewport.add_child(camera)
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	quad.mesh.size = Vector2(4, 4)
	viewport.add_child(quad)
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/video_rvm_pair.gdshader")
	quad.material_override = material
	var color := Image.create(2, 2, false, Image.FORMAT_RGB8)
	color.fill(Color(0.2, 0.3, 0.4))
	var mask := Image.create(4, 2, false, Image.FORMAT_R8)
	mask.fill(Color(0.5, 0, 0))
	material.set_shader_parameter("color_texture", ImageTexture.create_from_image(color))
	material.set_shader_parameter("alpha_texture", ImageTexture.create_from_image(mask))
	material.set_shader_parameter("model_size", Vector2(2, 2))
	material.set_shader_parameter("source_size", Vector2(2, 2))
	material.set_shader_parameter("alpha_enabled", false)
	var grade := Grade.new()
	var baseline := await sample(viewport)
	grade.select("Custom")
	grade.apply(material)
	var neutral := await sample(viewport)
	if baseline != neutral: failures.append("Neutral changes original pixels")
	grade.adjust("exposure", 1)
	grade.apply(material)
	var brighter := await sample(viewport)
	if brighter.r < baseline.r * 1.8 or brighter.g < baseline.g * 1.8: failures.append("Exposure does not double display RGB")
	grade.reset_custom()
	grade.adjust("saturation", 0)
	grade.apply(material)
	var mono := await sample(viewport)
	if absf(mono.r - mono.g) > 0.01 or absf(mono.g - mono.b) > 0.01: failures.append("Zero saturation not grayscale")
	material.set_shader_parameter("alpha_enabled", true)
	var alpha_before := await sample(viewport)
	grade.select("Warm")
	grade.apply(material)
	var warm := await sample(viewport)
	if absf(alpha_before.a - warm.a) > 0.005: failures.append("Grading modified mask alpha")
	if warm.r / warm.b <= baseline.r / baseline.b + 0.1: failures.append("Warm preset did not warm test sample")
	grade.select("Original")
	grade.apply(material)
	material.set_shader_parameter("alpha_enabled", false)
	if await sample(viewport) != baseline: failures.append("Original does not bypass grading")
	for failure in failures: push_error(failure)
	print("Color grading desktop pixels: ", "passed" if failures.is_empty() else failures)
	quit(0 if failures.is_empty() else 1)
