class_name DiagnosticLog extends RefCounted

const EVENT_PATH := "user://diagnostics/events.jsonl"

static func record(event: String, details: Dictionary = {}) -> void:
	var entry := {
		"schema_version": 1,
		"event": event,
		"monotonic_us": Time.get_ticks_usec(),
		"unix_seconds": Time.get_unix_time_from_system(),
		"details": details,
	}
	var line := JSON.stringify(entry)
	print("[VP_EVENT] ", line)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://diagnostics"))
	var file := FileAccess.open(EVENT_PATH, FileAccess.READ_WRITE if FileAccess.file_exists(EVENT_PATH) else FileAccess.WRITE)
	if file:
		file.seek_end()
		file.store_line(line)

