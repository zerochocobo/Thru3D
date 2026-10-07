extends RefCounted
## Borrowed native GL names. Caller must claim a complete pair before bind(),
## and keep the native display lease until unbind() plus the post-draw fence.
## This helper neither claims nor retires native slots.

const PAIR_SHADER := preload("res://shaders/video_rvm_pair.gdshader")
const DECODER_SHADER := preload("res://shaders/video_rvm_pair_oes.gdshader")

var material: ShaderMaterial
var color_rid := RID()
# Decoder images (MPV direct mode) arrive as EGLImages; one external texture is rebound per pair.
var _decoder_color: ExternalTexture
var alpha_rid := RID()
var ticket: Dictionary = {}
## 2D->3D: the bridge rendered this mono frame's stereo pair (side by side, 2W x H); it is shown
## instead of the color, with no shader parallax.
var warped := false

func bind(target: ShaderMaterial, pair: Dictionary) -> bool:
	if material or not target or not _valid(pair):
		return false
	warped = int(pair.get("warp_texture_id", 0)) > 0 and not bool(pair.stereo_sbs)
	var decoder := str(pair.get("color_target", "")) == "external" and not warped
	# A decimal string: JSON numbers are doubles and cannot carry a 64-bit pointer.
	var egl_image := str(pair.get("color_egl_image", "0")).to_int()
	if decoder and egl_image == 0:
		return false
	if warped:
		color_rid = RenderingServer.texture_create_from_native_handle(RenderingServer.TEXTURE_TYPE_2D,
			Image.FORMAT_RGBA8, int(pair.warp_texture_id), int(pair.width) * 2, int(pair.height), 1)
	elif not decoder:
		color_rid = RenderingServer.texture_create_from_native_handle(RenderingServer.TEXTURE_TYPE_2D,
			Image.FORMAT_RGBA8, int(pair.color_texture_id), int(pair.width), int(pair.height), 1)
	alpha_rid = RenderingServer.texture_create_from_native_handle(RenderingServer.TEXTURE_TYPE_2D,
		Image.FORMAT_R8, int(pair.alpha_texture_id), int(pair.alpha_width), int(pair.alpha_height), 1)
	if (not decoder and not color_rid.is_valid()) or not alpha_rid.is_valid():
		_free_wrappers()
		return false
	_use_shader(target, DECODER_SHADER if decoder else PAIR_SHADER)
	var rect: Array = pair.model_content_rect
	material = target
	ticket = pair.duplicate(true)
	if warped:
		ticket.stereo_sbs = true
		ticket.color_target = "texture"
	material.set_shader_parameter("source_size", Vector2(int(pair.width) * (2 if warped else 1), pair.height))
	material.set_shader_parameter("model_size", Vector2(pair.input_width, pair.input_height))
	material.set_shader_parameter("model_content_rect", Vector4(rect[0], rect[1], rect[2], rect[3]))
	material.set_shader_parameter("stereo_sbs", bool(pair.stereo_sbs) or warped)
	material.set_shader_parameter("rotation_degrees", int(pair.rotation_degrees))
	# The GLES material backend accepts texture RIDs directly. Avoid CPU copies.
	if decoder:
		if not _decoder_color:
			_decoder_color = ExternalTexture.new()
		_decoder_color.size = Vector2(int(pair.buffer_width), int(pair.buffer_height))
		_decoder_color.set_external_buffer_id(egl_image)
		var scale: Array = pair.get("color_uv_scale", [1.0, 1.0])
		material.set_shader_parameter("color_uv_scale", Vector2(float(scale[0]), float(scale[1])))
		RenderingServer.material_set_param(material.get_rid(), "color_texture", _decoder_color.get_rid())
	else:
		RenderingServer.material_set_param(material.get_rid(), "color_texture", color_rid)
	RenderingServer.material_set_param(material.get_rid(), "alpha_texture", alpha_rid)
	return true

## The bound frame's colour texture (the decoder image in direct mode).
func color_texture() -> RID:
	return _decoder_color.get_rid() if str(ticket.get("color_target", "")) == "external" and _decoder_color else color_rid

func unbind() -> Dictionary:
	if material:
		RenderingServer.material_set_param(material.get_rid(), "color_texture", null)
		RenderingServer.material_set_param(material.get_rid(), "alpha_texture", null)
	material = null
	warped = false
	_free_wrappers()
	var previous := ticket
	ticket = {}
	return previous

## Switch between the RGBA and decoder-image shader, keeping every uniform the display set.
static func _use_shader(target: ShaderMaterial, shader: Shader) -> void:
	if target.shader == shader:
		return
	var values := {}
	if target.shader:
		for uniform in target.shader.get_shader_uniform_list():
			var name := str(uniform.name)
			if not name in ["color_texture", "alpha_texture"]:
				values[name] = target.get_shader_parameter(name)
	target.shader = shader
	for name in values:
		if values[name] != null:
			target.set_shader_parameter(name, values[name])

func _free_wrappers() -> void:
	for rid in [color_rid, alpha_rid]:
		if rid.is_valid():
			RenderingServer.free_rid(rid)
	color_rid = RID()
	alpha_rid = RID()

static func _valid(pair: Dictionary) -> bool:
	for key in ["session_id", "logical_session_id", "generation", "frame_id", "pts_us", "format_revision",
		"effect_revision", "model_generation", "slot_token", "color_texture_id", "alpha_texture_id",
		"width", "height", "input_width", "input_height", "alpha_width", "alpha_height",
		"rotation_degrees", "model_content_rect", "stereo_sbs", "alpha_slot_token", "alpha_frame_id", "alpha_pts_us"]:
		if not pair.has(key):
			return false
	if not pair.get("source_pts_verified", false) or not pair.get("immutable_color_frame", false) \
		or not pair.get("pair_identity_verified", false) or not pair.get("alpha_fence_ready", false) \
		or not pair.get("alpha_gpu_uploaded", false) or pair.get("alpha_texture_format") != "GL_R8_numeric":
		return false
	for key in ["session_id", "logical_session_id", "generation", "format_revision", "effect_revision", "model_generation",
		"slot_token", "color_texture_id", "alpha_texture_id", "width", "height", "input_width", "input_height"]:
		if int(pair[key]) <= 0:
			return false
	if int(pair.frame_id) < 0 or int(pair.pts_us) < 0 or pair.color_texture_id == pair.alpha_texture_id:
		return false
	if pair.alpha_slot_token != pair.slot_token or pair.alpha_frame_id != pair.frame_id or pair.alpha_pts_us != pair.pts_us:
		return false
	if int(pair.alpha_width) != int(pair.input_width) * 2 or int(pair.alpha_height) != int(pair.input_height):
		return false
	if int(pair.rotation_degrees) not in [0, 90, 180, 270] or (bool(pair.stereo_sbs) and int(pair.width) % 2 != 0):
		return false
	var rect: Variant = pair.model_content_rect
	if not rect is Array or rect.size() != 4:
		return false
	for value in rect:
		if not (value is float or value is int) or not is_finite(float(value)):
			return false
	# model = rect.xy + eye * rect.zw. Letterbox: the eye lies inside the model.
	# ROI zoom: the model window [-xy/zw, (1-xy)/zw] lies inside the eye (zoom <= 8x).
	for axis in [0, 1]:
		var offset := float(rect[axis])
		var scale := float(rect[axis + 2])
		if scale <= 0 or scale > 8.0:
			return false
		var letterbox := offset >= 0 and offset + scale <= 1.000001
		var window_start := -offset / scale
		var window_end := (1.0 - offset) / scale
		var zoom := window_start >= -0.000001 and window_end <= 1.000001
		if not letterbox and not zoom:
			return false
		if letterbox:
			var size := float(pair.input_width if axis == 0 else pair.input_height)
			if ceilf(offset * size - 0.5) > floorf((offset + scale) * size - 0.5):
				return false
	return true
