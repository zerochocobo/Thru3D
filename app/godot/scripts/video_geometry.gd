extends RefCounted

enum Geometry { FLAT, HALF_EQUIRECT, FISHEYE, EQUIRECT_360 }

## Inside of a sphere band spanning [span] radians of longitude around -Z (PI: VR180, TAU: 360).
static func hemisphere(radius: float = 50.0, columns: int = 72, rows: int = 36, span: float = PI) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var uv := PackedVector2Array()
	var indices := PackedInt32Array()
	for row in rows + 1:
		var v := float(row) / rows
		var latitude := (0.5 - v) * PI
		for column in columns + 1:
			var u := float(column) / columns
			var longitude := (u - 0.5) * span
			vertices.append(Vector3(sin(longitude) * cos(latitude), sin(latitude), -cos(longitude) * cos(latitude)) * radius)
			uv.append(Vector2(u, v))
	for row in rows:
		for column in columns:
			var a := row * (columns + 1) + column
			var b := a + columns + 1
			indices.append_array(PackedInt32Array([a, b, a + 1, a + 1, b, b + 1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

static func packed_dimensions(width: int, height: int) -> Vector2i:
	# PTMediaServer pack_uploaded: round(W*.4)&~3, round(H*.4)&~1.
	return Vector2i(maxi(4, int(round(width * 0.4)) & ~3), maxi(2, int(round(height * 0.4)) & ~1))

static func legacy_compatible(format: Dictionary, stereo: bool, geometry: int) -> bool:
	var width := int(format.get("width", 0))
	var height := int(format.get("height", 0))
	return geometry == Geometry.FISHEYE and stereo and width >= 2 * height and height >= 10 \
		and width % 2 == 0 and height % 2 == 0 and int(format.get("unapplied_rotation_degrees", -1)) == 0 \
		and is_equal_approx(float(format.get("pixel_aspect", 0.0)), 1.0)
