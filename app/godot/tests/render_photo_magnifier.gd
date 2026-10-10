extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
var failures: Array[String] = []
var checks := 0
var viewport: SubViewport
var camera: Camera3D
var photo: Node3D
var output := ProjectSettings.globalize_path("res://../../artifacts/photo-magnifier-preview")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func frame() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func source_image(image: Image) -> void:
	photo._texture = ImageTexture.create_from_image(image)
	photo._size = Vector2(image.get_size())
	photo.material.set_shader_parameter("photo_texture", photo._texture)
	photo._detail_material.set_shader_parameter("photo_texture", photo._texture)
	photo._apply_geometry(); photo.panel.visible = true

func sample(image: Image, local: Vector3, node: Node3D) -> Color:
	var point := camera.unproject_position(node.to_global(local))
	return image.get_pixel(clampi(roundi(point.x), 0, image.get_width() - 1), clampi(roundi(point.y), 0, image.get_height() - 1))

func same_color(actual: Color, expected: Color) -> bool:
	return Vector3(actual.r, actual.g, actual.b).distance_to(Vector3(expected.r, expected.g, expected.b)) < 0.12

func detail_bounds(extra: float = 0.0) -> Rect2i:
	var upper := camera.unproject_position(photo._detail.to_global(Vector3(-0.42, 0.27, 0)))
	var lower := camera.unproject_position(photo._detail.to_global(Vector3(0.42, -0.27 - extra, 0)))
	return Rect2i(Vector2i(upper.floor()), Vector2i((lower - upper).ceil())).grow(3)

func white_size(image: Image) -> Vector2i:
	# Measure only the window interior, excluding its caption and the original behind it.
	var upper := camera.unproject_position(photo._detail.to_global(Vector3(-0.4, 0.25, 0)))
	var lower := camera.unproject_position(photo._detail.to_global(Vector3(0.4, -0.25, 0)))
	var bounds := Rect2i(Vector2i(upper.ceil()), Vector2i((lower - upper).floor())).grow(-2)
	var minimum := Vector2i(image.get_width(), image.get_height())
	var maximum := Vector2i(-1, -1)
	for y in range(maxi(0, bounds.position.y), mini(image.get_height(), bounds.end.y)):
		for x in range(maxi(0, bounds.position.x), mini(image.get_width(), bounds.end.x)):
			var color := image.get_pixel(x, y)
			if minf(color.r, minf(color.g, color.b)) > 0.8:
				minimum = Vector2i(mini(minimum.x, x), mini(minimum.y, y))
				maximum = Vector2i(maxi(maximum.x, x), maxi(maximum.y, y))
	return maximum - minimum + Vector2i.ONE if maximum.x >= 0 else Vector2i.ZERO

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	viewport = SubViewport.new()
	viewport.size = Vector2i(1280, 800)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	camera = Camera3D.new(); camera.fov = 70; camera.position = Vector3(0, 1.6, 0)
	viewport.add_child(camera)
	photo = Photo.new()
	photo.history_enabled = false
	viewport.add_child(photo)
	photo.view_camera = camera
	photo.flat_pose = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, -3))
	photo.set_screen_curve(0.0)
	var measured := {}
	for dimensions in [Vector2i(256, 128), Vector2i(128, 256), Vector2i(256, 256)]:
		photo.reset_view()
		var image := Image.create(dimensions.x, dimensions.y, false, Image.FORMAT_RGB8)
		image.fill(Color(0.05, 0.1, 0.2))
		image.fill_rect(Rect2i(0, 0, dimensions.x / 2, dimensions.y), Color(0.08, 0.35, 0.22))
		image.fill_rect(Rect2i(roundi(dimensions.x * 0.75) - 8, dimensions.y / 2 - 8, 16, 16), Color.WHITE)
		source_image(image)
		var before: Image = await frame()
		photo.set_inspect_magnification(2.0); photo.toggle_inspect()
		var hit: Vector3 = photo.panel.to_global(Vector3(photo._flat.size.x * 0.25, 0, 0))
		photo.inspect_ray(camera.global_position, (hit - camera.global_position).normalized())
		var enlarged: Image = await frame()
		var name := "%dx%d" % [dimensions.x, dimensions.y]
		enlarged.save_png(output.path_join(name + "-2x.png"))
		var changed := 0
		var excluded := detail_bounds(0.07)
		for y in enlarged.get_height():
			for x in enlarged.get_width():
				if not excluded.has_point(Vector2i(x, y)) and before.get_pixel(x, y) != enlarged.get_pixel(x, y): changed += 1
		check(changed == 0, "Original image pixels remain unchanged outside the detail window: " + name)
		var square2 := white_size(enlarged)
		check(square2.x > 30 and absi(square2.x - square2.y) <= 2, "Detail window preserves square source pixels: " + name + " " + str(square2))
		photo.close_inspect(); photo.set_inspect_magnification(4.0); photo.toggle_inspect()
		photo.inspect_ray(camera.global_position, (hit - camera.global_position).normalized())
		enlarged = await frame()
		enlarged.save_png(output.path_join(name + "-4x.png"))
		var square4 := white_size(enlarged)
		check(absi(square4.x - square4.y) <= 2 and absf(float(square4.x) / square2.x - 2.0) < 0.08,
			"Window alone doubles detail from 2x to 4x: " + name + " " + str(square4))
		measured[name] = [square2, square4]
	# Packed left/right and top/bottom photos preserve per-eye detail and eye order.
	for layout in [1, 2]:
		photo.reset_view()
		var image := Image.create(256, 128, false, Image.FORMAT_RGB8)
		image.fill(Color.RED)
		image.fill_rect(Rect2i(128, 0, 128, 128) if layout == 1 else Rect2i(0, 64, 256, 64), Color.GREEN)
		source_image(image); photo.set_stereo_layout(layout); photo.swap_eyes = false; photo._apply_geometry()
		photo.set_inspect_magnification(2.0); photo.toggle_inspect(); photo.crop_center = Vector2(0.5, 0.5); photo._update_inspect()
		for swapped in [false, true]:
			if swapped: photo.toggle_eye_order()
			for eye in 2:
				for material in [photo.material, photo._detail_material]: material.set_shader_parameter("test_eye", eye)
				var image_eye: Image = await frame()
				var expected := Color.RED if (eye == 0) != swapped else Color.GREEN
				check(same_color(sample(image_eye, Vector3.ZERO, photo._detail), expected)
					and same_color(sample(image_eye, Vector3(-photo._flat.size.x * 0.25, 0, 0), photo.panel), expected),
					"Original/detail agree on packed layout %d, eye %d, swapped %s" % [layout, eye, swapped])
	# Generated 2D->3D pair uses the same window without an extra decoded source.
	photo.set_stereo_layout(0); photo.swap_eyes = false
	var pair := Image.create(256, 128, false, Image.FORMAT_RGB8)
	pair.fill(Color.RED); pair.fill_rect(Rect2i(128, 0, 128, 128), Color.GREEN)
	photo._stereo_texture = ImageTexture.create_from_image(pair); photo.depth_enabled = true
	photo._apply_geometry()
	for eye in 2:
		for material in [photo.material, photo._detail_material]: material.set_shader_parameter("test_eye", eye)
		var image_eye: Image = await frame()
		check(same_color(sample(image_eye, Vector3.ZERO, photo._detail), Color.RED if eye == 0 else Color.GREEN),
			"Generated 3D detail retains its per-eye color: %d" % eye)
	photo.depth_enabled = false; photo._stereo_texture = null; photo._apply_geometry()
	photo.set_screen_curve(1.0)
	var radius: float = photo._curve_radius()
	var angle: float = photo._flat.size.x * 0.25 / radius
	var curved_hit: Vector3 = photo.panel.to_global(Vector3(sin(angle) * radius, 0, (1.0 - cos(angle)) * radius))
	check(photo.inspect_ray(camera.global_position, (curved_hit - camera.global_position).normalized())
		and is_equal_approx(photo.crop_center.x, 0.75), "Curved image ray samples its actual UV")
	photo.close_image()
	check(not photo.panel.visible and not photo._detail.visible, "Closing photo hides both image and magnifier")
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({
		"state":"passed" if failures.is_empty() else "failed", "checks":checks, "failures":failures, "square_pixels":measured,
		"scope":"Desktop NVIDIA OpenGL: unchanged original pixels, wide/portrait/square aspect, 2x/4x detail, SBS/TB/swap, generated stereo and curved UV",
		"physical_headset_verified":false}, "	"))
	photo.free(); viewport.free()
	for failure in failures: push_error(failure)
	print("Photo magnifier render: %d checks, %d failures; %s" % [checks, failures.size(), output])
	quit(0 if failures.is_empty() else 1)
