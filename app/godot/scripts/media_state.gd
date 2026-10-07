extends RefCounted
# Mirrors a native session without treating a SurfaceTexture timestamp as source PTS.
var session_id := 0
var logical_session_id := 0
var generation := 0
var format_revision := 0
var effect_revision := 0
var state := "closed"
var error := ""
var frame_counter := 0
var surface_timestamp_ns := 0
var transform := Projection.IDENTITY
var format := {"width": 0, "height": 0, "pixel_aspect": 1.0, "unapplied_rotation_degrees": 0}
var playback: Dictionary = {}
var decoder := ""
var codec_dropped_frames := 0
var coalesced_notifications := 0

func begin(id: int) -> void:
	session_id = id
	logical_session_id = 0
	generation = 0
	format_revision = 0
	effect_revision = 0
	state = "opening" if id > 0 else "failed"
	error = "" if id > 0 else "MEDIA_OPEN_REJECTED"
	frame_counter = 0
	surface_timestamp_ns = 0
	transform = Projection.IDENTITY
	format = {"width": 0, "height": 0, "pixel_aspect": 1.0, "unapplied_rotation_degrees": 0}
	playback = {}
	decoder = ""
	codec_dropped_frames = 0
	coalesced_notifications = 0

func accepts(id: int) -> bool:
	return id > 0 and id == session_id and state not in ["closed", "failed"]

func apply_event(kind: String, id: int, payload: String) -> bool:
	if not accepts(id):
		return false
	var parser := JSON.new()
	if parser.parse(payload) != OK:
		return false
	var parsed: Variant = parser.data
	if not parsed is Dictionary or not _valid_id(parsed.get("session_id")) or int(parsed.session_id) != id:
		return false
	var has_scope: bool = parsed.has("logical_session_id") or parsed.has("generation")
	var candidate_logical := int(parsed.get("logical_session_id", 0))
	var candidate_generation := int(parsed.get("generation", 0))
	if has_scope:
		if not _valid_id(parsed.get("logical_session_id")) or not _valid_id(parsed.get("generation")):
			return false
		if logical_session_id > 0 and (candidate_logical != logical_session_id or candidate_generation != generation):
			return false
	elif logical_session_id > 0:
		return false
	match kind:
		"state":
			if parsed.get("state", "") not in ["idle", "buffering", "ready", "ended"]:
				return false
			playback = parsed
			state = parsed.state
		"format":
			var aspect := float(parsed.get("pixel_aspect", 0.0))
			if int(parsed.get("width", 0)) <= 0 or int(parsed.get("height", 0)) <= 0 or not is_finite(aspect) or aspect <= 0.0:
				return false
			if int(parsed.get("unapplied_rotation_degrees", -1)) not in [0, 90, 180, 270]:
				return false
			if format.width != int(parsed.width) or format.height != int(parsed.height) \
				or float(format.pixel_aspect) != aspect or int(format.unapplied_rotation_degrees) != int(parsed.unapplied_rotation_degrees):
				format_revision += 1
			format = parsed
		"frame":
			var matrix: Variant = parsed.get("transform", [])
			var count := int(parsed.get("frame_counter", 0))
			if not matrix is Array or matrix.size() != 16 or count <= frame_counter:
				return false
			for value in matrix:
				if not (value is float or value is int) or not is_finite(float(value)):
					return false
			var columns: Array[Vector4] = []
			for column in 4:
				columns.append(Vector4(matrix[column * 4], matrix[column * 4 + 1], matrix[column * 4 + 2], matrix[column * 4 + 3]))
			transform = Projection(columns[0], columns[1], columns[2], columns[3])
			frame_counter = count
			surface_timestamp_ns = int(parsed.get("surface_timestamp_ns", 0))
			coalesced_notifications = int(parsed.get("coalesced_notifications", 0))
		"codec":
			decoder = str(parsed.get("decoder", decoder))
			codec_dropped_frames += maxi(0, int(parsed.get("dropped_frames", 0)))
		"error":
			error = str(parsed.get("code", "MEDIA_ERROR"))
			state = "failed"
		_:
			return false
	if has_scope:
		logical_session_id = candidate_logical
		generation = candidate_generation
	return true

func revise_effect() -> void:
	effect_revision += 1

func _valid_id(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) > 0 \
		and float(value) <= 2147483647 and float(value) == floorf(float(value))

func frame_identity() -> Dictionary:
	return {"session_id": logical_session_id, "decoder_id": session_id, "generation": generation, \
		"format_revision": format_revision, "effect_revision": effect_revision, "frame_id": frame_counter, \
		"pts_us": null, "source_pts_verified": false, "immutable_color_frame": false, "rvm_pairable": false}

func close() -> void:
	session_id = 0
	logical_session_id = 0
	generation = 0
	state = "closed"
	frame_counter = 0

func snapshot() -> Dictionary:
	return {"session_id": session_id, "state": state, "error": error,
		"logical_session_id": logical_session_id, "generation": generation,
		"presentation_identity": frame_identity(),
		"frame_counter": frame_counter, "surface_timestamp_ns": surface_timestamp_ns,
		"format": format, "playback": playback, "decoder": decoder,
		"codec_dropped_frames": codec_dropped_frames, "coalesced_notifications": coalesced_notifications,
		"frame_pairing": "direct_OES_only_no_RVM", "device_validation": "pending"}
