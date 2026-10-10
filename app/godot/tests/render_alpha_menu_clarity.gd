extends SceneTree
## Desktop oracle for UI contrast/composition; runtime passthrough and inference need a Quest capture.
const Menu := preload("res://scripts/player_menu.gd")
const Display := preload("res://scripts/xr_display.gd")
var failures: Array[String] = []
var checks := 0
var output := ProjectSettings.globalize_path("res://../../artifacts/vr-alignment-20261010/alpha-menu")

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func capture(viewport: SubViewport, name: String) -> Image:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.save_png(output.path_join(name + ".png"))
	return image

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1536,1536); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 90; viewport.add_child(camera)
	var world := WorldEnvironment.new(); world.environment = Environment.new(); viewport.add_child(world)
	var display := Display.new(); display.configure(viewport,world.environment,null,true)
	var video := MeshInstance3D.new(); video.mesh = QuadMesh.new(); video.mesh.size = Vector2(8,8); video.position.z = -3
	var video_material := ShaderMaterial.new(); video_material.shader = load("res://shaders/video_rvm_pair.gdshader"); video_material.render_priority = -10
	var color := Image.create(64,64,false,Image.FORMAT_RGB8)
	for y in 64:
		for x in 64: color.set_pixel(x,y,Color(0.8,0.4,0.2) if (x/8+y/8)%2==0 else Color(0.1,0.3,0.6))
	var mask := Image.create(640,320,false,Image.FORMAT_R8); mask.fill(Color(0.35,0,0))
	video_material.set_shader_parameter("color_texture",ImageTexture.create_from_image(color)); video_material.set_shader_parameter("alpha_texture",ImageTexture.create_from_image(mask))
	video_material.set_shader_parameter("source_size",Vector2(64,64)); video_material.set_shader_parameter("model_size",Vector2(320,320))
	video.material_override = video_material; viewport.add_child(video)
	var menu := Menu.new()
	menu.state_provider = func(): return {"has_video":true,"title":"Thru3D","geometry":1,"stereo":true,"top_bottom":false,"alpha_requested":true,"alpha_enabled":true,"position_ms":25000,"duration_ms":60000,"playing":true,"mode_lock":{}}
	viewport.add_child(menu); menu.set_process(false)
	menu.transform = Transform3D(Basis(Vector3.RIGHT,-atan2(0.45,1.4)),Vector3(0,-0.45,-1.4))
	var evidence: Array[Dictionary] = []
	for language in ["en","zh_Hans"]:
		preload("res://scripts/i18n.gd").use(language)
		for section in [0,1]:
			menu.section = section; menu.visible = true; menu._mode_open = true; menu.refresh()
			video_material.set_shader_parameter("alpha_enabled",false)
			display.requested_passthrough = false; display._apply_requested_mode()
			var normal := await capture(viewport,language+"-normal-"+str(section))
			video_material.set_shader_parameter("alpha_enabled",true)
			display.requested_passthrough = true; display._apply_requested_mode()
			var alpha := await capture(viewport,language+"-alpha-"+str(section))
			var text_pixels := 0; var retained := 0; var largest_delta := 0.0
			for y in viewport.size.y:
				for x in viewport.size.x:
					var a := normal.get_pixel(x,y)
					# Bright UI strokes/icons are distinct from this fixture's dim video.
					if minf(a.r,minf(a.g,a.b)) < 0.82: continue
					text_pixels += 1
					var b := alpha.get_pixel(x,y)
					var delta := maxf(absf(a.r-b.r),maxf(absf(a.g-b.g),absf(a.b-b.b)))
					largest_delta = maxf(largest_delta,delta)
					if delta < 0.04: retained += 1
			check(text_pixels > 150, "Menu has visible text "+language+str(section))
			check(retained >= text_pixels*0.98,"Alpha retains sharp foreground strokes "+language+str(section))
			check(viewport.size==Vector2i(1536,1536) and viewport.scaling_3d_scale==1.0,"Alpha keeps UI render size "+language+str(section))
			evidence.append({"language":language,"section":section,"bright_pixels":text_pixels,"retained_pixels":retained,"max_delta":largest_delta})
	viewport.free()
	var report := FileAccess.open(output.path_join("verification.json"),FileAccess.WRITE)
	report.store_string(JSON.stringify({"scope":"Desktop GL UI composition only, Android inference/runtime passthrough NOT tested","checks":checks,"cases":evidence,"failures":failures},"\t")); report.close()
	for failure in failures: push_error(failure)
	print("Alpha menu composition: %d checks, %d failures; Quest runtime unverified" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
