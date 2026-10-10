extends RefCounted

var requested_track := 0
var sequence := 0
var text := ""
var cue: Dictionary = {}
var bitmap: Dictionary = {}

func clear(reset_sequence: bool = false) -> void:
	text = ""
	cue = {}
	bitmap = {}
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
	var picture: Variant = snapshot.get("bitmap", {})
	if picture is Dictionary and picture.get("visible", false):
		var w := int(picture.get("width", 0))
		var h := int(picture.get("height", 0))
		var cw := int(picture.get("canvas_width", 0))
		var ch := int(picture.get("canvas_height", 0))
		var x := int(picture.get("x", -1))
		var y := int(picture.get("y", -1))
		if int(picture.get("version", 0)) > 0 and w > 0 and h > 0 and cw > 0 and ch > 0 \
			and cw <= 4096 and ch <= 4096 and w * h * 4 <= 16 * 1024 * 1024 \
			and x >= 0 and y >= 0 and x + w <= cw and y + h <= ch:
			# Native PGS decoding determines the active cue, including unknown end times.
			# Keep the same session/epoch/command/age fences as text observations.
			bitmap = picture.duplicate(true)
			cue = snapshot.duplicate(true)
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

static func supported_codec(codec: String, flat: bool, pgs_supported: bool) -> bool:
	return text_codec(codec) or (flat and pgs_supported and codec == "hdmv_pgs_subtitle")
