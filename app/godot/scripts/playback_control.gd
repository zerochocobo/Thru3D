extends RefCounted

# One pending target replaces earlier requests. Resource capacity never grows with input rate.
var sequence := 0
var pending := false
var in_flight := 0
var target_ms := 0
var observed_position_ms := 0
var duration_ms := -1

func observe(position: int, duration: int) -> void:
	if duration >= 0:
		duration_ms = duration
	if not pending and in_flight == 0:
		observed_position_ms = maxi(0, position)

func seek_absolute(position: int) -> int:
	sequence += 1
	target_ms = clampi(position, 0, clampi(duration_ms - 1, 0, 2147483647) if duration_ms >= 0 else 2147483647)
	pending = true
	return sequence

func seek_relative(delta_ms: int) -> int:
	var base := clampi(target_ms if pending or in_flight > 0 else observed_position_ms, 0, 2147483647)
	return seek_absolute(base + clampi(delta_ms, -2147483647, 2147483647))

func take_pending() -> Dictionary:
	if not pending:
		return {}
	pending = false
	in_flight = sequence
	return {"request_id": sequence, "target_ms": target_ms}

func first_frame(actual_position_ms: int = -1) -> bool:
	if pending or in_flight != sequence or in_flight == 0:
		return false
	in_flight = 0
	# Keyframe seeks can land before the requested target. Confirm the displayed
	# source PTS, while retaining target_ms as the user's request for diagnostics.
	observed_position_ms = maxi(0, actual_position_ms) if actual_position_ms >= 0 else target_ms
	return true

func reject() -> void:
	pending = false
	in_flight = 0

## The user's seek target stays on the timeline while the decoder catches up.
## observed_position_ms remains the last confirmed playback clock.
func display_position_ms() -> int:
	return target_ms if pending or in_flight > 0 else observed_position_ms

func close() -> void:
	reject()
	observed_position_ms = 0
	duration_ms = -1

func snapshot() -> Dictionary:
	return {"request_id": sequence, "state": "queued" if pending else ("awaiting_first_frame" if in_flight > 0 else "idle"), \
		"target_ms": target_ms, "observed_position_ms": observed_position_ms, "duration_ms": duration_ms, \
		"display_position_ms": display_position_ms(), \
		"capacity": 1, "seek_method": "Media3_decoder_and_Surface_replacement", "source_frame_pts_verified": false}
