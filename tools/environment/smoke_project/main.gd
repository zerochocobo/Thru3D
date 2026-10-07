extends Node3D

func _ready() -> void:
	print("Environment smoke: Godot + Meta OpenXR. Video/RVM are not implemented.")
	if OS.get_name() == "Android":
		var xr_interface: XRInterface = XRServer.find_interface("OpenXR")
		if xr_interface != null and xr_interface.initialize():
			get_viewport().use_xr = true
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		else:
			push_error("OpenXR initialization failed; inspect the device log.")

