extends SceneTree

const Controls := preload("res://scripts/player_stick_controls.gd")
const Main := preload("res://scripts/main.gd")
var failures: Array[String] = []
var checks := 0

class Trace extends Node3D:
	var calls: Array = []
	func seek_relative(delta: int) -> bool:
		calls.append(["seek", delta])
		return true
	func change_volume(delta: float) -> bool:
		calls.append(["volume", delta])
		return true
	func cycle_audio_track(direction: int) -> bool:
		calls.append(["audio_track", direction])
		return true
	func toggle_mute() -> bool:
		calls.append(["mute"])
		return true
	func cycle_subtitle_track(direction: int) -> bool:
		calls.append(["subtitle", direction])
		return true
	func toggle_eye_order() -> bool:
		calls.append(["swap_eyes"])
		return true
	func zoom_view(amount: float) -> void:
		calls.append(["zoom", amount])

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)

func _initialize() -> void:
	var main := Main.new()
	var video := Trace.new()
	main.video = video
	var controls := Controls.new()
	for stick in [Vector2(.8, .6), Vector2(-.6, -.8), Vector2(.7, .7)]:
		controls.poll(Vector2.ZERO, Vector2.ZERO)
		main._apply_stick_actions(controls.poll(stick, stick))
	check(video.calls.is_empty(), "Diagonals on either stick do nothing: no eye swap, no subtitle switch")
	controls.poll(Vector2.ZERO, Vector2.ZERO)
	main._apply_stick_actions(controls.poll(Vector2.ZERO, Vector2(-.99, 0)))
	check(video.calls.back() == ["seek", -10000], "Centered then left resumes ordinary seek")
	controls.poll(Vector2.ZERO, Vector2.ZERO)
	main._apply_stick_actions(controls.poll(Vector2(0, .99), Vector2(.99, 0)))
	check(video.calls.slice(-2) == [["volume", 10.0], ["seek", 10000]], "Two hands dispatch independently")
	for _sample in 100:
		main._apply_stick_actions(controls.poll(Vector2(0, .99), Vector2(.99, 0)))
	check(video.calls.size() == 3, "Holding both sticks cannot repeat commands every XR frame")
	var cases := [[Vector2(.99, 0), Vector2.ZERO, ["audio_track", 1]],
		[Vector2(-.99, 0), Vector2.ZERO, ["audio_track", -1]],
		[Vector2(0, .99), Vector2.ZERO, ["volume", 10.0]],
		[Vector2(0, -.99), Vector2.ZERO, ["volume", -10.0]],
		[Vector2.ZERO, Vector2(.99, 0), ["seek", 10000]],
		[Vector2.ZERO, Vector2(0, -.99), ["volume", -10.0]]]
	for sample in cases:
		controls.poll(Vector2.ZERO, Vector2.ZERO)
		main._apply_stick_actions(controls.poll(sample[0], sample[1]))
		check(video.calls.back() == sample[2], "Cardinal action reaches actual main controller: %s" % [sample[2]])
	controls.poll(Vector2.ZERO, Vector2.ZERO)
	check(controls.poll(Vector2(.4, .2), Vector2(.5, .1)).is_empty(), "Deadzone cannot produce an action")
	check(controls.poll(Vector2(NAN, 0), Vector2(INF, 0)).is_empty(), "Invalid tracking axes cannot control playback")
	# Immersive views: the right stick's up/down zooms every frame (no latch), sideways still seeks.
	controls = Controls.new()
	video.calls.clear()
	for _frame in 3:
		main._apply_stick_actions(controls.poll(Vector2.ZERO, Vector2(0.1, 0.9), true), 0.5)
	check(video.calls.size() == 3 and video.calls.all(func(c): return c[0] == "zoom" and c[1] > 0.0), "Right stick up zooms in continuously: %s" % [video.calls])
	main._apply_stick_actions(controls.poll(Vector2.ZERO, Vector2(0.99, 0.1), true))
	check(video.calls.back()[0] == "zoom", "Zooming stays zoom until the stick returns to center")
	controls.poll(Vector2.ZERO, Vector2.ZERO, true)
	main._apply_stick_actions(controls.poll(Vector2.ZERO, Vector2(0, -0.9), true), 0.5)
	check(video.calls.back()[0] == "zoom" and video.calls.back()[1] < 0.0, "Right stick down zooms out")
	controls.poll(Vector2.ZERO, Vector2.ZERO, true)
	main._apply_stick_actions(controls.poll(Vector2.ZERO, Vector2(0.99, 0), true))
	check(video.calls.back() == ["seek", 10000], "Sideways still seeks in immersive views")
	controls.poll(Vector2.ZERO, Vector2.ZERO)
	main._apply_stick_actions(controls.poll(Vector2(0, 0.99), Vector2.ZERO, true))
	check(video.calls.back() == ["volume", 10.0], "The left stick keeps the volume in immersive views")
	main.free()
	video.free()
	for failure in failures:
		push_error(failure)
	print("Player stick host checks: %s (%d)" % ["passed" if failures.is_empty() else "failed", checks])
	quit(0 if failures.is_empty() else 1)
