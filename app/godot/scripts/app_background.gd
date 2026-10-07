extends Node
## Application scenery owns its texture independently of the image viewer's current photo.
signal changed
signal custom_saved(path: String, title: String, orientation: int)
const Info := preload("res://scripts/image_info.gd")
const BELFAST := "res://backgrounds/belfast_sunset_puresky.jpg"
const CHOICES := ["belfast", "dark", "passthrough", "custom"]
var directory := "user://backgrounds"
var choice := "belfast"
var custom_path := ""
var custom_title := ""
var custom_orientation := 1
var yaw := 0.0
var brightness := 1.0
var loading := false
var error := ""
var sky := Sky.new()
var _material := PanoramaSkyMaterial.new()
var _builtin: Texture2D
var _custom: Texture2D
var _builtin_requested := false
var _thread: Thread
var _job := {}
var _generation := 0

func _ready() -> void:
	sky.sky_material = _material
	# Background only; no need for a large reflection cubemap.
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	_material.filter = true
	if not select(choice): select("belfast")

func select(value: String) -> bool:
	if value not in CHOICES: return false
	if value == "custom" and not has_custom(): return false
	_generation += 1
	choice = value
	error = ""
	if choice == "belfast" and not _builtin and not _builtin_requested:
		_builtin_requested = ResourceLoader.load_threaded_request(BELFAST, "Texture2D") == OK
		if not _builtin_requested: error = "Background unavailable"
	if choice == "custom" and not _custom and not _thread:
		_start_custom(custom_path, custom_orientation, false, custom_title)
	_apply()
	return true

func has_custom() -> bool:
	return _custom != null or (custom_path.begins_with(directory + "/") and FileAccess.file_exists(custom_path))

func import_photo(source: Dictionary, title: String) -> bool:
	if _thread or source.is_empty(): return false
	_generation += 1
	return _start_custom(str(source.path), int(source.get("orientation", 1)), true, title)

func _start_custom(path: String, orientation: int, copy: bool, title: String) -> bool:
	# Open before dispatch: an Android photo cache may be unlinked on the next selection.
	var input := FileAccess.open(path, FileAccess.READ)
	if not input or input.get_length() > 256 * 1024 * 1024:
		error = "Background unavailable"; changed.emit(); return false
	var destination := directory.path_join("custom_%d_%d.image" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec()]) if copy else path
	_job = {"path": destination, "orientation": orientation, "copy": copy, "title": title, "generation": _generation}
	_thread = Thread.new()
	if _thread.start(_read_custom.bind(input, _job.duplicate(true))) != OK:
		_thread = null; error = "Background unavailable"; changed.emit(); return false
	loading = true
	changed.emit()
	return true

static func _read_custom(input: FileAccess, job: Dictionary) -> Dictionary:
	var path := str(job.path)
	if job.copy:
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var output := FileAccess.open(path, FileAccess.WRITE)
		if not output: return {}
		while input.get_position() < input.get_length():
			var bytes := input.get_buffer(mini(65536, input.get_length() - input.get_position()))
			if bytes.is_empty(): return {}
			output.store_buffer(bytes)
		output.close()
	input.close()
	var header := Info.read_header(path)
	if header.is_empty() or header.width > 8192 or header.height > 8192 or int(header.width) * int(header.height) > 32 * 1024 * 1024: return {}
	var data := FileAccess.get_file_as_bytes(path)
	var image := Image.new()
	var result := image.load_jpg_from_buffer(data) if header.codec == "jpg" else (image.load_png_from_buffer(data) if header.codec == "png" else image.load_webp_from_buffer(data))
	if result != OK: return {}
	Info.orient(image, int(job.orientation))
	if absf(float(image.get_width()) / image.get_height() - 2.0) > 0.02: return {}
	image.generate_mipmaps()
	return {"image": image}

func _process(_delta: float) -> void:
	if _builtin_requested:
		var status := ResourceLoader.load_threaded_get_status(BELFAST)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			_builtin = ResourceLoader.load_threaded_get(BELFAST) as Texture2D
			_builtin_requested = false
			_apply()
		elif status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_builtin_requested = false
			error = "Background unavailable"
			_apply()
	if _thread and not _thread.is_alive():
		var result: Dictionary = _thread.wait_to_finish()
		_thread = null
		if result.has("image"):
			_custom = ImageTexture.create_from_image(result.image)
			if _job.copy:
				var previous := custom_path
				custom_path = str(_job.path); custom_title = str(_job.title); custom_orientation = int(_job.orientation)
				if int(_job.generation) == _generation: choice = "custom"
				# Persist the new reference before removing the old private copy.
				custom_saved.emit(custom_path, custom_title, custom_orientation)
				if previous.begins_with(directory + "/") and previous != custom_path: DirAccess.remove_absolute(previous)
		else:
			error = "Background unavailable"
			if _job.copy: DirAccess.remove_absolute(str(_job.path))
		_apply()

func _apply() -> void:
	_material.panorama = _builtin if choice == "belfast" else (_custom if choice == "custom" else null)
	_material.energy_multiplier = brightness
	loading = _thread != null or (choice == "belfast" and _builtin_requested)
	changed.emit()

func ready_sky() -> Sky:
	return sky if _material.panorama != null else null

func rotate_sky() -> void:
	yaw = fposmod(yaw + 45.0, 360.0)
	changed.emit()

func cycle_brightness() -> void:
	brightness = 0.5 if brightness >= 1.25 else brightness + 0.25
	_apply()

func _exit_tree() -> void:
	if _thread: _thread.wait_to_finish()
	if _builtin_requested: ResourceLoader.load_threaded_get(BELFAST)
