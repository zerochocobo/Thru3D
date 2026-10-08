extends SceneTree
const Background := preload("res://scripts/app_background.gd")
const Main := preload("res://scripts/main.gd")
const I18n := preload("res://scripts/i18n.gd")
class SupportedDisplay extends XrDisplay:
	func supports_passthrough() -> bool: return true
var checks := 0
var failures: Array[String] = []
var folder := "user://background_test_%d" % Time.get_ticks_usec()
var output := ProjectSettings.globalize_path("res://../../artifacts/background-preview")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)
func field_tap(menu: Node3D, target: int) -> void:
	for button in menu._buttons:
		if button.target == target:
			var origin: Vector3 = button.node.global_position + button.node.global_basis.z
			var direction: Vector3 = -button.node.global_basis.z
			menu.press_pointer("left_hand", origin, direction, true)
			menu.release_pointer("left_hand", origin, direction, true)
			return

func _initialize() -> void: call_deferred("_run")
func settle(background: Node) -> void:
	var deadline := Time.get_ticks_msec()+15000
	while background.loading and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	check(not background.loading, "Background loading completes")
func frame(viewport: SubViewport, name: String) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.save_png(output.path_join(name + ".png"))
	return image

func check_panorama_direction() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(256,256)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	viewport.add_child(world)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	# Distinguish the image centre from its joined edges in the real sky renderer.
	var pixels := Image.create(512,256,false,Image.FORMAT_RGB8)
	pixels.fill(Color.BLUE)
	pixels.fill_rect(Rect2i(0,0,64,256),Color.RED)
	pixels.fill_rect(Rect2i(448,0,64,256),Color.RED)
	pixels.fill_rect(Rect2i(224,0,64,256),Color.GREEN)
	var material := PanoramaSkyMaterial.new()
	material.panorama = ImageTexture.create_from_image(pixels)
	var sky := Sky.new()
	sky.sky_material = material
	var display := XrDisplay.new()
	display.configure(viewport, world.environment, null, true)
	display.set_scenery(sky)
	var front: Image = await frame(viewport,"direction-front")
	check(front.get_pixel(128,128).g > .8 and front.get_pixel(128,128).r < .1, "Global sky 0 degrees faces the panorama centre")
	camera.rotation.y = PI
	var back: Image = await frame(viewport,"direction-back")
	check(back.get_pixel(128,128).r > .8 and back.get_pixel(128,128).g < .1, "Global panorama seam is behind the viewer")
	camera.rotation.y = 0
	display.set_scenery(sky, 180)
	var rotated: Image = await frame(viewport,"direction-rotated")
	check(rotated.get_pixel(128,128).r > .8 and rotated.get_pixel(128,128).g < .1, "User 180-degree rotation still rotates relative to the image centre")
	viewport.queue_free(); await process_frame

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	DirAccess.make_dir_recursive_absolute(output)
	if DisplayServer.get_name() != "headless": await check_panorama_direction()
	var config := ConfigFile.new()
	config.set_value("appearance", "background", "dark")
	config.set_value("ui", "language", "zh")
	config.set_value("alpha", "model", "quality")
	config.save(folder.path_join("settings.cfg"))
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280,800)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var main := Main.new()
	main.settings_path = folder.path_join("settings.cfg")
	viewport.add_child(main)
	check(main.settings.get_value("alpha", "model") == "fast" and main.video.profile == main.video.AUTOMATIC_PROFILE, "Legacy quality model migrates to the unified playback configuration")
	main.photo.history_enabled = false
	main.background.directory = folder.path_join("backgrounds")
	check(main.background.choice == "dark" and main.display.environment.background_mode == Environment.BG_COLOR, "Saved dark background applies at startup")
	main._on_setting_changed("background", "belfast")
	await settle(main.background)
	check(main.display.environment.background_mode == Environment.BG_SKY and not viewport.transparent_bg, "Belfast is opaque application sky")
	check(main.background._builtin.get_size() == Vector2(8192,4096), "Packaged sky retains full 8K dimensions")
	main.recent_menu.section = main.recent_menu.Section.SETTINGS
	main.recent_menu.tab = main.recent_menu.BACKGROUND_TAB
	main.recent_menu.refresh()
	check(main.recent_menu.rows[0].key == "background" and main.recent_menu.rows[0].value == "belfast", "Background selection is shown in one settings field")
	main.recent_menu.stick_scroll(-1,.25)
	check(main.background.choice == "belfast", "Menu stick scroll never changes background selection")
	for target in main.recent_menu.choices.targets:
		var item: Dictionary = main.recent_menu.choices.targets[target]
		if item.kind == "open" and item.key == "background": field_tap(main.recent_menu, target); break
	for target in main.recent_menu.choices.targets:
		var item: Dictionary = main.recent_menu.choices.targets[target]
		if item.kind == "choose" and item.key == "background" and item.value == "dark": field_tap(main.recent_menu, target); break
	check(main.background.choice == "dark", "Same-hand ray/trigger switches background")
	main._on_setting_changed("background", "belfast")
	await settle(main.background)
	config.load(main.settings_path)
	check(config.get_value("appearance","background") == "belfast", "Background choice persists")
	main._on_setting_changed("background_yaw", true)
	main._on_setting_changed("background_brightness", true)
	check(is_equal_approx(main.display.environment.sky_rotation.y, PI + PI/4) and main.background.brightness == 1.25, "Rotation applies relative to panorama centre; brightness still applies")
	main.background.yaw = 0; main.background.brightness = 1; main.background._apply()
	if DisplayServer.get_name() != "headless":
		var shot: Image = await frame(viewport,"settings")
		var sky_color := shot.get_pixel(80,100)
		check(sky_color.r + sky_color.g + sky_color.b > .3, "Panorama renders behind the current settings panel")
		main.recent_menu.dismiss()
		await frame(viewport,"belfast")
	# A private copy survives navigation/deleting the original file and app restart.
	var pixels := Image.create(512,256,false,Image.FORMAT_RGB8)
	pixels.fill(Color(.2,.4,.7))
	var source := ProjectSettings.globalize_path(folder.path_join("source_360_2D.jpg"))
	pixels.save_jpg(source)
	main._on_library_chosen("file://"+source,"source_360_2D.jpg")
	var deadline := Time.get_ticks_msec()+5000
	while main.photo.loading and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	check(main.photo.geometry == 3 and main.photo.can_background(), "Full mono panorama offers use-as-background")
	check(main.display.environment.background_mode == Environment.BG_COLOR, "Immersive media temporarily hides scenery")
	main._on_photo_action("photo_background")
	await settle(main.background)
	check(main.background.choice == "custom" and not main.photo.panel.visible and main.display.environment.background_mode == Environment.BG_SKY, "Using panorama as background closes viewer and restores app sky")
	var saved := str(main.background.custom_path)
	check(FileAccess.file_exists(saved) and saved != source, "Background has independent private copy")
	DirAccess.remove_absolute(source)
	config.load(main.settings_path)
	check(config.get_value("appearance","custom_path") == saved and config.get_value("appearance","background") == "custom", "Custom background selection persists")
	var restored := Background.new()
	restored.directory = main.background.directory
	restored.choice = "custom"
	restored.custom_path = saved
	root.add_child(restored)
	await settle(restored)
	check(restored.ready_sky() != null and restored.error.is_empty(), "Custom background reloads without original file")
	main._on_setting_changed("background","belfast")
	await settle(main.background)
	check(main.background.has_custom(), "Changing preset retains the custom choice")
	main.photo.open_image(saved,"plain.jpg")
	deadline = Time.get_ticks_msec()+5000
	while main.photo.loading and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	check(main.photo.geometry == 0 and main.display.environment.background_mode == Environment.BG_SKY, "Flat photo preserves the application backdrop")
	main.photo.set_stereo_layout(1)
	check(not main.photo.can_background(), "Packed stereo cannot be used as a monoscopic sky")
	main.photo.close_image()
	main._on_setting_changed("background","passthrough")
	check(main.background.choice == "passthrough" and main.display.environment.background_mode == Environment.BG_COLOR and not viewport.transparent_bg, "Unavailable desktop passthrough falls back to opaque dark")
	main._on_setting_changed("background","belfast")
	await settle(main.background)
	check(main.display.environment.background_mode == Environment.BG_SKY, "Leaving passthrough restores selected panorama")
	check(not main.background.select("invalid"), "Unknown saved choice rejected")
	# Simulate only XR capability; exercise the real background policy and renderer.
	# This cannot verify Quest camera composition, which still requires the headset.
	var supported := SupportedDisplay.new()
	supported.configure(viewport, main.display.environment, null, true)
	main.display = supported
	main.photo_active = false
	main.video.local_uri = "smb://test/share/clip.mp4"
	main.video.media.begin(7)
	main.video.geometry = 1
	main.video.alpha_requested = true
	for choice in ["belfast", "custom", "dark", "passthrough"]:
		main.background.select(choice)
		main._update_background()
		check(supported.applied_passthrough and viewport.transparent_bg, "Preparing Alpha uses passthrough with " + choice)
		check(supported.environment.background_mode == Environment.BG_COLOR and supported.environment.background_color.a == 0.0 and supported.environment.sky == null, "Alpha removes opaque environment with " + choice)
		check(main.background.choice == choice, "Alpha preserves saved background " + choice)
	main.video.alpha_requested = false
	main.video.alpha_enabled = true
	main.background.select("belfast")
	main._update_background()
	check(supported.applied_passthrough, "Displayed Alpha remains transparent during mode transition")
	main.video.alpha_enabled = false
	main.video.alpha_requested = true
	main.video.media.state = "ended"
	main._update_background()
	check(not supported.applied_passthrough and supported.environment.background_mode == Environment.BG_SKY, "Natural Alpha EOF restores saved panorama despite retained URI and Alpha preference")
	main.video.loop_enabled = true
	main._update_background()
	check(supported.applied_passthrough, "Looping Alpha does not flash scenery at EOF")
	main.video.loop_enabled = false
	main.video.media.state = "ready"
	main.video.requested_play = false
	main._update_background()
	check(supported.applied_passthrough, "Paused Alpha retains passthrough")
	main.video.requested_play = true
	main.video.close_video()
	check(not main.video.local_uri.is_empty() and main.video.alpha_requested, "Regression reproduces closed video with retained URI and Alpha preference")
	main._update_background()
	check(not supported.applied_passthrough and supported.environment.background_mode == Environment.BG_SKY, "Closing Alpha restores saved panorama")
	main.video.media.begin(8)
	main.video.media.state = "failed"
	main._update_background()
	check(not supported.applied_passthrough and supported.environment.background_mode == Environment.BG_SKY, "Failed Alpha restores saved panorama")
	main.video.media.begin(9)
	main.video.alpha_requested = false
	main.video.geometry = 0
	main._update_background()
	check(not supported.applied_passthrough and supported.environment.background_mode == Environment.BG_SKY, "Leaving Alpha restores selected sky for flat video")
	main.background.select("passthrough")
	for geometry in [0, 1, 2, 3]:
		main.video.geometry = geometry
		main._update_background()
		check(supported.applied_passthrough, "Explicit passthrough works behind video geometry %d" % geometry)
	main.video.local_uri = ""
	main._update_background()
	check(supported.applied_passthrough, "Passthrough stays active after closing video")
	main.photo_active = true
	main.photo.local_uri = "file://photo.jpg"
	for geometry in [0, 1, 2, 3]:
		main.photo.geometry = geometry
		main._update_background()
		check(supported.applied_passthrough, "Explicit passthrough works behind photo geometry %d" % geometry)
	main.photo.local_uri = ""
	main.visible = false
	if DisplayServer.get_name() != "headless":
		var transparent_frame: Image = await frame(viewport, "passthrough-alpha")
		check(transparent_frame.get_pixel(80,100).a == 0.0, "Rendered passthrough background has zero alpha")
	supported._on_session_event("session_begun")
	check(viewport.transparent_bg and supported.environment.background_color.a == 0.0, "Session resume preserves transparent background")
	main.background.select("dark")
	check(not supported.applied_passthrough and not viewport.transparent_bg and supported.environment.background_color.a == 1.0, "Dark is opaque and distinct from passthrough")
	restored.queue_free(); viewport.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Application background: %d checks, %d failures; previews %s" % [checks,failures.size(),output])
	quit(0 if failures.is_empty() else 1)
