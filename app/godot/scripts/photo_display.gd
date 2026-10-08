extends "res://scripts/media_surface.gd"
signal changed
const Info := preload("res://scripts/image_info.gd")
const Naming := preload("res://scripts/media_naming.gd")
const Thumbnails := preload("res://scripts/thumbnail_cache.gd")
const ModeMemory := preload("res://scripts/file_mode_memory.gd")
const SHADER := preload("res://shaders/photo.gdshader")
const Methods := preload("res://scripts/platform_methods.gd")
const CACHE_IMAGE_BYTES := 32 * 1024 * 1024
var _prefetched := {}
var _prefetch_failed := {}
var _prefetch_request := 0
var _prefetch_sequence := 0
var _prefetch_decode := {}
var _cache_epoch := 0
var _display_info := {}
var _display_result := {}
var _requested_direction := 0
var _deferred_release_ids := {}
var _pending_display := {}
var _display_depth_data := {}
var _prefetch_depth_request := 0
var platform: Object
var catalog: RefCounted
var history_enabled := true
var local_uri := ""
var display_name := ""
var queue: Array[Dictionary] = []
var index := -1
var pending_index := -1
var error := ""
var loading := false
var inspect := false
var magnification := 1.0
var crop_center := Vector2(0.5, 0.5)
var depth_requested := false
var auto_depth := false # User choice survives image navigation and incompatible source modes.
var depth_enabled := false
var depth_strength := 1.0
const DepthStrength := preload("res://scripts/depth_strength.gd")
var depth_error := ""
var _depth_busy := false
var _depth_texture: ImageTexture
var _stereo_texture: ImageTexture
var _depth_thread: Thread
var _depth_job := {}
var _depth_queue: Array[Dictionary] = []
var _depth_rebuild_seconds := 0.0
var _depth_rect := Vector4(0, 0, 1, 1)
var _texture: ImageTexture
var _size := Vector2(1920, 1080)
var _metadata := {}
var _request := 0
var _display_request := 0
var _serial := 0
var _thread: Thread
var _next_decode := {}
var _decoding := {}
var _detail: MeshInstance3D
var _detail_material: ShaderMaterial
var _detail_zoom: Label3D
var _detail_direction := Vector3.FORWARD
var mode_memory := ModeMemory.new("user://photo_settings")
var mode_lock := {} # Independent of the video lock; used for unmarked, unremembered photos.

const DEFAULT_CURVE := 0.35
const IMMERSIVE_SIZE := Vector2(3.8, 2.6)
const SOFT_EDGE_METRES := 0.07
const TRANSITION_SECONDS := 0.24
var _departing: MeshInstance3D
var _transition_time := 0.0
var _transition_direction := 0
var _departing_pose := Transform3D.IDENTITY
var _transition_width := 0.0

func _init() -> void:
	screen_curve = DEFAULT_CURVE

func _screen_dimensions(aspect: float) -> Vector2:
	var width := minf(IMMERSIVE_SIZE.x, IMMERSIVE_SIZE.y * aspect)
	return Vector2(width, width / aspect)

func _curve_radius() -> float:
	# Keep the edges in front even when a large photo reaches the shared arc limit.
	return maxf(super._curve_radius(), _flat.size.x * _flat.size.x / (4.0 * screen_distance))

func _shape_screen() -> void:
	super._shape_screen()
	if material:
		material.set_shader_parameter("edge_feather", Vector2.ONE * SOFT_EDGE_METRES / _flat.size)

func hand_zoomed() -> bool:
	return inspect or screen_scale > 1.05

func set_hand_scale(value: float) -> void:
	if inspect:
		magnification = clampf(value, 1.0, 8.0)
		if magnification <= 1.01: reset_view()
		else: _update_inspect()
	else:
		set_screen_scale(value)
	changed.emit()

func pan_hand(step: Vector2) -> void:
	if inspect:
		pan_content(Vector2(-step.x, step.y) * 2.5)
	else:
		# Translate within the photo's plane; do not orbit a magnified photo round the head.
		flat_pose.origin += flat_pose.basis * Vector3(step.x, step.y, 0) * 3.0
		panel.transform = flat_pose

func _ready() -> void:
	initialize_surface(SHADER)
	mode_memory.load_saved()
	_detail = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.8, 0.5)
	_detail.mesh = quad
	_detail_material = ShaderMaterial.new()
	_detail_material.shader = SHADER
	_detail_material.render_priority = 2
	_detail.material_override = _detail_material
	_detail.visible = false
	add_child(_detail)
	var border := MeshInstance3D.new()
	var border_mesh := QuadMesh.new()
	border_mesh.size = Vector2(0.814, 0.514)
	border.mesh = border_mesh
	var border_material := StandardMaterial3D.new()
	border_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	border_material.albedo_color = Color(0.08, 0.24, 0.2)
	border_material.render_priority = 1
	border.material_override = border_material
	border.position.z = -0.002
	_detail.add_child(border)
	_detail_zoom = Label3D.new()
	_detail_zoom.font_size = 19
	_detail_zoom.pixel_size = 0.0012
	_detail_zoom.position = Vector3(0.35, -0.274, 0.003)
	_detail_zoom.render_priority = 3
	_detail.add_child(_detail_zoom)
	if OS.get_name() == "Android" and Engine.has_singleton("QuestPlayer"):
		platform = Engine.get_singleton("QuestPlayer")
		platform.connect("photo_ready", _on_ready)
		platform.connect("photo_depth", _on_depth)
		if platform.has_signal("photo_preload_depth"): platform.connect("photo_preload_depth", _on_prefetch_depth)
	_apply_geometry()

func _source_size() -> Vector2:
	return _size

func open_image(uri: String, title: String, entries: Array = []) -> bool:
	close_image()
	queue.clear()
	for entry in entries:
		if entry is Dictionary and not str(entry.get("uri", "")).is_empty() and (entry.get("kind") == "image" or Info.is_image(str(entry.uri), str(entry.get("title", "")))):
			queue.append(entry.duplicate(true))
	var target := -1
	for i in queue.size():
		if queue[i].uri == uri: target = i; break
	if target < 0:
		queue = [{"uri": uri, "title": title, "kind": "image"}]
		target = 0
	index = -1
	return _select(target)

func navigate(direction: int) -> bool:
	if queue.size() <= 1 or direction == 0: return false
	var target := (pending_index if pending_index >= 0 else index) + direction
	if geometry == Geometry.Geometry.FLAT: target = posmod(target, queue.size())
	return _select(target, 1 if direction > 0 else -1)

func _select(target: int, direction: int = 0) -> bool:
	if target < 0 or target >= queue.size(): return false
	if target == index and not loading: return false
	finish_transition()
	var cached: Dictionary = _prefetched.get(target, {})
	_pause_prefetch(int(cached.get("id", 0)) if cached.has("info") else 0)
	_serial += 1
	_pending_display = {}
	_depth_busy = false
	if not depth_enabled: depth_requested = false
	_next_decode = {}
	if platform and _request > 0 and _request != _display_request: _release_photo(_request, true)
	if target == index and _cache_supported():
		if platform: platform.activate_photo(_display_request)
		_request = _display_request; pending_index = -1; loading = false; error = ""
		changed.emit()
		return true
	pending_index = target
	_requested_direction = direction if direction != 0 else (1 if target > index else -1)
	loading = true
	error = ""
	var item := queue[target]
	if cached.has("info") and (not platform or platform.activate_photo(int(cached.id))):
		_prefetched.erase(target)
		_request = int(cached.id)
		var job := {"id": _request, "serial": _serial, "index": target, "info": cached.info, "direction": _requested_direction,
			"depth_data": cached.get("depth_data", {})}
		if cached.get("result", {}).has("image"): _prepare_display(cached.result, job)
		else: _next_decode = job
		changed.emit()
		return true
	if not cached.is_empty(): _drop_prefetch(target)
	_request = platform.open_photo(str(item.uri)) if platform else _serial
	if _request <= 0:
		loading = false; error = "Image unavailable"; changed.emit(); return false
	if not platform:
		var path := str(item.uri).trim_prefix("file://").uri_decode()
		if not path.is_absolute_path():
			loading = false; error = "Image unavailable"; changed.emit(); return false
		_on_ready(_request, JSON.stringify({"state": "ready", "path": path}))
	changed.emit()
	return true

func _on_ready(id: int, payload: String) -> void:
	if id == _prefetch_request and id != 0:
		_prefetch_request = 0
		for target in _prefetched:
			if int(_prefetched[target].id) != id: continue
			var ready: Variant = JSON.parse_string(payload)
			if ready is Dictionary and ready.get("state") == "ready": _prefetched[target]["info"] = ready
			else:
				_prefetch_failed[target] = true
				_drop_prefetch(target)
			return
	if id != _request or not loading:
		if platform: _release_photo(id)
		return
	var info: Variant = JSON.parse_string(payload)
	if not info is Dictionary or info.get("state") != "ready":
		loading = false
		error = "Image too large" if info is Dictionary and info.get("error") == "PHOTO_TOO_LARGE" else "Image unavailable"
		changed.emit(); return
	_next_decode = {"id": id, "serial": _serial, "index": pending_index, "info": info, "direction": _requested_direction}

static func _decode(job: Dictionary) -> Dictionary:
	var path := str(job.info.path)
	var header := Info.read_header(path)
	if header.is_empty(): return {"error": "Image unavailable"}
	if int(header.width) > 8192 or int(header.height) > 8192 or int(header.width) * int(header.height) > 32 * 1024 * 1024:
		return {"error": "Image too large"}
	if job.get("prefetch", false):
		var estimate := int(header.width) * int(header.height) * (3 if header.codec == "jpg" else 4) * 4 / 3
		if estimate > CACHE_IMAGE_BYTES:
			var small := str(job.info.get("thumbnail_path", ""))
			if not small.is_empty():
				var thumbnail := Image.new()
				if thumbnail.load_jpg_from_buffer(FileAccess.get_file_as_bytes(small)) == OK:
					Info.orient(thumbnail, int(job.info.get("orientation", 1)))
					return {"uncached": true, "thumbnail": thumbnail}
			return {"uncached": true}
	var image := Image.new()
	var bytes := FileAccess.get_file_as_bytes(path)
	var code := image.load_jpg_from_buffer(bytes) if header.codec == "jpg" else (image.load_png_from_buffer(bytes) if header.codec == "png" else image.load_webp_from_buffer(bytes))
	if code != OK or image.is_empty(): return {"error": "Image unavailable"}
	var info: Dictionary = header.duplicate(true)
	info.merge(job.info, true)
	Info.orient(image, int(info.get("orientation", 1)))
	var thumbnail := image.duplicate() as Image
	var ratio := 384.0 / maxf(image.get_width(), image.get_height())
	thumbnail.resize(maxi(1, int(image.get_width() * ratio)), maxi(1, int(image.get_height() * ratio)), Image.INTERPOLATE_BILINEAR)
	# Mipmaps improve stability when the source is much larger than its angular screen size.
	image.generate_mipmaps()
	return {"image": image, "thumbnail": thumbnail, "info": info}

func _process(delta: float) -> void:
	_process_depth_jobs()
	if _depth_rebuild_seconds > 0:
		_depth_rebuild_seconds = maxf(0, _depth_rebuild_seconds - delta)
		if _depth_rebuild_seconds == 0 and depth_requested and _display_request > 0:
			_depth_busy = _prepare_depth(_display_request)
	if _thread and not _thread.is_alive():
		var result: Dictionary = _thread.wait_to_finish()
		_thread = null
		if _decoding.get("prefetch", false):
			if int(_decoding.id) == _request and loading and result.has("image"):
				var job: Dictionary = _next_decode.duplicate()
				job.merge({"id": _request, "serial": _serial, "index": pending_index, "direction": _requested_direction}, true)
				_next_decode = {}
				_prepare_display(result, job)
			elif int(_decoding.epoch) == _cache_epoch and _prefetched.has(int(_decoding.index)) \
				and int(_prefetched[int(_decoding.index)].id) == int(_decoding.id):
				var entry: Dictionary = _prefetched[int(_decoding.index)]
				entry["decoded"] = true
				if result.has("image") and result.image.get_data().size() <= CACHE_IMAGE_BYTES: entry["result"] = result
				if result.has("thumbnail") and Thumbnails.store(str(queue[int(_decoding.index)].uri), result.thumbnail):
					result["thumbnail_cached"] = true
		elif _decoding.serial == _serial and _decoding.id == _request:
			_prepare_display(result, _decoding)
		elif platform and int(_decoding.id) != _display_request:
			_release_photo(int(_decoding.id))
		if _deferred_release_ids.erase(int(_decoding.id)) and int(_decoding.id) not in [_request, _display_request]:
			_release_photo(int(_decoding.id))
		_decoding = {}
	if not _thread and (not _next_decode.is_empty() or not _prefetch_decode.is_empty()):
		var foreground := not _next_decode.is_empty()
		_decoding = _next_decode if foreground else _prefetch_decode
		if foreground: _next_decode = {}
		else: _prefetch_decode = {}
		_thread = Thread.new()
		var code := _thread.start(_decode.bind(_decoding))
		if code != OK:
			_thread = null
			if foreground: loading = false; error = "Image unavailable"; changed.emit()
			else: _drop_prefetch(int(_decoding.index))
	if panel.visible and geometry != Geometry.Geometry.FLAT: _center_on_view()
	if is_instance_valid(_departing):
		_transition_time += delta
		_update_transition()
	if not loading and not is_instance_valid(_departing): _pump_prefetch()

func _cache_supported() -> bool:
	return not platform or (Methods.supports(platform, "preload_photo") and Methods.supports(platform, "activate_photo"))

func _release_photo(id: int, cancel: bool = false) -> void:
	if not platform: return
	if (_thread and int(_decoding.get("id", 0)) == id) or (_depth_thread and int(_depth_job.get("id", 0)) == id):
		# Do not unlink the decoder's source between reading its header and pixels.
		_deferred_release_ids[id] = true
	elif cancel: platform.cancel_photo(id)
	else: platform.release_photo(id)

func _neighbors(position: int) -> Array[int]:
	var result: Array[int] = []
	if queue.size() <= 1 or position < 0: return result
	for target in [posmod(position + 1, queue.size()), posmod(position - 1, queue.size())]:
		if target not in result and target != position: result.append(target)
	return result

func _drop_prefetch(target: int) -> void:
	if not _prefetched.has(target): return
	var id := int(_prefetched[target].id)
	_prefetched.erase(target)
	if _prefetch_request == id: _prefetch_request = 0
	if _prefetch_depth_request == id:
		if Methods.supports(platform, "cancel_preloaded_photo_depth"): platform.cancel_preloaded_photo_depth()
		_prefetch_depth_request = 0
	if not _prefetch_decode.is_empty() and int(_prefetch_decode.id) == id: _prefetch_decode = {}
	_release_photo(id, true)

func _pause_prefetch(except_id: int = 0) -> void:
	if _prefetch_depth_request != 0:
		if Methods.supports(platform, "cancel_preloaded_photo_depth"): platform.cancel_preloaded_photo_depth()
		_prefetch_depth_request = 0
	if _prefetch_request != 0 and _prefetch_request != except_id:
		for target in _prefetched.keys():
			if int(_prefetched[target].id) == _prefetch_request: _drop_prefetch(target)
	_prefetch_decode = {}

func _prune_prefetch() -> void:
	var wanted: Array = _neighbors(index) if geometry == Geometry.Geometry.FLAT and _cache_supported() else []
	for target in _prefetched.keys():
		if target not in wanted: _drop_prefetch(target)

func _pump_prefetch() -> void:
	_prune_prefetch()
	if index < 0 or geometry != Geometry.Geometry.FLAT or not _cache_supported(): return
	if _prefetch_depth_request != 0: return
	for target in _neighbors(index):
		if _prefetched.has(target):
			var entry: Dictionary = _prefetched[target]
			if entry.has("info") and not entry.get("decoded", false) and _prefetch_decode.is_empty() \
				and not (_decoding.get("prefetch", false) and int(_decoding.id) == int(entry.id)):
				_prefetch_decode = {"id": entry.id, "index": target, "info": entry.info, "prefetch": true, "epoch": _cache_epoch}
			if entry.has("info") and _requires_depth(target, entry.info) and not entry.has("depth_data") \
				and not entry.get("depth_failed", false) and _prefetch_request == 0 \
				and Methods.supports(platform, "prepare_preloaded_photo_depth"):
				_prefetch_depth_request = int(entry.id)
				if not _prepare_depth(_prefetch_depth_request, true):
					_prefetch_depth_request = 0; entry["depth_failed"] = true
				else: return
			continue
		if _prefetch_request != 0 or _prefetch_failed.has(target): continue
		var uri := str(queue[target].uri)
		_prefetch_sequence += 1
		var id: int = platform.preload_photo(uri) if platform else -_prefetch_sequence
		if platform and id <= 0: _prefetch_failed[target] = true; continue
		_prefetched[target] = {"id": id, "decoded": false}
		_prefetch_request = id
		if not platform:
			var path := uri.trim_prefix("file://").uri_decode()
			_on_ready(id, JSON.stringify({"state": "ready", "path": path}) if path.is_absolute_path() else '{"state":"error"}')

func _resolved_mode(target: int, info: Dictionary) -> Dictionary:
	var stated := Naming.from_name(str(queue[target].get("title", "")))
	var saved := mode_memory.lookup(str(queue[target].uri))
	var mode := {"geometry": int(saved.get("geometry", stated.get("geometry", Geometry.Geometry.EQUIRECT_360 if info.get("panorama", false) else Geometry.Geometry.FLAT))),
		"stereo_sbs": bool(saved.get("stereo_sbs", stated.get("stereo", false))),
		"top_bottom": bool(saved.get("top_bottom", stated.get("top_bottom", false))),
		"swap_eyes": bool(saved.get("swap_eyes", stated.get("swap", false))),
		"fisheye_fov": int(saved.get("fisheye_fov", stated.get("fisheye_fov", 180)))}
	if saved.is_empty() and not mode_lock.is_empty() and not stated.has("geometry") and not stated.has("stereo") and not info.get("panorama", false):
		mode.geometry = int(mode_lock.geometry)
		mode.stereo_sbs = int(mode_lock.layout) != 0
		mode.top_bottom = int(mode_lock.layout) == 2
		mode.fisheye_fov = int(mode_lock.fisheye_fov)
	return mode

func _requires_depth(target: int, info: Dictionary) -> bool:
	var mode := _resolved_mode(target, info)
	return auto_depth and platform != null and int(mode.geometry) == Geometry.Geometry.FLAT and not mode.stereo_sbs

func _prepare_display(result: Dictionary, job: Dictionary) -> void:
	if result.has("error") or not _requires_depth(int(job.index), result.info):
		_accept(result, job)
		return
	var depth_data: Dictionary = result.get("depth_data", job.get("depth_data", {}))
	if not depth_data.is_empty() and (not Methods.supports(platform, "prepare_photo_3d") or
		(depth_data.has("stereo_image") and is_equal_approx(float(depth_data.get("strength", -1)), depth_strength))):
		result["depth_data"] = depth_data
		_accept(result, job)
		return
	_pending_display = {"result": result, "job": job, "serial": _serial}
	if not _prepare_depth(int(job.id)): _fail_pending_depth()
	else: changed.emit()

func _fail_pending_depth() -> void:
	_pending_display = {}; loading = false; error = "3D unavailable"
	if _request != _display_request: _release_photo(_request, true)
	_request = _display_request
	changed.emit()

func _accept(result: Dictionary, job: Dictionary) -> void:
	loading = false
	if result.has("error"):
		error = str(result.error); changed.emit(); return
	var previous_index := index
	var previous_request := _display_request
	var previous_info := _display_info
	var previous_result := _display_result
	var previous_depth_data := _cache_depth(_display_depth_data)
	var previous_flat := _texture != null and geometry == Geometry.Geometry.FLAT and panel.visible
	var old_surface: MeshInstance3D
	if previous_flat:
		old_surface = MeshInstance3D.new()
		old_surface.mesh = panel.mesh.duplicate() as Mesh
		old_surface.material_override = material.duplicate() as ShaderMaterial
		old_surface.transform = panel.transform
	_display_request = int(job.id)
	index = int(job.index)
	pending_index = -1
	local_uri = str(queue[index].uri)
	display_name = str(queue[index].get("title", local_uri.get_file()))
	_metadata = result.info
	_texture = ImageTexture.create_from_image(result.image)
	_size = Vector2(result.image.get_width(), result.image.get_height())
	_depth_texture = null; _stereo_texture = null; depth_requested = false; depth_enabled = false; _depth_busy = false; depth_error = ""
	var mode := _resolved_mode(index, _metadata)
	geometry = int(mode.geometry); stereo_sbs = bool(mode.stereo_sbs)
	top_bottom = stereo_sbs and bool(mode.top_bottom); swap_eyes = bool(mode.swap_eyes); fisheye_fov = int(mode.fisheye_fov)
	_display_depth_data = result.get("depth_data", {}) if geometry == Geometry.Geometry.FLAT and not stereo_sbs else {}
	if not _display_depth_data.is_empty():
		_depth_texture = ImageTexture.create_from_image(_display_depth_data.image)
		_depth_rect = _display_depth_data.rect
		if _display_depth_data.has("stereo_image"): _stereo_texture = ImageTexture.create_from_image(_display_depth_data.stereo_image)
		depth_requested = auto_depth; depth_enabled = auto_depth
	_display_info = result.info
	_display_result = result if geometry == Geometry.Geometry.FLAT and result.image.get_data().size() <= CACHE_IMAGE_BYTES else {}
	_prefetch_failed.erase(index)
	if previous_flat and geometry == Geometry.Geometry.FLAT and previous_index in _neighbors(index) and _cache_supported() \
		and not previous_info.is_empty() and previous_request != _display_request:
		_drop_prefetch(previous_index)
		_prefetched[previous_index] = {"id": previous_request, "info": previous_info, "result": previous_result,
			"decoded": not previous_result.is_empty(), "depth_data": previous_depth_data} if not previous_depth_data.is_empty() else \
			{"id": previous_request, "info": previous_info, "result": previous_result, "decoded": not previous_result.is_empty()}
	elif platform and previous_request > 0 and previous_request != _display_request:
		_release_photo(previous_request)
	_prune_prefetch()
	reset_view()
	material.set_shader_parameter("photo_texture", _texture)
	_detail_material.set_shader_parameter("sharpness", sharpness)
	_detail_material.set_shader_parameter("photo_texture", _texture)
	_apply_geometry()
	panel.visible = true
	if previous_flat and geometry == Geometry.Geometry.FLAT and previous_index != index:
		_departing = old_surface
		_departing.material_override.render_priority = -11
		add_child(_departing)
		_departing_pose = _departing.transform
		_transition_direction = int(job.get("direction", 1 if index > previous_index else -1))
		_transition_width = _flat.size.x
		_transition_time = 0.0
		_update_transition()
	elif old_surface != null:
		old_surface.free()
	if auto_depth and geometry == 0 and not stereo_sbs: set_depth(true)
	if not result.get("thumbnail_cached", false) or not Thumbnails.has(local_uri):
		if Thumbnails.store(local_uri, result.thumbnail): result["thumbnail_cached"] = true
	if catalog and history_enabled:
		catalog.opened(local_uri, display_name, false, "image")
		catalog.save()
	changed.emit()

func _update_transition() -> void:
	var fraction := clampf(_transition_time / TRANSITION_SECONDS, 0.0, 1.0)
	var eased := fraction * fraction * (3.0 - 2.0 * fraction)
	var travel := Vector3.RIGHT * _transition_width * float(_transition_direction)
	panel.transform = flat_pose
	panel.position += flat_pose.basis * travel * (1.0 - eased)
	material.set_shader_parameter("presentation_opacity", eased)
	_departing.transform = _departing_pose
	_departing.position -= _departing_pose.basis * travel * eased
	_departing.material_override.set_shader_parameter("presentation_opacity", 1.0 - eased)
	if fraction >= 1.0: finish_transition()

func finish_transition() -> void:
	if is_instance_valid(_departing):
		_departing.free()
		_departing = null
		panel.transform = flat_pose
	if material: material.set_shader_parameter("presentation_opacity", 1.0)

func _apply_geometry() -> void:
	if geometry != Geometry.Geometry.FLAT: finish_transition()
	super._apply_geometry()
	if not _detail_material: return
	for target in [material, _detail_material]:
		target.set_shader_parameter("source_size", _size)
		target.set_shader_parameter("video_geometry", geometry)
		target.set_shader_parameter("stereo_sbs", stereo_sbs)
		target.set_shader_parameter("top_bottom", top_bottom)
		target.set_shader_parameter("swap_eyes", swap_eyes)
		target.set_shader_parameter("fisheye_fov", float(fisheye_fov))
		target.set_shader_parameter("pano_rect", Info.panorama_rect(_metadata))
		target.set_shader_parameter("photo_depth", depth_enabled and not stereo_sbs and geometry == Geometry.Geometry.FLAT)
		target.set_shader_parameter("depth_strength", depth_strength)
		target.set_shader_parameter("depth_texture", _depth_texture)
		target.set_shader_parameter("depth_rect", _depth_rect)
		target.set_shader_parameter("photo_stereo", depth_enabled and _stereo_texture != null and not stereo_sbs and geometry == Geometry.Geometry.FLAT)
		target.set_shader_parameter("stereo_texture", _stereo_texture)
		target.set_shader_parameter("generated_size", Vector2(_stereo_texture.get_width() / 2.0, _stereo_texture.get_height()) if _stereo_texture else Vector2.ONE)
	_update_inspect()

func set_projection(value: int) -> void:
	if value not in [0, 1, 2, 3]: return
	geometry = value
	if value != 0: depth_requested = false; depth_enabled = false
	elif auto_depth and not stereo_sbs: set_depth(true)
	reset_view(); _apply_geometry(); _remember_mode(); changed.emit()

func cycle_projection() -> void:
	set_projection((geometry + 1) % 4)

func set_stereo_layout(layout: int) -> void:
	stereo_sbs = layout != 0; top_bottom = layout == 2
	if stereo_sbs: depth_requested = false; depth_enabled = false
	elif auto_depth and geometry == 0: set_depth(true)
	_apply_geometry(); _remember_mode(); changed.emit()

func toggle_stereo() -> void:
	set_stereo_layout(0 if stereo_sbs else 1)

func toggle_eye_order() -> bool:
	if not stereo_sbs: return false
	swap_eyes = not swap_eyes; _apply_geometry(); _remember_mode(); changed.emit(); return true

func set_fisheye_fov(value: int) -> void:
	if value in FISHEYE_FOVS: fisheye_fov = value; _apply_geometry(); _remember_mode(); changed.emit()

func _remember_mode() -> void:
	if local_uri.is_empty(): return
	mode_memory.remember(local_uri, {"geometry": geometry, "stereo_sbs": stereo_sbs, "top_bottom": top_bottom, "swap_eyes": swap_eyes,
		"fisheye_fov": fisheye_fov, "profile": "320x320", "alpha_requested": false})
	mode_memory.save()

func current_lock() -> Dictionary:
	return {"geometry": geometry, "layout": 2 if top_bottom else (1 if stereo_sbs else 0),
		"depth": depth_requested and not stereo_sbs, "fisheye_fov": fisheye_fov}

func toggle_mode_lock() -> void:
	var current := current_lock()
	mode_lock = {} if mode_lock == current else current
	changed.emit()

func load_mode_lock(value: Variant) -> void:
	mode_lock = {}
	if not value is Dictionary or not value.get("depth") is bool: return
	for key in ["geometry", "layout", "fisheye_fov"]:
		var number: Variant = value.get(key)
		if not (number is int or number is float) or not is_finite(float(number)) or float(number) != floorf(float(number)): return
	if int(value.geometry) not in [0, 1, 2, 3] or int(value.layout) not in [0, 1, 2] or int(value.fisheye_fov) not in FISHEYE_FOVS: return
	mode_lock = {"geometry": int(value.geometry), "layout": int(value.layout),
		"depth": bool(value.depth) and int(value.layout) == 0 and int(value.geometry) == 0, "fisheye_fov": int(value.fisheye_fov)}

func toggle_inspect() -> void:
	inspect = not inspect
	magnification = 2.0 if inspect else 1.0
	if inspect and geometry != Geometry.Geometry.FLAT: _place_detail()
	_update_inspect(); changed.emit()

func _place_detail() -> void:
	var pose := view_camera.global_transform if view_camera else Transform3D(Basis(), Vector3(0, 1.6, 0))
	_detail.global_transform = pose * Transform3D(Basis(), Vector3(0.42, 0.22, -1.4))
	_detail_direction = panel.global_basis.inverse() * -pose.basis.z

func reset_view() -> void:
	super.reset_view()
	inspect = false; magnification = 1.0; crop_center = Vector2(0.5, 0.5)
	if _detail_material: _update_inspect()

func zoom_view(amount: float) -> void:
	if not inspect:
		inspect = true
		if geometry != Geometry.Geometry.FLAT: _place_detail()
	magnification = clampf(magnification * exp(amount * 2.0), 1.0, 8.0)
	_update_inspect(); changed.emit()

## The right stick scales the whole flat photo, including its mesh and corner hit targets.
## The explicit inspect controls still magnify a crop; panoramas use their detail window.
func zoom_picture(amount: float) -> void:
	if geometry != Geometry.Geometry.FLAT:
		zoom_view(amount)
		return
	set_screen_scale(screen_scale * exp(amount * 2.0))
	changed.emit()

func inspect_ray(origin: Vector3, direction: Vector3, drag: bool = false) -> bool:
	if not inspect or not panel.visible: return false
	if geometry == Geometry.Geometry.FLAT:
		var uv := _inspect_uv(origin, direction)
		if not Rect2(0, 0, 1, 1).has_point(uv): return false
		if not drag: crop_center += (uv - Vector2(0.5, 0.5)) / magnification
	else:
		_detail_direction = (panel.global_basis.inverse() * direction).normalized()
	_update_inspect(); return true

func _inspect_uv(origin: Vector3, direction: Vector3) -> Vector2:
	if screen_curve <= 0.0:
		var point: Variant = screen_point(origin, direction)
		return Vector2(-1, -1) if point == null else Vector2(point.x / _flat.size.x + 0.5, 0.5 - point.y / _flat.size.y)
	var inverse := panel.global_transform.affine_inverse()
	var start := inverse * origin
	var ray := (inverse.basis * direction).normalized()
	var radius := _curve_radius()
	var a := ray.x * ray.x + ray.z * ray.z
	var b := 2.0 * (start.x * ray.x + (start.z - radius) * ray.z)
	var c := start.x * start.x + pow(start.z - radius, 2) - radius * radius
	var discriminant := b * b - 4.0 * a * c
	if a < 0.000001 or discriminant < 0: return Vector2(-1, -1)
	for distance in [(-b - sqrt(discriminant)) / (2 * a), (-b + sqrt(discriminant)) / (2 * a)]:
		if distance <= 0: continue
		var hit: Vector3 = start + ray * distance
		var uv := Vector2(0.5 + atan2(hit.x, radius - hit.z) * radius / _flat.size.x, 0.5 - hit.y / _flat.size.y)
		if Rect2(0, 0, 1, 1).has_point(uv): return uv
	return Vector2(-1, -1)

func pan_content(step: Vector2) -> void:
	if not inspect or geometry != 0: return
	crop_center += Vector2(step.x, -step.y) / magnification
	_update_inspect()

func _update_inspect() -> void:
	var half := 0.5 / magnification
	crop_center = crop_center.clamp(Vector2(half, half), Vector2(1.0 - half, 1.0 - half))
	material.set_shader_parameter("crop_center", crop_center if inspect else Vector2(0.5, 0.5))
	material.set_shader_parameter("content_zoom", magnification if inspect and geometry == 0 else 1.0)
	_detail.visible = inspect and geometry != 0 and panel.visible
	_detail_zoom.text = "%.1f×" % magnification
	_detail_material.set_shader_parameter("detail_projection", true)
	_detail_material.set_shader_parameter("content_zoom", magnification)
	var forward := _detail_direction.normalized()
	var right := forward.cross(Vector3.UP).normalized()
	if right.length_squared() < 0.001: right = Vector3.RIGHT
	_detail_material.set_shader_parameter("detail_forward", forward)
	_detail_material.set_shader_parameter("detail_right", right)
	_detail_material.set_shader_parameter("detail_up", right.cross(forward).normalized())

func set_depth(enabled: bool) -> bool:
	if enabled and (stereo_sbs or geometry != 0 or not platform or _display_request <= 0): return false
	auto_depth = enabled
	depth_requested = enabled
	depth_enabled = enabled and _depth_texture != null and (not Methods.supports(platform, "prepare_photo_3d") or _stereo_texture != null)
	depth_error = ""
	if enabled and (not depth_enabled or (Methods.supports(platform, "prepare_photo_3d") and
		 not is_equal_approx(float(_display_depth_data.get("strength", -1)), depth_strength))) and not _depth_busy:
		_depth_busy = _prepare_depth(_display_request)
		if not _depth_busy: depth_error = "3D unavailable"
	_apply_geometry(); changed.emit(); return true

func _on_prefetch_depth(id: int, payload: String) -> void:
	if _queue_depth_payload(id, payload, true): return
	_finish_depth(id, _read_depth(payload), true)

func _prepare_depth(id: int, background: bool = false) -> bool:
	if not background: _depth_rebuild_seconds = 0.0
	var method := "prepare_preloaded_photo_3d" if background else "prepare_photo_3d"
	if Methods.supports(platform, method): return bool(platform.call(method, id, depth_strength))
	method = "prepare_preloaded_photo_depth" if background else "prepare_photo_depth"
	return Methods.supports(platform, method) and bool(platform.call(method, id))

static func _cache_depth(data: Dictionary) -> Dictionary:
	var cached := data.duplicate()
	if cached.has("stereo_image") and cached.stereo_image.get_data().size() > CACHE_IMAGE_BYTES: cached.erase("stereo_image")
	return cached

func _queue_depth_payload(id: int, payload: String, background: bool) -> bool:
	var info: Variant = JSON.parse_string(payload)
	if not info is Dictionary or not info.has("stereo_path"): return false
	# At most one queued result per source; PNG decoding and mip generation run off the frame thread.
	_depth_queue = _depth_queue.filter(func(job): return int(job.id) != id)
	_depth_queue.append({"id":id, "payload":payload, "background":background, "serial":_serial})
	return true

func _process_depth_jobs() -> void:
	if _depth_thread and not _depth_thread.is_alive():
		var data: Dictionary = _depth_thread.wait_to_finish()
		_depth_thread = null
		var id := int(_depth_job.id)
		if bool(_depth_job.background) or int(_depth_job.serial) == _serial: _finish_depth(id, data, bool(_depth_job.background))
		_depth_job = {}
		if _deferred_release_ids.erase(id) and id not in [_request, _display_request]: _release_photo(id)
	if _depth_thread: return
	while not _depth_queue.is_empty():
		var job: Dictionary = _depth_queue.pop_front()
		if bool(job.background):
			if int(job.id) != _prefetch_depth_request: continue
		elif int(job.serial) != _serial or int(job.id) not in [_request, _display_request]: continue
		_depth_job = job
		_depth_thread = Thread.new()
		if _depth_thread.start(_read_depth.bind(str(job.payload))) != OK:
			_depth_thread = null; _finish_depth(int(job.id), {}, bool(job.background)); _depth_job = {}
		break

func _finish_depth(id: int, data: Dictionary, background: bool) -> void:
	if not background and id != _display_request and id != int(_pending_display.get("job", {}).get("id", 0)): return
	if not background and data.has("strength") and not is_equal_approx(float(data.strength), depth_strength):
		_depth_busy = _prepare_depth(id)
		return
	if background:
	# A cancelled background error must not fail a foreground retry of the same file ID.
		if id != _prefetch_depth_request or id == 0: return
		_prefetch_depth_request = 0
		for target in _prefetched:
			if int(_prefetched[target].id) != id: continue
			if data.is_empty(): _prefetched[target]["depth_failed"] = true
			else: _prefetched[target]["depth_data"] = _cache_depth(data)
			return
		return
	if not _pending_display.is_empty() and int(_pending_display.job.id) == id and int(_pending_display.serial) == _serial:
		if data.is_empty(): _fail_pending_depth(); return
		var pending := _pending_display; _pending_display = {}
		pending.result["depth_data"] = data
		_accept(pending.result, pending.job)
		return
	if id != _display_request: return
	_depth_busy = false
	if data.is_empty(): depth_error = "3D unavailable"; changed.emit(); return
	_display_depth_data = data
	if not _display_result.is_empty(): _display_result["depth_data"] = data
	_depth_texture = ImageTexture.create_from_image(data.image)
	_depth_rect = data.rect
	_stereo_texture = ImageTexture.create_from_image(data.stereo_image) if data.has("stereo_image") else null
	depth_enabled = depth_requested and geometry == 0 and not stereo_sbs
	_apply_geometry(); changed.emit()

func _on_depth(id: int, payload: String) -> void:
	if _queue_depth_payload(id, payload, false): return
	_finish_depth(id, _read_depth(payload), false)

static func _read_depth(payload: String) -> Dictionary:
	var result: Variant = JSON.parse_string(payload)
	if not result is Dictionary or result.get("state") != "ready": return {}
	var w := int(result.get("width", 0)); var h := int(result.get("height", 0))
	var rect: Variant = result.get("rect")
	# Accept the independent photo model and legacy cached/test depth, with bounded allocation.
	if Vector2i(w, h) not in [Vector2i(518, 518), Vector2i(252, 140)] or not rect is Array or rect.size() != 4: return {}
	for value in rect:
		if not (value is float or value is int) or not is_finite(float(value)): return {}
	if rect[0] < 0 or rect[1] < 0 or rect[2] <= 0 or rect[3] <= 0 or rect[0] + rect[2] > 1.000001 or rect[1] + rect[3] > 1.000001: return {}
	if not FileAccess.file_exists(str(result.get("path", ""))): return {}
	var bytes := FileAccess.get_file_as_bytes(str(result.path))
	if bytes.size() != w * h * 4: return {}
	var depth := Image.create_from_data(w, h, false, Image.FORMAT_RF, bytes)
	var data := {"image": depth, "rect": Vector4(rect[0], rect[1], rect[2], rect[3])}
	if result.has("stereo_path"):
		if not (result.get("stereo_strength") is float or result.get("stereo_strength") is int): return {}
		var strength := float(result.get("stereo_strength", -1))
		var sw := int(result.get("stereo_width", 0)); var sh := int(result.get("stereo_height", 0))
		if result.get("stereo_strategy", "") != "video_soft_shift_gpu" or not is_finite(strength) or strength < 0 or strength > 2 \
			or sw < 2 or sw % 2 != 0 or sw > 8192 or sh < 1 or sh > 4096 or sw * sh > 16 * 1024 * 1024: return {}
		var stereo := Image.new()
		var header := Info.read_header(str(result.stereo_path))
		if header.is_empty() or int(header.width) != sw or int(header.height) != sh: return {}
		if stereo.load_png_from_buffer(FileAccess.get_file_as_bytes(str(result.stereo_path))) != OK or stereo.get_size() != Vector2i(sw, sh): return {}
		stereo.generate_mipmaps()
		data.merge({"stereo_image":stereo, "strength":strength, "strategy":str(result.stereo_strategy)})
	return data

func cycle_depth_strength() -> void:
	set_depth_strength(0.5 if depth_strength >= DepthStrength.PHOTO_MAX else depth_strength + 0.5)

func set_depth_strength(value: float) -> bool:
	var strength := DepthStrength.clamp_value(value, DepthStrength.PHOTO_MAX)
	if strength <= 0.0: return set_depth(false)
	if stereo_sbs or geometry != 0 or not platform or _display_request <= 0: return false
	depth_strength = strength
	if not depth_requested: return set_depth(true)
	# Reuse the same depth map; no decoding, model call or mesh rebuild during a drag.
	material.set_shader_parameter("depth_strength", depth_strength)
	_detail_material.set_shader_parameter("depth_strength", depth_strength)
	if Methods.supports(platform, "prepare_photo_3d"): _depth_rebuild_seconds = 0.15
	changed.emit()
	return true

func snapshot() -> Dictionary:
	var position := pending_index if pending_index >= 0 else index
	var title := str(queue[position].get("title", "")) if position >= 0 and position < queue.size() else display_name
	return {"has_image": _texture != null, "loading": loading, "preparing_depth": not _pending_display.is_empty(), "title": title, "index": position, "count": queue.size(),
		"can_background": can_background(),
		"can_previous": queue.size() > 1 and (geometry == Geometry.Geometry.FLAT or position > 0),
		"can_next": queue.size() > 1 and (geometry == Geometry.Geometry.FLAT or (position >= 0 and position < queue.size() - 1)),
		"geometry": geometry, "stereo": stereo_sbs, "top_bottom": top_bottom, "swap_eyes": swap_eyes, "fisheye_fov": fisheye_fov, "mode_lock": mode_lock.duplicate(),
		"inspect": inspect, "zoom": magnification, "depth_requested": depth_requested, "depth_enabled": depth_enabled,
		"depth_available": platform != null, "depth_strength": depth_strength, "depth_error": depth_error,
		"stereo_strategy":_display_depth_data.get("strategy", "inverse_shader"), "stereo_ready":_stereo_texture != null,
		"render_strength":_display_depth_data.get("strength", depth_strength),
		"source_size": "%d × %d" % [int(_size.x), int(_size.y)], "error": error, "screen_curve": screen_curve}

func can_background() -> bool:
	return _texture != null and not loading and error.is_empty() and geometry == Geometry.Geometry.EQUIRECT_360 and not stereo_sbs \
		and absf(_size.x / _size.y - 2.0) < 0.02 and Info.panorama_rect(_metadata).is_equal_approx(Vector4(0,0,1,1))

func background_source() -> Dictionary:
	return {"path": _metadata.get("path", ""), "orientation": _metadata.get("orientation", 1)} if can_background() else {}

func close_image(notify: bool = true) -> void:
	finish_transition()
	_cache_epoch += 1
	_pause_prefetch()
	for target in _prefetched.keys(): _drop_prefetch(target)
	_prefetch_decode = {}; _prefetch_request = 0; _prefetch_failed.clear()
	_display_info = {}; _display_result = {}
	_pending_display = {}; _display_depth_data = {}
	_depth_queue.clear(); _depth_rebuild_seconds = 0.0
	_serial += 1
	if platform:
		if _request > 0: _release_photo(_request, true)
		if _display_request > 0: _release_photo(_display_request)
	_request = 0; _display_request = 0; _next_decode = {}
	_texture = null; _depth_texture = null; _stereo_texture = null; _depth_busy = false; depth_requested = false; depth_enabled = false
	material.set_shader_parameter("photo_texture", null); material.set_shader_parameter("depth_texture", null)
	_detail_material.set_shader_parameter("sharpness", sharpness)
	_detail_material.set_shader_parameter("photo_texture", null); _detail_material.set_shader_parameter("depth_texture", null)
	for target in [material, _detail_material]:
		target.set_shader_parameter("stereo_texture", null); target.set_shader_parameter("photo_stereo", false)
	panel.visible = false; _detail.visible = false; loading = false; inspect = false
	local_uri = ""; display_name = ""; error = ""; index = -1; pending_index = -1
	if notify: changed.emit()

func _exit_tree() -> void:
	close_image(false)
	if _thread: _thread.wait_to_finish(); _thread = null
	if _depth_thread: _depth_thread.wait_to_finish(); _depth_thread = null
	for id in _deferred_release_ids: _release_photo(int(id))
	_deferred_release_ids.clear()
