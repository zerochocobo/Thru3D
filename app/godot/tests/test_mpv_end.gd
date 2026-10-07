extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
var failures: Array[String] = []

class ReplayProbe extends "res://scripts/mpv_video_display.gd":
	var play_actions := 0
	func toggle_play() -> void:
		play_actions += 1

func _check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)

func _initialize() -> void:
	var video := Video.new()
	video.media.state = "ended"
	video.loop_enabled = true
	video.alpha_requested = true
	video.media.last_pair = {"slot_token": 9, "source_epoch": 7, "frame_id": 179, "pts_us": 5966667, "inference_ran": true}
	video.media.playback = {"eof_source_resolved": true, "eof_source_ticket": {"source_epoch": 7, "frame_id": 179, "pts_us": 5966667}}
	_check(not video._can_loop(), "EOF and a bound final pair must wait for post-draw confirmation")
	video.media.playback["eof_pair_post_draw"] = true
	video.media.playback["eof_presented_slot"] = 8
	_check(not video._can_loop(), "Earlier drawn slot cannot authorize the newly bound final pair")
	video.media.playback["eof_presented_slot"] = 9
	_check(video._can_loop(), "Exact final source and complete drawn Alpha can loop")
	video.media.last_pair["pts_us"] = 5933333
	_check(not video._can_loop(), "Penultimate frame must not loop even if core is ended")
	video.media.last_pair["pts_us"] = 5966667
	video.requested_play = false
	_check(not video._can_loop(), "Explicit pause keeps the final frame displayed")
	video.requested_play = true
	video._pending_revision = {"position_ms": 2000}
	_check(not video._can_loop(), "User seek wins over a stale EOF status")
	video._pending_revision = {}
	video._waiting_first = true
	_check(not video._can_loop(), "Replacement generation cannot loop before its first frame")
	video._waiting_first = false
	video.media.last_pair["inference_ran"] = false
	_check(not video._can_loop(), "Alpha mode cannot loop from an opaque placeholder")
	video.alpha_requested = false
	_check(video._can_loop(), "Normal playback can loop from a complete opaque pair")
	video.free()
	var replay := ReplayProbe.new()
	replay.requested_play = true
	replay.media.state = "ended"
	replay._on_debug_command(1, '{"operation":"playing","enabled":true}')
	_check(replay.play_actions == 1, "Play at EOF must invoke replay even when play intent remains true")
	replay.media.state = "playing"
	replay._on_debug_command(2, '{"operation":"playing","enabled":true}')
	_check(replay.play_actions == 1, "Repeated play during playback must not toggle pause")
	replay.free()
	if failures.is_empty():
		print("MPV EOF host checks passed")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)
