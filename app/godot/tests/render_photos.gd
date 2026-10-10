extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Menu := preload("res://scripts/photo_menu.gd")
var failures: Array[String] = []
var viewport: SubViewport
var photo: Node3D
var output := ProjectSettings.globalize_path("res://../../artifacts/photo-preview")

class DepthHost extends RefCounted:
	func release_photo(_id: int) -> void: pass
	func cancel_photo(_id: int) -> void: pass
	func prepare_photo_depth(_id: int) -> bool: return true

func _initialize() -> void: call_deferred("_run")
func frame() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func centre_color(expected: Color, label: String) -> void:
	var image: Image = await frame()
	var color := image.get_pixel(640, 400)
	if Vector3(color.r, color.g, color.b).distance_to(Vector3(expected.r, expected.g, expected.b)) > .12:
		failures.append(label + ": " + str(color))

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	viewport = SubViewport.new()
	viewport.size = Vector2i(1280,800)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.position = Vector3(0,1.6,0)
	viewport.add_child(camera)
	photo = Photo.new()
	photo.history_enabled = false
	viewport.add_child(photo)
	photo.view_camera = camera
	photo.flat_pose = Transform3D(Basis(), Vector3(0,1.6,-1.4))
	var colors := Image.create(512,256,false,Image.FORMAT_RGB8)
	colors.fill(Color.RED)
	colors.fill_rect(Rect2i(256,0,256,256),Color.GREEN)
	photo._texture = ImageTexture.create_from_image(colors)
	photo._size = Vector2(512,256)
	photo.material.set_shader_parameter("photo_texture",photo._texture)
	photo._detail_material.set_shader_parameter("photo_texture",photo._texture)
	photo._apply_geometry(); photo.panel.visible = true
	photo.set_stereo_layout(1)
	for eye in 2:
		photo.material.set_shader_parameter("test_eye",eye)
		await centre_color(Color.RED if eye == 0 else Color.GREEN,"SBS eye %d" % eye)
	photo.toggle_eye_order()
	await centre_color(Color.RED,"SBS swapped right eye")
	colors.fill(Color.BLUE)
	colors.fill_rect(Rect2i(0,128,512,128),Color.YELLOW)
	photo._texture.update(colors)
	photo.swap_eyes = false; photo.set_stereo_layout(2)
	for eye in 2:
		photo.material.set_shader_parameter("test_eye",eye)
		await centre_color(Color.BLUE if eye == 0 else Color.YELLOW,"TB eye %d" % eye)
	# A right-stick zoom must grow the rendered boundary and content by the same ratio.
	# Use a smaller straight screen so both complete boundaries fit the pixel oracle.
	photo.set_screen_curve(0.0); photo.set_screen_scale(0.5)
	photo.set_stereo_layout(0)
	colors.fill(Color.BLUE); colors.fill_rect(Rect2i(240,80,32,96), Color.WHITE)
	photo._texture.update(colors)
	photo.set_corner_hover(1)
	var frame_widths: Array[int] = []
	var content_widths: Array[int] = []
	for step in ["zoom-before", "zoom-after"]:
		if step == "zoom-after": photo.zoom_picture(log(1.35) / 2.0)
		var rendered: Image = await frame()
		rendered.save_png(output.path_join(step + ".png"))
		var border_width := 0; var content_width := 0
		for x in 1280:
			var pixel := rendered.get_pixel(x,400)
			if pixel.b > .8: border_width += 1
			if minf(pixel.r, minf(pixel.g, pixel.b)) > .8: content_width += 1
		frame_widths.append(border_width); content_widths.append(content_width)
	if frame_widths[0] < 100 or absf(float(frame_widths[1]) / frame_widths[0] - 1.35) > .04 \
		or content_widths[0] < 10 or absf(float(content_widths[1]) / content_widths[0] - 1.35) > .06:
		failures.append("Photo boundary and content must scale together: %s / %s" % [frame_widths, content_widths])
	print("Photo zoom rendered boundary/content widths: %s / %s" % [frame_widths, content_widths])
	photo.set_screen_scale(0.5); photo.set_corner_hover(-1)
	# Constant near depth displaces the same square in opposite directions per eye.
	photo.set_stereo_layout(0)
	colors.fill(Color.BLACK); colors.fill_rect(Rect2i(240,80,32,96),Color.WHITE)
	photo._texture.update(colors)
	var near := Image.create(252,140,false,Image.FORMAT_RF)
	near.fill(Color(1,0,0))
	photo._depth_texture = ImageTexture.create_from_image(near)
	photo.platform = DepthHost.new(); photo._display_request = 1
	photo.set_depth(true)
	var centres: Array[float] = []
	var disparities: Array[float] = []
	for strength in [0.0, 0.5, 1.0, 2.0, 4.0]:
		photo.set_depth_strength(strength)
		centres.clear()
		for eye in 2:
			photo.material.set_shader_parameter("test_eye",eye)
			var result: Image = await frame()
			var sum := 0.0; var count := 0
			for x in 1280:
				if result.get_pixel(x,400).r > .8: sum += x; count += 1
			centres.append(sum / maxi(1,count))
		disparities.append(centres[0] - centres[1])
	if absf(disparities[0]) > 1: failures.append("Off must eliminate eye disparity")
	# Photos are capped at 100%; both 200% and 400% inputs preserve that output.
	for i in range(1, 3):
		if disparities[i] <= maxf(2, disparities[i-1] * 1.5): failures.append("Strength must visibly increase eye disparity: " + str(disparities))
	for i in [3,4]:
		if absf(disparities[i] - disparities[2]) > 1: failures.append("Above-maximum strength must preserve the 100% output")
	print("Photo rendered disparity at 0/50/100% and clamped 200/400% inputs: " + str(disparities))
	photo.set_depth(false); photo.platform = null
	# Exercise full-size downloaded JPG in the real shader, with the current app UI.
	var fixture := OS.get_environment("QUEST_PHOTO_FIXTURE")
	if fixture.is_empty(): fixture = ProjectSettings.globalize_path("res://../../artifacts/test-media/panoramas/sunset_forest.jpg")
	if not FileAccess.file_exists(fixture):
		viewport.queue_free(); await process_frame
		for failure in failures: push_error(failure)
		print("Photo render: %s; 8K fixture preview skipped (local fixture absent)" % ("passed" if failures.is_empty() else "failed"))
		quit(0 if failures.is_empty() else 1)
		return
	photo.open_image("file://"+fixture, "Sunset forest · 360_2D.jpg")
	var deadline := Time.get_ticks_msec()+15000
	while photo.loading and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
	if not photo.error.is_empty() or photo.loading: failures.append("8K fixture did not load: " + photo.error)
	photo.material.set_shader_parameter("test_eye",0)
	photo.set_projection(3)
	var menu := Menu.new()
	menu.state_provider = photo.snapshot
	menu.queue_provider = func(): return photo.queue
	viewport.add_child(menu)
	menu.position = Vector3(0,1.12,-1.4)
	menu.rotation.x = -.28
	menu.toggle()
	(await frame()).save_png(output.path_join("panorama.png"))
	photo.toggle_mode_lock(); menu.refresh(); menu._activate(menu.MODE)
	(await frame()).save_png(output.path_join("panorama-mode-locked.png"))
	menu._activate(menu.MODE); photo.toggle_mode_lock()
	photo.toggle_inspect(); photo.zoom_view(.3)
	photo.inspect_ray(camera.global_position,Vector3(.4,.05,-1).normalized())
	menu.refresh()
	(await frame()).save_png(output.path_join("panorama-detail.png"))
	photo.set_projection(0); photo.set_screen_curve(0.35); menu.refresh()
	(await frame()).save_png(output.path_join("flat.png"))
	# Actual menu render of the shared strength popup over the flat fixture.
	photo.platform = DepthHost.new()
	photo.depth_requested = true; photo.depth_strength = 1.0
	menu.refresh(); menu._activate(menu.PHOTO_DEPTH)
	(await frame()).save_png(output.path_join("depth-slider.png"))
	menu._activate(menu.PHOTO_DEPTH)
	photo.depth_requested = false; photo.platform = null
	photo.toggle_inspect(); photo.pan_content(Vector2(.4,0)); menu.refresh()
	(await frame()).save_png(output.path_join("flat-detail.png"))
	var inspect_origin := camera.global_position + Vector3(0.15,-0.18,-0.3)
	var target_u := 0.3
	var inspect_radius: float = photo._curve_radius()
	var inspect_x: float = (target_u - 0.5) * photo._flat.size.x
	var inspect_target: Vector3 = photo.panel.to_global(Vector3(sin(inspect_x / inspect_radius) * inspect_radius, 0, (1.0 - cos(inspect_x / inspect_radius)) * inspect_radius))
	photo.update_inspect_pointer(inspect_origin, (inspect_target - inspect_origin).normalized())
	menu.dismiss()
	(await frame()).save_png(output.path_join("flat-inspect-ray.png"))
	photo.hide_inspect_pointer(); menu.toggle()
	menu._activate(menu.MODE)
	(await frame()).save_png(output.path_join("projection-menu.png"))
	viewport.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Photo render: %s; SBS/TB/swap, depth centres %s, 8K JPG previews %s" % ["passed" if failures.is_empty() else "failed",centres,output])
	quit(0 if failures.is_empty() else 1)
