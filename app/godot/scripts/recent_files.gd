extends "res://scripts/file_mode_memory.gd"

# Private recent-file catalog. Unlike per-file mode keys, reopening requires
# retaining the original URI. Permissions are checked again before each open.
const RECENT_LIMIT := 32

func _bank_path(bank: int) -> String:
	return directory.path_join("recent_files_%d.json" % bank)

static func valid_entry(entry: Variant, serial: int) -> bool:
	if not entry is Dictionary or not entry.get("uri") is String or key_for(entry.uri).is_empty():
		return false
	if not entry.get("title") is String or entry.title.length() > 256 or not entry.get("persisted") is bool:
		return false
	for name in ["position_ms", "duration_ms", "opened"]:
		var number: Variant = entry.get(name)
		if not (number is int or number is float) or not is_finite(float(number)) or floorf(float(number)) != float(number):
			return false
	return int(entry.position_ms) >= 0 and int(entry.position_ms) <= 2147483647 \
		and int(entry.duration_ms) >= -1 and int(entry.duration_ms) <= 2147483647 \
		and int(entry.opened) >= 1 and int(entry.opened) <= serial

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
	if not (serial is int or serial is float) or not is_finite(float(serial)) or floorf(float(serial)) != float(serial) \
		or float(serial) < 1 or float(serial) > 9007199254740990.0:
		return {}
	var encoded: Variant = envelope.get("payload_json")
	if not encoded is String or encoded.sha256_text() != envelope.get("payload_sha256"):
		return {}
	var payload: Variant = _decode(encoded)
	if not payload is Dictionary or payload.get("sequence") != serial or not payload.get("entries") is Dictionary \
		or payload.entries.size() > RECENT_LIMIT:
		return {}
	var result: Dictionary = {}
	for key in payload.entries:
		var entry: Variant = payload.entries[key]
		if not valid_entry(entry, int(serial)) or key != key_for(str(entry.uri)):
			continue
		var value: Dictionary = entry.duplicate(true)
		for name in ["position_ms", "duration_ms", "opened"]:
			value[name] = int(value[name])
		result[key] = value
	return {"sequence": int(serial), "entries": result}

func lookup(uri: String) -> Dictionary:
	return entries.get(key_for(uri), {}).duplicate(true)

func list_recent() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value in entries.values():
		result.append(value.duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.opened) > int(b.opened) if a.opened != b.opened else str(a.uri) < str(b.uri))
	return result

func opened(uri: String, title: String, persisted: bool, kind: String = "video") -> bool:
	var key := key_for(uri)
	if key.is_empty():
		return false
	var old := lookup(uri)
	entries[key] = {"uri": uri, "title": title.replace("\n", " ").replace("\r", " ").replace("\t", " ").left(256),
		"kind": "image" if kind == "image" else "video",
		"persisted": persisted, "position_ms": int(old.get("position_ms", 0)),
		"duration_ms": int(old.get("duration_ms", -1)), "opened": sequence + 1}
	# Reserve room for the checksummed JSON envelope and its escaped payload.
	while entries.size() > RECENT_LIMIT or JSON.stringify(entries).to_utf8_buffer().size() > MAX_BYTES / 3:
		entries.erase(key_for(list_recent().back().uri))
	dirty = true
	return true

func progress(uri: String, position_ms: int, duration_ms: int, ended: bool = false) -> bool:
	var key := key_for(uri)
	if not entries.has(key) or position_ms < 0 or duration_ms < -1:
		return false
	var position := mini(position_ms, 2147483647)
	var duration := mini(duration_ms, 2147483647)
	if ended or (duration >= 0 and position >= maxi(0, duration - 2000)):
		position = 0
	var value: Dictionary = entries[key]
	if value.position_ms == position and value.duration_ms == duration:
		return true
	value.position_ms = position
	value.duration_ms = duration
	dirty = true
	return true

## Every entry, and with them the resume positions.
func clear_all() -> bool:
	if entries.is_empty():
		return false
	entries.clear()
	dirty = true
	return true

func forget(uri: String) -> bool:
	if not entries.erase(key_for(uri)):
		return false
	dirty = true
	return true

func resume_position(uri: String) -> int:
	var value := lookup(uri)
	if value.is_empty():
		return 0
	var position := int(value.position_ms)
	var duration := int(value.duration_ms)
	return position if duration < 0 or position < maxi(0, duration - 2000) else 0
