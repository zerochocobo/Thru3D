extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Actions := preload("res://scripts/library_file_actions.gd")
var checks := 0
var failures: Array[String] = []
class Platform extends Object:
	signal media_list(id: int, payload: String)
	var calls: Array[Dictionary] = []
	var management: Array[bool] = []
	func media_file_management_enabled(value: bool) -> void: management.append(value)
	func media_file_delete(json: String) -> int:
		calls.append({"operation": "delete", "target": JSON.parse_string(json)}); return calls.size()
	func media_file_delete_status(json: String) -> int:
		calls.append({"operation": "check", "target": JSON.parse_string(json)}); return calls.size()
	func media_file_delete_prepare(json: String) -> int:
		calls.append({"operation": "prepare", "target": JSON.parse_string(json)}); return calls.size()
	func media_file_rename_prepare(json: String) -> int:
		calls.append({"operation": "rename_prepare", "target": JSON.parse_string(json)}); return calls.size()
	func media_file_rename(json: String) -> int:
		calls.append({"operation": "rename", "target": JSON.parse_string(json)}); return calls.size()
	func media_cloud_sorted_page(path: String, offset: int, force: bool, order: String) -> int:
		calls.append({"operation": "sort", "path": path, "offset": offset, "force": force, "order": order}); return calls.size()
	func media_cloud_cancel(_id: int) -> void: pass
	func respond(id: int, state: String, values: Dictionary = {}) -> void:
		var request: Dictionary = calls[id - 1]
		var result := {"state": state, "uri": request.get("target", {}).get("uri", ""), "error": "File deletion permission denied"}
		result.merge(values, true); media_list.emit(id, JSON.stringify(result))

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var platform := Platform.new()
	var menu := Menu.new()
	root.add_child(menu); menu.attach_platform(platform)
	menu.section = Menu.Section.LOCAL
	menu._local_stack = [{"id": "/storage/test", "title": "Local"}]
	menu._local_entries = [{"title": "10.mp4", "uri": "file:///storage/test/10.mp4", "size": 10, "modified": 20, "can_delete": true},
		{"title": "2.mp4", "uri": "file:///storage/test/2.mp4", "size": 20, "modified": 10, "can_delete": true},
		{"title": "Folder", "id": "/storage/test/folder", "container": true},
		{"title": "ReadOnly.mp4", "uri": "file:///storage/test/ReadOnly.mp4", "size": 1, "modified": -1, "can_delete": false}]
	menu.visible = true; menu.refresh()
	check(not menu.file_actions.enabled and not menu._buttons.any(func(button): return button.target == Actions.EDIT_MODE), "Editing defaults off and entry is absent")
	check(platform.management == [false], "Plugin mutation gate starts disabled when attached")
	menu._activate(Actions.EDIT_MODE)
	check(not menu.file_actions.editing, "Disabled setting rejects edit action")
	menu.file_actions.set_enabled(true); menu.refresh()
	check(platform.management.back(), "Explicit opt-in enables the platform mutation gate")
	check(menu.rows[0].title == "Folder" and menu.rows[1].title == "2.mp4", "Folders first; numeric names natural")
	menu.file_actions.choose_order("name_desc")
	check(menu.rows[0].title == "Folder" and menu.rows.back().title == "2.mp4", "Folder priority survives descending")
	menu.file_actions.choose_order("modified_asc")
	check(menu.rows[1].title == "2.mp4" and menu.rows.back().title == "ReadOnly.mp4", "Unknown modification time stays last")
	menu.file_actions.choose_order("name_asc")
	var played: Array = []; var preparing: Array = []; var deleted: Array = []
	menu.chosen.connect(func(uri, _title): played.append(uri))
	menu.file_delete_preparing.connect(func(uri): preparing.append(uri))
	menu.file_deleted.connect(func(uri): deleted.append(uri))
	menu._activate(Actions.EDIT_MODE)
	menu._choose(menu.rows[0]); check(menu._local_stack.size() == 1, "Edit mode cannot enter folders")
	menu._choose(menu.rows[1]); check(played.is_empty() and menu.file_actions.selected.ends_with("2.mp4"), "Trigger selects without playback")
	menu._activate(Actions.DELETE_FILE)
	check(platform.calls.is_empty() and preparing.is_empty(), "Opening confirmation neither deletes nor stops playback")
	menu._activate(Menu.NAV_BASE + Menu.Section.SMB)
	check(menu.section == Menu.Section.LOCAL, "Modal blocks underlying navigation")
	menu._activate(Actions.CANCEL)
	check(menu._local_entries.size() == 4, "Cancel preserves file")
	menu._activate(Actions.DELETE_FILE); menu._activate(Actions.CONFIRM); menu._activate(Actions.CONFIRM)
	check(platform.calls.size() == 1 and preparing.size() == 1, "One confirmed delete; duplicate trigger ignored")
	check(menu._local_entries.size() == 4, "Pending delete retains row")
	platform.respond(1, "error")
	check(menu._local_entries.size() == 4 and deleted.is_empty(), "Permission failure retains row")
	menu._activate(Actions.CONFIRM)
	platform.respond(2, "uncertain")
	menu._activate(Actions.CONFIRM)
	check(platform.calls.size() == 2 and menu.file_actions.uncertain, "Ambiguous result cannot reissue delete")
	menu._activate(Actions.CHECK_STATUS)
	check(platform.calls.back().operation == "check", "Checking status only reads state")
	platform.respond(3, "ready", {"exists": false})
	check(menu._local_entries.size() == 3 and deleted.size() == 1, "Verified absence removes file and emits cleanup")
	menu._choose(menu.rows.back())
	menu._activate(Actions.DELETE_FILE)
	check(menu.file_actions.modal.is_empty() and platform.calls.size() == 3, "Read-only selection cannot delete")
	menu.file_actions.reset(); menu.section = Menu.Section.CLOUD
	menu._cloud_stack = [{"id": "/account", "title": "Cloud"}]
	menu._cloud_entries = [{"title": "Old.mp4", "uri": "cloud://account/Old.mp4", "size": 1}]
	menu._cloud_page = 2; menu._cloud_offsets.assign([0,48,96]); menu.refresh()
	menu.file_actions.choose_order("size_desc")
	check(platform.calls.back().offset == 0 and platform.calls.back().order == "size_desc", "Cloud sort resets to page one using directory sort endpoint")
	platform.respond(4, "error", {"path": "/account", "offset": 0, "order": "size_desc"})
	check(menu._cloud_page == 2 and menu._cloud_offsets == [0,48,96] and menu.rows[0].title == "Old.mp4", "Sort failure restores old pagination and content")
	menu.file_actions.choose_order("size_desc")
	platform.respond(5, "ready", {"path": "/account", "offset": 0, "order": "size_desc", "entries": [{"title": "New.mp4", "uri": "cloud://account/New.mp4"}], "next_offset": -1})
	check(menu._cloud_page == 0 and menu.rows[0].title == "New.mp4" and menu.file_actions.order() == "size_desc", "Successful sort commits preference and first page")
	menu.file_actions.reset(); menu.section = Menu.Section.LOCAL
	menu._local_entries = [{"id": "/storage/test/folder", "title": "folder", "container": true, "delete_uri": "file:///storage/test/folder", "can_delete": true}]
	menu.refresh(); menu._activate(Actions.EDIT_MODE); menu._choose(menu.rows[0]); menu._activate(Actions.DELETE_FILE)
	check(platform.calls.back().operation == "prepare" and preparing.size() == 2, "Folder confirmation first reads complete tree; does not stop playback")
	menu._activate(Actions.CONFIRM)
	check(platform.calls.size() == 6, "Cannot confirm folder before content plan arrives")
	platform.respond(6, "ready", {"preview": true, "plan": "tree-hash", "files": 3, "folders": 1})
	check(menu.file_actions.plan_ready and menu.text_snapshot().contains("3 files · 1 folders"), "Folder confirmation includes all content counts")
	menu._activate(Actions.CONFIRM)
	check(platform.calls.size() == 7 and platform.calls.back().target.plan == "tree-hash", "Confirmed folder uses inspected tree plan")
	platform.respond(7, "uncertain", {"partial": true, "error": "Some contents were deleted; check the folder"})
	check(menu._local_entries.size() == 1 and menu.status.contains("Some contents"), "Partial folder deletion retains folder and precise result")
	menu.file_actions.set_enabled(false); menu.refresh()
	check(not menu.file_actions.editing and menu.file_actions.modal.is_empty() and not menu._buttons.any(func(button): return button.target == Actions.EDIT_MODE), "Turning off editing removes entry and exits mode")
	check(not platform.management.back(), "Turning off management also closes the platform mutation gate")
	menu.file_actions.uncertain = false; menu.file_actions.set_enabled(true)
	menu._local_entries = [{"title":"old.mp4","uri":"file:///storage/test/old.mp4","size":10,"modified":1,"can_delete":true}]
	menu.refresh(); menu._activate(Actions.EDIT_MODE); menu._choose(menu.rows[0]); menu._activate(Actions.Rename.OPEN)
	menu.file_actions.rename.name = "new"; menu._activate(Actions.Rename.PREVIEW)
	check(platform.calls.back().operation == "rename_prepare" and preparing.size() == 3, "Rename preview does not mutate or stop playback")
	platform.respond(8, "ready", {"preview": true,"plan":"rename-hash","moves":[{"from":"old.mp4","to":"new.mp4"},{"from":"old.srt","to":"new.srt"}]})
	check(menu.file_actions.rename.phase == "preview" and menu.text_snapshot().contains("old.srt"), "Companion rename preview is visible before applying")
	var renamed: Array = []
	menu.file_renamed.connect(func(old, new, title): renamed.append([old,new,title]))
	menu._activate(Actions.Rename.APPLY); menu._activate(Actions.Rename.APPLY)
	check(platform.calls.size() == 9 and platform.calls.back().operation == "rename" and preparing.size() == 4, "Rename confirms exactly once and releases readers")
	platform.respond(9,"ready",{"renamed":true,"new_uri":"file:///storage/test/new.mp4","new_title":"new.mp4"})
	check(renamed.size() == 1 and menu.rows[0].uri.ends_with("new.mp4"), "Rename success updates browsing identity and emits migration")
	menu.file_actions.reset(); menu.section = Menu.Section.SETTINGS; menu.tab = Menu.GENERAL_TAB; menu.refresh()
	check(menu.rows.any(func(row): return row.get("key", "") == "file_editing" and row.title == "Allow file management"), "Global setting uses the requested file management label")
	menu.section = Menu.Section.CLOUD; menu._cloud_stack = [{"id":"/account","title":"Cloud"}]; menu.refresh()
	menu.file_actions.choose_order("source")
	check(platform.calls.back().operation == "sort" and platform.calls.back().order == "source", "Cloud source order is available without a sorted metadata snapshot")
	platform.respond(10,"ready",{"path":"/account","offset":0,"order":"source","entries":[],"next_offset":48,"total":20001})
	check(menu.file_actions.order() == "source" and menu._cloud_next == 48, "Source order keeps large directories browsable and commits its preference")

	menu.file_actions.reset(); menu._cloud_busy = false; menu._cloud_offsets.assign([0]); menu._cloud_page = 0
	menu._cloud_entries = [{"id":"/account/folder","title":"旅行","container":true,"delete_uri":"cloud://account/folder","cloud_id":"9007199254740993","delete_effect":"recycle","can_delete":true},
		{"title":"Cloud.mp4","uri":"cloud://account/Cloud.mp4","kind":"video","size":12,"modified":10,"cloud_id":"2","delete_effect":"recycle","can_delete":true}]
	menu.file_actions.set_enabled(false); menu.refresh(); menu._activate(Actions.EDIT_MODE)
	check(not menu.file_actions.editing and not menu._buttons.any(func(button): return button.target == Actions.EDIT_MODE), "Cloud edit entry also stays hidden with file management off")
	menu.file_actions.set_enabled(true); menu.refresh(); menu._activate(Actions.EDIT_MODE)
	menu._choose(menu.rows[1])
	check(not menu.file_actions.rename.can_rename(menu.file_actions.selected_row()), "Cloud deletion capability cannot accidentally enable cloud rename")
	menu._choose(menu.rows[0]); menu._activate(Actions.DELETE_FILE)
	check(platform.calls.back().operation == "prepare" and platform.calls.back().target.cloud_id == "9007199254740993", "Cloud folder keeps stable provider ID through selection and preview")
	platform.respond(11,"ready",{"preview":true,"plan":"cloud-tree","files":3,"folders":1})
	check(menu.text_snapshot().contains("cloud recycle bin") and not menu.text_snapshot().contains("Permanently"), "Cloud confirmation explains recycle-bin deletion")
	menu._activate(Actions.CONFIRM)
	check(platform.calls.back().target.plan == "cloud-tree" and platform.calls.back().target.delete_effect == "recycle", "Cloud folder confirms with its inspected plan and provider effect")
	platform.respond(12,"uncertain")
	menu._activate(Actions.CONFIRM)
	check(platform.calls.size() == 12, "Ambiguous cloud delete does not replay")
	menu._activate(Actions.CHECK_STATUS)
	platform.respond(13,"ready",{"exists":true,"changed":true})
	check(menu._cloud_entries.size() == 2 and not menu.file_actions.uncertain and menu.file_actions.target.is_empty(), "Replacement at deleted path clears stale confirmation and preserves replacement")
	menu.queue_free(); await process_frame; platform.free()
	print("library file actions checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
