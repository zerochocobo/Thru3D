extends RefCounted
## Debug observation only. The caller pins this exact native pair until return.
const Binding := preload("res://scripts/pair_texture_binding.gd")
const MaterialProbe := preload("res://scripts/pair_material_probe.gd")

static func capture(parent: Node, pair: Dictionary, request: int) -> Dictionary:
	var result := {"state": "failed", "request_id": request, "pair": pair.duplicate(true), "images": [],
		"scope": "Adreno Godot SubViewport using production shader and pinned MPV/RVM native textures; XR and main viewport unverified",
		"renderer": RenderingServer.get_video_adapter_name(), "shader": "res://shaders/video_rvm_pair.gdshader"}
	var viewport := SubViewport.new()
	# Square input eye: a full-screen orthographic quad gives known pixel-center UVs.
	viewport.size = Vector2i(640, 640)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	parent.add_child(viewport)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color(0, 0, 0, 0)
	viewport.add_child(world)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.position.z = 2.0
	viewport.add_child(camera)
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	quad.mesh.size = Vector2(2, 2)
	viewport.add_child(quad)
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/video_rvm_pair.gdshader")
	quad.material_override = material
	var binding := Binding.new()
	if not binding.bind(material, pair):
		result["error"] = "Native pair binding rejected"
		viewport.queue_free()
		return result
	DirAccess.make_dir_recursive_absolute("user://diagnostics")
	var errors: Array[String] = []
	for rotation in [0, 90, 180, 270]:
		material.set_shader_parameter("rotation_degrees", rotation)
		for eye in [0, 1]:
			# Regular SubViewport VIEW_INDEX is zero; swap selects the other eye
			# with the unchanged production shader. This is not XR multiview.
			material.set_shader_parameter("swap_eyes", eye == 1)
			for masked in [false, true]:
				material.set_shader_parameter("alpha_enabled", masked)
				await RenderingServer.frame_post_draw
				await RenderingServer.frame_post_draw
				var image := viewport.get_texture().get_image()
				var name := "mpv_pixels_%d_rot%d_eye%d_%s.png" % [request, rotation, eye, "alpha" if masked else "opaque"]
				var path := "user://diagnostics/" + name
				if image.is_empty() or image.get_size() != viewport.size or image.save_png(path) != OK:
					errors.append("Readback/save failed: " + name)
				result.images.append({"file": name, "eye": eye, "rotation": rotation, "alpha_enabled": masked,
					"width": image.get_width(), "height": image.get_height(), "premultiplied_on_transparent_background": true})
	# The image readback finished all GPU draws before borrowed wrappers and pin go.
	var detached := binding.unbind()
	viewport.queue_free()
	result["wrappers_detached"] = int(detached.get("slot_token", -1)) == int(pair.slot_token)
	result["errors"] = errors
	result["analytic_material_probe"] = await MaterialProbe.new().run(parent)
	if result.analytic_material_probe.state != "passed":
		errors.append("Analytic production material check failed")
	result["state"] = "captured" if errors.is_empty() and result.wrappers_detached else "failed"
	return result
