extends RefCounted

const Binding := preload("res://scripts/pair_texture_binding.gd")
var failures: Array[String] = []
var samples: Array[Dictionary] = []

func _sample(image: Image, uv: Vector2) -> Color:
	var p := (uv * Vector2(image.get_size()) - Vector2(0.5, 0.5)).clamp(Vector2.ZERO, Vector2(image.get_size()) - Vector2.ONE)
	var a := Vector2i(floori(p.x), floori(p.y))
	var b := (a + Vector2i.ONE).min(image.get_size() - Vector2i.ONE)
	return image.get_pixel(a.x, a.y).lerp(image.get_pixel(b.x, a.y), p.x - a.x).lerp(
		image.get_pixel(a.x, b.y).lerp(image.get_pixel(b.x, b.y), p.x - a.x), p.y - a.y)

func run(parent: Node) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(17, 17)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	parent.add_child(viewport)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.position.z = 2.0
	viewport.add_child(camera)
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	quad.mesh.size = Vector2(2, 2)
	viewport.add_child(quad)
	var rgb := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 64:
			rgb.set_pixel(x, y, Color(float(x % 32) / 31, float(y) / 31, 0.1 if x < 32 else 0.9, 1))
	var mask := Image.create(32, 16, false, Image.FORMAT_R8)
	# Deliberately fractional letterbox boundaries and distinct eyes.
	var rect := [0.2, 0.1, 0.6, 0.8]
	for y in 16:
		for x in 32:
			var inside: bool = (float(x % 16) + 0.5) / 16 >= rect[0] and (float(x % 16) + 0.5) / 16 <= rect[0] + rect[2] \
				and (float(y) + 0.5) / 16 >= rect[1] and (float(y) + 0.5) / 16 <= rect[1] + rect[3]
			mask.set_pixel(x, y, Color((0.15 if x < 16 else 0.6) + 0.2 * y / 15 if inside else 0, 0, 0))
	var rgb_owner := ImageTexture.create_from_image(rgb)
	var mask_owner := ImageTexture.create_from_image(mask)
	var code := FileAccess.get_file_as_string("res://shaders/video_rvm_pair.gdshader").replace(
		'#include "res://shaders/video_coordinates.gdshaderinc"', FileAccess.get_file_as_string("res://shaders/video_coordinates.gdshaderinc"))
	code = code.replace("varying flat int eye_index;", "uniform int test_eye = 0;\nuniform vec2 test_uv = vec2(0.5);\nvarying flat int eye_index;")
	code = code.replace("eye_index = int(VIEW_INDEX);", "eye_index = test_eye;").replace("eye_uv(UV, media_direction)", "test_uv")
	var material := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = code
	material.shader = shader
	quad.material_override = material
	await RenderingServer.frame_post_draw
	var pair := {"session_id": 1, "logical_session_id": 1, "generation": 1, "frame_id": 7, "pts_us": 233333,
		"format_revision": 2, "effect_revision": 2, "model_generation": 3, "slot_token": 8,
		"color_texture_id": RenderingServer.texture_get_native_handle(rgb_owner.get_rid()),
		"alpha_texture_id": RenderingServer.texture_get_native_handle(mask_owner.get_rid()),
		"width": 64, "height": 32, "input_width": 16, "input_height": 16, "alpha_width": 32, "alpha_height": 16,
		"rotation_degrees": 0, "model_content_rect": rect, "stereo_sbs": true, "alpha_slot_token": 8,
		"alpha_frame_id": 7, "alpha_pts_us": 233333, "source_pts_verified": true, "immutable_color_frame": true,
		"pair_identity_verified": true, "alpha_fence_ready": true, "alpha_gpu_uploaded": true, "alpha_texture_format": "GL_R8_numeric"}
	var invalid_cases := [{"alpha_pts_us": 233334}, {"alpha_frame_id": 8}, {"alpha_slot_token": 9}, {"alpha_fence_ready": false},
		{"source_pts_verified": false}, {"alpha_texture_format": "GL_SRGB8"}, {"alpha_width": 16}, {"rotation_degrees": 45},
		{"model_content_rect": [0.2, 0, 0.9, 1]}, {"model_content_rect": [0, 0, 0.001, 1]}, {"model_content_rect": [NAN, 0, 1, 1]}]
	for change in invalid_cases:
		var bad := pair.duplicate(true)
		bad.merge(change, true)
		if Binding._valid(bad):
			failures.append("Invalid descriptor accepted: %s" % change)
	# Repeated borrow/free verifies freeing wrappers leaves native owners alive.
	for repetition in 3:
		var binding := Binding.new()
		if not binding.bind(material, pair):
			failures.append("Native RID bind failed")
			break
		if binding.bind(material, pair):
			failures.append("An occupied binding accepted a second pair")
		# Binding selects the production shader. Reinstall the analytic eye/UV overrides
		# after that selection; otherwise every test sample reads the centre of eye 0.
		Binding._use_shader(material, shader)
		RenderingServer.material_set_param(material.get_rid(), "color_texture", binding.color_rid)
		RenderingServer.material_set_param(material.get_rid(), "alpha_texture", binding.alpha_rid)
		for rotation in [0, 90, 180, 270]:
			material.set_shader_parameter("rotation_degrees", rotation)
			for eye in [0, 1]:
				material.set_shader_parameter("test_eye", eye)
				for swap in [false, true]:
					material.set_shader_parameter("swap_eyes", swap)
					for uv in [Vector2(0,0), Vector2(1,0), Vector2(0,1), Vector2(1,1), Vector2(0.23,0.72), Vector2(0.5,0.5)]:
						material.set_shader_parameter("test_uv", uv)
						await RenderingServer.frame_post_draw
						await RenderingServer.frame_post_draw
						var actual := viewport.get_texture().get_image().get_pixel(8,8)
						var p: Vector2 = uv
						match rotation:
							90: p = Vector2(uv.y, 1 - uv.x)
							180: p = Vector2.ONE - uv
							270: p = Vector2(1 - uv.y, uv.x)
						var source_eye: int = 1 - eye if swap else eye
						var c_uv := p.clamp(Vector2.ONE / 64, Vector2.ONE - Vector2.ONE / 64)
						c_uv.x = (c_uv.x + source_eye) * 0.5
						var color := _sample(rgb, c_uv)
						# CPU oracle enumerates content texel centers rather than copying shader rounding.
						var valid_x: Array[float] = []
						var valid_y: Array[float] = []
						for index in 16:
							var center := (float(index) + 0.5) / 16
							if center >= rect[0] and center <= rect[0] + rect[2]: valid_x.append(center)
							if center >= rect[1] and center <= rect[1] + rect[3]: valid_y.append(center)
						var a_uv := Vector2(rect[0] + p.x * rect[2], rect[1] + p.y * rect[3]).clamp(
							Vector2(valid_x.front(), valid_y.front()), Vector2(valid_x.back(), valid_y.back()))
						a_uv.x = (a_uv.x + source_eye) * 0.5
						var alpha := _sample(mask, a_uv).r
						var expected := Color(color.r * alpha, color.g * alpha, color.b * alpha, alpha)
						var error := maxf(maxf(absf(actual.r-expected.r), absf(actual.g-expected.g)), maxf(absf(actual.b-expected.b), absf(actual.a-expected.a)))
						if error > 0.012:
							failures.append("Borrow %d rot%d eye%d swap%s uv%s actual%s expected%s" % [repetition, rotation, eye, swap, uv, actual, expected])
						samples.append({"borrow": repetition, "rotation": rotation, "eye": eye, "swap": swap, "uv": [uv.x,uv.y], "max_abs": error})
		var previous := binding.unbind()
		if previous.slot_token != pair.slot_token or binding.color_rid.is_valid() or binding.alpha_rid.is_valid():
			failures.append("Binding detach identity/resource failure")
		await RenderingServer.frame_post_draw
	# Original owners can still render after all borrowed RIDs were freed.
	material.set_shader_parameter("color_texture", rgb_owner)
	material.set_shader_parameter("alpha_texture", mask_owner)
	material.set_shader_parameter("alpha_enabled", false)
	material.set_shader_parameter("rotation_degrees", 0)
	material.set_shader_parameter("swap_eyes", false)
	material.set_shader_parameter("test_eye", 1)
	material.set_shader_parameter("test_uv", Vector2(0.5,0.5))
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var opaque := viewport.get_texture().get_image().get_pixel(8,8)
	if absf(opaque.r-0.5) > 0.012 or absf(opaque.g-0.5) > 0.012 or absf(opaque.b-0.9) > 0.012 or opaque.a < 0.99:
		failures.append("Native owners lost after wrapper release / opaque toggle failed: %s" % opaque)
	viewport.queue_free()
	return {"state": "passed" if failures.is_empty() else "failed",
		"scope": "Godot native GL borrowing and production RVM shader with analytic eye/UV overrides; no decoded source, XR or matting quality proof",
		"renderer": RenderingServer.get_video_adapter_name(), "samples": samples, "invalid_descriptors": invalid_cases.size(),
		"borrow_cycles": 3, "failures": failures}
