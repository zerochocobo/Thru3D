extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
var checks := 0
var failures: Array[String] = []

class Platform extends "res://tests/account_platform_fixture.gd":
	signal media_list(id: int, payload: String)
	var next := 0
	var automatic := true
	var fail_save := false
	var replies := {}
	var calls: Array = []
	var saved: Array = []
	var servers: Array = [{"id": "uuid:remote", "name": "Remote NAS", "location": "http://10.2.0.5:8200/description.xml", "manual": true}]
	func _reply(call: String, payload: Dictionary) -> int:
		next += 1
		var id := next
		calls.append(call)
		replies[id] = payload
		if automatic: (func(): send(id)).call_deferred()
		return id
	func send(id: int) -> void:
		if not replies.has(id): return
		var payload: Dictionary = replies[id]; replies.erase(id)
		media_list.emit(id, JSON.stringify(payload))
	func media_dlna_servers() -> int:
		return _reply("servers", {"source": "dlna", "state": "ready", "servers": servers.duplicate(true)})
	func media_dlna_discover() -> int:
		return _reply("discover", {"source": "dlna", "state": "ready", "servers": servers.duplicate(true)})
	func media_dlna_save(payload: String) -> int:
		var entry: Dictionary = JSON.parse_string(payload)
		saved.append(entry.duplicate(true))
		if fail_save: return _reply("save", {"source": "dlna", "state": "error", "error": "Invalid DLNA address"})
		if not entry.has("location"): entry.location = "%s://%s:%s/description.xml" % [entry.scheme, entry.host, entry.port]
		entry.id = "uuid:remote"; entry.manual = true; entry.name = "PT server"
		servers = [entry]
		return _reply("save", {"source": "dlna", "state": "ready", "servers": servers.duplicate(true)})
	func media_dlna_remove(_id: String) -> int:
		servers = []
		return _reply("remove", {"source": "dlna", "state": "ready", "servers": []})
	func media_dlna_browse(server: String, object_id: String) -> int:
		return _reply("browse", {"source": "dlna", "state": "ready", "server_id": server, "object_id": object_id,
			"entries": [{"id": "1", "title": "Sample", "uri": "http://10.2.0.5:8200/media/sample.mp4", "container": false}]})

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func settle() -> void:
	await process_frame; await process_frame
func button(menu: Node, target: int) -> Dictionary:
	for value in menu._buttons:
		if value.target == target: return value
	return {}
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var menu := Menu.new(); var platform := Platform.new()
	root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.DLNA); await settle()
	check(menu.rows.size() == 1 and menu.rows[0].title == "Remote NAS", "Saved server loads without a UDP reply")
	check(not button(menu, Menu.ADD).is_empty(), "Server list has the manual add button")
	menu._activate(Menu.ADD)
	check(menu._editor_fields() == ["host", "port"] and menu._field == 0, "DLNA editor separates IP and port")
	check(menu.text_snapshot().contains("192.168.1.10") and button(menu, Menu.FIELD_BASE).node.get_children().any(func(node): return node is Label3D and node.text == "IP address") and button(menu, Menu.FIELD_BASE + 1).node.get_children().any(func(node): return node is Label3D and node.text == "Port"), "IP and port are explicitly labeled")
	check(not menu.text_snapshot().contains("Password") and not menu.text_snapshot().contains("description.xml") and not menu.text_snapshot().contains("Name"), "Editor omits credentials, name and description path")
	menu._activate(Menu.KEY_BASE)
	check(menu._editor.host == "1", "Ray keyboard enters the IP field")
	menu._activate(Menu.BACKSPACE); menu._editor.host = "10.2.0.5"
	menu._activate(Menu.FIELD_BASE + 1)
	check(menu._field == 1, "Port can be selected independently")
	menu._editor.port = ""; var before := platform.saved.size(); menu._activate(Menu.SAVE)
	check(platform.saved.size() == before and menu._field == 1, "Empty port keeps focus without sending a request")
	menu._editor.port = "8200"
	menu._activate(Menu.SAVE); await settle()
	check(platform.saved.size() == 1 and platform.saved[0].host == "10.2.0.5" and platform.saved[0].port == "8200", "Save sends IP and port separately")
	check(not platform.saved[0].has("password") and not platform.saved[0].has("user") and not platform.saved[0].has("name"), "Server name is read automatically")
	check(menu._editor.is_empty() and menu.rows[0].title == "PT server", "Successful save uses the server name")
	menu._activate(Menu.ROW_BASE); await settle()
	check(not button(menu, Menu.EDIT).is_empty(), "Saved server offers edit while browsing")
	menu._activate(Menu.EDIT)
	check(menu._editor.host == "10.2.0.5" and menu._editor.port == "8200" and menu._editor.id == "uuid:remote", "Edit restores IP, port and identity")
	platform.fail_save = true; menu._editor.host = "bad address"
	menu._activate(Menu.SAVE); await settle()
	check(not menu._editor.is_empty() and menu._editor.host == "bad address", "Failed save keeps input for correction")
	check(menu.text_snapshot().contains("Invalid DLNA address"), "Connection errors appear in the editor")
	platform.fail_save = false; platform.automatic = false
	menu._editor.host = "10.2.0.6"; menu._activate(Menu.SAVE)
	var request := platform.next
	check(menu._editor_busy(), "Connection validation leaves editor busy")
	menu._activate(Menu.SAVE)
	check(platform.next == request, "Busy editor ignores duplicate saves")
	menu._activate(Menu.CANCEL); menu._activate(Menu.ADD)
	menu._editor.host = "10.3.0.7"
	platform.send(request); await settle()
	check(menu._editor.host == "10.3.0.7", "Late save response cannot close a new editor")
	menu._activate(Menu.CANCEL); platform.automatic = true
	menu._dlna_server = ""; menu._load_section(); await settle()
	menu._activate(Menu.ROW_BASE); await settle(); menu._activate(Menu.EDIT)
	menu._activate(Menu.DELETE); await settle()
	check(menu._editor.is_empty() and menu._dlna_server.is_empty() and menu.rows.is_empty(), "Delete returns to the empty server list")
	check(not button(menu, Menu.ADD).is_empty(), "Manual add remains reachable with no discovered servers")
	platform.servers = [{"id": "auto", "name": "Auto", "manual": false}]
	menu._load_section(); await settle(); menu._activate(Menu.ROW_BASE); await settle()
	check(button(menu, Menu.EDIT).is_empty(), "Unpersisted discovery has no misleading edit action")
	menu._dlna_entries = []
	menu._request("dlna_browse", 999)
	menu._on_media_list(999, JSON.stringify({"state": "ready", "server_id": "auto", "object_id": "old-folder", "entries": [{"title": "Stale"}]}))
	check(menu._dlna_entries.is_empty(), "Stale container reply cannot replace current folder")
	platform.automatic = false; menu._dlna_server = ""; menu._load_section()
	request = platform.next
	menu._activate(Menu.NAV_BASE + Menu.Section.RECENT)
	platform.send(request); await settle()
	check(menu.status.is_empty() and menu.section == Menu.Section.RECENT, "DLNA response does not alter another section")
	menu.section = Menu.Section.DLNA; platform.automatic = true
	menu._open_editor({"id": "proxy", "location": "https://nas.example/custom/device.xml?token=public"})
	check(menu._editor.host == "nas.example" and menu._editor.port == "443" and not menu.text_snapshot().contains("device.xml"), "Edit presents only IP/host and port for custom endpoints")
	menu._activate(Menu.SAVE); await settle()
	check(platform.saved.back().location == "https://nas.example/custom/device.xml?token=public", "Saving an unchanged address preserves a custom endpoint")
	menu._open_editor({"id": "proxy", "location": "https://nas.example/custom/device.xml"}); menu._editor.port = "8443"
	menu._activate(Menu.SAVE); await settle()
	check(platform.saved.back().scheme == "https" and platform.saved.back().port == "8443" and not platform.saved.back().has("location"), "Changing port preserves HTTPS and reruns description lookup")
	menu._open_editor({"id": "ipv6", "location": "http://[2001:db8::1]:8200/description.xml"})
	check(menu._editor.host == "2001:db8::1" and menu._editor.port == "8200", "IPv6 host and port split correctly")
	menu.free(); platform.free()
	print("DLNA menu checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
