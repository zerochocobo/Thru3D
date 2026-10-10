extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Accounts := preload("res://scripts/account_panel.gd")
const Platform := preload("res://tests/test_cloud_accounts.gd").Platform
var checks := 0
var failures: Array[String] = []
class JavaMethods extends Object:
	func has_java_method(method: String) -> bool:
		return method in ["account_open", "license_text"]
func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var platform := Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.visible = true
	menu.section = Menu.Section.CLOUD
	var panel: RefCounted = menu.account_panel
	var java := JavaMethods.new()
	menu.platform = java
	check(not java.has_method("account_open") and panel.supported(), "JNI account methods are supported through the Java method registry")
	check(Menu.PlatformMethods.supports(java, "license_text"), "JNI license method is detected through the Java method registry")
	menu.platform = null
	check(not panel.supported(), "missing account plugin remains unavailable")
	menu.platform = platform
	java.free()
	menu._activate(Menu.CLOUD_ACCOUNTS)
	check(panel.view == "choose" and not menu._grid(), "cloud plus opens provider list in the VR menu")
	check(menu.rows.size() == 6 and menu.rows[0].account_provider == "115_open" and menu.rows[0].title == "115" and menu.rows[2].account_provider == "aliyun_open" and menu.rows[3].account_provider == "quark_open" and menu.rows[4].account_provider == "onedrive" and menu.rows[5].account_provider == "webdav" and not menu.rows.any(func(row): return row.get("account_provider", "") == "115" or row.has("account_dav")), "Only 115 Open is offered for new 115 accounts")
	panel.choose(menu.rows[5])
	check(panel.view == "form" and panel.provider == "webdav" and panel.fields == ["name", "base", "username", "password"] and panel.field == "base", "WebDAV is a remote connection form inside the cloud library")
	check(menu._buttons.any(func(b): return b.target == Accounts.BASE + 6) and not menu._buttons.any(func(b): return b.target in [Accounts.BASE + 7, Accounts.BASE + 14]), "WebDAV uses test/save without web login or a local service toggle")
	panel.field = "password"; panel.input("append", "private-dav-secret")
	check(not JSON.stringify(panel.data).contains("private-dav-secret"), "WebDAV password remains masked in the snapshot")
	panel.action(Accounts.BASE + 6)
	check(platform.account_calls.back()[1] == "save_webdav", "WebDAV submits remote connection settings")
	var remote_button: Dictionary = menu._buttons.filter(func(b): return b.target == Accounts.BASE + 6)[0]
	var remote_key: Dictionary = menu._buttons.filter(func(b): return b.target == Accounts.KEY)[0]
	check(remote_button.rect.end.y < menu._buttons.filter(func(b): return b.target == Accounts.BASE + 1)[0].rect.position.y, "WebDAV save button does not overlap the keyboard modifiers")
	check(menu._buttons.filter(func(b): return b.target >= Accounts.FIELD and b.target < Accounts.FIELD + 4).all(func(b): return b.rect.position.y > remote_key.rect.end.y), "four WebDAV fields stay above the keyboard")
	panel.open("cloud")
	panel.start("cloud", "115", "first") # Existing legacy accounts retain their management form.
	check(panel.view == "form" and panel.provider == "115" and panel.session > 0, "115 uses backend authentication session")
	var web_login: Dictionary = menu._buttons.filter(func(button): return button.target == Accounts.BASE + 7)[0]
	var first_key: Dictionary = menu._buttons.filter(func(button): return button.target == Accounts.KEY)[0]
	check(web_login.rect.position.y > first_key.rect.end.y, "website login is above the input keyboard")
	var password_login: Dictionary = menu._buttons.filter(func(button): return button.target == Accounts.BASE + 6)[0]
	check(password_login.rect.position.y > first_key.rect.end.y and password_login.rect.position.y == web_login.rect.position.y, "115 primary login and secondary website option share the row above the keyboard")
	var id: int = panel.session
	platform.android_lifecycle.emit("pause"); platform.android_lifecycle.emit("resume")
	check(panel.session == id and panel.view == "form" and not id in platform.account_cancels, "headset pause retains login session")
	panel.field = "password"; panel.input("append", "private-secret")
	check(not JSON.stringify(panel.data).contains("private-secret") and panel.data.password_length == 14, "secret input only returns mask length")
	var text := "\n".join(menu.find_children("*", "Label3D", true, false).map(func(label): return label.text))
	check(not text.contains("private-secret") and text.contains("••••"), "secret does not appear in VR labels")
	panel.action(Accounts.BASE + 6)
	check(platform.account_calls.back()[1] == "password", "password login is explicit")
	var image := Image.create(100, 40, false, Image.FORMAT_RGB8); image.fill(Color.WHITE)
	var state: Dictionary = platform.account_sessions[id]
	state.state = "captcha"; state.revision += 1; state.challenge_revision = 1
	state.prompt = Marshalls.raw_to_base64(image.save_png_to_buffer()); state.choices = state.prompt
	panel.poll()
	check(panel.view == "captcha" and panel.choices != null, "captcha images become in-app textures")
	check(menu._buttons.filter(func(b): return b.target >= Accounts.CAPTCHA and b.target < Accounts.CAPTCHA + 10).size() == 10, "ten captcha ray targets")
	for i in [4, 1, 9, 0]: panel.action(Accounts.CAPTCHA + i)
	panel.action(Accounts.BASE + 12)
	check(platform.account_calls.back()[2].code == "4190", "captcha sends user-selected order")
	panel.action(Accounts.BASE + 11); check(panel.selected.is_empty(), "captcha reselect clears order")
	state.challenge_revision = 2; state.revision += 1; panel.poll()
	check(panel.challenge_revision == 2 and panel.selected.is_empty(), "new challenge replaces old captcha selection")
	state.state = "sms"; state.sms_wait = 60; state.sms_sent = false; state.revision += 1; panel.poll()
	check(panel.view == "sms" and panel.field == "sms", "SMS stays inside app")
	first_key = menu._buttons.filter(func(button): return button.target == Accounts.KEY)[0]
	var sms_field: Dictionary = menu._buttons.filter(func(button): return button.target == Accounts.FIELD)[0]
	var sms_send: Dictionary = menu._buttons.filter(func(button): return button.target == Accounts.BASE + 9)[0]
	var sms_verify: Dictionary = menu._buttons.filter(func(button): return button.target == Accounts.BASE + 10)[0]
	check(sms_send.rect.position.y > first_key.rect.end.y and sms_verify.rect.position.y > first_key.rect.end.y,
		"SMS send and verify buttons are above the keyboard")
	check(sms_send.rect.end.y < sms_field.rect.position.y and sms_verify.rect.end.y < sms_field.rect.position.y,
		"SMS action row stays below the code field without overlapping it")
	check(not menu._buttons.filter(func(b): return b.target == Accounts.BASE + 9)[0].enabled, "SMS cooldown disables resend")
	state.sms_wait = 59; panel.poll(); check(menu.text_snapshot().contains("59s"), "cooldown updates without a network result")
	state.state = "web"; state.web = {"editing": false, "status": "", "width": 1200, "height": 720, "scroll_range": 2160, "scroll_y": 0}; state.revision += 1; panel.poll()
	check(panel.view == "web" and menu._buttons.any(func(b): return b.target == Accounts.WEB), "website is a VR panel")
	var page_rect: Rect2 = panel.web_rect()
	check(page_rect.size.x > 1.7 and is_equal_approx(page_rect.size.x / page_rect.size.y, 1200.0 / 720.0), "webpage is enlarged without stretching")
	check(not menu._buttons.any(func(b): return b.target >= Menu.NAV_BASE and b.target < Menu.NAV_BASE + 10), "webpage has a dedicated full-width panel")
	var point := menu.to_global(Vector3(0.1, 0.1, 1))
	menu.press_pointer("right_hand", point, -menu.global_basis.z, true)
	check(panel.web_hand == "right_hand" and platform.web_calls.back()[1] == "down", "ray trigger starts webpage touch")
	menu.press_pointer("left_hand", point, -menu.global_basis.z, true)
	check(panel.web_hand == "right_hand", "other hand cannot steal webpage drag")
	menu.cancel_pointer("right_hand")
	check(panel.web_hand.is_empty() and platform.web_calls.back()[1] == "cancel", "lost pointer cancels webpage touch")
	var calls: int = platform.web_calls.size()
	menu.stick_scroll(1, 0.016)
	check(platform.web_calls.size() == calls + 1 and platform.web_calls.back()[1] == "scroll", "stick only scrolls website")
	var bar_point := menu.to_global(Vector3(0.91, 0.13, 1))
	menu.press_pointer("right_hand", bar_point, -menu.global_basis.z, true)
	check(panel.web_drag_scroll and platform.web_calls.back()[1] == "scroll_to", "ray press captures the webpage scrollbar")
	menu.update_pointer("right_hand", menu.to_global(Vector3(0.91, -0.1, 1)), -menu.global_basis.z, true)
	check(platform.web_calls.back()[3] > 0.7, "scrollbar ray drag moves towards later webpage content")
	calls = platform.web_calls.size(); menu.cancel_pointer("right_hand")
	check(panel.web_hand.is_empty() and platform.web_calls.size() == calls, "scrollbar cancellation does not send a stray website touch")
	panel.action(Accounts.BASE + 23); check(platform.web_calls.back()[1] == "zoom_in", "webpage zoom has a visible ray control")
	state.web.editing = true; panel.poll()
	check(panel.web_rect() == page_rect, "input focus never shrinks or moves the webpage")
	first_key = menu._buttons.filter(func(button): return button.target == Accounts.KEY)[0]
	check(first_key.rect.end.y < page_rect.position.y, "website keyboard sits below the full webpage")
	panel.input("append", "x")
	check(platform.web_calls.back()[1] == "text" and platform.web_calls.back()[4] == "x", "ray keyboard commits into webpage")
	menu._activate(Menu.NAV_BASE + Menu.Section.SETTINGS)
	check(not panel.active() and id in platform.account_cancels, "leaving section cancels login and clears textures")
	menu.tab = Menu.ABOUT_TAB; menu.refresh(); menu._open_licenses()
	check(menu.rows.any(func(row): return row.license_id == "115"), "115 notice lives in global About")
	check(menu._engine_notices().contains("Permission is hereby granted"), "engine third-party notices include full license texts")
	menu._choose(menu.rows[0])
	check(panel.view == "license" and panel.license_lines.size() > 10, "full engine license has scrollable text")
	check(not menu._grid() and menu._max_scroll() > 0, "license is a scrolling reader")
	for button in menu._buttons:
		if button.target >= Menu.ROW_BASE and button.target < Menu.ROW_BASE + menu._drawn_slots():
			var row: Dictionary = menu.rows[button.target - Menu.ROW_BASE]
			check(button.node.get_child(0).text == row.title, "license lines retain full text without ellipsis")
	panel.action(Accounts.BASE)
	check(menu._about_page == 3 and menu.rows.size() >= 10, "reader back returns to global license list")
	panel.open("server")
	check(menu.rows.size() == 6, "server chooser includes discovery and five types")
	panel.choose(menu.rows[1]); check(panel.fields.has("base") and panel.fields.has("password"), "server editor includes address and transient secret")
	panel.action(Accounts.BASE + 6); check(platform.account_calls.back()[1] == "save_server", "server test and save uses backend")
	menu.dismiss(); check(not panel.active() and panel.session == 0, "close explicitly cancels form")
	panel.open("cloud")
	for row in menu.rows.duplicate():
		if row.get("account_provider", "") in ["115_open", "baidu", "aliyun_open", "quark_open", "onedrive"]:
			panel.choose(row)
			check(panel.fields == ["name"], "OAuth form requests a name without cookie, password or QR fields")
			check(menu.text_snapshot().contains(menu.I18n.t("Authorize")) and not menu.text_snapshot().contains(menu.I18n.t("Sign in on website")), "OAuth providers use the authorization entry")
			panel.action(Accounts.BASE + 7)
			check(platform.account_calls.back()[1] == "web", "OAuth authorization uses the in-app VR web panel")
			panel.open("cloud")
	menu.free(); platform.free()
	print("in-app account checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
