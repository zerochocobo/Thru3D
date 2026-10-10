extends SceneTree
const Depth := preload("res://scripts/subtitle_depth.gd")
const Menu := preload("res://scripts/player_menu.gd")
var failures: Array[String] = []
var state := {"has_video": true, "geometry": 1, "subtitle_distance": 5.0, "subtitle_position": 0.0}
var saves: Array = []
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var settings := ConfigFile.new()
	check(Depth.restore_position(settings) == 0, "New settings default to centre")
	for index in 5:
		settings.set_value("subtitles", "position", index)
		check(is_equal_approx(Depth.elevation(Depth.restore_position(settings)), [0.488, 0.244, 0.0, -0.244, -0.488][index]), "Legacy position retains its angle")
	settings.set_value("subtitles", "elevation_degrees", 45.0)
	check(Depth.restore_position(settings) == 45, "New angle overrides legacy index")
	var restored := ConfigFile.new()
	restored.parse(settings.encode_to_text())
	check(Depth.restore_position(restored) == 45, "Angle persists across reload")
	check(Depth.position(INF) == 0 and Depth.position(-100) == -60 and Depth.position(100) == 60, "Angle validation")
	for angle in [-60.0, 0.0, 60.0]:
		var direction := Basis(Vector3.RIGHT, Depth.elevation(angle)) * Vector3.FORWARD
		check(is_equal_approx(direction.y, sin(deg_to_rad(angle))), "Positive angle points up, negative down")
	check(Depth.distance(15) == 10 and is_equal_approx(Depth.distance(0), 0.1), "Distance bounds")
	var menu := Menu.new()
	menu.state_provider = func(): return state
	menu.adjustment_requested.connect(func(key, value): state[key] = value)
	menu.setting_requested.connect(func(key, value): state[key] = value; saves.append([key, value]))
	root.add_child(menu)
	menu.toggle()
	menu._activate(110)
	check(menu.choices.sliders.size() == 2 and menu.choices.opened.is_empty(), "CC uses two direct sliders")
	for target in menu.choices.sliders.keys():
		var slider: Dictionary = menu.choices.sliders[target]
		var key: String = menu.choices.targets[target].key
		var centre: Vector3 = menu.to_local(slider.node.global_position)
		var start := Vector3(centre.x + slider.left, centre.y, 1)
		var end := Vector3(start.x + slider.width, start.y, 1)
		var before := saves.size()
		check(menu.press_pointer("right", menu.to_global(start), -menu.global_basis.z, true), "Ray captures rail")
		check(is_equal_approx(state[key], slider.span.x) and saves.size() == before and menu.has_pointer_capture(), "Press previews lower endpoint without saving")
		menu.update_pointer("left", menu.to_global(end), -menu.global_basis.z, true)
		check(is_equal_approx(state[key], slider.span.x), "Other hand cannot change captured slider")
		menu.refresh_values()
		menu.update_pointer("right", menu.to_global(end), -menu.global_basis.z, true)
		check(is_equal_approx(state[key], slider.span.y), "Drag survives menu redraw and reaches upper endpoint")
		menu.release_pointer("left", Vector3.ZERO, Vector3.ZERO, false)
		check(menu.has_pointer_capture(), "Other hand cannot release captured rail")
		menu.release_pointer("right", Vector3.ZERO, Vector3.ZERO, false)
		check(saves.size() == before + 1 and not menu.has_pointer_capture(), "Tracking loss commits last preview once")
	# Closing an active drag also saves once.
	var target: int = menu.choices.sliders.keys()[0]
	var slider: Dictionary = menu.choices.sliders[target]
	var centre: Vector3 = menu.to_local(slider.node.global_position)
	var point := Vector3(centre.x + slider.left + slider.width / 2, centre.y, 1)
	menu.press_pointer("right", menu.to_global(point), -menu.global_basis.z, true)
	check(state.subtitle_position == 0, "Angle midpoint returns to centre")
	var before := saves.size()
	menu.dismiss()
	check(saves.size() == before + 1 and not menu.has_pointer_capture(), "Dismiss saves and clears slider capture")
	menu.free()
	for failure in failures: push_error(failure)
	print("Subtitle slider checks=", checks, " failures=", failures.size())
	quit(0 if failures.is_empty() else 1)
