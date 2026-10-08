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
	_check_controller_profiles(action_map)
	_check_export_targets()
	viewport.queue_free()
	await process_frame
	if failures.is_empty():
		print("C01/C02 host regression passed: unavailable XR, rejected modes, independent Alpha uniforms, controller action map. Device display not tested.")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)

func _check_export_targets() -> void:
	var presets := ConfigFile.new()
	_check(presets.load("res://export_presets.cfg") == OK, "Export presets must be readable")
	var expected := {"Quest 3": "meta", "PICO 4": "pico", "OpenXR (Experimental)": "khronos"}
	for index in expected.size():
		var section := "preset.%d" % index
		var name := str(presets.get_value(section, "name", ""))
		_check(expected.has(name), "Unknown XR export target: " + name)
		if not expected.has(name): continue
		var options := section + ".options"
		for vendor in ["meta", "pico", "khronos", "androidxr"]:
			_check(bool(presets.get_value(options, "xr_features/enable_%s_plugin" % vendor, false)) == (vendor == expected[name]), "Each export must enable exactly its intended vendor: " + name + "/" + vendor)
	_check(bool(presets.get_value("preset.0.options", "meta_xr_features/quest_2_support", false)), "Quest export must include Quest 2")
	_check(bool(presets.get_value("preset.0.options", "meta_xr_features/quest_3_support", false)), "Quest export must retain Quest 3/3S")
	_check(int(presets.get_value("preset.2.options", "khronos_xr_features/vendors", -1)) == 0, "Generic OpenXR must use Khronos Other without HTC-specific requirements")

func _check_controller_profiles(action_map: OpenXRActionMap) -> void:
	_check(ProjectSettings.get_setting("xr/openxr/default_action_map") == "res://openxr_action_map.tres", "Startup must use the tested action map")
	var profiles := {}
	for profile in action_map.interaction_profiles:
		_check(not profiles.has(profile.interaction_profile_path), "Duplicate interaction profile")
		profiles[profile.interaction_profile_path] = profile
	for path in ["/interaction_profiles/bytedance/pico_neo3_controller", "/interaction_profiles/khr/simple_controller",
		"/interaction_profiles/bytedance/pico4_controller", "/interaction_profiles/bytedance/pico4s_controller",
		"/interaction_profiles/oculus/touch_controller"]:
		_check(profiles.has(path), "Missing controller profile: " + path)
		if not profiles.has(path): continue
		var bindings := {}
		for binding in profiles[path].bindings:
			var action: String = binding.action.resource_name
			if not bindings.has(action): bindings[action] = []
			bindings[action].append(binding.binding_path)
		if path.ends_with("/pico4s_controller"):
			_check("/user/hand/right/input/menu/click" not in bindings.get("menu_button", []), "Ultra has no right-hand menu button")
		var simple: bool = path.ends_with("/simple_controller")
		for hand in ["left", "right"]:
			var user_path: String = "/user/hand/" + hand
			var required := {"default_pose": "/input/aim/pose", "aim_pose": "/input/aim/pose",
				"grip_pose": "/input/grip/pose", "trigger_click": "/input/select/click" if simple else "/input/trigger/value",
				"haptic": "/output/haptic"}
			if not simple:
				required.merge({"trigger": "/input/trigger/value", "grip_click": "/input/squeeze/value",
					"primary": "/input/thumbstick", "primary_click": "/input/thumbstick/click",
					"ax_button": "/input/x/click" if hand == "left" else "/input/a/click",
					"by_button": "/input/y/click" if hand == "left" else "/input/b/click"})
			if simple or path.ends_with("/pico_neo3_controller") or hand == "left":
				required["menu_button"] = "/input/menu/click"
			for action in required:
				_check(user_path + required[action] in bindings.get(action, []), "%s %s missing %s" % [path, hand, action])
		# The fallback must remain usable without vendor or optional pose extensions.
		if simple:
			for binding in profiles[path].bindings:
				var component: String = binding.binding_path.trim_prefix("/user/hand/left").trim_prefix("/user/hand/right")
				_check(component in ["/input/aim/pose", "/input/grip/pose", "/input/select/click", "/input/menu/click", "/output/haptic"], "Unsupported simple-controller component: " + component)

