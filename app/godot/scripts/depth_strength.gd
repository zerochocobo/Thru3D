extends RefCounted
## Shared photo/video parallax scale. 1.0 preserves the original default; 2.0 is PTMediaServer's
## highest 2D->3D strength (its realtime menu offers 50..200%), which this player does not exceed.
const MAX := 2.0
const DEFAULT := 1.0
const STEP := 0.01

static func clamp_value(value: float) -> float:
	return snappedf(clampf(value, 0.0, MAX), STEP) if is_finite(value) else DEFAULT

static func remembered(value: float) -> float:
	var result := clamp_value(value)
	return result if result > 0.0 else DEFAULT

## The first fifth of the travel covers 0..50% (the bottom snaps to off); the rest is PTMediaServer's
## 50..200% range, linear.
static func from_fraction(fraction: float) -> float:
	var f := clampf(fraction, 0.0, 1.0)
	return clamp_value(f * 2.5 if f < 0.2 else 0.5 + (f - 0.2) * 1.875)

static func to_fraction(value: float) -> float:
	var v := clamp_value(value)
	return v / 2.5 if v < 0.5 else 0.2 + (v - 0.5) / 1.875
