extends RefCounted

# Shared 3D text plane: OpenXR supplies the runtime eye separation during rendering.
# Linear inverse distance gives uniform changes in stereo disparity along the slider.
const DEFAULT := 5.0
const LIMITS := Vector2(0.5, 20.0)
const PRESETS := [0.5, 1.0, 2.0, 5.0, 20.0]
const CHOICES := [0.5, 1.0, 2.0, 3.0, 5.0, 7.5, 10.0, 15.0, 20.0]
const POSITIONS := ["Top", "Upper", "Middle", "Lower", "Bottom"]
const DEFAULT_POSITION := 3

static func position(value: int) -> int:
	return clampi(value, 0, POSITIONS.size() - 1)

static func elevation(value: int) -> float:
	return [0.488, 0.244, 0.0, -0.244, -0.488][position(value)]

static func distance_choices() -> Array:
	var result: Array = []
	for value in CHOICES: result.append({"value": value, "label": str(value).trim_suffix(".0") + " m"})
	return result

static func position_choices() -> Array:
	var result: Array = []
	for i in POSITIONS.size(): result.append({"value": i, "label": POSITIONS[i]})
	return result

static func distance(value: float) -> float:
	return clampf(value, LIMITS.x, LIMITS.y) if is_finite(value) else DEFAULT

static func slider_fraction(value: float) -> float:
	return inverse_lerp(1.0 / LIMITS.x, 1.0 / LIMITS.y, 1.0 / distance(value))

static func slider_distance(fraction: float) -> float:
	return distance(snappedf(1.0 / lerpf(1.0 / LIMITS.x, 1.0 / LIMITS.y, clampf(fraction, 0, 1)), 0.05))
