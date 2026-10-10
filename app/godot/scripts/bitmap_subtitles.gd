extends RefCounted
## A changed PGS cue uploads one occupied RGBA crop; native pixels are premultiplied.
var texture: ImageTexture
var version := 0
var source := 0

func clear(material: ShaderMaterial) -> void:
	if material:
		material.set_shader_parameter("bitmap_subtitle_enabled", false)
	texture = null
	version = 0
	source = 0

func needs_pixels(bitmap: Dictionary, source_handle: int) -> bool:
	return not texture or version != int(bitmap.get("version", 0)) or source != source_handle

func apply(material: ShaderMaterial, bitmap: Dictionary, source_handle: int, pixels: PackedByteArray) -> bool:
	if not material or bitmap.is_empty():
		clear(material)
		return false
	if needs_pixels(bitmap, source_handle):
		var w := int(bitmap.get("width", 0))
		var h := int(bitmap.get("height", 0))
		if w <= 0 or h <= 0 or pixels.size() != w * h * 4:
			clear(material)
			return false
		var image := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, pixels)
		texture = ImageTexture.create_from_image(image)
		version = int(bitmap.version)
		source = source_handle
	var canvas := Vector2(float(bitmap.canvas_width), float(bitmap.canvas_height))
	material.set_shader_parameter("bitmap_subtitle_texture", texture)
	material.set_shader_parameter("bitmap_subtitle_rect", Vector4(float(bitmap.x) / canvas.x, float(bitmap.y) / canvas.y,
		float(bitmap.width) / canvas.x, float(bitmap.height) / canvas.y))
	material.set_shader_parameter("bitmap_subtitle_enabled", true)
	return true
