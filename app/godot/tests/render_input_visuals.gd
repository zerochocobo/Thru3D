extends SceneTree
const Visuals := preload("res://scripts/input_visuals.gd")

func _initialize() -> void:
	_render.call_deferred()

func _render() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1200, 700)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var origin := XROrigin3D.new()
	viewport.add_child(origin)
	var visuals := Visuals.new()
	visuals.use_runtime_models = false
	origin.add_child(visuals)
	var camera := Camera3D.new()
	camera.position = Vector3(0, 0.12, 0.8)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 0.7
	viewport.add_child(camera)
	camera.look_at(Vector3(0, 0.09, 0))
	for hand in visuals.hands:
		var entry: Dictionary = visuals.hands[hand]
		var left: bool = hand == "left_hand"
		entry.grip.show_when_tracked = false
		entry.tracked_hand.show_when_tracked = false
		entry.grip.visible = true
		entry.tracked_hand.visible = true
		entry.controller_gate.visible = true
		entry.hand_gate.visible = true
		entry.controller_gate.position = Vector3(-0.23 if left else 0.23, 0.07, 0)
		entry.controller_gate.rotation_degrees.x = 25
		entry.hand_gate.position.x = -0.085 if left else 0.085
		entry.hand_gate.rotation_degrees.x = -90
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var output := OS.get_environment("QUEST_PREVIEW_PATH")
	var error := image.save_png(output)
	print("Input visual preview: ", output, " result=", error)
	viewport.queue_free()
	await process_frame
	quit(0 if error == OK else 1)
