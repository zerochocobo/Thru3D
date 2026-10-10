extends Node
## Live soft-caption patch, composed in the video's spherical coordinates like tool_subembed.
## Only cue changes redraw the canvas. Distance/pose changes update shader parameters.
const PATCH_SIZE := 700
var viewport: SubViewport
var label: Label
var _text := ""
var _vertical := false
var vertical_text: Control
const VerticalText := preload("res://scripts/vertical_subtitle_text.gd")

func _ready() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(PATCH_SIZE, PATCH_SIZE)
	viewport.transparent_bg = true
	viewport.world_2d = World2D.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	label = Label.new()
	label.size = Vector2(PATCH_SIZE, PATCH_SIZE)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 40)
	label.add_theme_constant_override("outline_size", 8)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	viewport.add_child(label)
	vertical_text = VerticalText.new()
	vertical_text.size = Vector2(PATCH_SIZE, PATCH_SIZE)
	vertical_text.visible = false
	viewport.add_child(vertical_text)

func clear(target: ShaderMaterial) -> void:
	if target: target.set_shader_parameter("subtitle_enabled", false)

func update_patch(caption: Label3D, target: ShaderMaterial, anchor: Basis, distance: float, ipd: float, vertical: bool = false) -> void:
	if not viewport or not caption.visible or caption.text.is_empty():
		clear(target)
		return
	if _text != caption.text or _vertical != vertical:
		_text = caption.text
		_vertical = vertical
		label.visible = not vertical
		vertical_text.visible = vertical
		if vertical:
			vertical_text.set_text(_text, preload("res://scripts/ray_menu.gd").ui_font())
		else:
			label.text = _text
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	target.set_shader_parameter("subtitle_texture", viewport.get_texture())
	target.set_shader_parameter("subtitle_enabled", true)
	target.set_shader_parameter("subtitle_anchor_inverse", anchor.transposed())
	# The reference moves the right-eye patch left by this complete angular separation.
	# Do not add it to a separate stereo-projected text plane as well.
	target.set_shader_parameter("subtitle_parallax", 2.0 * atan(ipd / (2.0 * distance)))

static func runtime_ipd() -> float:
	var xr := XRServer.primary_interface
	if xr and xr.is_initialized() and xr.get_view_count() == 2:
		var left := xr.get_transform_for_view(0, Transform3D.IDENTITY)
		var right := xr.get_transform_for_view(1, Transform3D.IDENTITY)
		return left.origin.distance_to(right.origin) / maxf(XRServer.world_scale, 0.0001)
	return 0.063 # Desktop preview; physical XR obtains the current runtime eye positions.
