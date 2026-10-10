extends RefCounted
## One ray-driven browser; native clients supply capabilities and normalized nodes.
const I18n := preload("res://scripts/i18n.gd")
const ACTION := 1000
const KEY := 1400
const SORTS := ["created_at", "title", "date", "duration", "rating100"]
const SORT_NAMES := ["Recently added", "Title", "Release date", "Duration", "Rating"]
const FILTER_NAMES := {"genres": "Genres", "tags": "Tags", "performers": "Performers", "studios": "Studios"}
var menu: Node
var view := "servers"
var server := {}
var capabilities := {"navigation": [], "facets": [], "filters": ["watched"], "sorts": ["created_at", "title"], "favorite_scope": "local", "search": true}
var home_data := {}
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
var loaded_page := 0
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
var favorites := {}
var setup := false
var busy := false
var chips: Array = []
var removing := {}
var history: Array = []
var folder_path: Array = []
var library_id := ""
var end_reached := false
var candidate_end := false

func _init(owner: Node) -> void:
	menu = owner
	var config := ConfigFile.new()
	if config.load("user://settings/server_filters.cfg") == OK:
		var value: Variant = config.get_value("filters", "items", [])
		if value is Array: saved = value.slice(0, 100)
	if config.load("user://settings/server_favorites.cfg") == OK:
		for id in config.get_section_keys("favorites") if config.has_section("favorites") else []:
			var value: Variant = config.get_value("favorites", id, [])
			if value is Array: favorites[id] = value.filter(func(item): return item is Dictionary and str(item.get("uri", "")).begins_with("medialib://" + str(id) + "/scene/")).slice(0, 1000)

func cancel() -> void:
	generation += 1
	if menu.platform:
		for id in pending: menu.platform.media_server_cancel(int(id))
	pending.clear()
	busy = false

func load_servers() -> void:
	cancel(); view = "servers"; server = {}; history.clear(); keyboard = ""
	menu._reset_navigation()
	request("servers")

func request(action_name: String, extra: Dictionary = {}) -> void:
	if not menu.platform:
		menu.status = "Headset only"; return
	var body := {"action": action_name, "server_id": str(server.get("id", "")), "generation": generation}
	body.merge(extra, true)
	var id: int = menu.platform.media_server_request(JSON.stringify(body))
	if id > 0:
		pending[id] = body
		if action_name != "cover": busy = true; menu.status = "Loading…"
	else: menu.status = "Server unavailable"

func open_home() -> void:
	cancel(); view = "home"; entries = []; home_data = {}; folder_path = []; history.clear()
	query = {"page": 1, "q": "", "all_tags": true}; labels.clear()
	menu._reset_navigation(); request("home", {"library_id": library_id}); menu.refresh()

func browse(reset: bool = true) -> void:
	cancel()
	if reset: query.page = 1
	query.library_id = library_id
	view = "scenes"; entries = []; loaded_page = 0; end_reached = false
	if query.get("favorites", false) and capabilities.get("favorite_scope", "local") != "server":
		entries = _local_favorites_query(); total = entries.size(); end_reached = true
		menu.status = ""; menu._reset_navigation(); menu.refresh(); return
	textures.clear(); failed_covers.clear()
	menu._reset_navigation(); request("browse", query); menu.refresh()

func _append_unique(target: Array, incoming: Array) -> int:
	var seen := {}
	for item in target: seen[str(item.get("id", ""))] = true
	var added := 0
	for item in incoming:
		if item is Dictionary and not seen.has(str(item.get("id", ""))):
			seen[str(item.get("id", ""))] = true; target.append(item); added += 1
	return added

func receive(id: int, payload: String) -> bool:
	if not pending.has(id): return false
	var expected: Dictionary = pending[id]; pending.erase(id)
	var data: Variant = JSON.parse_string(payload)
	if not data is Dictionary or int(data.get("generation", -1)) != generation or data.get("server_id", "") != expected.server_id: return true
	if expected.action != "cover": busy = false
	if data.get("state") != "ready":
		if expected.action == "cover": failed_covers[expected.scene_id] = true
		else: menu.status = str(data.get("error", "Server unavailable"))
		menu.refresh(); return true
	if expected.action != "cover": menu.status = ""
	match expected.action:
		"servers": servers = data.get("servers", [])
		"home":
			home_data = data; capabilities = data.get("capabilities", capabilities); library_id = str(data.get("library_id", "")); total = int(data.get("total", 0))
			entries = []; _append_unique(entries, _resume_entries()); _append_unique(entries, home_data.get("recent", []))
		"browse":
			var incoming: Array = data.get("entries", [])
			var page := int(expected.get("page", 1))
			if page == 1: entries = []; total = int(data.get("total", 0))
			else: total = maxi(total, int(data.get("total", 0)))
			var added := _append_unique(entries, incoming)
			loaded_page = page; query.page = page
			end_reached = incoming.size() < 48 or entries.size() >= total or added == 0
			if page > 1 and not incoming.is_empty() and added == 0: menu.status = "Server query unsupported"
		"candidates":
			var incoming: Array = data.get("entries", [])
			if int(expected.get("page", 1)) == 1: candidates = []
			var added := _append_unique(candidates, incoming)
			candidate_total = int(data.get("total", 0)); candidate_page = int(expected.get("page", 1))
			candidate_end = incoming.size() < 48 or candidates.size() >= candidate_total or added == 0
		"detail":
			detail = data.get("detail", {}); view = "detail"
			for local in _local_resume():
				if local.id == detail.get("id"): detail.position_ms = local.position_ms
		"favorite":
			if str(detail.get("id", "")) == str(data.get("scene_id", "")):
				detail.favorite = bool(data.get("favorite", false))
				_favorite_changed(str(detail.id), detail.favorite)
		"cover": covers[str(expected.server_id) + "/" + str(expected.scene_id)] = str(data.get("path", ""))
		"remove":
			var removed := str(expected.server_id)
			saved = saved.filter(func(item): return item is Dictionary and item.get("server_id") != removed)
			_save_filters(); favorites.erase(removed); _save_favorites()
			covers.clear(); textures.clear(); failed_covers.clear(); removing = {}; load_servers()
	menu.refresh()
	return true

func _local_resume() -> Array:
	var result: Array = []
	if not menu.catalog: return result
	var prefix := "medialib://" + str(server.get("id", "")) + "/scene/"
	for item in menu.catalog.list_recent():
		if str(item.get("uri", "")).begins_with(prefix) and int(item.get("position_ms", 0)) > 0 and (int(item.get("duration_ms", 0)) <= 0 or int(item.position_ms) < int(item.duration_ms) - 1000):
			var node: Dictionary = item.duplicate(true); node.id = str(item.uri).trim_prefix(prefix); node.resume_source = "local"; node.kind = "video"
			result.append(node)
	return result

func _resume_entries() -> Array:
	var result: Array = []; _append_unique(result, _local_resume()); _append_unique(result, home_data.get("resume", []))
	return result.slice(0, 1)

func _remember() -> void:
	history.append({"view": view, "query": query.duplicate(true), "entries": entries.duplicate(true), "candidates": candidates.duplicate(true), "detail": detail.duplicate(true), "kind": kind,
		"total": total, "loaded_page": loaded_page, "candidate_page": candidate_page, "candidate_total": candidate_total, "candidate_q": candidate_q, "labels": labels.duplicate(true), "folder_path": folder_path.duplicate(true), "scroll": menu.scroll, "end": end_reached, "candidate_end": candidate_end})
	if history.size() > 12: history.pop_front()

func back() -> void:
	cancel(); keyboard = ""
	if not history.is_empty():
		var previous: Dictionary = history.pop_back()
		view = previous.view; query = previous.query; entries = previous.entries; candidates = previous.candidates; detail = previous.detail; kind = previous.kind
		total = previous.total; loaded_page = previous.loaded_page; candidate_page = previous.candidate_page; candidate_total = previous.candidate_total; candidate_q = previous.candidate_q
		labels = previous.labels; folder_path = previous.folder_path; end_reached = previous.end; candidate_end = previous.candidate_end
		menu._reset_navigation(); menu.scroll = previous.scroll; menu.status = ""; menu.refresh()
	elif view == "home": load_servers()
	elif view in ["remove_servers", "confirm_remove"]: removing = {}; load_servers()
	else: open_home()

func grid() -> bool:
	return view in ["servers", "home", "scenes", "facets", "libraries"] and keyboard.is_empty()

func visible_lines() -> int:
	return 2 if grid() else (4 if view == "filters" else 5)

func pitch() -> float:
	return 0.29 if grid() else (0.10 if view == "filters" else 0.105)

func list_top() -> float:
	return 0.18 if grid() else 0.15

func bar_span() -> Vector2:
	return Vector2(list_top() + (0.035 if not grid() else 0.0), visible_lines() * pitch() - 0.015)

func rows() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not keyboard.is_empty(): return result
	match view:
		"servers":
			for item in servers: result.append({"title": str(item.name), "detail": str(item.get("provider", "")).capitalize(), "icon": "media_library", "server_account": item})
		"remove_servers":
			for item in servers: result.append({"title": str(item.name), "detail": menu.account_panel.provider_name(str(item.get("provider", ""))), "icon": "trash", "remove_server": item})
		"confirm_remove":
			result.append({"title": I18n.t("Remove server") + ": " + str(removing.get("name", "")), "detail": menu.account_panel.provider_name(str(removing.get("provider", ""))), "icon": "trash", "confirm_remove": true})
			result.append({"title": I18n.t("Cancel"), "icon": "up", "cancel_remove": true})
		"home":
			for item in _resume_entries(): result.append(_node_row(item).merged({"resume": true}))
			for item in home_data.get("recent", []).slice(0, 4): result.append(_node_row(item))
		"scenes":
			for item in entries: result.append(_node_row(item))
		"libraries":
			for item in home_data.get("libraries", []): result.append({"title": str(item.title), "detail": "", "icon": "library", "library": item})
		"facets":
			if kind in capabilities.get("unclassified", []): result.append({"title": I18n.t("Uncategorized"), "detail": "", "icon": "folder", "unclassified": kind})
			for item in candidates: result.append({"title": str(item.name), "detail": str(item.count) if int(item.get("count", -1)) >= 0 else "", "icon": "list", "facet": item})
		"filters":
			for category in capabilities.get("facets", []): result.append({"title": I18n.t(FILTER_NAMES.get(category, category)), "detail": str(query.get(category, []).size() + query.get("exclude_" + category, []).size()), "icon": "list", "category": category})
			if capabilities.get("descendants", false) and not query.get("favorites", false): result.append({"title": I18n.t("Include child tags"), "detail": "", "icon": "check" if query.get("descendants", false) else "circle", "toggle": "descendants"})
			for flag in capabilities.get("filters", []):
				if query.get("favorites", false) and capabilities.get("favorite_scope", "local") != "server":
					if flag in ["watched", "resolution"]: continue
				var caption := ""
				match flag:
					"watched": caption = I18n.t("Watched") + ": " + I18n.t("All" if not query.has(flag) else ("Yes" if query[flag] else "No"))
					"min_rating": caption = I18n.t("Minimum rating") + ": " + str(query.get(flag, "—"))
					"min_duration": caption = I18n.t("Minimum duration") + ": " + ("—" if not query.has(flag) else "%d min" % (int(query[flag]) / 60))
					"resolution": caption = I18n.t("Resolution") + ": " + str(query.get(flag, "—")).replace("FOUR_K", "4K").replace("SIX_K", "6K").replace("EIGHT_K", "8K")
				if not caption.is_empty(): result.append({"title": caption, "icon": "history" if flag == "watched" else "info", "toggle": flag})
			result.append({"title": I18n.t("Clear filters"), "icon": "trash", "reset": true})
		"candidates":
			for item in candidates:
				var id := str(item.id); var included: bool = id in query.get(kind, []); var excluded: bool = id in query.get("exclude_" + kind, [])
				result.append({"title": str(item.name), "detail": "−" if excluded else ("+" if included else ""), "icon": "check" if included else ("minus" if excluded else "circle"), "selected": included or excluded, "candidate": item})
		"detail":
			if not detail.is_empty():
				result.append({"title": I18n.t("Continue watching" if int(detail.get("position_ms", 0)) > 0 else "Play / resume"), "icon": "play", "play_scene": detail})
				result.append({"title": I18n.t("Favorited" if _is_favorite(detail) else "Favorite"), "icon": "heart", "favorite": true})
				for category in capabilities.get("facets", []):
					for item in detail.get(category, []): result.append({"title": str(item.name), "detail": I18n.t(FILTER_NAMES.get(category, category)), "icon": "plus", "detail_filter": item, "category": category})
				for marker in detail.get("markers", []): result.append({"title": _time(int(marker.position_ms)) + "  " + str(marker.title), "icon": "seek_forward", "marker": marker})
		"saved":
			for item in saved:
				if item is Dictionary and item.get("server_id") == server.get("id") and item.get("query") is Dictionary: result.append({"title": str(item.get("name", "")), "icon": "list", "saved_filter": item})
		"options":
			if home_data.get("libraries", []).size() > 1: result.append({"title": I18n.t("Libraries"), "icon": "library", "open_libraries": true})
			result.append({"title": I18n.t("Refresh"), "icon": "refresh", "refresh_server": true})
			result.append({"title": I18n.t("Saved searches"), "icon": "list", "open_saved": true})
			result.append({"title": I18n.t("Edit"), "icon": "edit", "edit_server": true})
	return result

func _node_row(item: Dictionary) -> Dictionary:
	if item.get("container", false): return {"title": str(item.title), "detail": str(item.get("child_count", "")) if int(item.get("child_count", -1)) >= 0 else "", "icon": "folder", "container_node": item}
	return {"title": str(item.get("title", "Video")), "detail": _time(int(item.get("duration_ms", 0))) if int(item.get("duration_ms", 0)) > 0 else "", "icon": "video", "scene": item}

func _time(ms: int) -> String:
	var seconds := maxi(0, ms / 1000)
	return "%d:%02d" % [seconds / 60, seconds % 60]

func choose(row: Dictionary) -> void:
	if row.has("remove_server"): removing = row.remove_server.duplicate(true); view = "confirm_remove"; menu._reset_navigation()
	elif row.has("confirm_remove"):
		if busy: return
		cancel(); server = removing.duplicate(true); request("remove")
	elif row.has("cancel_remove"): removing = {}; view = "remove_servers"; menu._reset_navigation()
	elif row.has("server_account"):
		server = row.server_account.duplicate(true); capabilities = server.get("capabilities", {"navigation": [], "facets": [], "filters": [], "sorts": ["created_at", "title"], "favorite_scope": "local", "search": true}); library_id = ""; textures.clear(); failed_covers.clear(); open_home()
	elif row.has("resume"): _play(row.scene, int(row.scene.get("position_ms", -1)))
	elif row.has("container_node"):
		_remember(); folder_path.append(row.container_node); query.parent_id = row.container_node.id; query.mode = "folders"; browse()
	elif row.has("library"):
		library_id = str(row.library.id); open_home()
	elif row.has("facet") or row.has("detail_filter") or row.has("unclassified"):
		_remember()
		if row.has("unclassified"): query.unclassified = row.unclassified
		else:
			var category := str(row.get("category", kind)); var item: Dictionary = row.get("facet", row.get("detail_filter", {}))
			query[category] = [str(item.id)]; query.erase("exclude_" + category); query.erase("unclassified"); labels[category + "/" + str(item.id)] = str(item.name)
		query.erase("mode"); query.erase("parent_id"); folder_path.clear(); browse()
	elif row.has("scene"):
		_remember(); cancel(); detail = {}; view = "detail"; menu._reset_navigation(); request("detail", {"scene_id": str(row.scene.id)})
	elif row.has("category"):
		_remember(); cancel(); kind = str(row.category); exclude = false; view = "candidates"; candidate_q = ""; candidate_page = 1; get_candidates()
	elif row.has("candidate"): set_filter(kind, row.candidate, exclude)
	elif row.has("play_scene") or row.has("marker"):
		_play(detail, int(row.marker.position_ms) if row.has("marker") else (int(detail.position_ms) if int(detail.get("position_ms", 0)) > 0 else -1))
	elif row.has("favorite"): _toggle_favorite()
	elif row.has("saved_filter"):
		_remember(); query = row.saved_filter.query.duplicate(true); library_id = str(query.get("library_id", library_id)); labels = row.saved_filter.get("labels", {}).duplicate(true); browse()
	elif row.has("reset"):
		var context := {}
		for key in ["mode", "parent_id", "favorites"]:
			if query.has(key): context[key] = query[key]
		query = {"page": 1, "q": "", "all_tags": true}; query.merge(context); labels.clear()
	elif row.has("toggle"):
		var key: String = row.toggle
		match key:
			"descendants": query[key] = not query.get(key, false)
			"watched":
				if not query.has(key): query[key] = true
				elif query[key]: query[key] = false
				else: query.erase(key)
			_: cycle(key, {"min_duration": [0, 600, 1200, 1800, 3600], "min_rating": [0, 20, 40, 60, 80], "resolution": ["", "FOUR_K", "SIX_K", "EIGHT_K"]}[key])
	elif row.has("open_libraries"): _remember(); cancel(); view = "libraries"; menu._reset_navigation()
	elif row.has("refresh_server"): open_home()
	elif row.has("open_saved"): _remember(); cancel(); view = "saved"; menu._reset_navigation()
	elif row.has("edit_server"): cancel(); menu.account_panel.open("server", true)
	menu.refresh()

func _play(node: Dictionary, position: int) -> void:
	selection = node.duplicate(true); selection.start_ms = position
	menu.dismiss(); menu.chosen.emit(str(node.uri), str(node.get("title", "Video")))

func _is_favorite(node: Dictionary) -> bool:
	if capabilities.get("favorite_scope", "local") == "server": return bool(node.get("favorite", false))
	return favorites.get(str(server.get("id", "")), []).any(func(item): return str(item.id) == str(node.get("id", "")))

func _toggle_favorite() -> void:
	if detail.is_empty() or busy: return
	var selected := not _is_favorite(detail)
	if capabilities.get("favorite_scope", "local") == "server": request("favorite", {"scene_id": detail.id, "favorite": selected}); return
	var id := str(server.get("id", "")); var current: Array = favorites.get(id, []).duplicate(true)
	if selected:
		var item := {}
		for key in ["id", "uri", "title", "basename", "duration_ms", "width", "height", "year", "rating", "watched", "genres", "tags", "performers", "studios"]:
			if detail.has(key): item[key] = detail[key]
		current.append(item)
	else: current = current.filter(func(item): return str(item.id) != str(detail.id))
	var previous: Array = favorites.get(id, []).duplicate(true)
	favorites[id] = current.slice(0, 1000)
	if _save_favorites(): _favorite_changed(str(detail.id), selected)
	else: favorites[id] = previous

func _local_favorites_query() -> Array:
	var result: Array = favorites.get(str(server.get("id", "")), []).duplicate(true)
	result = result.filter(func(item):
		if not str(query.get("q", "")).is_empty() and not str(item.get("title", "")).containsn(str(query.q)): return false
		if int(item.get("duration_ms", 0)) < int(query.get("min_duration", 0)) * 1000 or int(item.get("rating", 0)) < int(query.get("min_rating", 0)): return false
		if query.has("watched") and (not item.has("watched") or bool(item.watched) != bool(query.watched)): return false
		for category in FILTER_NAMES:
			var ids: Array = item.get(category, []).map(func(facet): return str(facet.get("id", "")))
			var include: Array = query.get(category, []); var exclude_ids: Array = query.get("exclude_" + category, [])
			if not include.is_empty() and (not include.all(func(id): return id in ids) if category == "tags" and query.get("all_tags", true) else not include.any(func(id): return id in ids)): return false
			if exclude_ids.any(func(id): return id in ids): return false
		return true)
	var sort_key := str(query.get("sort", "created_at"))
	if sort_key == "title": result.sort_custom(func(a, b): return str(a.title).naturalnocasecmp_to(str(b.title)) < 0)
	elif sort_key in ["duration", "rating100", "date"]:
		var key: String = {"duration": "duration_ms", "rating100": "rating", "date": "year"}[sort_key]
		result.sort_custom(func(a, b): return int(a.get(key, 0)) > int(b.get(key, 0)))
	return result

func _favorite_changed(id: String, selected: bool) -> void:
	for item in entries:
		if str(item.get("id", "")) == id: item.favorite = selected
	for previous in history:
		for item in previous.entries:
			if str(item.get("id", "")) == id: item.favorite = selected
		if previous.query.get("favorites", false) and not selected:
			var before: int = previous.entries.size()
			previous.entries = previous.entries.filter(func(item): return str(item.get("id", "")) != id)
			previous.total = maxi(0, int(previous.total) - before + previous.entries.size())

func _save_favorites() -> bool:
	var config := ConfigFile.new()
	for id in favorites: config.set_value("favorites", str(id), favorites[id])
	DirAccess.make_dir_recursive_absolute("user://settings")
	if config.save("user://settings/server_favorites.cfg") != OK:
		menu.status = "Unable to save favorites"; return false
	return true

func _save_filters() -> void:
	var config := ConfigFile.new(); config.set_value("filters", "items", saved)
	DirAccess.make_dir_recursive_absolute("user://settings")
	if config.save("user://settings/server_filters.cfg") != OK: menu.status = "Unable to save filters"

func cycle(key: String, values: Array) -> void:
	var at: int = values.find(query.get(key, values[0])); var next: Variant = values[(at + 1) % values.size()]
	if next == values[0]: query.erase(key)
	else: query[key] = next

func set_filter(category: String, item: Dictionary, negative: bool) -> void:
	var key := ("exclude_" if negative else "") + category; var other := ("" if negative else "exclude_") + category
	var ids: Array = query.get(key, []).duplicate(); var id := str(item.id)
	if id in ids: ids.erase(id)
	else: ids.append(id)
	query[key] = ids; var opposite: Array = query.get(other, []).duplicate(); opposite.erase(id); query[other] = opposite
	labels[category + "/" + id] = str(item.name)

func get_candidates(append: bool = false) -> void:
	if not append: cancel(); candidates = []; candidate_page = 1; candidate_end = false; menu._reset_navigation()
	request("candidates", {"kind": kind, "q": candidate_q, "page": candidate_page + 1 if append else 1, "library_id": library_id})

func more() -> void:
	if busy: return
	if view == "scenes" and not end_reached and entries.size() < total:
		var next := query.duplicate(true); next.page = loaded_page + 1; request("browse", next)
	elif view in ["facets", "candidates"] and not candidate_end and candidates.size() < candidate_total: get_candidates(true)

func scroll_changed() -> void:
	if view not in ["scenes", "facets", "candidates"] or busy or menu._max_scroll() <= 0: return
	if menu.scroll >= menu._max_scroll() - 2.0: more()

func _navigate(section: String) -> void:
	history.clear(); labels.clear(); folder_path.clear(); keyboard = ""; candidate_q = ""
	query = {"page": 1, "q": "", "all_tags": true}
	if section == "home": open_home()
	elif section in FILTER_NAMES:
		cancel(); kind = section; view = "facets"; get_candidates(); menu.refresh()
	else:
		if section == "folders": query.mode = "folders"
		if section == "favorites":
			query.favorites = true
			if capabilities.get("favorite_scope", "local") != "server":
				cancel(); view = "scenes"; entries = favorites.get(str(server.id), []).duplicate(true); total = entries.size(); end_reached = true; menu._reset_navigation(); menu.refresh(); return
		browse()

func action(target: int) -> bool:
	if target < ACTION: return false
	if not keyboard.is_empty(): return _keyboard_action(target)
	if target >= ACTION + 200 and target < ACTION + 200 + chips.size():
		var chip: Dictionary = chips[target - ACTION - 200]
		if chip.key == "unclassified": query.erase("unclassified")
		else: var ids: Array = query.get(chip.key, []).duplicate(); ids.erase(chip.id); query[chip.key] = ids
		browse(); return true
	if target >= ACTION + 100 and target < ACTION + 100 + _navigation().size():
		_navigate(_navigation()[target - ACTION - 100]); return true
	match target - ACTION:
		0: back()
		1, 14: cancel(); menu.account_panel.open("server", target == ACTION + 14)
		2: _remember(); keyboard = "search"; text = candidate_q if view in ["candidates", "facets"] else str(query.get("q", ""))
		3: _remember(); cancel(); view = "filters"; menu._reset_navigation()
		4:
			var sorts: Array = capabilities.get("sorts", SORTS).duplicate();
			if query.get("favorites", false) and capabilities.get("favorite_scope", "local") != "server": sorts.erase("date")
			var at: int = sorts.find(str(query.get("sort", "created_at")))
			if not sorts.is_empty(): query.sort = sorts[(at + 1) % sorts.size()]; query.direction = "ASC" if query.sort == "title" else "DESC"; browse()
		6: more()
		7:
			if kind in capabilities.get("exclude_facets", []): exclude = not exclude
		8:
			if capabilities.get("tag_match_all", false): query.all_tags = not query.get("all_tags", true)
		9: keyboard = "save"; text = ""
		10: _remember(); cancel(); view = "saved"; menu._reset_navigation()
		11: browse()
		12:
			if busy: return true
			if view == "servers": load_servers()
			elif view == "home": open_home()
			elif view in ["facets", "candidates"]: get_candidates()
			elif loaded_page > 0 and entries.size() < total and not end_reached: more()
			else: browse()
		13: cancel(); view = "remove_servers"; menu._reset_navigation()
		15: _remember(); cancel(); view = "options"; menu._reset_navigation()
		17: _navigate("favorites")
		18:
			cancel(); menu.account_panel.close(); menu.account_panel.kind = "server"; menu.account_panel.start("server", str(server.get("provider", "")), str(server.get("id", "")))
	menu.refresh(); return true

func _keyboard_action(target: int) -> bool:
	if target >= KEY and target < KEY + 40:
		var layer: Array = menu.SYMBOLS if symbols else menu.KEYS; var character: String = layer[(target - KEY) / 10][(target - KEY) % 10]
		text = (text + (character.to_upper() if shift else character)).left(200); shift = false
	else:
		match target - ACTION:
			21: text = text.left(-1)
			22: text = (text + " ").left(200)
			23: shift = not shift
			24: symbols = not symbols
			25: keyboard = ""; if not history.is_empty(): history.pop_back()
			26:
				var purpose := keyboard; keyboard = ""
				if purpose == "save":
					if not text.strip_edges().is_empty():
						saved = saved.filter(func(item): return not (item is Dictionary and item.get("server_id") == server.get("id") and item.get("name") == text.strip_edges()))
						saved.append({"server_id": server.id, "name": text.strip_edges(), "query": query.duplicate(true), "labels": labels.duplicate(true)})
						if saved.size() > 100: saved.pop_front()
						_save_filters()
				elif view in ["candidates", "facets"]: candidate_q = text; get_candidates()
				else: query.q = text; query.erase("mode"); query.erase("parent_id"); folder_path.clear(); browse()
	menu.refresh(); return true

func _navigation() -> Array:
	return ["home", "all"] + capabilities.get("navigation", []).slice(0, 3)

func cover(row: Dictionary) -> Texture2D:
	var node: Dictionary = row.get("scene", row.get("container_node", {}))
	if node.is_empty() or not node.get("has_cover", true): return null
	var id := str(node.id); var key := str(server.get("id", "")) + "/" + id
	if textures.has(key): return textures[key]
	if covers.has(key):
		var image := Image.new()
		if image.load(str(covers[key])) == OK:
			var texture := ImageTexture.create_from_image(image)
			if textures.size() >= 24: textures.erase(textures.keys()[0])
			textures[key] = texture; return texture
		covers.erase(key)
	var active: Array = pending.values().filter(func(p): return p.action == "cover")
	if menu.visible and not failed_covers.has(id) and active.size() < 2 and not active.any(func(p): return p.scene_id == id): request("cover", {"scene_id": id})
	return null

func prioritize_covers() -> void:
	var visible_ids: Array[String] = []
	if view in ["scenes", "home"]:
		var first: int = menu._first_line() * menu._cols()
		for row in menu.rows.slice(first, first + menu._drawn_slots()):
			var node: Dictionary = row.get("scene", row.get("container_node", {}))
			if not node.is_empty(): visible_ids.append(str(node.id))
	elif view == "detail" and not detail.is_empty(): visible_ids.append(str(detail.id))
	for id in pending.keys():
		var req: Dictionary = pending[id]
		if req.action == "cover" and str(req.scene_id) not in visible_ids:
			if menu.platform: menu.platform.media_server_cancel(int(id))
			pending.erase(id)

func _fit_picture(picture: MeshInstance3D, texture: Texture2D, area: Vector2) -> void:
	var size := texture.get_size()
	if size.x > 0 and size.y > 0: picture.mesh.size = size * minf(area.x / size.x, area.y / size.y)

func tile(target: int, row: Dictionary, center: Vector2) -> void:
	menu._button(target, "", center, Vector2(0.30, 0.27), true, "", false, menu._list)
	var node: MeshInstance3D = menu._buttons.back().node
	var picture: MeshInstance3D = menu._quad(Vector2(0.278, 0.192), Vector3(0, 0.026, 0.003), menu.TILE, 12); node.add_child(picture)
	var texture := cover(row)
	if texture:
		var material = menu._material(Color.WHITE, 12); material.albedo_texture = texture; picture.material_override = material; _fit_picture(picture, texture, Vector2(0.278, 0.192))
	else: menu._icon(str(row.get("icon", "video")), Vector3(0, 0.026, 0.006), 0.064, menu.MUTED, node)
	menu._tips[target] = str(row.title)
	var title: Label3D = menu._label(menu._fit_title(str(row.title), "", 0.265, 22), Vector3(0, -0.087, 0.006), 22, node)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var meta: Label3D = menu._label(str(row.get("detail", "")), Vector3(0, -0.119, 0.006), 16, node); meta.modulate = menu.MUTED

func draw() -> void:
	if not keyboard.is_empty(): _draw_keyboard(); return
	prioritize_covers()
	menu._button(ACTION, "", Vector2(-0.52, 0.46), Vector2(0.09, 0.07), view != "servers", "up")
	var management := view in ["servers", "remove_servers", "confirm_remove"]
	var caption := I18n.t("Remove server") if view in ["remove_servers", "confirm_remove"] else str(server.get("name", I18n.t("Media servers")))
	var heading: Label3D = menu._label(menu._fit_title(caption, "", 0.77, 22), Vector3(-0.43, 0.46, 0.004), 22); heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	if view == "servers":
		for item in [[1, "plus"], [14, "edit"], [12, "refresh"], [13, "trash"]]: menu._button(ACTION + item[0], "", Vector2(0.43 + (0.12 * ([1, 14, 12, 13].find(item[0]))), 0.46), Vector2(0.09, 0.07), not busy or int(item[0]) in [1, 14], item[1])
	elif not management:
		if capabilities.get("search", true) or query.get("favorites", false) or view in ["facets", "candidates"]: menu._button(ACTION + 2, "", Vector2(0.55, 0.46), Vector2(0.09, 0.07), view != "filters", "search")
		menu._button(ACTION + 17, "", Vector2(0.67, 0.46), Vector2(0.09, 0.07), not busy and view != "filters", "heart"); menu._tips[ACTION + 17] = I18n.t("Favorites" if capabilities.get("favorite_scope", "local") == "server" else "On-device favorites")
		menu._button(ACTION + 15, "", Vector2(0.79, 0.46), Vector2(0.09, 0.07), view != "filters", "settings")
		var tabs := _navigation()
		for i in tabs.size():
			var name: String = {"home": "Home", "all": "All", "folders": "Folders"}.get(tabs[i], FILTER_NAMES.get(tabs[i], tabs[i]))
			menu._button(ACTION + 100 + i, I18n.t(name), Vector2(-0.37 + i * 0.263, 0.345), Vector2(0.25, 0.063), view != "filters")
			menu._lit((view == "home" and tabs[i] == "home") or (view == "scenes" and tabs[i] == ("folders" if query.get("mode", "") == "folders" else "all")) or (view == "facets" and tabs[i] == kind))
		_draw_context()
	chips = []
	for category in FILTER_NAMES:
		for prefix in ["", "exclude_"]:
			for id in query.get(prefix + category, []): chips.append({"key": prefix + category, "id": id, "label": ("− " if prefix != "" else "") + str(labels.get(category + "/" + id, id))})
	if query.has("unclassified"): chips.append({"key": "unclassified", "id": "", "label": I18n.t("Uncategorized")})
	if view == "scenes":
		menu._button(ACTION + 3, "", Vector2(0.79, 0.245), Vector2(0.08, 0.06), not busy, "settings")
		menu._button(ACTION + 4, "", Vector2(0.68, 0.245), Vector2(0.08, 0.06), not busy, "list")
		menu._tips[ACTION + 4] = I18n.t(SORT_NAMES[maxi(0, SORTS.find(str(query.get("sort", "created_at"))))])
		for i in mini(3, chips.size()): menu._button(ACTION + 200 + i, menu._fit_title(str(chips[i].label), "", 0.32, 14) + " ×", Vector2(-0.27 + i * 0.42, -0.435), Vector2(0.40, 0.055))
	if view == "candidates":
		if kind in capabilities.get("exclude_facets", []): menu._button(ACTION + 7, I18n.t("Exclude" if exclude else "Include"), Vector2(0.1, -0.44), Vector2(0.24, 0.065))
		if kind == "tags" and capabilities.get("tag_match_all", false): menu._button(ACTION + 8, I18n.t("Match all" if query.get("all_tags", true) else "Match any"), Vector2(0.40, -0.44), Vector2(0.30, 0.065))
	if view in ["scenes", "facets", "candidates"]:
		var count := candidate_total if view in ["facets", "candidates"] else total; var loaded := candidates.size() if view in ["facets", "candidates"] else entries.size()
		menu._label("%d / %d" % [loaded, count], Vector3(-0.36, -0.515, 0.004), 15)
		var has_more := not candidate_end if view in ["facets", "candidates"] else not end_reached
		if loaded < count and has_more: menu._button(ACTION + 6, I18n.t("More"), Vector2(0.73, -0.515), Vector2(0.18, 0.065), not busy)
		if view == "scenes": menu._button(ACTION + 9, "", Vector2(0.52, -0.515), Vector2(0.08, 0.065), not busy, "bookmark_add"); menu._tips[ACTION + 9] = I18n.t("Save search")
	elif view == "filters": menu._button(ACTION + 11, I18n.t("Apply"), Vector2(0.55, -0.345), Vector2(0.30, 0.065))
	if not menu.status.is_empty() and menu.status != "Server authentication required":
		menu._label(I18n.t(menu.status), Vector3(0.15, -0.57, 0.004), 15)
		if not busy: menu._button(ACTION + 12, "", Vector2(0.79, -0.565), Vector2(0.08, 0.06), true, "refresh")
	if menu.status == "Server authentication required" and not management:
		_draw_sign_in_required()
	elif view == "home": _draw_home()
	elif view == "filters": _draw_filters()
	elif view == "detail" and not detail.is_empty(): _draw_detail()
	else: menu._draw_rows()

func _draw_sign_in_required() -> void:
	menu._label(I18n.t("Server authentication required"), Vector3(0.16, 0.045, 0.009), 26)
	menu._button(ACTION + 18, I18n.t("Sign in again"), Vector2(0.16, -0.08), Vector2(0.46, 0.10), not busy, "", true)

func _draw_context() -> void:
	var context := ""
	for library in home_data.get("libraries", []):
		if str(library.id) == library_id: context = str(library.title)
	if view in ["facets", "candidates"]: context = I18n.t(FILTER_NAMES.get(kind, kind))
	elif view == "detail": context = str(detail.get("title", "…"))
	elif view == "filters": context = I18n.t("Filters")
	elif view == "saved": context = I18n.t("Saved searches")
	elif query.get("favorites", false): context = I18n.t("Favorites" if capabilities.get("favorite_scope", "local") == "server" else "On-device favorites")
	if not folder_path.is_empty(): context += " / " + " / ".join(folder_path.map(func(node): return str(node.title)))
	var label: Label3D = menu._label(menu._fit_title(context, "", 1.0, 15), Vector3(-0.48, 0.245, 0.004), 15); label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; label.modulate = menu.MUTED

func _draw_home() -> void:
	menu._list = Node3D.new(); menu.add_child(menu._list); menu._decorations.append(menu._list); menu._bar_thumb = null
	var resume := _resume_entries(); var row_offset := 0
	var latest_y := 0.11
	if not resume.is_empty():
		menu._label(I18n.t("Continue watching"), Vector3(-0.25, 0.195, 0.004), 21)
		var item: Dictionary = resume[0]; var row := _node_row(item)
		menu._button(menu.ROW_BASE, "", Vector2(0.16, 0.065), Vector2(1.24, 0.18), true, "", false, menu._list)
		var node: MeshInstance3D = menu._buttons.back().node
		var frame: MeshInstance3D = menu._quad(Vector2(0.18, 0.14), Vector3(-0.50, 0, 0.004), menu.TILE, 12); node.add_child(frame)
		var texture := cover(row)
		if texture: var material = menu._material(Color.WHITE, 12); material.albedo_texture = texture; frame.material_override = material; _fit_picture(frame, texture, Vector2(0.18, 0.14))
		else: menu._icon("video", Vector3(-0.5, 0, 0.005), 0.055, menu.MUTED, node)
		var title: Label3D = menu._label(menu._fit_title(str(item.get("title", "Video")), "", 0.70, 23), Vector3(-0.37, 0.041, 0.005), 23, node); title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var duration := int(item.get("duration_ms", 0)); var position := int(item.get("position_ms", 0))
		var caption: Label3D = menu._label(_time(position) + (" / " + _time(duration) if duration > 0 else ""), Vector3(-0.37, -0.008, 0.005), 17, node); caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; caption.modulate = menu.MUTED
		menu._icon("play", Vector3(0.51, 0.0, 0.006), 0.047, menu.ACCENT, node)
		if duration > 0: node.add_child(menu._quad(Vector2(0.68 * clampf(float(position) / duration, 0, 1), 0.008), Vector3(-0.37 + 0.34 * clampf(float(position) / duration, 0, 1), -0.05, 0.006), menu.ACCENT, 14))
		row_offset = 1; latest_y = -0.085
	menu._label(I18n.t("Recently added"), Vector3(-0.27, latest_y, 0.004), 21)
	menu._button(ACTION + 101, I18n.t("All") + " · " + str(total) + " ›", Vector2(0.64, latest_y), Vector2(0.34, 0.05))
	for i in mini(4, home_data.get("recent", []).size()): tile(menu.ROW_BASE + i + row_offset, menu.rows[i + row_offset], Vector2(-0.36 + i * 0.333, latest_y - 0.16))
	if menu.rows.is_empty() and not busy and menu.status.is_empty(): menu._label(I18n.t("No items"), Vector3(0.16, -0.05, 0.004), 18)

func _draw_filters() -> void:
	var background: MeshInstance3D = menu._decoration(Vector2(1.16, 0.68), Vector2(0.16, -0.03), menu.PANEL)
	background.position.z = -0.001
	background.material_override.render_priority = 9
	menu._list = Node3D.new(); menu.add_child(menu._list); menu._decorations.append(menu._list); menu._bar_thumb = null
	var first: int = menu._first_line()
	for i in range(first, mini(menu.rows.size(), first + menu._drawn_slots())):
		var row: Dictionary = menu.rows[i]; var k := i - first
		menu._button(menu.ROW_BASE + k, "", Vector2(0.16, list_top() - k * pitch()), Vector2(1.04, 0.088), true, "", false, menu._list)
		var node: MeshInstance3D = menu._buttons.back().node
		var caption: Label3D = menu._label(menu._fit_title(str(row.title), "", 0.88, 22), Vector3(-0.47, 0, 0.006), 22, node); caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		if not str(row.get("detail", "")).is_empty():
			var count: Label3D = menu._label(str(row.detail), Vector3(0.47, 0, 0.006), 17, node); count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; count.modulate = menu.MUTED
	_draw_bar(); menu._place_list()

func _draw_detail() -> void:
	var texture := cover({"scene": detail})
	var panel: MeshInstance3D = menu._decoration(Vector2(0.32, 0.38), Vector2(-0.30, -0.035), menu.TILE)
	if texture: var material = menu._material(Color.WHITE, 12); material.albedo_texture = texture; panel.material_override = material; _fit_picture(panel, texture, Vector2(0.32, 0.38))
	var description: Label3D = menu._label(str(detail.get("description", "")).left(100), Vector3(-0.3, -0.265, 0.004), 14)
	description.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY; description.width = 0.33 / description.pixel_size; description.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	menu._list = Node3D.new(); menu.add_child(menu._list); menu._decorations.append(menu._list); menu._bar_thumb = null
	var first: int = menu._first_line()
	for i in range(first, mini(menu.rows.size(), first + menu._drawn_slots())):
		var row: Dictionary = menu.rows[i]; var k := i - first
		menu._button(menu.ROW_BASE + k, menu._fit_title(str(row.title), "", 0.67, 18), Vector2(0.40, list_top() - k * pitch()), Vector2(0.73, 0.082), not busy, "", false, menu._list)
	_draw_bar(); menu._place_list()

func _draw_bar() -> void:
	if menu._max_scroll() > 0:
		var span := bar_span(); var x := 0.75 if view == "filters" else 0.835
		menu._button(menu.SCROLLBAR, "", Vector2(x, span.x - span.y * 0.5), Vector2(0.04, span.y))
		var thumb: float = span.y * visible_lines() / menu._line_count(); menu._bar_thumb = menu._decoration(Vector2(0.012, thumb), Vector2(x, span.x - thumb * 0.5), menu.MUTED)

func _draw_keyboard() -> void:
	menu._label(I18n.t("Save search" if keyboard == "save" else "Search"), Vector3(0.15, 0.46, 0.004), 23)
	menu._button(ACTION + 27, text.right(60) + "│", Vector2(0.15, 0.33), Vector2(1.24, 0.09))
	var layer: Array = menu.SYMBOLS if symbols else menu.KEYS
	for r in 4:
		for c in 10:
			var character: String = layer[r][c]; menu._button(KEY + r * 10 + c, character.to_upper() if shift else character, Vector2(-0.415 + c * 0.125, 0.16 - r * 0.12), Vector2(0.112, 0.1))
	for item in [[21, "⌫"], [22, "Space"], [23, "Shift"], [24, "#+="], [25, "Cancel"], [26, "Apply"]]: menu._button(ACTION + item[0], I18n.t(item[1]), Vector2(-0.4 + (item[0] - 21) * 0.22, -0.4), Vector2(0.21, 0.08))
