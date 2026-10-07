extends RefCounted
## Display-only grading. Stored custom values survive selecting another preset.
const PRESETS := ["Original", "Warm", "Daylight", "Cool", "Custom"]
const DEFAULTS := {"temperature": 6500.0, "tint": 0.0, "exposure": 0.0, "contrast": 1.0,
	"gamma": 1.0, "saturation": 1.0, "red_gain": 1.0, "green_gain": 1.0, "blue_gain": 1.0,
	"red_gamma": 1.0, "green_gamma": 1.0, "blue_gamma": 1.0,
	"red_offset": 0.0, "green_offset": 0.0, "blue_offset": 0.0}
const PAGES := [["temperature", "tint", "exposure", "contrast", "gamma", "saturation"],
	["red_gain", "green_gain", "blue_gain"],
	["red_gamma", "green_gamma", "blue_gamma", "red_offset", "green_offset", "blue_offset"]]
const NAMES := {"temperature": "Temperature", "tint": "Tint", "exposure": "Exposure", "contrast": "Contrast",
	"gamma": "Gamma", "saturation": "Saturation", "red_gain": "Red gain", "green_gain": "Green gain", "blue_gain": "Blue gain",
	"red_gamma": "Red gamma", "green_gamma": "Green gamma", "blue_gamma": "Blue gamma",
	"red_offset": "Red offset", "green_offset": "Green offset", "blue_offset": "Blue offset"}
var preset := "Original"
var custom: Dictionary = DEFAULTS.duplicate()

static func limits(key: String) -> Vector3:
	match key:
		"temperature": return Vector3(2700, 9000, 100)
		"tint": return Vector3(-50, 50, 1)
		"exposure": return Vector3(-2, 2, 0.05)
		"contrast": return Vector3(0.5, 1.5, 0.01)
		"gamma", "red_gamma", "green_gamma", "blue_gamma": return Vector3(0.7, 1.4, 0.01)
		"saturation": return Vector3(0, 2, 0.01)
		"red_gain", "green_gain", "blue_gain": return Vector3(0, 2, 0.01)
	return Vector3(-0.2, 0.2, 0.005)

static func clean(key: String, value: Variant) -> float:
	var number := float(value) if value is float or value is int else float(DEFAULTS[key])
	if not is_finite(number): number = DEFAULTS[key]
	var span := limits(key)
	return roundf(clampf(snappedf(number, span.z), span.x, span.y) * 10000.0) / 10000.0

func restore(data: Variant) -> void:
	preset = "Original"
	custom = DEFAULTS.duplicate()
	if not data is Dictionary: return
	if data.get("preset", "") in PRESETS: preset = data.preset
	var saved: Variant = data.get("custom", {})
	if saved is Dictionary:
		for key in DEFAULTS: custom[key] = clean(key, saved.get(key, DEFAULTS[key]))

func snapshot() -> Dictionary:
	return {"preset": preset, "custom": custom.duplicate()}

func values() -> Dictionary:
	if preset == "Custom": return custom.duplicate()
	var result := DEFAULTS.duplicate()
	result.temperature = {"Warm": 4000.0, "Daylight": 6500.0, "Cool": 8000.0}.get(preset, 6500.0)
	return result

func select(name: String) -> void:
	if name in PRESETS: preset = name

func adjust(key: String, value: Variant) -> void:
	if not DEFAULTS.has(key): return
	# The first edit starts from the visible preset, then becomes the remembered custom look.
	if preset != "Custom": custom = values()
	preset = "Custom"
	custom[key] = clean(key, value)

func reset_custom() -> void:
	custom = DEFAULTS.duplicate()
	preset = "Custom"

static func kelvin(k: float) -> Vector3:
	var t := k / 100.0
	var r := 255.0 if t <= 66 else 329.698727446 * pow(t - 60, -0.1332047592)
	var g := 99.4708025861 * log(t) - 161.1195681661 if t <= 66 else 288.1221695283 * pow(t - 60, -0.0755148492)
	var b := 255.0 if t >= 66 else 138.5177312231 * log(t - 10) - 305.0447927307
	return Vector3(clampf(r, 0, 255), clampf(g, 0, 255), clampf(b, 0, 255)) / 255.0

func apply(material: ShaderMaterial) -> void:
	if not material: return
	var p := values()
	var gains := kelvin(p.temperature) / kelvin(6500)
	var magenta := maxf(p.tint, 0) / 50.0
	var green := maxf(-p.tint, 0) / 50.0
	gains *= Vector3(1 + 0.12 * magenta, 1 + 0.12 * green - 0.08 * magenta, 1 + 0.12 * magenta)
	gains /= gains.dot(Vector3(0.2126, 0.7152, 0.0722))
	material.set_shader_parameter("grade_enabled", preset != "Original")
	material.set_shader_parameter("grade_gain", gains * pow(2, p.exposure) * Vector3(p.red_gain, p.green_gain, p.blue_gain))
	material.set_shader_parameter("grade_gamma", Vector3(p.red_gamma, p.green_gamma, p.blue_gamma) * p.gamma)
	material.set_shader_parameter("grade_offset", Vector3(p.red_offset, p.green_offset, p.blue_offset))
	material.set_shader_parameter("grade_contrast", p.contrast)
	material.set_shader_parameter("grade_saturation", p.saturation)
