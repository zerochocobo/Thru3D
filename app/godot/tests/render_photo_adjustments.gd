extends SceneTree
const Menu := preload("res://scripts/photo_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var output := ProjectSettings.globalize_path("res://../../artifacts/photo-adjustments-preview")
var failures: Array[String] = []
var viewport: SubViewport
var camera: Camera3D
var menu: Node3D
var state := {"has_image":true, "geometry":0, "title":"旅行相册 · 山川与城市 · Travel journal", "index":2, "count":12,
	"can_previous":true, "can_next":true, "screen_distance":3.0, "screen_scale":1.0, "inspect_magnification":2.0,
	"inspect":false, "zoom":1.0, "source_size":"7680 × 4320"}

func _initialize() -> void: call_deferred("_run")

func snapshot(name: String, guard_text: bool = true) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	if image.save_png(output.path_join(name + ".png")) != OK: failures.append("Failed to save " + name)
	if not guard_text: return
	var half: Vector2 = menu._backdrop.mesh.size / 2
	var upper := camera.unproject_position(menu.to_global(menu._backdrop.position + Vector3(-half.x, half.y, 0)))
	var lower := camera.unproject_position(menu.to_global(menu._backdrop.position + Vector3(half.x, -half.y, 0)))
	var pill: Node3D = menu.device_status
	var pill_half: Vector2 = pill._pill.mesh.size / 2
	var pill_upper := camera.unproject_position(pill.to_global(Vector3(-pill_half.x, pill_half.y, 0)))
	var pill_lower := camera.unproject_position(pill.to_global(Vector3(pill_half.x, -pill_half.y, 0)))
	var overflow := 0
	for y in image.get_height():
		for x in image.get_width():
			if x >= upper.x - 2 and x <= lower.x + 2 and y >= upper.y - 2 and y <= lower.y + 2: continue
			if x >= pill_upper.x - 2 and x <= pill_lower.x + 2 and y >= pill_upper.y - 2 and y <= pill_lower.y + 2: continue
			var color := image.get_pixel(x, y)
			if minf(color.r, minf(color.g, color.b)) > 0.8: overflow += 1
	if overflow > 0: failures.append("%s: %d white text pixels outside the panel" % [name, overflow])

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	viewport = SubViewport.new()
	viewport.size = Vector2i(1280, 800)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	camera = Camera3D.new()
	camera.fov = 48
	viewport.add_child(camera)
	menu = Menu.new()
	menu.state_provider = func(): return state.duplicate()
	viewport.add_child(menu)
	I18n.use("zh")
	menu.toggle()
	await snapshot("bar-zh", false)
	var entry: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.PHOTO_ADJUST)[0]
	menu.update_pointer("right_hand", entry.node.global_position + Vector3(0,0,1), -menu.global_basis.z, true)
	await snapshot("bar-hover-zh", false)
	menu.update_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
	menu._activate(Menu.PHOTO_ADJUST)
	for language in ["zh", "zh_Hant", "en", "ja"]:
		I18n.use(language); menu.refresh()
		await snapshot("adjustments-" + language)
	state.screen_distance = 10.0; state.screen_scale = 6.0; state.inspect_magnification = 8.0
	I18n.use("zh"); menu.refresh()
	await snapshot("adjustments-maximum-zh")
	state.geometry = 3
	menu.refresh_values()
	await snapshot("adjustments-panorama-zh")
	if menu._buttons.any(func(b): return b.target in [450, 451] and b.enabled): failures.append("Panorama flat sliders remain enabled")
	menu._activate(Menu.PHOTO_ADJUST_BACK)
	var inspect_icon: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.PHOTO_INSPECT)[0]
	menu.update_pointer("right_hand", inspect_icon.node.global_position + Vector3(0,0,1), -menu.global_basis.z, true)
	await snapshot("inspect-default-tip-zh", false)
	if not menu._tooltip.get_child(0).text.contains("8.0×"): failures.append("Hover does not show saved magnification")
	if menu._buttons.any(func(b): return b.target in [Menu.PHOTO_PLUS, Menu.PHOTO_MINUS]): failures.append("Live zoom controls remain on the photo bar")
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({
		"state":"passed" if failures.is_empty() else "failed", "failures":failures,
		"scope":"Production Godot photo menu on desktop OpenGL; four language layouts, slider extremes and panorama disabled controls",
		"physical_headset_verified":false}, "	"))
	menu.free(); viewport.free()
	for failure in failures: push_error(failure)
	print("Photo adjustment render: %s; %s" % ["passed" if failures.is_empty() else "failed", output])
	quit(0 if failures.is_empty() else 1)
