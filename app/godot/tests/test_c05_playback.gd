extends SceneTree

const PlaybackControl := preload("res://scripts/playback_control.gd")
const State := preload("res://scripts/media_state.gd")
const Video := preload("res://scripts/video_display.gd")
var failures: Array[String] = []

class RecoveryVideo extends Video:
	var recovered := 0
	var restored_position := -1
	func open_local(_uri: String, _name_value: String, start_ms: int = 0) -> bool:
		recovered += 1
		restored_position = start_ms
		alpha_requested = false
		media.begin(media.session_id + 1)
		return true

func _check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var control := PlaybackControl.new()
	control.observe(4000, 2000000)
	for _index in 100:
		control.seek_relative(10000)
	_check(control.sequence == 100 and control.target_ms == 1004000, "Rapid relative seeks must accumulate from pending target")
	_check(control.snapshot().capacity == 1 and control.pending, "100 requests must occupy one pending slot")
	_check(control.display_position_ms() == 1004000 and control.observed_position_ms == 4000,
		"Queued UI target is independent of the actual playback clock")
	var request := control.take_pending()
	_check(request.request_id == 100 and request.target_ms == 1004000, "Only latest target may allocate a replacement decoder")
	control.observe(0, -1)
	_check(control.observed_position_ms == 4000 and control.duration_ms == 2000000, "Opening replacement must not reset known position or duration")
	_check(control.display_position_ms() == 1004000, "Timeline holds its in-flight target despite old status")
	control.seek_relative(-10000)
	_check(not control.first_frame(), "An in-flight frame cannot complete a newer queued request")
	_check(control.display_position_ms() == 994000, "A newer seek immediately replaces the displayed target")
	request = control.take_pending()
	_check(request.request_id == 101 and request.target_ms == 994000, "Pending replacement must use current target")
	_check(control.first_frame() and not control.first_frame(), "First frame completion must occur exactly once")
	control.seek_absolute(-40000)
	_check(control.target_ms == 0, "Backward seek must clamp to zero")
	control.seek_absolute(3000000)
	_check(control.target_ms == 1999999, "Known duration must bound seek target below EOS")
	control.close()
	control.seek_absolute(9223372036854775807)
	_check(control.target_ms == 2147483647, "JNI int boundary must not wrap huge positions")
	control.seek_relative(9223372036854775807)
	_check(control.target_ms == 2147483647, "Large relative deltas must not overflow before target clamping")
	control.reject()
	_check(not control.pending and control.in_flight == 0, "Failure must clear queued work")
	var media := State.new()
	media.begin(10)
	_check(media.apply_event("state", 10, '{"session_id":10,"logical_session_id":3,"generation":2,"state":"ready"}'), "Native logical scope must attach to producer")
	_check(not media.apply_event("state", 10, '{"session_id":10,"logical_session_id":3,"generation":1,"state":"ended"}'), "Older generation within decoder ID must be rejected")
	_check(not media.apply_event("error", 10, '{"session_id":10,"logical_session_id":4,"generation":2,"code":"OLD"}'), "Foreign logical scope cannot fail active source")
	_check(not media.apply_event("state", 10, '{"session_id":10,"state":"ready"}'), "Attached scope cannot accept packets missing generation")
	_check(not media.apply_event("state", 10, '{"session_id":10,"logical_session_id":3,"generation":2.5,"state":"ended"}'), "Fractional generation cannot be truncated into a valid token")
	_check(media.state == "ready" and media.error.is_empty(), "Rejected packets must leave state intact")
	media.revise_effect()
	var identity := media.frame_identity()
	_check(identity.session_id == 3 and identity.decoder_id == 10 and identity.generation == 2 and identity.effect_revision == 1, "Identity must carry logical/decoder and effect fields separately")
	_check(identity.pts_us == null and not identity.rvm_pairable and not identity.immutable_color_frame, "Direct OES must never claim verified PTS or immutable RVM pairing")
	media.begin(11)
	_check(media.apply_event("state", 11, '{"session_id":11,"logical_session_id":3,"generation":3,"state":"ready"}'), "Replacement can retain logical source with a newer generation")
	_check(not media.apply_event("state", 10, '{"session_id":10,"logical_session_id":3,"generation":2,"state":"ended"}'), "Queued old decoder callback cannot affect new generation")
	# Exercise both UI/GL ordering permutations and replacement before deferred recovery.
	for release_first in [false, true]:
		var video := RecoveryVideo.new()
		root.add_child(video)
		video.media.begin(42)
		video.media.playback = {"position_ms": 4000}
		video.alpha_requested = true
		video.retained_textures[42] = null
		if release_first:
			video._on_released(42, "{}")
		video._on_media_event(42, '{"session_id":42,"code":"GL_CONTEXT_CHANGED"}', "error")
		if not release_first:
			video._on_released(42, "{}")
		await process_frame
		_check(video.recovered == 1 and video.restored_position == 4000 and video.alpha_requested, "Context recovery must handle either error/release order and restore requested Alpha")
		video.queue_free()
		await process_frame
	var superseded := RecoveryVideo.new()
	root.add_child(superseded)
	superseded.media.begin(50)
	superseded._on_media_event(50, '{"session_id":50,"code":"GL_CONTEXT_CHANGED"}', "error")
	superseded.media.begin(51)
	await process_frame
	_check(superseded.recovered == 0, "Deferred old context recovery must not reopen a replacement file")
	superseded.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("C05 host regression passed: latest seek, bounds, stale completions, immutable scopes and unverified OES PTS. Android seek not exercised.")
	quit(0 if failures.is_empty() else 1)
