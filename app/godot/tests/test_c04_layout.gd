extends SceneTree

const Geometry := preload("res://scripts/video_geometry.gd")
const Video := preload("res://scripts/video_display.gd")
var failures: Array[String] = []

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var format := {"width": 1280, "height": 640, "pixel_aspect": 1.0, "unapplied_rotation_degrees": 0}
	_check(Geometry.packed_dimensions(1280, 640) == Vector2i(512, 256), "Known PT packing dimensions must match")
	_check(Geometry.legacy_compatible(format, true, Geometry.Geometry.FISHEYE), "Explicit F180 SBS format must be compatible")
	_check(not Geometry.legacy_compatible(format, false, Geometry.Geometry.FISHEYE), "Mono cannot imply six-block SBS")
	_check(not Geometry.legacy_compatible(format, true, Geometry.Geometry.HALF_EQUIRECT), "Equirect must not read legacy tiles")
	format.unapplied_rotation_degrees = 90
	_check(not Geometry.legacy_compatible(format, true, Geometry.Geometry.FISHEYE), "Rotated packing must be rejected")
	format.unapplied_rotation_degrees = 0
	format.pixel_aspect = 1.2
	_check(not Geometry.legacy_compatible(format, true, Geometry.Geometry.FISHEYE), "Non-square pixel layout needs its own contract")
	var mesh := Geometry.hemisphere()
	var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for vertex in vertices:
		_check(absf(vertex.length() - 50.0) < 0.001 and vertex.z <= 0.001, "VR180 vertices must lie on the forward hemisphere")
	_check(vertices.size() == 73 * 37, "Dome tessellation must retain edges and poles")
	var video := Video.new()
	root.add_child(video)
	_check(not video.alpha_ready(), "Alpha cannot be enabled before a media frame")
	_check(not video.set_alpha(true) and not video.alpha_enabled, "No-frame toggle must preserve opaque material")
	video.media.begin(9)
	video.media.format = {"width": 1280, "height": 640, "pixel_aspect": 1.0, "unapplied_rotation_degrees": 0}
	video.media.frame_counter = 1
	video.geometry = Geometry.Geometry.FISHEYE
	video.stereo_sbs = true
	video.alpha_encoding = 2
	_check(video.alpha_ready() and video.set_alpha(true), "Frame plus explicit legacy layout must allow material selection")
	video.toggle_stereo()
	_check(not video.alpha_ready() and not video.alpha_enabled, "Invalidated SBS layout must stop legacy Alpha")
	video.close_video()
	_check(not video.alpha_ready() and not video.alpha_enabled, "Closed sessions cannot reuse Alpha")
	video.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("C04 host guards passed: explicit layout, format constraints, hemisphere and frame readiness. Quest composition not tested.")
	quit(0 if failures.is_empty() else 1)
