extends SceneTree
## Pixel regression: menu depth must respect nearby input models without losing media overlays.
const Menu := preload("res://scripts/ray_menu.gd")
const Visuals := preload("res://scripts/input_visuals.gd")
var failures: Array[String] = []
var checks := 0
var output := OS.get_environment("QUEST_MENU_DEPTH_DIR")

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func capture(viewport: SubViewport, label: String) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	if not output.is_empty():
		DirAccess.make_dir_recursive_absolute(output)
		if image.save_png(output.path_join(label + ".png")) != OK: failures.append("Save " + label)
	return image

func difference(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()

func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(600, 600)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.position.z = 1.0
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.0
	viewport.add_child(camera)
	var menu := Menu.new()
	viewport.add_child(menu)
	menu.position = Vector3.ZERO
	menu._set_backdrop(Vector2(0.9, 0.8))
	menu._button(1, "Play", Vector2(0, 0.1), Vector2(0.22, 0.16), true, "play")
	menu._label("Menu depth", Vector3(0, -0.08, 0.006), 24)
	menu._place_device_status(Vector2(0, -0.27))
	menu.device_status.set_process(false)
	menu.device_status.status_provider = func(): return {"level": 75, "charging": true, "clock24": true}
	menu.device_status.clock_provider = func(): return {"hour": 12, "minute": 34}
	menu.device_status.refresh(true)
	var texture_image := Image.create(2, 2, false, Image.FORMAT_RGB8)
	texture_image.fill(Color(0.8, 0.15, 0.2))
	var texture := ImageTexture.create_from_image(texture_image)
	var thumbnail := MeshInstance3D.new()
	thumbnail.mesh = QuadMesh.new()
	thumbnail.mesh.size = Vector2(0.1, 0.1)
	thumbnail.position = Vector3(0.23, 0.1, 0.007)
	thumbnail.material_override = menu._material(Color.WHITE, 12)
	thumbnail.material_override.albedo_texture = texture
	menu.add_child(thumbnail)
	menu.visible = true
	var menu_only := await capture(viewport, "menu")
	var occluder := MeshInstance3D.new()
	occluder.mesh = BoxMesh.new()
	occluder.mesh.size = Vector3(0.65, 0.65, 0.04)
	occluder.position.z = 0.3
	var opaque := StandardMaterial3D.new()
	opaque.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	opaque.albedo_color = Color(0.12, 0.7, 0.23)
	occluder.material_override = opaque
	viewport.add_child(occluder)
	var front := await capture(viewport, "front")
	menu.visible = false
	var model_only := await capture(viewport, "opaque-reference")
	var covered := 0
	for y in range(115, 485):
		for x in range(115, 485):
			if difference(front.get_pixel(x, y), model_only.get_pixel(x, y)) < 0.02: covered += 1
	check(covered > 370 * 370 * 0.99, "Near model occludes panel, buttons, labels, icons, thumbnail and status pill")
	menu.visible = true
	occluder.position.z = -0.3
	var behind := await capture(viewport, "behind")
	check(difference(behind.get_pixel(300, 300), menu_only.get_pixel(300, 300)) < 0.04,
		"Far model stays behind the panel")
	occluder.free()
	# Exercise the actual controller geometry/material, not just a solid depth fixture.
	var visuals := Visuals.new()
	visuals.use_runtime_models = false
	viewport.add_child(visuals)
	var controller := visuals._controller_model(false)
	controller.scale = Vector3.ONE * 3.0
	controller.position.z = 0.3
	viewport.add_child(controller)
	menu.visible = false
	var controller_only := await capture(viewport, "controller-reference")
	menu.visible = true
	var controller_menu := await capture(viewport, "controller-menu")
	var pixels := 0
	var preserved := 0
	for y in 600:
		for x in 600:
			var reference := controller_only.get_pixel(x, y)
			if reference.r > 0.3:
				pixels += 1
				if difference(reference, controller_menu.get_pixel(x, y)) < 0.02: preserved += 1
	check(pixels > 1000 and preserved > pixels * 0.99, "Actual controller remains visible in front of menu")
	controller.free()
	# Production media surfaces draw before the menu and do not write depth, even at 0.8 m.
	var media := MeshInstance3D.new()
	media.mesh = QuadMesh.new()
	media.mesh.size = Vector2(1, 1)
	media.position.z = 0.2
	viewport.add_child(media)
	for shader_name in ["video_rvm_pair", "photo"]:
		var material := ShaderMaterial.new()
		material.shader = load("res://shaders/" + shader_name + ".gdshader")
		material.render_priority = -10
		material.set_shader_parameter("photo_texture" if shader_name == "photo" else "color_texture", texture)
		material.set_shader_parameter("alpha_enabled", false)
		material.set_shader_parameter("source_size", Vector2(2, 2))
		media.material_override = material
		var over_media := await capture(viewport, shader_name)
		check(difference(over_media.get_pixel(300, 300), menu_only.get_pixel(300, 300)) < 0.04,
			"Menu stays above near " + shader_name)
	media.free()
	var ray_origin := Vector3(0, 0.1, 0.6)
	check(menu.press_pointer("right_hand", ray_origin, Vector3.FORWARD, true), "Ray still selects menu")
	var pointer := await capture(viewport, "pointer")
	var dot: Vector2i = camera.unproject_position(menu.to_global(menu._pointers.right_hand.dot.position))
	check(pointer.get_pixelv(dot).r > 0.8 and pointer.get_pixelv(dot).g > 0.4, "Pointer remains visible over menu")
	viewport.free()
	for failure in failures: push_error(failure)
	print("Menu depth pixels: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
