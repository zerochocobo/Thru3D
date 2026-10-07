extends SceneTree

const DisplayController := preload("res://scripts/xr_display.gd")
const Board := preload("res://scripts/calibration_board.gd")
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

func _run() -> void:
	var viewport := SubViewport.new()
	root.add_child(viewport)
	var environment := Environment.new()
	var controller := DisplayController.new()
	_check(controller.configure(viewport, environment, null, true), "Desktop preview must initialize without XR")
	_check(not viewport.transparent_bg, "Opaque preview must have an opaque background")
	_check(not controller.set_passthrough(true), "Preview must reject real passthrough")
	_check(not controller.requested_passthrough and not controller.applied_passthrough, "Rejected mode must preserve the prior mode")
	_check(not viewport.transparent_bg, "Rejected mode must preserve background opacity")
	_check(controller.error_code == "XR_PASSTHROUGH_UNAVAILABLE", "Unavailable capability must produce a distinct error")
	_check(controller.set_passthrough(false), "Returning to opaque must be allowed")
	_check(controller.error_code.is_empty(), "Successful mode selection must clear a prior error")
	var unavailable := DisplayController.new()
	_check(not unavailable.configure(viewport, environment, null, false), "Missing Android XR must fail initialization")
	_check(unavailable.session_state == "failed", "Missing runtime must not look ready")
	_check(not unavailable.set_passthrough(true), "Missing runtime must reject passthrough")
	var board := Board.new()
	viewport.add_child(board)
	var expected := [0.0, 0.25, 0.5, 0.75, 1.0]
	var material_ids: Array[int] = []
	for index in expected.size():
		var card := board.get_node("Alpha%d" % index) as MeshInstance3D
		var material := card.material_override as ShaderMaterial
		_check(is_equal_approx(float(material.get_shader_parameter("alpha_value")), expected[index]), "Alpha card %d has wrong uniform" % index)
		_check(material.get_instance_id() not in material_ids, "Alpha cards must not share mutable material uniforms")
		material_ids.append(material.get_instance_id())
	var action_map := load("res://openxr_action_map.tres") as OpenXRActionMap
	var action_names: Array[String] = []
	for action_set in action_map.action_sets:
		for action in action_set.actions:
			action_names.append(action.resource_name)
	for required_action in ["trigger_click", "ax_button", "by_button"]:
		_check(required_action in action_names, "Missing controller action: " + required_action)
	viewport.queue_free()
	await process_frame
	if failures.is_empty():
		print("C01/C02 host regression passed: unavailable XR, rejected modes, independent Alpha uniforms, controller action map. Device display not tested.")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)

