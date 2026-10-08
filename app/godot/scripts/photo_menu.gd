extends "res://scripts/player_menu.gd"
## Photo controls share the existing ray-menu surface, glyphs and projection picker, with no
## video timeline or audio commands. The image queue is supplied by the browsing context.
const PHOTO_PREVIOUS := 400
const PHOTO_NEXT := 401
const PHOTO_INSPECT := 402
const PHOTO_RESET := 403
const PHOTO_MINUS := 404
const PHOTO_PLUS := 405
const PHOTO_GALLERY := 406
const PHOTO_DEPTH := 407
const PHOTO_STRENGTH := 408
const PHOTO_CURVE := 409
const PHOTO_PAGE_BACK := 410
const PHOTO_PAGE_NEXT := 411
const PHOTO_BACKGROUND := 412
const PHOTO_THUMB := 420
var queue_provider: Callable
var _gallery_open := false
var _gallery_start := 0

func _depth_maximum() -> float:
	return DepthStrength.PHOTO_MAX

func _reset_navigation() -> void:
	super._reset_navigation()
	_gallery_open = false

func refresh_values() -> void:
	if not visible: return
	var latest: Dictionary = state_provider.call() if state_provider.is_valid() else {}
	if latest != _state:
		var old_layout := _state.duplicate()
		var new_layout := latest.duplicate()
		for key in ["depth_strength", "depth_requested", "depth_enabled", "depth_error", "stereo_strategy", "stereo_ready", "render_strength"]:
			old_layout.erase(key); new_layout.erase(key)
		_state = latest
		if old_layout != new_layout:
			_draw()
		else:
			_refresh_depth()
			if is_instance_valid(_status): _status.text = _photo_status()
			for button in _buttons:
				if button.target == PHOTO_STRENGTH:
					button.node.get_child(0).text = I18n.t("3D depth") + "  " + _depth_caption()
			_update_highlights()

func _can_depth() -> bool:
	return _state.get("has_image", false) and not _state.get("loading", false) and int(_state.get("geometry", 0)) == 0 \
		and not _state.get("stereo", false) and _state.get("depth_available", false)

func _draw_bar() -> void:
	_set_backdrop(Vector2(1.16, 0.27), Vector2.ZERO)
	_backdrop.material_override.set_shader_parameter("surface_color", Color(PANEL, 0.86))
	_backdrop.material_override.set_shader_parameter("corner_radius", 0.05)
	_title = _label(_fit_title(str(_state.get("title", "")), "", 0.9, 15), Vector3(0, 0.1, 0.004), 15)
	_title.modulate = MUTED
	var has: bool = _state.get("has_image", false)
	_glyph(PHOTO_GALLERY, "images", Vector2(-0.5, 0.025), 0.075, _state.get("count", 0) > 0, I18n.t("Images"))
	_glyph(PHOTO_INSPECT, "zoom", Vector2(-0.39, 0.025), 0.075, has, I18n.t("Inspect"))
	_glyph(PHOTO_PREVIOUS, "previous", Vector2(-0.14, 0.025), 0.085, _state.get("can_previous", false), I18n.t("Previous image"))
	_label("%d / %d" % [maxi(0, int(_state.get("index", -1)) + 1), int(_state.get("count", 0))], Vector3(0, 0.025, 0.004), 18)
	_glyph(PHOTO_NEXT, "next", Vector2(0.14, 0.025), 0.085, _state.get("can_next", false), I18n.t("Next image"))
	if int(_state.get("geometry", 0)) == 0:
		_glyph(PHOTO_DEPTH, "depth", Vector2(DEPTH_X, 0.025), 0.075, _can_depth(), I18n.t("Auto 3D"))
	_glyph(MODE, "view_mode", Vector2(0.41, 0.025), 0.075, has, I18n.t("Image mode"))
	_glyph(11, "settings", Vector2(0.5, 0.025), 0.075, has, I18n.t("Settings"))
	if _state.get("inspect", false):
		_glyph(PHOTO_MINUS, "minus", Vector2(-0.18, -0.075), 0.065, has, I18n.t("Zoom out"))
		_label("%.1f×" % float(_state.get("zoom", 1)), Vector3(-0.06, -0.075, 0.004), 17)
		_glyph(PHOTO_PLUS, "plus", Vector2(0.06, -0.075), 0.065, has, I18n.t("Zoom in"))
		_glyph(PHOTO_RESET, "recenter", Vector2(0.18, -0.075), 0.065, has, I18n.t("Fit image"))
	else:
		_status = _label(_photo_status(), Vector3(0, -0.075, 0.004), 15)
		_status.modulate = MUTED
	_round(107, "close", Vector2(-0.14, 0.215), 0.08, has or _state.get("loading", false), false, I18n.t("Close image"))
	_round(100, "folder", Vector2(0, 0.215), 0.08, true, false, I18n.t("Library"))
	_round(108, "recenter", Vector2(0.14, 0.215), 0.08, true, false, I18n.t("Recenter"))
	_place_device_status(Vector2(0, -0.175))
	if _mode_open:
		_draw_modes()
		for button in _buttons:
			if button.target == MODE_STEREO + 3: button.enabled = bool(button.enabled) and _state.get("depth_available", false)
	elif _gallery_open:
		_draw_gallery()
	elif _depth_open:
		_draw_depth()

func _draw_panel() -> void:
	_set_backdrop(Vector2(1.16, 0.55))
	_button(10, "", Vector2(-0.48, 0.2), Vector2(0.085, 0.065), true, "up")
	_label(I18n.t("Images"), Vector3(0, 0.2, 0.004), 21)
	_button(PHOTO_STRENGTH, I18n.t("3D depth") + "  " + _depth_caption(), Vector2(-0.26, 0.035), Vector2(0.49, 0.105), _can_depth(), "depth")
	var names := ["Off", "Slight", "Medium", "Full"]
	var curve := [0.0, 0.35, 0.7, 1.0].find(float(_state.get("screen_curve", 0)))
	_button(PHOTO_CURVE, I18n.t("Screen curve") + "  " + I18n.t(names[maxi(0, curve)]), Vector2(0.26, 0.035), Vector2(0.49, 0.105), int(_state.get("geometry", 0)) == 0, "screen")
	_button(PHOTO_BACKGROUND, I18n.t("Use as background"), Vector2(0, -0.10), Vector2(0.56, 0.08), _state.get("can_background", false), "image")
	_status = _label(_photo_status(), Vector3(0, -0.19, 0.004), 15)
	_status.modulate = MUTED
	_place_device_status(Vector2(0, -0.32))

func _draw_gallery() -> void:
	var entries: Array = queue_provider.call() if queue_provider.is_valid() else []
	_gallery_start = clampi(_gallery_start, 0, maxi(0, entries.size() - 5))
	var background := _quad(Vector2(1.16, 0.23), Vector3(0, 0.465, 0.001), PANEL, 10)
	add_child(background); _decorations.append(background)
	_round(PHOTO_PAGE_BACK, "previous", Vector2(-0.64, 0.465), 0.075, _gallery_start > 0, false, I18n.t("Previous"))
	_round(PHOTO_PAGE_NEXT, "next", Vector2(0.64, 0.465), 0.075, _gallery_start + 5 < entries.size(), false, I18n.t("Next"))
	for i in mini(5, entries.size() - _gallery_start):
		var entry: Dictionary = entries[_gallery_start + i]
		var x := -0.44 + i * 0.22
		_button(PHOTO_THUMB + i, "", Vector2(x, 0.465), Vector2(0.2, 0.2), true, "image")
		var button: Dictionary = _buttons.back()
		if _gallery_start + i == int(_state.get("index", -1)): button.base_color = SELECTED
		_tips[PHOTO_THUMB + i] = str(entry.get("title", ""))
		var texture := preload("res://scripts/thumbnail_cache.gd").texture(str(entry.uri))
		if texture:
			var image := MeshInstance3D.new()
			var quad := QuadMesh.new(); quad.size = Vector2(0.18, 0.10125)
			image.mesh = quad
			var mat := _material(Color.WHITE, 14)
			mat.albedo_texture = texture
			image.material_override = mat; image.position.z = 0.005
			button.node.add_child(image)
		var caption := _label(_fit_title(str(entry.get("title", "")), "", 0.18, 12), Vector3(0,-0.077,0.008),12,button.node)
		caption.modulate = MUTED

func stick_scroll(amount: float, delta: float) -> void:
	if not _gallery_open or absf(amount) < 0.7: return
	if Time.get_ticks_msec() < _scroll_after: return
	_scroll_after = Time.get_ticks_msec() + 200
	_gallery_start += -1 if amount > 0 else 1
	_draw()

var _scroll_after := 0

func _activate(target: int) -> void:
	if target in [PHOTO_DEPTH, PHOTO_STRENGTH]:
		section = 0
		_gallery_open = false
		_toggle_depth_slider()
		return
	_close_depth_slider()
	match target:
		CLOSE: dismiss()
		100: dismiss(); recent_requested.emit()
		107: action_requested.emit("stop")
		108: action_requested.emit("recenter")
		10, 11: section = target - 10
		MODE: _mode_open = not _mode_open; _gallery_open = false
		PHOTO_PREVIOUS: action_requested.emit("photo_previous")
		PHOTO_NEXT: action_requested.emit("photo_next")
		PHOTO_INSPECT: action_requested.emit("photo_inspect")
		PHOTO_RESET: action_requested.emit("photo_fit")
		PHOTO_MINUS: action_requested.emit("photo_zoom_out")
		PHOTO_PLUS: action_requested.emit("photo_zoom_in")
		PHOTO_CURVE: action_requested.emit("screen_curve")
		PHOTO_PAGE_BACK: _gallery_start -= 5
		PHOTO_PAGE_NEXT: _gallery_start += 5
		PHOTO_BACKGROUND: action_requested.emit("photo_background")
		PHOTO_GALLERY:
			_gallery_open = not _gallery_open; _mode_open = false
			_gallery_start = maxi(0, int(_state.get("index", 0)) - 2)
		_:
			if _lit_modes.has(target): action_requested.emit("lock_mode")
			elif target >= MODE_PROJECTION and target < MODE_PROJECTION + 4: action_requested.emit("projection_%d" % (target - MODE_PROJECTION))
			elif target == MODE_STEREO: action_requested.emit("stereo_2d")
			elif target == MODE_STEREO + 1: action_requested.emit("stereo_sbs")
			elif target == MODE_STEREO + 2: action_requested.emit("eyes")
			elif target == MODE_STEREO + 3: action_requested.emit("depth")
			elif target == MODE_STEREO + 4: action_requested.emit("stereo_tb")
			elif target >= MODE_LENS and target < MODE_LENS + 4: action_requested.emit("fov_%d" % LENS_FOVS[target - MODE_LENS])
			elif target >= PHOTO_THUMB and target < PHOTO_THUMB + 5: action_requested.emit("photo_index_%d" % (_gallery_start + target - PHOTO_THUMB))
	refresh()

func _photo_status() -> String:
	if _state.get("loading", false): return I18n.t("Preparing 3D" if _state.get("preparing_depth", false) else "Loading image")
	if not str(_state.get("error", "")).is_empty(): return I18n.t(str(_state.error))
	if not str(_state.get("depth_error", "")).is_empty(): return I18n.t(str(_state.depth_error))
	if _state.get("depth_requested", false): return I18n.t("3D on" if _state.get("depth_enabled", false) else "Preparing 3D")
	return str(_state.get("source_size", ""))

func _update_highlights() -> void:
	super._update_highlights()
	for button in _buttons:
		if (button.target == PHOTO_INSPECT and _state.get("inspect", false)) or (button.target == PHOTO_DEPTH and _state.get("depth_requested", false)):
			button.node.material_override.set_shader_parameter("surface_color", SELECTED)
