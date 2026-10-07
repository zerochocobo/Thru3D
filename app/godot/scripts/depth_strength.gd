extends RefCounted
## Shared photo/video parallax scale. 1.0 preserves the original default.
const MAX := 4.0
const DEFAULT := 1.0
const STEP := 0.01

static func clamp_value(value: float) -> float:
	return snappedf(clampf(value, 0.0, MAX), STEP) if is_finite(value) else DEFAULT

static func remembered(value: float) -> float:
	var result := clamp_value(value)
	return result if result > 0.0 else DEFAULT

## Give 100..300% sixty percent of the travel; compress the barely visible low end.
static func from_fraction(fraction: float) -> float:
	var f := clampf(fraction, 0.0, 1.0)
	return clamp_value(f * 5.0 if f < 0.2 else (1.0 + (f - 0.2) / 0.3 if f < 0.8 else 3.0 + (f - 0.8) * 5.0))

static func to_fraction(value: float) -> float:
	var v := clamp_value(value)
	return v / 5.0 if v < 1.0 else (0.2 + (v - 1.0) * 0.3 if v < 3.0 else 0.8 + (v - 3.0) / 5.0)
