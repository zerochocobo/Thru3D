extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
var viewport: SubViewport
var camera: Camera3D
var photo: Node3D
var failures: Array[String] = []
var checks := 0
var measurements: Array = []
var output := ProjectSettings.globalize_path("res://../../artifacts/photo-magnifier-scale")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func frame() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func white_box(image: Image, bounds: Rect2i) -> Vector2i:
	var minimum := image.get_size()
	var maximum := Vector2i(-1,-1)
	for y in range(maxi(0,bounds.position.y),mini(image.get_height(),bounds.end.y)):
		for x in range(maxi(0,bounds.position.x),mini(image.get_width(),bounds.end.x)):
			var color := image.get_pixel(x,y)
			if minf(color.r,minf(color.g,color.b)) > 0.8:
				minimum = Vector2i(mini(minimum.x,x),mini(minimum.y,y))
				maximum = Vector2i(maxi(maximum.x,x),maxi(maximum.y,y))
	return maximum-minimum+Vector2i.ONE if maximum.x >= 0 else Vector2i.ZERO

func window_bounds() -> Rect2i:
	var upper := camera.unproject_position(photo._detail.to_global(Vector3(-0.4,0.25,0)))
	var lower := camera.unproject_position(photo._detail.to_global(Vector3(0.4,-0.25,0)))
	return Rect2i(Vector2i(upper.ceil()),Vector2i((lower-upper).floor())).grow(-2)

func source_point(uv: Vector2) -> Vector3:
	var x: float = (uv.x-0.5)*photo._flat.size.x
	var local := Vector3(x,(0.5-uv.y)*photo._flat.size.y,0)
	if photo.screen_curve > 0:
		var radius: float = photo._curve_radius()
		local.x = sin(x/radius)*radius; local.z = (1-cos(x/radius))*radius
	return photo.panel.to_global(local)

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	viewport = SubViewport.new(); viewport.size = Vector2i(1280,800)
	viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	camera = Camera3D.new(); camera.position = Vector3(0,1.6,0); camera.fov = 70
	viewport.add_child(camera)
	photo = Photo.new(); photo.history_enabled = false; photo.sharpness = 0
	viewport.add_child(photo); photo.view_camera = camera
	var cases := [
		{"name":"wide-default","size":Vector2i(4096,2048),"scale":1.0,"distance":3.0,"curve":0.0,"yaw":0.0},
		{"name":"wide-600-percent","size":Vector2i(4096,2048),"scale":6.0,"distance":3.0,"curve":0.0,"yaw":0.0},
		{"name":"wide-closest-largest","size":Vector2i(4096,2048),"scale":6.0,"distance":0.3,"curve":0.0,"yaw":0.0},
		{"name":"wide-small-far","size":Vector2i(4096,2048),"scale":0.4,"distance":10.0,"curve":0.0,"yaw":0.0},
		{"name":"portrait-default","size":Vector2i(2048,4096),"scale":1.0,"distance":3.0,"curve":0.0,"yaw":0.0},
		{"name":"portrait-largest","size":Vector2i(2048,4096),"scale":6.0,"distance":3.0,"curve":0.0,"yaw":0.0},
		{"name":"square-large","size":Vector2i(2048,2048),"scale":3.0,"distance":2.0,"curve":0.0,"yaw":0.0},
		{"name":"curved-large","size":Vector2i(4096,2048),"scale":6.0,"distance":3.0,"curve":0.7,"yaw":0.0},
		{"name":"tilted-curved","size":Vector2i(4096,2048),"scale":1.0,"distance":3.0,"curve":0.35,"yaw":0.15},
		{"name":"pitched-rolled","size":Vector2i(4096,2048),"scale":1.0,"distance":3.0,"curve":0.0,"yaw":0.2,"pitch":0.2,"roll":0.3},
		{"name":"moved-viewer","size":Vector2i(4096,2048),"scale":2.0,"distance":3.0,"curve":0.4,"yaw":0.0,"eye_offset":Vector3(0.4,0.2,0.5)}
	]
	for item in cases:
		camera.position = Vector3(0,1.6,0)+item.get("eye_offset",Vector3.ZERO)
		camera.look_at(Vector3(0,1.6,-item.distance))
		photo.reset_view()
		photo._size = Vector2(item.size)
		photo.set_screen_distance(item.distance); photo.set_screen_scale(item.scale); photo.set_screen_curve(item.curve)
		photo.flat_pose = Transform3D(Basis.from_euler(Vector3(item.get("pitch",0.0),item.yaw,item.get("roll",0.0))),Vector3(0,1.6,-item.distance))
		photo._apply_geometry(); photo.panel.visible = true
		var centre := camera.unproject_position(source_point(Vector2(0.5,0.5)))
		var one_texel := camera.unproject_position(source_point(Vector2(0.5+1.0/item.size.x,0.5)))-centre
		var side := maxi(2,roundi(14.0/maxf(0.001,one_texel.length())))
		var desired_u: float = clampf(0.5-130.0/maxf(1.0,one_texel.length()*item.size.x),0.4,0.499)
		var pixel_x := roundi(desired_u*item.size.x)
		var pixel_y: int = item.size.y/2
		var image := Image.create(item.size.x,item.size.y,false,Image.FORMAT_RGB8)
		image.fill(Color(0.05,0.1,0.2))
		image.fill_rect(Rect2i(pixel_x-side/2,pixel_y-side/2,side,side),Color.WHITE)
		photo._texture = ImageTexture.create_from_image(image)
		photo.material.set_shader_parameter("photo_texture",photo._texture)
		photo._detail_material.set_shader_parameter("photo_texture",photo._texture)
		photo._apply_geometry()
		var original: Image = await frame()
		var original_size := white_box(original,Rect2i(Vector2i.ZERO,original.get_size()))
		check(original_size.x >= 5 and original_size.y >= 5, item.name+": original detail is measurable")
		if item.name in ["wide-default","wide-600-percent"]: original.save_png(output.path_join(item.name+"-original.png"))
		var target: Vector3 = source_point(Vector2(float(pixel_x)/item.size.x,float(pixel_y)/item.size.y))
		var record := {"case":item.name,"original_pixels":original_size,"magnified":[]}
		for magnification in [2.0,4.0,8.0]:
			photo.set_inspect_magnification(magnification); photo.toggle_inspect()
			photo.inspect_ray(camera.global_position,(target-camera.global_position).normalized())
			var enlarged: Image = await frame()
			var actual := white_box(enlarged,window_bounds())
			var expected: Vector2 = Vector2(original_size)*magnification
			var tolerance := Vector2(maxf(3.0,expected.x*0.08),maxf(3.0,expected.y*0.08))
			check(absf(actual.x-expected.x) <= tolerance.x and absf(actual.y-expected.y) <= tolerance.y,
				"%s %.0fx must magnify ORIGINAL %s to %s, actual %s" % [item.name,magnification,original_size,expected,actual])
			record.magnified.append({"zoom":magnification,"pixels":actual,"relative_to_original":Vector2(actual)/Vector2(original_size)})
			if item.name in ["wide-default","wide-600-percent"]: enlarged.save_png(output.path_join("%s-%.0fx.png" % [item.name,magnification]))
			photo.close_inspect()
		measurements.append(record)
	FileAccess.open(output.path_join("verification.json"),FileAccess.WRITE).store_string(JSON.stringify({
		"state":"passed" if failures.is_empty() else "failed","checks":checks,"failures":failures,"measurements":measurements,
		"scope":"Actual rendered source/detail pixel ratios at 2/4/8x, 40-600% image size, 0.3-10m, wide/portrait/square, curve/yaw/pitch/roll/moved viewer",
		"physical_headset_verified":false},"	"))
	photo.free(); viewport.free()
	for failure in failures: push_error(failure)
	print("Photo visual magnification: %d checks, %d failures; %s" % [checks,failures.size(),output])
	quit(0 if failures.is_empty() else 1)
