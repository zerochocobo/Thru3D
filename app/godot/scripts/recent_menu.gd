extends "res://scripts/ray_menu.gd"

signal chosen(uri: String)
signal choose_file
signal player_requested

const PLAYER := -5

var catalog: RefCounted
var focus_index := 0 # Desktop keyboard preview only.
var page := 0
var rows: Array[Dictionary] = []

func _reset_navigation() -> void:
	page = 0
	focus_index = 0

func refresh() -> void:
	rows = catalog.list_recent() if catalog else []
	page = clampi(page, 0, _page_count() - 1)
	_draw()

func _page_count() -> int:
	return ceili(float(rows.size() + 1) / PAGE_SIZE)

func move_focus(direction: int) -> void:
	focus_index = posmod(focus_index + direction, rows.size() + 1)
	page = focus_index / PAGE_SIZE
	_draw()

func activate_desktop() -> void:
	if visible:
		_activate(focus_index)

func _activate(target: int) -> void:
	if target == PLAYER:
		dismiss()
		player_requested.emit()
	elif target == PREVIOUS or target == NEXT:
		page = clampi(page + (-1 if target == PREVIOUS else 1), 0, _page_count() - 1)
		_draw()
	elif target == CLOSE:
		dismiss()
	elif target == 0:
		dismiss()
		choose_file.emit()
	elif target > 0 and target <= rows.size():
		var uri := str(rows[target - 1].uri)
		dismiss()
		chosen.emit(uri)

func _draw() -> void:
	_clear_layout()
	_set_backdrop(Vector2(1.55, 1.08))
	var heading := _label("Library", Vector3(-0.69, 0.445, 0.004), 29)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_button(PLAYER, "Player", Vector2(0.58, 0.445), Vector2(0.28, 0.065))
	var count := _label("Recent · %d" % rows.size(), Vector3(-0.69, 0.365, 0.004), 18)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	count.modulate = MUTED
	var pages := _label("%d / %d" % [page + 1, _page_count()], Vector3(0.66, 0.365, 0.004), 18)
	pages.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	pages.modulate = MUTED
	_decoration(Vector2(1.4, 0.002), Vector2(0, 0.315), Color(0.17, 0.2, 0.24))
	var first := page * PAGE_SIZE
	for index in range(first, mini(rows.size() + 1, first + PAGE_SIZE)):
		var text := "Open video"
		var resume := ""
		if index > 0:
			var entry: Dictionary = rows[index - 1]
			var seconds := int(entry.position_ms) / 1000
			text = _fit_title(str(entry.title), "", 1.0, 23)
			resume = "%02d:%02d" % [seconds / 60, seconds % 60]
		_button(index, text, Vector2(0, 0.25 - (index - first) * 0.087), Vector2(1.4, 0.075), true, "", index == 0)
		var node: MeshInstance3D = _buttons.back().node
		var title: Label3D = node.get_child(0)
		title.position.x = -0.55
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		_icon("folder" if index == 0 else "play", Vector3(-0.645, 0, 0.004), 0.036, _buttons.back().foreground, node)
		if index > 0:
			var time := _label(resume, Vector3(0.64, 0, 0.004), 18, node)
			time.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			time.modulate = MUTED
	if rows.is_empty():
		var empty := _label("No recent videos", Vector3(0, -0.03, 0.004), 22)
		empty.modulate = MUTED
	_button(PREVIOUS, "Previous", Vector2(-0.5, -0.415), Vector2(0.3, 0.075), page > 0)
	_button(NEXT, "Next", Vector2(0, -0.415), Vector2(0.3, 0.075), page < _page_count() - 1)
	_button(CLOSE, "Close", Vector2(0.5, -0.415), Vector2(0.3, 0.075))
	_update_highlights()

