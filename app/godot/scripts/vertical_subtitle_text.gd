extends Control
## Native vertical shaping, one independently shaped run per wrapped column.
## Godot 4.7 shaped_text_substr() clears the first glyph's negative x offset,
## which is legitimate in vertical layout. Re-shape the full column to retain it.
const FONT_SIZE := 40
const MARGIN := 40.0
const COLUMN_PITCH := 56.0
var columns: Array[Dictionary] = []
var content_scale := 1.0
var _server: TextServer
var _font: Font

func set_text(value: String, font: Font) -> void:
	_clear_columns()
	_server = TextServerManager.get_primary_interface()
	_font = font
	var available := maxf(1, size.y - 2 * MARGIN)
	for paragraph in value.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
		if paragraph.is_empty():
			columns.append({"text": "", "rid": RID(), "size": Vector2(FONT_SIZE, 0)})
			continue
		var sideways := not _has_cjk(paragraph)
		var shape := _shape(paragraph, not sideways)
		var breaks := _server.shaped_text_get_line_breaks(shape, available, 0,
			TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE)
		for index in range(0, breaks.size(), 2):
			var text: String = paragraph.substr(breaks[index], breaks[index + 1] - breaks[index])
			var column := _shape(text, not sideways)
			var column_size := _server.shaped_text_get_size(column)
			columns.append({"text": text, "rid": column, "size": Vector2(column_size.y, column_size.x) if sideways else column_size, "sideways": sideways})
		_server.free_rid(shape)
	var height := 0.0
	var width := float(FONT_SIZE)
	for column in columns:
		height = maxf(height, column.size.y)
		width = maxf(width, column.size.x)
	width += maxf(0, columns.size() - 1) * COLUMN_PITCH
	content_scale = minf(1, minf((size.x - 2 * MARGIN) / width, available / maxf(1, height)))
	var right := (size.x / content_scale + maxf(0, columns.size() - 1) * COLUMN_PITCH) / 2
	var top := (size.y / content_scale - height) / 2
	for index in columns.size():
		columns[index].point = Vector2(right - index * COLUMN_PITCH, top)
		if columns[index].get("sideways", false):
			columns[index].point.x -= (_server.shaped_text_get_ascent(columns[index].rid) - _server.shaped_text_get_descent(columns[index].rid)) / 2
	queue_redraw()

# Latin-only translation lines retain word shaping and read sideways as a whole.
static func _has_cjk(text: String) -> bool:
	for index in text.length():
		var code := text.unicode_at(index)
		if (code >= 0x2E80 and code <= 0xA4CF) or (code >= 0xAC00 and code <= 0xD7AF) or (code >= 0xF900 and code <= 0xFAFF) or (code >= 0xFF00 and code <= 0xFFEF) or (code >= 0x20000 and code <= 0x323AF): return true
	return false

func _shape(text: String, vertical: bool = true) -> RID:
	var shape := _server.create_shaped_text(TextServer.DIRECTION_AUTO, TextServer.ORIENTATION_VERTICAL if vertical else TextServer.ORIENTATION_HORIZONTAL)
	_server.shaped_text_add_string(shape, text, _font.get_rids(), FONT_SIZE)
	_server.shaped_text_shape(shape)
	return shape

func _draw() -> void:
	if not _server: return
	for column in columns:
		if not column.rid.is_valid(): continue
		var point: Vector2 = column.point
		if column.get("sideways", false):
			draw_set_transform(point * content_scale, PI / 2, Vector2.ONE * content_scale)
			point = Vector2.ZERO
		else:
			draw_set_transform(Vector2.ZERO, 0, Vector2.ONE * content_scale)
		_server.shaped_text_draw_outline(column.rid, get_canvas_item(), point, -1, -1, 8, Color.BLACK)
		_server.shaped_text_draw(column.rid, get_canvas_item(), point, -1, -1, Color.WHITE)

func _clear_columns() -> void:
	if _server:
		for column in columns:
			if column.rid.is_valid(): _server.free_rid(column.rid)
	columns.clear()

func _exit_tree() -> void: _clear_columns()
