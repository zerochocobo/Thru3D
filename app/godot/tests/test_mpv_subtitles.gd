extends SceneTree

const State := preload("res://scripts/mpv_subtitle_state.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
var failures: Array[String] = []
var checks := 0

class Host extends RefCounted:
	var accepted := true
	var calls: Array = []
	func set_mpv_subtitle(id: int, track: int) -> bool:
		calls.append([id, track])
		return accepted
	func set_mpv_playing(_id: int, _playing: bool) -> void:
		pass
	func revise_mpv_video(_id: int, _stereo: bool, _alpha: bool, _profile: String, _position: int, _depth: bool = false, _top_bottom: bool = false, _exact: bool = false) -> int:
		return 0

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)

func _initialize() -> void:
	var state := State.new()
	var pair := {"session_id": 7, "generation": 3, "source_epoch": 2, "mpv_source_handle": 55}
	var sample := {"session_id": 7, "sequence": 1, "generation": 3, "source_epoch": 2,
		"mpv_source_handle": 55, "command_id": 4, "required_command_id": 4, "track_id": "9",
		"timeline_valid": true, "age_ms": 20, "start_seconds": "1.0", "end_seconds": "2.0",
		"position_seconds": "1.5", "text": "中文字幕 😀\nSecond line"}
	state.select(9)
	check(state.observe(sample, 7, pair) and state.text == sample.text, "Unicode and line breaks must survive the current cue")
	var old := sample.duplicate(true)
	old.session_id = 6
	old.sequence = 99
	check(not state.observe(old, 7, pair) and state.text == sample.text, "Late old-session cue cannot erase current text")
	check(not state.observe(sample, 7, pair), "Duplicate/out-of-order sequence must be ignored")
	for mutation in [{"generation": 2}, {"source_epoch": 1}, {"mpv_source_handle": 54},
		{"command_id": 3}, {"track_id": "8"}, {"timeline_valid": false}, {"age_ms": 1001},
		{"start_seconds": ""}, {"end_seconds": ""}, {"position_seconds": "nan"},
		{"position_seconds": "0.99"}, {"position_seconds": "2.0"}]:
		state.clear(true)
		var invalid := sample.duplicate(true)
		invalid.merge(mutation, true)
		check(state.observe(invalid, 7, pair) and state.text.is_empty(), "Reject stale/invalid cue %s" % str(mutation))
	state.clear(true)
	var wrong_pair := pair.duplicate(true)
	wrong_pair.session_id = 6
	check(state.observe(sample, 7, wrong_pair) and state.text.is_empty(), "Bound frame must belong to the requested session")
	state.clear(true)
	check(state.observe(sample, 7, {}) and state.text.is_empty(), "No cue before a complete current video binding")
	state.select(0)
	state.clear(true)
	check(state.observe(sample, 7, pair) and state.text.is_empty(), "Disabled subtitles cannot show late text")
	state.select(-1)
	state.clear(true)
	check(state.observe(sample, 7, pair) and state.text == sample.text, "Automatic text track selection accepts actual MPV id")
	state.clear()
	check(state.text.is_empty() and state.sequence == 1, "Seek clears text and retains same-source sequence fence")
	state.clear(true)
	check(state.sequence == 0, "A fresh native source resets sequence")
	for codec in ["subrip", "webvtt", "ass", "ssa", "sami", "microdvd", "subviewer", "mov_text"]:
		check(State.text_codec(codec), "CC accepts common text codec " + codec)
	for codec in ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", ""]:
		check(not State.text_codec(codec), "CC excludes bitmap/unknown codec " + codec)
	var video := Video.new()
	var host := Host.new()
	video.platform = host
	video.media.begin(7)
	video.media.generation = 3
	video.media.playback = {"details": {"subtitle_tracks": [{"id": 5, "codec": "hdmv_pgs_subtitle"},
		{"id": 9, "codec": "ass"}, {"id": 12, "codec": "subrip"}]}}
	check(video.cycle_subtitle_track() and host.calls.back() == [7, 9], "Cycle actual text ids and skip unsupported bitmap tracks")
	check(video.cycle_subtitle_track() and host.calls.back() == [7, 12], "Next actual text track")
	check(video.cycle_subtitle_track() and host.calls.back() == [7, 0], "Cycle includes subtitles off")
	check(video.cycle_subtitle_track(-1) and host.calls.back() == [7, 12], "Reverse cycle uses real ids")
	check(video.media.session_id == 7 and video.media.generation == 3, "Selecting subtitles preserves RVM/video processing generation")
	host.accepted = false
	check(not video.set_subtitle_track(9) and video.subtitles.requested_track == 12, "Rejected native choice preserves desired track")
	var count := host.calls.size()
	check(not video.set_subtitle_track(-2) and host.calls.size() == count, "Invalid track cannot reach native host")
	video.subtitles.text = "old cue"
	video.subtitles.sequence = 10
	check(video.seek_absolute(2000) and video.subtitles.text.is_empty() and video.subtitles.sequence == 10,
		"Seek immediately clears text while replacement processing is pending")
	video.subtitles.text = "old cue"
	video.set_alpha(true)
	check(video.subtitles.text.is_empty() and video.subtitles.requested_track == 12, "Alpha switch clears old cue and retains selected native track")
	video.media.playback = {"details": {"subtitle_tracks": []}}
	check(not video.cycle_subtitle_track(), "Source without text subtitles cannot advertise a track")
	# External tracks arrive after FILE_LOADED. CC must become available using the
	# actual codec/id without reopening playback (including WebVTT and SSA).
	for codec in ["subrip", "webvtt", "ass", "ssa", "sami", "microdvd"]:
		host.accepted = true
		video.subtitles.select(0)
		video.media.playback = {"details": {"subtitle_tracks": [{"id": 25, "codec": codec}]}}
		check(video.cycle_subtitle_track() and host.calls.back() == [7, 25], "Late external track enables CC: " + codec)
	video.free()
	if failures.is_empty():
		print("MPV subtitle host checks passed: %d" % checks)
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)
