extends RefCounted
## State and rendering for the server library, sharing LibraryMenu's ray/drag targets.
const I18n := preload("res://scripts/i18n.gd")
const ACTION := 1000
const KEY := 1400
const SORTS := ["created_at", "title", "date", "duration", "rating100"]
const SORT_NAMES := ["Recently added", "Title", "Release date", "Duration", "Rating"]
const FILTER_NAMES := {"tags": "Tags", "performers": "Performers", "studios": "Studios"}
var menu: Node
var view := "servers"
var server := {}
var query := {"page": 1, "q": "", "all_tags": true}
var servers: Array = []
var entries: Array = []
var candidates: Array = []
var detail := {}
var kind := "tags"
var exclude := false
var candidate_page := 1
var candidate_q := ""
var candidate_total := 0
var total := 0
var generation := 0
var pending := {}
var labels := {}
var covers := {}
var textures := {}
var failed_covers := {}
var selection := {}
var keyboard := ""
var text := ""
var shift := false
var symbols := false
var saved: Array = []
var setup := false
var busy := false
var chips: Array = []
var removing := {}

func _init(owner: Node) -> void:
	menu = owner
	var config := ConfigFile.new()
	if config.load("user://settings/server_filters.cfg") == OK:
		var value: Variant = config.get_value("filters", "items", [])
		if value is Array: saved = value.slice(0, 100)

func cancel() -> void:
	generation += 1
	if menu.platform:
		for id in pending: menu.platform.media_server_cancel(int(id))
	pending.clear()
	busy = false

func load_servers() -> void:
	cancel()
	view = "servers"
	server = {}
	request("servers")

func request(action: String, extra: Dictionary = {}) -> void:
	if not menu.platform:
		menu.status = "Headset only"
		return
	var body := {"action": action, "server_id": str(server.get("id", "")), "generation": generation}
	body.merge(extra, true)
	var id: int = menu.platform.media_server_request(JSON.stringify(body))
	if id > 0:
		pending[id] = body
		if action != "cover":
			busy = true
			menu.status = "Loading…"
	else:
		menu.status = "Server unavailable"

func browse(reset: bool = true) -> void:
	cancel()
	if reset: query.page = 1
	view = "scenes"
	entries = []
	textures.clear()
	failed_covers.clear()
	menu._reset_navigation()
	request("browse", query)
	menu.refresh()

func receive(id: int, payload: String) -> bool:
	if not pending.has(id): return false
	var expected: Dictionary = pending[id]
	pending.erase(id)
	var data: Variant = JSON.parse_string(payload)
	if not data is Dictionary or int(data.get("generation", -1)) != generation or data.get("server_id", "") != expected.server_id:
		return true
	if expected.action != "cover": busy = false
	if data.get("state") != "ready":
		if expected.action == "cover": failed_covers[expected.scene_id] = true
		else: menu.status = str(data.get("error", "Server unavailable"))
		menu.refresh()
		return true
	if expected.action != "cover": menu.status = ""
	match expected.action:
		"servers": servers = data.get("servers", [])
		"browse": entries = data.get("entries", []); total = int(data.get("total", 0))
		"candidates": candidates = data.get("entries", []); candidate_total = int(data.get("total", 0))
		"detail": detail = data.get("detail", {}); view = "detail"
		"cover":
			covers[str(expected.server_id) + "/" + str(expected.scene_id)] = str(data.get("path", ""))
		"remove":
			var removed := str(expected.server_id)
			saved = saved.filter(func(item): return item is Dictionary and item.get("server_id") != removed)
			var config := ConfigFile.new()
			if config.load("user://settings/server_filters.cfg") == OK:
				config.set_value("filters", "items", saved)
				config.save("user://settings/server_filters.cfg")
			covers.clear(); textures.clear(); failed_covers.clear(); removing = {}
			load_servers()
	menu.refresh()
	return true

func grid() -> bool:
	return view in ["servers", "scenes"] and keyboard.is_empty()

func rows() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not keyboard.is_empty(): return result
	match view:
		"servers":
			for item in servers: result.append({"title": str(item.name), "detail": {"stash": "Stash", "emby": "Emby", "jellyfin": "Jellyfin", "xbvr": "XBVR"}.get(item.get("provider", "stash"), ""), "icon": "media_library", "server_account": item})
		"remove_servers":
			for item in servers: result.append({"title": str(item.name), "detail": str(item.get("base", "")), "icon": "trash", "remove_server": item})
		"confirm_remove":
			result.append({"title": I18n.t("Remove server") + ": " + str(removing.get("name", "")), "icon": "trash", "confirm_remove": true})
			result.append({"title": I18n.t("Cancel"), "icon": "up", "cancel_remove": true})
		"scenes":
			for item in entries:
				var seconds := int(item.get("duration_ms", 0)) / 1000
				result.append({"title": str(item.title), "detail": "%d:%02d" % [seconds / 60, seconds % 60], "icon": "video", "scene": item})
		"filters":
			for category in FILTER_NAMES:
				result.append({"title": I18n.t(FILTER_NAMES[category]), "detail": str(query.get(category, []).size() + query.get("exclude_" + category, []).size()), "icon": "list", "category": category})
			result.append({"title": I18n.t("Include child tags"), "detail": "", "icon": "check" if query.get("descendants", false) else "circle", "toggle": "descendants"})
			result.append({"title": I18n.t("Watched") + ": " + I18n.t("All" if not query.has("watched") else ("Yes" if query.watched else "No")), "icon": "history", "toggle": "watched"})
			result.append({"title": I18n.t("Minimum duration") + ": " + ("—" if not query.has("min_duration") else "%d min" % (int(query.min_duration) / 60)), "icon": "time", "toggle": "min_duration"})
			result.append({"title": I18n.t("Minimum rating") + ": " + str(query.get("min_rating", "—")), "icon": "info", "toggle": "min_rating"})
			result.append({"title": I18n.t("Resolution") + ": " + str(query.get("resolution", "—")).replace("FOUR_K", "4K").replace("SIX_K", "6K").replace("EIGHT_K", "8K"), "icon": "video", "toggle": "resolution"})
			result.append({"title": I18n.t("Clear filters"), "icon": "trash", "reset": true})
		"candidates":
			for item in candidates:
				var id := str(item.id)
				var included: bool = id in query.get(kind, [])
				var excluded: bool = id in query.get("exclude_" + kind, [])
				result.append({"title": str(item.name), "detail": "−" if excluded else ("+" if included else ""), "icon": "check" if included else ("minus" if excluded else "circle"), "selected": included or excluded, "candidate": item})
		"detail":
			if not detail.is_empty():
				result.append({"title": I18n.t("Play / resume"), "icon": "play", "play_scene": detail})
				for category in ["tags", "performers"]:
					for item in detail.get(category, []): result.append({"title": str(item.name), "detail": I18n.t(FILTER_NAMES[category]), "icon": "plus", "detail_filter": item, "category": category})
				for marker in detail.get("markers", []):
					var seconds := int(marker.position_ms) / 1000
					result.append({"title": "%d:%02d  %s" % [seconds / 60, seconds % 60, str(marker.title)], "icon": "seek_forward", "marker": marker})
		"saved":
			for item in saved:
				if item is Dictionary and item.get("server_id") == server.get("id") and item.get("query") is Dictionary:
					result.append({"title": str(item.get("name", "")), "icon": "list", "saved_filter": item})
	if view == "filters" and server.get("provider", "stash") != "stash":
		var provider: String = server.get("provider", "stash")
		var supported: Array[Dictionary] = []
		for row in result:
			if row.has("reset") or row.get("toggle", "") == "watched": supported.append(row)
			elif provider == "xbvr" and row.has("category"): supported.append(row)
			elif provider in ["emby", "jellyfin"] and row.get("toggle", "") == "min_rating": supported.append(row)
		return supported
	return result

func choose(row: Dictionary) -> void:
	if row.has("remove_server"):
		removing = row.remove_server.duplicate(true); view = "confirm_remove"; menu._reset_navigation()
	elif row.has("confirm_remove"):
		if busy: return
		cancel(); server = removing.duplicate(true); request("remove")
	elif row.has("cancel_remove"):
		removing = {}; view = "remove_servers"; menu._reset_navigation()
	elif row.has("server_account"):
		server = row.server_account.duplicate(true); query = {"page": 1, "q": "", "all_tags": true}; failed_covers.clear(); browse()
	elif row.has("scene"):
		cancel(); detail = {}; view = "detail"; menu._reset_navigation(); request("detail", {"scene_id": str(row.scene.id)})
	elif row.has("category") and not row.has("detail_filter"):
		kind = str(row.category); view = "candidates"; candidate_q = ""; candidate_page = 1; get_candidates()
	elif row.has("candidate"):
		set_filter(kind, row.candidate, exclude)
	elif row.has("detail_filter"):
		set_filter(str(row.category), row.detail_filter, false); browse()
	elif row.has("play_scene") or row.has("marker"):
		selection = detail.duplicate(true)
		selection["start_ms"] = int(row.marker.position_ms) if row.has("marker") else -1
		menu.dismiss(); menu.chosen.emit(str(detail.uri), str(detail.title))
		return
	elif row.has("saved_filter"):
		query = row.saved_filter.query.duplicate(true); labels = row.saved_filter.get("labels", {}).duplicate(true); browse()
	elif row.has("reset"):
		query = {"page": 1, "q": "", "all_tags": true}; labels.clear()
	elif row.has("toggle"):
		var key: String = row.toggle
		match key:
			"descendants": query[key] = not query.get(key, false)
			"watched":
				if not query.has(key): query[key] = true
				elif query[key]: query[key] = false
				else: query.erase(key)
			_: cycle(key, {"min_duration": [0, 600, 1200, 1800, 3600], "min_rating": [0, 20, 40, 60, 80], "resolution": ["", "FOUR_K", "SIX_K", "EIGHT_K"]}[key])
	menu.refresh()

func cycle(key: String, values: Array) -> void:
	var at: int = values.find(query.get(key, values[0]))
	var next: Variant = values[(at + 1) % values.size()]
	if next == values[0]: query.erase(key)
	else: query[key] = next

func set_filter(category: String, item: Dictionary, negative: bool) -> void:
	var key := ("exclude_" if negative else "") + category
	var other := ("" if negative else "exclude_") + category
	var ids: Array = query.get(key, []).duplicate()
	var id := str(item.id)
	if id in ids: ids.erase(id)
	else: ids.append(id)
	query[key] = ids
	var opposite: Array = query.get(other, []).duplicate(); opposite.erase(id); query[other] = opposite
	labels[category + "/" + id] = str(item.name)

func get_candidates() -> void:
	cancel(); candidates = []; menu._reset_navigation()
	request("candidates", {"kind": kind, "q": candidate_q, "page": candidate_page})

func action(target: int) -> bool:
	if target < ACTION: return false
	if keyboard.is_empty() and target >= ACTION + 200 and target < ACTION + 200 + chips.size():
		var chip: Dictionary = chips[target - ACTION - 200]
		var ids: Array = query.get(chip.key, []).duplicate(); ids.erase(chip.id); query[chip.key] = ids
		browse()
		return true
	if not keyboard.is_empty():
		if target >= KEY and target < KEY + 40:
			var layer: Array = menu.SYMBOLS if symbols else menu.KEYS
			var character: String = layer[(target - KEY) / 10][(target - KEY) % 10]
			text = (text + (character.to_upper() if shift else character)).left(200); shift = false
		elif target == ACTION + 21: text = text.left(-1)
		elif target == ACTION + 22: text = (text + " ").left(200)
		elif target == ACTION + 23: shift = not shift
		elif target == ACTION + 24: symbols = not symbols
		elif target == ACTION + 25: keyboard = ""
		elif target == ACTION + 26:
			var purpose := keyboard; keyboard = ""
			if purpose == "save":
				if not text.strip_edges().is_empty():
					saved = saved.filter(func(item): return not (item is Dictionary and item.get("server_id") == server.get("id") and item.get("name") == text.strip_edges()))
					saved.append({"server_id": server.id, "name": text.strip_edges(), "query": query.duplicate(true), "labels": labels.duplicate(true)})
					if saved.size() > 100: saved.pop_front()
					var config := ConfigFile.new(); config.set_value("filters", "items", saved)
					DirAccess.make_dir_recursive_absolute("user://settings")
					if config.save("user://settings/server_filters.cfg") != OK: menu.status = "Unable to save filters"
			elif view == "candidates": candidate_q = text; candidate_page = 1; get_candidates()
			else: query.q = text; browse()
	else:
		match target - ACTION:
			0:
				if view == "servers": pass
				elif view in ["remove_servers", "confirm_remove"]: removing = {}; load_servers()
				elif view == "scenes": load_servers()
				elif view == "candidates": cancel(); view = "filters"
				else: browse()
			1, 14: cancel(); menu.account_panel.open("server", target == ACTION + 14)
			2: keyboard = "search"; text = candidate_q if view == "candidates" else str(query.get("q", ""))
			3: cancel(); view = "filters"; menu._reset_navigation()
			4:
				query.sort = SORTS[(SORTS.find(str(query.get("sort", "created_at"))) + 1) % SORTS.size()]
				if server.get("provider", "stash") == "xbvr" and query.sort == "duration": query.sort = "rating100"
				query.direction = "ASC" if query.sort == "title" else "DESC"; browse()
			5, 6:
				var step := -1 if target - ACTION == 5 else 1
				if view == "candidates": candidate_page = maxi(1, candidate_page + step); get_candidates()
				else: query.page = maxi(1, int(query.page) + step); browse(false)
			7: exclude = not exclude
			8: query.all_tags = not query.get("all_tags", true)
			9: keyboard = "save"; text = ""
			10: cancel(); view = "saved"; menu._reset_navigation()
			11: browse()
			12:
				if busy: return true
				if view == "servers": load_servers()
				else: browse(false)
			13: cancel(); view = "remove_servers"; menu._reset_navigation()
	menu.refresh()
	return true

func cover(row: Dictionary) -> Texture2D:
	if not row.has("scene"): return null
	var id := str(row.scene.id)
	var key := str(server.get("id", "")) + "/" + id
	if textures.has(key): return textures[key]
	if covers.has(key):
		var image := Image.new()
		if image.load(str(covers[key])) == OK:
			var texture := ImageTexture.create_from_image(image)
			if textures.size() >= 24: textures.erase(textures.keys()[0])
			textures[key] = texture
			return texture
		covers.erase(key)
	var active_covers: Array = pending.values().filter(func(p): return p.action == "cover")
	if menu.visible and not failed_covers.has(id) and active_covers.size() < 2 and not active_covers.any(func(p): return p.scene_id == id):
		request("cover", {"scene_id": id})
	return null

func draw() -> void:
	if not keyboard.is_empty():
		menu._label(I18n.t("Save search" if keyboard == "save" else "Search"), Vector3(0.15, 0.46, 0.004), 23)
		menu._button(ACTION + 27, text.right(60) + "│", Vector2(0.15, 0.33), Vector2(1.24, 0.09))
		var layer: Array = menu.SYMBOLS if symbols else menu.KEYS
		for r in 4:
			for c in 10:
				var character: String = layer[r][c]
				menu._button(KEY + r * 10 + c, character.to_upper() if shift else character, Vector2(-0.415 + c * 0.125, 0.16 - r * 0.12), Vector2(0.112, 0.1))
		for item in [[21, "⌫"], [22, "Space"], [23, "Shift"], [24, "#+="], [25, "Cancel"], [26, "Apply"]]:
			menu._button(ACTION + item[0], I18n.t(item[1]), Vector2(-0.4 + (item[0] - 21) * 0.22, -0.4), Vector2(0.21, 0.08))
		return
	prioritize_covers()
	menu._button(ACTION, "", Vector2(-0.52, 0.46), Vector2(0.09, 0.07), view != "servers", "up")
	var title := str(server.get("name", I18n.t("Media servers")))
	if view == "detail": title = str(detail.get("title", "…"))
	elif view == "candidates": title = I18n.t(FILTER_NAMES[kind])
	elif view == "filters": title = I18n.t("Filters")
	elif view == "saved": title = I18n.t("Saved searches")
	elif view in ["remove_servers", "confirm_remove"]: title = I18n.t("Remove server")
	var label: Label3D = menu._label(menu._fit_title(title, "", 0.68, 22), Vector3(-0.43, 0.46, 0.004), 22)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	if view == "candidates" or (view == "scenes" and server.get("provider", "stash") != "xbvr"):
		menu._button(ACTION + 2, "", Vector2(0.43, 0.46), Vector2(0.09, 0.07), true, "search")
	if view == "scenes":
		menu._button(ACTION + 12, "", Vector2(0.31, 0.46), Vector2(0.09, 0.07), not busy, "refresh")
		menu._button(ACTION + 3, "", Vector2(0.55, 0.46), Vector2(0.09, 0.07), true, "settings")
		menu._button(ACTION + 4, "", Vector2(0.67, 0.46), Vector2(0.09, 0.07), true, "list")
		menu._tips[ACTION + 4] = I18n.t(SORT_NAMES[SORTS.find(str(query.get("sort", "created_at")))])
		chips = []
		for category in FILTER_NAMES:
			for prefix in ["", "exclude_"]:
				for id in query.get(prefix + category, []): chips.append({"key": prefix + category, "id": id, "label": ("− " if prefix != "" else "+ ") + str(labels.get(category + "/" + id, id))})
		for i in mini(6, chips.size()):
			menu._button(ACTION + 200 + i, menu._fit_title(str(chips[i].label), "", 0.33, 16) + " ×", Vector2(-0.28 + (i % 3) * 0.43, -0.28 - (i / 3) * 0.085), Vector2(0.41, 0.065))
			(menu._buttons.back().node.get_child(0) as Label3D).font_size = 16
	menu._button(ACTION + 1, "", Vector2(0.79, 0.46), Vector2(0.09, 0.07), menu.platform != null, "plus" if view == "servers" else "edit")
	if view == "servers":
		menu._button(ACTION + 14, "", Vector2(0.43, 0.46), Vector2(0.09, 0.07), menu.platform != null and not servers.is_empty(), "edit")
		menu._tips[ACTION + 14] = I18n.t("Edit")
		menu._button(ACTION + 12, "", Vector2(0.55, 0.46), Vector2(0.09, 0.07), not busy and menu.platform != null, "refresh")
		menu._button(ACTION + 13, "", Vector2(0.67, 0.46), Vector2(0.09, 0.07), not servers.is_empty(), "trash")
		menu._tips[ACTION + 13] = I18n.t("Remove server")
	if view == "candidates":
		menu._button(ACTION + 7, I18n.t("Exclude" if exclude else "Include"), Vector2(0.16, -0.47), Vector2(0.25, 0.07))
		if kind == "tags": menu._button(ACTION + 8, I18n.t("Match all" if query.get("all_tags", true) else "Match any"), Vector2(0.46, -0.47), Vector2(0.25, 0.07))
	if view in ["scenes", "candidates"]:
		var page: int = candidate_page if view == "candidates" else int(query.page)
		var count: int = candidate_total if view == "candidates" else total
		menu._button(ACTION + 5, "‹", Vector2(-0.45, -0.47), Vector2(0.09, 0.07), not busy and page > 1)
		menu._label("%d / %d" % [page, maxi(1, ceili(count / 48.0))], Vector3(-0.27, -0.47, 0.004), 18)
		menu._button(ACTION + 6, "›", Vector2(-0.09, -0.47), Vector2(0.09, 0.07), not busy and page * 48 < count)
		if view == "scenes":
			menu._button(ACTION + 9, I18n.t("Save search"), Vector2(0.18, -0.47), Vector2(0.36, 0.07))
			menu._button(ACTION + 10, I18n.t("Saved searches"), Vector2(0.59, -0.47), Vector2(0.39, 0.07))
	elif view == "filters":
		menu._button(ACTION + 11, I18n.t("Apply"), Vector2(0.62, -0.47), Vector2(0.3, 0.07))
	var state: String = I18n.t(menu.status)
	if state.is_empty() and view == "scenes":
		var parts: Array[String] = []
		if not str(query.get("q", "")).is_empty(): parts.append(str(query.q))
		for category in FILTER_NAMES:
			for prefix in ["", "exclude_"]:
				for id in query.get(prefix + category, []): parts.append(("− " if prefix != "" else "+ ") + str(labels.get(category + "/" + id, id)))
		state = "%d  ·  %s" % [total, ", ".join(parts)]
	menu._label(menu._fit_title(state, "", 1.25, 16), Vector3(0.16, -0.55, 0.004), 16)
	if view == "detail" and not detail.is_empty(): draw_detail()
	else: menu._draw_rows()

func prioritize_covers() -> void:
	var visible_ids: Array[String] = []
	if view == "scenes":
		var first: int = menu._first_line() * menu._cols()
		for item in entries.slice(first, first + menu._drawn_slots()): visible_ids.append(str(item.id))
	elif view == "detail" and not detail.is_empty(): visible_ids.append(str(detail.id))
	for id in pending.keys():
		var req: Dictionary = pending[id]
		if req.action == "cover" and str(req.scene_id) not in visible_ids:
			if menu.platform: menu.platform.media_server_cancel(int(id))
			pending.erase(id)

func draw_detail() -> void:
	var texture := cover({"scene": detail})
	var panel: MeshInstance3D = menu._decoration(Vector2(0.36, 0.24), Vector2(-0.3, 0.2), Color(0.13, 0.15, 0.18))
	if texture:
		panel.material_override = menu._material(Color.WHITE, 12)
		panel.material_override.albedo_texture = texture
	var description: Label3D = menu._label(str(detail.get("description", "")).left(140), Vector3(-0.3, -0.02, 0.004), 15)
	description.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	description.width = 0.35 / description.pixel_size
	description.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	menu._list = Node3D.new(); menu.add_child(menu._list); menu._decorations.append(menu._list)
	var first: int = menu._first_line()
	for i in range(first, mini(menu.rows.size(), first + menu._drawn_slots())):
		var row: Dictionary = menu.rows[i]
		var k := i - first
		menu._button(menu.ROW_BASE + k, menu._fit_title(str(row.title), "", 0.7, 20), Vector2(0.39, menu.LIST_TOP - k * menu.ROW_PITCH), Vector2(0.76, 0.098), true, "", false, menu._list)
	if menu._max_scroll() > 0:
		var span: Vector2 = menu._bar_span()
		menu._button(menu.SCROLLBAR, "", Vector2(0.835, span.x - span.y * 0.5), Vector2(0.04, span.y))
		var thumb: float = span.y * menu._lines() / menu._line_count()
		menu._bar_thumb = menu._decoration(Vector2(0.012, thumb), Vector2(0.835, span.x - thumb * 0.5), menu.MUTED)
	menu._place_list()
