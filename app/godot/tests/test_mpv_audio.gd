extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
class Host extends RefCounted:
	var accepted := true
	var calls: Array = []
	func set_mpv_audio(id: int, track: int, volume: float, muted: bool) -> bool:
		calls.append([id, track, volume, muted])
		return accepted

var failures: Array[String] = []
func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)

func _initialize() -> void:
	var video := Video.new()
	var host := Host.new()
	video.platform = host
	video.media.begin(7)
	video.media.generation = 3
	video.media.playback = {"details": {"audio_track_id": "1", "audio_tracks": [{"id": 1}, {"id": 2}]}}
	check(video.cycle_audio_track(), "Actual enumerated next track must be selectable")
	check(host.calls.back()[1] == 2, "Track selection uses MPV track id")
	video.media.playback.details.audio_track_id = "2"
	check(video.cycle_audio_track() and host.calls.back()[1] == 0, "Track cycle includes disabled audio")
	check(video.set_audio_options(-1, 40, true), "Auto selection, volume and mute share one request")
	check(video.change_volume(-50) and video.audio_volume == 0 and video.audio_muted, "Volume clamp preserves mute")
	check(video.toggle_mute() and not video.audio_muted, "Mute toggles independently")
	check(video.toggle_mute() and video.change_volume(10) and video.audio_volume == 10 and not video.audio_muted, "Raising the volume unmutes")
	check(video.change_volume(-10) and video.audio_volume == 0 and not video.audio_muted, "Lowering does not mute by itself")
	check(video.media.session_id == 7 and video.media.generation == 3, "Audio controls preserve media and processing generation")
	host.accepted = false
	check(not video.set_audio_options(1, 90, true) and video.audio_volume == 0 and not video.audio_muted, "Rejected native request must not update desired controls")
	check(not video.set_audio_options(-2, 50, false) and not video.set_audio_options(1, NAN, false), "Invalid controls cannot reach the host")
	video.media.playback = {"details": {"audio_tracks": []}}
	check(not video.cycle_audio_track(), "Silent source has no audio choice")
	video.requested_play = true
	video._on_state(6, JSON.stringify({"state": "paused", "audio_focus_change": "loss"}))
	check(video.requested_play, "Old source focus loss cannot pause the current source")
	video._on_state(7, JSON.stringify({"state": "paused", "audio_focus_change": "loss"}))
	check(not video.requested_play and video.media.session_id == 7 and video.media.generation == 3, "Permanent focus loss requires a fresh play request without resetting RVM")
	video.free()
	if failures.is_empty():
		print("MPV audio host checks passed")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)
