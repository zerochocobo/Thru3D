extends RefCounted
## Shared photo/video parallax scale. 1.0 preserves the original default; 2.0 is PTMediaServer's
## highest 2D->3D strength (its realtime menu offers 50..200%), which this player does not exceed.
const MAX := 2.0
const PHOTO_MAX := 1.0
const DEFAULT := 1.0
const STEP := 0.01

static func clamp_value(value: float, maximum: float = MAX) -> float:
	return snappedf(clampf(value, 0.0, maximum), STEP) if is_finite(value) else minf(DEFAULT, maximum)

static func remembered(value: float, maximum: float = MAX) -> float:
	var result := clamp_value(value, maximum)
	return result if result > 0.0 else DEFAULT

## The first fifth of the travel covers 0..50% (the bottom snaps to off); the rest is PTMediaServer's
## 50..200% range, linear.
static func from_fraction(fraction: float, maximum: float = MAX) -> float:
	var f := clampf(fraction, 0.0, 1.0)
	return clamp_value(f * 2.5 if f < 0.2 else 0.5 + (f - 0.2) * ((maximum - 0.5) / 0.8), maximum)

static func to_fraction(value: float, maximum: float = MAX) -> float:
	var v := clamp_value(value, maximum)
	return v / 2.5 if v < 0.5 else 0.2 + (v - 0.5) / ((maximum - 0.5) / 0.8)
