extends RefCounted
## Layout and trigger ownership for timestamps. All requests carry the captured media scope.
const ADD := 2000
const LIST := 2001
const UNDO := 2002
const CLOSE := 2003
const UP := 2004
const DOWN := 2005
const ROW := 2100
const DELETE := 2200
const GROUP := 2300
const ROWS := 5
const LANE_Y := -0.142
const Timeline := preload("res://scripts/timeline_markers.gd")
var menu: Node3D
var opened := false
var offset := 0
var subset: Array = []
var targets: Dictionary = {}
var capture: Dictionary = {}
var scope := ""
var scroll := 0.0
var notice := ""
var notice_until := 0
var flash_id := ""

func _init(owner: Node3D) -> void:
	menu = owner

func reset() -> void:
	opened = false; offset = 0; subset.clear(); capture.clear(); scroll = 0.0

func notify(text: String, marker_id: String = "") -> void:
	notice = text
	flash_id = marker_id
	notice_until = Time.get_ticks_msec() + 3000
	menu.refresh()

func _markers() -> Array:
	var all: Array = menu._state.get("bookmarks", [])
	return all if subset.is_empty() else all.filter(func(item): return item.id in subset)

func _scope() -> String:
	return str(menu._state.get("bookmark_scope", ""))

func draw() -> void:
	if scope != _scope():
		reset(); notice = ""; scope = _scope()
	targets.clear()
	var has_video: bool = menu._state.get("has_video", false)
	menu._round(ADD, "bookmark_add", Vector2(0.28, 0.215), 0.08,
		menu._state.get("bookmark_ready", false) and menu._seek_hand.is_empty(), false, menu.I18n.t("Add bookmark"))
	menu._round(LIST, "bookmark", Vector2(-0.28, 0.215), 0.08, has_video, false, menu.I18n.t("Bookmarks"))
	var all: Array = menu._state.get("bookmarks", [])
	if not all.is_empty(): menu._label(str(all.size()), Vector3(-0.235, 0.245, 0.004), 13)
	if menu._state.get("bookmark_undo", false):
		menu._round(UNDO, "undo", Vector2(0.42, 0.215), 0.08, true, false, menu.I18n.t("Undo delete"))
	if Time.get_ticks_msec() < notice_until:
		menu._label(notice, Vector3(0, 0.152, 0.005), 14)
	var groups := Timeline.groups(all, int(menu._state.get("duration_ms", 0)), menu.BAR_SEEK)
	for index in groups.size():
		var group: Dictionary = groups[index]
		var target := GROUP + index
		menu._button(target, str(group.markers.size()) if group.markers.size() > 1 else "", Vector2(group.x, LANE_Y),
			Vector2(0.044, 0.044), menu._state.get("bookmark_seekable", false), "" if group.markers.size() > 1 else "bookmark")
		menu._buttons.back().base_color = menu.SELECTED if Time.get_ticks_msec() < notice_until and group.markers.any(func(item): return item.id == flash_id) else Color(menu.TILE, 0)
		menu._decoration(Vector2(0.002, 0.024), Vector2(group.x, -0.105), menu.ACCENT)
		menu._tips[target] = menu._time(int(group.markers[0].position_ms)) if group.markers.size() == 1 else menu.I18n.t("Bookmarks") + " · " + str(group.markers.size())
		targets[target] = {"kind": "group", "ids": group.markers.map(func(item): return item.id)}
	if not opened: return
	var entries := _markers()
	offset = clampi(offset, 0, maxi(0, entries.size() - ROWS))
	var panel = menu._quad(Vector2(0.84, 0.46), Vector3(0, 0.5, 0.001), menu.PANEL, 10)
	menu.add_child(panel); menu._decorations.append(panel)
	menu._label(menu.I18n.t("Bookmarks") + " · " + str(entries.size()), Vector3(-0.05, 0.686, 0.01), 21)
	menu._glyph(CLOSE, "close", Vector2(0.355, 0.686), 0.065, true, menu.I18n.t("Close"))
	if entries.is_empty(): menu._label(menu.I18n.t("No bookmarks"), Vector3(0, 0.49, 0.01), 20)
	for row in mini(ROWS, entries.size() - offset):
		var item: Dictionary = entries[offset + row]
		var y := 0.604 - row * 0.066
		var enabled: bool = menu._state.get("bookmark_seekable", false) and int(item.position_ms) < int(menu._state.get("duration_ms", 0))
		menu._button(ROW + row, menu._time(int(item.position_ms)), Vector2(-0.065, y), Vector2(0.51, 0.058), enabled)
		menu._glyph(DELETE + row, "trash", Vector2(0.275, y), 0.058, true, menu.I18n.t("Delete bookmark"))
		targets[ROW + row] = {"kind": "seek", "id": item.id}
		targets[DELETE + row] = {"kind": "delete", "id": item.id}
	menu._button(UP, "↑", Vector2(0.365, 0.57), Vector2.ONE * 0.055, offset > 0)
	menu._button(DOWN, "↓", Vector2(0.365, 0.37), Vector2.ONE * 0.055, offset + ROWS < entries.size())

func _belongs(target: int) -> bool:
	return target in [ADD, LIST, UNDO, CLOSE, UP, DOWN] or targets.has(target)

func press(hand: String, hit: Dictionary) -> bool:
	if not capture.is_empty(): return true
	var target := int(hit.get("target", -1))
	if not _belongs(target): return false
	capture = {"hand": hand, "target": target, "scope": scope, "item": targets.get(target, {}).duplicate(true),
		"start": hit.point, "offset": offset, "moved": false}
	return true

func update(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if capture.is_empty() or capture.hand != hand: return
	if not tracked or not menu.visible or capture.scope != _scope():
		capture.clear(); return
	var point: Variant = menu._plane_point(origin, direction)
	if point == null: capture.clear(); return
	var delta: Vector2 = Vector2(point.x - capture.start.x, point.y - capture.start.y)
	if delta.length() > 0.018: capture.moved = true
	if capture.moved and int(capture.target) >= ROW and int(capture.target) < DELETE + ROWS:
		var next := clampi(int(capture.offset) + roundi(delta.y / 0.066), 0, maxi(0, _markers().size() - ROWS))
		if next != offset:
			offset = next; menu.refresh()

func cancel() -> void:
	capture.clear()

func release(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	if capture.is_empty() or capture.hand != hand: return
	var pressed := capture.duplicate(true)
	capture.clear()
	if not tracked or not menu.visible or pressed.scope != _scope() or pressed.moved: return
	var hit: Dictionary = menu.ray_hit(origin, direction)
	if int(hit.get("target", -1)) != int(pressed.target) or targets.get(pressed.target, {}) != pressed.item: return
	if Vector2(hit.point.x - pressed.start.x, hit.point.y - pressed.start.y).length() > 0.018: return
	_activate(int(pressed.target), pressed.item, str(pressed.scope))

func _activate(target: int, item: Dictionary, media_scope: String) -> void:
	if target == ADD:
		if menu._state.get("bookmark_ready", false): menu.bookmark_requested.emit("add", "", media_scope)
	elif target == UNDO:
		menu.bookmark_requested.emit("undo", "", media_scope)
	elif target == LIST:
		opened = not opened; subset.clear(); offset = 0; _close_other_popups(); menu.refresh()
	elif target == CLOSE:
		opened = false; menu.refresh()
	elif target in [UP, DOWN]:
		offset += -ROWS if target == UP else ROWS; menu.refresh()
	elif item.get("kind") == "delete":
		menu.bookmark_requested.emit("delete", str(item.id), media_scope)
	elif item.get("kind") == "seek":
		menu.bookmark_requested.emit("seek", str(item.id), media_scope)
	elif item.get("kind") == "group":
		if item.ids.size() == 1: menu.bookmark_requested.emit("seek", str(item.ids[0]), media_scope)
		else:
			opened = true; subset = item.ids.duplicate(); offset = 0; _close_other_popups(); menu.refresh()

func _close_other_popups() -> void:
	menu._subtitle_open = false; menu._mode_open = false; menu._volume_open = false
	menu._close_depth_slider()

func stick_scroll(y: float, delta: float) -> void:
	if not opened or not capture.is_empty() or not is_finite(y) or absf(y) < 0.3: return
	scroll -= y * delta * 8
	if absf(scroll) >= 1:
		offset += int(scroll); scroll -= int(scroll); menu.refresh()

func key() -> Array:
	return [menu._state.get("bookmark_scope", ""), menu._state.get("bookmark_revision", 0),
		menu._state.get("bookmark_undo", false), menu._state.get("bookmark_ready", false),
		menu._state.get("bookmark_seekable", false), menu._state.get("duration_ms", 0), Time.get_ticks_msec() < notice_until]
