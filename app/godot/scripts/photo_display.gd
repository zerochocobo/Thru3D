extends "res://scripts/media_surface.gd"
signal changed
const Info := preload("res://scripts/image_info.gd")
const Naming := preload("res://scripts/media_naming.gd")
const Thumbnails := preload("res://scripts/thumbnail_cache.gd")
const ModeMemory := preload("res://scripts/file_mode_memory.gd")
const SHADER := preload("res://shaders/photo.gdshader")
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
	return _select((pending_index if pending_index >= 0 else index) + direction)

func _select(target: int) -> bool:
	if target < 0 or target >= queue.size(): return false
	_serial += 1
	_depth_busy = false
	if not depth_enabled: depth_requested = false
	_next_decode = {}
	if platform and _request > 0 and _request != _display_request: platform.cancel_photo(_request)
	pending_index = target
	loading = true
	error = ""
	var item := queue[target]
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
	if id != _request or not loading:
		if platform: platform.release_photo(id)
		return
	var info: Variant = JSON.parse_string(payload)
	if not info is Dictionary or info.get("state") != "ready":
		loading = false
		error = "Image too large" if info is Dictionary and info.get("error") == "PHOTO_TOO_LARGE" else "Image unavailable"
		changed.emit(); return
	_next_decode = {"id": id, "serial": _serial, "index": pending_index, "info": info}

static func _decode(job: Dictionary) -> Dictionary:
	var path := str(job.info.path)
	var header := Info.read_header(path)
	if header.is_empty(): return {"error": "Image unavailable"}
	if int(header.width) > 8192 or int(header.height) > 8192 or int(header.width) * int(header.height) > 32 * 1024 * 1024:
		return {"error": "Image too large"}
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

func _process(_delta: float) -> void:
	if _thread and not _thread.is_alive():
		var result: Dictionary = _thread.wait_to_finish()
		_thread = null
		if _decoding.serial == _serial and _decoding.id == _request:
			_accept(result, _decoding)
		elif platform and int(_decoding.id) != _display_request:
			platform.release_photo(int(_decoding.id))
		_decoding = {}
	if not _thread and not _next_decode.is_empty():
		_decoding = _next_decode
		_next_decode = {}
		_thread = Thread.new()
		var code := _thread.start(_decode.bind(_decoding))
		if code != OK:
			_thread = null; loading = false; error = "Image unavailable"; changed.emit()
	if panel.visible and geometry != Geometry.Geometry.FLAT: _center_on_view()

func _accept(result: Dictionary, job: Dictionary) -> void:
	loading = false
	if result.has("error"):
		error = str(result.error); changed.emit(); return
	if platform and _display_request > 0 and _display_request != int(job.id): platform.release_photo(_display_request)
	_display_request = int(job.id)
	index = int(job.index)
	local_uri = str(queue[index].uri)
	display_name = str(queue[index].get("title", local_uri.get_file()))
	_metadata = result.info
	_texture = ImageTexture.create_from_image(result.image)
	_size = Vector2(result.image.get_width(), result.image.get_height())
	_depth_texture = null; depth_requested = false; depth_enabled = false; _depth_busy = false; depth_error = ""
	var stated := Naming.from_name(display_name)
	var saved := mode_memory.lookup(local_uri)
	geometry = int(saved.get("geometry", stated.get("geometry", Geometry.Geometry.EQUIRECT_360 if _metadata.get("panorama", false) else Geometry.Geometry.FLAT)))
	stereo_sbs = bool(saved.get("stereo_sbs", stated.get("stereo", false)))
	top_bottom = stereo_sbs and bool(saved.get("top_bottom", stated.get("top_bottom", false)))
	swap_eyes = bool(saved.get("swap_eyes", stated.get("swap", false)))
	fisheye_fov = int(saved.get("fisheye_fov", stated.get("fisheye_fov", 180)))
	if saved.is_empty() and not mode_lock.is_empty() and not stated.has("geometry") and not stated.has("stereo") and not _metadata.get("panorama", false):
		geometry = int(mode_lock.geometry)
		stereo_sbs = int(mode_lock.layout) != 0
		top_bottom = int(mode_lock.layout) == 2
		fisheye_fov = int(mode_lock.fisheye_fov)
	reset_view()
	material.set_shader_parameter("photo_texture", _texture)
	_detail_material.set_shader_parameter("photo_texture", _texture)
	_apply_geometry()
	panel.visible = true
	if auto_depth and geometry == 0 and not stereo_sbs: set_depth(true)
	Thumbnails.store(local_uri, result.thumbnail)
	if catalog and history_enabled:
		catalog.opened(local_uri, display_name, false, "image")
		catalog.save()
	changed.emit()

func _apply_geometry() -> void:
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
	depth_enabled = enabled and _depth_texture != null
	depth_error = ""
	if enabled and not depth_enabled and not _depth_busy:
		_depth_busy = platform.prepare_photo_depth(_display_request)
		if not _depth_busy: depth_error = "3D unavailable"
	_apply_geometry(); changed.emit(); return true

func _on_depth(id: int, payload: String) -> void:
	if id != _display_request: return
	_depth_busy = false
	var result: Variant = JSON.parse_string(payload)
	if not result is Dictionary or result.get("state") != "ready":
		depth_error = "3D unavailable"; changed.emit(); return
	var bytes := FileAccess.get_file_as_bytes(str(result.path))
	var w := int(result.width); var h := int(result.height)
	if w != 252 or h != 140 or bytes.size() != w * h * 4: return
	var depth := Image.create_from_data(w, h, false, Image.FORMAT_RF, bytes)
	_depth_texture = ImageTexture.create_from_image(depth)
	var rect: Array = result.rect
	_depth_rect = Vector4(rect[0], rect[1], rect[2], rect[3])
	depth_enabled = depth_requested and geometry == 0 and not stereo_sbs
	_apply_geometry(); changed.emit()

func cycle_depth_strength() -> void:
	set_depth_strength(0.5 if depth_strength >= DepthStrength.MAX else depth_strength + 0.5)

func set_depth_strength(value: float) -> bool:
	var strength := DepthStrength.clamp_value(value)
	if strength <= 0.0: return set_depth(false)
	if stereo_sbs or geometry != 0 or not platform or _display_request <= 0: return false
	depth_strength = strength
	if not depth_requested: return set_depth(true)
	# Reuse the same depth map; no decoding, model call or mesh rebuild during a drag.
	material.set_shader_parameter("depth_strength", depth_strength)
	_detail_material.set_shader_parameter("depth_strength", depth_strength)
	changed.emit()
	return true

func snapshot() -> Dictionary:
	var position := pending_index if pending_index >= 0 else index
	var title := str(queue[position].get("title", "")) if position >= 0 and position < queue.size() else display_name
	return {"has_image": _texture != null, "loading": loading, "title": title, "index": position, "count": queue.size(),
		"can_background": can_background(),
		"can_previous": position > 0, "can_next": position >= 0 and position < queue.size() - 1,
		"geometry": geometry, "stereo": stereo_sbs, "top_bottom": top_bottom, "swap_eyes": swap_eyes, "fisheye_fov": fisheye_fov, "mode_lock": mode_lock.duplicate(),
		"inspect": inspect, "zoom": magnification, "depth_requested": depth_requested, "depth_enabled": depth_enabled,
		"depth_available": platform != null, "depth_strength": depth_strength, "depth_error": depth_error,
		"source_size": "%d × %d" % [int(_size.x), int(_size.y)], "error": error, "screen_curve": screen_curve}

func can_background() -> bool:
	return _texture != null and not loading and error.is_empty() and geometry == Geometry.Geometry.EQUIRECT_360 and not stereo_sbs \
		and absf(_size.x / _size.y - 2.0) < 0.02 and Info.panorama_rect(_metadata).is_equal_approx(Vector4(0,0,1,1))

func background_source() -> Dictionary:
	return {"path": _metadata.get("path", ""), "orientation": _metadata.get("orientation", 1)} if can_background() else {}

func close_image(notify: bool = true) -> void:
	_serial += 1
	if platform:
		if _request > 0: platform.cancel_photo(_request)
		if _display_request > 0: platform.release_photo(_display_request)
	_request = 0; _display_request = 0; _next_decode = {}
	_texture = null; _depth_texture = null; _depth_busy = false; depth_requested = false; depth_enabled = false
	material.set_shader_parameter("photo_texture", null); material.set_shader_parameter("depth_texture", null)
	_detail_material.set_shader_parameter("photo_texture", null); _detail_material.set_shader_parameter("depth_texture", null)
	panel.visible = false; _detail.visible = false; loading = false; inspect = false
	local_uri = ""; display_name = ""; error = ""; index = -1; pending_index = -1
	if notify: changed.emit()

func _exit_tree() -> void:
	close_image(false)
	if _thread: _thread.wait_to_finish()
