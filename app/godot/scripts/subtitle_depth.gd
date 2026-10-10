extends RefCounted

# Position is elevation in degrees, independent of the subtitle plane distance.
const DEFAULT := 5.0
const LIMITS := Vector2(0.1, 10.0)
const DEFAULT_POSITION := 0.0
const POSITION_LIMITS := Vector2(-60.0, 60.0)

static func position(value: float) -> float:
	return clampf(value, POSITION_LIMITS.x, POSITION_LIMITS.y) if is_finite(value) else DEFAULT_POSITION

static func elevation(value: float) -> float:
	return deg_to_rad(position(value))

# Slider grows bottom-to-top horizontally, and left-to-right for vertical text.
static func anchor(value: float, vertical: bool = false) -> Basis:
	return Basis(Vector3.UP, -elevation(value)) if vertical else Basis(Vector3.RIGHT, elevation(value))

static func direction_row(value: int) -> Dictionary:
	return {"key": "subtitle_direction", "value": clampi(value, 0, 1), "choices": [
		{"value": 0, "label": "Horizontal"}, {"value": 1, "label": "Vertical"}]}

static func restore_position(settings: ConfigFile) -> float:
	if settings.has_section_key("subtitles", "elevation_degrees"):
		return position(float(settings.get_value("subtitles", "elevation_degrees")))
	if settings.has_section_key("subtitles", "position"):
		return rad_to_deg([0.488, 0.244, 0.0, -0.244, -0.488][clampi(int(settings.get_value("subtitles", "position")), 0, 4)])
	return DEFAULT_POSITION

static func slider_row(key: String, value: float) -> Dictionary:
	var is_position := key == "subtitle_position"
	return {"key": key, "value": position(value) if is_position else distance(value),
		"slider": true, "span": Vector3(POSITION_LIMITS.x, POSITION_LIMITS.y, 1) if is_position else Vector3(LIMITS.x, LIMITS.y, 0.1),
		"unit": "°" if is_position else " m", "midpoint": is_position}

static func distance(value: float) -> float:
	return clampf(value, LIMITS.x, LIMITS.y) if is_finite(value) else DEFAULT

static func slider_fraction(value: float) -> float:
	return inverse_lerp(LIMITS.x, LIMITS.y, distance(value))

static func slider_distance(fraction: float) -> float:
	return distance(snappedf(lerpf(LIMITS.x, LIMITS.y, clampf(fraction, 0, 1)), 0.1))
