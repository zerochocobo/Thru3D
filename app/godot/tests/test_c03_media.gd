extends SceneTree

const MediaState := preload("res://scripts/media_state.gd")
const Video := preload("res://scripts/video_display.gd")
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

func _run() -> void:
	var media := MediaState.new()
	media.begin(1)
	media.begin(2)
	_check(not media.apply_event("error", 1, '{"session_id":1,"code":"OLD_ERROR"}'), "Old callback must not fail replacement")
	_check(media.state == "opening" and media.error.is_empty(), "Old event must not mutate active state")
	_check(not media.apply_event("state", 2, '{"session_id":1,"state":"ready"}'), "Signal/payload identity mismatch must be rejected")
	_check(not media.apply_event("state", 2, 'broken json'), "Malformed payload must be rejected")
	_check(media.apply_event("state", 2, '{"session_id":2,"state":"ready","position_ms":5000}'), "Current valid state must be accepted")
	var frame := {"session_id": 2, "frame_counter": 1, "surface_timestamp_ns": 1000,
		"transform": [1,0,0,0, 0,-1,0,0, 0,0,1,0, 0,1,0,1]}
	_check(media.apply_event("frame", 2, JSON.stringify(frame)), "Full frame transform must be accepted")
	var transformed: Vector4 = media.transform * Vector4(0.25, 0.75, 0, 1)
	_check(transformed.is_equal_approx(Vector4(0.25, 0.25, 0, 1)), "Column-major matrix must preserve crop/flip orientation")
	_check(not media.apply_event("frame", 2, JSON.stringify(frame)), "Duplicate frame notification must not advance frame identity")
	frame.frame_counter = 2
	frame.transform = [1, 0, 0]
	_check(not media.apply_event("frame", 2, JSON.stringify(frame)), "Partial matrix must be rejected")
	_check(media.frame_counter == 1, "Invalid frame must preserve previous transform and counter")
	_check(not media.apply_event("format", 2, '{"session_id":2,"width":1920,"height":0,"pixel_aspect":1,"unapplied_rotation_degrees":0}'), "Invalid dimensions must be rejected")
	_check(media.apply_event("format", 2, '{"session_id":2,"width":3840,"height":1920,"pixel_aspect":1,"unapplied_rotation_degrees":0}'), "Valid SBS format must be accepted")
	_check(media.apply_event("error", 2, '{"session_id":2,"code":"GL_CONTEXT_RECREATED"}'), "Context loss must produce a failure")
	_check(not media.apply_event("state", 2, '{"session_id":2,"state":"ready"}'), "Queued ready must not revive a failed context")
	media.begin(3)
	_check(media.frame_counter == 0 and media.format.width == 0, "Replacement must reset frame and format")
	media.close()
	_check(not media.apply_event("frame", 3, JSON.stringify(frame)), "Closed session must reject callbacks")
	var video := Video.new()
	root.add_child(video)
	video.pick_file()
	_check(not video.picker_error.is_empty(), "Desktop must explain that Android playback is unavailable")
	_check(not video.open_local("https://example.invalid/video.mp4", "test"), "Desktop must not pretend to open a video")
	video.queue_free()
	await process_frame
	for message in failures:
		push_error(message)
	if failures.is_empty():
		print("C03 host regression passed: stale/invalid events, transform columns, context failure, reset and desktop capability boundary. Android media not exercised.")
	quit(0 if failures.is_empty() else 1)
