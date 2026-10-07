extends "res://scripts/ray_menu.gd"

## Library: left navigation (recent, local disk, SMB, DLNA, settings), right content with sub-tabs,
## breadcrumbs and a scrolling list (ray drag anywhere on the list, or either thumbstick). Sources answer
## asynchronously through the platform's media_list(id, json) signal. Selection is controller ray + trigger only.

signal chosen(uri: String, title: String)
signal player_requested
signal recenter_requested
signal setting_changed(key: String, value: Variant)

enum Section { RECENT, LOCAL, SMB, DLNA, CLOUD, SETTINGS, MEDIA_SERVER }
const NAV := ["Recent", "Local files", "SMB network", "DLNA network", "Cloud drives", "Settings", "Media servers"]
const NAV_ICONS := ["history", "device", "server", "cast", "cloud", "settings", "media_library"]
const NAV_ORDER := [Section.RECENT, Section.LOCAL, Section.SMB, Section.DLNA, Section.CLOUD, Section.MEDIA_SERVER, Section.SETTINGS]
const ServerBrowser := preload("res://scripts/media_server_browser.gd")
var server_browser: RefCounted = ServerBrowser.new(self)
const SETTING_TABS := ["Video", "Subtitles", "Background", "About"]
const VIDEO_TAB := 0
const SUBTITLES_TAB := 1
const BACKGROUND_TAB := 2
const ABOUT_TAB := 3
const ABOUT_HOME := 36
var _about_page := 0 # app, language, credits
## VR subtitle distances (metres); the text keeps its angular size at any distance.
const SUBTITLE_DISTANCES := [5.0, 7.5, 10.0, 15.0, 20.0]
const OUTPUT_WIDTHS := [0, 5760, 4096]
const OUTPUT_NAMES := ["Original resolution", "6K", "4K"]
## Language rows in About: each language named in itself.
const LANGUAGE_NAMES := I18n.NAMES
const VISIBLE_ROWS := 7
const DRAG_START := 0.015          # metres of ray travel on the panel before a press becomes a drag
const STICK_DEADZONE := 0.2
const STICK_SPEED := 1.5           # visible pages per second at full deflection
const LIST_TOP := 0.33
const ROW_PITCH := 0.112
const FIELDS := ["name", "host", "user", "password"]
const FIELD_NAMES := ["Name", "Address", "User", "Password"]
const KEYS := [["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"], ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
	["a", "s", "d", "f", "g", "h", "j", "k", "l", "."], ["z", "x", "c", "v", "b", "n", "m", "-", "_", "@"]]
const SYMBOLS := [["!", "#", "$", "%", "&", "*", "(", ")", "+", "="], ["/", "\\", ":", ";", "'", "\"", ",", "?", "~", "|"],
	["[", "]", "{", "}", "<", ">", "^", "`", ".", "@"], ["-", "_", "0", "1", "2", "3", "4", "5", "6", "7"]]

# Targets (ray_menu reserves negatives).
const PLAYER := -5
const RECENTER := -6
const NAV_BASE := 10
const TAB_BASE := 20
const BACK := 30
const ADD := 31
const REFRESH := 32
const EDIT := 33
const SAVE := 40
const CANCEL := 41
const DELETE := 42
const SHIFT := 43
const BACKSPACE := 44
const SPACE := 45
const SYMBOL_LAYER := 46
const GRANT := 47
const CLEAR_HISTORY := 49
const ALL_FILES := 34
const CLOUD_ACCOUNTS := 35
const SCROLLBAR := 48
const CRUMB_BASE := 50
const FILTER_BASE := 70
const MEDIA_FILTERS := ["All", "Video", "Images"]
const ImageInfo := preload("res://scripts/image_info.gd")
## Browsing shows a grid like common VR players (folders and videos as tiles); settings stay a list.
const COLS := 4
const GRID_LINES := 3
const TILE_SIZE := Vector2(0.3, 0.27)
const GRID_PITCH := Vector2(0.33, 0.29)
const GRID_TOP := 0.375
const SELECTED := Color(0.16, 0.31, 0.27)
const Thumbnails := preload("res://scripts/thumbnail_cache.gd")
const COVER_BYTES := 2 * 1024 * 1024
const FOLDER := Color(0.98, 0.78, 0.36)
const ROW_BASE := 100
const FIELD_BASE := 200
const KEY_BASE := 300

var catalog: RefCounted            # recent files
var platform: Object               # QuestPlayer singleton or a test double
var settings_provider: Callable    # -> {"profile", "profiles", "output_width", "version"}

var section := Section.RECENT
var tab := 0
var scroll := 0.0                  # first visible line; fractional while moving, settles on a whole line
var _drag := {}                    # hand, target, start_y, start_scroll, moved, last, at_us, velocity
var _fling := 0.0                  # lines per second left by a released drag
var _stick_ms := -1000             # last thumbstick scroll; the list settles once the stick is released
var _list: Node3D                  # drawn rows; moved for fractional scrolling
var _bar_thumb: MeshInstance3D
var focus_index := 0 # Desktop keyboard preview only.
var rows: Array[Dictionary] = []
var media_filter := 0
var status := ""                   # English; shown through I18n
var _pending := {}                 # request id -> kind
var _local_entries: Array = []
var _local_stack: Array = []       # [{id, title}] from a storage volume down to the open folder
var _local_all_files := true       # the last listing could read the whole disk
var _smb_servers: Array = []
var _smb_found: Array = []
var _smb_server := ""
var _smb_path := ""
var _smb_entries: Array = []
var _dlna_servers: Array = []
var _dlna_stack: Array = []        # [{id, title}] containers from the server root
var _dlna_server := ""
var _dlna_entries: Array = []
var _cloud_stack: Array = []
var _cloud_entries: Array = []
var _cloud_setup := false
var _editor := {}                  # SMB server being edited; empty when not editing
var _field := 1
var _shift := false
var _symbols := false
var _side: Node3D                  # navigation column, angled towards the viewer
var _covers := {}                  # DLNA cover URL -> HTTPRequest while it downloads

func dismiss() -> void:
	server_browser.cancel()
	super()

func _ready() -> void:
	super()
	_side = Node3D.new()
	_side.transform = Transform3D(Basis(Vector3.UP, deg_to_rad(24)), Vector3(-0.84, 0, 0.1))
	add_child(_side)
	if platform and platform.has_signal("media_list"):
		platform.connect("media_list", _on_media_list)

func attach_platform(value: Object) -> void:
	platform = value
	if platform and platform.has_signal("media_list") and not platform.is_connected("media_list", _on_media_list):
		platform.connect("media_list", _on_media_list)
	if platform and platform.has_signal("android_lifecycle") and not platform.is_connected("android_lifecycle", _on_android_lifecycle):
		platform.connect("android_lifecycle", _on_android_lifecycle)

func _on_android_lifecycle(state: String) -> void:
	if state == "resume" and server_browser.setup:
		server_browser.setup = false
		server_browser.load_servers()
		refresh()
	if state == "resume" and _cloud_setup:
		_cloud_setup = false
		_cloud_stack = []
		_cloud_entries = []
		_load_section()
		refresh()

func _reset_navigation() -> void:
	_drag = {}
	_fling = 0.0
	scroll = 0.0
	focus_index = 0

# --- scrolling: ray drag on the list, thumbsticks, fling ------------------------------------------

## Point on the panel plane (local), even outside any button; null when the ray misses the plane.
func _plane_point(origin: Vector3, direction: Vector3) -> Variant:
	if not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.000001:
		return null
	var inverse := global_transform.affine_inverse()
	var start := inverse * origin
	var delta := inverse.basis * direction.normalized()
	if delta.z >= -0.00001 or start.z <= 0.0:
		return null
	return start + delta * (-start.z / delta.z)

func _row_target(target: int) -> bool:
	return target >= ROW_BASE and target < ROW_BASE + _drawn_slots()

## The list area, gaps between tiles included: a press there can drag the list.
func _in_list(point: Vector3) -> bool:
	var span := _bar_span()
	return _editor.is_empty() and not rows.is_empty() and point.x > -0.56 and point.x < 0.86 \
		and point.y < span.x + 0.01 and point.y > span.x - span.y - 0.02

func press_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if not _drag.is_empty() and _drag.hand != hand: return true
	update_pointer(hand, origin, direction, tracked)
	var hit := ray_hit(origin, direction) if tracked else {}
	var target := int(hit.get("target", NONE))
	var start_y := 0.0
	if not hit.is_empty() and target != SCROLLBAR and not _row_target(target):
		_activate_hit(hit)
		return true
	if hit.is_empty():
		var point: Variant = _plane_point(origin, direction) if tracked else null
		if point == null or not _in_list(point):
			return false
		start_y = float(point.y)
	else:
		start_y = float(hit.point.y)
	# Rows, gaps and the scrollbar wait for release: a press that moves becomes a scroll.
	_fling = 0.0
	_drag = {"hand": hand, "target": target, "start_y": start_y, "start_scroll": scroll, "moved": false,
		"last": scroll, "at_us": Time.get_ticks_usec(), "velocity": 0.0}
	if target == SCROLLBAR:
		_scroll_to_bar(start_y)
		_drag.moved = true
	return true

func cancel_pointer(hand: String) -> void:
	if not _drag.is_empty() and _drag.hand == hand:
		_drag = {}
		_fling = 0.0
	super(hand)

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	super(hand, origin, direction, tracked)
	if not tracked and not _drag.is_empty() and _drag.hand == hand:
		_drag = {}
		_fling = 0.0
	if _drag.is_empty() or _drag.hand != hand or not tracked:
		return
	var point: Variant = _plane_point(origin, direction)
	if point == null:
		return
	var y := float(point.y)
	if int(_drag.target) == SCROLLBAR:
		_scroll_to_bar(y)
		return
	if not _drag.moved and absf(y - float(_drag.start_y)) < DRAG_START:
		return
	_drag.moved = true
	# Content follows the ray: moving the ray up shows later rows.
	_set_scroll(float(_drag.start_scroll) + (y - float(_drag.start_y)) / _pitch())
	var now := Time.get_ticks_usec()
	var seconds := (now - int(_drag.at_us)) / 1000000.0
	if seconds > 0.004:
		_drag.velocity = lerpf(float(_drag.velocity), (scroll - float(_drag.last)) / seconds, 0.5)
		_drag.last = scroll
		_drag.at_us = now

func release_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if _drag.is_empty() or _drag.hand != hand:
		return
	var drag := _drag
	_drag = {}
	if drag.moved:
		# A quick flick keeps the list moving; a drag that stopped before release does not.
		var still := Time.get_ticks_usec() - int(drag.at_us) > 80000
		_fling = 0.0 if still or absf(float(drag.velocity)) < 1.5 else clampf(float(drag.velocity), -20.0, 20.0)
		return
	if not tracked or int(drag.target) == NONE:
		return
	var hit := ray_hit(origin, direction)
	if not hit.is_empty() and int(hit.target) == int(drag.target):
		_activate_hit(hit)

## Thumbstick y (up positive) scrolls the list; it never selects.
func stick_scroll(y: float, delta: float) -> void:
	if not visible or not _drag.is_empty() or not _editor.is_empty() or not is_finite(y) or absf(y) < STICK_DEADZONE:
		return
	_stick_ms = Time.get_ticks_msec()
	_fling = 0.0
	var amount := pow((absf(y) - STICK_DEADZONE) / (1.0 - STICK_DEADZONE), 1.6)
	_set_scroll(scroll - signf(y) * amount * _lines() * STICK_SPEED * delta)

func _process(delta: float) -> void:
	if not visible or not _drag.is_empty() or Time.get_ticks_msec() - _stick_ms < 120:
		return
	if absf(_fling) > 0.4:
		var before := scroll
		_set_scroll(scroll + _fling * delta)
		_fling = 0.0 if scroll == before else _fling * exp(-4.0 * delta)
		return
	_fling = 0.0
	# At rest the list sits on a whole line.
	var line := roundf(scroll)
	if scroll != line:
		_set_scroll(move_toward(scroll, line, delta * 5.0))

func _set_scroll(value: float) -> void:
	var clamped := clampf(value, 0.0, _max_scroll())
	if clamped == scroll:
		return
	var redraw := floori(clamped + 0.001) != _first_line()
	scroll = clamped
	if redraw:
		_draw()
	else:
		_place_list()

func _scroll_to_bar(y: float) -> void:
	var span := _bar_span()
	_set_scroll((span.x - y) / span.y * (_max_scroll() + 1.0) - 0.5)

## First drawn line (float noise from dragging cannot drop a line).
func _first_line() -> int:
	return floori(scroll + 0.001)

## Drawn rows: the visible lines plus one, which shows while the list is between lines.
func _drawn_slots() -> int:
	return _cols() * (_lines() + 1)

## Shift the drawn rows by the fractional scroll; rows past the edges of the list hide.
func _place_list() -> void:
	if not is_instance_valid(_list):
		return
	var fraction := scroll - _first_line()
	_list.position.y = fraction * _pitch()
	for button in _buttons:
		if _row_target(button.target):
			var line := float((button.target - ROW_BASE) / _cols()) - fraction
			button.node.visible = line > -0.35 and line < _lines() - 0.65
	if is_instance_valid(_bar_thumb):
		var span := _bar_span()
		var thumb: float = _bar_thumb.mesh.size.y
		var travel := (span.y - thumb) * (scroll / _max_scroll() if _max_scroll() > 0 else 0.0)
		_bar_thumb.position.y = span.x - travel - thumb * 0.5

func _grid() -> bool:
	if section == Section.MEDIA_SERVER: return server_browser.grid()
	return section != Section.SETTINGS

func _cols() -> int:
	return COLS if _grid() else 1

## Visible lines (tile rows or list rows); [scroll] counts lines.
func _lines() -> int:
	if section == Section.MEDIA_SERVER: return 2 if _grid() else 6
	return GRID_LINES if _grid() else VISIBLE_ROWS

func _pitch() -> float:
	return GRID_PITCH.y if _grid() else ROW_PITCH

func _line_count() -> int:
	return ceili(float(rows.size()) / _cols())

## Scrollbar track: top and height.
func _bar_span() -> Vector2:
	return Vector2(GRID_TOP if _grid() else LIST_TOP + 0.05, _lines() * _pitch() - 0.012)

func _max_scroll() -> float:
	return float(maxi(0, _line_count() - _lines()))

func refresh() -> void:
	_rebuild_rows()
	_draw()

# --- requests -------------------------------------------------------------------------------

func _request(kind: String, id: Variant) -> void:
	if id is int and id > 0:
		if kind == "cloud":
			for previous in _pending.keys():
				if _pending[previous] == "cloud":
					_pending.erase(previous)
		_pending[id] = kind
		status = "Loading…"
	else:
		status = "Unavailable"

func _on_media_list(id: int, payload: String) -> void:
	if server_browser.receive(id, payload): return
	if not _pending.has(id):
		return
	var kind: String = _pending[id]
	_pending.erase(id)
	if kind == "cloud" and section != Section.CLOUD:
		return
	var parsed: Variant = JSON.parse_string(payload)
	if not parsed is Dictionary:
		return
	var result: Dictionary = parsed
	status = ""
	var state := str(result.get("state", "error"))
	if state == "denied":
		status = "All files access needed" if str(result.get("error", "")) == "ALL_FILES_ACCESS_NEEDED" else "Media access needed"
	elif state != "ready":
		status = str(result.get("error", "Error")).left(80)
	else:
		match kind:
			"cloud":
				if str(result.get("path", "")) == _cloud_path():
					_cloud_entries = result.get("entries", [])
			"local":
				if str(result.get("path", "")) == _local_path():
					_local_entries = result.get("entries", [])
					_local_all_files = bool(result.get("all_files", true))
			"smb_servers":
				_smb_servers = result.get("servers", [])
			"smb_found":
				_smb_found = result.get("discovered", [])
			"smb_browse":
				if str(result.get("server_id")) == _smb_server and str(result.get("path")) == _smb_path:
					_smb_entries = result.get("entries", [])
			"dlna_servers":
				_dlna_servers = result.get("servers", [])
			"dlna_browse":
				if str(result.get("server_id")) == _dlna_server:
					_dlna_entries = result.get("entries", [])
	if visible:
		refresh()

func _load_section() -> void:
	if section == Section.MEDIA_SERVER:
		server_browser.load_servers()
		return
	if not platform:
		status = "Headset only" if section in [Section.LOCAL, Section.SMB, Section.DLNA, Section.CLOUD] else ""
		return
	match section:
		Section.CLOUD:
			_request("cloud", platform.media_cloud_browse(_cloud_path(), false))
		Section.LOCAL:
			# Always read again: files change, and access may have just been granted in settings.
			_request("local", platform.media_local_browse(_local_path()))
		Section.SMB:
			if _smb_server.is_empty():
				_request("smb_servers", platform.media_smb_servers())
		Section.DLNA:
			if _dlna_server.is_empty() and _dlna_servers.is_empty():
				_request("dlna_servers", platform.media_dlna_discover())

# --- rows -----------------------------------------------------------------------------------

func _rebuild_rows() -> void:
	rows.clear()
	match section:
		Section.RECENT:
			for entry in (catalog.list_recent() if catalog else []):
				var seconds := int(entry.position_ms) / 1000
				var photo: bool = entry.get("kind", "") == "image" or ImageInfo.is_image(str(entry.uri), str(entry.title))
				rows.append({"title": str(entry.title), "detail": "%02d:%02d" % [seconds / 60, seconds % 60] if seconds > 0 else "",
					"kind": "image" if photo else "video", "icon": "image" if photo else "video", "uri": str(entry.uri)})
		Section.LOCAL:
			for entry in _local_entries:
				var row := _entry_row(entry)
				if bool(entry.get("volume", false)):
					row.icon = "usb" if bool(entry.get("removable", false)) else "device"
				rows.append(row)
		Section.SMB:
			if _smb_server.is_empty():
				for server in _smb_servers:
					rows.append({"title": str(server.name), "detail": str(server.host), "icon": "server", "smb_server": str(server.id)})
				for found in _smb_found:
					if _smb_servers.any(func(s): return str(s.host) == str(found.host)):
						continue
					rows.append({"title": str(found.name), "detail": str(found.host), "icon": "plus", "smb_found": found})
			else:
				for entry in _smb_entries:
					rows.append(_entry_row(entry))
		Section.DLNA:
			if _dlna_server.is_empty():
				for server in _dlna_servers:
					rows.append({"title": str(server.name), "detail": "", "icon": "cast", "dlna_server": str(server.id)})
			else:
				for entry in _dlna_entries:
					rows.append(_entry_row(entry))
		Section.SETTINGS:
			var settings: Dictionary = settings_provider.call() if settings_provider.is_valid() else {}
			if tab == VIDEO_TAB:
				for i in OUTPUT_WIDTHS.size():
					var selected: bool = int(settings.get("output_width", 0)) == int(OUTPUT_WIDTHS[i])
					rows.append({"title": I18n.t(OUTPUT_NAMES[i]), "detail": "", "icon": "check" if selected else "circle",
						"selected": selected, "setting": ["output_width", OUTPUT_WIDTHS[i]]})
				# Library pictures: frames of played videos and DLNA covers.
				if _cache_usage == null:
					_cache_usage = Thumbnails.usage() # opens every picture file: not on each redraw
				var cache: Vector2i = _cache_usage
				var armed := _confirm == "clear_cache"
				rows.append({"title": I18n.t("Clear cache"), "detail": _bytes(cache.y) if cache.x > 0 else "", "icon": "check" if armed else "trash",
					"selected": armed, "clear_cache": true, "empty": cache.x == 0})
				var history: bool = settings.get("history", true)
				rows.append({"title": I18n.t("Save play history"), "detail": "", "icon": "check" if history else "circle",
					"selected": history, "setting": ["history", not history]})
			elif tab == SUBTITLES_TAB:
				var distance := float(settings.get("subtitle_distance", 5.0))
				for value in SUBTITLE_DISTANCES:
					var current := is_equal_approx(distance, value)
					rows.append({"title": "%s  %s m" % [I18n.t("Distance"), str(value).trim_suffix(".0")], "detail": "",
						"icon": "check" if current else "circle", "selected": current, "setting": ["subtitle_distance", value]})
			elif tab == BACKGROUND_TAB:
				var selected := str(settings.get("background", "belfast"))
				for option in [["belfast", "Belfast sunset", "image"], ["dark", "Dark background", "circle"], ["passthrough", "Passthrough", "eyes"]]:
					rows.append({"title": I18n.t(option[1]), "detail": "", "icon": "check" if selected == option[0] else option[2],
						"selected": selected == option[0], "setting": ["background", option[0]]})
				if settings.get("background_custom", false):
					rows.append({"title": I18n.t("Custom panorama"), "detail": str(settings.get("background_title", "")), "icon": "check" if selected == "custom" else "image",
						"selected": selected == "custom", "setting": ["background", "custom"]})
				if selected in ["belfast", "custom"]:
					rows.append({"title": I18n.t("Direction"), "detail": "%d°" % int(settings.get("background_yaw", 0)), "icon": "recenter", "setting": ["background_yaw", true]})
					rows.append({"title": I18n.t("Brightness"), "detail": "%d%%" % int(float(settings.get("background_brightness", 1)) * 100), "icon": "image", "setting": ["background_brightness", true]})
				status = "Loading…" if settings.get("background_loading", false) else str(settings.get("background_error", ""))
			elif tab == ABOUT_TAB:
				if _about_page == 1:
					for value in I18n.CHOICES:
						var current: bool = I18n.choice == value
						rows.append({"title": I18n.t(LANGUAGE_NAMES[value]), "detail": "", "icon": "check" if current else "circle",
							"selected": current, "setting": ["language", value]})
				elif _about_page == 2:
					for credit in [
						["Belfast Sunset (Pure Sky)", "Poly Haven · CC0 1.0 · Dimitrios Savva / Greg Zaal / Jarod Guest"],
						["Godot", "MIT"], ["Godot OpenXR Vendors", "Vendor license notices"],
						["RVM MobileNetV3", "GPL-3.0"], ["MNN", "Apache-2.0"], ["ncnn", "BSD-3-Clause"],
						["Depth Anything V2 Small", "Apache-2.0"], ["MPV / FFmpeg", "Bundled license notices"],
						["AndroidX Media3", "Apache-2.0"], ["jcifs-ng", "LGPL-2.1"], ["p115rsacipher", "MIT"]]:
						rows.append(_about_info(I18n.t(credit[0]), I18n.t(credit[1])))
				else:
					rows.append(_about_info("Thru3D Media Player", str(settings.get("version", ""))))
					rows.append(_about_info("FFSky Studio", "© 2026 FFSky Studio"))
					rows.append(_about_info(I18n.t("Support"), "ffskyteam@gmail.com"))
					rows.append(_about_info(I18n.t("Website"), "https://wapok.com"))
					rows.append({"title": I18n.t("Language"), "icon": "settings", "about_page": 1})
					rows.append({"title": I18n.t("Credits"), "icon": "info", "about_page": 2})
		Section.CLOUD:
			for entry in _cloud_entries:
				rows.append(_entry_row(entry))
	if section == Section.MEDIA_SERVER:
		rows = server_browser.rows()
	if media_filter > 0 and section not in [Section.SETTINGS, Section.MEDIA_SERVER]:
		rows.assign(rows.filter(func(row): return not row.has("uri") or row.get("kind", "video") == ("image" if media_filter == 2 else "video")))
	focus_index = clampi(focus_index, 0, maxi(0, rows.size() - 1))
	scroll = clampf(scroll, 0.0, _max_scroll())

## The open local folder's path ("" lists the storage volumes).
func _local_path() -> String:
	return "" if _local_stack.is_empty() else str(_local_stack.back().id)

func _cloud_path() -> String:
	return "" if _cloud_stack.is_empty() else str(_cloud_stack.back().id)

func _entry_row(entry: Dictionary) -> Dictionary:
	if bool(entry.get("container", false)):
		return {"title": str(entry.title), "detail": "", "icon": "folder", "container": entry}
	var photo: bool = entry.get("kind", "") == "image" or ImageInfo.is_image(str(entry.get("uri", "")), str(entry.title))
	var row := {"title": str(entry.title), "detail": _size(entry), "kind": "image" if photo else "video", "icon": "image" if photo else "video", "uri": str(entry.get("uri", ""))}
	if not str(entry.get("cover", "")).is_empty():
		row["cover"] = str(entry.cover)
	return row

func image_queue() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for row in rows:
		if row.get("kind") == "image" and row.has("uri"): result.append(row.duplicate(true))
	return result

func is_image_uri(uri: String) -> bool:
	return rows.any(func(row): return row.get("uri", "") == uri and row.get("kind") == "image")

static func _leaf(path: String) -> String:
	var parts := path.trim_suffix("/").split("/")
	return parts[parts.size() - 1] if parts.size() > 0 else path

static func _bytes(bytes: int) -> String:
	if bytes >= 1048576:
		return "%.1f MB" % (bytes / 1048576.0)
	return "%d KB" % maxi(1, bytes / 1024)

static func _size(entry: Dictionary) -> String:
	var bytes := float(entry.get("size", 0))
	if bytes <= 0:
		return ""
	return "%.1f GB" % (bytes / 1073741824.0) if bytes >= 1073741824.0 else "%d MB" % int(bytes / 1048576.0)

# --- activation -----------------------------------------------------------------------------

## Cold Alpha profile awaiting its confirming second press.
var _confirm := ""
var _cache_usage: Variant = null   # thumbnail files and bytes, read when the Video tab is opened

## Video state changes arrive several times a second: redraw only when the Alpha profiles
## (current, compiling, cold) shown on the Alpha tab change.
func _activate(target: int) -> void:
	if section == Section.MEDIA_SERVER and server_browser.action(target): return
	if not _row_target(target) and target != CLEAR_HISTORY:
		_confirm = ""
	if target == CLOSE:
		dismiss()
	elif target == PLAYER:
		dismiss()
		player_requested.emit()
	elif target == RECENTER:
		recenter_requested.emit()
	elif target >= NAV_BASE and target < NAV_BASE + NAV.size():
		server_browser.cancel()
		section = target - NAV_BASE
		tab = 0
		scroll = 0.0
		status = ""
		_editor = {}
		_cache_usage = null
		_load_section()
		refresh()
	elif target >= TAB_BASE and target < TAB_BASE + SETTING_TABS.size():
		tab = target - TAB_BASE
		scroll = 0.0
		_cache_usage = null
		_load_section()
		refresh()
	elif target == BACK:
		_go_back()
	elif target == ABOUT_HOME:
		_about_page = 0
		scroll = 0.0
		refresh()
	elif target == REFRESH:
		_refresh_source()
	elif target == ADD:
		_open_editor({})
	elif target == CLOUD_ACCOUNTS and platform:
		_cloud_setup = true
		platform.media_cloud_accounts()
	elif target == EDIT:
		var current: Array = _smb_servers.filter(func(s): return str(s.id) == _smb_server)
		_open_editor(current[0] if current.size() > 0 else {})
	elif target == GRANT:
		if status == "All files access needed":
			platform.media_local_grant_all_files()
		else:
			_load_section()
		refresh()
	elif target == ALL_FILES:
		platform.media_local_grant_all_files()
	elif target == CLEAR_HISTORY:
		if _confirm != "clear_history":
			_confirm = "clear_history"
		else:
			_confirm = ""
			setting_changed.emit("clear_history", true)
		refresh()
	elif target >= CRUMB_BASE and target < CRUMB_BASE + 10:
		_go_to(target - CRUMB_BASE)
	elif target >= FILTER_BASE and target < FILTER_BASE + MEDIA_FILTERS.size():
		media_filter = target - FILTER_BASE
		_reset_navigation()
		refresh()
	elif _row_target(target):
		var index := _first_line() * _cols() + target - ROW_BASE
		if index < rows.size():
			_choose(rows[index])
	elif not _editor.is_empty():
		_editor_input(target)

func _choose(row: Dictionary) -> void:
	if row.has("about_page"):
		_about_page = int(row.about_page)
		scroll = 0.0
		refresh()
		return
	if section == Section.MEDIA_SERVER:
		server_browser.choose(row)
		return
	if row.has("uri") and not str(row.uri).is_empty():
		dismiss()
		chosen.emit(str(row.uri), str(row.title))
	elif row.has("smb_server"):
		_smb_server = str(row.smb_server)
		_smb_path = ""
		_smb_entries = []
		_request("smb_browse", platform.media_smb_browse(_smb_server, ""))
		scroll = 0.0
		refresh()
	elif row.has("smb_found"):
		_open_editor({"name": str(row.smb_found.name), "host": str(row.smb_found.host)})
	elif row.has("dlna_server"):
		_dlna_server = str(row.dlna_server)
		_dlna_stack = []
		_dlna_entries = []
		_request("dlna_browse", platform.media_dlna_browse(_dlna_server, "0"))
		scroll = 0.0
		refresh()
	elif row.has("container"):
		var container: Dictionary = row.container
		scroll = 0.0
		if section == Section.LOCAL:
			_local_stack.append({"id": str(container.id), "title": str(container.title)})
			_local_entries = []
			_load_section()
		elif section == Section.SMB:
			_smb_path = str(container.id)
			_smb_entries = []
			_request("smb_browse", platform.media_smb_browse(_smb_server, _smb_path))
		elif section == Section.CLOUD:
			_cloud_stack.append({"id": str(container.id), "title": str(container.title)})
			_cloud_entries = []
			_load_section()
		else:
			_dlna_stack.append({"id": str(container.id), "title": str(container.title)})
			_dlna_entries = []
			_request("dlna_browse", platform.media_dlna_browse(_dlna_server, str(container.id)))
		refresh()
	elif row.has("clear_cache"):
		if bool(row.get("empty", false)):
			return
		if _confirm != "clear_cache":
			_confirm = "clear_cache"
			refresh()
			return
		_confirm = ""
		_cancel_covers()
		Thumbnails.clear()
		_cache_usage = null
		refresh()
	elif row.has("setting"):
		if bool(row.get("cold", false)) and _confirm != str(row.setting[1]):
			_confirm = str(row.setting[1])
			refresh()
			return
		_confirm = ""
		setting_changed.emit(str(row.setting[0]), row.setting[1])
		refresh()

func _go_back() -> void:
	scroll = 0.0
	status = ""
	if not _editor.is_empty():
		_editor = {}
	elif section == Section.CLOUD:
		_cloud_stack.pop_back()
		_cloud_entries = []
		_load_section()
	elif section == Section.LOCAL:
		_local_stack.pop_back()
		_local_entries = []
		_load_section()
	elif section == Section.SMB:
		if _smb_path.is_empty():
			_smb_server = ""
			_request("smb_servers", platform.media_smb_servers())
		else:
			_smb_path = _smb_path.get_base_dir() if _smb_path.contains("/") else ""
			_smb_entries = []
			_request("smb_browse", platform.media_smb_browse(_smb_server, _smb_path))
	elif section == Section.DLNA:
		if _dlna_stack.is_empty():
			_dlna_server = ""
		else:
			_dlna_stack.pop_back()
			_dlna_entries = []
			_request("dlna_browse", platform.media_dlna_browse(_dlna_server, str(_dlna_stack.back().id) if _dlna_stack.size() > 0 else "0"))
	refresh()

## Path segments of the current folder, the server (or library) first.
func _crumbs() -> Array:
	match section:
		Section.CLOUD:
			return [] if _cloud_stack.is_empty() else [I18n.t("Cloud drives")] + _cloud_stack.map(func(c): return str(c.title))
		Section.LOCAL:
			return [] if _local_stack.is_empty() else [I18n.t(NAV[Section.LOCAL])] + _local_stack.map(func(c): return str(c.title))
		Section.SMB:
			if _smb_server.is_empty():
				return []
			var names: Array = _smb_servers.filter(func(s): return str(s.id) == _smb_server).map(func(s): return str(s.name))
			var parts: Array = [str(names[0]) if names.size() > 0 else "SMB"]
			for part in _smb_path.split("/", false):
				parts.append(part)
			return parts
		Section.DLNA:
			if _dlna_server.is_empty():
				return []
			var names: Array = _dlna_servers.filter(func(s): return str(s.id) == _dlna_server).map(func(s): return str(s.name))
			var parts: Array = [str(names[0]) if names.size() > 0 else "DLNA"]
			for container in _dlna_stack:
				parts.append(str(container.title))
			return parts
	return []

## Jump to path segment [level] (0: the server or library root).
func _go_to(level: int) -> void:
	var depth := _crumbs().size() - 1
	if level < 0 or level >= depth:
		return
	scroll = 0.0
	status = ""
	match section:
		Section.CLOUD:
			_cloud_stack.resize(level)
			_cloud_entries = []
			_load_section()
		Section.LOCAL:
			_local_stack.resize(level)
			_local_entries = []
			_load_section()
		Section.SMB:
			_smb_path = "/".join(_smb_path.split("/", false).slice(0, level))
			_smb_entries = []
			_request("smb_browse", platform.media_smb_browse(_smb_server, _smb_path))
		Section.DLNA:
			_dlna_stack.resize(level)
			_dlna_entries = []
			_request("dlna_browse", platform.media_dlna_browse(_dlna_server, str(_dlna_stack.back().id) if _dlna_stack.size() > 0 else "0"))
	refresh()

func _refresh_source() -> void:
	if not platform:
		return
	if section == Section.CLOUD:
		_request("cloud", platform.media_cloud_browse(_cloud_path(), true))
		refresh()
		return
	match section:
		Section.LOCAL:
			pass # _load_section below reads the folder again
		Section.SMB:
			if _smb_server.is_empty():
				_request("smb_found", platform.media_smb_discover())
			else:
				_request("smb_browse", platform.media_smb_browse(_smb_server, _smb_path))
		Section.DLNA:
			if _dlna_server.is_empty():
				_dlna_servers = []
				_request("dlna_servers", platform.media_dlna_discover())
			else:
				_request("dlna_browse", platform.media_dlna_browse(_dlna_server, str(_dlna_stack.back().id) if _dlna_stack.size() > 0 else "0"))
	_load_section()
	refresh()

# --- SMB server editor with a ray keyboard --------------------------------------------------

func _open_editor(server: Dictionary) -> void:
	_editor = {"id": str(server.get("id", "")), "name": str(server.get("name", "")), "host": str(server.get("host", "")),
		"user": str(server.get("user", "")), "password": "", "has_password": bool(server.get("has_password", false))}
	_field = 1 if str(_editor.host).is_empty() else 2
	_shift = false
	_symbols = false
	refresh()

func _editor_input(target: int) -> void:
	var key: String = FIELDS[_field]
	if target >= FIELD_BASE and target < FIELD_BASE + FIELDS.size():
		_field = target - FIELD_BASE
	elif target >= KEY_BASE and target < KEY_BASE + 40:
		var layer: Array = SYMBOLS if _symbols else KEYS
		var character: String = layer[(target - KEY_BASE) / 10][(target - KEY_BASE) % 10]
		_editor[key] = str(_editor[key]) + (character.to_upper() if _shift else character)
		_shift = false
	elif target == SHIFT:
		_shift = not _shift
	elif target == SYMBOL_LAYER:
		_symbols = not _symbols
	elif target == SPACE:
		_editor[key] = str(_editor[key]) + " "
	elif target == BACKSPACE:
		_editor[key] = str(_editor[key]).left(-1)
	elif target == CANCEL:
		_editor = {}
	elif target == DELETE:
		if platform and not str(_editor.id).is_empty():
			_request("smb_servers", platform.media_smb_remove(str(_editor.id)))
			if _smb_server == str(_editor.id):
				_smb_server = ""
		_editor = {}
	elif target == SAVE:
		if str(_editor.host).strip_edges().is_empty():
			_field = 1
		elif platform:
			var request := {"id": _editor.id, "name": _editor.name, "host": _editor.host, "user": _editor.user,
				"password": _editor.password}
			_request("smb_servers", platform.media_smb_save(JSON.stringify(request)))
			_smb_server = ""
			_editor = {}
	refresh()

# --- drawing --------------------------------------------------------------------------------

func _draw() -> void:
	_clear_layout()
	# Like common VR players: a navigation column angled towards the viewer, the browser beside
	# it, and round actions floating under the browser.
	_set_backdrop(Vector2(1.46, 1.12), Vector2(0.13, 0))
	var column := _quad(Vector2(0.42, 1.12), Vector3.ZERO, PANEL, 10)
	_side.add_child(column)
	_decorations.append(column)
	for position in NAV_ORDER.size():
		var i: int = NAV_ORDER[position]
		_nav_button(NAV_BASE + i, I18n.t(NAV[i]), NAV_ICONS[i], Vector2(0, 0.39 - position * 0.13), i == section)
	_round(RECENTER, "recenter", Vector2(0.01, -0.65), 0.08, true, false, I18n.t("Recenter"))
	_round(PLAYER, "play", Vector2(0.13, -0.65), 0.08, true, false, I18n.t("Player"))
	_round(CLOSE, "close", Vector2(0.25, -0.65), 0.08, true, false, I18n.t("Close"))
	_place_device_status(Vector2(0.13, -0.735))
	if not _editor.is_empty():
		_draw_editor()
		return
	if section == Section.MEDIA_SERVER:
		server_browser.draw()
		return
	# Right header: sub-tabs at the top level, otherwise a clickable path with back.
	var crumbs := _crumbs()
	if crumbs.is_empty():
		var tabs: Array = SETTING_TABS if section == Section.SETTINGS else []
		for i in tabs.size():
			_button(TAB_BASE + i, I18n.t(tabs[i]), Vector2(-0.37 + i * 0.25, 0.46), Vector2(0.23, 0.07))
			_lit(i == tab)
		if section in [Section.RECENT, Section.LOCAL, Section.SMB, Section.DLNA, Section.CLOUD]:
			var title := _label(I18n.t(NAV[section]), Vector3(-0.42, 0.46, 0.004), 24)
			title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	else:
		_button(BACK, "", Vector2(-0.52, 0.46), Vector2(0.09, 0.07), true, "up")
		_draw_crumbs(crumbs)
	if section in [Section.LOCAL, Section.SMB, Section.DLNA, Section.CLOUD]:
		_button(REFRESH, "", Vector2(0.80, 0.46), Vector2(0.09, 0.07), platform != null, "refresh")
	if section == Section.CLOUD:
		_button(CLOUD_ACCOUNTS, "", Vector2(0.69, 0.46), Vector2(0.09, 0.07), platform != null, "plus")
		_tips[CLOUD_ACCOUNTS] = I18n.t("Cloud accounts")
	if section == Section.LOCAL and not _local_all_files and platform:
		_button(ALL_FILES, "", Vector2(0.69, 0.46), Vector2(0.09, 0.07), true, "unlock")
		_tips[ALL_FILES] = I18n.t("Allow access to all files")
	if section == Section.RECENT and not rows.is_empty():
		# Two presses: the first lights the button, the second clears.
		_button(CLEAR_HISTORY, "", Vector2(0.80, 0.46), Vector2(0.09, 0.07), true, "check" if _confirm == "clear_history" else "trash",
			_confirm == "clear_history")
		_tips[CLEAR_HISTORY] = I18n.t("Clear history")
	if section == Section.SMB and _smb_server.is_empty():
		_button(ADD, "", Vector2(0.69, 0.46), Vector2(0.09, 0.07), platform != null, "plus")
	if section == Section.SMB and not _smb_server.is_empty():
		_button(EDIT, "", Vector2(0.69, 0.46), Vector2(0.09, 0.07), true, "edit")
	_decoration(Vector2(1.28, 0.002), Vector2(0.19, 0.405), Color(0.17, 0.2, 0.24))
	_draw_rows()
	if section == Section.SETTINGS and tab == ABOUT_TAB:
		_draw_about()
	if status in ["Video access needed", "Media access needed", "All files access needed"]:
		_button(GRANT, I18n.t("Grant"), Vector2(0.19, -0.34), Vector2(0.3, 0.07), true, "", true)
	if section != Section.SETTINGS:
		for i in MEDIA_FILTERS.size():
			_button(FILTER_BASE + i, I18n.t(MEDIA_FILTERS[i]), Vector2(0.36 + i * 0.18, -0.515), Vector2(0.17, 0.06), true, "", media_filter == i)
			(_buttons.back().node.get_child(0) as Label3D).font_size = 17
	var line := _label(_fit_title(I18n.t(status), "", 0.67, 17), Vector3(-0.45, -0.52, 0.004), 17)
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	line.modulate = MUTED

## Path pills (last four segments); every segment but the current one jumps there.
func _draw_crumbs(crumbs: Array) -> void:
	var x := -0.455
	var first := maxi(0, crumbs.size() - 4)
	for i in range(first, crumbs.size()):
		var text := _fit_title(str(crumbs[i]), "", 0.24, 19)
		var width := FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 19).x * 0.0012 + 0.05
		var current := i == crumbs.size() - 1
		_button(CRUMB_BASE + i, text, Vector2(x + width * 0.5, 0.46), Vector2(width, 0.065), not current)
		var label: Label3D = _buttons.back().node.get_child(0)
		label.font_size = 19
		label.modulate = ACCENT if current else MUTED
		if current:
			_buttons.back().base_color = Color(TILE, 0.0)
		x += width + 0.035
		if not current:
			_label("›", Vector3(x - 0.0175, 0.46, 0.004), 19).modulate = MUTED

func _header_title() -> String:
	match section:
		Section.CLOUD:
			return " / ".join(_cloud_stack.map(func(c): return str(c.title)))
		Section.LOCAL:
			return " / ".join(_local_stack.map(func(c): return str(c.title)))
		Section.SMB:
			if _smb_server.is_empty():
				return ""
			var names: Array = _smb_servers.filter(func(s): return str(s.id) == _smb_server).map(func(s): return str(s.name))
			return (str(names[0]) if names.size() > 0 else "SMB") + ("" if _smb_path.is_empty() else " / " + _smb_path)
		Section.DLNA:
			if _dlna_server.is_empty():
				return ""
			var names: Array = _dlna_servers.filter(func(s): return str(s.id) == _dlna_server).map(func(s): return str(s.name))
			var path := " / ".join(_dlna_stack.map(func(c): return str(c.title)))
			return (str(names[0]) if names.size() > 0 else "DLNA") + ("" if path.is_empty() else " / " + path)
	return ""

func _draw_rows() -> void:
	_list = Node3D.new()
	add_child(_list)
	_decorations.append(_list)
	_bar_thumb = null
	var first := _first_line() * _cols()
	for i in range(first, mini(rows.size(), first + _drawn_slots())):
		var row: Dictionary = rows[i]
		var k := i - first
		if _grid():
			_tile(ROW_BASE + k, row, Vector2(-0.36 + (k % COLS) * GRID_PITCH.x, GRID_TOP - TILE_SIZE.y * 0.5 - (k / COLS) * GRID_PITCH.y))
		else:
			_row_button(ROW_BASE + k, str(row.title), "" if row.get("about_info", false) else str(row.get("detail", "")), str(row.get("icon", "video")),
				Vector2(0.17, LIST_TOP - k * ROW_PITCH), bool(row.get("selected", false)))
			if bool(row.get("about_info", false)):
				_buttons.back().enabled = false
				var node: MeshInstance3D = _buttons.back().node
				var title: Label3D = node.get_child(0)
				title.position.y = 0.023
				title.text = _fit_title(str(row.title), "", 1.08, 21)
				title.font_size = 21
				# Informational rows use two lines, leaving long contacts and credits readable.
				var detail := _label(_fit_title(str(row.detail), "", 1.08, 17), Vector3(-0.48, -0.024, 0.004), 17, node)
				detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
				detail.modulate = MUTED
	if _max_scroll() > 0:
		# Scrollbar: the thumb shows position and length; pointing at the track jumps there.
		var top := _bar_span().x
		var height := _bar_span().y
		_button(SCROLLBAR, "", Vector2(0.835, top - height * 0.5), Vector2(0.04, height))
		var thumb := height * float(_lines()) / _line_count()
		_bar_thumb = _decoration(Vector2(0.012, thumb), Vector2(0.835, top - thumb * 0.5), MUTED)
		_bar_thumb.material_override.render_priority = 13
	elif rows.is_empty() and status.is_empty():
		var empty := _label("—", Vector3(0.19, 0.0, 0.004), 30)
		empty.modulate = MUTED
	_place_list()

## A folder, video or server as a tile: a large glyph (videos keep a dark picture area with the
## length or size in the corner), the name in up to two lines below.
func _tile(target: int, row: Dictionary, centre: Vector2) -> void:
	var icon := str(row.get("icon", "video"))
	_button(target, _fit_title(str(row.title), "", 0.5, 18), centre, TILE_SIZE, true, "", false, _list)
	var button: Dictionary = _buttons.back()
	button.base_color = Color(TILE, 0.0)
	var node: MeshInstance3D = button.node
	var name: Label3D = node.get_child(0)
	name.font_size = 18
	name.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	name.width = (TILE_SIZE.x - 0.03) / name.pixel_size
	name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	name.position = Vector3(0, -0.06, 0.004)
	var picture := icon in ["video", "image"]
	var area := _quad(Vector2(TILE_SIZE.x - 0.02, 0.165), Vector3(0, 0.04, 0.003), Color(0.13, 0.15, 0.18) if picture else Color(TILE, 0.0), 12)
	node.add_child(area)
	var shown: Texture2D = _picture(row) if picture else null
	if shown:
		var frame := _material(Color.WHITE, 12)
		frame.albedo_texture = shown
		area.material_override = frame
	else:
		var glyph := _icon(icon, Vector3(0, 0.04, 0.005), 0.065 if picture else 0.1, MUTED if picture else (FOLDER if icon == "folder" else Color(0.93, 0.95, 0.98)), node)
		glyph.material_override.render_priority = 13
	var detail := str(row.get("detail", ""))
	if not detail.is_empty():
		var badge := _label(detail, Vector3(TILE_SIZE.x * 0.5 - 0.02, -0.03, 0.006), 13, node)
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		badge.render_priority = 14
		badge.modulate = MUTED

## The current choice is lit by colour (dark green tile, accent text), not a solid accent fill.
func _lit(selected: bool) -> void:
	if not selected:
		return
	var button: Dictionary = _buttons.back()
	button.base_color = SELECTED
	button.foreground = ACCENT
	button.node.get_child(0).modulate = ACCENT

## A played video's frame, or the cover a DLNA server offers (fetched once, then cached).
## Never reads a video to make one.
func _picture(row: Dictionary) -> Texture2D:
	if row.has("scene"): return server_browser.cover(row)
	var cover := str(row.get("cover", ""))
	if cover.is_empty():
		return Thumbnails.texture(str(row.get("uri", "")))
	var cached := Thumbnails.texture(cover)
	if not cached and not _covers.has(cover) and _covers.size() < 4:
		_fetch_cover(cover)
	return cached

func _fetch_cover(url: String) -> void:
	var request := HTTPRequest.new()
	request.body_size_limit = COVER_BYTES
	request.timeout = 10.0
	add_child(request)
	_covers[url] = request
	request.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray):
		_covers.erase(url)
		request.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			return
		var image := Image.new()
		if image.load_jpg_from_buffer(body) != OK and image.load_png_from_buffer(body) != OK and image.load_webp_from_buffer(body) != OK:
			return
		if Thumbnails.store(url, image) and visible:
			_draw())
	if request.request(url) != OK:
		_covers.erase(url)
		request.queue_free()

func _cancel_covers() -> void:
	for request in _covers.values():
		request.cancel_request()
		request.queue_free()
	_covers.clear()

func _row_button(target: int, title: String, detail: String, icon: String, centre: Vector2, selected: bool) -> void:
	_button(target, _fit_title(title, "", 0.9, 22), centre, Vector2(1.24, 0.098), true, "", false, _list)
	_lit(selected)
	var node: MeshInstance3D = _buttons.back().node
	var label: Label3D = node.get_child(0)
	label.position.x = -0.48
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.font_size = 22
	_icon(icon, Vector3(-0.565, 0, 0.004), 0.045, _buttons.back().foreground, node)
	if not detail.is_empty():
		var info := _label(detail, Vector3(0.58, 0, 0.004), 17, node)
		info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		info.modulate = MUTED

## Navigation entry on the angled column: the current one is lit by colour, not a solid fill.
func _nav_button(target: int, text: String, icon: String, centre: Vector2, selected: bool) -> void:
	_button(target, text, centre, Vector2(0.36, 0.11), true, "", false, _side)
	var button: Dictionary = _buttons.back()
	button.base_color = SELECTED if selected else Color(TILE, 0.0)
	var node: MeshInstance3D = button.node
	var label: Label3D = node.get_child(0)
	label.position.x = -0.08
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.modulate = ACCENT if selected else button.foreground
	_icon(icon, Vector3(-0.13, 0, 0.004), 0.05, ACCENT if selected else button.foreground, node)

func _draw_about() -> void:
	if _about_page != 0:
		_button(ABOUT_HOME, "", Vector2(0.80, 0.46), Vector2(0.09, 0.07), true, "up")

func _about_info(title: String, detail: String) -> Dictionary:
	return {"title": title, "detail": detail, "icon": "info", "about_info": true}

func _draw_editor() -> void:
	var title := _label("SMB", Vector3(-0.42, 0.46, 0.004), 24)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	for i in FIELDS.size():
		var value := str(_editor[FIELDS[i]])
		if FIELDS[i] == "password":
			value = "•".repeat(value.length()) if not value.is_empty() else ("••••" if bool(_editor.has_password) else "")
		var centre := Vector2(-0.12 + (i % 2) * 0.64, 0.36 - (i / 2) * 0.115)
		_button(FIELD_BASE + i, _fit_title(value, "", 0.42, 21), centre, Vector2(0.62, 0.1), true, "", i == _field)
		var node: MeshInstance3D = _buttons.back().node
		var label: Label3D = node.get_child(0)
		label.position = Vector3(-0.17, -0.012, 0.004)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var name := _label(I18n.t(FIELD_NAMES[i]), Vector3(-0.28, 0.0, 0.004), 17, node)
		name.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		name.modulate = MUTED
	var layer: Array = SYMBOLS if _symbols else KEYS
	for r in layer.size():
		for c in 10:
			var character: String = layer[r][c]
			_button(KEY_BASE + r * 10 + c, character.to_upper() if _shift else character,
				Vector2(-0.38 + c * 0.126, 0.1 - r * 0.098), Vector2(0.115, 0.085))
	var y := 0.1 - 4 * 0.098
	_button(SHIFT, "⇧", Vector2(-0.32, y), Vector2(0.18, 0.085), true, "", _shift)
	_button(SYMBOL_LAYER, "#+=" if not _symbols else "abc", Vector2(-0.13, y), Vector2(0.18, 0.085), true, "", _symbols)
	_button(SPACE, "␣", Vector2(0.15, y), Vector2(0.34, 0.085))
	_button(BACKSPACE, "", Vector2(0.43, y), Vector2(0.18, 0.085), true, "backspace")
	var actions := -0.44
	_button(SAVE, "", Vector2(0.73, actions), Vector2(0.18, 0.08), not str(_editor.host).strip_edges().is_empty(), "check", true)
	_button(CANCEL, "", Vector2(0.52, actions), Vector2(0.18, 0.08), true, "close")
	if not str(_editor.id).is_empty():
		_button(DELETE, I18n.t("Delete"), Vector2(0.24, actions), Vector2(0.24, 0.08))

# --- desktop preview helpers ----------------------------------------------------------------

func _activate_hit(hit: Dictionary) -> void:
	if int(hit.target) == SCROLLBAR:
		_scroll_to_bar(float(hit.point.y))
	else:
		super(hit)

func move_focus(direction: int) -> void:
	if rows.is_empty():
		return
	focus_index = posmod(focus_index + direction, rows.size())
	var line := focus_index / _cols()
	scroll = clampf(float(line - _lines() + 1) if line >= _first_line() + _lines() else minf(_first_line(), line), 0.0, _max_scroll())
	_draw()

func activate_desktop() -> void:
	if visible and focus_index < rows.size():
		_choose(rows[focus_index])
