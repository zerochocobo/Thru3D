extends Node3D

signal changed

const State := preload("res://scripts/media_state.gd")
const Log := preload("res://scripts/diagnostic_log.gd")
const Geometry := preload("res://scripts/video_geometry.gd")
const PlaybackControl := preload("res://scripts/playback_control.gd")

var media := State.new()
var platform: Object
var panel: MeshInstance3D
var material: ShaderMaterial
var alpha_material: ShaderMaterial
var view_camera: Camera3D
var geometry := Geometry.Geometry.FLAT
var alpha_encoding := 0
var alpha_enabled := false
var alpha_requested := false
var control := PlaybackControl.new()
var loop_enabled := false
var alpha_texture: Texture2D
var _flat_mesh := QuadMesh.new()
var _hemisphere_mesh: ArrayMesh
var _fixture_index := -1
var texture: ExternalTexture
var retained_textures: Dictionary = {}
var local_uri := ""
var display_name := ""
var stereo_sbs := false
var swap_eyes := false
var requested_play := true
var picker_error := ""
var _status_seconds := 0.0
var _recover_pending := false
var _recover_position_ms := 0
var _recover_alpha := false

func _ready() -> void:
	panel = MeshInstance3D.new()
	panel.name = "VideoPanel"
	panel.mesh = _flat_mesh
	panel.position = Vector3(0, 1.5, -2.0)
	panel.visible = false
	add_child(panel)
	if OS.get_name() == "Android" and Engine.has_singleton("QuestPlayer"):
		platform = Engine.get_singleton("QuestPlayer")
		# Load only on Android; samplerExternalOES cannot compile in desktop OpenGL.
		material = ShaderMaterial.new()
		material.shader = load("res://shaders/video_oes.gdshader")
		alpha_material = ShaderMaterial.new()
		alpha_material.shader = load("res://shaders/video_alpha_oes.gdshader")
		alpha_material.render_priority = -10
		panel.material_override = material
		platform.connect("local_video_selected", _on_selected)
		for kind in ["state", "format", "frame", "codec", "error"]:
			platform.connect("media_" + kind, _on_media_event.bind(kind))
		platform.connect("media_released", _on_released)

func pick_file() -> void:
	if platform:
		picker_error = ""
		platform.pick_local_video()
	else:
		picker_error = "Local Android video playback requires Quest"
	changed.emit()

func play_calibration_clip() -> void:
	if not platform:
		picker_error = "Local Android video playback requires Quest"
		changed.emit()
		return
	_fixture_index = (_fixture_index + 1) % 3
	var filename: String = ["c03_sbs_grid", "c04_alpha_f180", "c04_independent_alpha"][_fixture_index]
	var resource_path := "res://media/%s.mp4" % filename
	var source := FileAccess.open(resource_path, FileAccess.READ)
	if not source:
		picker_error = "CALIBRATION_CLIP_MISSING"
		changed.emit()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://fixtures"))
	var source_hash := FileAccess.get_sha256(resource_path)
	var target_path := "user://fixtures/%s_%s.mp4" % [filename, source_hash.left(16)]
	var copy_error := OK
	if not FileAccess.file_exists(target_path) or FileAccess.get_sha256(target_path) != source_hash:
		var target := FileAccess.open(target_path, FileAccess.WRITE)
		if not target:
			picker_error = "CALIBRATION_COPY_FAILED"
			changed.emit()
			return
		# File import only; playback never reads video frames into Godot CPU memory.
		while source.get_position() < source.get_length():
			target.store_buffer(source.get_buffer(65536))
		copy_error = target.get_error()
		target.close()
	source.close()
	if copy_error != OK:
		picker_error = "CALIBRATION_COPY_FAILED"
		changed.emit()
		return
	stereo_sbs = true
	geometry = Geometry.Geometry.FISHEYE if _fixture_index == 1 else Geometry.Geometry.FLAT
	alpha_encoding = [0, 2, 1][_fixture_index]
	alpha_texture = load("res://media/c04_independent_mask.png") if _fixture_index == 2 else null
	_apply_geometry()
	requested_play = true
	open_local("file://" + ProjectSettings.globalize_path(target_path), filename)

func open_local(uri: String, name_value: String, start_ms: int = 0) -> bool:
	if not platform or retained_textures.size() >= 4:
		picker_error = "MEDIA_UNAVAILABLE" if not platform else "MEDIA_RELEASE_PENDING"
		changed.emit()
		return false
	close_video()
	_recover_pending = false
	local_uri = uri
	display_name = name_value
	texture = ExternalTexture.new()
	texture.size = Vector2(256, 256)
	var texture_id := texture.get_external_texture_id()
	var id: int = platform.open_local_video(texture_id, uri, maxi(0, start_ms))
	media.begin(id)
	if id > 0:
		retained_textures[id] = texture
		_set_uniform("video_texture", texture)
		_set_uniform("surface_transform", Projection.IDENTITY)
		platform.set_video_playing(id, requested_play)
	else:
		texture = null
	changed.emit()
	return id > 0

func close_video() -> void:
	var id := media.session_id
	media.close()
	if platform and id > 0:
		platform.close_video(id)
	texture = null
	alpha_enabled = false
	alpha_requested = false
	control.close()
	if material:
		_set_uniform("video_texture", null)
		panel.material_override = material
	if panel:
		panel.visible = false
	changed.emit()

func toggle_play() -> void:
	if platform and media.accepts(media.session_id):
		if media.state == "ended":
			requested_play = true
			seek_absolute(0)
			return
		requested_play = not requested_play
		platform.set_video_playing(media.session_id, requested_play and not control.pending)
		changed.emit()

func seek_absolute(position_ms: int) -> bool:
	if not platform or not media.accepts(media.session_id):
		picker_error = "SEEK_REQUIRES_ACTIVE_MEDIA"
		changed.emit()
		return false
	control.seek_absolute(position_ms)
	_queue_seek()
	return true

func seek_relative(delta_ms: int) -> bool:
	if not platform or not media.accepts(media.session_id):
		picker_error = "SEEK_REQUIRES_ACTIVE_MEDIA"
		changed.emit()
		return false
	control.seek_relative(delta_ms)
	_queue_seek()
	return true

func _queue_seek() -> void:
	# Pause while waiting for bounded resource capacity, including audio.
	platform.set_video_playing(media.session_id, false)
	panel.visible = false
	alpha_enabled = false
	panel.material_override = material
	picker_error = ""
	_try_pending_seek()
	changed.emit()

func _try_pending_seek() -> void:
	if not control.pending or retained_textures.size() >= 4:
		return
	var request := control.take_pending()
	var next_texture := ExternalTexture.new()
	next_texture.size = Vector2(256, 256)
	var id: int = platform.restart_video_at(media.session_id, next_texture.get_external_texture_id(), request.target_ms)
	if id <= 0:
		control.reject()
		picker_error = "MEDIA_SEEK_REJECTED"
		platform.set_video_playing(media.session_id, requested_play)
		return
	media.begin(id)
	texture = next_texture
	retained_textures[id] = texture
	_set_uniform("video_texture", texture)
	_set_uniform("surface_transform", Projection.IDENTITY)
	platform.set_video_playing(id, requested_play)
	Log.record("seek_decoder_replaced", {"decoder_id": id, "request_id": request.request_id, "target_ms": request.target_ms})

func toggle_loop() -> void:
	loop_enabled = not loop_enabled
	changed.emit()

func toggle_stereo() -> void:
	stereo_sbs = not stereo_sbs
	if alpha_enabled and not alpha_ready():
		set_alpha(false)
	_set_uniform("stereo_sbs", stereo_sbs)
	_update_size()
	changed.emit()

func cycle_projection() -> void:
	geometry = (geometry + 1) % 3
	# The explicit F180 compatibility mode is the only mode which reads packed red.
	alpha_encoding = 2 if geometry == Geometry.Geometry.FISHEYE else (1 if alpha_texture else 0)
	if geometry != Geometry.Geometry.FLAT:
		stereo_sbs = true
	set_alpha(false)
	_apply_geometry()
	changed.emit()

func set_alpha(enabled: bool) -> bool:
	if enabled and not alpha_ready():
		picker_error = "ALPHA_NOT_READY: choose a known Alpha fixture or F180 packed file"
		changed.emit()
		return false
	alpha_enabled = enabled
	alpha_requested = enabled
	media.revise_effect()
	if panel and material:
		panel.material_override = alpha_material if enabled else material
	picker_error = ""
	changed.emit()
	return true

func alpha_ready() -> bool:
	return media.accepts(media.session_id) and media.frame_counter > 0 and ( \
		(alpha_encoding == 1 and alpha_texture != null) or \
		(alpha_encoding == 2 and Geometry.legacy_compatible(media.format, stereo_sbs, geometry)))

func _set_uniform(key: String, value: Variant) -> void:
	for target in [material, alpha_material]:
		if target:
			target.set_shader_parameter(key, value)

func _apply_geometry() -> void:
	if not panel:
		return
	if geometry == Geometry.Geometry.FLAT:
		panel.mesh = _flat_mesh
		panel.position = Vector3(0, 1.5, -2.0)
	else:
		if not _hemisphere_mesh:
			_hemisphere_mesh = Geometry.hemisphere()
		panel.mesh = _hemisphere_mesh
		panel.position = Vector3(0, 1.6, 0)
	_set_uniform("video_geometry", geometry)
	_set_uniform("stereo_sbs", stereo_sbs)
	_set_uniform("alpha_encoding", alpha_encoding)
	_set_uniform("alpha_texture", alpha_texture)
	_set_uniform("packed_color", alpha_encoding == 2 and Geometry.legacy_compatible(media.format, stereo_sbs, geometry))
	_update_size()

func layout_snapshot() -> Dictionary:
	return {"geometry": ["flat", "half_equirect_180", "fisheye_180"][geometry], \
		"stereo_sbs": stereo_sbs, "swap_eyes": swap_eyes, "alpha_encoding": alpha_encoding, \
		"alpha_enabled": alpha_enabled, "alpha_ready": alpha_ready(), "lens_fov": 180, \
		"alpha_requested": alpha_requested, "loop_enabled": loop_enabled, "playback_control": control.snapshot(), \
		"selection": "explicit_manual_or_fixture", "device_validation": "pending"}

func _on_selected(payload: String) -> void:
	var result: Variant = JSON.parse_string(payload)
	if not result is Dictionary:
		return
	match result.get("state", ""):
		"selected":
			alpha_texture = null
			alpha_encoding = 2 if geometry == Geometry.Geometry.FISHEYE else 0
			_apply_geometry()
			requested_play = true
			open_local(str(result.get("uri", "")), str(result.get("display_name", "Local video")))
		"error":
			picker_error = str(result.get("error", "PICKER_ERROR"))
			Log.record("local_picker_failed", {"code": picker_error})
	changed.emit()

func _on_media_event(id: int, payload: String, kind: String) -> void:
	if not media.apply_event(kind, id, payload):
		return
	if kind == "state":
		control.observe(int(media.playback.get("position_ms", 0)), int(media.playback.get("duration_ms", -1)))
		if media.state == "ended" and control.in_flight > 0 and media.frame_counter == 0:
			control.reject()
		if media.state == "ended" and media.frame_counter > 0 and loop_enabled and not control.pending and control.in_flight == 0:
			seek_absolute(0)
	elif kind == "format":
		texture.size = Vector2(media.format.width, media.format.height)
		_set_uniform("rotation_degrees", media.format.unapplied_rotation_degrees)
		_set_uniform("source_size", Vector2(media.format.width, media.format.height))
		_set_uniform("packed_size", Vector2(Geometry.packed_dimensions(media.format.width, media.format.height)))
		_set_uniform("packed_color", alpha_encoding == 2 and Geometry.legacy_compatible(media.format, stereo_sbs, geometry))
		if alpha_enabled and not alpha_ready():
			set_alpha(false)
		_update_size()
		_refresh_presentation()
	elif kind == "frame":
		_set_uniform("surface_transform", media.transform)
		_refresh_presentation()
	elif kind == "error":
		_recover_position_ms = control.target_ms if control.pending or control.in_flight > 0 else int(media.playback.get("position_ms", 0))
		_recover_alpha = alpha_requested
		control.reject()
		panel.visible = false
		Log.record("media_failed", {"session_id": id, "code": media.error})
		_recover_pending = media.error in ["GL_CONTEXT_RECREATED", "GL_CONTEXT_CHANGED"]
		# Error and release originate on different threads. Either arrival order is valid.
		if _recover_pending and not retained_textures.has(id):
			call_deferred("_recover_video", id)
	elif kind == "codec":
		Log.record("media_codec", media.snapshot())
	changed.emit()

func _refresh_presentation() -> void:
	panel.visible = int(media.format.width) > 0 and int(media.format.height) > 0 and media.frame_counter > 0 and not control.pending
	if not panel.visible:
		return
	if control.first_frame():
		Log.record("seek_first_presentation_frame", {"request_id": control.sequence, "identity": media.frame_identity()})
	if alpha_requested and not alpha_enabled and alpha_ready():
		set_alpha(true)

func _on_released(id: int, _payload: String) -> void:
	# Native player and SurfaceTexture have released this Godot-owned texture.
	retained_textures.erase(id)
	if control.pending:
		_try_pending_seek()
		changed.emit()
		return
	if id == media.session_id and _recover_pending:
		_recover_video(id)
	elif id == media.session_id:
		texture = null
		_set_uniform("video_texture", null)

func _recover_video(expected_decoder: int) -> void:
	if not _recover_pending or expected_decoder != media.session_id:
		return
	_recover_pending = false
	var restore_alpha := _recover_alpha
	if open_local(local_uri, display_name, _recover_position_ms):
		alpha_requested = restore_alpha

func _update_size() -> void:
	if not panel or geometry != Geometry.Geometry.FLAT:
		return
	var width := float(media.format.width) * float(media.format.pixel_aspect)
	var height := float(media.format.height)
	if height <= 0.0:
		return
	if int(media.format.unapplied_rotation_degrees) in [90, 270]:
		var previous_width := width
		width = height
		height = previous_width
	if stereo_sbs:
		width *= 0.5
	var aspect := width / height
	var panel_width := minf(1.9, aspect)
	panel.mesh.size = Vector2(panel_width, panel_width / aspect)

func _process(delta: float) -> void:
	if panel and geometry != Geometry.Geometry.FLAT and view_camera:
		# Video follows head translation; turning the head still changes the viewed direction.
		panel.global_position = view_camera.global_position
	_status_seconds += delta
	if platform and _status_seconds >= 1.0 and media.accepts(media.session_id):
		_status_seconds = 0.0
		platform.request_video_status(media.session_id)

func _exit_tree() -> void:
	close_video()
