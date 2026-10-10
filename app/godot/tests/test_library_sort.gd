extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Actions := preload("res://scripts/library_file_actions.gd")
const Order := preload("res://scripts/library_order.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func titles(rows: Array) -> Array:
	return rows.map(func(row): return row.title)

func sorted_titles(rows: Array, order: String) -> Array:
	var sorted := rows.duplicate(true)
	sorted.sort_custom(func(a, b): return Order.before(a, b, order))
	return titles(sorted)

func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var rows := [{"title":"A10","container":{"id":"10"},"modified":100,"size":900},
		{"title":"Unknown","container":{"id":"unknown"}},
		{"title":"B","container":{"id":"b"},"modified":300,"size":100},
		{"title":"A2","container":{"id":"2"},"modified":100,"size":700},
		{"title":"New.mp4","uri":"file:///new.mp4","modified":999,"size":1},
		{"title":"Old.mp4","uri":"file:///old.mp4","modified":1,"size":2},
		{"title":"Unknown.mp4","uri":"file:///unknown.mp4"}]
	check(sorted_titles(rows, "modified_asc") == ["A2","A10","B","Unknown","Old.mp4","New.mp4","Unknown.mp4"], "Oldest sorts folder timestamps, natural ties and missing metadata within each group")
	check(sorted_titles(rows, "modified_desc") == ["B","A2","A10","Unknown","New.mp4","Old.mp4","Unknown.mp4"], "Newest keeps even undated folders before all files")
	for value in ["size_asc", "size_desc"]:
		check(sorted_titles(rows, value).slice(0,4) == ["A2","A10","B","Unknown"], "Size does not mistake folder metadata for recursive content size")
	check(sorted_titles(rows, "name_desc").slice(0,4) == ["Unknown","B","A10","A2"], "Descending names reverse folder names but preserve folder priority")
	var platform := preload("res://tests/test_library_file_actions.gd").Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.visible = true
	var saved_orders := {}
	menu.setting_changed.connect(func(key, value):
		if key == "library_orders": saved_orders.merge(value, true))
	var folders := [{"title":"A10","id":"/test/10","container":true,"modified":100},
		{"title":"B","id":"/test/b","container":true,"modified":300},
		{"title":"A2","id":"/test/2","container":true,"modified":100},
		{"title":"Unknown","id":"/test/unknown","container":true}]
	menu._local_stack = [{"id":"/test","title":"Local"}]; menu._local_entries = folders
	menu._smb_server = "nas"; menu._smb_path = "share/test"; menu._smb_entries = folders
	for section in [Menu.Section.LOCAL, Menu.Section.SMB]:
		menu.section = section; menu.refresh(); menu._activate(Actions.SORT)
		check(menu._buttons.any(func(button): return button.target == Actions.ORDER_BASE + 2 and button.enabled), "Folder-only directory enables modified sorting")
		check(not menu._buttons.any(func(button): return button.target == Actions.ORDER_BASE + 4 and button.enabled), "Folder-only directory keeps size sorting unavailable")
		menu._activate(Actions.ORDER_BASE + 2)
		check(titles(menu.rows) == ["B","A2","A10","Unknown"], "Actual directory rows retain folder metadata through newest sort")
		menu.file_actions.choose_order("modified_asc")
		check(titles(menu.rows) == ["A2","A10","B","Unknown"], "Actual directory oldest sort works with file management disabled")
	menu._smb_path = ""; menu.refresh()
	check(not menu._buttons.any(func(button): return button.target == Actions.SORT), "SMB share list remains outside file-directory sorting")
	menu.section = Menu.Section.CLOUD; menu._cloud_stack = [{"id":"/account","title":"Cloud"}]; menu._cloud_entries = folders
	menu.refresh(); menu._activate(Actions.SORT)
	check(menu._buttons.any(func(button): return button.target == Actions.ORDER_BASE + 2 and button.enabled), "Cloud folder-only metadata also enables modified sorting")
	menu._activate(Actions.ORDER_BASE + 2)
	check(platform.calls.back().order == "modified_desc", "Cloud uses whole-directory native time sort")
	platform.respond(platform.calls.size(), "ready", {"path":"/account","offset":0,"order":"modified_desc","entries":[folders[1],folders[2],folders[0],folders[3]],"next_offset":-1})
	check(titles(menu.rows) == ["B","A2","A10","Unknown"], "Cloud page preserves native global folder order")
	menu.file_actions.reset(); menu.section = Menu.Section.DLNA; menu._dlna_server = "uuid:test"
	menu._dlna_stack = []; menu._dlna_entries = [{"title":"Movie10","uri":"http://nas/10.mp4"},
		{"id":"10","title":"Folder10","container":true}, {"title":"Movie2","uri":"http://nas/2.mp4"},
		{"id":"2","title":"Folder2","container":true}]
	menu.file_actions.set_enabled(true); menu.refresh()
	check(titles(menu.rows) == ["Folder2","Folder10","Movie2","Movie10"], "DLNA server root defaults to natural names with folders first")
	check(menu._buttons.any(func(button): return button.target == Actions.SORT) and not menu._buttons.any(func(button): return button.target == Actions.EDIT_MODE), "DLNA gets sorting without file editing even after global management opt-in")
	menu._activate(Actions.SORT)
	var options := menu._buttons.filter(func(button): return button.target >= Actions.ORDER_BASE and button.target < Actions.ORDER_BASE + Order.ORDERS.size())
	check(options.size() == 2 and options.all(func(button): return button.enabled), "DLNA shows only two supported name options")
	menu._activate(Actions.ORDER_BASE + 1)
	check(titles(menu.rows) == ["Folder10","Folder2","Movie10","Movie2"], "DLNA descending names sort both groups")
	check(saved_orders.get(str(Menu.Section.DLNA)) == "name_desc" and saved_orders.get(str(Menu.Section.LOCAL)) == "modified_asc", "DLNA preference is saved independently from local sorting")
	menu.file_actions.choose_order("modified_desc")
	check(menu.file_actions.order() == "name_desc" and titles(menu.rows)[0] == "Folder10", "Unsupported DLNA order cannot change saved selection")
	menu._dlna_stack = [{"id":"nested","title":"Nested"}]; menu.refresh()
	check(titles(menu.rows)[0] == "Folder10", "DLNA nested containers inherit the saved name direction")
	menu.file_actions.load(saved_orders); menu.refresh()
	check(menu.file_actions.order() == "name_desc", "Reloaded settings restore the DLNA choice")
	menu.file_actions.load({str(Menu.Section.DLNA):"size_desc"}); menu.refresh()
	check(menu.file_actions.order() == "name_asc", "Invalid DLNA stored mode falls back to names")
	menu._dlna_server = ""; menu.refresh()
	check(not menu._buttons.any(func(button): return button.target == Actions.SORT), "DLNA server list has no directory sort entry")
	menu.section = Menu.Section.MEDIA_SERVER
	check(not menu.file_actions.sortable(), "Media server sorting remains isolated")
	menu.queue_free(); await process_frame; platform.free()
	print("library sort checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
