extends RefCounted
## Read bounded headers before decoding. Dimensions never imply stereo or spherical projection.
const EXTENSIONS := ["jpg", "jpeg", "png", "webp"]
static func is_image(uri: String, title: String = "") -> bool:
	return title.get_extension().to_lower() in EXTENSIONS or uri.get_slice("?", 0).get_slice("#", 0).uri_decode().get_extension().to_lower() in EXTENSIONS

static func _u16(bytes: PackedByteArray, offset: int, little: bool = false) -> int:
	if offset < 0 or offset + 2 > bytes.size(): return 0
	return bytes[offset] | (bytes[offset + 1] << 8) if little else (bytes[offset] << 8) | bytes[offset + 1]

static func _u32(bytes: PackedByteArray, offset: int, little: bool = false) -> int:
	if offset < 0 or offset + 4 > bytes.size(): return 0
	return _u16(bytes, offset, true) | (_u16(bytes, offset + 2, true) << 16) if little else (_u16(bytes, offset) << 16) | _u16(bytes, offset + 2)

static func read_header(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file or file.get_length() > 256 * 1024 * 1024: return {}
	var b := file.get_buffer(mini(file.get_length(), 1024 * 1024))
	if b.size() < 30: return {}
	var info := {"width": 0, "height": 0, "orientation": 1, "panorama": false}
	if b[0] == 0x89 and b.slice(1, 4).get_string_from_ascii() == "PNG":
		info["codec"] = "png"
		info.width = _u32(b, 16); info.height = _u32(b, 20)
	elif b.slice(0, 4).get_string_from_ascii() == "RIFF" and b.slice(8, 12).get_string_from_ascii() == "WEBP":
		info["codec"] = "webp"
		var format := b.slice(12, 16).get_string_from_ascii()
		if format == "VP8X":
			info.width = 1 + b[24] + (b[25] << 8) + (b[26] << 16)
			info.height = 1 + b[27] + (b[28] << 8) + (b[29] << 16)
		elif format == "VP8L" and b[20] == 0x2f:
			info.width = 1 + b[21] + ((b[22] & 63) << 8)
			info.height = 1 + (b[22] >> 6) + (b[23] << 2) + ((b[24] & 15) << 10)
		elif format == "VP8 " and b[23] == 0x9d and b[24] == 1 and b[25] == 0x2a:
			info.width = _u16(b, 26, true) & 0x3fff; info.height = _u16(b, 28, true) & 0x3fff
	elif b[0] == 0xff and b[1] == 0xd8:
		info["codec"] = "jpg"
		var at := 2
		while at + 4 < b.size():
			if b[at] != 0xff: break
			while at < b.size() and b[at] == 0xff: at += 1
			if at >= b.size(): break
			var marker := int(b[at]); at += 1
			if marker in [0xda, 0xd9]: break
			var length := _u16(b, at)
			if length < 2 or at + length > b.size(): break
			if marker in [0xc0, 0xc1, 0xc2] and length >= 8:
				info.height = _u16(b, at + 3); info.width = _u16(b, at + 5)
			if marker == 0xe1 and length >= 16 and b.slice(at + 2, at + 6).get_string_from_ascii() == "Exif":
				var tiff := at + 8
				var little := b[tiff] == 0x49
				var table := tiff + _u32(b, tiff + 4, little)
				if table >= tiff and table + 2 < at + length:
					for index in mini(_u16(b, table, little), 256):
						var entry := table + 2 + index * 12
						if entry + 12 > at + length: break
						if _u16(b, entry, little) == 0x112 and _u16(b, entry + 2, little) == 3 and _u32(b, entry + 4, little) == 1:
							info.orientation = _u16(b, entry + 8, little)
			if marker == 0xe1 and length > 7 and _u32(b, at + 2) == 0x68747470 and b[at + 6] == 58:
				var segment := b.slice(at + 2, at + length)
				var separator := segment.find(0)
				var xml := segment.slice(separator + 1).get_string_from_utf8() if separator >= 0 else ""
				if xml.contains('GPano:ProjectionType="equirectangular"') or xml.contains('<GPano:ProjectionType>equirectangular</GPano:ProjectionType>'):
					info.panorama = true
				for key in ["FullPanoWidthPixels", "FullPanoHeightPixels", "CroppedAreaImageWidthPixels", "CroppedAreaImageHeightPixels", "CroppedAreaLeftPixels", "CroppedAreaTopPixels"]:
					var match := RegEx.create_from_string('GPano:' + key + '(?:="|>)([0-9]+)').search(xml)
					if match: info[key] = int(match.get_string(1))
			at += length
	return info if info.width > 0 and info.height > 0 else {}

static func orient(image: Image, orientation: int) -> void:
	match orientation:
		2: image.flip_x()
		3: image.rotate_180()
		4: image.flip_y()
		5: image.rotate_90(CLOCKWISE); image.flip_x()
		6: image.rotate_90(CLOCKWISE)
		7: image.rotate_90(CLOCKWISE); image.flip_y()
		8: image.rotate_90(COUNTERCLOCKWISE)

static func panorama_rect(info: Dictionary) -> Vector4:
	var full := Vector2(float(info.get("FullPanoWidthPixels", 0)), float(info.get("FullPanoHeightPixels", 0)))
	var size := Vector2(float(info.get("CroppedAreaImageWidthPixels", 0)), float(info.get("CroppedAreaImageHeightPixels", 0)))
	var offset := Vector2(float(info.get("CroppedAreaLeftPixels", 0)), float(info.get("CroppedAreaTopPixels", 0)))
	if full.x > 0 and full.y > 0 and size.x > 0 and size.y > 0 and offset.x >= 0 and offset.y >= 0 and offset.x + size.x <= full.x and offset.y + size.y <= full.y:
		return Vector4(offset.x / full.x, offset.y / full.y, size.x / full.x, size.y / full.y)
	return Vector4(0, 0, 1, 1)
