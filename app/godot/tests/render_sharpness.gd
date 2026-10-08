extends SceneTree
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../artifacts/compat-quality-20261007")

func _initialize() -> void: call_deferred("_run")
func frame(viewport: SubViewport) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(128,128)
	viewport.transparent_bg = true
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2
	camera.position.z = 2
	viewport.add_child(camera)
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	quad.mesh.size = Vector2(2,2)
	viewport.add_child(quad)
	var picture := Image.create(32,32,false,Image.FORMAT_RGB8)
	for y in 32:
		for x in 32:
			var v := 0.5 + 0.25 * sin(float(x) * 0.6)
			picture.set_pixel(x,y,Color(v,v,v))
	var mask := Image.create(64,32,false,Image.FORMAT_R8)
	mask.fill(Color(.5,0,0))
	for name in ["video_rvm_pair", "photo"]:
		var material := ShaderMaterial.new()
		material.shader = load("res://shaders/%s.gdshader" % name)
		material.set_shader_parameter("source_size",Vector2(32,32))
		material.set_shader_parameter("color_texture" if name == "video_rvm_pair" else "photo_texture",ImageTexture.create_from_image(picture))
		if name == "video_rvm_pair":
			material.set_shader_parameter("alpha_texture",ImageTexture.create_from_image(mask))
			material.set_shader_parameter("model_size",Vector2(32,32))
		quad.material_override = material
		material.set_shader_parameter("sharpness",0.0)
		var before := await frame(viewport)
		material.set_shader_parameter("sharpness",0.6)
		var after := await frame(viewport)
		var changed := 0
		for y in range(8,120):
			for x in range(8,120):
				var a := before.get_pixel(x,y)
				var b := after.get_pixel(x,y)
				if absf(a.r-b.r) > 0.002: changed += 1
				if absf(a.a-b.a) > 0.001: failures.append(name + " modified alpha"); break
		if changed < 100: failures.append(name + " sharpness has no visible effect")
		before.save_png(output.path_join(name+"-original.png"))
		after.save_png(output.path_join(name+"-sharp.png"))
		material.set_shader_parameter("sharpness",0.0)
		var restored := await frame(viewport)
		if restored.get_data() != before.get_data(): failures.append(name + " off did not restore original pixels")
		# Different constant colours at the stereo seam must never sharpen across eyes.
		material.set_shader_parameter("stereo_sbs", true)
		for y in 32:
			for x in 32: picture.set_pixel(x,y,Color(.8,.1,.1) if x < 16 else Color(.1,.1,.8))
		material.set_shader_parameter("color_texture" if name == "video_rvm_pair" else "photo_texture",ImageTexture.create_from_image(picture))
		var seam_before := await frame(viewport)
		material.set_shader_parameter("sharpness",0.6)
		var seam_after := await frame(viewport)
		if seam_before.get_data() != seam_after.get_data(): failures.append(name + " sharpening crosses the stereo seam")
		# Restore the pattern for the next shader.
		for y in 32:
			for x in 32:
				var v := .5 + .25 * sin(float(x)*.6)
				picture.set_pixel(x,y,Color(v,v,v))
	for failure in failures: push_error(failure)
	print("Sharpness pixels, alpha, bypass and stereo seam: ", "passed" if failures.is_empty() else failures)
	quit(0 if failures.is_empty() else 1)
