extends SceneTree

const Menu := preload("res://scripts/library_menu.gd")
var checks := 0
var failures: Array[String] = []
var chosen: Array = []
var settings_events: Array = []

class Catalog extends RefCounted:
	func list_recent() -> Array[Dictionary]:
		return [{"uri": "smb://srv1/Video/a.mp4", "title": "最近 A", "position_ms": 61000}]

class PagedCatalog extends RefCounted:
	var count := 32
	func list_recent() -> Array[Dictionary]:
		var result: Array[Dictionary] = []
		for index in count:
			var photo := index >= 30
			result.append({"uri": "file:///recent-page/%d.%s" % [index, "jpg" if photo else "mp4"],
				"title": "Recent %d" % index, "position_ms": 1000, "kind": "image" if photo else "video"})
		return result

## Answers like the Android plugin: an id now, media_list(id, json) later.
class FakePlatform extends "res://tests/account_platform_fixture.gd":
	signal media_list(id: int, payload: String)
	signal android_lifecycle(state: String)
	var cloud_setups := 0
	var cloud_refreshed := false
	func media_cloud_browse(path: String, refresh_cloud: bool) -> int:
		cloud_refreshed = refresh_cloud
		var entries := [{"id": "/mount1", "title": "115", "container": true}] if path.is_empty() else \
			[{"id": path + "/片名.mp4", "title": "片名.mp4", "container": false, "uri": "cloud://mount1/%E7%89%87%E5%90%8D.mp4"}]
		return _reply({"call": "cloud", "source": "cloud", "state": "ready", "path": path, "refresh": refresh_cloud, "entries": entries})
	var next := 0
	var calls: Array = []
	var saved: Array = []
	func _reply(payload: Dictionary) -> int:
		next += 1
		var id := next
		calls.append(payload.get("call", ""))
		(func(): media_list.emit(id, JSON.stringify(payload))).call_deferred()
		return id
	var all_files := false
	var grants := 0
	var usb_connected := true
	var storage_settings: Array = []
	var storage_settings_available := true
	var extra_usb: Array = []
	func storage_volumes() -> Array:
		var result := [{"id":"/storage/emulated/0","title":"Internal storage","container":true,"volume":true,"removable":false}]
		if usb_connected: result.append({"id":"/storage/1234-5678","uuid":"1234-5678","title":"USB drive","container":true,"volume":true,"removable":true})
		result.append_array(extra_usb)
		return result
	## The headset disk: volumes, then folders and videos read from it.
	func media_local_browse(path: String) -> int:
		var entries := []
		if path.is_empty():
			entries = storage_volumes()
		elif path == "/storage/emulated/0":
			entries = [{"id": path + "/Movies", "title": "Movies", "container": true},
				{"id": path + "/舞台.mp4", "title": "舞台.mp4", "container": false, "uri": "file:///storage/emulated/0/%E8%88%9E%E5%8F%B0.mp4", "size": 2147483648}]
		elif path == "/storage/emulated/0/Movies":
			entries = [{"id": path + "/b.mp4", "title": "b.mp4", "container": false, "uri": "file:///storage/emulated/0/Movies/b.mp4", "size": 1048576}]
		elif path == "/storage/1234-5678":
			entries = [{"id":path+"/Movies","title":"Movies","container":true}]
		return _reply({"call": "local", "source": "local", "state": "ready", "path": path, "all_files": all_files, "entries": entries,"volumes":storage_volumes()})
	func media_local_storage_settings(path: String) -> int:
		storage_settings.append(path)
		return _reply({"call":"local_eject","source":"local_eject","state":"settings_opened" if storage_settings_available else "error","error":"" if storage_settings_available else "Storage settings unavailable","volume_id":path,"unmounted":false})
	func media_local_grant_all_files() -> void:
		grants += 1
		(func(): media_list.emit(0, JSON.stringify({"source": "local_access", "state": "settings_opened"}))).call_deferred()
	func media_smb_servers() -> int:
		return _reply({"call": "smb_servers", "source": "smb", "state": "ready",
			"servers": [{"id": "srv1", "name": "NAS", "host": "192.168.1.9", "user": "me", "has_password": true}]})
	func media_smb_discover() -> int:
		return _reply({"call": "smb_discover", "source": "smb", "state": "ready", "discovered": [{"name": "Other", "host": "192.168.1.20"}]})
	func media_smb_browse(server: String, path: String) -> int:
		var entries := [{"id": "Video", "title": "Video", "container": true}] if path.is_empty() else \
			[{"id": path + "/8k.mp4", "title": "8k.mp4", "container": false, "uri": "smb://%s/%s/8k.mp4" % [server, path], "size": 7}]
		return _reply({"call": "smb_browse", "source": "smb", "state": "ready", "server_id": server, "path": path, "entries": entries})
	func media_smb_save(json: String) -> int:
		saved.append(JSON.parse_string(json))
		return media_smb_servers()
	func media_smb_remove(_id: String) -> int:
		return _reply({"call": "smb_remove", "source": "smb", "state": "ready", "servers": []})
	func media_dlna_discover() -> int:
		return _reply({"call": "dlna_discover", "source": "dlna", "state": "ready",
			"servers": [{"id": "uuid:1", "name": "媒体服务器", "location": "http://x", "control_url": "http://x/c"}]})
	func media_dlna_browse(server: String, object_id: String) -> int:
		var entries := [{"id": "c1", "title": "VR", "container": true}] if object_id == "0" else \
			[{"id": "i1", "title": "Show", "container": false, "uri": "http://192.168.1.5/1.mp4"}]
		return _reply({"call": "dlna_browse", "source": "dlna", "state": "ready", "server_id": server, "entries": entries})

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)

func _initialize() -> void:
	call_deferred("_run")

func settle() -> void:
	await process_frame
	await process_frame

func titles(menu: Node) -> Array:
	return menu.rows.map(func(r): return str(r.title))

func choose_setting(menu: Node, key: String, value: Variant) -> void:

	for target in menu.choices.sliders:
		if menu.choices.targets[target].key != key: continue
		var slider: Dictionary = menu.choices.sliders[target]
		var local: Vector3 = menu.to_local(slider.node.global_position)
		local.x += slider.left + slider.width * inverse_lerp(slider.span.x, slider.span.y, float(value))
		local.z = 1
		var origin: Vector3 = menu.to_global(local)
		menu.press_pointer("right_hand", origin, -menu.global_basis.z, true)
		menu.release_pointer("right_hand", origin, -menu.global_basis.z, true)
		return
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.get("kind") == "open" and item.get("key") == key:
			menu.choices.action(target); break
	for page in range(menu.choices.popup.get("choices", []).size() + 1):
		for target in menu.choices.targets:
			var item: Dictionary = menu.choices.targets[target]
			if item.get("kind") == "choose" and item.get("key") == key and menu.choices.same(item.value, value):
				menu.choices.action(target); return
		if menu.choices.opened.is_empty(): return
		menu.stick_scroll(-1.0, 0.3)

func _run() -> void:
	preload("res://scripts/i18n.gd").use("en") # text checks are written in English
	var platform := FakePlatform.new()
	var menu := Menu.new()
	menu.catalog = Catalog.new()
	menu.settings_provider = func(): return {"profile": "320x320", "profiles": ["320x320", "512x512"], "output_width": 0, "rvm_model": "fast", "version": "t"}
	menu.chosen.connect(func(uri: String, title: String): chosen.append([uri, title]))
	menu.setting_changed.connect(func(key: String, value: Variant): settings_events.append([key, value]))
	root.add_child(menu)
	menu.attach_platform(platform)
	menu.toggle()
	check(menu.section == Menu.Section.RECENT and titles(menu) == ["最近 A"], "Opens on the play history")
	var paged := PagedCatalog.new()
	menu.catalog = paged; menu.refresh()
	check(menu.rows.size() == 12 and menu._recent_page_count() == 3 and menu._max_scroll() == 0,
		"32 recent records use three bounded pages of 12 cards")
	check(menu._buttons.filter(func(b): return b.target == Menu.RECENT_PREVIOUS)[0].enabled == false
		and menu._buttons.filter(func(b): return b.target == Menu.RECENT_NEXT)[0].enabled,
		"First page disables previous and enables next")
	var next_button: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.RECENT_NEXT)[0]
	var next_point: Vector2 = next_button.rect.get_center()
	var next_origin := menu.to_global(Vector3(next_point.x, next_point.y, 1))
	menu.press_pointer("right_hand", next_origin, -menu.global_basis.z, true)
	menu.release_pointer("right_hand", next_origin, -menu.global_basis.z, true)
	check(menu._recent_page == 1 and menu.rows[0].uri == "file:///recent-page/12.mp4", "Ray trigger selects the next recent page")
	menu.stick_scroll(-1, 1.0)
	check(menu._recent_page == 1 and menu.scroll == 0, "Thumbstick does not choose or turn recent pages")
	check(menu.video_queue().size() == 30 and menu.image_queue().size() == 2, "Playback queues retain the complete bounded history across pages")
	menu._turn_recent_page(99)
	check(menu._recent_page == 2 and menu.rows.size() == 8
		and not menu._buttons.filter(func(b): return b.target == Menu.RECENT_NEXT)[0].enabled,
		"Final partial page disables next")
	menu.media_filter = 2; menu.refresh()
	check(menu._recent_page == 0 and menu.rows.size() == 2 and menu._recent_page_count() == 1, "Filter recalculates and clamps the recent page")
	paged.count = 0; menu.media_filter = 0; menu.refresh()
	check(menu.rows.is_empty() and menu._recent_page_count() == 1, "Empty history is a stable single empty page")
	menu.catalog = Catalog.new(); menu._reset_navigation(); menu.refresh()
	# Clearing history takes a second press on the same button.
	menu._activate(Menu.CLEAR_HISTORY)
	check(settings_events.is_empty() and menu._confirm == "clear_history", "First press only arms clearing")
	menu._activate(Menu.CLEAR_HISTORY)
	check(settings_events.back() == ["clear_history", true], "Second press clears the history")
	# Local: the disk itself, volumes then folders and videos.
	menu._activate(Menu.NAV_BASE + Menu.Section.LOCAL)
	await settle()
	check(titles(menu) == ["Internal storage", "USB drive"] and menu.rows[1].icon == "usb", "Storage volumes: %s" % [titles(menu)])
	check(menu.text_snapshot().is_empty() == false and menu._buttons.any(func(b): return b.target == Menu.ALL_FILES),
		"Without all-files access a button offers it")
	menu._activate(Menu.ALL_FILES)
	check(platform.grants == 1, "The button opens the system access page")
	menu._activate(Menu.ALL_FILES)
	check(platform.grants == 1, "Repeated grant presses cannot open concurrent permission pages")
	await settle()
	check(menu.status == "Allow access in system settings" and menu._local_grant_pending, "Settings launch is visible in the menu")
	var before_resume := platform.calls.size()
	platform.android_lifecycle.emit("resume")
	await settle()
	check(not menu._local_grant_pending and platform.calls.size() == before_resume + 1 and not menu.rows.is_empty(), "Returning from permissions refreshes the current local listing")
	menu._activate(Menu.ROW_BASE)
	await settle()
	check(titles(menu) == ["Movies", "舞台.mp4"] and menu.rows[1].detail == "2.0 GB" and menu._header_title() == "Internal storage",
		"Volume lists folders first, then videos with size")
	menu._activate(Menu.ROW_BASE)
	await settle()
	check(titles(menu) == ["b.mp4"] and menu._header_title() == "Internal storage / Movies", "Folder opens")
	menu._activate(Menu.ROW_BASE)
	check(chosen.back() == ["file:///storage/emulated/0/Movies/b.mp4", "b.mp4"] and not menu.visible, "Choosing a video emits its file URI and closes")
	menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.LOCAL)
	await settle()
	check(titles(menu) == ["b.mp4"], "Reopening keeps the folder")
	menu._activate(Menu.BACK)
	await settle()
	check(titles(menu) == ["Movies", "舞台.mp4"], "Back returns to the parent folder")
	# SMB: saved servers plus discovered hosts, shares, folders, file URI.
	menu._activate(Menu.NAV_BASE + Menu.Section.CLOUD)
	await settle()
	check(titles(menu) == ["115"], "Cloud accounts appear as mounts")
	menu._activate(Menu.ROW_BASE)
	await settle()
	check(titles(menu) == ["片名.mp4"] and menu._header_title() == "115", "Cloud folder opens with a readable breadcrumb")
	menu._activate(Menu.REFRESH)
	await settle()
	check(platform.cloud_refreshed, "Cloud refresh bypasses cached metadata")
	menu._activate(Menu.ROW_BASE)
	check(str(chosen.back()[0]).begins_with("cloud://mount1/") and not menu.visible, "Cloud selection keeps a stable URI")
	menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.CLOUD)
	await settle()
	menu._activate(Menu.CRUMB_BASE)
	await settle()
	check(titles(menu) == ["115"], "Cloud breadcrumb returns to account list")
	menu._activate(Menu.CLOUD_ACCOUNTS)
	check(menu.account_panel.view == "choose" and menu.account_panel.kind == "cloud", "Account action opens in-app provider selection")
	platform.android_lifecycle.emit("resume")
	await settle()
	check(menu.account_panel.view == "choose", "Resume retains in-app provider selection")
	menu.account_panel.action(menu.AccountPanel.BASE)
	await settle()
	check(not menu._cloud_setup and titles(menu) == ["115"], "Leaving account management returns to mounts")
	menu._activate(Menu.NAV_BASE + Menu.Section.SMB)
	await settle()
	check(titles(menu) == ["NAS"], "Saved SMB server listed")
	menu._activate(Menu.REFRESH)
	await settle()
	check(titles(menu) == ["NAS", "Other"] and menu.rows[1].icon == "plus", "Discovered host offered to add")
	menu._activate(Menu.ROW_BASE)
	await settle()
	check(titles(menu) == ["Video"] and menu._header_title() == "NAS", "Server lists shares")
	menu._activate(Menu.ROW_BASE)
	await settle()
	check(menu._header_title() == "NAS / Video" and titles(menu) == ["8k.mp4"], "Share lists videos")
	menu._activate(Menu.ROW_BASE)
	check(chosen.back()[0] == "smb://srv1/Video/8k.mp4", "SMB video emits a stable smb:// URI")
	menu.toggle()
	menu._activate(Menu.BACK)
	await settle()
	check(menu._smb_path == "" and titles(menu) == ["Video"], "Back from a share returns to the share list")
	# Editor: typing with the ray keyboard, shift, backspace, save.
	menu._activate(Menu.BACK)
	await settle()
	menu._activate(Menu.ADD)
	check(not menu._editor.is_empty() and menu._field == 1, "Add opens the editor on the host field")
	for key in [Menu.KEY_BASE + 0, Menu.KEY_BASE + 9, Menu.KEY_BASE + 28]: # "1", "0", "."
		menu._activate(key)
	menu._activate(Menu.BACKSPACE)
	check(menu._editor.host == "10", "Keyboard types and deletes: %s" % menu._editor.host)
	menu._activate(Menu.FIELD_BASE + 2)
	menu._activate(Menu.SHIFT)
	menu._activate(Menu.KEY_BASE + 10) # "q" -> "Q"
	menu._activate(Menu.KEY_BASE + 11)
	check(menu._editor.user == "Qw", "Shift applies to one key")
	menu._activate(Menu.FIELD_BASE + 3)
	menu._activate(Menu.KEY_BASE + 20)
	check(menu.text_snapshot().contains("•") and not menu.text_snapshot().contains("Qwa"), "Password is masked")
	menu._activate(Menu.SAVE)
	await settle()
	check(platform.saved.size() == 1 and platform.saved[0].host == "10" and platform.saved[0].password == "a", "Save sends the server")
	check(menu._editor.is_empty() and titles(menu) == ["NAS", "Other"], "Editor closes; saved and still-unsaved discovered hosts listed")
	# DLNA: discovery on entry, containers, items.
	menu._activate(Menu.NAV_BASE + Menu.Section.DLNA)
	await settle()
	check(titles(menu) == ["媒体服务器"], "DLNA servers discovered on entry")
	menu._activate(Menu.ROW_BASE)
	await settle()
	menu._activate(Menu.ROW_BASE)
	await settle()
	check(menu._header_title() == "媒体服务器 / VR" and titles(menu) == ["Show"], "DLNA container lists items")
	menu._activate(Menu.ROW_BASE)
	check(chosen.back()[0] == "http://192.168.1.5/1.mp4", "DLNA item emits its media URL")
	menu.toggle()
	menu._activate(Menu.BACK)
	await settle()
	check(titles(menu) == ["VR"], "DLNA back to the root container")
	# Settings sub-tabs.
	menu._activate(Menu.NAV_BASE + Menu.Section.SETTINGS)
	check(not Menu.SETTING_TABS.has("Alpha") and not menu.text_snapshot().contains("320x320")
		and not menu.text_snapshot().contains("RVM quality"), "Settings omit model and input-resolution decisions")
	menu._activate(Menu.TAB_BASE + Menu.VIDEO_TAB)
	choose_setting(menu, "output_width", 4096)
	check(settings_events.back() == ["output_width", 4096], "Output cap setting")
	menu._activate(Menu.TAB_BASE + Menu.GENERAL_TAB)
	check(menu.rows.any(func(row): return row.get("key", "") == "history" and row.value == true), "History is saved by default")
	choose_setting(menu, "history", false)
	check(settings_events.back() == ["history", false], "History can be switched off")
	menu._activate(Menu.TAB_BASE + Menu.SUBTITLES_TAB)
	check(menu.rows.size() == 3 and menu.rows[0].slider and menu.rows[0].value == 5.0,
		"Subtitle distance is a slider, 5 m by default")
	check(menu.rows[2].key == "subtitle_position" and menu.rows[2].slider and menu.rows[2].value == 0,
		"Global subtitle angle defaults to the marked centre")
	check(menu.rows[1].key == "subtitle_direction" and menu.rows[1].value == 0 and menu.rows[1].choices.size() == 2,
		"Direction control is above position, horizontal by default")
	choose_setting(menu, "subtitle_direction", 1)
	check(settings_events.back() == ["subtitle_direction", 1], "Global settings can choose vertical")
	choose_setting(menu, "subtitle_position", -60)
	check(settings_events.back() == ["subtitle_position", -60.0], "Global angle slider reaches lower endpoint")
	choose_setting(menu, "subtitle_distance", 10.0)
	check(settings_events.back() == ["subtitle_distance", 10.0], "Distance slider reaches 10 m")
	choose_setting(menu, "subtitle_distance", 0.1)
	check(settings_events.back()[0] == "subtitle_distance" and is_equal_approx(settings_events.back()[1], 0.1), "Distance slider reaches 0.1 m: %s" % str(settings_events.back()))
	menu._activate(Menu.TAB_BASE + Menu.ABOUT_TAB)
	var about_text := "\n".join(menu.find_children("*", "Label3D", true, false).map(func(label): return label.text))
	check(about_text.contains("Thru3D Media Player") and about_text.contains("FFSky Studio")
		and about_text.contains("ffskyteam@gmail.com") and about_text.contains("https://thru3d.com")
		and about_text.contains("https://github.com/zerochocobo/Thru3D-Media-Player"), "About brand and support")
	menu._activate(Menu.ROW_BASE + 5)
	check(menu.rows[0].title == "Belfast Sunset (Pure Sky)" and menu.rows[0].detail.contains("Poly Haven · CC0 1.0")
		and menu.rows[0].detail.contains("Dimitrios Savva / Greg Zaal / Jarod Guest") and menu.rows[1].title == "Godot",
		"One panorama entry contains its source, license and all authors")
	var credit_detail: Label3D = menu._buttons.filter(func(button): return button.target == Menu.ROW_BASE)[0].node.get_child(2)
	check(credit_detail.text == menu.rows[0].detail, "Combined panorama attribution remains visible without truncation")
	var credit_origin := menu.to_global(Vector3(0.1, Menu.LIST_TOP, 1))
	check(menu.ray_hit(credit_origin, -menu.global_basis.z).is_empty(), "Copyright information is not a fake clickable control")
	menu.press_pointer("right_hand", credit_origin, -menu.global_basis.z, true)
	menu.update_pointer("right_hand", menu.to_global(Vector3(0.1, Menu.LIST_TOP + 0.4, 1)), -menu.global_basis.z, true)
	menu.release_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, true)
	check(menu.scroll > 0, "Ray dragging still scrolls informational credits")
	menu.scroll = menu._max_scroll()
	menu._draw()
	check(menu.text_snapshot().contains("p115rsacipher") and menu._max_scroll() > 0, "Copyright list scrolls to its final component")
	menu._activate(Menu.ABOUT_HOME)
	check(menu.rows[0].title == "Thru3D Media Player" and menu.scroll == 0, "Return from credits resets scrolling")
	# Long lists scroll with the stick (whole rows) and the scrollbar track; no pages.
	menu._activate(Menu.NAV_BASE + Menu.Section.LOCAL)
	await settle()
	var many: Array = []
	for i in 30:
		many.append({"id": "/big/%d" % i, "uri": "file:///big/v%02d.mp4" % i, "title": "v%02d" % i, "size": 1, "container": false})
	menu.platform = null # keep this listing; a reload would replace it
	menu._local_stack = [{"id": "/big", "title": "Big"}]
	menu._local_entries = many
	menu.scroll = 0.0
	menu.refresh()
	check(menu.rows.size() == 30 and int(menu.scroll) == 0, "Folder with 30 videos starts at the top")
	var direction := -menu.global_basis.z
	# Videos are tiles, four per line; [scroll] counts lines.
	var at := func(y: float) -> Vector3: return menu.to_global(Vector3(-0.36, y, 1.0))
	var first_line := Menu.GRID_TOP - Menu.TILE_SIZE.y * 0.5
	# Ray press on a tile, drag up five line pitches, release: scrolls, does not select.
	var picks := chosen.size()
	check(menu.press_pointer("right_hand", at.call(first_line), direction, true), "Press on a tile is accepted")
	check(chosen.size() == picks, "Press alone does not select")
	menu.update_pointer("right_hand", at.call(first_line + 5 * Menu.GRID_PITCH.y), direction, true)
	menu.release_pointer("right_hand", at.call(first_line + 5 * Menu.GRID_PITCH.y), direction, true)
	check(roundi(menu.scroll) == 5 and chosen.size() == picks, "Ray drag scrolls five lines without selecting: %s" % menu.scroll)
	# A tap (press + release without moving) selects the row under the ray.
	menu.press_pointer("right_hand", at.call(first_line), direction, true)
	menu.release_pointer("right_hand", at.call(first_line + 0.005), direction, true)
	check(chosen.back()[1] == "v20", "Tap selects the visible tile at the scroll position")
	menu.toggle()
	check(menu.visible and menu._local_path() == "/big" and menu.rows.size() == 30, "Reopening keeps the folder")
	menu.press_pointer("right_hand", at.call(first_line), direction, true)
	menu.update_pointer("right_hand", at.call(first_line - 9.0), direction, true)
	menu.release_pointer("right_hand", at.call(first_line - 9.0), direction, true)
	check(menu.scroll == 0.0, "Dragging down past the top clamps")
	var bar_bottom := Menu.GRID_TOP - (Menu.GRID_LINES * Menu.GRID_PITCH.y - 0.012) + 0.01
	menu.press_pointer("left_hand", menu.to_global(Vector3(0.835, bar_bottom, 1.0)), direction, true)
	menu.release_pointer("left_hand", menu.to_global(Vector3(0.835, bar_bottom, 1.0)), direction, true)
	check(menu.scroll == menu._max_scroll(), "Pointing at the scrollbar bottom jumps to the end")
	# A press in the gap between tiles also drags; mid-way the rows shift smoothly instead of jumping.
	menu.scroll = 0.0
	menu.refresh()
	var gap := Menu.GRID_TOP - Menu.TILE_SIZE.y - 0.01
	var gap_at := func(y: float) -> Vector3: return menu.to_global(Vector3(-0.36, y, 1.0))
	check(menu.press_pointer("right_hand", gap_at.call(gap), direction, true), "Press between tiles starts a drag")
	menu.update_pointer("right_hand", gap_at.call(gap + 1.5 * Menu.GRID_PITCH.y), direction, true)
	check(is_equal_approx(menu.scroll, 1.5) and is_equal_approx(menu._list.position.y, 0.5 * Menu.GRID_PITCH.y),
		"Drag scrolls by fractions of a line: %s" % menu.scroll)
	var hidden := menu._buttons.filter(func(b): return menu._row_target(b.target) and not b.node.visible).size()
	check(hidden == Menu.COLS * 2, "Half-way between lines both edge lines hide: %d" % hidden)
	menu.release_pointer("right_hand", gap_at.call(gap + 1.5 * Menu.GRID_PITCH.y), direction, true)
	check(chosen.size() == picks + 1, "Releasing a drag from a gap selects nothing")
	for _frame in 60:
		menu._process(1.0 / 60.0)
	check(menu.scroll == roundf(menu.scroll), "At rest the list settles on a whole line: %s" % menu.scroll)
	# Thumbsticks scroll (down shows later rows) and never select.
	menu.scroll = 0.0
	menu.refresh()
	menu.stick_scroll(-1.0, 0.25)
	check(menu.scroll > 0.5 and chosen.size() == picks + 1, "Stick down scrolls towards later rows: %s" % menu.scroll)
	var held := menu.scroll
	menu.stick_scroll(0.1, 0.25)
	check(menu.scroll == held, "Inside the dead zone the stick does nothing")
	menu.stick_scroll(1.0, 5.0)
	check(menu.scroll == 0.0, "Stick up scrolls back and clamps at the top")
	# The navigation column is angled towards the viewer: a ray aimed at an entry from the front hits it.
	var smb_entry: Vector3 = menu._side.to_global(Vector3(0, 0.39 - Menu.Section.SMB * 0.13, 0.002))
	var eye := smb_entry + menu._side.global_basis.z * 1.2
	check(menu.press_pointer("left_hand", eye, smb_entry - eye, true) and menu.section == Menu.Section.SMB, "Ray selects an entry on the angled navigation column")
	menu.attach_platform(platform)
	menu._activate(Menu.NAV_BASE + Menu.Section.LOCAL)
	check(not menu.text_snapshot().contains(" / "), "No page counter")
	# Denied media permission offers a retry.
	menu._on_media_list(-1, "{}")
	menu._pending[999] = "local"
	menu._on_media_list(999, JSON.stringify({"state": "denied"}))
	check(menu.status == "Media access needed", "Denied permission shows a short status")
	menu._pending[998] = "local"
	menu._on_media_list(998, JSON.stringify({"state": "denied", "error": "ALL_FILES_ACCESS_NEEDED"}))
	menu._activate(Menu.GRANT)
	check(menu._local_grant_pending and platform.grants == 2, "An unreadable folder requests access")
	await settle()
	menu._on_media_list(0, JSON.stringify({"source": "local_access", "state": "error", "error": "Permission settings unavailable"}))
	check(menu.status == "Permission settings unavailable" and not menu._local_grant_pending, "Unsupported settings show failure and release the retry guard")
	var before_granted := platform.calls.size()
	menu._on_media_list(0, JSON.stringify({"source": "local_access", "state": "granted"}))
	await settle()
	check(platform.calls.size() == before_granted + 1, "A legacy runtime grant refreshes the local folder without a settings resume")
	menu._on_media_list(0, JSON.stringify({"source": "local_access", "state": "settings_opened"}))
	var before_manual_refresh := platform.calls.size()
	menu._activate(Menu.REFRESH)
	await settle()
	check(not menu._local_grant_pending and platform.calls.size() == before_manual_refresh + 1, "Manual refresh recovers a VR permission overlay without a resume event")
	menu._pending[997] = "local"
	menu._on_media_list(997, JSON.stringify({"state": "denied"}))
	# Language: follows the choice, the same menu in Chinese and back in English.
	var I18n := preload("res://scripts/i18n.gd")
	I18n.use("zh")
	menu.refresh()
	check(menu.text_snapshot().contains("本地文件") and menu.text_snapshot().contains("需要媒体访问权限") 		and not menu.text_snapshot().contains("Local files"), "Chinese menu and status")
	menu._activate(Menu.NAV_BASE + Menu.Section.SETTINGS)
	menu._activate(Menu.TAB_BASE + Menu.GENERAL_TAB)
	check(menu.rows.size() == 4 and menu.rows[0].title == "语言" and menu.rows[0].value == "zh"
		and menu.rows[0].choices.map(func(option): return option.label) == ["System", "简体中文", "繁體中文", "日本語", "English"],
		"General groups all languages in one dropdown, each named in itself")
	var chosen := []
	menu.setting_changed.connect(func(key, value): chosen.append([key, value]))
	choose_setting(menu, "language", "en")
	check(chosen == [["language", "en"]], "Choosing a language reports it")
	I18n.use("en")
	menu.refresh()
	check(menu.text_snapshot().contains("About") and not menu.text_snapshot().contains("关于"), "English menu")
	print("library menu checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures:
		push_error(failure)
	menu.queue_free()
	platform.free()
	quit(0 if failures.is_empty() else 1)
