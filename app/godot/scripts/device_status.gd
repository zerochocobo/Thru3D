extends Node3D
## Headset battery and clock in a small pill under a menu, as in SKYBOX. Reads the platform's
## device_status() itself; without one (desktop preview) only the clock shows.

const Menu := preload("res://scripts/ray_menu.gd")
const Icons := preload("res://scripts/menu_icons.gd")
const I18n := preload("res://scripts/i18n.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const HEIGHT := 0.046
const ICON := 0.036
const FONT_SIZE := 16
const LOW := 20
const LOW_COLOR := Color(1.0, 0.42, 0.38)
const POWER_COLOR := Color(1.0, 0.76, 0.36)
const POLL_MS := 1000

## -> {"level": 0..100 or -1, "charging", "plugged", "clock24"}; tests inject one, otherwise the QuestPlayer singleton.
var status_provider: Callable
## -> {"hour", "minute"}; tests pin the clock.
var clock_provider: Callable = Time.get_time_dict_from_system
var _status: Dictionary = {}
var _polled_ms := -POLL_MS
var _shown := ""
var _pill: MeshInstance3D
var _battery: MeshInstance3D
var _fill: MeshInstance3D
var _bolt: MeshInstance3D
var _label: Label3D

func _ready() -> void:
	if not status_provider.is_valid() and Engine.has_singleton("QuestPlayer"):
		var plugin := Engine.get_singleton("QuestPlayer")
		if Methods.supports(plugin, "device_status"):
			status_provider = func() -> Dictionary:
				var parsed: Variant = JSON.parse_string(str(plugin.device_status()))
				return parsed if parsed is Dictionary else {}
	_pill = _quad(Vector2(0.2, HEIGHT), Vector3.ZERO, Color(Menu.PANEL, 0.86), 10)
	_pill.material_override.set_shader_parameter("corner_radius", HEIGHT * 0.5)
	_battery = _icon("battery", Color(0.93, 0.95, 0.98))
	# Inside of the battery outline (icon units 8.5..15.5 x 5.5..20.5 of 24), filled from the bottom.
	_fill = _quad(Vector2(ICON * 7.0 / 24, ICON * 15.0 / 24), Vector3.ZERO, Color.WHITE, 12)
	_fill.material_override.set_shader_parameter("corner_radius", 0.002)
	_bolt = _icon("bolt", Menu.ACCENT)
	_label = Label3D.new()
	_label.font = Menu.ui_font()
	_label.font_size = FONT_SIZE
	_label.pixel_size = 0.0012
	_label.no_depth_test = false
	_label.render_priority = 12
	_label.outline_size = 0
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	add_child(_label)
	refresh(true)

func _process(_delta: float) -> void:
	if is_visible_in_tree():
		refresh()

## Polls the battery once a second; redraws on clock, level or power-state changes.
func refresh(force: bool = false) -> void:
	var now := Time.get_ticks_msec()
	if force or now - _polled_ms >= POLL_MS:
		_polled_ms = now
		_status = status_provider.call() if status_provider.is_valid() else {}
	var level := int(_status.get("level", -1))
	var charging := bool(_status.get("charging", false))
	var plugged := bool(_status.get("plugged", charging))
	var text := ("%d%%   " % level if level >= 0 else "") + clock_text()
	var key := "%s|%d|%s|%s" % [text, level, charging, plugged]
	if key == _shown and not force:
		return
	_shown = key
	_label.text = text
	var has_battery := level >= 0
	_battery.visible = has_battery
	_fill.visible = has_battery and level > 0
	_bolt.visible = has_battery and (charging or plugged)
	_bolt.material_override.albedo_color = Menu.ACCENT if charging else POWER_COLOR
	var text_width := Menu.FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x * _label.pixel_size
	# Leave room for the larger charging glyph, including space from the battery outline.
	var battery_slot := ICON * 0.5 if has_battery else 0.0
	var bolt_slot := ICON * 0.55 if _bolt.visible else 0.0
	var gap := 0.008 if has_battery else 0.0
	var content := battery_slot + bolt_slot + gap + text_width
	_pill.mesh.size = Vector2(content + HEIGHT * 0.8, HEIGHT)
	_pill.material_override.set_shader_parameter("surface_size", _pill.mesh.size)
	var left := -content / 2
	_battery.position = Vector3(left + battery_slot / 2, 0, 0.002)
	_bolt.position = Vector3(left + battery_slot + bolt_slot / 2, 0, 0.002)
	var full := ICON * 15.0 / 24
	var height := maxf(0.001, full * clampi(level, 0, 100) / 100.0)
	_fill.mesh.size = Vector2(ICON * 7.0 / 24, height)
	_fill.material_override.set_shader_parameter("surface_size", _fill.mesh.size)
	# Outline interior spans y 5.5..20.5 of 24 (top to bottom); grow upwards from the bottom.
	_fill.position = Vector3(_battery.position.x, ICON * (0.5 - 20.5 / 24) + height / 2, 0.003)
	var low := has_battery and level < LOW and not charging
	var foreground := Color(0.93, 0.95, 0.98)
	_fill.material_override.set_shader_parameter("surface_color", Menu.ACCENT if charging else (LOW_COLOR if low else foreground))
	_battery.material_override.albedo_color = Menu.ACCENT if charging else (LOW_COLOR if low else foreground)
	_label.position = Vector3(left + battery_slot + bolt_slot + gap, 0, 0.003)

func clock_text() -> String:
	var now: Dictionary = clock_provider.call()
	var hour := int(now.get("hour", 0))
	var minute := int(now.get("minute", 0))
	if bool(_status.get("clock24", true)):
		return "%02d:%02d" % [hour, minute]
	var half := I18n.t("AM" if hour < 12 else "PM")
	var twelve := 12 if hour % 12 == 0 else hour % 12
	return "%s %d:%02d" % [half, twelve, minute] if I18n.language == "zh" else "%d:%02d %s" % [twelve, minute, half]

func text_snapshot() -> String:
	return _label.text

func _icon(key: String, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE * ICON
	node.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.render_priority = 12
	material.albedo_color = color
	material.albedo_texture = Icons.texture(key)
	node.material_override = material
	add_child(node)
	return node

func _quad(size: Vector2, location: Vector3, color: Color, priority: int) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.position = location
	var surface := ShaderMaterial.new()
	surface.shader = Menu.SURFACE
	surface.render_priority = priority
	surface.set_shader_parameter("surface_color", color)
	surface.set_shader_parameter("surface_size", size)
	node.material_override = surface
	add_child(node)
	return node
