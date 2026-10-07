class_name CalibrationBoard extends Node3D

const ALPHA_VALUES := [0.0, 0.25, 0.5, 0.75, 1.0]
const ALPHA_SHADER := preload("res://shaders/alpha_calibration.gdshader")
const EYE_SHADER := preload("res://shaders/eye_marker.gdshader")

func _ready() -> void:
	for index in ALPHA_VALUES.size():
		var x := (index - 2) * 0.39
		var card := MeshInstance3D.new()
		card.name = "Alpha%d" % index
		card.mesh = QuadMesh.new()
		card.mesh.size = Vector2(0.34, 0.38)
		card.position = Vector3(x, 1.47, -2.0)
		var material := ShaderMaterial.new()
		material.shader = ALPHA_SHADER
		material.set_shader_parameter("alpha_value", ALPHA_VALUES[index])
		card.material_override = material
		add_child(card)
		_add_label("%.2f" % ALPHA_VALUES[index], Vector3(x, 1.15, -1.99), 28)
		# A border keeps the completely transparent card locatable.
		for edge in [Vector3(x - 0.175, 1.47, -2.01), Vector3(x + 0.175, 1.47, -2.01)]:
			var border := MeshInstance3D.new()
			border.mesh = QuadMesh.new()
			border.mesh.size = Vector2(0.005, 0.39)
			border.position = edge
			var border_material := StandardMaterial3D.new()
			border_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			border.material_override = border_material
			add_child(border)
	var eye_marker := MeshInstance3D.new()
	eye_marker.name = "EyeMarker"
	eye_marker.mesh = QuadMesh.new()
	eye_marker.mesh.size = Vector2(0.55, 0.17)
	eye_marker.position = Vector3(0, 0.85, -2)
	var eye_material := ShaderMaterial.new()
	eye_material.shader = EYE_SHADER
	eye_marker.material_override = eye_material
	add_child(eye_marker)
	_add_label("Left eye: red / 4 stripes   Right eye: blue / 8 stripes", Vector3(0, 0.65, -2), 24)

func _add_label(text: String, position_value: Vector3, size_value: int) -> void:
	var label := Label3D.new()
	label.text = text
	label.position = position_value
	label.font_size = size_value
	label.pixel_size = 0.003
	label.outline_size = 5
	add_child(label)

