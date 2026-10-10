extends Node
## Debug menu probe: read-only browsing, or explicit account UI authentication from a private one-shot input.
var menu: Node
var main: Node
var command := {}
var events: Array = []
var reauth_result := ""
func start(owner: Node, request: Dictionary) -> void:
	main = owner; menu = owner.recent_menu; command = request
	main.platform_plugin.connect("media_list", _observe)
	_run.call_deferred()
func _observe(_id: int, payload: String) -> void:
	var data: Variant = JSON.parse_string(payload)
	if data is Dictionary and data.get("source") == "medialib" and data.get("action") != "cover":
		events.append({"action": data.get("action", ""), "state": data.get("state", ""), "error": data.get("error", ""), "total": data.get("total", -1), "entries": data.get("entries", []).size(), "recent": data.get("recent", []).size(), "resume": data.get("resume", []).size(), "chars": payload.length()})
func _idle() -> void:
	for i in 100:
		if not menu.server_browser.busy: return
		await get_tree().create_timer(0.2).timeout
func _run() -> void:
	main._show_recent_menu(); menu.account_panel.close(); menu.section = menu.Section.MEDIA_SERVER
	var b: RefCounted = menu.server_browser
	var step := str(command.get("step", "snapshot"))
	if step in ["servers", "add", "delete"]:
		b.load_servers(); await _idle(); menu.refresh()
		if step == "add": b.action(b.ACTION + 1)
		elif step == "delete": b.action(b.ACTION + 13)
	elif step != "snapshot":
		var provider := str(command.get("provider", "emby"))
		if str(b.server.get("provider", "")) != provider:
			b.load_servers(); await _idle()
			var found: Array = b.servers.filter(func(item): return str(item.get("provider", "")) == provider)
			if not found.is_empty(): b.choose({"server_account": found[0]}); await _idle()
		if step == "reauth":
			await _reauth(provider)
		elif str(b.server.get("provider", "")) == provider:
			if step == "home": b.open_home()
			elif step in ["all", "genres", "tags", "folders"]: b._navigate(step)
			elif step == "scroll_end": menu._set_scroll(menu._max_scroll())
			elif step == "back": b.back()
			elif step == "retry": b.action(b.ACTION + 12)
			await _idle()
	menu.refresh(); await get_tree().process_frame
	var profiles: Array = b.servers.map(func(item): return {"provider": item.get("provider", ""), "has_capabilities": item.has("capabilities")})
	var ids := {}
	for entry in b.entries: ids[str(entry.get("id", ""))] = true
	var media_tabs: Array = menu._buttons.filter(func(button): return button.target >= b.ACTION + 100 and button.target < b.ACTION + 110)
	var report := {"request": command.get("request_key", ""), "step": step, "view": b.view, "account_view": menu.account_panel.view, "provider": b.server.get("provider", ""), "busy": b.busy, "status": menu.status, "total": b.total, "entries": b.entries.size(), "candidates": b.candidates.size(), "candidate_total": b.candidate_total, "rows": menu.rows.size(), "visible_lines": menu._lines(), "pitch": menu._pitch(), "scroll": menu.scroll, "library_selected": not b.library_id.is_empty(), "profiles": profiles, "events": events, "reauth_result": reauth_result, "server_base": b.server.get("base", ""), "account_http_status": menu.account_panel.data.get("result", {}).get("http_status", 0), "unique_entries": ids.size(), "media_tabs": media_tabs.size(), "row_providers": menu.rows.map(func(row): return row.get("detail", "")) if step == "delete" else [], "home_libraries": b.home_data.get("libraries", []).size(), "home_recent": b.home_data.get("recent", []).size(), "home_resume": b.home_data.get("resume", []).size(), "covers_cached": b.covers.size(), "end_reached": b.end_reached}
	DirAccess.make_dir_recursive_absolute("user://diagnostics")
	var file := FileAccess.open("user://diagnostics/media_server_ui_" + str(command.get("request_key", "probe")) + ".json", FileAccess.WRITE)
	if file: file.store_string(JSON.stringify(report)); file.close()
	main.platform_plugin.disconnect("media_list", _observe); queue_free()
func _reauth(provider: String) -> void:
	var path := "user://diagnostics/media_server_reauth_input.json"
	var input := FileAccess.open(path, FileAccess.READ)
	if not input: reauth_result = "No input"; return
	var credentials: Variant = JSON.parse_string(input.get_as_text()); input.close()
	DirAccess.remove_absolute(path)
	if not credentials is Dictionary: reauth_result = "Invalid input"; return
	var b: RefCounted = menu.server_browser
	var panel: RefCounted = menu.account_panel
	var account_id := str(b.server.get("id", ""))
	if account_id.is_empty() and str(credentials.get("base", "")).is_empty():
		reauth_result = "No account or address"; credentials.clear(); return
	panel.kind = "server"; panel.start("server", provider, account_id, {"base": credentials.get("base", ""), "name": credentials.get("name", provider.capitalize())})
	if account_id.is_empty():
		menu.platform.account_input(panel.session, "username", "replace", str(credentials.get("username", ""))); panel.poll()
	var configured := str(panel.data.get("fields", {}).get("username", ""))
	if configured != str(credentials.get("username", "")):
		reauth_result = "Configured account differs; input not submitted"; credentials.clear(); return
	menu.platform.account_input(panel.session, "password", "append", str(credentials.get("password", "")))
	credentials.clear(); panel.command("save_server")
	for i in 100:
		panel.poll()
		if not panel.active() or (not panel.data.get("busy", false) and not str(panel.data.get("error", "")).is_empty()): break
		await get_tree().create_timer(0.2).timeout
	reauth_result = "Saved through account UI" if not panel.active() else str(panel.data.get("error", "Incomplete"))
	if not panel.active():
		await _idle()
		var found: Array = b.servers.filter(func(item): return str(item.get("provider", "")) == provider)
		if not found.is_empty(): b.choose({"server_account": found[0]}); await _idle()
