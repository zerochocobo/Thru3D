extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Actions := preload("res://scripts/cloud_account_actions.gd")
var failures: Array[String] = []
var checks := 0

class Platform extends "res://tests/account_platform_fixture.gd":
	signal media_list(id: int, payload: String)
	signal android_lifecycle(state: String)
	var requests: Array[Dictionary] = []
	var cancelled: Array[int] = []
	var setups := 0
	func media_cloud_page(path: String, offset: int, force: bool) -> int:
		requests.append({"action": "browse", "path": path, "offset": offset}); return requests.size()
	func media_cloud_cancel(id: int) -> void: cancelled.append(id)
	func media_cloud_remove(id: String) -> int:
		requests.append({"action": "remove", "account_id": id}); return requests.size()
	func answer(entries: Array) -> void:
		var req: Dictionary = requests.back()
		media_list.emit(requests.size(), JSON.stringify({"state": "ready", "path": req.path, "offset": req.offset, "entries": entries}))
	func changed() -> void: media_list.emit(0, '{"source":"cloud","state":"accounts_changed"}')

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var platform := Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	var a: RefCounted = menu.cloud_accounts
	menu._activate(Menu.NAV_BASE + Menu.Section.CLOUD)
	var mounts := [{"id": "/first", "title": "115 home", "container": true}, {"id": "/second", "title": "Baidu", "container": true}]
	platform.answer(mounts)
	check(menu._buttons.any(func(b): return b.target == Actions.EDIT and b.enabled), "cloud edit is visible")
	check(menu._buttons.any(func(b): return b.target == Actions.REMOVE and b.enabled), "cloud remove is visible")
	menu._activate(Actions.EDIT)
	check(menu.account_panel.view == "accounts" and not menu._cloud_setup, "edit opens in-app account management")
	menu.account_panel.close()
	platform.changed()
	mounts[0].title = "Renamed"
	platform.answer(mounts)
	check(menu.rows[0].title == "Renamed" and not menu._cloud_setup, "rename refreshes without resume")
	menu._choose(menu.rows[0])
	platform.answer([{ "id": "/first/folder", "title": "Folder", "container": true }])
	menu._cloud_stack.append({"id": "/first/long/folder", "title": "A very long nested folder name"})
	menu._cloud_stack.append({"id": "/first/long/folder/child", "title": "Another very long nested folder name"})
	menu.refresh()
	var edit_rect: Rect2 = menu._buttons.filter(func(b): return b.target == Actions.EDIT)[0].rect
	check(menu._buttons.filter(func(b): return b.target >= Menu.CRUMB_BASE and b.target < Menu.CRUMB_BASE + 10).all(func(b): return b.rect.end.x < edit_rect.position.x), "nested breadcrumbs leave room for edit and delete")
	menu._activate(Actions.REMOVE)
	check(platform.requests.back().path == "" and menu._cloud_stack.is_empty(), "remove inside a directory returns to account selection")
	platform.answer(mounts)
	check(not menu._grid() and menu.rows.size() == 2 and menu.rows[0].has("cloud_remove"), "deletion selects an account rather than a remote folder")
	var count: int = platform.requests.size()
	menu._choose(menu.rows[1])
	check(a.mode == "confirm" and platform.requests.size() == count, "choosing an account requires confirmation")
	check(menu.rows[0].title.contains("Baidu"), "confirmation identifies the chosen account")
	menu._choose(menu.rows[1])
	check(a.mode == "remove" and platform.requests.size() == count, "cancel leaves account intact")
	menu._choose(menu.rows[1]); menu._choose(menu.rows[0])
	check(platform.requests.back().action == "remove" and platform.requests.back().account_id == "second", "confirmation removes only the selected account ID")
	var deletion: int = platform.requests.size()
	menu._choose(menu.rows[0])
	check(platform.requests.size() == deletion, "repeated confirmation cannot duplicate deletion")
	platform.media_list.emit(deletion, '{"state":"error","error":"Cloud connection failed"}')
	check(a.request_id == 0 and a.mode == "confirm" and menu.status == "Cloud connection failed", "failed delete preserves confirmation for retry")
	menu._choose(menu.rows[0]); deletion = platform.requests.size()
	platform.changed()
	var reload: int = platform.requests.size()
	platform.media_list.emit(deletion, '{"state":"ready"}')
	check(platform.requests.size() == reload and a.request_id == 0, "notification and delete response reload only once")
	platform.answer([mounts[0]])
	check(menu.rows.size() == 1 and menu.rows[0].title == "Renamed" and a.mode.is_empty(), "removed account disappears from browsing")
	menu._choose(menu.rows[0])
	var old_browse: int = platform.requests.size()
	menu._cloud_positions["/first"] = {"page": 2, "offsets": [0,48,96]}
	platform.changed()
	check(old_browse in platform.cancelled and menu._cloud_positions.is_empty(), "account change cancels old directory and clears saved pages")
	platform.media_list.emit(old_browse, '{"state":"ready","path":"/first","entries":[{"id":"/first/stale","title":"stale","container":true}]}')
	check(menu.rows.is_empty(), "old directory result cannot restore removed account data")
	platform.answer([])
	check(not menu._buttons.any(func(b): return b.target == Actions.REMOVE and b.enabled), "empty account list disables delete")
	menu._activate(Actions.EDIT)
	menu._activate(Menu.NAV_BASE + Menu.Section.RECENT)
	count = platform.requests.size()
	var status: String = menu.status
	platform.android_lifecycle.emit("resume"); platform.changed()
	check(menu.section == Menu.Section.RECENT and platform.requests.size() == count and menu.status == status, "late lifecycle and account notifications leave other sections alone")
	menu.free(); platform.free()
	print("cloud accounts checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
