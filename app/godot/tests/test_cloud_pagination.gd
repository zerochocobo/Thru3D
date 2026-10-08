extends SceneTree

const Menu := preload("res://scripts/library_menu.gd")
var checks := 0
var failures: Array[String] = []

class JavaMethods extends Object:
	func has_java_method(method: String) -> bool:
		return method in ["media_cloud_page", "media_cloud_cancel"]

class Platform extends Object:
	signal media_list(id: int, payload: String)
	var requests: Array[Dictionary] = []
	var cancelled: Array[int] = []
	func media_cloud_page(path: String, offset: int, force: bool) -> int:
		requests.append({"path": path, "offset": offset, "force": force})
		return requests.size()
	func media_cloud_cancel(id: int) -> void:
		cancelled.append(id)
	func respond(id: int, total: int = 3001, error: bool = false, empty: bool = false) -> void:
		var request := requests[id - 1]
		var entries: Array = []
		if request.path == "":
			entries = [{"id": "/mount1", "title": "115", "container": true}]
		elif not empty:
			for i in range(request.offset, mini(request.offset + 48, total)):
				entries.append({"id": request.path + "/目录 %d" % i, "title": "目录 %d" % i, "container": true})
		media_list.emit(id, JSON.stringify({"state": "error" if error else "ready", "error": "Cloud connection failed",
			"path": request.path, "offset": request.offset, "entries": entries, "total": total, "page_size": 48,
			"next_offset": request.offset + 48 if request.offset + 48 < total and request.path != "" else -1}))

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func enabled(menu: Node, target: int) -> bool:
	for button in menu._buttons:
		if button.target == target: return button.enabled
	return false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var java := JavaMethods.new()
	check(not java.has_method("media_cloud_page") and Menu.PlatformMethods.supports(java, "media_cloud_page"), "Java-only methods use has_java_method, not Object.has_method")
	check(Menu.PlatformMethods.supports(java, "media_cloud_cancel") and not Menu.PlatformMethods.supports(java, "absent"), "Java cancellation and missing methods detected correctly")
	java.free()
	var platform := Platform.new()
	var menu := Menu.new()
	root.add_child(menu)
	menu.attach_platform(platform)
	menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.CLOUD)
	platform.respond(1)
	menu._choose(menu.rows[0])
	check(platform.requests.size() == 2 and platform.requests.back().offset == 0, "Opening directory requests only page one")
	platform.respond(2)
	check(menu.rows.size() == 48 and menu.text_snapshot().contains("1 / 63"), "First of 63 pages is visible")
	check(not enabled(menu, Menu.CLOUD_PREVIOUS) and enabled(menu, Menu.CLOUD_NEXT), "First page boundary")
	menu._set_scroll(menu._max_scroll())
	check(platform.requests.size() == 2, "Scrolling never fetches another page")
	menu._activate(Menu.CLOUD_NEXT)
	check(platform.requests.back().offset == 48 and menu.rows.size() == 48, "Next page is requested while current entries remain")
	check(not enabled(menu, Menu.CLOUD_NEXT), "No concurrent page requests")
	menu._activate(Menu.CLOUD_NEXT)
	check(platform.requests.size() == 3, "Repeated trigger is ignored while busy")
	platform.respond(3, 3001, true)
	check(menu.rows[0].title == "目录 0" and menu._cloud_page == 0 and enabled(menu, Menu.CLOUD_NEXT), "Failure preserves page and allows retry")
	menu._activate(Menu.CLOUD_NEXT)
	platform.respond(4)
	check(menu.rows.size() == 48 and menu.rows[0].title == "目录 48" and menu.scroll == 0.0, "Success replaces entries and resets scrolling")
	check(menu.text_snapshot().contains("2 / 63") and enabled(menu, Menu.CLOUD_PREVIOUS), "Numbered page two")
	menu._choose(menu.rows[0])
	platform.respond(5, 0)
	menu._go_back()
	check(platform.requests.back().path == "/mount1" and platform.requests.back().offset == 48, "Returning from child restores parent page")
	platform.respond(6)
	menu._activate(Menu.REFRESH)
	check(platform.requests.back().force and platform.requests.back().offset == 48, "Refresh bypasses cache for the current page")
	platform.respond(7)
	menu._activate(Menu.CLOUD_PREVIOUS)
	check(platform.requests.back().offset == 0, "Previous page uses recorded offset")
	platform.respond(8, 50)
	menu._activate(Menu.CLOUD_NEXT)
	platform.respond(9, 50)
	check(menu.rows.size() == 2 and menu.text_snapshot().contains("2 / 2") and not enabled(menu, Menu.CLOUD_NEXT), "Last page boundary and count")
	menu._activate(Menu.CLOUD_PREVIOUS)
	menu._go_back()
	check(platform.cancelled.has(10), "Navigating away cancels pending HTTP browse")
	platform.respond(10, 3001)
	check(menu._cloud_entries.is_empty(), "Cancelled response cannot populate a different directory")
	platform.respond(11)
	menu._choose(menu.rows[0])
	platform.respond(12, 10001, false, true)
	check(menu.rows.is_empty() and enabled(menu, Menu.CLOUD_NEXT), "Unsupported or filtered page can still turn forward")
	menu._activate(Menu.CLOUD_NEXT)
	var pending: int = platform.requests.size()
	menu.dismiss()
	check(platform.cancelled.has(pending) and not menu._cloud_busy, "Closing menu cancels loading")
	platform.respond(pending)
	check(menu._cloud_entries.is_empty(), "Dismissed result stays ignored")
	menu.toggle()
	menu._cloud_next = 96
	menu._turn_cloud_page(1)
	pending = platform.requests.size()
	var expected: Dictionary = platform.requests.back()
	platform.media_list.emit(pending, JSON.stringify({"state": "ready", "path": expected.path, "offset": 0, "entries": []}))
	check(menu.status == "Cloud connection failed" and not menu._cloud_busy, "Wrong-page response exits Loading immediately")
	check(menu.text_snapshot().contains("Cloud connection failed") and enabled(menu, Menu.CLOUD_NEXT), "Error and retry button redraw without any scrolling")
	menu._turn_cloud_page(1)
	platform.respond(platform.requests.size(), 10001)
	check(menu.status == "" and menu._cloud_page == menu._cloud_requested_page, "Retry commits the correct page")
	var probe := preload("res://scripts/cloud_page_probe.gd").new()
	root.add_child(probe)
	probe.start(platform)
	check(platform.requests.back().path == "" and platform.requests.back().offset == 48, "Device probe exercises second-page UI against local accounts only")
	platform.respond(platform.requests.size())
	check(probe.finished and probe.menu._cloud_page == 1, "Device probe observes committed page before completing")
	print("cloud pagination checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	menu.queue_free()
	platform.free()
	quit(0 if failures.is_empty() else 1)
