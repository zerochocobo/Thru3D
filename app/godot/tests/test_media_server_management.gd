extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_media_servers.gd")
const Browser := preload("res://scripts/media_server_browser.gd")
const Accounts := preload("res://scripts/account_panel.gd")
var checks := 0
var failures: Array[String] = []
func check(value: bool, caption: String) -> void:
	checks += 1
	if not value: failures.append(caption)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var platform := Fixture.Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle(); menu.section = Menu.Section.MEDIA_SERVER
	var b: RefCounted = menu.server_browser
	b.server = {"id":"profile", "provider":"emby", "name":"NAS"}; b.view = "home"
	b.capabilities = {"navigation":["genres","tags","folders"], "facets":["genres","tags"], "filters":["watched"], "search":true}
	menu.account_panel.open("server")
	check(is_equal_approx(menu._pitch(), menu.ROW_PITCH) and menu._lines() == menu.VISIBLE_ROWS, "account views use account list geometry, not home-grid spacing")
	var choices: Array = menu._buttons.filter(func(button): return button.target >= Menu.ROW_BASE + 1 and button.target <= Menu.ROW_BASE + 5)
	check(choices.size() == 5 and choices.all(func(button): return button.enabled and button.node.visible), "five server choices fit without scrolling")
	check(choices[0].rect.position.x != choices[1].rect.position.x and is_equal_approx(choices[0].rect.position.y, choices[1].rect.position.y), "server choices use two compact columns")
	check(choices[0].rect.position.y - choices[2].rect.position.y < 0.30, "chooser rows are not sparse")
	check(not menu._buttons.any(func(button): return button.target >= Browser.ACTION + 100 and button.target < Browser.ACTION + 110), "chooser has no media navigation")
	menu.account_panel.close(); b.server = {}; b.view = "remove_servers"; b.servers = [{"id":"emby", "name":"Same name", "provider":"emby", "base":"http://nas:8096"}, {"id":"jellyfin", "name":"Same name", "provider":"jellyfin", "base":"http://nas:8097"}]; menu.refresh()
	check(menu.rows.size() == 2 and menu.rows[0].detail == "Emby" and menu.rows[1].detail == "Jellyfin", "deletion rows distinguish same-name server types")
	check(not menu._buttons.any(func(button): return button.target >= Browser.ACTION + 100 and button.target < Browser.ACTION + 110), "deletion has no irrelevant media tabs")
	b.choose(menu.rows[0]); check(b.view == "confirm_remove" and b.rows()[0].detail == "Emby", "confirmation keeps server type")
	check(not menu._buttons.any(func(button): return button.target >= Browser.ACTION + 100 and button.target < Browser.ACTION + 110), "confirmation has no irrelevant media tabs")
	b.removing = {}; b.view = "home"; b.server = {"id":"profile", "provider":"emby", "name":"NAS"}; b.home_data = {}; menu.status = "Server authentication required"; menu.refresh()
	check(menu._buttons.any(func(button): return button.target == Browser.ACTION + 18 and button.enabled), "authentication failure offers a prominent login action")
	check(menu.text_snapshot().contains("Server authentication required") and menu.text_snapshot().contains("Sign in again"), "authentication failure is not presented as an empty library")
	b.action(Browser.ACTION + 18)
	check(menu.account_panel.active() and menu.account_panel.kind == "server" and menu.account_panel.provider == "emby", "re-login opens the selected server editor")
	menu.free(); platform.free()
	for failure in failures: push_error(failure)
	print("media server management checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
