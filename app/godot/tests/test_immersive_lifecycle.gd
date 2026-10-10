extends SceneTree
const Main := preload("res://scripts/main.gd")
const TestHost := preload("res://tests/test_player_menu.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Catalog := preload("res://scripts/recent_files.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func aligned(viewer: Node3D) -> bool:
	return (-viewer.panel.global_basis.z).distance_to(-viewer.view_camera.global_basis.z) < 0.00001

func _run() -> void:
	var main := Main.new()
	var directory := ProjectSettings.globalize_path("res://../../artifacts/vr-alignment-20261010/lifecycle")
	DirAccess.make_dir_recursive_absolute(directory)
	main.settings_path = directory.path_join("settings.cfg"); main.settings.save(main.settings_path)
	root.add_child(main); main.set_process(false); main.video.set_process(false); main.photo.set_process(false)
	main.video.platform = TestHost.Host.new()
	main.video.mode_memory = Memory.new(directory.path_join("modes")); main.video.recent_files = Catalog.new(directory.path_join("recent"))
	var head: Camera3D = main.video.view_camera
	for name in ["first_180_SBS.mp4","next_360_TB.mp4","lens_fisheye200_SBS.mp4"]:
		head.basis = Basis(Vector3.UP,-0.65) * Basis(Vector3.RIGHT,0.13) * Basis(Vector3.FORWARD,0.18)
		check(main.video.open_local("file:///alignment/"+name,name),"Open "+name)
		main.video._apply_geometry()
		check(aligned(main.video),"File open aligns current gaze "+name)
		var orientation: Basis = main.video.panel.global_basis
		head.rotate_y(0.3); main.video._apply_geometry()
		check(main.video.panel.global_basis.is_equal_approx(orientation),"Presented frame keeps orientation "+name)
		main.video.turn_view(0.2,-0.1); main.video.zoom_view(0.3)
		await main._recenter()
		check(aligned(main.video) and main.video.view_yaw == 0 and main.video.view_pitch == 0 and main.video.view_zoom == 0,"Application recenter removes old offsets "+name)
	# Files without naming markers can enter VR only after the first format event.
	main.video.open_local("file:///alignment/unnamed.mp4","unnamed.mp4")
	main.video.media.format = {"width":8192,"height":4096,"pixel_aspect":1.0}
	head.rotation = Vector3(-0.17,0.9,0)
	main.video._complete_layout()
	check(main.video.geometry==1 and aligned(main.video),"First-frame projection detection aligns current gaze")
	# The shared fix also applies to panorama photos and keeps their detail window coherent.
	main.photo_active = true; main.player_menu = main.photo_menu
	main.photo.local_uri = "file:///alignment/panorama.jpg"
	main.photo.set_projection(3)
	check(aligned(main.photo),"Panorama photo enters aligned")
	main.photo.turn_view(-0.4,0.1); head.rotate_y(-0.5)
	await main._recenter()
	check(aligned(main.photo),"Photo recenter aligns current gaze")
	# Mode persistence must survive a new application instance after manual switching.
	main.video.set_projection(1); main.video.toggle_mode_lock(); main.video.set_projection(3)
	main.photo.toggle_mode_lock(); main.photo.set_stereo_layout(1)
	var saved := ConfigFile.new(); saved.load(main.settings_path)
	check(saved.get_value("video","mode_lock").is_empty() and saved.get_value("photo","mode_lock").is_empty(),"Both manual unlocks saved")
	var restored := Main.new(); restored.settings_path = main.settings_path; root.add_child(restored)
	check(restored.video.mode_lock.is_empty() and restored.photo.mode_lock.is_empty(),"Restart keeps both media types unlocked")
	restored.queue_free(); main.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Immersive lifecycle: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
