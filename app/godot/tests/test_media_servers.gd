extends SceneTree

const Menu := preload("res://scripts/library_menu.gd")
const Browser := preload("res://scripts/media_server_browser.gd")
var checks := 0
var failures: Array[String] = []

class Platform extends Object:
	signal media_list(id: int, json: String)
	signal android_lifecycle(state: String)
	var next := 0
	var requests := {}
	var cancelled: Array = []
	var setups := 0
	func media_server_request(json: String) -> int:
		next += 1; requests[next] = JSON.parse_string(json); return next
	func media_server_cancel(id: int) -> void: cancelled.append(id)
	func media_server_accounts() -> void: setups += 1
	func accounts_changed() -> void:
		media_list.emit(0, JSON.stringify({"source": "medialib", "state": "accounts_changed"}))
	func answer(id: int, data: Dictionary) -> void:
		var req: Dictionary = requests[id]
		data.merge({"generation": req.generation, "server_id": req.server_id, "source": "medialib", "state": "ready"})
		media_list.emit(id, JSON.stringify(data))

func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var platform := Platform.new()
	var menu := Menu.new()
	root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.MEDIA_SERVER)
	var b: RefCounted = menu.server_browser
	platform.answer(platform.next, {"servers": [{"id": "srv", "name": "Stash", "base": "http://test"}]})
	check(menu.rows.size() == 1 and menu.rows[0].server_account.id == "srv", "server list")
	menu._choose(menu.rows[0])
	var first: int = platform.next
	check(platform.requests[first].action == "browse" and platform.requests[first].page == 1, "server query begins on page one")
	b.query.q = "new"; b.browse()
	var second: int = platform.next
	platform.answer(first, {"entries": [{"id": "9", "title": "stale"}], "total": 1})
	check(b.entries.is_empty() and first in platform.cancelled, "stale query discarded and cancelled")
	platform.answer(second, {"entries": [{"id": "1", "title": "Test", "uri": "medialib://srv/scene/1", "duration_ms": 62000}], "total": 100})
	check(menu.rows.size() == 1 and menu.rows[0].scene.id == "1", "scene results")
	check(b.total == 100 and menu._grid(), "server count and grid")
	b.set_filter("tags", {"id": "12", "name": "A"}, false)
	b.set_filter("tags", {"id": "34", "name": "B"}, true)
	check(b.query.tags == ["12"] and b.query.exclude_tags == ["34"], "include and exclude coexist")
	b.set_filter("tags", {"id": "12", "name": "A"}, true)
	check(b.query.tags.is_empty() and "12" in b.query.exclude_tags, "same tag cannot be both")
	menu.refresh()
	check(b.chips.size() == 2, "removable condition chips")
	b.action(Browser.ACTION + 200)
	check(b.query.exclude_tags.size() == 1 and b.query.page == 1, "chip removes filter and resets page")
	b.action(Browser.ACTION + 3)
	check(b.view == "filters" and not menu._grid(), "filter list layout")
	b.choose({"category": "tags"})
	var candidate_request: int = platform.next
	platform.answer(candidate_request, {"entries": [{"id": "7", "name": "Sample"}], "total": 1})
	check(b.view == "candidates" and menu.rows[0].candidate.id == "7", "candidate query")
	b.action(Browser.ACTION + 7); menu._choose(menu.rows[0])
	check("7" in b.query.exclude_tags, "exclude candidate")
	b.action(Browser.ACTION + 8)
	check(not b.query.all_tags, "ANY toggle")
	b.action(Browser.ACTION + 2)
	b.action(Browser.KEY + 10)
	check(b.text == "q" and not b.keyboard.is_empty(), "ray keyboard input")
	b.action(Browser.ACTION + 26)
	check(b.keyboard.is_empty() and platform.requests[platform.next].q == "q", "search submitted as data")
	b.choose({"toggle": "watched"}); check(b.query.watched, "watched yes")
	b.choose({"toggle": "watched"}); check(not b.query.watched, "watched no")
	b.choose({"toggle": "watched"}); check(not b.query.has("watched"), "watched all")
	b.choose({"scene": {"id": "1"}})
	platform.answer(platform.next, {"detail": {"id": "1", "title": "Scene", "uri": "medialib://srv/scene/1", "basename": "test_180_SBS.mp4", "tags": [], "performers": [], "markers": [{"title": "Start", "position_ms": 45000}]}})
	check(b.view == "detail" and menu.rows.size() == 2, "detail and marker rows")
	var selected: Array = []
	menu.chosen.connect(func(uri, title): selected.append([uri, title]))
	menu._choose(menu.rows[1])
	check(selected.size() == 1 and selected[0][0] == "medialib://srv/scene/1", "play stable identity")
	check(b.selection.start_ms == 45000 and b.selection.basename == "test_180_SBS.mp4", "marker and source filename preserved")
	check(not menu.visible and b.pending.is_empty(), "play closes UI and cancels prefetch")
	check(not preload("res://scripts/file_mode_memory.gd").key_for("medialib://srv/scene/1").is_empty(), "stable history identity accepted")
	menu.toggle(); b.action(Browser.ACTION + 1)
	check(platform.setups == 1, "native server setup")
	platform.android_lifecycle.emit("resume")
	check(b.view == "servers" and not b.setup, "native setup return refreshes accounts")
	menu._activate(Menu.NAV_BASE + Menu.Section.RECENT)
	check(b.pending.is_empty(), "leaving server cancels requests")
	check(Menu.NAV_ORDER.find(Menu.Section.MEDIA_SERVER) + 1 == Menu.NAV_ORDER.find(Menu.Section.SETTINGS), "servers immediately above settings")
	for provider in ["emby", "jellyfin"]:
		b.server = {"id": "test", "provider": provider}; b.view = "filters"
		var rows: Array = b.rows()
		check(rows.size() == 3 and rows.all(func(row): return not row.has("category")), provider + " only supported filters")
	b.server = {"id": "test", "provider": "xbvr"}; b.view = "filters"
	check(b.rows().size() == 5, "XBVR tag actor studio watched and reset")
	b.view = "servers"; b.servers = [{"id": "test", "name": "NAS", "provider": "jellyfin"}]
	check(b.rows()[0].detail == "Jellyfin", "provider badge")
	check(Menu.NAV_ICONS[Menu.Section.MEDIA_SERVER] not in [Menu.NAV_ICONS[Menu.Section.SMB], Menu.NAV_ICONS[Menu.Section.DLNA]], "distinct media library icon")
	b.cancel(); b.server = {"id": "srv", "provider": "stash"}; b.view = "scenes"; b.entries = []; b.failed_covers.clear()
	menu.section = Menu.Section.MEDIA_SERVER; menu.visible = true; menu._reset_navigation()
	for i in 48: b.entries.append({"id": str(i + 1), "title": "Scene %d" % i})
	menu.refresh()
	var old_covers: Array = b.pending.keys()
	check(old_covers.size() == 2, "bounded cover requests")
	menu._set_scroll(4.0)
	check(old_covers.all(func(id): return id in platform.cancelled), "scroll cancels offscreen covers")
	check(b.pending.values().all(func(req): return req.action == "cover" and int(req.scene_id) >= 17), "visible rows get priority")
	var failed_id: int = b.pending.keys()[0]
	platform.answer(failed_id, {"state": "error", "error": "Cover unavailable"})
	check(not b.failed_covers.is_empty(), "missing cover recorded")
	b.query.page = 2; b.action(Browser.ACTION + 12)
	check(b.failed_covers.is_empty() and platform.requests[platform.next].page == 2, "refresh retries failures without returning to page one")
	platform.answer(platform.next, {"entries": [{"id": "49", "title": "Page two"}], "total": 100})
	check(b.pending.values().any(func(req): return req.action == "cover" and req.scene_id == "49"), "page two requests its cover")
	b.cancel(); b.view = "servers"; b.servers = [{"id": "srv", "name": "Test"}]; b.action(Browser.ACTION + 13)
	check(b.view == "remove_servers", "visible remove server action")
	b.choose(b.rows()[0]); check(b.view == "confirm_remove", "deletion requires confirmation")
	b.choose(b.rows()[1]); check(b.view == "remove_servers", "cancel deletion")
	b.choose(b.rows()[0]); b.choose(b.rows()[0])
	check(platform.requests[platform.next].action == "remove" and platform.requests[platform.next].server_id == "srv", "delete correct server")
	var removing_request: int = platform.next
	platform.accounts_changed()
	check(b.pending.has(removing_request), "store notification preserves VR removal completion and cleanup")
	platform.answer(platform.next, {})
	check(b.view == "servers" and platform.requests[platform.next].action == "servers", "deletion refreshes server list")
	platform.answer(platform.next, {"servers": []})
	b.action(Browser.ACTION + 1)
	var before_save: int = platform.next
	platform.accounts_changed() # Saved in the native window, without an Android resume.
	check(platform.next == before_save + 1 and platform.requests[platform.next].action == "servers", "saving without resume reloads servers")
	var emby := {"id": "emby-new", "name": "Emby NAS", "provider": "emby"}
	platform.answer(platform.next, {"servers": [emby]})
	check(menu.rows.size() == 1 and menu.rows[0].server_account.id == "emby-new", "new Emby has a visible entry without reopening the menu")
	check(menu._buttons.any(func(button): return button.target == Browser.ACTION + 14 and button.enabled), "server edit is visible beside add and delete")
	var setups_before: int = platform.setups
	b.action(Browser.ACTION + 14)
	check(platform.setups == setups_before + 1 and b.setup, "explicit server edit opens account management")
	menu._choose(menu.rows[0])
	check(platform.requests[platform.next].action == "browse" and platform.requests[platform.next].server_id == "emby-new", "new Emby entry opens its library")
	b.action(Browser.ACTION + 1)
	platform.android_lifecycle.emit("resume") # Some window transitions resume before save.
	var before_change: int = platform.next
	platform.accounts_changed()
	check(before_change in platform.cancelled, "account change cancels a pre-save list request")
	platform.answer(before_change, {"servers": []})
	check(b.busy, "stale pre-save result cannot finish the replacement request")
	emby.name = "Renamed Emby"
	platform.answer(platform.next, {"servers": [emby]})
	check(menu.rows.size() == 1 and menu.rows[0].title == "Renamed Emby", "save after early resume still refreshes the entry")
	platform.accounts_changed()
	platform.answer(platform.next, {"servers": []})
	check(menu.rows.is_empty(), "native removal clears the old entry without resume")
	check(menu._buttons.any(func(button): return button.target == Browser.ACTION + 12), "empty server list offers a refresh button")
	b.action(Browser.ACTION + 12)
	check(platform.requests[platform.next].action == "servers" and b.view == "servers", "server refresh requests accounts rather than scenes")
	var refreshing: int = platform.next
	b.action(Browser.ACTION + 12)
	check(platform.next == refreshing, "busy server refresh cannot enqueue duplicates")
	platform.answer(refreshing, {"state": "error", "error": "Server unavailable"})
	b.action(Browser.ACTION + 12)
	check(platform.next == refreshing + 1, "failed list refresh can be retried")
	menu._activate(Menu.NAV_BASE + Menu.Section.RECENT)
	var outside: int = platform.next
	var outside_status: String = menu.status
	platform.accounts_changed()
	check(platform.next == outside and menu.section == Menu.Section.RECENT and menu.status == outside_status, "account notification leaves other sections alone")
	menu._activate(Menu.NAV_BASE + Menu.Section.MEDIA_SERVER)
	check(platform.requests[platform.next].action == "servers", "returning to servers reads the latest accounts")
	menu.free(); platform.free()
	for failure in failures: push_error(failure)
	print("media server checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
