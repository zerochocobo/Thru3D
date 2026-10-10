extends RefCounted

# Two checksummed generations keep the previous valid configuration available
# while the older bank is replaced. One writer, owned by the video controller.
const VERSION := 1
const LIMIT := 128
const MAX_BYTES := 262144
const PROFILES := ["320x320", "384x216", "512x288", "384x384", "512x512", "256x144", "256x256"]
var directory := "user://settings"
var entries: Dictionary = {}
var sequence := 0
var active_bank := -1
var dirty := false
var read_only := false
var last_error := OK

func _init(path: String = "user://settings") -> void:
	directory = path

static func key_for(uri: String) -> String:
	if uri.is_empty() or uri.length() > 8192:
		return ""
	# Network library URIs are stable (smb://<server id>/..., DLNA http media URLs); the
	# loopback SMB proxy URL is per run and never stored.
	var network := uri.begins_with("smb://") or uri.begins_with("cloud://") or uri.begins_with("medialib://") or ((uri.begins_with("http://") or uri.begins_with("https://")) 		and not uri.begins_with("http://127.0.0.1"))
	if not (uri.begins_with("content://") or uri.begins_with("file://") or network):
		return ""
	# Android document identifiers and file paths can be case-sensitive.
	return uri.sha256_text()

static func valid_mode(value: Variant) -> bool:
	if not value is Dictionary or not value.get("profile") in PROFILES:
		return false
	var geometry: Variant = value.get("geometry")
	if not (geometry is int or geometry is float) or not is_finite(float(geometry)) \
		or float(geometry) != floorf(float(geometry)) or int(geometry) not in [0, 1, 2, 3]:
		return false
	for name in ["stereo_sbs", "swap_eyes", "alpha_requested"]:
		if not value.get(name) is bool:
			return false
	for name in ["top_bottom", "stereo_half"]:
		if value.has(name) and not value[name] is bool:
			return false
	return true

func _bank_path(bank: int) -> String:
	return directory.path_join("file_modes_%d.json" % bank)

static func _decode(text: String) -> Variant:
	var parser := JSON.new()
	return parser.data if parser.parse(text) == OK else null

func _read_bank(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file or file.get_length() > MAX_BYTES:
		return {}
	var envelope: Variant = _decode(file.get_as_text())
	if not envelope is Dictionary:
		return {}
	var version: Variant = envelope.get("schema_version")
	if (version is int or version is float) and is_finite(float(version)) and float(version) > VERSION:
		return {"unsupported_schema": true}
	if version != VERSION:
		return {}
	var serial: Variant = envelope.get("sequence")
	if not (serial is int or serial is float) or not is_finite(float(serial)) \
		or float(serial) != floorf(float(serial)) or float(serial) < 1 or float(serial) > 9007199254740990.0:
		return {}
	var encoded: Variant = envelope.get("payload_json")
	if not encoded is String or encoded.sha256_text() != envelope.get("payload_sha256"):
		return {}
	var payload: Variant = _decode(encoded)
	if not payload is Dictionary or payload.get("sequence") != serial \
		or not payload.get("entries") is Dictionary or payload.entries.size() > LIMIT:
		return {}
	var result: Dictionary = {}
	for key in payload.entries:
		var entry: Variant = payload.entries[key]
		if not key is String or key.length() != 64 or not key.is_valid_hex_number(false) \
			or not entry is Dictionary or not valid_mode(entry.get("mode")):
			continue
		var updated: Variant = entry.get("updated")
		if not (updated is int or updated is float) or not is_finite(float(updated)) \
			or float(updated) != floorf(float(updated)) or float(updated) < 1 or float(updated) > float(serial):
			continue
		var mode: Dictionary = entry.mode.duplicate(true)
		mode.geometry = int(mode.geometry)
		result[key] = {"mode": mode, "updated": int(updated)}
	return {"sequence": int(serial), "entries": result}

func load_saved() -> void:
	entries = {}
	sequence = 0
	active_bank = -1
	dirty = false
	read_only = false
	for bank in 2:
		var value := _read_bank(_bank_path(bank))
		if value.get("unsupported_schema", false):
			read_only = true
			continue
		if not value.is_empty() and int(value.sequence) > sequence:
			sequence = int(value.sequence)
			entries = value.entries
			active_bank = bank

func lookup(uri: String) -> Dictionary:
	var value: Dictionary = entries.get(key_for(uri), {})
	return value.get("mode", {}).duplicate(true)

func remember(uri: String, mode: Dictionary) -> bool:
	var key := key_for(uri)
	if key.is_empty() or not valid_mode(mode):
		return false
	if lookup(uri) == mode:
		return true
	entries[key] = {"mode": mode.duplicate(true), "updated": sequence + 1}
	while entries.size() > LIMIT:
		var oldest := str(entries.keys()[0])
		for candidate in entries:
			if int(entries[candidate].updated) < int(entries[oldest].updated):
				oldest = candidate
		entries.erase(oldest)
	dirty = true
	return true

func _commit(staged: String, target: String) -> Error:
	return DirAccess.rename_absolute(staged, target)

func relocate(old_uri: String, new_uri: String, title: String = "") -> bool:
	var old_key := key_for(old_uri)
	var new_key := key_for(new_uri)
	if old_key.is_empty() or new_key.is_empty() or not entries.has(old_key): return false
	var value: Dictionary = entries[old_key].duplicate(true)
	if value.has("uri"): value.uri = new_uri
	if value.has("title") and not title.is_empty(): value.title = title.left(256)
	entries[new_key] = value; entries.erase(old_key); dirty = true
	return true

func save() -> bool:
	if not dirty:
		return true
	if read_only:
		last_error = ERR_UNAVAILABLE
		return false
	if sequence >= 9007199254740990:
		last_error = ERR_OUT_OF_MEMORY
		return false
	last_error = DirAccess.make_dir_recursive_absolute(directory)
	if last_error != OK:
		return false
	var next_bank := 0 if active_bank != 0 else 1
	var target := _bank_path(next_bank)
	var staged := target + ".tmp"
	var encoded := JSON.stringify({"sequence": sequence + 1, "entries": entries})
	var serialized := JSON.stringify({"schema_version": VERSION, "sequence": sequence + 1,
		"payload_json": encoded, "payload_sha256": encoded.sha256_text()})
	if serialized.to_utf8_buffer().size() > MAX_BYTES:
		last_error = ERR_OUT_OF_MEMORY
		return false
	var file := FileAccess.open(staged, FileAccess.WRITE)
	if not file:
		last_error = FileAccess.get_open_error()
		return false
	file.store_string(serialized)
	file.flush()
	last_error = file.get_error()
	file.close()
	if last_error != OK:
		return false
	if _read_bank(staged).get("sequence", 0) != sequence + 1:
		last_error = ERR_FILE_CORRUPT
		return false
	last_error = _commit(staged, target)
	if last_error != OK:
		return false
	sequence += 1
	active_bank = next_bank
	dirty = false
	return true
