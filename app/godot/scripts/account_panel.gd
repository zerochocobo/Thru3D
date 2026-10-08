extends RefCounted
## Account forms and web login share the existing VR library ray menu.
const I18n := preload("res://scripts/i18n.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const BASE := 2000
const FIELD := 2100
const KEY := 2200
const CAPTCHA := 2300
const WEB := 2400
const WEB_SCROLL := 2401
var menu: Node
var view := ""
var kind := ""
var provider := ""
var session := 0
var data := {}
var items: Array = []
var fields: Array[String] = []
var field := ""
var shift := false
var symbols := false
var selected: Array[int] = []
var prompt: Texture2D
var choices: Texture2D
var web_texture: ImageTexture
var web_node: MeshInstance3D
var web_hand := ""
var web_drag_scroll := false
var web_point := Vector2.ZERO
var web_time := 0.0
var poll_time := 0.0
var revision := -1
var challenge_revision := -1
var paused := false
var license_lines: Array[String] = []
var title := ""

func _init(owner: Node) -> void: menu = owner
func active() -> bool: return not view.is_empty()
func supported() -> bool: return Methods.supports(menu.platform, "account_open")

func close() -> void:
	web_cancel()
	if session > 0 and menu.platform: menu.platform.account_cancel(session)
	session = 0; view = ""; data = {}; items = []; fields.clear(); field = ""
	prompt = null; choices = null; web_texture = null; web_node = null; selected.clear()
	license_lines.clear(); menu.scroll = 0.0; revision = -1; challenge_revision = -1; paused = false; _defaults = {}

func open(source: String, manage: bool = false) -> void:
	close()
	kind = source
	menu.server_browser.cancel(); menu._cancel_cloud()
	if not supported():
		menu.status = "Account settings unavailable"; menu.refresh(); return
	view = "accounts" if manage else "choose"
	title = "Cloud accounts" if source == "cloud" else "Media servers"
	if manage: load_accounts()
	menu.status = ""; menu._reset_navigation(); menu.refresh()

func load_accounts() -> void:
	var parsed: Variant = JSON.parse_string(menu.platform.account_list(kind))
	items = parsed if parsed is Array else []
	if not parsed is Array: menu.status = "Account settings unavailable"

func start(type: String, selected_provider: String = "", id: String = "", defaults: Dictionary = {}) -> void:
	if session > 0: menu.platform.account_cancel(session)
	web_cancel(); web_texture = null; prompt = null; choices = null; selected.clear()
	provider = selected_provider
	session = menu.platform.account_open(type, provider, id, JSON.stringify(defaults))
	view = "discover" if type == "discover" else ("dav" if type == "dav" else "form")
	fields.assign(["name", "base", "username", "password"] if type == "server" else ["name", "username", "password"])
	if type == "server" and provider == "stash": fields.erase("username")
	if type == "cloud" and provider == "baidu": fields.assign(["name"])
	field = "base" if type == "server" else "username"
	if not field in fields: field = "name"
	_defaults = {}
	data = {}; revision = -1; challenge_revision = -1; title = "WebDAV" if type == "dav" else ("Search local network" if type == "discover" else provider_name(provider))
	menu.scroll = 0.0; poll(); menu.refresh()

func provider_name(value: String) -> String:
	return {"115": "115", "baidu": I18n.t("Baidu Netdisk"), "emby": "Emby", "jellyfin": "Jellyfin", "stash": "Stash", "xbvr": "XBVR"}.get(value, value)

func poll() -> void:
	if session <= 0 or not menu.platform: return
	var parsed: Variant = JSON.parse_string(menu.platform.account_snapshot(session))
	if not parsed is Dictionary or parsed.is_empty(): return
	var previous_wait := int(data.get("sms_wait", 0))
	data = parsed
	var state := str(data.get("state", "form"))
	if state == "done":
		var source := kind
		close()
		if source == "cloud": menu.cloud_accounts.changed()
		else: menu.server_browser.load_servers(); menu.refresh()
		return
	if state in ["captcha", "sms", "web", "dav", "discover"]: view = state
	if state == "captcha" and int(data.get("challenge_revision", 0)) != challenge_revision:
		prompt = decode(str(data.get("prompt", ""))); choices = decode(str(data.get("choices", ""))); selected.clear()
		challenge_revision = int(data.get("challenge_revision", 0))
	if view == "sms": fields.assign(["sms"]); field = "sms"
	if view == "discover": items = data.get("result", {}).get("servers", [])
	var changed := int(data.get("revision", 0)) != revision or previous_wait != int(data.get("sms_wait", 0))
	if view == "web": changed = changed or str(data.get("web", {})) != _web_status
	_web_status = str(data.get("web", {}))
	revision = int(data.get("revision", 0))
	if changed: menu.refresh()

var _web_status := ""
func tick(delta: float) -> void:
	if not active() or paused: return
	poll_time += delta; web_time += delta
	if poll_time >= 0.2: poll_time = 0.0; poll()
	if view == "web" and web_time >= 0.2 and menu.visible:
		web_time = 0.0
		var bytes: PackedByteArray = menu.platform.account_web_frame(session)
		if not bytes.is_empty():
			var image := Image.new()
			if image.load_jpg_from_buffer(bytes) == OK:
				if web_texture == null: web_texture = ImageTexture.create_from_image(image)
				elif web_texture.get_height() != image.get_height(): web_texture.set_image(image)
				else: web_texture.update(image)
				if is_instance_valid(web_node): web_node.material_override.albedo_texture = web_texture

func lifecycle(state: String) -> void:
	paused = state == "pause"
	if paused: web_cancel()
	else: poll()

func decode(value: String) -> Texture2D:
	if value.length() > 1500000: return null
	var bytes := Marshalls.base64_to_raw(value)
	var image := Image.new()
	var error := image.load_png_from_buffer(bytes)
	if error != OK: error = image.load_jpg_from_buffer(bytes)
	if error != OK or image.get_width() > 2048 or image.get_height() > 2048: return null
	return ImageTexture.create_from_image(image)

func command(action: String, extra: Dictionary = {}) -> void:
	if session > 0: menu.platform.account_action(session, action, JSON.stringify(extra)); poll()

func rows() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if view == "choose":
		if kind == "cloud":
			for p in ["115", "baidu"]: result.append({"title": provider_name(p), "icon": "cloud", "account_provider": p})
			result.append({"title": "WebDAV", "icon": "settings", "account_dav": true})
		else:
			result.append({"title": I18n.t("Search local network"), "icon": "refresh", "account_discover": true})
			for p in ["emby", "jellyfin", "stash", "xbvr"]: result.append({"title": provider_name(p), "icon": "server", "account_provider": p})
	elif view == "accounts":
		for item in items: result.append({"title": str(item.name), "detail": provider_name(str(item.provider)), "icon": "edit", "account_edit": item})
	elif view == "discover":
		for item in items: result.append({"title": str(item.name) if not str(item.name).is_empty() else I18n.t("Server"), "detail": str(item.base), "icon": "server", "account_found": item})
	elif view == "license":
		for i in range(0, license_lines.size(), 2):
			result.append({"title": license_lines[i], "detail": license_lines[i + 1] if i + 1 < license_lines.size() else "", "icon": "info", "about_info": true})
	return result

func choose(row: Dictionary) -> bool:
	if not active(): return false
	if row.has("account_provider"): start(kind, str(row.account_provider), "", _defaults)
	elif row.has("account_edit"): start(kind, str(row.account_edit.provider), str(row.account_edit.id))
	elif row.has("account_dav"): start("dav")
	elif row.has("account_discover"): start("discover")
	elif row.has("account_found"):
		var found: Dictionary = row.account_found
		if str(found.provider).is_empty():
			_defaults = found; view = "choose"; menu.refresh()
		else: start("server", str(found.provider), "", found)
	return true

var _defaults := {}
func action(target: int) -> bool:
	if not active() or target < BASE: return false
	if paused: return true
	if target == BASE:
		close(); menu._load_section(); menu.refresh(); return true
	if target >= FIELD and target < FIELD + fields.size(): field = fields[target - FIELD]; menu.refresh(); return true
	if target >= CAPTCHA and target < CAPTCHA + 10:
		if not data.get("busy", false) and selected.size() < 4: selected.append(target - CAPTCHA); menu.refresh()
		return true
	if target >= KEY and target < KEY + 40:
		var layer: Array = menu.SYMBOLS if symbols else menu.KEYS
		var value: String = layer[(target - KEY) / 10][(target - KEY) % 10]
		input("append", value.to_upper() if shift else value); shift = false; return true
	match target - BASE:
		1: shift = not shift; menu.refresh()
		2: symbols = not symbols; menu.refresh()
		3: input("append", " ")
		4: input("backspace", "")
		5: input("paste", "")
		6: command("save_server" if kind == "server" else "password")
		7: command("web")
		8: command("rename")
		9: command("send_sms")
		10: command("verify_sms")
		11: selected.clear(); menu.refresh()
		12:
			var code := ""
			for i in selected: code += str(i)
			command("answer", {"code": code})
		13: choices = null; prompt = null; selected.clear(); command("captcha")
		14: command("dav_enable", {"enabled": not data.get("result", {}).get("enabled", false)})
		15: command("dav_reset")
		16: command("dav_show")
		17: web_action("back")
		18: web_action("reload")
		19: web_action("enter")
		20: web_action("keyboard_close")
		21: web_action("finish")
		22:
			if session > 0: menu.platform.account_cancel(session); session = 0
			view = "choose"; menu.scroll = 0.0; menu.refresh()
		23: web_action("zoom_in")
		24: web_action("zoom_out")
		25: web_action("scroll", Vector2(0, -1))
		26: web_action("scroll", Vector2(0, 1))
	return true

func input(action_name: String, text: String) -> void:
	if data.get("busy", false): return
	if view == "web": web_action("text" if action_name == "append" else action_name, Vector2.ZERO, text)
	else: menu.platform.account_input(session, field, action_name, text); poll()

func draw() -> void:
	if view == "web":
		draw_web(); return
	menu._button(BASE, "", Vector2(-0.52, 0.46), Vector2(0.09, 0.07), true, "up")
	menu._label(I18n.t(title), Vector3(0.13, 0.46, 0.004), 24)
	var enabled := not bool(data.get("busy", false))
	if view in ["choose", "accounts", "discover", "license"]:
		menu._draw_rows()
		if view == "accounts": menu._button(BASE + 22, "", Vector2(0.8, 0.46), Vector2(0.09, 0.07), true, "plus")
		if view == "discover": menu._button(BASE + 22, I18n.t("Add manually"), Vector2(0.15, -0.51), Vector2(0.38, 0.07))
	elif view == "form" or view == "sms":
		draw_fields(enabled); draw_keyboard(enabled)
		if view == "sms":
			var wait := int(data.get("sms_wait", 0))
			menu._button(BASE + 9, str(wait) + "s" if wait > 0 else I18n.t("Send SMS code"), Vector2(-0.14, -0.51), Vector2(0.42, 0.07), enabled and wait == 0)
			menu._button(BASE + 10, I18n.t("Verify and sign in"), Vector2(0.4, -0.51), Vector2(0.48, 0.07), enabled and bool(data.get("sms_sent", false)))
		else:
			if kind == "server": menu._button(BASE + 6, I18n.t("Test and save"), Vector2(0.3, -0.51), Vector2(0.4, 0.07), enabled, "", true)
			else:
				if provider == "115":
					menu._button(BASE + 7, I18n.t("Sign in on website"), Vector2(-0.15, 0.012), Vector2(0.54, 0.077), enabled)
					menu._button(BASE + 6, I18n.t("Sign in"), Vector2(0.46, 0.012), Vector2(0.54, 0.077), enabled and not str(data.get("fields", {}).get("username", "")).is_empty() and int(data.get("password_length", 0)) > 0, "", true)
				else: menu._button(BASE + 7, I18n.t("Sign in on website"), Vector2(0.17, 0.012), Vector2(0.7, 0.077), enabled, "", true)
				if _editing_id():
					menu._button(BASE + 8, "", Vector2(0.73, -0.51), Vector2(0.1, 0.07), enabled and not str(data.get("fields", {}).get("name", "")).strip_edges().is_empty(), "check")
					menu._tips[BASE + 8] = I18n.t("Save name")
	elif view == "captcha": draw_captcha(enabled)
	elif view == "dav":
		var result: Dictionary = data.get("result", {})
		var on: bool = result.get("enabled", false)
		menu._button(BASE + 14, I18n.t("Turn off" if on else "Turn on"), Vector2(0.1, 0.29), Vector2(0.43, 0.09), enabled)
		var y := 0.15
		for address in result.get("addresses", []): menu._label(str(address), Vector3(0.1, y, 0.004), 20); y -= 0.06
		if on:
			menu._label(I18n.t("Username: quest"), Vector3(0.1, y - 0.06, 0.004), 21)
			menu._label(str(result.get("password", "••••••••••••")), Vector3(0.1, y - 0.13, 0.004), 20)
			menu._button(BASE + 16, I18n.t("Show password"), Vector2(-0.15, -0.3), Vector2(0.4, 0.08), enabled)
			menu._button(BASE + 15, I18n.t("Reset password"), Vector2(0.4, -0.3), Vector2(0.4, 0.08), enabled)
	elif view == "web": draw_web()
	var error := str(data.get("error", ""))
	if error.begins_with("Sign-in declined ("):
		error = I18n.t("Sign-in declined (%s).").replace("%s", error.trim_prefix("Sign-in declined (").trim_suffix(")."))
	else: error = I18n.t(error)
	if bool(data.get("busy", false)): error = I18n.t("Connecting…")
	if not error.is_empty(): menu._label(error, Vector3(0.15, 0.375, 0.006), 17)

func _editing_id() -> bool: return bool(data.get("editing_account", false))
func draw_fields(enabled: bool) -> void:
	var names := {"name": "Name", "base": "Server address", "username": "Username", "password": "Password", "sms": "SMS code"}
	if provider == "115": names.username = "115 account / phone number"
	if provider == "stash": names.password = "API Key"
	for i in fields.size():
		var key: String = fields[i]
		var value := str(data.get("fields", {}).get(key, ""))
		if key in ["password", "sms"]:
			value = "•".repeat(mini(int(data.get(key + "_length", 0)), 32))
			if key == "password" and value.is_empty() and data.get("has_password", false): value = I18n.t("Keep saved login")
		var y := 0.30 - i * 0.087
		menu._button(FIELD + i, "", Vector2(0.17, y), Vector2(1.2, 0.077), enabled, "", key == field)
		var node: MeshInstance3D = menu._buttons.back().node
		var label: Label3D = node.get_child(0)
		label.text = I18n.t(names[key]); label.font_size = 16; label.position = Vector3(-0.57, 0.012, 0.004); label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		var detail: Label3D = menu._label(menu._fit_title(value, "", 1.1, 19), Vector3(-0.57, -0.018, 0.004), 19, node)
		detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		detail.modulate = Color(0.04, 0.10, 0.08) if key == field else Color.WHITE

func draw_keyboard(enabled: bool, offset: Vector2 = Vector2.ZERO) -> void:
	var layer: Array = menu.SYMBOLS if symbols else menu.KEYS
	for row in 4:
		for col in 10:
			var value: String = layer[row][col]
			menu._button(KEY + row * 10 + col, value.to_upper() if shift else value, Vector2(-0.40 + col * 0.125, -0.10 - row * 0.071) + offset, Vector2(0.114, 0.061), enabled)
	for spec in [[1,"⇧",-0.36,0.16],[2,"#+=" if not symbols else "abc",-0.16,0.2],[3,"␣",0.15,0.36],[4,"⌫",0.46,0.2],[5,I18n.t("Paste"),0.7,0.22]]:
		menu._button(BASE + int(spec[0]), str(spec[1]), Vector2(float(spec[2]), -0.405) + offset, Vector2(float(spec[3]), 0.073), enabled)

func texture_node(texture: Texture2D, centre: Vector2, size: Vector2) -> MeshInstance3D:
	var node := MeshInstance3D.new(); var mesh := QuadMesh.new(); mesh.size = size; node.mesh = mesh
	node.position = Vector3(centre.x, centre.y, 0.007)
	var material: StandardMaterial3D = menu._material(Color.WHITE, 13); material.albedo_texture = texture
	node.material_override = material; menu.add_child(node); menu._decorations.append(node)
	return node

func draw_captcha(enabled: bool) -> void:
	if prompt: texture_node(prompt, Vector2(0.12, 0.26), Vector2(0.85, 0.13))
	for i in 10:
		var centre := Vector2(-0.34 + (i % 5) * 0.23, 0.02 - (i / 5) * 0.18)
		menu._button(CAPTCHA + i, "", centre, Vector2(0.19, 0.15), enabled and selected.size() < 4)
		if choices:
			var tile := AtlasTexture.new(); tile.atlas = choices
			tile.region = Rect2((i % 5) * choices.get_width() / 5.0, (i / 5) * choices.get_height() / 2.0, choices.get_width() / 5.0, choices.get_height() / 2.0)
			texture_node(tile, centre, Vector2(0.14, 0.12))
	menu._label("%d / 4" % selected.size(), Vector3(0.1, -0.29, 0.008), 22)
	for i in selected.size():
		menu._label(str(i + 1), Vector3(-0.34 + (selected[i] % 5) * 0.23, 0.085 - (selected[i] / 5) * 0.18, 0.01), 25)
	menu._button(BASE + 11, I18n.t("Clear selection"), Vector2(-0.24, -0.43), Vector2(0.32, 0.08), enabled)
	menu._button(BASE + 13, "", Vector2(0.13, -0.43), Vector2(0.12, 0.08), enabled, "refresh")
	menu._button(BASE + 12, I18n.t("Continue"), Vector2(0.49, -0.43), Vector2(0.34, 0.08), enabled and selected.size() == 4, "", true)

func web_rect() -> Rect2:
	return Rect2(-0.87, -0.38, 1.72, 1.032)
func draw_web() -> void:
	var editing: bool = data.get("web", {}).get("editing", false)
	menu._set_backdrop(Vector2(1.94, 1.94 if editing else 1.38), Vector2(0, -0.12 if editing else 0.16))
	menu._button(BASE, "", Vector2(-0.85, 0.75), Vector2(0.1, 0.08), true, "up")
	menu._button(BASE + 17, "", Vector2(-0.70, 0.75), Vector2(0.1, 0.08), true, "back")
	menu._button(BASE + 18, "", Vector2(-0.55, 0.75), Vector2(0.1, 0.08), true, "refresh")
	menu._label(provider_name(provider), Vector3(-0.05, 0.75, 0.009), 24)
	menu._button(BASE + 24, "", Vector2(0.51, 0.75), Vector2(0.1, 0.08), true, "minus")
	menu._button(BASE + 23, "", Vector2(0.66, 0.75), Vector2(0.1, 0.08), true, "plus")
	menu._button(menu.CLOSE, "", Vector2(0.85, 0.75), Vector2(0.1, 0.08), true, "close")
	var rect := web_rect()
	menu._button(WEB, "", rect.get_center(), rect.size)
	web_node = texture_node(web_texture, rect.get_center(), rect.size)
	var info: Dictionary = data.get("web", {})
	var range_px := maxf(1.0, float(info.get("scroll_range", 720)))
	var page_px := float(info.get("height", 720))
	var can_scroll := range_px > page_px + 1
	menu._button(WEB_SCROLL, "", Vector2(0.91, 0.135), Vector2(0.045, 0.92), can_scroll)
	var thumb := clampf(page_px / range_px, 0.08, 1.0) * 0.92
	var fraction := clampf(float(info.get("scroll_y", 0)) / maxf(1.0, range_px - page_px), 0, 1)
	menu._decoration(Vector2(0.025, thumb), Vector2(0.91, 0.595 - thumb * 0.5 - fraction * (0.92 - thumb)), menu.ACCENT if can_scroll else Color(0.4, 0.45, 0.5))
	menu._button(BASE + 25, "", Vector2(0.91, 0.63), Vector2(0.06, 0.06), can_scroll, "arrow_up")
	menu._button(BASE + 26, "", Vector2(0.91, -0.36), Vector2(0.06, 0.06), can_scroll, "arrow_down")
	menu._button(BASE + 21, I18n.t("Finish sign-in"), Vector2(0, -0.48), Vector2(0.45, 0.08), true, "", true)
	if editing:
		draw_keyboard(true, Vector2(-0.17, -0.53))
		menu._button(BASE + 20, "", Vector2(-0.42, -0.48), Vector2(0.12, 0.08), true, "keyboard_hide")
		menu._button(BASE + 19, "", Vector2(0.42, -0.48), Vector2(0.12, 0.08), true, "check")
	menu._place_device_status(Vector2(0, -1.17 if editing else -0.66))
	var status: String = data.get("web", {}).get("status", "")
	var error := str(data.get("error", ""))
	if data.get("busy", false): status = "Connecting…"
	elif not error.is_empty(): status = error
	if not status.is_empty(): menu._label(I18n.t(status), Vector3(0, -0.56, 0.009), 17)

func web_action(action_name: String, point: Vector2 = Vector2.ZERO, text: String = "") -> void:
	if session > 0 and menu.platform: menu.platform.account_web_action(session, action_name, point.x, point.y, text)
func web_uv(point: Vector3) -> Vector2:
	var rect := web_rect()
	return Vector2((point.x - rect.position.x) / rect.size.x, 1.0 - (point.y - rect.position.y) / rect.size.y)
func web_press(hand: String, point: Vector3, scrolling: bool = false) -> void:
	if not web_hand.is_empty(): return
	web_hand = hand; web_drag_scroll = scrolling
	if scrolling: web_scroll_to(point)
	else: web_point = web_uv(point); web_action("down", web_point)
func web_move(hand: String, point: Vector3) -> void:
	if web_hand != hand: return
	if web_drag_scroll: web_scroll_to(point)
	else: web_point = web_uv(point); web_action("move", web_point)
func web_release(hand: String, point: Variant) -> void:
	if web_hand != hand: return
	if web_drag_scroll:
		if point != null: web_scroll_to(point)
	elif point == null: web_action("cancel", web_point)
	else: web_action("up", web_uv(point))
	web_hand = ""; web_drag_scroll = false
func web_cancel() -> void:
	if not web_hand.is_empty() and not web_drag_scroll: web_action("cancel", web_point)
	web_hand = ""; web_drag_scroll = false

func web_scroll_to(point: Vector3) -> void:
	web_action("scroll_to", Vector2(0, clampf((0.595 - point.y) / 0.92, 0, 1)))

func show_license(name: String, text: String) -> void:
	close(); view = "license"; title = name
	for original in text.split("\n"):
		var line := ""
		for c in original:
			if menu.ui_font().get_string_size(line + c, HORIZONTAL_ALIGNMENT_LEFT, -1, 19).x * 0.0012 > 1.12:
				license_lines.append(line); line = ""
			line += c
		license_lines.append(line)
	menu._reset_navigation(); menu.refresh()
