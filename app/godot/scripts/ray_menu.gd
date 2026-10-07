extends Node3D

const PAGE_SIZE := 7
const NONE := -1
const PREVIOUS := -2
const NEXT := -3
const CLOSE := -4
const MAX_RAY_METRES := 5.0
const SURFACE := preload("res://shaders/menu_surface.gdshader")
const Icons := preload("res://scripts/menu_icons.gd")
const I18n := preload("res://scripts/i18n.gd")
const DeviceStatus := preload("res://scripts/device_status.gd")
const PANEL := Color(0.065, 0.075, 0.095, 0.98)
const TILE := Color(0.105, 0.12, 0.15, 1.0)
const ACCENT := Color(0.54, 0.93, 0.77)
const MUTED := Color(0.56, 0.62, 0.69)
# File names and the menu are often Chinese/Japanese: fall back to the system CJK font.
static var FONT: Font = _make_font()
static var _font_language := I18n.language
static func _make_font() -> Font:
	var font := SystemFont.new()
	var names := ["Noto Sans CJK SC", "Noto Sans SC", "Microsoft YaHei", "PingFang SC"]
	if I18n.language == "zh_Hant":
		names = ["Noto Sans CJK TC", "Noto Sans TC", "Microsoft JhengHei", "PingFang TC"]
	elif I18n.language == "ja":
		names = ["Noto Sans CJK JP", "Noto Sans JP", "Yu Gothic", "Meiryo", "Hiragino Sans"]
	font.font_names = PackedStringArray(names + ["sans-serif"])
	font.fallbacks = [ThemeDB.fallback_font]
	return font

static func ui_font() -> Font:
	if _font_language != I18n.language:
		_font_language = I18n.language
		FONT = _make_font()
	return FONT

var _buttons: Array[Dictionary] = []
var _labels: Array[Label3D] = []
var _hover: Dictionary = {}
var _pointers: Dictionary = {}
var _decorations: Array[Node3D] = []
var _backdrop: MeshInstance3D
## Hover names of icon-only buttons (target -> text), shown over the hovered button.
var _tips: Dictionary = {}
var _tooltip: MeshInstance3D
## Battery and clock pill under the panel; kept across redraws.
var device_status: Node3D

func _ready() -> void:
	position = Vector3(0, -0.03, -1.55)
	_backdrop = _quad(Vector2(1.55, 1.08), Vector3.ZERO, PANEL, 10)
	add_child(_backdrop)
	visible = false

func toggle() -> void:
	if visible:
		dismiss()
	else:
		visible = true
		_reset_navigation()
		refresh()

func dismiss() -> void:
	visible = false
	_hover.clear()
	for pointer in _pointers.values():
		pointer.line.visible = false
		pointer.dot.visible = false

func _reset_navigation() -> void:
	pass

func refresh() -> void:
	_draw()

func _activate(_target: int) -> void:
	pass

func _draw() -> void:
	pass

# Origins/directions are in world space, including recenter/origin/menu transforms. Each button is
# tested on its own plane, so panels may be angled (the library's side column); the nearest wins.
# "point" is in this menu's space.
func ray_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	if not visible or not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.000001:
		return {}
	var ray := direction.normalized()
	var best := {}
	for button in _buttons:
		if not button.enabled or not button.node.visible:
			continue
		var inverse: Transform3D = button.node.global_transform.affine_inverse()
		var start: Vector3 = inverse * origin
		var delta: Vector3 = inverse.basis * ray
		# Only the front face accepts input; parallel, rear and behind-origin hits fail.
		if delta.z >= -0.00001 or start.z <= 0.0:
			continue
		var local := start + delta * (-start.z / delta.z)
		var half: Vector2 = button.rect.size * 0.5
		var radius := minf(0.012, minf(half.x, half.y))
		var corner := Vector2(absf(local.x), absf(local.y)) - (half - Vector2.ONE * radius)
		if corner.x > radius or corner.y > radius or corner.max(Vector2.ZERO).length() > radius:
			continue
		var world: Vector3 = button.node.global_transform * Vector3(local.x, local.y, 0)
		var distance := origin.distance_to(world)
		if distance > MAX_RAY_METRES or (not best.is_empty() and distance >= float(best.distance)):
			continue
		best = {"target": button.target, "point": to_local(world), "distance": distance}
	return best

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if not visible:
		return
	var hit := ray_hit(origin, direction) if tracked else {}
	_hover[hand] = int(hit.get("target", NONE))
	var pointer := _pointer(hand)
	var valid := tracked and origin.is_finite() and direction.is_finite() and direction.length_squared() > 0.000001
	pointer.line.visible = valid
	pointer.dot.visible = not hit.is_empty()
	if valid:
		var endpoint: Vector3 = to_global(hit.point) if not hit.is_empty() else origin + direction.normalized() * MAX_RAY_METRES
		var mesh: ImmediateMesh = pointer.line.mesh
		mesh.clear_surfaces()
		mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		mesh.surface_add_vertex(to_local(origin))
		mesh.surface_add_vertex(to_local(endpoint) + Vector3(0, 0, 0.006))
		mesh.surface_end()
		if not hit.is_empty():
			pointer.dot.position = hit.point + Vector3(0, 0, 0.008)
	_update_highlights()

func cancel_pointer(hand: String) -> void:
	update_pointer(hand, Vector3.ZERO, Vector3.ZERO, false)

func press_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	# Recompute at trigger time. A stale hover or the other hand cannot click.
	update_pointer(hand, origin, direction, tracked)
	var hit := ray_hit(origin, direction) if tracked else {}
	if hit.is_empty():
		return false
	_activate_hit(hit)
	return true

func _activate_hit(hit: Dictionary) -> void:
	_activate(int(hit.target))

func _set_backdrop(size: Vector2, centre: Vector2 = Vector2.ZERO) -> void:
	_backdrop.mesh.size = size
	_backdrop.position = Vector3(centre.x, centre.y, 0)
	_backdrop.material_override.set_shader_parameter("surface_size", size)

func _clear_layout() -> void:
	for button in _buttons:
		button.node.free()
	_buttons.clear()
	for label in _labels:
		label.free()
	_labels.clear()
	for decoration in _decorations:
		decoration.free()
	_decorations.clear()
	_tips.clear()
	if _tooltip:
		_tooltip.visible = false
	_hover.clear()
	for pointer in _pointers.values():
		pointer.dot.visible = false

func _button(target: int, text: String, centre: Vector2, size: Vector2, enabled: bool = true,
		icon: String = "", primary: bool = false, parent: Node3D = null) -> void:
	var base := ACCENT if primary else TILE
	var foreground := Color(0.045, 0.1, 0.085) if primary else Color(0.93, 0.95, 0.98)
	var node := _quad(size, Vector3(centre.x, centre.y, 0.002), base, 11)
	(parent if parent else self).add_child(node)
	var label := _label(text, Vector3(0, -size.y * 0.26 if not icon.is_empty() else 0, 0.004), 19 if not icon.is_empty() else 23, node)
	label.modulate = foreground if enabled else MUTED * Color(0.7, 0.7, 0.7)
	if not icon.is_empty():
		# Icon-only buttons centre a larger glyph; captioned buttons stack icon over text.
		var alone := text.is_empty()
		_icon(icon, Vector3(0, 0 if alone else size.y * 0.15, 0.004), minf(size.y * (0.55 if alone else 0.38), 0.05 if alone else 0.045),
			foreground if enabled else MUTED, node)
	_buttons.append({"target": target, "rect": Rect2(centre - size / 2, size), "enabled": enabled, "node": node,
		"base_color": base, "foreground": foreground})

## Icon-only round button (play, floating actions); [tip] names it while a ray hovers it.
func _round(target: int, icon: String, centre: Vector2, diameter: float, enabled: bool = true,
		primary: bool = false, tip: String = "") -> void:
	_button(target, "", centre, Vector2.ONE * diameter, enabled, icon, primary)
	_buttons.back().node.material_override.set_shader_parameter("corner_radius", diameter * 0.5)
	if not tip.is_empty():
		_tips[target] = tip

## Icon over the panel without a tile of its own: only hover lights it up.
func _glyph(target: int, icon: String, centre: Vector2, size: float, enabled: bool = true, tip: String = "") -> void:
	_button(target, "", centre, Vector2.ONE * size, enabled, icon)
	var button: Dictionary = _buttons.back()
	button.base_color = Color(TILE, 0.0)
	button.node.material_override.set_shader_parameter("corner_radius", size * 0.5)
	if not tip.is_empty():
		_tips[target] = tip

## Puts the battery and clock pill centred at [centre], under the panel like SKYBOX.
func _place_device_status(centre: Vector2) -> void:
	if not device_status:
		device_status = DeviceStatus.new()
		add_child(device_status)
	device_status.position = Vector3(centre.x, centre.y, 0.002)

func _decoration(size: Vector2, centre: Vector2, color: Color) -> MeshInstance3D:
	var node := _quad(size, Vector3(centre.x, centre.y, 0.003), color, 12)
	add_child(node)
	_decorations.append(node)
	return node

func _icon(key: String, location: Vector3, size: float, color: Color, parent: Node = self) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE * size
	node.mesh = mesh
	node.position = location
	var material := _material(color, 12)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_texture = Icons.texture(key)
	node.material_override = material
	parent.add_child(node)
	if parent == self: _decorations.append(node)
	return node

func _quad(size: Vector2, location: Vector3, color: Color, priority: int) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.position = location
	var surface := ShaderMaterial.new()
	surface.shader = SURFACE
	surface.render_priority = priority
	surface.set_shader_parameter("surface_color", color)
	surface.set_shader_parameter("surface_size", size)
	surface.set_shader_parameter("corner_radius", 0.028 if priority == 10 else 0.012)
	node.material_override = surface
	return node

func _material(color: Color, priority: int) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.no_depth_test = true
	material.render_priority = priority
	return material

func _label(text: String, location: Vector3, size: int, parent: Node = self) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font = ui_font()
	label.language = I18n.language
	label.font_size = size
	label.pixel_size = 0.0012
	label.position = location
	label.no_depth_test = true
	label.render_priority = 12
	label.outline_size = 0
	parent.add_child(label)
	if parent == self:
		_labels.append(label)
	return label

func _pointer(hand: String) -> Dictionary:
	if _pointers.has(hand):
		return _pointers[hand]
	var color := Color(0.15, 0.9, 1.0) if hand == "left_hand" else Color(1.0, 0.65, 0.15)
	var line := MeshInstance3D.new()
	line.mesh = ImmediateMesh.new()
	line.material_override = _material(color, 14)
	add_child(line)
	var dot := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.009
	sphere.height = 0.018
	dot.mesh = sphere
	dot.material_override = _material(color, 15)
	add_child(dot)
	_pointers[hand] = {"line": line, "dot": dot}
	return _pointers[hand]

func _update_highlights() -> void:
	for button in _buttons:
		var hovered: bool = button.enabled and _hover.values().has(button.target)
		var color: Color = button.base_color
		if not button.enabled: color = Color(0.085, 0.095, 0.115, button.base_color.a)
		elif hovered: color = Color(0.67, 1.0, 0.86) if button.base_color == ACCENT else Color(0.23, 0.43, 0.38)
		button.node.material_override.set_shader_parameter("surface_color", color)
	_update_tooltip()

func _update_tooltip() -> void:
	var shown := {}
	for button in _buttons:
		if button.enabled and _tips.has(button.target) and _hover.values().has(button.target):
			shown = button
			break
	if shown.is_empty():
		if _tooltip:
			_tooltip.visible = false
		return
	if not _tooltip:
		_tooltip = _quad(Vector2(0.2, 0.05), Vector3.ZERO, Color(0.02, 0.025, 0.03, 0.92), 16)
		add_child(_tooltip)
		var text := _label("", Vector3(0, 0, 0.002), 17, _tooltip)
		text.render_priority = 17
	var label: Label3D = _tooltip.get_child(0)
	label.text = str(_tips[shown.target])
	var width := FONT.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x * 0.0012 + 0.04
	var size := Vector2(width, 0.046)
	_tooltip.mesh.size = size
	_tooltip.material_override.set_shader_parameter("surface_size", size)
	var rect: Rect2 = shown.rect
	_tooltip.position = Vector3(rect.get_center().x, rect.end.y + 0.04, 0.012)
	_tooltip.visible = true

func _fit_title(title: String, suffix: String, width: float = 1.32, font_size: int = 26) -> String:
	var fits := func(text: String) -> bool:
		return ui_font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x * 0.0012 <= width
	if title.is_empty() or fits.call(title + suffix):
		return title + suffix
	# Longest prefix that fits with the ellipsis, by bisection: every measure shapes the text.
	var low := 0
	var high := title.length() - 1
	while low < high:
		var middle := (low + high + 1) / 2
		if fits.call(title.left(middle) + "…" + suffix):
			low = middle
		else:
			high = middle - 1
	return title.left(low) + "…" + suffix

func text_snapshot() -> String:
	var lines := PackedStringArray()
	for label in _labels:
		lines.append(label.text)
	for button in _buttons:
		lines.append(button.node.get_child(0).text)
	return "\n".join(lines)
