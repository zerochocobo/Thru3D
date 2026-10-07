extends "res://scripts/media_state.gd"

var last_pair: Dictionary = {}

func begin(id: int) -> void:
	super.begin(id)
	last_pair = {}

func frame_identity() -> Dictionary:
	if last_pair.is_empty():
		return {"source_pts_verified": false, "immutable_color_frame": false}
	var result: Dictionary = {}
	for key in ["session_id", "logical_session_id", "generation", "frame_id", "pts_us", "source_epoch",
		"format_revision", "effect_revision", "model_generation", "slot_token", "source_pts_verified",
		"immutable_color_frame", "pair_identity_verified", "inference_ran", "alpha_requested"]:
		result[key] = last_pair.get(key)
	return result

func snapshot() -> Dictionary:
	var result := super.snapshot()
	result["backend"] = "Android_libmpv"
	result["presentation_identity"] = frame_identity()
	result["frame_pairing"] = "MPV_shared_RGBA8_plus_same_ticket_numeric_R8"
	return result
