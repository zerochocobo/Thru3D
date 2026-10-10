extends SceneTree
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/player_menu.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func locks(menu: Node3D) -> int:
	var count := 0
	for button in menu._buttons:
		for child in button.node.get_children():
			if child is MeshInstance3D and child.material_override is StandardMaterial3D and child.material_override.albedo_texture == preload("res://scripts/menu_icons.gd").texture("lock"):
				count += 1
	return count

func _run() -> void:
	var main := Main.new()
	main.settings_path = ProjectSettings.globalize_path("res://../../artifacts/vr-alignment-20261010/mode-unlock.cfg")
	DirAccess.make_dir_recursive_absolute(main.settings_path.get_base_dir())
	main.settings.save(main.settings_path)
	root.add_child(main)
	main.set_process(false)
	main.video.set_process(false)
	main.photo.set_process(false)
	for viewer in [main.video, main.photo]:
		var kind := "video" if viewer == main.video else "photo"
		var menu: Node3D = main.player_menu if kind == "video" else main.photo_menu
		viewer.geometry = 1; viewer.stereo_sbs = true; viewer.top_bottom = false; viewer.stereo_half = false
		viewer._apply_geometry()
		viewer.toggle_mode_lock()
		var saved := ConfigFile.new(); saved.load(main.settings_path)
		check(saved.get_value(kind, "mode_lock") == viewer.current_lock(), kind + " lock persisted")
		# Opening/detecting a named file can override a default lock without discarding it.
		viewer.geometry = 2; viewer._apply_geometry()
		check(not viewer.mode_lock.is_empty(), kind + " automatic projection override keeps default lock")
		viewer.geometry = 1; viewer._apply_geometry()
		menu.visible = true; menu._mode_open = true; menu.refresh()
		check(locks(menu) == 2, kind + " both locked tiles visible")
		if kind == "photo": main.photo_active = true
		menu._activate(Menu.MODE_PROJECTION + 3)
		check(viewer.geometry == 3 and viewer.mode_lock.is_empty() and locks(menu) == 0, kind + " other projection removes both locks")
		saved.load(main.settings_path)
		check(saved.get_value(kind, "mode_lock").is_empty(), kind + " projection unlock persisted")
		menu._activate(Menu.MODE_PROJECTION + 3)
		check(not viewer.mode_lock.is_empty(), kind + " selected projection can lock again")
		menu._activate(Menu.MODE_STEREO + 1)
		# 360 video defaults to mono, photos preserve SBS. Ensure an actual different layout next.
		if not viewer.mode_lock.is_empty(): menu._activate(Menu.MODE_STEREO)
		check(viewer.mode_lock.is_empty() and locks(menu) == 0, kind + " layout choice unlocks")
		for layout in ([0, 1, 2, 3, 4] if kind == "video" else [0, 1, 2]):
			viewer.set_stereo_layout(layout)
			viewer.toggle_mode_lock()
			viewer.set_stereo_layout((layout + 1) % (5 if kind == "video" else 3))
			check(viewer.mode_lock.is_empty(), kind + " unlock from layout " + str(layout))
		viewer.set_projection(2); viewer.set_fisheye_fov(180); viewer.toggle_mode_lock()
		viewer.set_fisheye_fov(200)
		check(viewer.mode_lock.is_empty(), kind + " lens selection unlocks")
		viewer.set_projection(0); viewer.set_stereo_layout(0); viewer.depth_requested = true; viewer.toggle_mode_lock()
		viewer.set_depth(false)
		check(viewer.mode_lock.is_empty(), kind + " leaving generated 3D unlocks")
		viewer.toggle_mode_lock()
		var before: Dictionary = viewer.mode_lock.duplicate()
		viewer.set_projection(-1); viewer.set_stereo_layout(-1); viewer.set_fisheye_fov(90)
		check(viewer.mode_lock == before, kind + " rejected choices retain lock")
		viewer.set_stereo_layout(0); viewer.set_fisheye_fov(200)
		check(viewer.mode_lock == before, kind + " unchanged choices retain lock")
		main.photo_active = false
		viewer.toggle_mode_lock()
	main.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Mode unlock: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
