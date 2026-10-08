extends "res://scripts/ray_menu.gd"

signal action_requested(operation: String)
signal recent_requested
signal seek_requested(position_ms: int)
signal bookmark_requested(operation: String, marker_id: String, scope: String)
signal volume_requested(volume: float, muted: bool)
signal subtitle_requested(track_id: int)
signal depth_strength_requested(strength: float)
signal adjustment_requested(key: String, value: Variant)
signal adjustment_committed
signal depth_strength_committed

const SEEK := 200
const BookmarkMenu := preload("res://scripts/bookmark_menu.gd")
var bookmarks := BookmarkMenu.new(self)
const MODE := 120
const SELECTED := Color(0.16, 0.31, 0.27)
const MODE_PROJECTION := 130
const MODE_STEREO := 140
const MODE_LENS := 150
const VOLUME := 160
## Volume slider over the sound icon: track span (bottom, top) and its x; the lowest steps mute.
const VOLUME_X := -0.5
const VOLUME_SPAN := Vector2(0.2, 0.44)
const VOLUME_MUTE := 3
const DepthStrength := preload("res://scripts/depth_strength.gd")
const DEPTH := 161
const DEPTH_X := 0.32
const DEPTH_SPAN := Vector2(0.2, 0.44)
const LENS_FOVS := [180, 190, 200, 220]
## Timeline width: the slim bar while watching, the full width in the expanded panel.
const BAR_SEEK := 0.82
const SUBTITLE_ROW := 300
const SUBTITLE_UP := 290
const SUBTITLE_DOWN := 291
const SUBTITLE_ROWS := 3

## The bar already carries video mode, eye order, recenter, volume and subtitles, and Alpha resolution
## lives in the library's Settings: this panel keeps only what neither has.
const TABS := ["Playback", "Settings", "Info"]
const OPERATIONS := [
	["recent", "previous_video", "play", "next_video", "alpha", "projection", "stereo", "stop", "recenter", "mute", "subtitles",
		"clone_voice", "depth"],
	["audio", "depth_strength", "screen_distance", "screen_curve", "subtitle_distance", "color_grade", "loop"],
	["capabilities"]]
const HEADINGS := ["Audio track", "3D depth", "Screen distance", "Screen curve", "Subtitle distance", "Color grading", "Loop"]
const SETTING_ICONS := ["audio", "depth", "screen", "screen", "subtitle", "settings", "loop"]
const Surface := preload("res://scripts/media_surface.gd")
const SCREEN_DISTANCES := [1.0, 2.0, 3.0, 5.0, 8.0]
## Flat screen curve steps (the video's CURVES) and their names.
const CURVE_NAMES := ["Off", "Slight", "Medium", "Full"]

const Grade := preload("res://scripts/color_grade.gd")
var _adjustment := ""
var _seek_hand := ""
var _seek_start := -1
var _seek_preview := -1
var _grade_page := 0
var _adjust_hand := ""
var _adjust_target := -1
var _adjust_rows := {}
var _preset_buttons := {}
var state_provider: Callable
var section := 0
var _state: Dictionary = {}
var _status: Label3D
var _info: Label3D
var _refresh_ms := 0
var _title: Label3D
var _elapsed: Label3D
var _duration: Label3D
var _progress: MeshInstance3D
var _thumb: MeshInstance3D
var _modes: Dictionary = {} # bar button target -> its mode caption
var _mode_open := false
var _bar_drawn := "" # what decides the bar's buttons (clone voice, projection) when it was drawn
var _lit_modes: Dictionary = {} # video mode tiles lit as current; pressing one again locks the mode
var _volume_open := false
var _volume_hand := "" # the hand dragging the volume slider
var _volume_sent := -1 # last level sent during this press (0 = muted)
var _volume_fill: MeshInstance3D
var _volume_knob: MeshInstance3D
var _volume_label: Label3D
var _depth_open := false
var _depth_hand := ""
var _depth_sent := -1
var _depth_fill: MeshInstance3D
var _depth_knob: MeshInstance3D
var _depth_label: Label3D
var _subtitle_open := false
var _subtitle_offset := 0
var _subtitle_scroll := 0.0
var _subtitle_source := ""
var _subtitle_ids: Dictionary = {}

func _finish_depth_drag() -> void:
	if not _depth_hand.is_empty():
		_depth_hand = ""
		depth_strength_committed.emit()

func _close_depth_slider() -> void:
	_finish_depth_drag()
	_depth_open = false

func dismiss() -> void:
	bookmarks.reset()
	_seek_hand = ""
	_seek_preview = -1
	_finish_adjustment()
	_adjustment = ""
	_subtitle_open = false
	_close_depth_slider()
	_volume_hand = ""
	super.dismiss()

func _reset_navigation() -> void:
	bookmarks.reset()
	_seek_hand = ""
	_seek_preview = -1
	_finish_adjustment()
	_adjustment = ""
	_subtitle_open = false
	_subtitle_offset = 0
	_subtitle_scroll = 0.0
	section = 0
	_mode_open = false
	_volume_open = false
	_volume_hand = ""
	_close_depth_slider()

func refresh() -> void:
	_state = state_provider.call() if state_provider.is_valid() else {}
	_draw()

func refresh_values() -> void:
	if not visible:
		return
	_state = state_provider.call() if state_provider.is_valid() else {}
	if not _adjustment.is_empty():
		_refresh_adjustments()
		_update_highlights()
		return
	if section == 0 and _bar_drawn != _bar_key():
		refresh()
		return
	for button in _buttons:
		if button.target == BookmarkMenu.ADD:
			button.enabled = _state.get("bookmark_ready", false) and _seek_hand.is_empty()
			button.node.get_child(1).material_override.albedo_color = button.foreground if button.enabled else MUTED
			continue
		if button.target >= BookmarkMenu.GROUP and button.target < BookmarkMenu.GROUP + 1000:
			button.enabled = _state.get("bookmark_seekable", false)
			continue
		if button.target == SEEK:
			button.enabled = _can_seek()
			continue
		if button.target < 100 or button.target >= 100 + OPERATIONS[section].size():
			continue
		var operation: String = OPERATIONS[section][button.target - 100]
		button.enabled = _enabled(operation)
		var label: Label3D = button.node.get_child(0)
		label.text = "" if section == 0 else _caption(operation)
		if _modes.has(button.target):
			_modes[button.target].text = _caption(operation)
		label.modulate = button.foreground if button.enabled else MUTED * Color(0.7, 0.7, 0.7)
		if section == 0 and button.target in [104, 110, 112]:
			button.node.get_child(1).material_override.albedo_color = button.foreground if button.enabled else MUTED
		if section == 0 and button.target == 102:
			button.node.get_child(1).material_override.albedo_texture = Icons.texture("pause" if _pausable() else "play")
			_tips[102] = I18n.t("Pause" if _pausable() else "Play")
		if section == 0 and button.target == 109:
			button.node.get_child(1).material_override.albedo_texture = Icons.texture(_sound_icon())
	if is_instance_valid(_status):
		_status.text = _status_text()
	if is_instance_valid(_info):
		_info.text = _info_text()
	if is_instance_valid(_title):
		_title.text = _fit_title(str(_state.get("title", "")) if _state.get("has_video", false) else I18n.t("Your player"), "", 1.14, 23)
	_refresh_progress()
	_refresh_volume()
	_refresh_depth()
	_update_highlights()

func _process(_delta: float) -> void:
	if visible and Time.get_ticks_msec() >= _refresh_ms:
		_refresh_ms = Time.get_ticks_msec() + 250
		refresh_values()

func _draw() -> void:
	_clear_layout()
	_info = null
	_title = null
	_progress = null
	_thumb = null
	_elapsed = null
	_duration = null
	_status = null
	_modes = {}
	_volume_fill = null
	_volume_knob = null
	_volume_label = null
	_depth_fill = null
	_depth_knob = null
	_depth_label = null
	_subtitle_ids = {}
	_adjust_rows = {}
	_preset_buttons = {}
	if not _adjustment.is_empty():
		_draw_adjustments()
		_update_highlights()
		return
	if not _state.get("has_video", false) or _subtitle_source != str(_state.get("source_uri", "")):
		_subtitle_open = false
		_subtitle_offset = 0
	_subtitle_source = str(_state.get("source_uri", ""))
	if not _can_depth(): _close_depth_slider()
	if section == 0:
		_draw_bar()
	else:
		_draw_panel()
	_update_highlights()

## While watching, laid out like common VR players: a small translucent bar (title, then
## sound and subtitles | previous, play, next | Alpha, 2D -> 3D, video mode, settings, then the timeline),
## round actions floating above it, icons only with their names on hover.
func _draw_bar() -> void:
	_set_backdrop(Vector2(1.16, 0.34), Vector2(0, -0.025))
	_backdrop.material_override.set_shader_parameter("surface_color", Color(PANEL, 0.86))
	_backdrop.material_override.set_shader_parameter("corner_radius", 0.05)
	_title = _label(_fit_title(str(_state.get("title", "")) if _state.get("has_video", false) else "", "", 0.9, 15), Vector3(0, 0.1, 0.004), 15)
	_title.modulate = MUTED
	var row := 0.025
	_glyph(109, _sound_icon(), Vector2(VOLUME_X, row), 0.075, _enabled("mute"), I18n.t("Sound"))
	_glyph(110, "subtitle", Vector2(-0.4, row), 0.075, _enabled("subtitles"), I18n.t("Subtitles") + ": " + _subtitle_name())
	_bar_drawn = _bar_key()
	if _state.get("clone_voice", false):
		_glyph(111, "voice", Vector2(-0.3, row), 0.075, _enabled("clone_voice"), I18n.t("Dubbing"))
	_glyph(101, "previous_video", Vector2(-0.13, row), 0.08, _enabled("previous_video"), I18n.t("Previous video"))
	_round(102, "pause" if _pausable() else "play", Vector2(0, row), 0.095, _enabled("play"), true,
		I18n.t("Pause" if _pausable() else "Play"))
	_glyph(103, "next_video", Vector2(0.13, row), 0.08, _enabled("next_video"), I18n.t("Next video"))
	# Both effects stay directly on the bar; unsupported source modes dim their buttons.
	_glyph(104, "alpha", Vector2(0.23, row), 0.075, _enabled("alpha"), I18n.t("Passthrough"))
	_glyph(112, "depth", Vector2(0.32, row), 0.075, _enabled("depth"), I18n.t("Auto 3D"))
	_glyph(MODE, "view_mode", Vector2(0.41, row), 0.075, true, I18n.t("Video mode"))
	_glyph(11, "settings", Vector2(0.5, row), 0.075, true, I18n.t("Settings"))
	_seek_bar(-0.08)
	# Floating actions above the bar.
	_round(107, "close", Vector2(-0.14, 0.215), 0.08, _enabled("stop"), false, I18n.t("Close video"))
	_round(100, "folder", Vector2(0, 0.215), 0.08, true, false, I18n.t("Library"))
	_round(108, "recenter", Vector2(0.14, 0.215), 0.08, true, false, I18n.t("Recenter"))
	_place_device_status(Vector2(0, -0.245))
	bookmarks.draw()
	if _mode_open:
		_draw_modes()
	if _volume_open:
		_draw_volume()
	if _depth_open:
		_draw_depth()
	if _subtitle_open:
		_draw_subtitles()

func _subtitle_tracks() -> Array:
	return _state.get("subtitle_options", [])

func _subtitle_label(track: Dictionary) -> String:
	var title := str(track.get("title", "")).strip_edges()
	if title.is_empty(): title = str(track.get("language", "")).strip_edges()
	if title.is_empty(): title = I18n.t("Subtitles") + " %d" % int(track.id)
	var codec := str(track.get("codec", "")).to_upper().replace("SUBRIP", "SRT").replace("WEBVTT", "VTT")
	return _fit_title(title.replace("\n", " "), " · " + codec, 0.76, 20)

func _draw_subtitles() -> void:
	var tracks := _subtitle_tracks()
	_subtitle_offset = clampi(_subtitle_offset, 0, maxi(0, tracks.size() - SUBTITLE_ROWS))
	var panel := _quad(Vector2(1.0, 0.38), Vector3(0, 0.475, 0.001), Color(PANEL, 0.96), 10)
	panel.material_override.set_shader_parameter("corner_radius", 0.025)
	add_child(panel)
	_decorations.append(panel)
	var heading := _label(I18n.t("Subtitles"), Vector3(-0.44, 0.615, 0.004), 18)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_button(SUBTITLE_UP, "↑", Vector2(0.33, 0.615), Vector2(0.07, 0.055), _subtitle_offset > 0)
	_button(SUBTITLE_DOWN, "↓", Vector2(0.42, 0.615), Vector2(0.07, 0.055), _subtitle_offset + SUBTITLE_ROWS < tracks.size())
	_subtitle_row(SUBTITLE_ROW, 0, I18n.t("Off"), 0.545)
	for index in range(_subtitle_offset, mini(tracks.size(), _subtitle_offset + SUBTITLE_ROWS)):
		var track: Dictionary = tracks[index]
		_subtitle_row(SUBTITLE_ROW + index + 1, int(track.id), _subtitle_label(track), 0.47 - (index - _subtitle_offset) * 0.075)

func _subtitle_row(target: int, id: int, text: String, y: float) -> void:
	_subtitle_ids[target] = id
	_button(target, text, Vector2(0, y), Vector2(0.92, 0.065))
	var button: Dictionary = _buttons.back()
	var label: Label3D = button.node.get_child(0)
	label.font_size = 20
	label.position.x = -0.42
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	if id == int(_state.get("subtitle_track", 0)):
		button.base_color = SELECTED
		_icon("check", Vector3(0.414, 0, 0.004), 0.029, ACCENT, button.node)

func stick_scroll(y: float, delta: float) -> void:
	if visible and bookmarks.opened:
		bookmarks.stick_scroll(y, delta)
		return
	if not visible or not _subtitle_open or not is_finite(y) or absf(y) < 0.4:
		_subtitle_scroll = 0.0
		return
	_subtitle_scroll -= y * delta * 7.0
	if absf(_subtitle_scroll) >= 1.0:
		_scroll_subtitles(int(_subtitle_scroll))
		_subtitle_scroll -= int(_subtitle_scroll)

func _scroll_subtitles(rows: int) -> void:
	var offset := clampi(_subtitle_offset + rows, 0, maxi(0, _subtitle_tracks().size() - SUBTITLE_ROWS))
	if offset != _subtitle_offset:
		_subtitle_offset = offset
		refresh()

func _can_depth() -> bool:
	return _state.get("has_video", false) and int(_state.get("geometry", 0)) == 0 and not _state.get("stereo", false)

func _toggle_depth_slider() -> void:
	if not _can_depth(): return
	if _depth_open:
		_close_depth_slider()
	else:
		_depth_open = true
		_subtitle_open = false
		_mode_open = false
		_volume_open = false
		_volume_hand = ""
		if not _state.get("depth_requested", false):
			depth_strength_requested.emit(DepthStrength.remembered(float(_state.get("depth_strength", 1.0))))
	refresh()

func _draw_depth() -> void:
	var height := DEPTH_SPAN.y - DEPTH_SPAN.x
	var middle := (DEPTH_SPAN.x + DEPTH_SPAN.y) / 2
	var panel := _quad(Vector2(0.13, height + 0.13), Vector3(DEPTH_X, middle + 0.025, 0.001), Color(PANEL, 0.94), 10)
	panel.material_override.set_shader_parameter("corner_radius", 0.05)
	add_child(panel)
	_decorations.append(panel)
	_button(DEPTH, "", Vector2(DEPTH_X, middle), Vector2(0.11, height + 0.04), _can_depth())
	_buttons.back().base_color = Color(TILE, 0.0)
	_decoration(Vector2(0.012, height), Vector2(DEPTH_X, middle), Color(0.3, 0.35, 0.4))
	# Ticks mark 100%, 200%, 300%; the original default stays easy to find.
	for value in [1.0, 2.0, 3.0]:
		_decoration(Vector2(0.035, 0.003), Vector2(DEPTH_X, DEPTH_SPAN.x + height * DepthStrength.to_fraction(value)), MUTED)
	_depth_fill = _decoration(Vector2(0.012, height), Vector2(DEPTH_X, middle), ACCENT)
	_depth_fill.material_override.render_priority = 13
	_depth_knob = _decoration(Vector2(0.03, 0.03), Vector2(DEPTH_X, DEPTH_SPAN.x), Color.WHITE)
	_depth_knob.material_override.set_shader_parameter("corner_radius", 0.015)
	_depth_knob.material_override.render_priority = 14
	_depth_label = _label("", Vector3(DEPTH_X, DEPTH_SPAN.y + 0.045, 0.004), 16)
	_refresh_depth()

func _depth_caption() -> String:
	return "%d%%" % roundi(float(_state.get("depth_strength", 1.0)) * 100) if _state.get("depth_requested", false) else I18n.t("Off")

func _refresh_depth() -> void:
	if not is_instance_valid(_depth_fill): return
	var fraction := DepthStrength.to_fraction(float(_state.get("depth_strength", 1.0))) if _state.get("depth_requested", false) else 0.0
	var height := DEPTH_SPAN.y - DEPTH_SPAN.x
	_depth_fill.visible = fraction > 0
	_depth_fill.mesh.size.y = maxf(0.001, height * fraction)
	_depth_fill.position.y = DEPTH_SPAN.x + height * fraction / 2
	_depth_fill.material_override.set_shader_parameter("surface_size", _depth_fill.mesh.size)
	_depth_knob.position.y = DEPTH_SPAN.x + height * fraction
	_depth_label.text = _depth_caption()

func _set_depth_at(y: float) -> void:
	var fraction := (y - DEPTH_SPAN.x) / (DEPTH_SPAN.y - DEPTH_SPAN.x)
	var strength := DepthStrength.from_fraction(fraction)
	if fraction < 0.02: strength = 0.0 # Small bottom dead zone makes Off easy to reach.
	var level := roundi(strength * 100)
	if level == _depth_sent: return
	_depth_sent = level
	depth_strength_requested.emit(strength)
	refresh_values()

## Volume: a slider rising from the sound icon; the bottom of the track is mute.
func _draw_volume() -> void:
	var height := VOLUME_SPAN.y - VOLUME_SPAN.x
	var middle := (VOLUME_SPAN.x + VOLUME_SPAN.y) / 2
	var panel := _quad(Vector2(0.1, height + 0.13), Vector3(VOLUME_X, middle + 0.025, 0.001), Color(PANEL, 0.94), 10)
	panel.material_override.set_shader_parameter("corner_radius", 0.05)
	add_child(panel)
	_decorations.append(panel)
	_button(VOLUME, "", Vector2(VOLUME_X, middle), Vector2(0.09, height + 0.04), _enabled("mute"))
	_buttons.back().base_color = Color(TILE, 0.0) # the track itself is the visible part
	_decoration(Vector2(0.012, height), Vector2(VOLUME_X, middle), Color(0.3, 0.35, 0.4))
	_volume_fill = _decoration(Vector2(0.012, height), Vector2(VOLUME_X, middle), ACCENT)
	_volume_fill.material_override.render_priority = 13
	_volume_knob = _decoration(Vector2(0.03, 0.03), Vector2(VOLUME_X, VOLUME_SPAN.x), Color.WHITE)
	_volume_knob.material_override.set_shader_parameter("corner_radius", 0.015)
	_volume_knob.material_override.render_priority = 14
	_volume_label = _label("", Vector3(VOLUME_X, VOLUME_SPAN.y + 0.045, 0.004), 16)
	_refresh_volume()

## Shown level: 0 while muted.
func _volume_level() -> int:
	return 0 if _state.get("muted", false) else roundi(float(_state.get("volume", 100)))

func _sound_icon() -> String:
	var level := _volume_level()
	return "mute" if level == 0 else ("volume_low" if level < 50 else "sound")

func _refresh_volume() -> void:
	if not is_instance_valid(_volume_fill): return
	var height := VOLUME_SPAN.y - VOLUME_SPAN.x
	var fraction := _volume_level() / 100.0
	_volume_fill.visible = fraction > 0
	_volume_fill.mesh.size.y = maxf(0.001, height * fraction)
	_volume_fill.position.y = VOLUME_SPAN.x + height * fraction / 2
	_volume_fill.material_override.set_shader_parameter("surface_size", _volume_fill.mesh.size)
	_volume_knob.position.y = VOLUME_SPAN.x + height * fraction
	_volume_label.text = str(_volume_level()) if fraction > 0 else ""

## Pointer height on the track -> 0..100; the lowest steps snap to mute.
func _set_volume_at(y: float) -> void:
	var level := roundi(clampf((y - VOLUME_SPAN.x) / (VOLUME_SPAN.y - VOLUME_SPAN.x), 0.0, 1.0) * 100)
	if level < VOLUME_MUTE:
		level = 0
	if level == _volume_sent:
		return
	_volume_sent = level
	volume_requested.emit(float(level), level == 0)
	refresh_values()

## Point on the menu plane (local), even off the track, so a drag past either end clamps.
func _plane_point(origin: Vector3, direction: Vector3) -> Variant:
	if not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.000001:
		return null
	var inverse := global_transform.affine_inverse()
	var start := inverse * origin
	var delta := inverse.basis * direction.normalized()
	if delta.z >= -0.00001 or start.z <= 0.0:
		return null
	return start + delta * (-start.z / delta.z)

func press_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if not bookmarks.capture.is_empty(): return true
	for owner in [_adjust_hand, _depth_hand, _volume_hand, _seek_hand]:
		if not owner.is_empty() and owner != hand: return false
	update_pointer(hand, origin, direction, tracked)
	var hit := ray_hit(origin, direction) if tracked else {}
	if not hit.is_empty() and bookmarks.press(hand, hit): return true
	if not hit.is_empty() and int(hit.target) == SEEK and _can_seek():
		_seek_hand = hand
		_seek_start = _seek_at(float(hit.point.x))
		_seek_preview = _seek_start
		return true
	if not hit.is_empty() and _adjust_rows.has(int(hit.target)):
		if not _adjust_hand.is_empty() and _adjust_hand != hand: return false
		_adjust_hand = hand
		_adjust_target = int(hit.target)
		_set_adjustment_at(float(hit.point.x))
		return true
	if not hit.is_empty() and int(hit.target) == DEPTH:
		if not _depth_hand.is_empty() and _depth_hand != hand: return false
		_depth_hand = hand
		_depth_sent = -1
		_set_depth_at(float(hit.point.y))
		return true
	if not hit.is_empty() and int(hit.target) == VOLUME:
		# The press sets the level; holding the trigger drags it (update_pointer).
		_volume_hand = hand
		_volume_sent = -1
		_set_volume_at(float(hit.point.y))
		return true
	return super(hand, origin, direction, tracked)

func cancel_pointer(hand: String) -> void:
	if bookmarks.capture.get("hand", "") == hand: bookmarks.cancel()
	if hand == _seek_hand:
		_seek_hand = ""
		_seek_preview = -1
	release_pointer(hand, Vector3.ZERO, Vector3.ZERO, false)
	super(hand)

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	super(hand, origin, direction, tracked)
	bookmarks.update(hand, origin, direction, tracked)
	if hand == _seek_hand:
		if not tracked or not visible or not _can_seek():
			_seek_hand = ""
			_seek_preview = -1
		else:
			var seek_point: Variant = _plane_point(origin, direction)
			if seek_point != null: _seek_preview = _seek_at(float(seek_point.x))
	if hand == _volume_hand and (not visible or not tracked): _volume_hand = ""
	if hand == _adjust_hand:
		if not visible or not tracked:
			_finish_adjustment()
		else:
			var adjust_point: Variant = _plane_point(origin, direction)
			if adjust_point != null: _set_adjustment_at(float(adjust_point.x))
	if hand == _depth_hand:
		if not visible or not tracked or not _depth_open or not _can_depth():
			_finish_depth_drag()
		else:
			var depth_point: Variant = _plane_point(origin, direction)
			if depth_point != null: _set_depth_at(float(depth_point.y))
	if hand != _volume_hand or not tracked or not _volume_open:
		return
	var point: Variant = _plane_point(origin, direction)
	if point != null:
		_set_volume_at(float(point.y))

func release_pointer(hand: String, _origin: Vector3, _direction: Vector3, _tracked: bool) -> void:
	bookmarks.release(hand, _origin, _direction, _tracked)
	if hand == _seek_hand:
		var target := _seek_preview
		_seek_hand = ""
		_seek_preview = -1
		if _tracked and visible and _can_seek() and target >= 0: seek_requested.emit(target)
	if hand == _adjust_hand: _finish_adjustment()
	if hand == _depth_hand: _finish_depth_drag()
	if hand == _volume_hand:
		_volume_hand = ""

func _bar_key() -> String:
	return str([_state.get("clone_voice", false), _state.get("geometry", 0), _state.get("has_video", false),
		_state.get("source_uri", ""), _subtitle_tracks(), _state.get("subtitle_track", 0), bookmarks.key()])

func _seek_at(x: float) -> int:
	return roundi(clampf((x + BAR_SEEK / 2) / BAR_SEEK, 0.0, 1.0) * int(_state.get("duration_ms", 0)))

## Video mode: every projection and stereo layout at once, the current ones lit (no cycling).
## Pressing a lit tile again locks that projection and layout for unnamed new files (a lock on
## the corner of both); pressing a locked one again unlocks.
func _draw_modes() -> void:
	_lit_modes = {}
	var lock: Dictionary = _state.get("mode_lock", {})
	var locked := {}
	if not lock.is_empty():
		locked[MODE_PROJECTION + int(lock.geometry)] = true
		locked[MODE_STEREO + (3 if lock.depth else [0, 1, 4][int(lock.layout)])] = true
	var fisheye := int(_state.get("geometry", 0)) == 2
	# The lens row sits under the layouts: the panel rises to clear the floating round buttons.
	var top := 0.61 if fisheye else 0.47
	# Fisheye adds a row of lens angles under the layouts.
	var panel := _quad(Vector2(1.06, 0.5 if fisheye else 0.36), Vector3(0, top - (0.07 if fisheye else 0.0), 0.001), Color(PANEL, 0.94), 10)
	panel.material_override.set_shader_parameter("corner_radius", 0.04)
	add_child(panel)
	_decorations.append(panel)
	var projection := int(_state.get("geometry", 0))
	var names := ["Flat", "180°", "Fisheye", "360°"]
	var icons := ["screen", "dome", "fisheye", "panorama"]
	for g in 4:
		_mode_tile(MODE_PROJECTION + g, I18n.t(names[g]), icons[g], Vector2(-0.3 + g * 0.2, top + 0.075), projection == g)
	var stereo: bool = _state.get("stereo", false)
	var depth: bool = _state.get("depth_requested", false)
	var tb: bool = stereo and _state.get("top_bottom", false)
	_mode_tile(MODE_STEREO, "2D", "screen", Vector2(-0.4, top - 0.09), not stereo and not depth)
	_mode_tile(MODE_STEREO + 1, "3D SBS", "stereo", Vector2(-0.2, top - 0.09), stereo and not tb)
	_mode_tile(MODE_STEREO + 4, "3D TB", "stacked", Vector2(0, top - 0.09), tb)
	# 2D source shown in 3D: depth estimated live, one view per eye.
	_mode_tile(MODE_STEREO + 3, I18n.t("Auto 3D"), "depth", Vector2(0.2, top - 0.09), depth, not stereo and projection == 0)
	var swapped: bool = _state.get("swap_eyes", false)
	_mode_tile(MODE_STEREO + 2, ("B / T" if swapped else "T / B") if tb else ("R / L" if swapped else "L / R"), "eyes",
		Vector2(0.4, top - 0.09), false, stereo)
	if fisheye:
		for i in LENS_FOVS.size():
			_button(MODE_LENS + i, "%d°" % LENS_FOVS[i], Vector2(-0.3 + i * 0.2, top - 0.235), Vector2(0.18, 0.08))
			if int(_state.get("fisheye_fov", 180)) == LENS_FOVS[i]:
				_buttons.back().base_color = SELECTED
	for button in _buttons:
		if locked.has(button.target):
			var half: Vector2 = button.rect.size / 2
			_icon("lock", Vector3(half.x - 0.022, half.y - 0.022, 0.005), 0.026, ACCENT, button.node)

func _mode_tile(target: int, text: String, icon: String, centre: Vector2, current: bool, enabled: bool = true) -> void:
	_button(target, text, centre, Vector2(0.18, 0.13), enabled, icon)
	if current:
		_buttons.back().base_color = SELECTED
		_lit_modes[target] = true

## "More": picture, sound and info settings; the arrow returns to the bar.
func _draw_panel() -> void:
	_set_backdrop(Vector2(1.55, 1.08))
	_button(10, "", Vector2(-0.63, 0.38), Vector2(0.11, 0.065), true, "up")
	for tab in range(1, TABS.size()):
		_button(10 + tab, I18n.t(TABS[tab]), Vector2(-0.6 + tab * 0.33, 0.38), Vector2(0.3, 0.065))
	_button(CLOSE, "", Vector2(0.69, 0.38), Vector2(0.085, 0.065), true, "close")
	_place_device_status(Vector2(0, -0.585))
	var operations: Array = OPERATIONS[section]
	for index in operations.size():
		var operation: String = operations[index]
		_button(100 + index, _caption(operation), Vector2(-0.36 if index % 2 == 0 else 0.36,
			0.23 - (index / 2) * 0.145), Vector2(0.67, 0.12), _enabled(operation))
		if section == 1:
			var node: MeshInstance3D = _buttons.back().node
			var value: Label3D = node.get_child(0)
			value.position = Vector3(-0.2, -0.021, 0.004)
			value.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			var heading := _label(I18n.t(HEADINGS[index]), Vector3(-0.2, 0.026, 0.004), 17, node)
			heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			heading.modulate = MUTED
			_icon(SETTING_ICONS[index], Vector3(-0.27, 0, 0.004), 0.042, MUTED, node)
	_status = _label(_status_text(), Vector3(0, -0.435, 0.004), 18)
	_status.modulate = MUTED
	if section == 2:
		_info = _label(_info_text(), Vector3(0, -0.08, 0.004), 20)

func _seek_bar(y: float) -> void:
	_button(SEEK, "", Vector2(0, y), Vector2(BAR_SEEK + 0.06, 0.05), _can_seek())
	_buttons.back().base_color = Color(TILE, 0.0) # the track itself is the visible part
	_decoration(Vector2(BAR_SEEK, 0.007), Vector2(0, y), Color(0.3, 0.35, 0.4))
	_progress = _decoration(Vector2(BAR_SEEK, 0.007), Vector2(0, y), ACCENT)
	_thumb = _decoration(Vector2(0.023, 0.023), Vector2(0, y), Color.WHITE)
	_progress.material_override.render_priority = 13
	_thumb.material_override.render_priority = 14
	_elapsed = _label("", Vector3(-BAR_SEEK / 2 - 0.035, y, 0.004), 16)
	_elapsed.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_duration = _label("", Vector3(BAR_SEEK / 2 + 0.035, y, 0.004), 16)
	_duration.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_refresh_progress()

func _can_seek() -> bool:
	return _state.get("has_video", false) and int(_state.get("duration_ms", 0)) > 0

func _refresh_progress() -> void:
	if not is_instance_valid(_progress): return
	var duration := maxi(0, int(_state.get("duration_ms", 0)))
	var position := clampi(_seek_preview if _seek_preview >= 0 else int(_state.get("position_ms", 0)), 0, duration)
	var fraction := float(position) / duration if duration > 0 else 0.0
	_progress.visible = fraction > 0
	_progress.mesh.size.x = maxf(0.001, BAR_SEEK * fraction)
	_progress.position.x = -BAR_SEEK / 2 + BAR_SEEK / 2 * fraction
	_progress.material_override.set_shader_parameter("surface_size", _progress.mesh.size)
	_thumb.position.x = -BAR_SEEK / 2 + BAR_SEEK * fraction
	_thumb.visible = _can_seek()
	_elapsed.text = _time(position)
	_duration.text = _time(duration) if duration > 0 else "--:--"

func _time(milliseconds: int) -> String:
	var seconds := maxi(0, milliseconds / 1000)
	return "%d:%02d:%02d" % [seconds / 3600, (seconds / 60) % 60, seconds % 60] if seconds >= 3600 else "%02d:%02d" % [seconds / 60, seconds % 60]

func _activate_hit(hit: Dictionary) -> void:
	if int(hit.target) == SEEK:
		if _can_seek():
			var fraction := clampf((float(hit.point.x) + BAR_SEEK / 2) / BAR_SEEK, 0.0, 1.0)
			seek_requested.emit(roundi(fraction * int(_state.duration_ms)))
	else:
		super._activate_hit(hit)

func _activate(target: int) -> void:
	bookmarks.opened = false
	if not _adjustment.is_empty():
		_activate_adjustment(target)
		return
	if section == 1 and target >= 100 and target < 100 + OPERATIONS[1].size() and OPERATIONS[1][target - 100] in ["screen_distance", "subtitle_distance", "color_grade"]:
		if not _enabled(OPERATIONS[1][target - 100]): return
		_adjustment = OPERATIONS[1][target - 100]
		_grade_page = 0
		refresh()
		return
	if section == 0 and target == 110:
		if not _enabled("subtitles"): return
		_subtitle_open = not _subtitle_open
		_subtitle_offset = 0
		_subtitle_scroll = 0.0
		_mode_open = false
		_volume_open = false
		_volume_hand = ""
		_close_depth_slider()
		refresh()
		return
	if section == 0 and _subtitle_open:
		if target in [SUBTITLE_UP, SUBTITLE_DOWN]:
			_scroll_subtitles(-SUBTITLE_ROWS if target == SUBTITLE_UP else SUBTITLE_ROWS)
			return
		if _subtitle_ids.has(target):
			subtitle_requested.emit(int(_subtitle_ids[target]))
			_subtitle_open = false
			refresh()
			return
		_subtitle_open = false
		refresh()
	_subtitle_open = false
	if (section == 0 and target == 112) or (section == 1 and target == 101):
		section = 0
		_toggle_depth_slider()
		return
	_close_depth_slider()
	if target != MODE and (target < MODE_PROJECTION or target >= MODE_LENS + LENS_FOVS.size()):
		_mode_open = false
	if target != 109:
		_volume_open = false
	if target == CLOSE:
		dismiss()
	elif section == 0 and target == 109:
		_volume_open = not _volume_open
		refresh()
	elif target >= 10 and target < 10 + TABS.size():
		section = target - 10
		refresh()
	elif target == MODE:
		_mode_open = not _mode_open
		refresh()
	elif _lit_modes.has(target):
		action_requested.emit("lock_mode")
		refresh()
	elif target >= MODE_PROJECTION and target < MODE_PROJECTION + 4:
		action_requested.emit("projection_%d" % (target - MODE_PROJECTION))
		refresh()
	elif target == MODE_STEREO or target == MODE_STEREO + 1:
		action_requested.emit("stereo_sbs" if target == MODE_STEREO + 1 else "stereo_2d")
		refresh()
	elif target == MODE_STEREO + 2:
		action_requested.emit("eyes")
		refresh()
	elif target == MODE_STEREO + 4:
		action_requested.emit("stereo_tb")
		refresh()
	elif target >= MODE_LENS and target < MODE_LENS + LENS_FOVS.size():
		action_requested.emit("fov_%d" % LENS_FOVS[target - MODE_LENS])
		refresh()
	elif target == MODE_STEREO + 3:
		if not _state.get("stereo", false):
			action_requested.emit("depth")
		refresh()
	elif target >= 100 and target < 100 + OPERATIONS[section].size():
		var operation: String = OPERATIONS[section][target - 100]
		if not _enabled(operation):
			return
		if operation == "recent":
			dismiss()
			recent_requested.emit()
		else:
			if operation == "open_file":
				dismiss()
			action_requested.emit(operation)
			if section == 0 and operation == "stop":
				refresh()
			else:
				refresh_values()

func _update_highlights() -> void:
	super._update_highlights()
	for button in _buttons:
		if section == 0 and button.target == 110:
			var active: bool = button.enabled and int(_state.get("subtitle_track", 0)) != 0
			button.node.get_child(1).material_override.albedo_color = ACCENT if active else (button.foreground if button.enabled else MUTED)
			if active and not _hover.values().has(button.target):
				button.node.material_override.set_shader_parameter("surface_color", SELECTED)
		if button.target == 10 + section and not _hover.values().has(button.target):
			button.node.material_override.set_shader_parameter("surface_color", Color(0.16, 0.31, 0.27))
		if section == 0 and button.enabled and not _hover.values().has(button.target) and button.target == 104 and _state.get("alpha_requested", false):
			button.node.material_override.set_shader_parameter("surface_color", Color(0.16, 0.31, 0.27))
		if section == 0 and button.enabled and not _hover.values().has(button.target) and button.target == 112 and _state.get("depth_requested", false):
			button.node.material_override.set_shader_parameter("surface_color", Color(0.16, 0.31, 0.27))
		if section == 0 and button.enabled and not _hover.values().has(button.target) and button.target == 111 and _state.get("clone_voice_active", false):
			button.node.material_override.set_shader_parameter("surface_color", Color(0.16, 0.31, 0.27))

func _enabled(operation: String) -> bool:
	var has_video: bool = _state.get("has_video", false)
	match operation:
		"play", "loop", "stop": return has_video
		"previous_video", "next_video": return has_video and _state.get("has_" + operation, false)
		"alpha": return has_video and int(_state.get("geometry", 0)) in [1, 2]
		"eyes": return _state.get("stereo", false)
		"volume_down", "volume_up", "mute": return has_video and _state.get("audio_available", false)
		"audio": return has_video and _state.get("audio_tracks", 0) > 0
		"clone_voice": return has_video and _state.get("clone_voice", false)
		"depth": return has_video and int(_state.get("geometry", 0)) == 0 and not _state.get("stereo", false)
		"depth_strength": return _can_depth()
		"subtitles": return has_video
		"capabilities": return _state.get("capabilities_available", false)
		"screen_curve", "screen_distance": return has_video and int(_state.get("geometry", 0)) == 0
	return true

func _pausable() -> bool:
	return _state.get("playing", false) and _state.get("playback_state", "") != "ended"

func _caption(operation: String) -> String:
	return I18n.t(_caption_text(operation))

## English caption; [_caption] shows it in the current language.
func _caption_text(operation: String) -> String:
	match operation:
		"open_file": return "Open"
		"recent": return "Library"
		"play": return "Pause" if _pausable() else "Play"
		"alpha": return "Passthrough"
		"previous_video": return "Previous video"
		"next_video": return "Next video"
		"loop": return "On" if _state.get("loop", false) else "Off"
		"stop": return "Close video"
		"stereo": return ("TB" if _state.get("top_bottom", false) else "SBS") if _state.get("stereo", false) else "2D"
		"eyes": return "R / L" if _state.get("swap_eyes", false) else "L / R"
		"projection": return str(_state.get("projection", "Flat"))
		"quality": return str(_state.get("profile", "320x320"))
		"recenter": return "Recenter"
		"volume_down": return "-10%"
		"volume_up": return "+10%"
		"mute": return "Unmute" if _state.get("muted", false) else "Mute"
		"audio": return str(_state.get("audio_track", "Auto"))
		"clone_voice": return "Dubbing"
		"depth_strength": return _depth_caption()
		"subtitles": return "Subtitles"
		"capabilities": return "Refresh device info"
		"subtitle_distance": return "%.1f m" % float(_state.get("subtitle_distance", 5.0))
		"screen_distance": return "%.1f m" % float(_state.get("screen_distance", Surface.SCREEN_DISTANCE))
		"color_grade": return str(_state.get("color_grade", {}).get("preset", "Original"))
		"screen_curve": return CURVE_NAMES[clampi(roundi(float(_state.get("screen_curve", 0.0)) / 0.35), 0, 3)]
	return operation

func _status_text() -> String:
	if not str(_state.get("error", "")).is_empty():
		return I18n.t("Error: open Info")
	if not _state.get("has_video", false): return I18n.t("No video selected")
	if section == 1:
		return "%d%% · %s · %s %s" % [int(_state.get("volume", 100)), I18n.t("Muted" if _state.get("muted", false) else "Sound on"),
			I18n.t("Subtitles"), _subtitle_name()]
	if _state.get("alpha_requested", false): return I18n.t("Alpha on" if _state.get("alpha_enabled", false) else "Preparing Alpha")
	if _state.get("depth_requested", false):
		if not str(_state.get("depth_error", "")).is_empty(): return I18n.t("3D unavailable")
		return I18n.t("3D on" if _state.get("depth_enabled", false) else "Preparing 3D")
	return I18n.t(str(_state.get("playback_state", "Ready")).capitalize())

func _subtitle_name() -> String:
	return I18n.t("Off") if int(_state.get("subtitle_track", 0)) == 0 else I18n.t("On")

func _info_text() -> String:
	var lines := PackedStringArray()
	lines.append(_fit_title(str(_state.get("title", I18n.t("No video selected"))), ""))
	lines.append(I18n.t("Source: %s | %s") % [str(_state.get("source_size", I18n.t("Unknown"))), I18n.t(str(_state.get("codec", "Unknown codec")))])
	lines.append(I18n.t("Time: %.1f / %.1f seconds") % [float(_state.get("position_ms", 0)) / 1000, float(_state.get("duration_ms", 0)) / 1000])
	lines.append(I18n.t("Subtitles: %s") % _subtitle_name())
	lines.append(I18n.t("XR: %s") % I18n.t(str(_state.get("xr_state", "Unavailable"))))
	if _state.get("depth_requested", false) and not str(_state.get("depth_error", "")).is_empty():
		lines.append(I18n.t("3D unavailable") + ": " + str(_state.depth_error))
	var error := str(_state.get("error", ""))
	if not error.is_empty():
		lines.append(_fit_title(error.replace("\n", " "), ""))
	for index in lines.size():
		lines[index] = _fit_title(lines[index], "")
	return "\n".join(lines)

func _finish_adjustment() -> void:
	if _adjust_hand.is_empty(): return
	_adjust_hand = ""
	_adjust_target = -1
	adjustment_committed.emit()

func _draw_adjustments() -> void:
	_set_backdrop(Vector2(1.55, 1.22))
	_button(400, "", Vector2(-0.66, 0.51), Vector2(0.09, 0.065), true, "up")
	_button(CLOSE, "", Vector2(0.66, 0.51), Vector2(0.09, 0.065), true, "close")
	_label(I18n.t({"screen_distance": "Screen distance", "subtitle_distance": "Subtitle distance", "color_grade": "Color grading"}[_adjustment]), Vector3(0, 0.51, 0.004), 24)
	_place_device_status(Vector2(0, -0.66))
	if _adjustment == "screen_distance":
		_adjustment_row(450, "screen_distance", "Screen distance", Vector3(Surface.DISTANCE_LIMITS.x, Surface.DISTANCE_LIMITS.y, 0.1), 0.17)
		for i in SCREEN_DISTANCES.size():
			_button(420 + i, "%.1f m" % SCREEN_DISTANCES[i], Vector2(-0.56 + i * 0.28, -0.05), Vector2(0.25, 0.075))
	elif _adjustment == "subtitle_distance":
		_adjustment_row(450, "subtitle_distance", "Subtitle distance", Vector3(5, 20, 0.5), 0.17)
		for i in 5:
			_button(420 + i, "%.1f m" % [5, 7.5, 10, 15, 20][i], Vector2(-0.56 + i * 0.28, -0.05), Vector2(0.25, 0.075))
	else:
		for i in Grade.PRESETS.size():
			_button(410 + i, I18n.t(Grade.PRESETS[i]), Vector2(-0.56 + i * 0.28, 0.38), Vector2(0.25, 0.075))
			_preset_buttons[Grade.PRESETS[i]] = _buttons.back()
		for i in 3:
			_button(430 + i, I18n.t(["Basic", "RGB gain", "RGB gamma / offset"][i]), Vector2(-0.46 + i * 0.46, 0.275), Vector2(0.44, 0.065))
			if i == _grade_page: _buttons.back().base_color = SELECTED
		var keys: Array = Grade.PAGES[_grade_page]
		for i in keys.size():
			_adjustment_row(450 + i, keys[i], Grade.NAMES[keys[i]], Grade.limits(keys[i]), 0.16 - i * 0.105)
		_button(440, I18n.t("Reset custom"), Vector2(0, -0.505), Vector2(0.4, 0.075))
	_refresh_adjustments()

func _adjustment_row(target: int, key: String, title: String, span: Vector3, y: float) -> void:
	var heading := _label(I18n.t(title), Vector3(-0.66, y, 0.004), 20)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	var value := _label("", Vector3(-0.06, y, 0.004), 18)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_button(target, "", Vector2(0.33, y), Vector2(0.7, 0.08))
	_buttons.back().base_color = Color(TILE, 0)
	_decoration(Vector2(0.6, 0.009), Vector2(0.33, y), MUTED)
	var fill := _decoration(Vector2(0.6, 0.009), Vector2(0.33, y), ACCENT)
	fill.material_override.render_priority = 13
	var knob := _decoration(Vector2(0.025, 0.025), Vector2(0.03, y), Color.WHITE)
	knob.material_override.render_priority = 14
	_adjust_rows[target] = {"key": key, "span": span, "label": value, "fill": fill, "knob": knob}

func _refresh_adjustments() -> void:
	var values: Dictionary = _state.get("grade_values", Grade.DEFAULTS)
	for row in _adjust_rows.values():
		var distance: bool = row.key in ["subtitle_distance", "screen_distance"]
		var value := float(_state.get(row.key, 5.0 if row.key == "subtitle_distance" else Surface.SCREEN_DISTANCE)) if distance else float(values.get(row.key, Grade.DEFAULTS[row.key]))
		var fraction := clampf((value - row.span.x) / (row.span.y - row.span.x), 0, 1)
		row.label.text = "%.1f m" % value if distance else ("%d K" % value if row.key == "temperature" else ("%+.2f EV" % value if row.key == "exposure" else "%.3f" % value))
		row.fill.visible = fraction > 0
		row.fill.mesh.size.x = maxf(0.001, fraction * 0.6)
		row.fill.position.x = 0.03 + fraction * 0.3
		row.fill.material_override.set_shader_parameter("surface_size", row.fill.mesh.size)
		row.knob.position.x = 0.03 + fraction * 0.6
	var selected := str(_state.get("color_grade", {}).get("preset", "Original"))
	for name in _preset_buttons:
		_preset_buttons[name].base_color = SELECTED if name == selected else TILE

func _set_adjustment_at(x: float) -> void:
	if not _adjust_rows.has(_adjust_target): return
	var row: Dictionary = _adjust_rows[_adjust_target]
	var value := clampf(snappedf(lerpf(row.span.x, row.span.y, clampf((x - 0.03) / 0.6, 0, 1)), row.span.z), row.span.x, row.span.y)
	adjustment_requested.emit(row.key, value)
	refresh_values()

func _activate_adjustment(target: int) -> void:
	_finish_adjustment()
	if target == CLOSE:
		dismiss()
		return
	if target == 400:
		_adjustment = ""
	elif _adjustment == "screen_distance" and target >= 420 and target < 425:
		adjustment_requested.emit("screen_distance", SCREEN_DISTANCES[target - 420])
		adjustment_committed.emit()
	elif _adjustment == "subtitle_distance" and target >= 420 and target < 425:
		adjustment_requested.emit("subtitle_distance", [5.0, 7.5, 10.0, 15.0, 20.0][target - 420])
		adjustment_committed.emit()
	elif _adjustment == "color_grade":
		if target >= 410 and target < 415:
			adjustment_requested.emit("grade_preset", Grade.PRESETS[target - 410])
			adjustment_committed.emit()
		elif target >= 430 and target < 433:
			_grade_page = target - 430
		elif target == 440:
			adjustment_requested.emit("grade_reset", true)
			adjustment_committed.emit()
	refresh()
