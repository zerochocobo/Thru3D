extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
var failures: Array[String] = []

class Host extends RefCounted:
	var sequence := 0
	var track := 9
	var cue_text := "中文字幕 😀\nSecond line"
	func get_mpv_subtitles(_id: int, after: int) -> String:
		sequence = maxi(sequence, after) + 1
		return JSON.stringify({"session_id": 7, "sequence": sequence, "generation": 3, "source_epoch": 2,
			"mpv_source_handle": 55, "command_id": 1, "required_command_id": 1, "track_id": str(track),
			"timeline_valid": true, "age_ms": 0, "start_seconds": "1", "end_seconds": "3",
			"position_seconds": "2", "text": cue_text})
	func set_mpv_subtitle(_id: int, value: int) -> bool:
		track = value
		return true
	func close_mpv_video(_id: int) -> void:
		pass

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("QUEST_SUBTITLE_PREVIEW_DIR")
	if output.is_empty():
		push_error("Preview output directory required")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(640, 360)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.position = Vector3(0, 1.6, 0)
	viewport.add_child(camera)
	var video := Video.new()
	viewport.add_child(video)
	video.view_camera = camera
	video.set_process(false)
	video.platform = Host.new()
	video.media.begin(7)
	video.media.last_pair = {"session_id": 7, "generation": 3, "source_epoch": 2, "mpv_source_handle": 55}
	video.subtitles.select(9)
	video._flat.size = Vector2(1.9, 1)
	video.panel.visible = true
	var color := Image.create(2, 2, false, Image.FORMAT_RGB8)
	color.fill(Color(0.1, 0.4, 0.7))
	var alpha := Image.create(2, 2, false, Image.FORMAT_R8)
	alpha.fill(Color.BLACK)
	video.material.set_shader_parameter("color_texture", ImageTexture.create_from_image(color))
	video.material.set_shader_parameter("alpha_texture", ImageTexture.create_from_image(alpha))
	video.material.set_shader_parameter("source_size", Vector2(2, 2))
	video.material.set_shader_parameter("model_size", Vector2(2, 2))
	video.material.set_shader_parameter("stereo_sbs", false)
	var images: Array[Image] = []
	for mode in ["normal", "alpha_zero", "off"]:
		video.material.set_shader_parameter("alpha_enabled", mode != "normal")
		if mode == "off":
			video.set_subtitle_track(0)
		video._subtitle_poll_ms = 0
		video._poll_subtitles()
		await process_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		images.append(image)
		if image.save_png(output.path_join(mode + ".png")) != OK:
			failures.append("Cannot save " + mode)
		if video.caption.visible != (mode != "off"):
			failures.append("Caption visibility differs in " + mode)
	var visible_pixels := [0, 0, 0]
	for i in images.size():
		for y in range(200, 350):
			for x in range(100, 540):
				var p := images[i].get_pixel(x, y)
				if minf(p.r, minf(p.g, p.b)) > 0.8:
					visible_pixels[i] += 1
	if visible_pixels[0] < 100 or visible_pixels[1] < 100 or visible_pixels[2] != 0:
		failures.append("Caption pixels must survive zero video Alpha and disappear when off: " + str(visible_pixels))
	# Flat subtitles share the screen's depth; VR preferences must not move them.
	var anchor := video.panel.global_transform * Vector3(0, -video._flat.size.y * 0.5 + 0.06, 0.01)
	for distance in [0.5, 1.0, 2.0, 5.0, 10.0, 20.0]:
		video.subtitle_distance = distance
		video._place_caption()
		if video.caption.global_position.distance_to(anchor) > 0.001 or not is_equal_approx(video.caption.pixel_size, 0.0016):
			failures.append("Flat caption incorrectly follows immersive distance")
		if camera.unproject_position(anchor).distance_to(camera.unproject_position(video.caption.global_position)) > 0.5:
			failures.append("Flat caption angular anchor moved")
	video.subtitle_distance = 2.0
	if video.subtitle_distance != 2.0: failures.append("Near subtitle distance was unexpectedly clamped")
	# Immersive: at the chosen distance below the line of sight, the same angular size.
	video.set_subtitle_track(9)
	video.geometry = video.Geometry.Geometry.HALF_EQUIRECT
	video._apply_geometry()
	for distance in [0.5, 1.0, 2.0, 5.0, 10.0, 20.0]:
		video.subtitle_distance = distance
		video._subtitle_poll_ms = 0
		video._poll_subtitles()
		var offset: Vector3 = video.caption.global_position - camera.global_position
		if not video.caption.visible or absf(offset.length() - distance) > 0.01 or offset.y > -0.2 * distance \
			or not is_equal_approx(video.caption.pixel_size, 0.001 * distance):
			failures.append("VR caption at %s m: %s" % [distance, offset])
	for geometry in [1, 2, 3]:
		video.geometry = geometry
		for position in 5:
			video.subtitle_position = position
			video._place_caption()
			var offset: Vector3 = video.caption.global_position - camera.global_position
			if absf(offset.length() - video.subtitle_distance) > 0.01 or absf(offset.y / offset.length() - sin(video.SubtitleDepth.elevation(position))) > 0.001:
				failures.append("Immersive subtitle position mismatch")
	video.subtitle_position = video.SubtitleDepth.DEFAULT_POSITION
	var report := {"state": "passed" if failures.is_empty() else "failed", "caption_white_pixels": visible_pixels,
		"scope": "Desktop flat caption pixels, CC Off, immersive layout anchors with mock cue; projected glyph rendering is checked separately; native MPV/Quest timing not exercised",
		"failures": failures}
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	viewport.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	print("MPV subtitle desktop rendering: ", report.state)
	quit(0 if failures.is_empty() else 1)
