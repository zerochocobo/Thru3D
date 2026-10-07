extends Node3D
## Shared spatial surface only: decoding, playback clocks and photo queues live in their owners.
const Geometry := preload("res://scripts/video_geometry.gd")
var panel: MeshInstance3D
var material: ShaderMaterial
var view_camera: Camera3D
var geometry := Geometry.Geometry.FLAT
var stereo_sbs := false
var top_bottom := false
const FISHEYE_FOVS := [180, 190, 200, 220]
var fisheye_fov := 180
var swap_eyes := false
var _flat := QuadMesh.new()
## Where the flat screen stands (parent space); main places it in front of the viewer on open and recenter.
var flat_pose := Transform3D(Basis(), Vector3(0, 1.5, -2))
## Flat screen set by the viewer: distance from the eyes, size (corner drag) and curvature.
## A curve of 1 bends the screen round the eyes; smaller values bend it less.
const SCREEN_DISTANCE := 2.0
const DISTANCE_LIMITS := Vector2(0.8, 8.0)
const SCALE_LIMITS := Vector2(0.4, 3.0)
const CURVES := [0.0, 0.35, 0.7, 1.0]
var screen_distance := SCREEN_DISTANCE
var screen_scale := 1.0
var screen_curve := 0.0
var _screen_base := Vector2(1.9, 1.07)
var _curved: ArrayMesh
var _curved_key := Vector4.ZERO
## Corner brackets shown while a ray points at a corner (or drags one to resize).
var _handles: Array[MeshInstance3D] = []
var hovered_corner := -1
var _hemisphere: ArrayMesh
var _sphere: ArrayMesh
const SPHERE_RADIUS := 50.0
## Immersive view set by the viewer: a drag turns the sphere, the right stick moves its centre
## towards the picture (a fraction of the radius; negative moves the picture away).
var view_yaw := 0.0
var view_pitch := 0.0
var view_zoom := 0.0
const ZOOM_LIMITS := Vector2(-0.5, 0.6)

func initialize_surface(shader: Shader) -> void:
	panel = MeshInstance3D.new()
	panel.mesh = _flat
	panel.position = Vector3(0, 1.5, -2)
	panel.visible = false
	material = ShaderMaterial.new()
	material.shader = shader
	material.render_priority = -10
	panel.material_override = material
	add_child(panel)

func _source_size() -> Vector2:
	return Vector2(1920, 1080)

func _apply_geometry() -> void:
	if geometry == Geometry.Geometry.FLAT:
		panel.transform = flat_pose
		var dimensions := _source_size()
		var aspect := dimensions.x / maxf(1.0, dimensions.y) \
			/ (2.0 if stereo_sbs and not top_bottom else 1.0) * (2.0 if stereo_sbs and top_bottom else 1.0)
		if aspect > 0:
			_screen_base = Vector2(minf(1.9, aspect), minf(1.9, aspect)/aspect)
			_flat.size = _screen_base * screen_scale
		_shape_screen()
	elif geometry == Geometry.Geometry.EQUIRECT_360 or (geometry == Geometry.Geometry.FISHEYE and fisheye_fov > 180):
		# Lenses wider than 180 degrees reach behind the viewer: the whole sphere, black beyond the lens.
		if not _sphere:
			_sphere = Geometry.hemisphere(SPHERE_RADIUS, 144, 72, TAU)
		panel.mesh = _sphere
		_center_on_view()
	else:
		if not _hemisphere:
			_hemisphere = Geometry.hemisphere(SPHERE_RADIUS)
		panel.mesh = _hemisphere
		_center_on_view()
	material.set_shader_parameter("video_geometry", geometry)
	# A 2D->3D stereo pair from the bridge is side by side; otherwise the shader adds the parallax.
	material.set_shader_parameter("stereo_sbs", stereo_sbs)
	material.set_shader_parameter("top_bottom", stereo_sbs and top_bottom)
	material.set_shader_parameter("fisheye_fov", float(fisheye_fov))
	material.set_shader_parameter("swap_eyes", swap_eyes)

## Immersive projections are centred on the eyes every frame. Runs on every presented video frame
## too, so it must never put the sphere anywhere else (that alternated with _process and shook the view).
func _center_on_view() -> void:
	panel.basis = Basis(Vector3.UP, view_yaw) * Basis(Vector3.RIGHT, view_pitch)
	if view_camera and view_camera.is_inside_tree():
		panel.global_position = view_camera.global_position
	else:
		panel.position = Vector3(0, 1.6, 0)
	panel.global_position += panel.global_basis * Vector3(0, 0, -view_zoom * SPHERE_RADIUS)

## Drag: the picture follows the controller (radians; positive yaw turns it left, pitch up).
func turn_view(yaw: float, pitch: float) -> void:
	view_yaw = wrapf(view_yaw + yaw, -PI, PI)
	view_pitch = clampf(view_pitch + pitch, -1.4, 1.4)
	if geometry != Geometry.Geometry.FLAT:
		_center_on_view()

## Positive brings the picture nearer.
func zoom_view(amount: float) -> void:
	view_zoom = clampf(view_zoom + amount, ZOOM_LIMITS.x, ZOOM_LIMITS.y)
	if geometry != Geometry.Geometry.FLAT:
		_center_on_view()

## The flat screen's mesh: the quad, or a cylinder section of radius distance / curve with the
## same width along the arc (the video maps by UV, so the picture bends with it).
func _shape_screen() -> void:
	if geometry != Geometry.Geometry.FLAT:
		_show_handles(-1)
		return
	if screen_curve <= 0.0:
		panel.mesh = _flat
	else:
		var key := Vector4(_flat.size.x, _flat.size.y, screen_curve, screen_distance)
		if not _curved or key != _curved_key:
			_curved_key = key
			_curved = _cylinder(_flat.size, _curve_radius())
		panel.mesh = _curved
	_show_handles(hovered_corner)

func _curve_radius() -> float:
	# At most ~140 degrees of arc, however wide the screen.
	return maxf(screen_distance / screen_curve, _flat.size.x / 2.4) if screen_curve > 0.0 else INF

static func _cylinder(size: Vector2, radius: float, columns: int = 48) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var uv := PackedVector2Array()
	var indices := PackedInt32Array()
	var half := size.x * 0.5 / radius
	for column in columns + 1:
		var u := float(column) / columns
		var angle := lerpf(-half, half, u)
		var x := sin(angle) * radius
		var z := (1.0 - cos(angle)) * radius
		vertices.append_array(PackedVector3Array([Vector3(x, size.y * 0.5, z), Vector3(x, -size.y * 0.5, z)]))
		uv.append_array(PackedVector2Array([Vector2(u, 0), Vector2(u, 1)]))
		if column < columns:
			var a := column * 2
			indices.append_array(PackedInt32Array([a, a + 2, a + 1, a + 1, a + 2, a + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

## Corner [index] (0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right) in the screen's space,
## and the angle the screen surface turns there.
func screen_corner(index: int) -> Vector3:
	var side := 1.0 if index % 2 == 1 else -1.0
	var y := _flat.size.y * 0.5 * (1.0 if index < 2 else -1.0)
	if screen_curve <= 0.0:
		return Vector3(side * _flat.size.x * 0.5, y, 0)
	var radius := _curve_radius()
	var angle := _flat.size.x * 0.5 / radius
	return Vector3(side * sin(angle) * radius, y, (1.0 - cos(angle)) * radius)

## The flat screen corner a ray points at (within a few degrees), or -1.
func corner_at(origin: Vector3, direction: Vector3) -> int:
	if geometry != Geometry.Geometry.FLAT or not panel.visible or direction.length_squared() < 0.000001:
		return -1
	var best := -1
	var closest := 0.07 # radians
	for index in 4:
		var angle := direction.angle_to(panel.global_transform * screen_corner(index) - origin)
		if angle < closest:
			closest = angle
			best = index
	return best

## Where a ray meets the screen's plane, in the screen's space; null when it misses.
func screen_point(origin: Vector3, direction: Vector3) -> Variant:
	var inverse := panel.global_transform.affine_inverse()
	var start := inverse * origin
	var delta := inverse.basis * direction
	if absf(delta.z) < 0.00001 or (-start.z / delta.z) <= 0.0:
		return null
	return start + delta * (-start.z / delta.z)

func set_screen_scale(value: float) -> void:
	screen_scale = clampf(value, SCALE_LIMITS.x, SCALE_LIMITS.y)
	_flat.size = _screen_base * screen_scale
	_shape_screen()

func set_screen_curve(value: float) -> void:
	screen_curve = clampf(value, 0.0, 1.0)
	_shape_screen()

func cycle_screen_curve() -> void:
	var index := CURVES.find(screen_curve)
	set_screen_curve(CURVES[(index + 1) % CURVES.size()])

## Main moves the screen nearer or farther; a curved screen keeps bending round the eyes.
func set_screen_distance(value: float) -> void:
	screen_distance = clampf(value, DISTANCE_LIMITS.x, DISTANCE_LIMITS.y)
	_shape_screen()

## Brackets on one corner ([index]) or none (-1); they bend with the screen.
func _show_handles(index: int) -> void:
	hovered_corner = index
	if index >= 0 and _handles.is_empty():
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.no_depth_test = true
		material.albedo_color = Color(1, 1, 1, 0.9)
		material.render_priority = 5
		for corner in 4:
			var bracket := MeshInstance3D.new()
			bracket.mesh = _bracket()
			bracket.material_override = material
			panel.add_child(bracket)
			_handles.append(bracket)
	for corner in _handles.size():
		var bracket := _handles[corner]
		bracket.visible = corner == index and geometry == Geometry.Geometry.FLAT
		if bracket.visible:
			var turn := 0.0 if screen_curve <= 0.0 else _flat.size.x * 0.5 / _curve_radius() * (1.0 if corner % 2 == 1 else -1.0)
			var mirror := Vector3(1.0 if corner % 2 == 1 else -1.0, 1.0 if corner < 2 else -1.0, 1.0)
			bracket.transform = Transform3D(Basis(Vector3.UP, -turn) * Basis.from_scale(mirror * screen_distance / SCREEN_DISTANCE),
				screen_corner(corner) + Vector3(0, 0, 0.01).rotated(Vector3.UP, -turn))

## An L outside a top-right corner (mirrored for the others).
static func _bracket() -> ArrayMesh:
	var arm := 0.12
	var width := 0.016
	var gap := 0.012
	var quads := [Rect2(-arm + gap, gap, arm, width), Rect2(gap, gap - arm + width, width, arm)]
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	for item in quads:
		var quad: Rect2 = item
		var a := vertices.size()
		vertices.append_array(PackedVector3Array([Vector3(quad.position.x, quad.end.y, 0), Vector3(quad.end.x, quad.end.y, 0),
			Vector3(quad.position.x, quad.position.y, 0), Vector3(quad.end.x, quad.position.y, 0)]))
		indices.append_array(PackedInt32Array([a, a + 1, a + 2, a + 2, a + 1, a + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func set_corner_hover(index: int) -> void:
	if index != hovered_corner:
		_show_handles(index)

func reset_view() -> void:
	view_yaw = 0.0
	view_pitch = 0.0
	view_zoom = 0.0
	if geometry != Geometry.Geometry.FLAT:
		_center_on_view()
