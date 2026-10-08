extends RefCounted

const NAMES := ["Standard", "Enhanced", "High"]
const SCALES := [1.0, 1.1, 1.25]
const DEFAULT := 1
const SHARPNESS := [0.0, 0.2, 0.4, 0.6]
const SHARPNESS_NAMES := ["Off", "Low", "Medium", "High"]
const DEFAULT_SHARPNESS := 0.2

static func load_quality(settings: ConfigFile) -> int:
	if settings.has_section_key("video", "display_quality"):
		return clampi(int(settings.get_value("video", "display_quality")), 0, SCALES.size() - 1)
	if settings.has_section_key("video", "render_scale"):
		var scale := float(settings.get_value("video", "render_scale"))
		return 0 if scale <= 1.0 else (1 if scale < 1.2 else 2)
	return DEFAULT

static func load_sharpness(settings: ConfigFile) -> float:
	var value := float(settings.get_value("video", "sharpness", DEFAULT_SHARPNESS))
	return clampf(value, 0.0, 0.6) if is_finite(value) else DEFAULT_SHARPNESS
