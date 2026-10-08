extends "res://scripts/media_surface.gd"

signal changed
signal thumbnail_ready(uri: String)

const State := preload("res://scripts/mpv_media_state.gd")
const Thumbnails := preload("res://scripts/thumbnail_cache.gd")
const Binding := preload("res://scripts/pair_texture_binding.gd")
const PlaybackControl := preload("res://scripts/playback_control.gd")
const SeekPolicy := preload("res://scripts/seek_policy.gd")
var seek_mode := SeekPolicy.SPEED
var bookmark_seek_mode := SeekPolicy.GLOBAL
var _last_seek_mode := SeekPolicy.SPEED
const Log := preload("res://scripts/diagnostic_log.gd")
const PixelProbe := preload("res://scripts/mpv_pixel_probe.gd")
const SubtitleState := preload("res://scripts/mpv_subtitle_state.gd")
const ModeMemory := preload("res://scripts/file_mode_memory.gd")
const RecentFiles := preload("res://scripts/recent_files.gd")
const BookmarkStore := preload("res://scripts/bookmark_store.gd")
var bookmark_store := BookmarkStore.new()
var _bookmark_metadata: Dictionary = {}
var _bookmark_media_id := ""
var _bookmark_scope_sequence := 0
var _bookmark_cache_revision := -1
var _bookmark_rows: Array = []
var bookmark_last_added: Dictionary = {}
const Naming := preload("res://scripts/media_naming.gd")
const AUTOMATIC_PROFILE := "320x320"
const PROFILES := ["320x320", "384x216", "512x288", "384x384", "512x512", "256x144", "256x256"]

var media := State.new()
var control := PlaybackControl.new()
var platform: Object
var alpha_encoding := 1
var alpha_enabled := false
var alpha_requested := false
## Realtime 2D->3D: a depth model drives per-eye parallax on mono sources (never with Alpha or SBS).
var depth_requested := false
var auto_depth := false # Global user choice, independent of remembered per-file projection.
var depth_enabled := false
const DEPTH_STRENGTHS := [0.5, 1.0, 1.5, 2.0]
const DepthStrength := preload("res://scripts/depth_strength.gd")
## Eye-width fraction of the full parallax at strength 1 (PTMediaServer), and the near value kept on
## the screen plane (nearer content comes out of the screen).
const DEPTH_SHIFT := 0.035
const DEPTH_CONVERGENCE := 0.35
var _depth_view_sent := ""
var depth_strength := 1.0
## Pick the clone-voice track (an extra M4A beside the video) whenever a video has one.
var prefer_clone_voice := false
## The file is an alpha-packed fisheye output (its name says so): the mask is in the frame and
## the Alpha switch shows it instead of running RVM.
var packed_file := false
var packed_alpha := false
## What the file name left open; filled from the first frame's shape, then cleared.
var _layout_pending: Variant = null
var _rvm_alpha := false # the bound pair carries an inferred Alpha
var _clone_applied := false
## Locked mode for files that are neither remembered nor named for VR: {geometry, layout (0 mono,
## 1 side by side, 2 top-bottom), depth, fisheye_fov}; empty when unlocked.
var mode_lock := {}
var loop_enabled := false
var requested_play := true
var audio_track_id := -1
var audio_volume := 100.0
var audio_muted := false
var subtitles := SubtitleState.new()
## Text subtitles: on the flat screen near its lower edge; in immersive modes floating at
## [subtitle_distance] below the line of sight, following the head lazily.
var caption: Label3D
const ColorGrade := preload("res://scripts/color_grade.gd")
var color_grade := ColorGrade.new()
const SubtitleDepth := preload("res://scripts/subtitle_depth.gd")
var subtitle_distance := 5.0:
	set(value):
		subtitle_distance = SubtitleDepth.distance(value)
var subtitle_position := SubtitleDepth.DEFAULT_POSITION:
	set(value):
		subtitle_position = SubtitleDepth.position(value)
const ProjectedSubtitles := preload("res://scripts/projected_subtitles.gd")
var projected_subtitles: Node
const CAPTION_DROP := 0.244 # radians below the line of sight (14 degrees)
const CAPTION_SLACK := 0.314 # radians (18 degrees) the head turns before the subtitles follow
var _caption_direction := Vector3.ZERO
var _caption_following := false
var _caption_ms := 0
var _subtitle_poll_ms := 0
var _subtitle_received_ms := 0
var mode_memory := ModeMemory.new()
var _remember_file := false
var recent_files := RecentFiles.new()
## Settings: when off, nothing new is recorded and videos start from the beginning.
var history_enabled := true
var _history_started := false
var _file_permission_persisted := false
var _history_save_ms := 0
var _access_request := 0
var _access_pending: Dictionary = {}
var _audio_pending := false
var local_uri := ""
var display_name := ""
var picker_error := ""
var _picker_request := 0
var profile := AUTOMATIC_PROFILE # ROI default: one square input for full-eye and zoom windows
var _binding := Binding.new()
var _pending_pair: Dictionary = {}
var _pending_revision: Dictionary = {}
var _fixture := -1
var _recover := false
var _recover_ms := 0
var _waiting_first := false
var _thumbnail_busy := false
var _thumbnail_sequence := 0
var _thumbnail_result: Dictionary = {}
var _library_cover := ""
var _freeze_sequence := 0
var _freeze_request := 0
var _seek_trace: Array[Dictionary] = []
var _open_trace: Array[Dictionary] = []
var _debug_seek_delay_until_ms := 0
var _debug_request := 0
var _debug_commands: Array = []
var _debug_pairs: Array = []
var _debug_status: Dictionary = {}
var _debug_pixels: Dictionary = {}
var _debug_benchmark := false
var _debug_next_report_us := 0
var _pixel_request := 0
var _pixel_request_key := ""
var _pixel_busy := false

func _ready() -> void:
	mode_memory.load_saved()
	recent_files.load_saved()
	initialize_surface(load("res://shaders/video_rvm_pair.gdshader"))
	color_grade.apply(material)
	caption = Label3D.new()
	caption.name = "Subtitles"
	caption.font_size = 40
	caption.pixel_size = 0.0015
	caption.outline_size = 8
	caption.no_depth_test = true
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	caption.width = 700
	caption.visible = false
	add_child(caption)
	projected_subtitles = ProjectedSubtitles.new()
	add_child(projected_subtitles)
	if OS.get_name() == "Android" and Engine.has_singleton("QuestPlayer"):
		platform = Engine.get_singleton("QuestPlayer")
		platform.connect("local_video_selected", _on_selected)
		platform.connect("local_video_access", _on_local_access)
		platform.connect("mpv_pair_available", _on_pair)
		platform.connect("mpv_state", _on_state)
		platform.connect("mpv_error", _on_error)
		platform.connect("mpv_detach", _on_detach)
		platform.connect("mpv_released", _on_released)
		platform.connect("mpv_debug_command", _on_debug_command)
		platform.connect("mpv_pixel_mask", _on_pixel_mask)
		platform.connect("mpv_frozen_pair", _on_frozen_pair)
		if platform.has_signal("rvm_warmup"):
			platform.connect("rvm_warmup", _on_rvm_warmup)
	# First photo use should not queue behind unrelated video-model cold compilation.
	_apply_geometry()

# First use of an Alpha profile compiles/tunes GPU kernels; start it before playback.
var rvm_warmup := {}
func _warm_rvm() -> void:
	if local_uri.is_empty(): return
	# JNISingleton.has_method() does not see Java plugin methods; test doubles never set this singleton.
	if OS.get_name() == "Android" and Engine.has_singleton("QuestPlayer"):
		Engine.get_singleton("QuestPlayer").warm_rvm(profile)

## The RVM model changed: warm it and reopen an Alpha session so it takes effect now.
## First usable displayed source frame, for every stable library URI. No second video decoder.
var _thumb_after_ms := -1          # media position to try; -1: already cached/not wanted
var _thumb_tries := 0

static func _thumbnail_source(uri: String) -> bool:
	return not ModeMemory.key_for(uri).is_empty()

func _maybe_capture_thumbnail() -> void:
	if _thumb_after_ms < 0 or _thumbnail_busy or _pixel_busy or _waiting_first or not _pending_revision.is_empty() \
		or media.state not in ["playing", "paused", "ended"] or not _binding.material or media.last_pair.is_empty():
		return
	if int(media.last_pair.get("pts_us", 0)) / 1000 < _thumb_after_ms:
		return
	var uri := local_uri
	var sequence := _thumbnail_sequence
	var pair := media.last_pair.duplicate(true)
	if not platform.pin_mpv_pair(int(pair.session_id), int(pair.slot_token)): return
	_thumbnail_busy = true
	_thumb_after_ms = -1
	# Own wrappers/ExternalTexture, so a close cannot detach/rebind our readback source.
	var binding := Binding.new()
	var target := ShaderMaterial.new()
	if not binding.bind(target, pair):
		platform.release_mpv_pair_pin(int(pair.session_id), int(pair.slot_token))
		_thumbnail_busy = false
		return
	var stereo := bool(pair.get("stereo_sbs", false)) or binding.warped
	var tb := stereo and bool(pair.get("top_bottom", false))
	var eye := Vector2(float(pair.width) * (2.0 if binding.warped else 1.0) * (0.5 if stereo and not tb else 1.0), float(pair.height) * (0.5 if tb else 1.0))
	var scale: Array = pair.get("color_uv_scale", [1.0, 1.0])
	var image: Image = await Thumbnails.capture(self, binding.color_texture(), str(binding.ticket.get("color_target", "")) == "external",
		stereo, Thumbnails.crop_for(geometry, eye), Vector2(float(scale[0]), float(scale[1])), tb)
	binding.unbind()
	platform.release_mpv_pair_pin(int(pair.session_id), int(pair.slot_token))
	_thumbnail_busy = false
	if sequence != _thumbnail_sequence or uri != local_uri: return
	if not image or image.is_empty():
		_thumbnail_result = {"state": "capture_failed"}
		_thumb_after_ms = int(pair.pts_us) / 1000 + 2000
		return
	# A fade or a black opening says nothing about the video: try again a little later.
	var small := image.duplicate() as Image
	small.resize(16, 9, Image.INTERPOLATE_BILINEAR)
	var light := 0.0
	for y in 9:
		for x in 16:
			light += small.get_pixel(x, y).get_luminance()
	_thumb_tries += 1
	if light / 144.0 < 0.06 and _thumb_tries < 3:
		_thumb_after_ms = int(pair.pts_us) / 1000 + 2000
		return
	var stored := Thumbnails.store(uri, image)
	_thumbnail_result = {"state": "stored" if stored else "store_failed", "pts_us": int(pair.pts_us),
		"width": image.get_width(), "height": image.get_height(), "source_epoch": int(pair.source_epoch)}
	if stored: thumbnail_ready.emit(uri)
	_write_debug_report()

## Profiles compiling right now (any model), from the warmup reports.
var warming := {}

## Alpha on [value] starts at once; a cold profile first compiles for ~40 s per model.
func profile_ready(value: String) -> bool:
	if OS.get_name() == "Android" and Engine.has_singleton("QuestPlayer"):
		return bool(Engine.get_singleton("QuestPlayer").rvm_profile_ready(value))
	return true

func reload_rvm() -> void:
	_warm_rvm()
	if alpha_requested:
		_request_revision()

func _on_rvm_warmup(payload: String) -> void:
	var result: Variant = JSON.parse_string(payload)
	if result is Dictionary:
		rvm_warmup = result
		if str(result.get("state", "")) == "warming":
			warming[str(result.get("profile_key", ""))] = true
		else:
			warming.erase(str(result.get("profile_key", "")))
		DiagnosticLog.record("rvm_warmup", result)
		changed.emit()

func pick_file() -> void:
	cancel_pending_open()
	picker_error = ""
	if platform:
		_picker_request = platform.pick_local_video()
		if _picker_request <= 0:
			picker_error = "File picker unavailable"
	else:
		picker_error = "Quest local playback required"
	changed.emit()

func _on_selected(payload: String) -> void:
	var result: Variant = JSON.parse_string(payload)
	if not result is Dictionary or _picker_request <= 0 or result.get("picker_request", -1) != _picker_request:
		return
	if result.get("state") == "selected":
		_picker_request = 0
		requested_play = true
		var uri := str(result.uri)
		if open_local(uri, str(result.get("display_name", "Local video")), _resume(uri), true, false, "", {"basename": result.get("display_name", "")}):
			_file_permission_persisted = bool(result.get("persisted_permission", false))
	elif result.get("state") == "error":
		_picker_request = 0
		picker_error = str(result.get("error", "Local file unavailable"))
	elif result.get("state") == "cancelled":
		_picker_request = 0
		picker_error = ""
	elif result.get("state") == "checking":
		picker_error = "Checking file access..."
	changed.emit()

func cancel_pending_open() -> void:
	var picker := _picker_request
	_picker_request = 0
	if picker > 0 and platform:
		platform.cancel_local_video_pick(picker)
	var previous := _access_request
	_access_request = 0
	_access_pending = {}
	if previous > 0 and platform:
		platform.cancel_local_video_access(previous)

# Library selection: MediaStore content URIs are readable through the media permission;
# network URIs (smb://, DLNA http) have no document grant to check.
func open_library(uri: String, title: String, metadata: Dictionary = {}) -> bool:
	var cover := str(metadata.get("cover", recent_files.lookup(uri).get("cover", "")))
	var opened := false
	if uri.begins_with("medialib://") and not metadata.is_empty():
		requested_play = true
		var start: int = int(metadata.get("start_ms", -1))
		opened = open_local(uri, title, _resume(uri) if start < 0 else start, true, false, str(metadata.get("basename", "")), metadata)
	elif not recent_files.lookup(uri).is_empty():
		opened = open_recent(uri, false, metadata)
	else:
		requested_play = true
		opened = open_local(uri, title, 0, true, false, "", metadata)
	if opened and RecentFiles.valid_cover(cover): _library_cover = cover
	return opened

func open_recent(uri: String, from_start: bool = false, metadata: Dictionary = {}) -> bool:
	var entry := recent_files.lookup(uri)
	if entry.is_empty() or not platform:
		return false
	if not uri.begins_with("content://"):
		requested_play = true
		return open_local(uri, str(entry.title), 0 if from_start else _resume(uri), true, false, "", metadata)
	cancel_pending_open()
	_access_pending = {"uri": uri, "title": str(entry.title), "start_ms": 0 if from_start else _resume(uri), "metadata": metadata.duplicate(true)}
	_access_request = platform.request_local_video_access(uri)
	if _access_request <= 0:
		_access_pending = {}
		picker_error = "File access check busy or unavailable"
		changed.emit()
		return false
	picker_error = "Checking file access..."
	changed.emit()
	return true

func _on_local_access(id: int, payload: String) -> void:
	if id != _access_request or _access_pending.is_empty():
		return
	var parser := JSON.new()
	if parser.parse(payload) != OK or not parser.data is Dictionary:
		return
	var result: Dictionary = parser.data
	if result.get("uri") != _access_pending.uri:
		return
	var pending := _access_pending.duplicate(true)
	_access_pending = {}
	_access_request = 0
	if result.get("state") != "readable" or not result.get("persisted_permission") is bool:
		picker_error = str(result.get("error", "File unavailable; select it again"))
		changed.emit()
		return
	requested_play = true
	var metadata: Dictionary = pending.get("metadata", {}).duplicate(true)
	if not str(result.get("display_name", "")).is_empty(): metadata.basename = result.display_name
	if open_local(str(pending.uri), str(pending.title), int(pending.start_ms), true, false, "", metadata):
		_file_permission_persisted = result.persisted_permission

func play_calibration_clip() -> void:
	_fixture = (_fixture + 1) % 3
	var filename: String = ["mp03_frame_identity", "c03_sbs_grid", "mp06_audio_clock"][_fixture]
	var source := FileAccess.open("res://media/%s.mp4" % filename, FileAccess.READ)
	if not source:
		picker_error = "Calibration video unavailable"
		changed.emit()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://fixtures"))
	var path := "user://fixtures/%s.mp4" % filename
	var target := FileAccess.open(path, FileAccess.WRITE)
	if not target:
		return
	while source.get_position() < source.get_length():
		target.store_buffer(source.get_buffer(65536))
	target.close()
	source.close()
	stereo_sbs = true
	geometry = Geometry.Geometry.FLAT
	requested_play = true
	open_local("file://" + ProjectSettings.globalize_path(path), filename, 0, false)

func open_local(uri: String, title: String, start_ms: int = 0, restore_mode: bool = true, alpha: bool = false, basename: String = "", metadata: Dictionary = {}) -> bool:
	_open_trace = [{"stage": "requested", "time_ms": Time.get_ticks_msec(), "start_ms": start_ms}]
	if not platform or not platform.mpv_supported():
		picker_error = "MPV playback backend unavailable"
		changed.emit()
		return false
	cancel_pending_open()
	close_video()
	# Alpha-packed and Alpha-wanted files say so in their names (PTMediaServer / DeoVR markers).
	var stated := Naming.from_name(basename if not basename.is_empty() else (title if not title.is_empty() else uri.uri_decode().get_file()))
	if uri.begins_with("medialib://"): stated.erase("alpha")
	packed_file = bool(stated.get("packed", false))
	packed_alpha = packed_file
	_layout_pending = null
	if restore_mode:
		# Ignore legacy per-file model choices; everyday playback uses one tested ROI profile.
		profile = AUTOMATIC_PROFILE
		var saved := mode_memory.lookup(uri)
		if not saved.is_empty():
			# The user's own choice for this file wins over its name and shape.
			geometry = int(saved.geometry)
			stereo_sbs = bool(saved.stereo_sbs)
			top_bottom = stereo_sbs and bool(saved.get("top_bottom", false))
			fisheye_fov = int(saved.get("fisheye_fov", 180)) if int(saved.get("fisheye_fov", 180)) in FISHEYE_FOVS else 180
			swap_eyes = bool(saved.swap_eyes)
			depth_requested = bool(saved.get("depth_requested", false)) and not stereo_sbs
		elif not mode_lock.is_empty() and not stated.has("geometry") and not stated.has("stereo"):
			geometry = int(mode_lock.geometry)
			stereo_sbs = int(mode_lock.layout) != 0
			top_bottom = int(mode_lock.layout) == 2
			fisheye_fov = int(mode_lock.fisheye_fov)
			swap_eyes = false
			depth_requested = bool(mode_lock.depth) and not stereo_sbs
		else:
			depth_requested = false
			geometry = int(stated.get("geometry", Geometry.Geometry.FLAT))
			stereo_sbs = bool(stated.get("stereo", geometry in [Geometry.Geometry.HALF_EQUIRECT, Geometry.Geometry.FISHEYE]))
			top_bottom = stereo_sbs and bool(stated.get("top_bottom", false))
			fisheye_fov = int(stated.get("fisheye_fov", 180))
			swap_eyes = bool(stated.get("swap", false))
			if not stated.has("geometry") or not stated.has("stereo"):
				_layout_pending = stated
	# Videos start as normal playback unless the name asks for live Alpha.
	alpha_requested = alpha or (restore_mode and bool(stated.get("alpha", false)) and not packed_file)
	_thumb_tries = 0
	_thumbnail_result = {}
	_thumb_after_ms = -1
	if _thumbnail_source(uri) and Thumbnails.texture(uri) == null:
		_thumb_after_ms = 0
	local_uri = uri
	_warm_rvm()
	if auto_depth and OS.get_name() == "Android" and Engine.has_singleton("QuestPlayer"):
		Engine.get_singleton("QuestPlayer").warm_depth()
	display_name = title
	_bookmark_metadata = metadata.duplicate(true)
	if not basename.is_empty(): _bookmark_metadata.basename = basename
	if str(_bookmark_metadata.get("basename", "")).is_empty():
		if uri.begins_with("file://") or uri.begins_with("smb://") or uri.begins_with("cloud://"):
			_bookmark_metadata.basename = uri.uri_decode().get_file()
		elif uri.begins_with("content://"):
			_bookmark_metadata.basename = title
	if uri.begins_with("file://"):
		var source := FileAccess.open(uri.trim_prefix("file://").uri_decode(), FileAccess.READ)
		if source: _bookmark_metadata.size = source.get_length()
	_bookmark_resolve()
	depth_requested = auto_depth and geometry == Geometry.Geometry.FLAT and not stereo_sbs and not alpha_requested
	_last_seek_mode = SeekPolicy.normalize(seek_mode)
	var id: int = platform.open_mpv_video(uri, maxi(start_ms, 0), stereo_sbs, profile, alpha_requested, true, depth_requested,
		stereo_sbs and top_bottom, SeekPolicy.normalize(seek_mode) == SeekPolicy.EXACT)
	media.begin(id)
	_open_trace.append({"stage": "dispatched", "time_ms": Time.get_ticks_msec(), "session_id": id})
	_remember_file = restore_mode and id > 0
	_history_started = false
	_file_permission_persisted = false
	audio_track_id = -1
	_clone_applied = false
	subtitles.select(0)
	subtitles.clear(true)
	reset_view() # every video starts straight ahead at its natural size
	_audio_pending = id > 0
	if id <= 0:
		picker_error = "Player resources are still closing"
	else:
		_waiting_first = true
		platform.set_mpv_playing(id, false)
		picker_error = ""
	changed.emit()
	return id > 0

func _unbind() -> void:
	var previous: Dictionary = _binding.unbind()
	if platform and not previous.is_empty():
		if int(previous.get("frozen_frame_id", 0)) > 0:
			platform.release_mpv_frozen_frame(int(previous.frozen_frame_id))
		else:
			platform.detach_mpv_pair(int(previous.session_id), int(previous.slot_token))
	alpha_enabled = false
	_rvm_alpha = false
	depth_enabled = false
	panel.visible = false
	if caption:
		caption.visible = false

func close_video() -> void:
	_bookmark_scope_sequence += 1
	_bookmark_media_id = ""
	_bookmark_metadata.clear()
	_bookmark_rows.clear()
	_bookmark_cache_revision = -1
	_thumbnail_sequence += 1
	_library_cover = ""
	_record_history(true)
	cancel_pending_open()
	if mode_memory.dirty:
		mode_memory.save()
	if recent_files.dirty:
		recent_files.save()
	_unbind()
	if platform and media.session_id > 0:
		platform.close_mpv_video(media.session_id)
	media.close()
	_pending_pair = {}
	_pending_revision = {}
	_freeze_request = 0
	_debug_seek_delay_until_ms = 0
	_waiting_first = false
	_audio_pending = false
	control.close()
	_remember_file = false
	subtitles.clear(true)
	changed.emit()

func checkpoint_playback() -> void:
	_record_history(true)

func clear_history() -> void:
	if recent_files.clear_all() and not recent_files.save():
		Log.record("recent_file_save_failed", {"error": recent_files.last_error})
	_history_started = false

func _resume(uri: String) -> int:
	return recent_files.resume_position(uri) if history_enabled else 0

func _record_history(force: bool = false) -> void:
	if not history_enabled or not _remember_file or not media.accepts(media.session_id) or media.last_pair.is_empty() \
		or not media.last_pair.get("source_pts_verified", false) or not panel.visible:
		return
	var pair: Dictionary = media.last_pair
	if int(pair.get("session_id", 0)) != media.session_id or int(pair.get("generation", 0)) != media.generation:
		return
	if not _history_started:
		if not recent_files.opened(local_uri, display_name, _file_permission_persisted):
			return
		_history_started = true
		recent_files.set_cover(local_uri, _library_cover)
		force = true
	var now := Time.get_ticks_msec()
	if not force and now < _history_save_ms:
		return
	var position_ms := clampi(int(float(pair.pts_us) / 1000.0), 0, 2147483647)
	recent_files.progress(local_uri, position_ms, control.duration_ms, media.state == "ended")
	_history_save_ms = now + 5000
	if not recent_files.save():
		Log.record("recent_file_save_failed", {"error": recent_files.last_error})

func _request_revision(position_ms: int = -1, mode: String = "") -> void:
	if not platform or not media.accepts(media.session_id):
		return
	_pending_revision = {"stereo": stereo_sbs, "alpha": alpha_requested, "profile": profile, "position_ms": position_ms,
		"depth": depth_requested and not alpha_requested and not stereo_sbs, "top_bottom": stereo_sbs and top_bottom,
		"seek_mode": SeekPolicy.normalize(seek_mode if mode.is_empty() else mode)}
	platform.set_mpv_playing(media.session_id, false)
	_waiting_first = true
	subtitles.clear()
	if caption:
		caption.visible = false
	if position_ms >= 0: _seek_event("requested")
	_try_revision()

func _start_seek_freeze() -> bool:
	# Capture exactly once before seek/flush; rapid requests share this frame.
	if _freeze_request == 0 and not _binding.ticket.is_empty() and not _is_frozen():
		var capable := Engine.has_singleton("QuestPlayer") or platform.has_method("freeze_mpv_pair")
		if capable:
			_freeze_sequence += 1
			_freeze_request = _freeze_sequence
			if not platform.freeze_mpv_pair(media.session_id, int(_binding.ticket.slot_token), _freeze_request):
				_abort_frozen_seek("Frame capture request rejected")
			return true
	return false

func _is_frozen() -> bool:
	return int(_binding.ticket.get("frozen_frame_id", 0)) > 0

func _seek_event(stage: String) -> void:
	_seek_trace.append({"stage": stage, "time_ms": Time.get_ticks_msec(), "visible": panel != null and panel.visible,
		"frozen": _is_frozen(), "capture_pending": _freeze_request > 0,
		"session_id": media.session_id, "target_ms": control.target_ms,
		"displayed_pts_us": int(_binding.ticket.get("pts_us", -1)),
		"freeze_copy_us": int(_binding.ticket.get("freeze_copy_us", 0))})
	if _seek_trace.size() > 64: _seek_trace.pop_front()
	_write_debug_report()

func _abort_frozen_seek(reason: String) -> void:
	_freeze_request = 0
	_pending_revision = {}
	_waiting_first = false
	control.reject()
	picker_error = reason
	platform.set_mpv_playing(media.session_id, requested_play)
	_seek_event("capture_failed")
	changed.emit()

func _on_frozen_pair(id: int, payload: String) -> void:
	var report: Variant = JSON.parse_string(payload)
	if not report is Dictionary: return
	var pair: Dictionary = report.get("pair", {})
	if id != media.session_id or int(report.get("request_id", 0)) != _freeze_request \
			or _pending_revision.is_empty() or int(_pending_revision.position_ms) < 0:
		if int(pair.get("frozen_frame_id", 0)) > 0:
			platform.release_mpv_frozen_frame(int(pair.frozen_frame_id))
		if int(report.get("request_id", 0)) == _freeze_request: _freeze_request = 0
		return
	if report.get("state") != "ready":
		_abort_frozen_seek(str(report.get("error", "Frame capture failed")))
		return
	# Preserve visibility, shader parameters and effect state during replacement.
	var previous := _binding.unbind()
	if not _binding.bind(material, pair):
		_binding.bind(material, previous)
		platform.release_mpv_frozen_frame(int(pair.frozen_frame_id))
		_abort_frozen_seek("Frozen video frame could not be bound")
		return
	platform.detach_mpv_pair(int(previous.session_id), int(previous.slot_token))
	_freeze_request = 0
	_seek_event("frozen")
	_try_revision()

func _try_revision() -> void:
	if _pending_revision.is_empty() or _freeze_request > 0 or _pixel_busy or _thumbnail_busy:
		return
	if int(_pending_revision.position_ms) >= 0 and _start_seek_freeze(): return
	if int(_pending_revision.position_ms) >= 0 and Time.get_ticks_msec() < _debug_seek_delay_until_ms:
		return
	var request := _pending_revision
	var id: int = platform.revise_mpv_video(media.session_id, request.stereo, request.alpha, request.profile, request.position_ms,
		request.depth, request.top_bottom, request.seek_mode == SeekPolicy.EXACT)
	if id <= 0:
		return
	if int(request.position_ms) < 0 or not _is_frozen(): _unbind()
	_pending_pair = {}
	_pending_revision = {}
	var held_format := media.format.duplicate()
	media.begin(id)
	if _is_frozen(): media.format = held_format
	platform.set_mpv_playing(id, false)
	if int(request.position_ms) >= 0:
		_last_seek_mode = request.seek_mode
		control.take_pending()
		_debug_seek_delay_until_ms = 0
		_seek_event("seek_started")
	changed.emit()

## Alpha as the user sees it: live RVM, or the mask packed in this file.
func alpha_wanted() -> bool:
	return alpha_requested or (packed_file and packed_alpha)

## The URI/effect preferences survive close for history; they are not playback state.
func has_active_presentation() -> bool:
	if local_uri.is_empty() or not media.accepts(media.session_id): return false
	return media.state != "ended" or (loop_enabled and requested_play) \
		or _waiting_first or not _pending_revision.is_empty()

func set_alpha(enabled: bool) -> bool:
	if packed_file:
		packed_alpha = enabled
		_apply_packed()
		changed.emit()
		return true
	alpha_requested = enabled
	if enabled:
		depth_requested = false
	_remember_mode()
	_request_revision()
	changed.emit()
	return true

## 2D->3D for mono sources; switching it on ends Alpha.
func set_depth(enabled: bool) -> bool:
	if enabled and (stereo_sbs or geometry != Geometry.Geometry.FLAT):
		return false
	auto_depth = enabled
	depth_requested = enabled
	if enabled:
		alpha_requested = false
	_remember_mode()
	_request_revision()
	changed.emit()
	return true

## The bridge renders the stereo pair: tell it the strength once per session and change.
func _send_depth_view() -> void:
	if not depth_enabled or media.session_id <= 0 or not platform:
		return
	# JNISingleton.has_method() cannot see Java plugin methods. Only inspect host test doubles.
	if not Engine.has_singleton("QuestPlayer") and not platform.has_method("set_mpv_depth_view"): return
	var strength := depth_strength if depth_requested else 0.0
	var key := "%d:%f" % [media.session_id, strength]
	if key != _depth_view_sent and platform.set_mpv_depth_view(media.session_id,
		DEPTH_SHIFT * strength, DEPTH_CONVERGENCE):
		_depth_view_sent = key

func depth_ready() -> bool:
	return depth_enabled and not media.last_pair.is_empty() and media.last_pair.get("depth_ran", false)

## Depth compiled for this device: 3D starts at once (otherwise frames show flat until it is).
func depth_model_ready() -> bool:
	if OS.get_name() == "Android" and Engine.has_singleton("QuestPlayer"):
		return bool(Engine.get_singleton("QuestPlayer").depth_ready())
	return true

func cycle_depth_strength() -> void:
	set_depth_strength(DEPTH_STRENGTHS[(DEPTH_STRENGTHS.find(depth_strength) + 1) % DEPTH_STRENGTHS.size()])

func set_depth_strength(value: float) -> bool:
	var strength := DepthStrength.clamp_value(value)
	if strength > 0.0 and (stereo_sbs or geometry != 0 or local_uri.is_empty() or media.state == "closed"): return false
	if strength > 0.0: depth_strength = strength
	auto_depth = strength > 0.0
	material.set_shader_parameter("depth_shift", DEPTH_SHIFT * strength)
	if depth_requested != (strength > 0.0): set_depth(strength > 0.0)
	# Nonzero changes only update parallax; never revise/restart the processing session.
	_send_depth_view()
	changed.emit()
	return true

## The extra track titled "Clone voice" (see SidecarAudio.kt); 0 when this video has none.
func clone_voice_track() -> int:
	for track in media.playback.get("details", {}).get("audio_tracks", []):
		if track is Dictionary and bool(track.get("external", false)) and str(track.get("title", "")) == "Clone voice":
			return int(track.get("id", 0))
	return 0

func clone_voice_active() -> bool:
	var clone := clone_voice_track()
	return clone > 0 and str(media.playback.get("details", {}).get("audio_track_id", "")) == str(clone)

## Clone voice <-> the video's own audio. The choice carries over to the next video with a clone voice.
func toggle_clone_voice() -> bool:
	var clone := clone_voice_track()
	if clone <= 0:
		return false
	var active := clone_voice_active()
	if not set_audio_options(-1 if active else clone, audio_volume, audio_muted):
		return false
	prefer_clone_voice = not active
	return true

func alpha_ready() -> bool:
	return alpha_enabled and not media.last_pair.is_empty() and media.last_pair.get("inference_ran", false)

func toggle_play() -> void:
	if media.state == "ended":
		requested_play = true
		seek_absolute(0)
		return
	requested_play = not requested_play
	if not requested_play:
		_record_history(true)
	if platform and media.accepts(media.session_id):
		platform.set_mpv_playing(media.session_id, requested_play and not _waiting_first)
	changed.emit()

func set_audio_options(track_id: int, volume: float, muted: bool) -> bool:
	if track_id < -1 or not is_finite(volume) or volume < 0.0 or volume > 100.0 or not platform or not media.accepts(media.session_id):
		return false
	if not platform.set_mpv_audio(media.session_id, track_id, volume, muted):
		return false
	audio_track_id = track_id
	audio_volume = volume
	audio_muted = muted
	_audio_pending = false
	changed.emit()
	return true

## An explicit menu choice wins over automatic dubbing, including before the first frame.
func select_audio_track(track_id: int) -> bool:
	if not set_audio_options(track_id, audio_volume, audio_muted): return false
	_clone_applied = true
	prefer_clone_voice = clone_voice_track() > 0 and track_id == clone_voice_track()
	return true

## Raising the volume unmutes (a muted slider shows 0, so a silent step up would look ignored);
## lowering keeps mute.
func change_volume(delta: float) -> bool:
	return set_audio_options(audio_track_id, clampf(audio_volume + delta, 0.0, 100.0), audio_muted and delta <= 0.0)

func toggle_mute() -> bool:
	return set_audio_options(audio_track_id, audio_volume, not audio_muted)

func cycle_audio_track(direction: int = 1) -> bool:
	var details: Dictionary = media.playback.get("details", {})
	var tracks: Array = details.get("audio_tracks", [])
	if tracks.is_empty():
		return false
	var choices: Array[int] = [0]
	for track in tracks:
		if track is Dictionary and int(track.get("id", 0)) > 0:
			choices.append(int(track.id))
	var current := int(details.get("audio_track_id", 0))
	var index := choices.find(current)
	return set_audio_options(choices[posmod(index + direction, choices.size())], audio_volume, audio_muted)

func seek_absolute(position_ms: int, mode: String = "") -> bool:
	if not platform or not media.accepts(media.session_id):
		return false
	control.seek_absolute(position_ms)
	_request_revision(control.target_ms, mode)
	return true

func _bookmark_resolve() -> void:
	_bookmark_media_id = bookmark_store.resolve(local_uri, str(_bookmark_metadata.get("basename", "")), _bookmark_metadata.get("size", -1))
	_bookmark_cache_revision = -1

func bookmark_seekable() -> bool:
	var details: Dictionary = media.playback.get("details", {})
	return media.accepts(media.session_id) and control.duration_ms > 0 and details.get("seekable", "") == "yes" \
		and details.get("partially_seekable", "no") != "yes" and media.state not in ["failed", "closed"]

func bookmark_scope() -> String:
	return str(_bookmark_scope_sequence) + "|" + _bookmark_media_id

func bookmark_snapshot() -> Dictionary:
	if not bookmark_seekable() or _waiting_first or control.pending or control.in_flight > 0 \
		or not _pending_revision.is_empty() or _is_frozen() or not panel or not panel.visible: return {}
	var pair: Dictionary = _binding.ticket
	if not pair.get("source_pts_verified", false) or int(pair.get("session_id", -1)) != media.session_id \
		or int(pair.get("generation", -1)) != media.generation or int(pair.get("pts_us", -1)) < 0: return {}
	var time := int(pair.pts_us) / 1000
	if time >= control.duration_ms: return {}
	return {"scope": bookmark_scope(), "position_ms": time}

func bookmarks_snapshot() -> Dictionary:
	if _bookmark_cache_revision != bookmark_store.revision:
		_bookmark_rows = bookmark_store.list_markers(_bookmark_media_id)
		_bookmark_cache_revision = bookmark_store.revision
	return {"bookmark_scope": bookmark_scope(), "bookmarks": _bookmark_rows,
		"bookmark_revision": bookmark_store.revision, "bookmark_undo": bookmark_store.can_undo(),
		"bookmark_ready": not bookmark_snapshot().is_empty(), "bookmark_seekable": bookmark_seekable(),
		"seek_mode": SeekPolicy.normalize(seek_mode), "bookmark_seek_mode": SeekPolicy.bookmark_override(bookmark_seek_mode),
		"bookmark_effective_seek_mode": SeekPolicy.effective(seek_mode, bookmark_seek_mode)}

func bookmark_action(operation: String, marker_id: String, scope: String) -> String:
	if scope != bookmark_scope(): return ""
	match operation:
		"add":
			var snapshot := bookmark_snapshot()
			if snapshot.is_empty(): return ""
			var item := bookmark_store.add(local_uri, str(_bookmark_metadata.get("basename", "")), _bookmark_metadata.get("size", -1), int(snapshot.position_ms))
			bookmark_last_added = item
			return "Bookmark added" if not item.is_empty() else bookmark_store.last_error
		"delete":
			return "Bookmark deleted" if bookmark_store.remove(_bookmark_media_id, marker_id) else "Bookmark save failed"
		"undo":
			return "Bookmark restored" if bookmark_store.restore() else "Bookmark save failed"
		"seek":
			if not bookmark_seekable(): return ""
			for marker in bookmark_store.list_markers(_bookmark_media_id):
				if marker.id == marker_id and int(marker.position_ms) < control.duration_ms:
					return "" if seek_absolute(int(marker.position_ms), SeekPolicy.effective(seek_mode, bookmark_seek_mode)) else "Bookmark jump failed"
	return ""

func set_subtitle_track(track_id: int) -> bool:
	if track_id < -1 or not platform or not media.accepts(media.session_id):
		return false
	if not platform.set_mpv_subtitle(media.session_id, track_id):
		return false
	subtitles.select(track_id)
	if caption:
		caption.visible = false
	if projected_subtitles:
		projected_subtitles.clear(material)
	changed.emit()
	return true

func cycle_subtitle_track(direction: int = 1) -> bool:
	var choices: Array[int] = [0]
	for track in media.playback.get("details", {}).get("subtitle_tracks", []):
		if track is Dictionary and int(track.get("id", 0)) > 0 and SubtitleState.text_codec(str(track.get("codec", ""))):
			choices.append(int(track.id))
	if choices.size() == 1:
		return false
	return set_subtitle_track(choices[posmod(choices.find(subtitles.requested_track) + direction, choices.size())])

func _poll_subtitles() -> void:
	if not caption:
		return
	var ready := platform != null and media.accepts(media.session_id) and not media.last_pair.is_empty() \
		and not _waiting_first and _pending_revision.is_empty() and panel.visible
	if not ready:
		caption.visible = false
		projected_subtitles.clear(material)
		return
	var now := Time.get_ticks_msec()
	if now >= _subtitle_poll_ms:
		_subtitle_poll_ms = now + 50
		var payload: String = platform.get_mpv_subtitles(media.session_id, subtitles.sequence)
		var snapshot: Variant = JSON.parse_string(payload) if not payload.is_empty() else null
		if snapshot is Dictionary and subtitles.observe(snapshot, media.session_id, media.last_pair):
			_subtitle_received_ms = now
	if now - _subtitle_received_ms > 1000:
		subtitles.clear()
	caption.text = subtitles.text
	caption.visible = not subtitles.text.is_empty()
	if caption.visible:
		_place_caption()
	else:
		projected_subtitles.clear(material)

func _place_caption() -> void:
	var now := Time.get_ticks_msec()
	var delta := clampf((now - _caption_ms) / 1000.0, 0.0, 0.1)
	_caption_ms = now
	var eye := Vector3(0, 1.6, 0)
	var forward := Vector3.FORWARD
	if view_camera and view_camera.is_inside_tree():
		eye = view_camera.global_position
		forward = -view_camera.global_basis.z
	if geometry == Geometry.Geometry.FLAT:
		# Ordinary video captions stay on the screen, independent of immersive preferences.
		var anchor := panel.global_transform * Vector3(0, -_flat.size.y * 0.5 + 0.06, 0.01)
		caption.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		caption.layers = 1
		projected_subtitles.clear(material)
		caption.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		caption.pixel_size = 0.0016
		caption.width = _flat.size.x * 0.9 / 0.0016
		caption.global_transform = Transform3D(panel.global_basis, anchor)
		_caption_direction = Vector3.ZERO
		return
	# Lazy follow: still while the head looks around a little, then glides back in front.
	if _caption_direction == Vector3.ZERO:
		_caption_direction = forward
	elif _caption_following or _caption_direction.angle_to(forward) > CAPTION_SLACK:
		_caption_following = _caption_direction.angle_to(forward) > deg_to_rad(2.0)
		_caption_direction = _caption_direction.slerp(forward, minf(1.0, delta * 4.0)).normalized()
	var up := Vector3.UP if absf(_caption_direction.y) < 0.98 else Vector3.BACK
	var facing := Basis.looking_at(_caption_direction, up)
	var place := facing * (Basis(Vector3.RIGHT, SubtitleDepth.elevation(subtitle_position)) * Vector3(0, 0, -subtitle_distance))
	# Same angular size at any distance.
	caption.pixel_size = 0.001 * subtitle_distance
	caption.width = 700
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	caption.global_transform = Transform3D(Basis(), eye + place)
	caption.layers = 0 # Immersive glyphs are drawn once, inside the video projection below.
	var ray := place.normalized()
	var relative := eye - panel.global_position
	var b := relative.dot(ray)
	var along := -b + sqrt(maxf(0, b * b - relative.length_squared() + SPHERE_RADIUS * SPHERE_RADIUS))
	var local_direction := panel.global_basis.inverse() * (eye + ray * along - panel.global_position)
	var local_up := panel.global_basis.inverse() * (view_camera.global_basis.y if view_camera else Vector3.UP)
	var anchor_basis := Basis.looking_at(local_direction.normalized(), local_up.normalized())
	projected_subtitles.update_patch(caption, material, anchor_basis, subtitle_distance, ProjectedSubtitles.runtime_ipd())

func seek_relative(delta_ms: int) -> bool:
	if not platform or not media.accepts(media.session_id):
		return false
	control.seek_relative(delta_ms)
	_request_revision(control.target_ms)
	return true

## The current projection and layout as a lock.
func current_lock() -> Dictionary:
	return {"geometry": geometry, "layout": stereo_layout(), "depth": depth_requested and not stereo_sbs, "fisheye_fov": fisheye_fov}

## Locks the current mode, or unlocks when it is the locked one.
func toggle_mode_lock() -> void:
	var current := current_lock()
	mode_lock = {} if str(mode_lock) == str(current) else current
	changed.emit()

## A stored lock, checked; anything malformed leaves the player unlocked.
func load_mode_lock(value: Variant) -> void:
	mode_lock = {}
	if not value is Dictionary:
		return
	var numbers := ["geometry", "layout", "fisheye_fov"].all(func(k): return value.get(k) is int or value.get(k) is float)
	if not numbers or not value.get("depth") is bool or int(value.geometry) not in [0, 1, 2, 3] 		or int(value.layout) not in [0, 1, 2] or int(value.fisheye_fov) not in FISHEYE_FOVS:
		return
	mode_lock = {"geometry": int(value.geometry), "layout": int(value.layout), "depth": bool(value.depth) and int(value.layout) == 0,
		"fisheye_fov": int(value.fisheye_fov)}

func toggle_loop() -> void:
	loop_enabled = not loop_enabled
	changed.emit()

## 2D -> side by side -> top-bottom -> 2D.
func toggle_stereo() -> void:
	set_stereo_layout(0 if stereo_sbs and top_bottom else (2 if stereo_sbs else 1))

## 0 mono, 1 side by side, 2 top-bottom.
func set_stereo_layout(layout: int) -> void:
	if layout < 0 or layout > 2 or layout == stereo_layout():
		return
	stereo_sbs = layout != 0
	top_bottom = layout == 2
	if stereo_sbs:
		depth_requested = false
	elif auto_depth and geometry == Geometry.Geometry.FLAT:
		depth_requested = true
		alpha_requested = false
	_remember_mode()
	_request_revision()
	_apply_geometry()
	changed.emit()

func stereo_layout() -> int:
	return 0 if not stereo_sbs else (2 if top_bottom else 1)

func set_fisheye_fov(value: int) -> void:
	if not value in FISHEYE_FOVS or value == fisheye_fov:
		return
	fisheye_fov = value
	_apply_geometry()
	_remember_mode()
	changed.emit()

func cycle_projection() -> void:
	set_projection((geometry + 1) % 4)

func set_projection(value: int) -> void:
	if value < 0 or value > 3:
		return
	geometry = value
	# VR180 and fisheye sources are side-by-side stereo; 360 sources are mostly mono.
	var stereo := geometry in [Geometry.Geometry.HALF_EQUIRECT, Geometry.Geometry.FISHEYE]
	var revise := false
	if geometry != Geometry.Geometry.FLAT and stereo != stereo_sbs:
		stereo_sbs = stereo
		revise = true
	# 2D -> 3D applies to the flat screen, Alpha to VR180 and fisheye: stop effects when switching
	# to an unsupported projection, where their persistent bar buttons are disabled.
	if geometry != Geometry.Geometry.FLAT and depth_requested:
		depth_requested = false
		revise = true
	if not stereo and alpha_requested:
		alpha_requested = false
		revise = true
	if geometry == Geometry.Geometry.FLAT and not stereo_sbs and auto_depth and not depth_requested:
		depth_requested = true
		revise = true
	if revise:
		_request_revision()
	_apply_geometry()
	_remember_mode()
	changed.emit()

func set_profile(value: String) -> void:
	if value == profile or not value in PROFILES:
		return
	profile = value
	_warm_rvm()
	_remember_mode()
	_request_revision()
	changed.emit()

## Quick switch (button / quick bar): only between compiled profiles. Cold ones are chosen in
## settings, which asks for a second press before starting a compile.
func cycle_profile() -> void:
	var start := PROFILES.find(profile)
	var next := profile
	for step in range(1, PROFILES.size()):
		var candidate: String = PROFILES[(start + step) % PROFILES.size()]
		if profile_ready(candidate):
			next = candidate
			break
	if next == profile:
		return
	profile = next
	_warm_rvm()
	_remember_mode()
	_request_revision()
	changed.emit()

func toggle_eye_order() -> bool:
	if not stereo_sbs:
		return false
	swap_eyes = not swap_eyes
	_apply_geometry()
	_remember_mode()
	changed.emit()
	return true

## The file name left the projection or the layout open: the frame's shape decides (once).
func _complete_layout() -> void:
	if _layout_pending == null:
		return
	var chosen := Naming.complete(_layout_pending, int(media.format.width), int(media.format.height))
	_layout_pending = null
	swap_eyes = chosen.swap
	var tb := bool(chosen.stereo) and bool(chosen.top_bottom)
	if int(chosen.geometry) != geometry or bool(chosen.stereo) != stereo_sbs or tb != top_bottom:
		geometry = int(chosen.geometry)
		var revise := bool(chosen.stereo) != stereo_sbs or tb != top_bottom
		stereo_sbs = chosen.stereo
		top_bottom = tb
		var wanted := auto_depth and geometry == Geometry.Geometry.FLAT and not stereo_sbs and not alpha_requested
		revise = revise or depth_requested != wanted
		depth_requested = wanted
		if revise: _request_revision()
		_apply_geometry()
	Log.record("auto_layout", {"geometry": geometry, "stereo_sbs": stereo_sbs, "swap_eyes": swap_eyes,
		"width": media.format.width, "height": media.format.height})

## Packed masks show only on the layout they were made for (fisheye side by side).
func _apply_packed() -> void:
	var shown := packed_file and packed_alpha and not media.last_pair.is_empty() 		and Geometry.legacy_compatible(media.format, stereo_sbs, geometry)
	material.set_shader_parameter("packed_alpha", shown)
	if shown:
		material.set_shader_parameter("packed_size", Vector2(Geometry.packed_dimensions(int(media.format.width), int(media.format.height))))
	alpha_enabled = _rvm_alpha or shown

func _remember_mode() -> void:
	if not _remember_file or not media.accepts(media.session_id):
		return
	var mode := {"geometry": geometry, "stereo_sbs": stereo_sbs, "swap_eyes": swap_eyes,
		"alpha_requested": alpha_requested, "profile": profile, "depth_requested": depth_requested,
		"top_bottom": stereo_sbs and top_bottom, "fisheye_fov": fisheye_fov}
	if mode_memory.remember(local_uri, mode) and not mode_memory.save():
		Log.record("file_mode_save_failed", {"error": mode_memory.last_error})

func _on_pair(id: int, payload: String) -> void:
	if id != media.session_id:
		return
	var pair: Variant = JSON.parse_string(payload)
	if pair is Dictionary:
		_pending_pair = pair

func _present_pending() -> void:
	if _pixel_busy or _thumbnail_busy or _pending_pair.is_empty() or not _pending_revision.is_empty():
		return
	var offered := _pending_pair
	_pending_pair = {}
	var claimed: Variant = JSON.parse_string(platform.claim_mpv_pair(media.session_id, int(offered.slot_token)))
	if not claimed is Dictionary:
		return
	_unbind()
	if not _binding.bind(material, claimed):
		platform.detach_mpv_pair(media.session_id, int(claimed.slot_token))
		picker_error = "Complete video frame could not be bound"
		changed.emit()
		return
	media.last_pair = claimed
	media.logical_session_id = int(claimed.logical_session_id)
	media.generation = int(claimed.generation)
	media.format_revision = int(claimed.format_revision)
	media.effect_revision = int(claimed.effect_revision)
	media.frame_counter += 1
	media.format = {"width": int(claimed.width), "height": int(claimed.height), "pixel_aspect": 1.0, "unapplied_rotation_degrees": 0}
	_rvm_alpha = bool(claimed.alpha_requested) and bool(claimed.inference_ran)
	depth_enabled = bool(claimed.get("depth_requested", false)) and bool(claimed.get("depth_ran", false))
	_apply_packed()
	material.set_shader_parameter("alpha_enabled", _rvm_alpha)
	_send_depth_view()
	_apply_geometry()
	panel.visible = true
	if not platform.acknowledge_mpv_pair(media.session_id, int(claimed.slot_token)):
		_unbind()
		return
	if _waiting_first:
		if control.in_flight > 0: _seek_event("target_presented")
		_waiting_first = false
		var actual_position_ms := int(int(claimed.pts_us) / 1000)
		if control.in_flight > 0:
			control.first_frame(actual_position_ms)
		else:
			control.observe(actual_position_ms, control.duration_ms)
		platform.set_mpv_playing(media.session_id, requested_play)
	else:
		control.observe(int(int(claimed.pts_us) / 1000), control.duration_ms)
	if media.frame_counter == 1:
		_open_trace.append({"stage": "first_pair_bound", "time_ms": Time.get_ticks_msec(), "pts_us": int(claimed.pts_us)})
		_complete_layout()
		_remember_mode()
		Log.record("mpv_pair_bound", media.frame_identity())
	_record_history()
	if _debug_request > 0 and not _debug_benchmark and _debug_pairs.size() < 128:
		_debug_pairs.append(claimed.duplicate(true))
		_write_debug_report()
	changed.emit()

func _on_state(id: int, payload: String) -> void:
	if id != media.session_id:
		return
	var report: Variant = JSON.parse_string(payload)
	if not report is Dictionary:
		return
	if report.get("audio_focus_change", "") == "loss":
		requested_play = false
	media.playback = report
	var details: Dictionary = report.get("details", {})
	var size := str(details.get("file_size", ""))
	if not BookmarkStore.integer(_bookmark_metadata.get("size", -1), 1, 9007199254740991) and size.is_valid_int() and BookmarkStore.integer(int(size), 1, 9007199254740991):
		# Native metadata fills gaps for recent/SAF opens, without hashing or reading the video.
		_bookmark_metadata.size = int(size)
		_bookmark_resolve()
	if details.has("position_seconds"):
		var position_ms := int(float(details.position_seconds) * 1000)
		# MPV's time-pos may still be the requested time after a paused keyframe
		# seek. Keep the timeline and relative shortcuts on the displayed frame.
		var pair: Dictionary = media.last_pair
		if pair.get("source_pts_verified", false) and int(pair.get("session_id", -1)) == media.session_id:
			position_ms = int(int(pair.pts_us) / 1000)
		control.observe(position_ms, int(float(details.get("duration_seconds", "-1")) * 1000))
		media.decoder = str(details.get("codec", "")) + " / " + str(details.get("hwdec_current", ""))
	media.state = str(report.get("state", "opening"))
	if media.state == "ended":
		_record_history(true)
	if _debug_request > 0:
		_debug_status = report.duplicate(true)
		_write_debug_report()
	changed.emit()

func _on_error(id: int, payload: String) -> void:
	if id != media.session_id:
		return
	_thumbnail_sequence += 1
	var report: Variant = JSON.parse_string(payload)
	media.error = str(report.get("code", "MPV playback failed")) if report is Dictionary else "MPV playback failed"
	media.state = "failed"
	_freeze_request = 0
	_pending_revision = {}
	_waiting_first = false
	control.reject()
	subtitles.clear()
	_recover = media.error == "MPV_GL_CONTEXT_RECREATED"
	_recover_ms = control.observed_position_ms
	_unbind()
	Log.record("mpv_error", {"session_id": id, "report": report})
	_write_debug_report()
	changed.emit()

func _on_detach(id: int, _payload: String) -> void:
	if int(_binding.ticket.get("session_id", 0)) == id and not _is_frozen():
		_unbind()

func _on_released(id: int, _payload: String) -> void:
	if id == media.session_id and _recover:
		_recover = false
		call_deferred("_reopen_after_context_loss", local_uri, display_name, _recover_ms, _remember_file)
	_write_debug_report()

func _reopen_after_context_loss(uri: String, title: String, position_ms: int, remember_file: bool) -> void:
	# Retain live user choices even if the last disk save failed.
	var persisted := _file_permission_persisted
	if open_local(uri, title, position_ms, false, alpha_requested):
		_remember_file = remember_file
		_file_permission_persisted = persisted

func _on_debug_command(id: int, payload: String) -> void:
	var command: Variant = JSON.parse_string(payload)
	if command is Dictionary and command.get("operation", "") in ["open", "seek"] and command.get("seek_mode", "") in [SeekPolicy.SPEED, SeekPolicy.EXACT]:
		seek_mode = command.seek_mode
	if not command is Dictionary:
		return
	_debug_request = id
	if command.operation == "open":
		_debug_benchmark = bool(command.get("benchmark", false))
		loop_enabled = bool(command.get("loop", false)) # long thermal runs replay a short fixture
		_debug_next_report_us = 0
		if _debug_benchmark:
			geometry = int(command.get("projection", 0))
		_debug_commands = []
		_debug_pairs = []
		stereo_sbs = bool(command.get("stereo", true))
		profile = str(command.profile)
		alpha_requested = bool(command.enabled)
		depth_requested = bool(command.get("depth", false))
		auto_depth = depth_requested
		requested_play = true
		open_local(str(command.uri), str(command.title), maxi(int(command.position_ms), 0), false, alpha_requested)
	elif command.operation == "alpha":
		set_alpha(bool(command.enabled))
	elif command.operation == "depth":
		command["accepted"] = set_depth_strength(float(command.strength)) if command.has("strength") else set_depth(bool(command.enabled))
	elif command.operation == "audio":
		command["accepted"] = set_audio_options(int(command.track_id), audio_volume, audio_muted)
	elif command.operation == "subtitle":
		command["accepted"] = set_subtitle_track(int(command.track_id))
	elif command.operation == "playing":
		if requested_play != bool(command.enabled) or (bool(command.enabled) and media.state == "ended"):
			toggle_play()
	elif command.operation == "seek":
		_debug_seek_delay_until_ms = Time.get_ticks_msec() + clampi(int(command.get("hold_seek_ms", 0)), 0, 30000)
		seek_absolute(int(command.position_ms))
	elif command.operation == "hold_pixels":
		if _is_frozen() and not _pixel_busy:
			var held: Dictionary = _binding.ticket.duplicate(true)
			if _binding.warped: held.stereo_sbs = false
			var pinned: bool = platform.retain_mpv_frozen_frame(int(held.frozen_frame_id))
			if not pinned: return
			_pixel_busy = true
			_debug_pixels = await PixelProbe.capture(self, held, id)
			_debug_pixels["request_key"] = str(command.request_key)
			platform.release_mpv_frozen_frame(int(held.frozen_frame_id))
			_pixel_busy = false
	elif command.operation == "observe":
		pass
	elif command.operation == "stereo":
		if stereo_sbs != bool(command.enabled):
			toggle_stereo()
	elif command.operation == "profile":
		profile = str(command.profile)
		_warm_rvm() # as set_profile: a cold profile starts its background compile
		_request_revision()
	elif command.operation == "close":
		close_video()
	elif command.operation == "pixels":
		_debug_pixels = {"state": "failed", "request_id": id, "request_key": str(command.request_key)}
		if not _pixel_busy and not requested_play and not _binding.ticket.is_empty() and _pending_revision.is_empty():
			_pixel_busy = true
			_pixel_request = id
			_pixel_request_key = str(command.request_key)
			if platform.request_mpv_pixel_mask(id, int(_binding.ticket.session_id), int(_binding.ticket.slot_token)):
				_debug_pixels["state"] = "waiting_mask"
			else:
				_pixel_busy = false
				_debug_pixels["error"] = "Native pinned mask request rejected"
		else:
			_debug_pixels["error"] = "Paused immutable binding required"
	command["request_id"] = id
	_debug_commands.append(command)
	if _debug_commands.size() > 32:
		_debug_commands.pop_front()
	_write_debug_report()

func _on_pixel_mask(id: int, payload: String) -> void:
	if id != _pixel_request:
		return
	var mask: Variant = JSON.parse_string(payload)
	if not mask is Dictionary or mask.get("state") != "ready":
		_debug_pixels = {"state": "failed", "request_id": id, "error": "Native mask readback failed", "native": mask}
		_pixel_busy = false
		_write_debug_report()
		return
	var pair: Dictionary = mask.pair
	_debug_pixels = await PixelProbe.capture(self, pair, id)
	_debug_pixels["request_key"] = _pixel_request_key
	_debug_pixels["mask_reference"] = mask
	_debug_pixels["native_pin_released"] = platform.release_mpv_pixel_pin(int(pair.session_id), int(pair.slot_token))
	_pixel_busy = false
	_write_debug_report()

func _write_debug_report() -> void:
	if _debug_request <= 0 or not platform:
		return
	var now := Time.get_ticks_usec()
	if _debug_benchmark and now < _debug_next_report_us:
		return
	_debug_next_report_us = now + 250000
	var progress: Dictionary = {}
	var host := get_parent()
	if host and host.has_method("_menu_state"):
		var menu: Node3D = host.player_menu
		if menu and menu.visible and is_instance_valid(menu._thumb):
			progress = {"visible": true, "position_ms": int(menu._state.get("position_ms", -1)),
				"preview_ms": menu._seek_preview, "elapsed": menu._elapsed.text,
				"thumb_x": menu._thumb.position.x, "bar_width": menu.BAR_SEEK,
				"duration_ms": int(menu._state.get("duration_ms", -1))}
	var report := {"schema_version": 1, "request_id": _debug_request, "commands": _debug_commands,
		"seek_policy_ui": host.seek_policy_probe_result if host and host.get("seek_policy_probe_result") is Dictionary else {},
		"open_trace": _open_trace.duplicate(true),
		"media": media.snapshot(), "layout": layout_snapshot(), "pairs": _debug_pairs,
		"native_status": _debug_status, "engine_fps": Engine.get_frames_per_second(),
		"sample_monotonic_us": now, "engine_drawn_frames": Engine.get_frames_drawn(),
		"benchmark": _debug_benchmark,
		"pixel_probe": _debug_pixels,
		"seek_trace": _seek_trace,
		"player_menu_progress": progress,
		"thumbnail": {"available": Thumbnails.has(local_uri), "capture": _thumbnail_result, "busy": _thumbnail_busy},
		"diagnostic_2d": OS.get_cmdline_user_args().has("--mpv-diagnostic-2d"),
		"scope": "Production MPV/RVM/Godot ownership trace; independent pixel, audio and performance validation pending"}
	platform.save_mpv_player_report(_debug_request, JSON.stringify(report))

func _source_size() -> Vector2:
	return Vector2(float(media.format.width), float(media.format.height))

func _apply_geometry() -> void:
	super._apply_geometry()
	material.set_shader_parameter("stereo_sbs", stereo_sbs or _binding.warped)
	material.set_shader_parameter("depth_enabled", depth_enabled and not _binding.warped)
	material.set_shader_parameter("depth_shift", DEPTH_SHIFT * depth_strength if depth_requested else 0.0)

func reset_view() -> void:
	super.reset_view()
	_caption_direction = Vector3.ZERO

func layout_snapshot() -> Dictionary:
	var playback := control.snapshot()
	playback["seek_method"] = "mpv_absolute_" + ("exact" if _last_seek_mode == SeekPolicy.EXACT else "keyframes") + "_and_processing_generation"
	playback["seek_mode"] = SeekPolicy.normalize(seek_mode)
	playback["active_seek_mode"] = _last_seek_mode
	playback["bookmark_seek_mode"] = SeekPolicy.bookmark_override(bookmark_seek_mode)
	playback["source_frame_pts_verified"] = not media.last_pair.is_empty()
	return {"geometry": ["flat", "half_equirect_180", "fisheye_180", "equirect_360"][geometry], "stereo_sbs": stereo_sbs,
		"top_bottom": stereo_sbs and top_bottom, "fisheye_fov": fisheye_fov,
		"alpha_requested": alpha_requested, "alpha_enabled": alpha_enabled, "profile": profile,
		"depth_requested": depth_requested, "depth_enabled": depth_enabled, "depth_strength": depth_strength, "auto_depth": auto_depth,
		"alpha_ready": alpha_ready(), "backend": "Android_libmpv", "loop_enabled": loop_enabled,
		"playback_control": playback, "subtitles": {"requested_track": subtitles.requested_track,
			"cue": subtitles.cue, "text": subtitles.text,
			"render_layer": "independent_Label3D" if geometry == Geometry.Geometry.FLAT else "video_projection_overlay",
			"distance_m": subtitle_distance, "position": subtitle_position,
			"runtime_ipd_m": ProjectedSubtitles.runtime_ipd(),
			"angular_parallax_rad": material.get_shader_parameter("subtitle_parallax"),
			"source_frame_sync_verified": false, "device_validation": "pending"},
		"frame_hold": {"visible": panel.visible, "frozen": _is_frozen(), "capture_pending": _freeze_request > 0,
			"frame_id": int(_binding.ticket.get("frame_id", -1)), "pts_us": int(_binding.ticket.get("pts_us", -1)),
			"frozen_frame_id": int(_binding.ticket.get("frozen_frame_id", 0)),
			"freeze_copy_us": int(_binding.ticket.get("freeze_copy_us", 0))}, "device_validation": "pending"}

func _can_loop() -> bool:
	if not loop_enabled or not requested_play or media.state != "ended" or _waiting_first or not _pending_revision.is_empty():
		return false
	var end: Dictionary = media.playback
	var final_pair: Dictionary = media.last_pair
	var target: Variant = end.get("eof_source_ticket")
	if not end.get("eof_source_resolved", false) or not end.get("eof_pair_post_draw", false) or not target is Dictionary or final_pair.is_empty():
		return false
	return int(end.get("eof_presented_slot", 0)) == int(final_pair.get("slot_token", -1)) \
		and int(target.source_epoch) == int(final_pair.get("source_epoch", -1)) \
		and int(target.frame_id) == int(final_pair.get("frame_id", -1)) \
		and int(target.pts_us) == int(final_pair.get("pts_us", -1)) \
		and (not alpha_requested or final_pair.get("inference_ran", false))

func _process(_delta: float) -> void:
	if _audio_pending:
		set_audio_options(audio_track_id, audio_volume, audio_muted)
	elif prefer_clone_voice and not _clone_applied and clone_voice_track() > 0:
		_clone_applied = set_audio_options(clone_voice_track(), audio_volume, audio_muted)
	if panel and geometry != Geometry.Geometry.FLAT:
		_center_on_view()
	if not _pending_revision.is_empty():
		_try_revision()
	_present_pending()
	_maybe_capture_thumbnail()
	_poll_subtitles()
	if _can_loop():
		seek_absolute(0)

func _exit_tree() -> void:
	close_video()
	if is_instance_valid(caption) and caption.get_parent() != self:
		caption.queue_free()
