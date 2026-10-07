extends SceneTree
const Grade := preload("res://scripts/color_grade.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
var failures: Array[String] = []
var grade := Grade.new()
var distance := 5.0
var commits := 0

func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	grade.adjust("exposure", 0.75)
	var saved := grade.snapshot()
	grade.select("Warm")
	check(grade.values().temperature == 4000, "Warm preset")
	grade.select("Custom")
	check(grade.values().exposure == 0.75, "Preset selection must retain custom")
	var config := ConfigFile.new()
	config.set_value("video", "color_grade", saved)
	var reloaded := ConfigFile.new()
	check(reloaded.parse(config.encode_to_text()) == OK, "Config round trip")
	grade.restore(reloaded.get_value("video", "color_grade"))
	check(grade.snapshot() == saved, "Restart restores preset and custom values")
	grade.restore({"preset": "broken", "custom": {"exposure": INF, "gamma": -3, "red_gain": "bad", "blue_offset": 8}})
	check(grade.preset == "Original" and grade.custom.exposure == 0 and grade.custom.gamma == 0.7
		and grade.custom.red_gain == 1 and is_equal_approx(grade.custom.blue_offset, 0.2), "Invalid saved settings clamp safely")
	grade.select("Cool")
	grade.adjust("contrast", 1.2)
	check(grade.preset == "Custom" and grade.custom.temperature == 8000, "Editing starts with displayed preset")
	grade.reset_custom()
	check(grade.values() == Grade.DEFAULTS, "Explicit custom reset")
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/video_rvm_pair.gdshader")
	grade.adjust("exposure", 1)
	grade.apply(material)
	preload("res://scripts/pair_texture_binding.gd")._use_shader(material, load("res://shaders/video_rvm_pair_oes.gdshader"))
	check(material.get_shader_parameter("grade_enabled") and material.get_shader_parameter("grade_gain").is_equal_approx(Vector3.ONE * 2), "OES switch preserves grading")
	var video := Video.new()
	video.subtitle_distance = 1
	check(video.subtitle_distance == 5, "Legacy subtitle depth clamps to 5m")
	video.subtitle_distance = INF
	check(video.subtitle_distance == 5, "Invalid subtitle depth defaults to 5m")
	video.subtitle_distance = 100
	check(video.subtitle_distance == 20, "Subtitle maximum")
	video.free()
	var menu := Menu.new()
	menu.state_provider = func(): return {"subtitle_distance": distance, "color_grade": grade.snapshot(), "grade_values": grade.values()}
	menu.adjustment_requested.connect(func(key: String, value: Variant):
		if key == "subtitle_distance": distance = value
		elif key == "grade_preset": grade.select(value)
		elif key == "grade_reset": grade.reset_custom()
		else: grade.adjust(key, value))
	menu.adjustment_committed.connect(func(): commits += 1)
	root.add_child(menu)
	menu.toggle()
	menu.section = 1
	menu._activate(100 + Menu.OPERATIONS[1].find("subtitle_distance"))
	check(menu._adjustment == "subtitle_distance", "Playback setting opens distance editor")
	menu.press_pointer("right", menu.to_global(Vector3(0.63, 0.17, 1)), -menu.global_basis.z, true)
	check(distance == 20 and commits == 0, "Ray press previews subtitle depth")
	menu.update_pointer("left", menu.to_global(Vector3(0.03, 0.17, 1)), -menu.global_basis.z, true)
	check(distance == 20, "Other hand cannot move active slider")
	menu.release_pointer("right", Vector3.ZERO, Vector3.ZERO, true)
	check(commits == 1 and menu._adjust_hand.is_empty(), "Release saves and ends drag")
	menu._activate(400)
	menu._activate(100 + Menu.OPERATIONS[1].find("color_grade"))
	menu._activate(411)
	check(grade.preset == "Warm", "Preset selection")
	menu.press_pointer("right", menu.to_global(Vector3(0.33, -0.05, 1)), -menu.global_basis.z, true)
	check(grade.preset == "Custom", "Dragging exposure selects custom")
	menu.dismiss()
	check(commits == 3 and menu._adjust_hand.is_empty(), "Dismiss saves active drag")
	menu.free()
	for failure in failures: push_error(failure)
	print("Color grading and distance controls: ", "passed" if failures.is_empty() else failures)
	quit(0 if failures.is_empty() else 1)
