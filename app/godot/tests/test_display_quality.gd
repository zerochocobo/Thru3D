extends SceneTree
const Quality := preload("res://scripts/display_quality.gd")
const Main := preload("res://scripts/main.gd")
class HostProbe extends RefCounted:
	var requests: Array[bool] = []
	func finish_app(restart: bool) -> void: requests.append(restart)
var failures: Array[String] = []
func check(value: bool, message: String) -> void:
	if not value: failures.append(message)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var settings := ConfigFile.new()
	check(Quality.load_quality(settings) == 1, "Default quality is enhanced")
	check(Quality.load_sharpness(settings) == 0.2, "Default sharpness is gentle")
	var path := "user://quality_test_%d.cfg" % Time.get_ticks_usec()
	settings.set_value("appearance", "background", "dark")
	settings.save(path)
	var main := Main.new()
	main.settings_path = path
	root.add_child(main)
	main.recent_menu.section = main.recent_menu.Section.SETTINGS
	main.recent_menu.tab = main.recent_menu.DISPLAY_TAB
	main.recent_menu.refresh()
	check(main.recent_menu.rows.size() == 2 and main.recent_menu.rows[0].choices.size() == 3 and main.recent_menu.rows[1].choices.size() == 4,
		"Quality and sharpness each occupy one field with all their choices")
	main._on_setting_changed("display_quality",2)
	main._on_setting_changed("sharpness",0.4)
	check(main.display.render_scale == 1.1, "Quality keeps current XR targets until restart")
	check(main._library_settings().display_quality_pending, "Pending quality is visible")
	check(main.video.sharpness == 0.4 and main.photo.sharpness == 0.4, "Sharpness applies to both media types")
	check(main.photo._detail_material.get_shader_parameter("sharpness") == 0.4, "Photo magnifier matches")
	settings.load(path)
	check(Quality.load_quality(settings) == 2 and Quality.load_sharpness(settings) == 0.4, "Settings persist")
	main._on_setting_changed("sharpness",0.0)
	check(main.video.material.get_shader_parameter("sharpness") == 0.0, "Off restores neutral shader")
	var host := HostProbe.new()
	main.platform_plugin = host
	main.recent_menu._activate(main.recent_menu.RESTART_APP)
	main.recent_menu._activate(main.recent_menu.RESTART_APP)
	check(host.requests == [true], "Restart button calls Android once and saves settings")
	main.platform_plugin = null
	main.queue_free()
	await process_frame
	main = Main.new()
	main.settings_path = path
	root.add_child(main)
	check(main.display.render_scale == 1.25, "Restart applies saved quality globally")
	check(not main._library_settings().display_quality_pending, "Restart clears pending label")
	main.platform_plugin = host
	main.recent_menu._activate(main.recent_menu.QUIT_APP)
	check(host.requests == [true, false], "Close button requests actual application exit")
	main.platform_plugin = null
	main.queue_free()
	await process_frame
	DirAccess.remove_absolute(path)
	for failure in failures: push_error(failure)
	print("Global display quality: ", "passed" if failures.is_empty() else failures)
	quit(0 if failures.is_empty() else 1)
