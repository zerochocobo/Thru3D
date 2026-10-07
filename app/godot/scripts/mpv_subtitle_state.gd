extends RefCounted

var requested_track := 0
var sequence := 0
var text := ""
var cue: Dictionary = {}

func clear(reset_sequence: bool = false) -> void:
	text = ""
	cue = {}
	if reset_sequence:
		sequence = 0

func select(track: int) -> void:
	requested_track = track
	clear()

func observe(snapshot: Dictionary, session_id: int, pair: Dictionary) -> bool:
	if int(snapshot.get("session_id", -1)) != session_id or int(snapshot.get("sequence", 0)) <= sequence:
		return false
	sequence = int(snapshot.sequence)
	clear()
	if requested_track == 0 or not snapshot.get("timeline_valid", false) or pair.is_empty() \
		or int(pair.get("session_id", -1)) != session_id or int(snapshot.get("age_ms", 1001)) > 1000:
		return true
	if int(snapshot.get("mpv_source_handle", -1)) != int(pair.get("mpv_source_handle", 0)) \
		or int(snapshot.get("source_epoch", -1)) != int(pair.get("source_epoch", 0)) \
		or int(snapshot.get("generation", -1)) != int(pair.get("generation", 0)):
		return true
	if int(snapshot.get("command_id", -1)) < int(snapshot.get("required_command_id", 0)):
		return true
	var actual := int(snapshot.get("track_id", 0))
	if actual <= 0 or (requested_track > 0 and actual != requested_track):
		return true
	var start := str(snapshot.get("start_seconds", ""))
	var end := str(snapshot.get("end_seconds", ""))
	var position := str(snapshot.get("position_seconds", ""))
	if not start.is_valid_float() or not end.is_valid_float() or not position.is_valid_float():
		return true
	if not is_finite(float(start)) or not is_finite(float(end)) or not is_finite(float(position)) \
		or float(position) < float(start) or float(position) >= float(end):
		return true
	# This follows MPV's playback clock. It is not a source-frame ticket.
	text = str(snapshot.get("text", "")).left(4096)
	cue = snapshot.duplicate(true)
	return true

static func text_codec(codec: String) -> bool:
	return codec in ["subrip", "ass", "ssa", "webvtt", "mov_text", "text", "sami", "microdvd", "subviewer", "ttml"]
