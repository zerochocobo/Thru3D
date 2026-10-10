extends SceneTree
const Surface := preload("res://scripts/media_surface.gd")
var failures: Array[String] = []
var checks := 0
var samples: Array[Dictionary] = []
var viewport: SubViewport
var output := OS.get_environment("VRPP_ALIGNMENT_OUTPUT")

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func capture() -> Image:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func shader_for(path: String) -> Shader:
	var shader := Shader.new()
	shader.code = FileAccess.get_file_as_string(path).replace("samplerExternalOES", "sampler2D").replace("eye_index = int(VIEW_INDEX);", "eye_index = test_eye;")
	shader.code = shader.code.replace('#include "res://shaders/video_coordinates.gdshaderinc"', FileAccess.get_file_as_string("res://shaders/video_coordinates.gdshaderinc").replace("varying flat int eye_index;", "uniform int test_eye = 0;\nvarying flat int eye_index;"))
	return shader

func source(layout: int) -> ImageTexture:
	var sbs := layout in [1, 3]
	var tb := layout in [2, 4]
	var image := Image.create(256 * (2 if sbs else 1), 256 * (2 if tb else 1), false, Image.FORMAT_RGB8)
	for y in image.get_height():
		for x in image.get_width():
			image.set_pixel(x, y, Color((float(x % 256) + 0.5) / 256.0, (float(y % 256) + 0.5) / 256.0, 0.8 if (sbs and x >= 256) or (tb and y >= 256) else 0.2))
	return ImageTexture.create_from_image(image)

func _run() -> void:
	if output.is_empty(): output = ProjectSettings.globalize_path("res://../../artifacts/vr-alignment-20261010")
	DirAccess.make_dir_recursive_absolute(output)
	viewport = SubViewport.new(); viewport.size = Vector2i(257, 257); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var head := Camera3D.new(); head.position = Vector3(1.1, 1.7, -0.8)
	head.basis = Basis(Vector3.UP, 0.67) * Basis(Vector3.RIGHT, -0.21)
	viewport.add_child(head)
	var eye_camera := Camera3D.new(); eye_camera.fov = 80; viewport.add_child(eye_camera); eye_camera.current = true
	var parent := Node3D.new(); parent.position = Vector3(2, 0.2, 1); parent.rotation.y = -0.31; viewport.add_child(parent)
	var surface: Node3D
	var baseline_path := OS.get_environment("VRPP_ALIGNMENT_BASELINE")
	if baseline_path.is_empty(): surface = Surface.new()
	else:
		var baseline := GDScript.new(); baseline.source_code = FileAccess.get_file_as_string(baseline_path)
		if baseline.reload() != OK: push_error("Could not load baseline surface"); quit(1); return
		surface = baseline.new()
	parent.add_child(surface); surface.view_camera = head
	surface.initialize_surface(shader_for("res://shaders/video_rvm_pair.gdshader")); surface.panel.visible = true
	surface.material.set_shader_parameter("alpha_enabled", false); surface.sharpness = 0
	for pipeline in ["video_rvm_pair", "video_rvm_pair_oes"]:
		surface.material.shader = shader_for("res://shaders/" + pipeline + ".gdshader")
		surface.material.set_shader_parameter("alpha_enabled", false); surface.sharpness = 0
		for projection in [0, 1, 2, 3]:
			for layout in 5:
				surface.stereo_sbs = layout != 0; surface.top_bottom = layout in [2, 4]; surface.stereo_half = layout in [3, 4]
				var texture := source(layout)
				surface.material.set_shader_parameter("color_texture", texture)
				surface.material.set_shader_parameter("source_size", Vector2(texture.get_width(), texture.get_height()))
				for lens in ([180, 190, 200, 220] if projection == 2 else [180]):
					surface.fisheye_fov = lens; surface.geometry = projection
					surface.flat_pose = surface.global_transform.affine_inverse() * Transform3D(head.global_basis, head.global_position - head.global_basis.z * 2)
					surface._apply_geometry(); surface.reset_view()
					check((-surface.panel.global_basis.z).distance_to(-head.global_basis.z) < 0.00001, "World gaze alignment " + str([pipeline, projection, layout, lens]))
					for swap in [false, true]:
						surface.swap_eyes = swap; surface._apply_geometry()
						for eye in 2:
							eye_camera.global_transform = head.global_transform * Transform3D(Basis.IDENTITY, Vector3(-0.032 if eye == 0 else 0.032, 0, 0))
							surface.material.set_shader_parameter("test_eye", eye)
							var image := await capture()
							var centre := image.get_pixel(128, 128)
							var chosen_eye := (1 - eye if swap else eye) if layout != 0 else 0
							var name := str([pipeline, projection, layout, lens, swap, eye])
							check(absf(centre.r - 0.5) < (0.06 if projection == 0 else 0.025) and absf(centre.g - 0.5) < 0.025, "Eye centre UV " + name + " got " + str(centre))
							check(absf(centre.b - (0.8 if chosen_eye == 1 else 0.2)) < 0.025, "Correct eye packing " + name)
							var step := 8 if projection == 0 else 37 # Full SBS/TB can make the flat screen narrow on one axis.
							check(image.get_pixel(128+step,128).r > centre.r and image.get_pixel(128-step,128).r < centre.r and image.get_pixel(128,128-step).g < centre.g and image.get_pixel(128,128+step).g > centre.g, "Direction signs " + name)
							samples.append({"pipeline":pipeline,"projection":projection,"layout":layout,"fov":lens,"swap":swap,"eye":eye,"centre":[centre.r,centre.g,centre.b]})
							if layout == 1 and not swap and eye == 0 and lens == 180: image.save_png(output.path_join(pipeline + "-projection-%d.png" % projection))
	# Capturing an orientation must not turn the media into a head-locked overlay.
	surface.geometry = 1; surface._apply_geometry(); surface.reset_view()
	var fixed: Basis = surface.panel.global_basis
	head.rotate_y(-0.4); head.position += Vector3(0.2,0.1,-0.3)
	for repeat in 3: surface._apply_geometry(); surface._center_on_view()
	check(surface.panel.global_basis.is_equal_approx(fixed), "Presented frames retain orientation after head turn")
	check(surface.panel.global_position.is_equal_approx(head.global_position), "Translation still follows the head")
	surface.turn_view(0.3,-0.1); surface.zoom_view(0.25)
	check(not surface.panel.global_basis.is_equal_approx(fixed) and surface.panel.global_position.distance_to(head.global_position) > 10, "Manual drag and zoom still work")
	surface.reset_view()
	check((-surface.panel.global_basis.z).distance_to(-head.global_basis.z) < 0.00001 and surface.view_zoom == 0, "Reset removes drag/zoom and centres current gaze")
	for pitch in [PI * 0.5, -PI * 0.5]:
		head.basis = Basis(Vector3.UP,0.7) * Basis(Vector3.RIGHT,pitch); surface.reset_view()
		check(surface.panel.global_basis.is_finite() and (-surface.panel.global_basis.z).distance_to(-head.global_basis.z) < 0.00001, "Vertical gaze stays finite")
	var report := FileAccess.open(output.path_join("render-verification.json"), FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks":checks,"failures":failures,"samples":samples,"scope":"Production projection shaders on desktop OpenGL, OES emulated as sampler2D; Android codec, runtime stereo and passthrough not validated"},"\t")); report.close()
	viewport.free()
	for failure in failures: push_error(failure)
	print("Immersive alignment: %d checks, %d render cases, %d failures" % [checks,samples.size(),failures.size()])
	quit(0 if failures.is_empty() else 1)
