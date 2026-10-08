extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
var checks := 0
var failures: Array[String] = []

class BindingProbe extends "res://scripts/pair_texture_binding.gd":
	func bind(target: ShaderMaterial, pair: Dictionary) -> bool:
		material = target
		ticket = pair.duplicate(true)
		return true

class BridgeProbe extends RefCounted:
	var captures: Array = []
	var revisions: Array = []
	var detached: Array = []
	var released: Array = []
	var busy := false
	func set_mpv_playing(_id: int, _play: bool) -> void: pass
	func freeze_mpv_pair(id: int, token: int, request: int) -> bool:
		captures.append([id, token, request])
		return true
	func revise_mpv_video(id: int, _stereo: bool, _alpha: bool, _profile: String, target: int, _depth: bool, _tb: bool) -> int:
		revisions.append([id, target])
		return -1 if busy else id + 1
	func detach_mpv_pair(id: int, token: int) -> bool:
		detached.append([id, token])
		return true
	func release_mpv_frozen_frame(id: int) -> void: released.append(id)
	func close_mpv_video(_id: int) -> void: pass

func check(value: bool, reason: String) -> void:
	checks += 1
	if not value: failures.append(reason)

func _initialize() -> void:
	var bridge := BridgeProbe.new()
	var video := Video.new()
	video.platform = bridge
	video.panel = MeshInstance3D.new()
	video.material = ShaderMaterial.new()
	video._binding = BindingProbe.new()
	video._binding.bind(video.material, {"session_id": 1, "slot_token": 10, "pts_us": 1000000})
	video.media.begin(1)
	video.media.format = {"width": 8192, "height": 4096}
	video.control.observe(1000, 120000)
	video.panel.visible = true
	video.alpha_enabled = true
	video._rvm_alpha = true
	video._thumbnail_busy = true
	video.seek_absolute(25000)
	check(bridge.captures.is_empty() and bridge.revisions.is_empty(), "Seek queues while the current frame is pinned for its thumbnail")
	video._thumbnail_busy = false
	video.seek_absolute(30000)
	video._try_revision()
	check(bridge.revisions.is_empty() and video.panel.visible, "Seek waits for safe GPU capture without hiding the original")
	video.seek_absolute(60000)
	check(bridge.captures.size() == 1 and bridge.revisions.is_empty(), "Requests during capture coalesce without a second snapshot")
	var request: int = bridge.captures[0][2]
	var frozen := {"session_id": 1, "slot_token": 10, "pts_us": 1000000, "frozen_frame_id": 77}
	video._on_frozen_pair(1, JSON.stringify({"request_id": request, "state": "ready", "pair": frozen}))
	check(bridge.revisions == [[1, 60000]] and video.media.session_id == 2, "Only the latest target starts after capture")
	check(video.panel.visible and video._is_frozen() and video.alpha_enabled and video._rvm_alpha, "Freeze preserves surface and same-frame Alpha during buffer wait")
	check(bridge.detached == [[1, 10]] and video.media.last_pair.is_empty(), "Old decoder lease is detached without passing the frozen frame as a new timeline frame")
	check(int(video.media.format.width) == 8192, "Held presentation retains its source geometry while media state resets")
	video._on_detach(1, "{}")
	check(video._is_frozen() and video.panel.visible and bridge.released.is_empty(), "Retirement event cannot clear the independent frozen copy")
	bridge.busy = true
	video.seek_absolute(90000)
	check(bridge.captures.size() == 1 and video._is_frozen() and video.panel.visible, "Repeated seek reuses freeze while old session cleanup catches up")
	bridge.busy = false
	video._try_revision()
	check(video.media.session_id == 3 and bridge.revisions.back() == [2, 90000], "Retried generation starts without waiting for an intermediate frame")
	video.close_video()
	check(bridge.released == [77] and not video.panel.visible and not video._is_frozen(), "Close releases the frozen texture exactly once")
	video._on_frozen_pair(1, JSON.stringify({"request_id": request, "state": "ready", "pair": {"frozen_frame_id": 78}}))
	check(bridge.released == [77, 78] and video.media.session_id == 0, "Late capture after close is released and cannot reopen playback")
	video.media.begin(4)
	video.panel.visible = true
	video._binding.bind(video.material, {"session_id": 4, "slot_token": 20})
	video.requested_play = false
	video.seek_absolute(10000)
	video._on_frozen_pair(4, JSON.stringify({"request_id": video._freeze_request, "state": "failed", "error": "allocation failed"}))
	check(video.panel.visible and not video._waiting_first and video._pending_revision.is_empty() and not video.requested_play,
		"Capture failure cancels the seek and preserves the user's paused original frame")
	video._unbind()
	video.platform = null
	video.panel.free()
	video.free()
	if failures.is_empty(): print("MPV seek hold host checks passed: ", checks)
	else:
		for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
