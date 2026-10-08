extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
var failures: Array[String] = []
var checks := 0
var viewport: SubViewport
var output := ProjectSettings.globalize_path("res://../../artifacts/photo-immersive")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func frame() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	viewport = SubViewport.new()
	viewport.size = Vector2i(960,600)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color.BLUE
	viewport.add_child(world)
	var camera := Camera3D.new()
	camera.fov = 90
	camera.position = Vector3(0,1.6,0)
	viewport.add_child(camera)
	var photo := Photo.new()
	viewport.add_child(photo)
	photo.view_camera = camera
	photo.flat_pose = Transform3D(Basis.IDENTITY, Vector3(0,1.6,-2))
	var image := Image.create(128,64,false,Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	photo._texture = ImageTexture.create_from_image(image)
	photo._size = Vector2(128,64)
	photo.material.set_shader_parameter("photo_texture", photo._texture)
	photo._apply_geometry(); photo.panel.visible = true
	var soft: Image = await frame()
	soft.save_png(output.path_join("default-flat.png"))
	var feather: Vector2 = photo.material.get_shader_parameter("edge_feather")
	photo.material.set_shader_parameter("edge_feather", Vector2.ZERO)
	var hard: Image = await frame()
	var left := -1; var right := -1
	for x in viewport.size.x:
		if hard.get_pixel(x,300).r > .9:
			if left < 0: left = x
			right = x
	check(left > 0 and right < 959 and right - left > 500, "Default large curve stays within the oracle camera")
	if left >= 0:
		check(soft.get_pixel(left+2,300).r < .7 and soft.get_pixel(left+2,300).b > .2, "Photo edge smoothly reveals background")
		check(soft.get_pixel(480,300).r > .95 and soft.get_pixel(480,300).b < .05, "Photo centre remains unchanged")
	photo.material.set_shader_parameter("edge_feather", feather)
	# Source alpha combines with edge alpha instead of being overwritten.
	image.fill(Color(1,0,0,.5)); photo._texture.update(image)
	var alpha: Image = await frame()
	check(alpha.get_pixel(480,300).r > .3 and alpha.get_pixel(480,300).b > .3, "Transparent photo preserves source alpha")
	image.fill(Color.RED); image.fill_rect(Rect2i(64,0,64,64), Color.GREEN)
	photo._texture.update(image)
	photo.set_stereo_layout(1)
	for eye in 2:
		photo.material.set_shader_parameter("test_eye", eye)
		var stereo: Image = await frame()
		var centre := stereo.get_pixel(480,300)
		check(centre.r > .95 if eye == 0 else centre.g > .95, "SBS eye centre has no artificial seam or opposite-eye bleed")
	image.fill(Color.RED); image.fill_rect(Rect2i(0,32,128,32), Color.GREEN)
	photo._texture.update(image); photo.set_stereo_layout(2)
	for eye in 2:
		photo.material.set_shader_parameter("test_eye", eye)
		var stereo: Image = await frame()
		var centre := stereo.get_pixel(480,300)
		check(centre.r > .95 if eye == 0 else centre.g > .95, "TB eye centre retains its original colour")
	photo.set_stereo_layout(0)
	image.fill(Color.RED); photo._texture.update(image)
	photo.set_projection(3)
	var pano: Image = await frame()
	photo.material.set_shader_parameter("edge_feather", Vector2.ZERO)
	var pano_without_feather: Image = await frame()
	check(pano.get_data() == pano_without_feather.get_data(), "360 panorama pixels unaffected by planar feather uniform")
	photo.set_projection(1)
	photo.material.set_shader_parameter("edge_feather", feather)
	pano = await frame()
	photo.material.set_shader_parameter("edge_feather", Vector2.ZERO)
	pano_without_feather = await frame()
	check(pano.get_data() == pano_without_feather.get_data(), "VR180 pixels unaffected by planar feather uniform")
	photo.set_projection(0)
	photo.set_process(false)
	photo.queue.assign([{"uri":"file://immersive-render-one.png", "title":"immersive-render-one.png"}, {"uri":"file://immersive-render-two.png", "title":"immersive-render-two.png"}])
	photo.index = 0; photo.local_uri = str(photo.queue[0].uri)
	image.fill(Color.GREEN)
	photo._accept({"image":image, "thumbnail":image, "info":{}}, {"id":1, "index":1})
	photo._transition_time = photo.TRANSITION_SECONDS * .5; photo._update_transition()
	var transition: Image = await frame()
	transition.save_png(output.path_join("next-midpoint.png"))
	check(transition.get_pixel(350,300).r > .3 and transition.get_pixel(610,300).g > .3,
		"Rendered next transition has departing red on left and incoming green on right")
	photo.finish_transition()
	image.fill(Color.RED)
	photo._accept({"image":image, "thumbnail":image, "info":{}}, {"id":2, "index":0})
	photo._transition_time = photo.TRANSITION_SECONDS * .5; photo._update_transition()
	transition = await frame()
	transition.save_png(output.path_join("previous-midpoint.png"))
	check(transition.get_pixel(350,300).r > .3 and transition.get_pixel(610,300).g > .3,
		"Rendered previous transition has incoming red on left and departing green on right")
	photo.finish_transition()
	photo.auto_depth = true
	image.fill(Color.BLACK); image.fill_rect(Rect2i(55,18,18,28), Color.WHITE)
	var near := Image.create(252,140,false,Image.FORMAT_RF); near.fill(Color(1,0,0))
	photo._accept({"image":image, "thumbnail":image, "info":{}, "depth_data":{"image":near,"rect":Vector4(0,0,1,1)}}, {"id":3,"index":1})
	photo.finish_transition()
	var centres: Array[float] = []
	for eye in 2:
		photo.material.set_shader_parameter("test_eye", eye)
		var rendered: Image = await frame()
		var total := 0.0; var count := 0
		for x in 960:
			var pixel := rendered.get_pixel(x,300)
			if pixel.r > .8 and pixel.g > .8: total += x; count += 1
		centres.append(total / maxi(count,1))
	check(absf(centres[0]-centres[1]) > 8, "Preconverted photo produces visible opposite-eye disparity")
	var far := Image.create(252,140,false,Image.FORMAT_RF); far.fill(Color(.4,0,0))
	photo._accept({"image":image, "thumbnail":image, "info":{}, "depth_data":{"image":far,"rect":Vector4(0,0,1,1)}}, {"id":4,"index":0})
	photo._transition_time = photo.TRANSITION_SECONDS * .5; photo._update_transition()
	transition = await frame(); transition.save_png(output.path_join("converted-previous-midpoint.png"))
	check(photo.material.get_shader_parameter("photo_depth") and photo._departing.material_override.get_shader_parameter("photo_depth"),
		"Both surfaces in converted transition remain stereo")
	check(is_equal_approx(photo._departing.material_override.get_shader_parameter("depth_texture").get_image().get_pixel(0,0).r,1) \
		and is_equal_approx(photo.material.get_shader_parameter("depth_texture").get_image().get_pixel(0,0).r,.4), "Transition keeps each photo's own depth texture")
	photo.finish_transition(); photo.set_hand_scale(1.2); photo.pan_hand(Vector2(.02,0))
	var magnified: Image = await frame()
	check(photo.depth_enabled and photo.material.get_shader_parameter("photo_depth") and magnified.get_width() == 960,
		"Converted photo still renders in 3D after whole-photo scale and pan")
	photo.free(); viewport.free()
	for failure in failures: push_error(failure)
	print("Immersive photo render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
