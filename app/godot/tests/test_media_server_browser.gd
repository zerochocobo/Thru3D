extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_media_servers.gd")
const Browser := preload("res://scripts/media_server_browser.gd")
var checks := 0
var failures: Array[String] = []
const CAPS := {"navigation": ["genres", "tags", "folders"], "facets": ["genres", "tags", "performers", "studios"], "filters": ["watched", "min_rating"], "sorts": ["created_at", "title"], "favorite_scope": "server", "search": true, "unclassified": ["genres", "tags"]}
func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)
func _initialize() -> void: call_deferred("_run")
func page(start: int, count: int) -> Array:
	var result: Array = []
	for i in range(start, start + count): result.append({"id": str(i), "title": "Film %d" % i, "uri": "medialib://profile/scene/%d" % i, "duration_ms": 60000, "has_cover": false})
	return result
func request_id(browser: RefCounted, action_name: String) -> int:
	for id in browser.pending:
		if browser.pending[id].action == action_name: return int(id)
	return -1
func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var platform := Fixture.Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.MEDIA_SERVER)
	var b: RefCounted = menu.server_browser
	platform.answer(request_id(b, "servers"), {"servers": [{"id": "profile", "name": "NAS", "provider": "unknown"}]})
	menu._choose(menu.rows[0])
	check(platform.requests[request_id(b, "home")].action == "home", "server opens home")
	platform.answer(request_id(b, "home"), {"capabilities": CAPS, "total": 250, "library_id": "lib1", "libraries": [{"id": "lib1", "title": "Movies"}], "recent": page(1, 4), "resume": page(5, 1)})
	check(b.view == "home" and menu.rows.size() == 5, "home combines one resume with four recent")
	check(b.library_id == "lib1", "single library auto-selected")
	check(b._navigation() == ["home", "all", "genres", "tags", "folders"], "capabilities generate navigation without provider checks")
	check(menu._max_scroll() == 0, "home does not paginate card rows")
	b._navigate("all")
	platform.answer(request_id(b, "browse"), {"entries": page(1, 48), "total": 250})
	check(b.entries.size() == 48 and b.loaded_page == 1, "initial batch")
	for number in range(2, 7):
		b.more(); var id := request_id(b, "browse"); var before: int = platform.next; b.more()
		check(platform.next == before, "busy append cannot duplicate request")
		check(platform.requests[id].page == number and platform.requests[id].library_id == "lib1", "append scope and offset")
		platform.answer(id, {"entries": page((number - 1) * 48 + 1, 10 if number == 6 else 48), "total": 250})
	check(b.entries.size() == 250 and b.total == 250 and b.end_reached, "250 items reachable without page controls")
	var last: int = platform.next; b.more(); check(platform.next == last, "no seventh empty page")
	menu._set_scroll(20); var before_detail: float = menu.scroll
	b.choose({"scene": b.entries[85]})
	platform.answer(request_id(b, "detail"), {"detail": b.entries[85].merged({"tags": [{"id": "a", "name": "Tag A"}], "genres": [], "markers": []})})
	check(b.view == "detail" and menu.rows.any(func(row): return row.has("detail_filter")), "detail has clickable facets")
	var detail_tag: Dictionary = menu.rows.filter(func(row): return row.has("detail_filter"))[0]
	menu._choose(detail_tag); var tag_request := request_id(b, "browse")
	check(b.view == "scenes" and platform.requests[tag_request].tags == ["a"], "detail tag opens corresponding video query")
	platform.answer(tag_request, {"entries": page(1, 2), "total": 2})
	check(b.entries.size() == 2 and b.total == 2, "detail tag displays matching videos")
	b.back(); check(b.view == "detail" and b.detail.id == "86", "tag results return to original video detail")
	b.back()
	check(b.view == "scenes" and b.entries.size() == 250 and is_equal_approx(menu.scroll, before_detail), "detail back restores loaded list and scroll")
	b._navigate("folders")
	platform.answer(request_id(b, "browse"), {"entries": [{"id": "folder1", "title": "Folder", "container": true, "has_cover": false}, page(1, 1)[0]], "total": 2})
	check(menu.rows[0].has("container_node") and not menu.rows[0].has("scene"), "container is distinct from playable media")
	check(menu.video_queue().size() == 1, "containers never enter video queue")
	menu._choose(menu.rows[0]); var child := request_id(b, "browse")
	check(platform.requests[child].parent_id == "folder1" and platform.requests[child].mode == "folders", "child query uses normalized container ID")
	platform.answer(child, {"entries": page(10, 2), "total": 2}); b.back()
	check(b.entries.size() == 2 and b.folder_path.is_empty(), "container back restores parent")
	b._navigate("genres"); platform.answer(request_id(b, "candidates"), {"entries": [{"id": "Drama", "name": "Drama"}], "total": 1})
	check(menu.rows[0].has("unclassified"), "unclassified entry remains accessible")
	menu._choose(menu.rows[1]); var facet := request_id(b, "browse")
	check(platform.requests[facet].genres == ["Drama"], "facet navigation translates to common query")
	platform.answer(facet, {"entries": page(1, 2), "total": 2}); b.back()
	check(b.view == "facets" and b.candidates.size() == 1, "facet back restores categories")
	menu._choose(menu.rows[0]); check(platform.requests[request_id(b, "browse")].unclassified == "genres", "unclassified query")
	var stale := request_id(b, "browse"); b._navigate("all")
	platform.answer(stale, {"entries": page(250, 1), "total": 1})
	check(b.entries.is_empty(), "stale branch query cannot replace new view")
	platform.answer(request_id(b, "browse"), {"entries": page(1, 48), "total": 250})
	menu._set_scroll(menu._max_scroll())
	check(request_id(b, "browse") > 0, "scroll near end requests next batch")
	var append := request_id(b, "browse")
	platform.answer(append, {"state": "error", "error": "Server unavailable"})
	check(b.entries.size() == 48 and not b.busy, "append failure keeps already loaded media")
	b.action(Browser.ACTION + 12); check(platform.requests[request_id(b, "browse")].page == 2, "retry does not skip failed batch")
	platform.answer(request_id(b, "browse"), {"entries": page(49, 48), "total": 250})
	check(b.entries.size() == 96, "retry appends correct batch")
	b.choose({"scene": b.entries[0]}); platform.answer(request_id(b, "detail"), {"detail": b.entries[0].merged({"favorite": false, "markers": []})})
	b.choose({"favorite": true}); var favorite := request_id(b, "favorite")
	check(platform.requests[favorite].favorite, "server favorite mutation is explicit")
	platform.answer(favorite, {"scene_id": "1", "favorite": true}); check(b.detail.favorite, "favorite reflects confirmed response")
	b._navigate("favorites"); check(platform.requests[request_id(b, "browse")].favorites, "server favorite navigation")
	platform.answer(request_id(b, "browse"), {"entries": [], "total": 0})
	check(b.entries.is_empty() and b.end_reached, "empty favorites do not keep loading")
	b.capabilities = {"navigation": ["tags"], "facets": ["tags"], "filters": ["watched"], "favorite_scope": "local", "search": false, "sorts": ["created_at"]}
	check(not b._navigation().has("folders") and not b._navigation().has("genres"), "unavailable features absent")
	b.favorites["profile"] = []
	b.detail = page(1, 1)[0]
	b.choose({"favorite": true})
	check(b._is_favorite(b.detail), "local favorite can be added")
	var restored: RefCounted = Browser.new(menu); restored.server = b.server; restored.capabilities = b.capabilities
	check(restored._is_favorite(b.detail), "local favorite survives browser recreation")
	b._navigate("favorites"); check(b.entries.size() == 1, "local favorites list")
	b.query.q = "missing"; b.browse(); check(b.entries.is_empty(), "local favorite search stays local")
	b.query.q = ""; b.browse(); b.choose({"scene": b.entries[0]})
	platform.answer(request_id(b, "detail"), {"detail": page(1, 1)[0]})
	b.choose({"favorite": true}); b.back(); check(b.entries.is_empty(), "removing local favorite updates restored list")

	menu.free(); platform.free()
	for failure in failures: push_error(failure)
	print("common server browser checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
