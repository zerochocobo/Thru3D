extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Accounts := preload("res://scripts/account_panel.gd")
const Platform := preload("res://tests/test_media_servers.gd").Platform
var checks := 0
var failures: Array[String] = []
func check(value: bool, caption: String) -> void:
	checks += 1
	if not value: failures.append(caption)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var platform := Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle(); menu.section = Menu.Section.MEDIA_SERVER
	var panel: RefCounted = menu.account_panel
	panel.open("server")
	check(menu.rows.size() == 6 and menu.rows.any(func(row): return row.get("account_provider", "") == "plex"), "Plex appears alongside existing server providers")
	var choices: Array = menu._buttons.filter(func(button): return button.target >= Menu.ROW_BASE + 1 and button.target <= Menu.ROW_BASE + 5)
	check(choices.size() == 5 and choices.all(func(button): return button.rect.position.y > -0.3), "all five choices stay above network discovery")
	panel.start("server", "plex")
	check(panel.fields == ["name", "base"] and panel.field == "base", "Plex has an optional address and no password collection")
	check(menu._buttons.any(func(button): return button.target == Accounts.BASE + 27), "Plex offers official account authorization")
	panel.action(Accounts.BASE + 27)
	check(platform.account_calls.back()[1] == "plex_authorize", "authorization is requested from the native account session")
	var id: int = panel.session
	platform.account_sessions[id].merge({"state":"plex_link","result":{"code":"ABCD","link":"plex.tv/link"},"revision":2}, true)
	panel.poll(); menu.refresh()
	check(panel.view == "plex_link" and menu.text_snapshot().contains("ABCD") and menu.text_snapshot().contains("plex.tv/link"), "pairing shows official link and readable code")
	check(not menu._buttons.any(func(button): return button.target >= Accounts.KEY and button.target < Accounts.KEY + 40), "pairing hides the form keyboard")
	check(menu.text_snapshot().contains("Confirm pairing") and menu.text_snapshot().contains("Pair on phone or computer") and not menu.text_snapshot().contains("Sign in on website"), "Plex uses external device pairing with a confirmation button")
	panel.action(Accounts.BASE + 28)
	check(platform.account_calls.back()[1] == "plex_confirm", "confirmation asks native Plex to verify approval")
	platform.account_sessions[id].merge({"state":"plex_link","error":"Pairing not completed","revision":3}, true)
	panel.poll(); menu.refresh()
	check(panel.view == "plex_link" and menu.text_snapshot().contains("Pairing not completed"), "unapproved pairing keeps the code and offers retry")
	platform.account_sessions[id].merge({"busy":true,"error":"","revision":4}, true)
	panel.poll(); menu.refresh()
	check(menu._buttons.filter(func(button): return button.target in [Accounts.BASE + 27, Accounts.BASE + 28]).all(func(button): return not button.enabled) and menu.text_snapshot().contains("Checking…"), "checking disables duplicate confirmation and code refresh")
	platform.account_sessions[id].merge({"busy":false,"pairing_expired":true,"error":"Pairing code expired","revision":4}, true)
	panel.poll()
	check(not menu._buttons.filter(func(button): return button.target == Accounts.BASE + 28)[0].enabled and menu._buttons.filter(func(button): return button.target == Accounts.BASE + 27)[0].enabled, "expiry disables confirmation but allows a new code without a revision change")
	panel.action(Accounts.BASE + 27)
	check(platform.account_calls.back()[1] == "plex_authorize", "refresh requests a new pairing session")
	platform.account_sessions[id].merge({"state":"plex_servers","result":{"servers":[{"id":"one","name":"Home"},{"id":"two","name":"Remote"}]},"revision":3}, true)
	panel.poll(); menu.refresh()
	check(panel.view == "plex_servers" and menu.rows.size() == 2, "multiple authorized servers can be selected")
	panel.choose(menu.rows[1])
	check(platform.account_calls.back()[1] == "plex_select" and platform.account_calls.back()[2].server_id == "two", "selection identifies one server without credentials")
	panel.start("server", "plex", "existing")
	check(menu._buttons.any(func(button): return button.target == Accounts.BASE + 6), "existing Plex settings can be tested and saved without reauthorization")
	panel.close(); menu.free(); platform.free()
	for failure in failures: push_error(failure)
	print("Plex account checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
