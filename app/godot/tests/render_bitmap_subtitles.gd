extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
var failures: Array[String] = []

class Host extends RefCounted:
	var sequence := 0
	var track := 5
	var gap := false
	var reads := 0
	var pixels := PackedByteArray()
	func get_mpv_subtitles(_id: int, after: int) -> String:
		sequence = maxi(sequence, after) + 1
		return JSON.stringify({"session_id": 7, "sequence": sequence, "generation": 3, "source_epoch": 2,
			"mpv_source_handle": 55, "command_id": 1, "required_command_id": 1, "track_id": str(track),
			"timeline_valid": true, "age_ms": 0, "position_seconds": "2", "text": "",
			"bitmap": {"visible": track == 5 and not gap, "version": 1, "x": 256, "y": 800,
				"width": 1280, "height": 160, "canvas_width": 1920, "canvas_height": 1080}})
	func get_mpv_subtitle_bitmap(_id: int, _version: int) -> PackedByteArray:
		reads += 1
		return pixels
	func set_mpv_subtitle(_id: int, value: int) -> bool:
		track = value
		return true
	func close_mpv_video(_id: int) -> void:
		pass

func _initialize() -> void:
	call_deferred("_run")

func white_pixels(image: Image) -> int:
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var p := image.get_pixel(x, y)
			if minf(p.r, minf(p.g, p.b)) > 0.85:
				count += 1
	return count

func _run() -> void:
	var output := OS.get_environment("QUEST_SUBTITLE_PREVIEW_DIR")
	if output.is_empty():
		push_error("PGS pixel output directory required")
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
	var host := Host.new()
	var patch := Image.create(1280, 160, false, Image.FORMAT_RGBA8)
	patch.fill(Color.TRANSPARENT)
	patch.fill_rect(Rect2i(20, 20, 1240, 120), Color.WHITE)
	host.pixels = patch.get_data()
	video.platform = host
	video.media.begin(7)
	video.media.playback = {"details": {"pgs_supported": true, "subtitle_tracks": [
		{"id": 5, "codec": "hdmv_pgs_subtitle", "title": "简体中文"}, {"id": 9, "codec": "subrip"}]}}
	video.media.last_pair = {"session_id": 7, "generation": 3, "source_epoch": 2, "mpv_source_handle": 55}
	video.subtitles.select(5)
	video.media.format = {"width": 1920, "height": 1080}
	video._apply_geometry()
	video.panel.visible = true
	var color := Image.create(2, 2, false, Image.FORMAT_RGB8)
	color.fill(Color(0.1, 0.4, 0.7))
	var alpha := Image.create(2, 2, false, Image.FORMAT_R8)
	alpha.fill(Color.BLACK)
	video.material.set_shader_parameter("color_texture", ImageTexture.create_from_image(color))
	video.material.set_shader_parameter("alpha_texture", ImageTexture.create_from_image(alpha))
	video.material.set_shader_parameter("source_size", Vector2(1920, 1080))
	video.material.set_shader_parameter("model_size", Vector2(2, 2))
	video.material.set_shader_parameter("stereo_sbs", false)
	var counts := {}
	var masks := {}
	for mode in ["normal", "unchanged", "rotation90", "rotation-90", "restored", "alpha_zero", "gap", "vr", "off"]:
		video.material.set_shader_parameter("alpha_enabled", mode == "alpha_zero")
		if mode == "rotation90": video.set_screen_rotation(90)
		if mode == "rotation-90": video.set_screen_rotation(-90)
		if mode == "restored": video.set_screen_rotation(0)
		if mode == "gap": host.gap = true
		if mode == "vr":
			host.gap = false
			video.geometry = 1
			video._apply_geometry()
			if host.track != 0 or video.subtitle_tracks().size() != 1:
				failures.append("Entering VR must deselect and hide PGS while retaining text")
		if mode == "off":
			video.geometry = 0
			video._apply_geometry()
			video.set_subtitle_track(0)
		video._subtitle_poll_ms = 0
		video._poll_subtitles()
		await process_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		counts[mode] = white_pixels(image)
		var mask := PackedInt32Array()
		for y in image.get_height():
			for x in image.get_width():
				var pixel := image.get_pixel(x, y)
				if minf(pixel.r, minf(pixel.g, pixel.b)) > 0.85: mask.append(y * image.get_width() + x)
		masks[mode] = mask
		image.save_png(output.path_join("pgs_" + mode + ".png"))
		if mode in ["normal", "unchanged", "rotation90", "rotation-90", "restored", "alpha_zero"] and counts[mode] < 100:
			failures.append("PGS must render above the video including transparent Alpha: " + mode)
		if mode in ["gap", "vr", "off"] and counts[mode] != 0:
			failures.append("PGS must disappear immediately: " + mode)
		if video.caption.visible:
			failures.append("PGS must never produce a duplicate text label")
		var state: Dictionary = video.layout_snapshot().subtitles
		if bool(state.bitmap_ready) != (mode in ["normal", "unchanged", "rotation90", "rotation-90", "restored", "alpha_zero"]):
			failures.append("PGS diagnostics must reflect the actual uploaded texture: " + mode)
		if state.bitmap_ready and (state.bitmap_texture_size != [1280, 160] or state.render_layer != "flat_PGS_bitmap_overlay"):
			failures.append("PGS texture dimensions/render layer must be reported correctly")
		if mode == "alpha_zero" and host.reads != 1:
			failures.append("Unchanged/paused PGS crop must upload only once")
	# Transparent video gives a background-independent reference for the same PGS silhouette.
	for mode in ["rotation90", "rotation-90"]:
		if masks[mode] != masks.alpha_zero:
			failures.append("PGS silhouette must retain its position and orientation: " + mode)
	var report := {"state": "passed" if failures.is_empty() else "failed", "white_pixels": counts,
		"pixel_fetches": host.reads, "failures": failures,
		"scope": "Production Godot shader and PGS state/pixel bridge with mock RGBA, desktop OpenGL; native decoder tested separately"}
	FileAccess.open(output.path_join("pgs-render-verification.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	viewport.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("PGS bitmap rendering: ", report.state)
	quit(0 if failures.is_empty() else 1)
