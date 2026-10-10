extends RefCounted
## Pictures for library tiles. Played videos get a frame of the displayed picture (see capture).
## DLNA items prefer the cover their server offers, with the played frame as fallback. Nothing
## here opens or reads a video file. Settings > clear cache empties the directory.

const DIRECTORY := "user://thumbnails"
const SIZE := Vector2i(320, 180)
const SHADER_2D := preload("res://shaders/thumbnail.gdshader")
const SHADER_OES := preload("res://shaders/thumbnail_oes.gdshader")
const KEEP_TEXTURES := 96
const MAX_IMAGES := 256
const MAX_BYTES := 32 * 1024 * 1024

static var _textures: Dictionary = {} # file path -> ImageTexture, most recent last
static var _protected: Dictionary = {} # the current recent entries survive normal browsing

static func protect_keys(keys: Array) -> void:
	_protected.clear()
	for key in keys.slice(0, 32):
		if key is String and not key.is_empty(): _protected[path_for(key)] = true

static func path_for(key: String) -> String:
	return DIRECTORY.path_join(key.sha1_text() + ".jpg")

static func relocate(old_uri: String, new_uri: String) -> void:
	var old_path := path_for(old_uri)
	var new_path := path_for(new_uri)
	_textures.erase(old_path); _textures.erase(new_path)
	if FileAccess.file_exists(new_path): DirAccess.remove_absolute(new_path)
	if FileAccess.file_exists(old_path): DirAccess.rename_absolute(old_path, new_path)

static func has(key: String) -> bool:
	return not key.is_empty() and FileAccess.file_exists(path_for(key))

static func texture(key: String) -> Texture2D:
	if key.is_empty():
		return null
	var path := path_for(key)
	if _textures.has(path):
		var cached: Texture2D = _textures[path]
		_textures.erase(path)
		_textures[path] = cached
		return cached
	if not FileAccess.file_exists(path):
		return null
	var image := Image.load_from_file(path)
	if not image or image.is_empty():
		return null
	var loaded := ImageTexture.create_from_image(image)
	_textures[path] = loaded
	while _textures.size() > KEEP_TEXTURES:
		_textures.erase(_textures.keys()[0])
	return loaded

## Fills SIZE (centre crop, no bars) and stores it as the picture of [key].
static func store(key: String, image: Image) -> bool:
	if key.is_empty() or not image or image.is_empty():
		return false
	var picture := fit(image)
	DirAccess.make_dir_recursive_absolute(DIRECTORY)
	var path := path_for(key)
	_textures.erase(path)
	if picture.save_jpg(path, 0.85) != OK: return false
	prune(MAX_IMAGES, MAX_BYTES, path)
	return true

## Evict only generated SHA1 JPEG names inside the thumbnail directory.
static func prune(max_images: int = MAX_IMAGES, max_bytes: int = MAX_BYTES, keep: String = "") -> void:
	var dir := DirAccess.open(DIRECTORY)
	if not dir: return
	var records: Array[Dictionary] = []
	var count := 0
	var bytes := 0
	for name in dir.get_files():
		if name.length() != 44 or not name.ends_with(".jpg") or not name.get_basename().is_valid_hex_number(): continue
		var path := DIRECTORY.path_join(name)
		var file := FileAccess.open(path, FileAccess.READ)
		if not file: continue
		var size := file.get_length()
		file.close()
		count += 1; bytes += size
		if path != keep and not _protected.has(path):
			records.append({"name": name, "bytes": size, "time": FileAccess.get_modified_time(path)})
	records.sort_custom(func(a: Dictionary, b: Dictionary): return a.time < b.time if a.time != b.time else str(a.name) < str(b.name))
	for record in records:
		if count <= max_images and bytes <= max_bytes: break
		if dir.remove(str(record.name)) == OK:
			count -= 1; bytes -= int(record.bytes)
			_textures.erase(DIRECTORY.path_join(str(record.name)))

static func fit(image: Image) -> Image:
	var picture := image.duplicate() as Image
	if picture.is_compressed():
		picture.decompress()
	picture.convert(Image.FORMAT_RGB8)
	var scale := maxf(float(SIZE.x) / picture.get_width(), float(SIZE.y) / picture.get_height())
	var scaled := Vector2i(maxi(SIZE.x, ceili(picture.get_width() * scale)), maxi(SIZE.y, ceili(picture.get_height() * scale)))
	picture.resize(scaled.x, scaled.y, Image.INTERPOLATE_BILINEAR)
	return picture.get_region(Rect2i((scaled - SIZE) / 2, SIZE))

## Files and bytes in the cache.
static func usage() -> Vector2i:
	var dir := DirAccess.open(DIRECTORY)
	if not dir:
		return Vector2i.ZERO
	var files := 0
	var bytes := 0
	for name in dir.get_files():
		var file := FileAccess.open(DIRECTORY.path_join(name), FileAccess.READ)
		if file:
			files += 1
			bytes += file.get_length()
	return Vector2i(files, bytes)

static func clear() -> void:
	_textures.clear()
	var dir := DirAccess.open(DIRECTORY)
	if not dir:
		return
	for name in dir.get_files():
		dir.remove(name)

## Part of one eye that makes a 16:9 picture: the whole flat frame, the centre of VR180 /
## fisheye, a quarter of the 360 panorama. (x, y, width, height) in eye UV, row 0 on top.
static func crop_for(geometry: int, eye_size: Vector2) -> Vector4:
	var width: float = [1.0, 0.5, 0.5, 0.25][clampi(geometry, 0, 3)]
	var height := width * eye_size.x / maxf(1.0, eye_size.y) * float(SIZE.y) / SIZE.x
	if height > 1.0:
		width /= height
		height = 1.0
	return Vector4((1.0 - width) * 0.5, (1.0 - height) * 0.5, width, height)

## Renders the left eye of a bound video frame (an RGBA texture, or the decoder's external image)
## into SIZE. Call while that frame is bound; resolves after the frame is drawn.
static func capture(parent: Node, color: RID, decoder: bool, stereo_sbs: bool, crop: Vector4,
		uv_scale: Vector2 = Vector2.ONE, top_bottom: bool = false) -> Image:
	var viewport := SubViewport.new()
	viewport.size = SIZE
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.0
	camera.position = Vector3(0, 0, 1)
	viewport.add_child(camera)
	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(float(SIZE.x) / SIZE.y, 1.0)
	quad.mesh = mesh
	var material := ShaderMaterial.new()
	material.shader = SHADER_OES if decoder else SHADER_2D
	material.set_shader_parameter("stereo_sbs", stereo_sbs)
	material.set_shader_parameter("top_bottom", top_bottom)
	material.set_shader_parameter("crop", crop)
	material.set_shader_parameter("color_uv_scale", uv_scale)
	quad.material_override = material
	viewport.add_child(quad)
	parent.add_child(viewport)
	RenderingServer.material_set_param(material.get_rid(), "color_texture", color)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	RenderingServer.material_set_param(material.get_rid(), "color_texture", null)
	viewport.queue_free()
	return image
