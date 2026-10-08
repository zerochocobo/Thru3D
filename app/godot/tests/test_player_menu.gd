extends SceneTree

const Menu := preload("res://scripts/player_menu.gd")
const Recent := preload("res://scripts/recent_menu.gd")
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Catalog := preload("res://scripts/recent_files.gd")
const Library := preload("res://scripts/library_menu.gd")
var checks := 0
var failures: Array[String] = []

class InputMain extends "res://scripts/main.gd":
	var test_rays := {}
	func _ray(hand: String) -> Variant: return test_rays.get(hand)

class Host extends RefCounted:
	var calls: Array = []
	func mpv_supported() -> bool: return true
	func open_mpv_video(uri: String, start: int, stereo: bool, profile: String, alpha: bool, _vulkan: bool, _depth: bool = false, _top_bottom: bool = false, _exact: bool = false) -> int:
		calls.append(["open", uri, start, stereo, profile, alpha])
		return 7
	func close_mpv_video(id: int) -> void: calls.append(["close", id])
	func set_mpv_playing(id: int, playing: bool) -> void: calls.append(["play", id, playing])
	func revise_mpv_video(id: int, stereo: bool, alpha: bool, profile: String, position: int, _depth: bool = false, _top_bottom: bool = false, _exact: bool = false) -> int:
		calls.append(["revise", id, stereo, alpha, profile, position])
		return 0 # Busy native revision stays queued, just as production.
	func set_mpv_audio(id: int, track: int, volume: float, muted: bool) -> bool:
		calls.append(["audio", id, track, volume, muted])
		return true
	func set_mpv_subtitle(id: int, track: int) -> bool:
		calls.append(["subtitle", id, track])
		return true
	func set_mpv_depth_view(id: int, shift: float, convergence: float) -> bool:
		calls.append(["depth_view", id, shift, convergence])
		return true
	func pick_local_video() -> int:
		calls.append(["pick"])
		return 20
	func cancel_local_video_pick(id: int) -> void: calls.append(["cancel_pick", id])

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _check_video_queue() -> void:
	var library := Library.new()
	library.rows = [{"uri": "smb://host/a.mp4", "title": "A", "kind": "video"},
		{"uri": "smb://host/p.jpg", "title": "Photo", "kind": "image"},
		{"folder": "subfolder", "title": "Folder"},
		{"uri": "cloud://folder", "title": "Container", "container": true},
		{"uri": "cloud://b.mp4", "title": "B", "kind": "video"}]
	var queue := library.video_queue()
	check(queue.map(func(item): return item.uri) == ["smb://host/a.mp4", "cloud://b.mp4"], "Video queue preserves browse order and excludes photos, folders and containers")
	library.rows.reverse()
	check(queue[0].uri == "smb://host/a.mp4", "Browsing later cannot reorder the captured playback queue")
	library.section = Library.Section.MEDIA_SERVER
	library.server_browser.entries = [{"uri": "medialib://server/scene/1", "title": "Scene", "basename": "movie_180_sbs.mp4"}]
	queue = library.video_queue()
	library.server_browser.entries[0].basename = "changed.mp4"
	check(queue.size() == 1 and queue[0].metadata.basename == "movie_180_sbs.mp4", "Server queue keeps a copy of naming metadata even when details are displayed")
	library.free()

func press_at(menu: Node3D, x: float, y: float, hand: String = "right_hand") -> bool:
	return menu.press_pointer(hand, menu.to_global(Vector3(x, y, 1)), -menu.global_basis.z, true)

func click(menu: Node3D, target: int, hand: String = "right_hand") -> bool:
	for button in menu._buttons:
		if button.target == target:
			var centre: Vector2 = button.rect.get_center()
			return menu.press_pointer(hand, menu.to_global(Vector3(centre.x, centre.y, 1)), -menu.global_basis.z, true)
	return false

## Battery and clock pill: text, 12/24 h, low and charging states, no battery on desktop.
func _check_device_status() -> void:
	var I18n := preload("res://scripts/i18n.gd")
	var status := {"level": 85, "charging": false, "clock24": true}
	var pill := preload("res://scripts/device_status.gd").new()
	pill.status_provider = func() -> Dictionary: return status
	pill.clock_provider = func() -> Dictionary: return {"hour": 13, "minute": 5}
	root.add_child(pill)
	check(pill.text_snapshot() == "85%   13:05" and pill._battery.visible and not pill._bolt.visible, "Status pill: battery and 24 h clock")
	status.clear()
	status.merge({"level": 12, "charging": false, "clock24": false})
	pill.refresh(true)
	check(pill.text_snapshot() == "12%   1:05 PM" and pill._battery.material_override.albedo_color == pill.LOW_COLOR, "Status pill: 12 h clock, low battery red")
	check(is_equal_approx(pill._fill.mesh.size.y, pill.ICON * 15.0 / 24 * 0.12), "Status pill: fill follows level")
	status.clear()
	status.merge({"level": 12, "charging": true, "clock24": false})
	pill.refresh(true)
	check(pill._bolt.visible and pill._battery.material_override.albedo_color != pill.LOW_COLOR, "Status pill: charging shows bolt, not red")
	I18n.use("zh")
	pill.refresh(true)
	check(pill.text_snapshot() == "12%   下午 1:05", "Status pill: Chinese 12 h clock")
	I18n.use("en")
	status.clear()
	pill.refresh(true)
	check(pill.text_snapshot() == "13:05" and not pill._battery.visible, "Status pill: clock only without a battery source")
	pill.free()

func setting_click(menu: Node3D, target: int) -> bool:
	for button in menu._buttons:
		if button.target == target:
			var centre: Vector2 = button.rect.get_center()
			var point := menu.to_global(Vector3(centre.x, centre.y, 1))
			if not menu.press_pointer("right_hand", point, -menu.global_basis.z, true): return false
			menu.release_pointer("right_hand", point, -menu.global_basis.z, true)
			return true
	return false

func choose_setting(menu: Node3D, key: String, value: Variant) -> bool:
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.get("kind") == "open" and item.get("key") == key:
			if not setting_click(menu, target): return false
			break
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.get("kind") == "choose" and item.get("key") == key and menu.choices.same(item.value, value): return setting_click(menu, target)
	return false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	preload("res://scripts/i18n.gd").use("en") # text checks are written in English
	_check_video_queue()
	var directory := ProjectSettings.globalize_path("res://../../artifacts/player-menu-host/" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(directory)
	var host := Host.new()
	var video := Video.new()
	video.bookmark_store = preload("res://scripts/bookmark_store.gd").new(directory.path_join("bookmarks"))
	video.mode_memory = Memory.new(directory.path_join("modes"))
	video.recent_files = Catalog.new(directory.path_join("recent"))
	root.add_child(video)
	video.set_process(false)
	video.platform = host
	var main := InputMain.new()
	main.settings_path = directory.path_join("settings.cfg")
	main.video = video
	var menu := Menu.new()
	menu.state_provider = main._menu_state
	menu.action_requested.connect(main._on_menu_action)
	menu.setting_requested.connect(main._on_player_setting)
	menu.adjustment_requested.connect(main._on_playback_adjustment)
	menu.adjustment_committed.connect(main._save_playback_adjustments)
	menu.recent_requested.connect(main._show_recent_menu)
	menu.seek_requested.connect(main._on_menu_seek)
	menu.volume_requested.connect(main._on_menu_volume)
	menu.subtitle_requested.connect(video.set_subtitle_track)
	menu.depth_strength_requested.connect(main._on_depth_strength.bind(false))
	menu.depth_strength_committed.connect(main._save_depth_strength)
	root.add_child(menu)
	menu.set_process(false)
	main.player_menu = menu
	var recent := Recent.new()
	recent.catalog = video.recent_files
	recent.player_requested.connect(main._show_player_menu)
	root.add_child(recent)
	main.recent_menu = recent
	menu.toggle()
	check(not click(menu, 102) and not click(menu, 104) and not click(menu, 112) and host.calls.is_empty(), "No-video play and both effects disabled, no native side effect")
	check(click(menu, 100) and recent.visible and not menu.visible, "Pointer recent button opens one menu")
	check(click(recent, Recent.PLAYER) and menu.visible and not recent.visible, "Pointer Player returns from recent menu")
	check(click(menu, 100) and not menu.visible and recent.visible, "Pointer open video shows the in-headset library")
	recent.dismiss()
	video.open_local("file:///menu.mp4", "测试电影 😀", 0, false)
	video._waiting_first = false
	video.media.state = "playing"
	video.media.format = {"width": 3840, "height": 1920}
	video.media.playback = {"details": {"codec": "hevc", "audio_tracks": [{"id": 1}, {"id": 2}], "audio_track_id": "1",
		"subtitle_tracks": [{"id": 1, "codec": "subrip"}, {"id": 2, "codec": "hdmv_pgs_subtitle"}, {"id": 3, "codec": "ass"}]}}
	main._show_player_menu()
	check(main._menu_state().source_size == "3840 x 1920" and main._menu_state().codec == "hevc" and main._menu_state().text_subtitle_tracks == 2, "Menu uses actual format and codec; excludes bitmap subtitles")
	check(click(menu, 102, "left_hand") and not video.requested_play and host.calls.back() == ["play", 7, false], "Left pointer pauses actual player")
	check(click(menu, 102) and video.requested_play and host.calls.back() == ["play", 7, true], "Right pointer resumes actual player")
	var shown := func(target: int) -> bool: return menu._buttons.any(func(b): return b.target == target)
	check(shown.call(112) and shown.call(104) and not click(menu, 104), "Flat screen keeps both effects on the bar, with unsupported Alpha disabled")
	check(not menu._mode_open and click(menu, 112, "left_hand") and video.depth_requested and video._pending_revision.depth and menu._depth_open,
		"2D -> 3D opens its strength slider and enables the remembered strength")
	menu.update_pointer("left_hand", Vector3.ZERO, Vector3.ZERO, false)
	var depth_tile: Dictionary = menu._buttons.filter(func(b): return b.target == 112)[0]
	check(depth_tile.node.material_override.get_shader_parameter("surface_color") == Menu.SELECTED, "Requested depth lights its primary bar button")
	check(click(menu, 112) and video.depth_requested and not menu._depth_open, "Closing the slider keeps 3D active")
	check(click(menu, 112) and menu._depth_open, "Reopen strength control")
	video.depth_enabled = true # Native first depth pair accepted; exercise live bridge values.
	var revisions := host.calls.filter(func(call): return call[0] == "revise").size()
	var depth_y := func(value: float) -> float: return lerpf(Menu.DEPTH_SPAN.x, Menu.DEPTH_SPAN.y, Menu.DepthStrength.to_fraction(value))
	check(press_at(menu, Menu.DEPTH_X, depth_y.call(1.5), "left_hand") and is_equal_approx(video.depth_strength, 1.5)
		and host.calls.back()[0] == "depth_view" and is_equal_approx(host.calls.back()[2], .0525), "Slider sets 150% and sends actual native parallax")
	menu.update_pointer("right_hand", menu.to_global(Vector3(Menu.DEPTH_X, depth_y.call(2), 1)), -menu.global_basis.z, true)
	check(is_equal_approx(video.depth_strength, 1.5) and not press_at(menu, Menu.DEPTH_X, depth_y.call(2)), "Other hand cannot move or steal an active depth drag")
	menu.update_pointer("left_hand", menu.to_global(Vector3(Menu.DEPTH_X, Menu.DEPTH_SPAN.y + .2, 1)), -menu.global_basis.z, true)
	check(video.depth_strength == 2.0 and menu._depth_label.text == "200%" and is_equal_approx(float(video.material.get_shader_parameter("depth_shift")), .07), "Drag beyond top clamps to PTMediaServer's 200% and updates shader")
	check(host.calls.filter(func(call): return call[0] == "revise").size() == revisions, "Nonzero drag never restarts depth inference or playback")
	menu.update_pointer("left_hand", menu.to_global(Vector3(Menu.DEPTH_X, Menu.DEPTH_SPAN.x - .2, 1)), -menu.global_basis.z, true)
	check(not video.depth_requested and not video.auto_depth and video.depth_strength == 2.0 and menu._depth_label.text == "Off", "Bottom disables 3D and retains last nonzero strength")
	menu.release_pointer("left_hand", Vector3.ZERO, Vector3.ZERO, false)
	var depth_calls := host.calls.size()
	menu.update_pointer("left_hand", menu.to_global(Vector3(Menu.DEPTH_X, depth_y.call(2), 1)), -menu.global_basis.z, true)
	check(host.calls.size() == depth_calls, "Depth drag stops on trigger release")
	var saved_strength := ConfigFile.new()
	saved_strength.load(main.settings_path)
	check(saved_strength.get_value("video", "depth_strength") == 2.0 and not saved_strength.get_value("effects", "auto_3d"), "Release persists strength and manual Off")
	check(click(menu, 112) and not menu._depth_open, "Close disabled depth slider")
	video.depth_enabled = false
	video.set_projection(1)
	menu.refresh()
	var before_disabled_depth := host.calls.size()
	check(shown.call(104) and shown.call(112) and not click(menu, 112) and host.calls.size() == before_disabled_depth,
		"VR180 keeps both bar effects visible; disabled depth cannot issue a backend command")
	check(click(menu, 104) and video.alpha_requested and video._pending_revision.alpha, "Alpha button requests same-source production revision")
	menu.update_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
	var alpha_tile: Dictionary = menu._buttons.filter(func(b): return b.target == 104)[0]
	check(alpha_tile.node.material_override.get_shader_parameter("surface_color") == Color(0.16, 0.31, 0.27), "Requested Alpha is shown on its bar button, not as status text")
	video.set_projection(3)
	menu.refresh()
	check(shown.call(104) and shown.call(112) and not click(menu, 104) and not click(menu, 112) and not video.alpha_requested,
		"360 keeps both bar effects visible but disabled, and stops the previous Alpha effect")
	check(click(menu, Menu.MODE) and click(menu, Menu.MODE_PROJECTION) and video.geometry == 0 and not video.stereo_sbs, "Back to flat 2D through the mode tiles")
	check(click(menu, Menu.MODE_STEREO + 3) and video.depth_requested and click(menu, Menu.MODE_STEREO) and not video.depth_requested, "2D tile ends 2D -> 3D")
	check(click(menu, Menu.MODE), "Mode panel closes")
	video.control.observe(20000, 60000)
	menu.refresh_values()
	var seek_calls := host.calls.size()
	check(menu.press_pointer("left_hand", menu.to_global(Vector3(-Menu.BAR_SEEK / 4, -0.08, 1)), -menu.global_basis.z, true) and host.calls.size() == seek_calls, "Ray press previews time without starting a seek")
	menu.release_pointer("left_hand", Vector3.ZERO, Vector3.ZERO, true)
	check(video.control.target_ms == 15000 and host.calls.back()[-1] == 15000, "Click release seeks real source to 15s")
	menu.refresh_values()
	check(menu._elapsed.text == "00:15" and is_equal_approx(menu._thumb.position.x, -Menu.BAR_SEEK / 4)
		and video.control.observed_position_ms == 20000, "Released seek keeps the thumb at its queued target while the clock remains at the original frame")
	video.control.observe(19000, 60000)
	video.control.take_pending()
	video.control.observe(18000, 60000)
	menu.refresh_values()
	check(menu._elapsed.text == "00:15" and is_equal_approx(menu._thumb.position.x, -Menu.BAR_SEEK / 4),
		"Stale source clock during first-frame wait cannot bounce the timeline back")
	video.control.first_frame()
	menu.refresh_values()
	check(menu._elapsed.text == "00:15" and video.control.observed_position_ms == 15000,
		"Confirmed first frame changes ownership without moving the thumb")
	video.control.observe(16000, 60000)
	menu.refresh_values()
	check(menu._elapsed.text == "00:16" and menu._thumb.position.x > -Menu.BAR_SEEK / 4,
		"Timeline resumes advancing from the confirmed target")
	check(menu.press_pointer("right_hand", menu.to_global(Vector3(Menu.BAR_SEEK / 4, -0.08, 1)), -menu.global_basis.z, true), "Other ray starts a time preview")
	menu.release_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, true)
	check(video.control.target_ms == 45000, "Other ray release seeks to 75 percent")
	check(menu.press_pointer("right_hand", menu.to_global(Vector3(Menu.BAR_SEEK / 2 + 0.02, -0.08, 1)), -menu.global_basis.z, true), "Timeline edge accepts a preview")
	menu.release_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, true)
	check(video.control.target_ms == 59999, "Timeline release clamps before EOF")
	seek_calls = host.calls.size()
	menu.press_pointer("left_hand", menu.to_global(Vector3(-Menu.BAR_SEEK / 4, -0.08, 1)), -menu.global_basis.z, true)
	menu.update_pointer("left_hand", menu.to_global(Vector3(Menu.BAR_SEEK / 4, -0.08, 1)), -menu.global_basis.z, true)
	check(host.calls.size() == seek_calls and menu._seek_preview == 45000, "Drag changes preview only")
	menu.release_pointer("left_hand", Vector3.ZERO, Vector3.ZERO, true)
	check(video.control.target_ms == 45000 and host.calls.filter(func(c): return c[0] == "revise").back()[-1] == 45000, "Drag submits its final target")
	seek_calls = host.calls.size()
	menu.press_pointer("left_hand", menu.to_global(Vector3(0, -0.08, 1)), -menu.global_basis.z, true)
	menu.cancel_pointer("left_hand")
	check(host.calls.size() == seek_calls, "Cancelled drag submits no seek")
	video.control.reject()
	menu.refresh_values()
	check(menu._elapsed.text == "00:16", "Rejected seek returns to the confirmed playback position")
	var call_count := host.calls.size()
	video.control.duration_ms = -1
	menu.refresh_values()
	check(not click(menu, Menu.SEEK) and host.calls.size() == call_count, "Unknown-duration timeline cannot seek")
	video.control.duration_ms = 60000
	menu.refresh_values()
	check(not menu.text_snapshot().contains("Press trigger") and not menu.text_snapshot().contains("controller"), "Product controls omit implementation and interaction instruction text")
	check(click(menu, 11) and menu.section == 1 and choose_setting(menu, "loop", true) and video.loop_enabled and menu.visible and menu.text_snapshot().contains("On"), "Loop radio selection applies without closing menu")
	check(click(menu, 10) and menu.section == 0, "Arrow returns from the settings panel to the slim bar")
	check(click(menu, 11) and menu.section == 1 and menu.visible, "Settings tab selected by ray")
	check(not menu.text_snapshot().contains("Test video") and not Menu.OPERATIONS[1].has("calibration"), "Settings no longer offers test videos")
	check(not menu.text_snapshot().contains("Alpha resolution") and not menu.text_snapshot().contains("Eye order") and not menu.text_snapshot().contains("Unmute"),
		"Settings panel leaves out what the bar and the library already have")
	check(choose_setting(menu, "audio_track", 2) and video.audio_track_id == 2, "Audio dropdown selects native track IDs directly")
	check(not Menu.OPERATIONS[1].has("subtitle_back") and not Menu.OPERATIONS[1].has("subtitle_next")
		and Menu.HEADINGS.has("Subtitles"), "Settings groups subtitle layout without duplicate track controls")
	check(click(menu, 10) and click(menu, 110) and menu._subtitle_open and video.subtitles.requested_track == 0, "CC opens choices without changing subtitle selection")
	check(menu._subtitle_ids.values() == [0, 1, 3], "Picker shows Off and every supported text track, skipping bitmap subtitles")
	check(click(menu, Menu.SUBTITLE_ROW + 2) and video.subtitles.requested_track == 3 and host.calls.back() == ["subtitle", 7, 3]
		and not menu._subtitle_open, "Ray selects the actual nonconsecutive ASS track ID and closes picker")
	menu.update_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
	var cc: Dictionary = menu._buttons.filter(func(b): return b.target == 110)[0]
	check(cc.node.material_override.get_shader_parameter("surface_color") == Menu.SELECTED
		and cc.node.get_child(1).material_override.albedo_color == Menu.ACCENT, "Enabled CC has both selected background and accent glyph")
	check(click(menu, 110), "CC reopens to inspect current selection")
	check(not menu._buttons.any(func(b): return b.target == Menu.SUBTITLE_POSITION)
		and not menu.choices.targets.values().any(func(item): return item.get("key") == "subtitle_distance"),
		"Flat subtitle picker hides immersive distance and position controls")
	var selected: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.SUBTITLE_ROW + 2)[0]
	check(selected.base_color == Menu.SELECTED and selected.node.get_child_count() == 2, "Current subtitle row is highlighted and checked")
	check(click(menu, Menu.SUBTITLE_ROW) and video.subtitles.requested_track == 0, "Off explicitly disables subtitles")
	cc = menu._buttons.filter(func(b): return b.target == 110)[0]
	check(cc.node.get_child(1).material_override.albedo_color != Menu.ACCENT, "Off resets CC accent")
	var saved_tracks: Array = video.media.playback.details.subtitle_tracks.duplicate(true)
	video.media.playback.details.subtitle_tracks = []
	menu.refresh_values()
	check(click(menu, 110) and menu._subtitle_ids.values() == [0], "No subtitles still opens a truthful Off-only picker")
	video.media.playback.details.subtitle_tracks = saved_tracks
	menu.refresh_values()
	check(menu._subtitle_open and menu._subtitle_ids.values() == [0, 1, 3], "Late-loaded external tracks update the open picker")
	for index in 8:
		video.media.playback.details.subtitle_tracks.append({"id": 10 + index, "codec": "webvtt", "title": "clip.language%d.vtt" % index})
	menu.refresh_values()
	var subtitle_calls := host.calls.size()
	menu.stick_scroll(-1, 0.5)
	check(menu._subtitle_offset > 0 and host.calls.size() == subtitle_calls and video.subtitles.requested_track == 0, "Thumbstick only scrolls subtitle list; it never selects or seeks")
	check(menu._subtitle_ids.has(Menu.SUBTITLE_ROW) and menu._subtitle_ids.size() == 4, "Off stays visible while a long track list scrolls")
	check(click(menu, Menu.SUBTITLE_DOWN) and menu._subtitle_offset > 3, "Ray arrow scrolls further subtitle choices")
	check(click(menu, Menu.SUBTITLE_UP), "Ray arrow scrolls earlier subtitle choices")
	check(click(menu, 109) and not menu._subtitle_open and menu._subtitle_ids.is_empty(), "Opening volume closes subtitle picker")
	check(click(menu, 110) and menu._subtitle_open and not menu._volume_open, "Opening subtitles closes volume")
	check(click(menu, 110) and not menu._subtitle_open, "Pressing CC again dismisses picker without changing track")
	video.media.playback.details.subtitle_tracks = saved_tracks
	menu.refresh_values()
	check(click(menu, Menu.MODE) and not click(menu, Menu.MODE_STEREO + 2), "Eye order disabled for 2D video")
	check(click(menu, Menu.MODE_STEREO + 1) and video.stereo_sbs, "SBS tile updates actual player format")
	check(shown.call(112) and not click(menu, 112) and not video.depth_requested, "Native stereo keeps the depth shortcut visible but disabled")
	check(click(menu, Menu.MODE_STEREO + 2) and video.swap_eyes, "Eye order tile swaps actual player eyes")
	check(click(menu, Menu.MODE_PROJECTION + 1) and video.geometry == 1, "Projection tile sets actual video geometry")
	check(click(menu, 108), "Recenter routed through preview-safe Main")
	var layout_calls := host.calls.size()
	check(click(menu, 110) and menu._subtitle_open and menu._buttons.filter(func(b): return b.target >= Menu.SUBTITLE_POSITION and b.target < Menu.SUBTITLE_POSITION + 5).size() == 5,
		"VR CC popup includes all five subtitle positions")
	check(click(menu, Menu.SUBTITLE_POSITION + 2) and video.subtitle_position == 2 and main.settings.get_value("subtitles", "position") == 2 and menu._subtitle_open,
		"CC position selection applies and persists while keeping the popup open")
	check(choose_setting(menu, "subtitle_distance", 2.0) and video.subtitle_distance == 2.0 and menu._subtitle_open,
		"CC distance selection applies without closing subtitle controls")
	check(host.calls.size() == layout_calls, "Changing subtitle layout never switches tracks or rebuilds playback")
	check(click(menu, 110) and click(menu, 11) and click(menu, 104), "Settings opens the shared VR subtitle editor")
	check(click(menu, 444) and video.subtitle_position == 4 and main._library_settings().subtitle_position == 4
		and main.settings.get_value("subtitles", "position") == 4, "Playback and global settings share subtitle position")
	main._on_setting_changed("subtitle_position", 0)
	menu.refresh_values()
	check(menu._buttons.filter(func(b): return b.target == 440)[0].base_color == Menu.SELECTED,
		"External position changes refresh the active editor's selected chip")
	check(click(menu, 400) and click(menu, 10), "Return from subtitle editor to transport bar")
	# Lock: a lit tile pressed again locks projection and layout, both marked; again unlocks.
	var locks := func() -> int:
		var count := 0
		for b in menu._buttons:
			for child in b.node.get_children():
				if child is MeshInstance3D and child.material_override is StandardMaterial3D 					and child.material_override.albedo_texture == preload("res://scripts/menu_icons.gd").texture("lock"):
					count += 1
		return count
	check(click(menu, Menu.MODE) and locks.call() == 0 and video.mode_lock.is_empty(), "Unlocked by default")
	check(click(menu, Menu.MODE_PROJECTION + 1) and video.mode_lock == {"geometry": 1, "layout": 1, "depth": false, "fisheye_fov": 180}
		and locks.call() == 2 and main.settings.get_value("video", "mode_lock") == video.mode_lock, "Second press on 180 locks 180 + SBS, both tiles marked, saved")
	check(click(menu, Menu.MODE_STEREO + 1) and video.mode_lock.is_empty() and locks.call() == 0, "Pressing a locked tile unlocks")
	check(click(menu, Menu.MODE_STEREO + 1) and video.mode_lock.layout == 1 and click(menu, Menu.MODE), "Either lit tile locks")
	# Volume: the sound icon raises a vertical slider; its bottom mutes and keeps the level.
	check(click(menu, 109) and menu._volume_open and menu._buttons.any(func(b): return b.target == Menu.VOLUME), "Sound icon opens the volume slider")
	var span: Vector2 = Menu.VOLUME_SPAN
	check(press_at(menu, Menu.VOLUME_X, span.x + (span.y - span.x) * 0.9) and video.audio_volume == 90.0 and host.calls.back() == ["audio", 7, video.audio_track_id, 90.0, false], "Slider press sets the MPV volume")
	menu.update_pointer("right_hand", menu.to_global(Vector3(Menu.VOLUME_X, span.x + (span.y - span.x) * 0.4, 1)), -menu.global_basis.z, true)
	check(video.audio_volume == 40.0 and not video.audio_muted, "Dragging with the trigger held follows the ray")
	menu.update_pointer("right_hand", menu.to_global(Vector3(Menu.VOLUME_X, span.x - 0.2, 1)), -menu.global_basis.z, true)
	check(video.audio_muted and video.audio_volume == 40.0 and menu._sound_icon() == "mute", "Dragging past the bottom mutes and keeps the level")
	menu.release_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
	var calls_after_release := host.calls.size()
	menu.update_pointer("right_hand", menu.to_global(Vector3(Menu.VOLUME_X, span.y, 1)), -menu.global_basis.z, true)
	check(host.calls.size() == calls_after_release, "Released trigger stops the drag")
	check(press_at(menu, Menu.VOLUME_X, span.x + (span.y - span.x) * 0.3) and not video.audio_muted and video.audio_volume == 30.0 and menu._sound_icon() == "volume_low", "Raising the slider unmutes")
	menu.release_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
	check(click(menu, 109) and not menu._volume_open, "Sound icon closes the slider")
	check(click(menu, 11) and click(menu, 12) and menu.section == 2 and menu.text_snapshot().contains("3840 x 1920 | hevc"), "Info tab shows source properties from actual player")
	check(not click(menu, 100), "Unavailable Android plugin disables device refresh")
	video.picker_error = "PERMISSION_LOST"
	menu.refresh_values()
	check(menu.text_snapshot().contains("PERMISSION_LOST"), "Action error remains visible in Info")
	video.picker_error = "LOCAL_DOCUMENT_PERMISSION_LOST"
	menu.refresh_values()
	check(menu.text_snapshot().contains("File access lost. Select the video again"), "Actual Android preflight permission code gives recovery instruction")
	video.picker_error = "LOCAL_DOCUMENT_MISSING"
	menu.refresh_values()
	check(menu.text_snapshot().contains("Video no longer exists"), "Actual Android preflight missing code stays distinct from permission loss")
	main._on_controller_button("ax_button", "right_hand")
	check(menu.visible and host.calls.back()[0] != "pick", "Controller A cannot open a file through menu")
	main._process(1.0 / 72.0)
	check(menu.section == 2, "Menu ignores absent/zero tracking axes")
	check(click(menu, Menu.CLOSE) and not menu.visible, "Close button dismisses controls overlay")
	main._on_controller_button("menu_button", "left_hand")
	check(menu.visible and menu.section == 0, "Menu button reopens controls on Playback")
	main._on_controller_button("menu_button", "left_hand")
	check(not menu.visible, "Second menu button dismisses controls")
	# Dragging the picture: the flat screen swings around the eyes at its distance, still facing them.
	menu.dismiss()
	video.geometry = video.Geometry.Geometry.FLAT
	video._apply_geometry()
	video.flat_pose = Transform3D(Basis(), Vector3(0, 1.6, -2))
	video.panel.transform = video.flat_pose
	main._turn_picture(PI / 2, 0.0)
	var screen: Vector3 = video.panel.global_position
	check(screen.distance_to(Vector3(-2, 1.6, 0)) < 0.001 and video.panel.global_basis.z.distance_to(Vector3.RIGHT) < 0.001,
		"Flat screen drag swings it around the head, facing the eyes: %s" % screen)
	main._turn_picture(0.0, 0.3)
	check(absf(video.panel.global_position.distance_to(Vector3(0, 1.6, 0)) - 2.0) < 0.001 and video.panel.global_position.y > 2.1,
		"Dragging up raises the screen at the same distance")
	# Flat screen distance, size and curve.
	video.flat_pose = Transform3D(Basis(), Vector3(0, 1.6, -2))
	video.panel.transform = video.flat_pose
	main._push_screen(1.0)
	check(video.panel.global_position.distance_to(Vector3(0, 1.6, -3)) < 0.001 and is_equal_approx(video.screen_distance, 3.0),
		"Pushing the held screen moves it away along the line of sight")
	main._push_screen(-10.0)
	check(is_equal_approx(video.screen_distance, video.DISTANCE_LIMITS.x), "The screen cannot come closer than the limit")
	main._push_screen(2.0 - video.DISTANCE_LIMITS.x)
	var size: Vector2 = video._flat.size
	video.panel.visible = true # as once frames show
	var eye := Vector3(0, 1.6, 0)
	var corner: Vector3 = video.panel.global_transform * video.screen_corner(1)
	check(video.corner_at(eye, corner - eye) == 1 and video.corner_at(eye, Vector3.FORWARD) == -1, "A ray at the top-right corner finds it, the centre does not")
	video.set_corner_hover(1)
	check(video._handles[1].visible and not video._handles[0].visible, "Only the pointed corner shows its bracket")
	video.set_screen_scale(1.5)
	check(video._flat.size.is_equal_approx(size * 1.5), "Corner drag scales the screen")
	video.set_screen_scale(10.0)
	check(is_equal_approx(video.screen_scale, video.SCALE_LIMITS.y), "Size is limited")
	video.set_screen_scale(1.0)
	video.set_corner_hover(-1)
	video.set_screen_curve(1.0)
	var bent: Vector3 = video.screen_corner(1)
	check(video.panel.mesh is ArrayMesh and bent.z > 0.05 and bent.x < size.x * 0.5 and video.screen_corner(0).x == -bent.x,
		"A curved screen bends its sides towards the viewer: %s" % bent)
	check(absf(video.panel.global_transform.origin.distance_to(eye) - 2.0) < 0.001, "Curving keeps the centre in place")
	main._on_menu_action("screen_curve")
	check(video.screen_curve == 0.0 and video.panel.mesh == video._flat, "The curve cycles back to a flat screen")
	main._on_menu_action("screen_curve")
	check(video.screen_curve == video.CURVES[1], "Curve steps from the player settings")
	video.set_screen_curve(0.0)
	video.set_screen_scale(2.0)
	main._push_screen(3.0)
	main._reset_picture()
	check(video.screen_scale == 1.0 and video.screen_distance == video.SCREEN_DISTANCE, "Right stick press restores size and distance")
	# Immersive: the sphere turns with the drag and the stick moves it nearer; the right stick press resets.
	video.set_projection(1)
	main._turn_picture(0.4, -0.2)
	check(is_equal_approx(video.view_yaw, 0.4) and is_equal_approx(video.view_pitch, -0.2), "VR drag turns the view")
	main._apply_stick_actions([{"operation": "zoom", "amount": 1.0}], 0.5)
	check(video.view_zoom > 0.2 and video.panel.global_position.distance_to(Vector3(0, 1.6, 0)) > 5.0, "Pushing the stick brings the picture nearer")
	main._apply_stick_actions([{"operation": "zoom", "amount": 1.0}], 10.0)
	check(video.view_zoom == video.ZOOM_LIMITS.y, "Zoom is limited")
	main._on_controller_button("primary_click", "right_hand")
	check(video.view_yaw == 0.0 and video.view_pitch == 0.0 and video.view_zoom == 0.0, "Right stick press straightens the view")
	video.set_projection(0)
	main._show_player_menu()
	check(click(menu, 107) and video.media.state == "closed" and host.calls.back() == ["close", 7], "Close video uses production close/cancel sequence")
	check(not click(menu, 102), "Play disabled after close even if URI retained for recovery")
	video.open_local("file:///lock/plain.mp4", "plain.mp4")
	check(video.geometry == 1 and video.stereo_sbs and not video.top_bottom and video._layout_pending == null, "Locked mode opens an unnamed new file")
	video.open_local("file:///lock/trip_TB.mp4", "trip_TB.mp4")
	check(video.top_bottom and video.geometry == 0, "A VR-named file follows its name, not the lock")
	video.open_local("file:///menu.mp4", "测试电影 😀")
	check(video.geometry == 3 or video.geometry == 1, "A remembered file keeps its own mode")
	video.load_mode_lock({"geometry": 9, "layout": 1, "depth": false, "fisheye_fov": 180})
	check(video.mode_lock.is_empty(), "A malformed stored lock is ignored")
	video.open_local("file:///sticky/first_2D.mp4", "first_2D.mp4")
	main._on_depth_strength(1.65, false)
	video.open_local("file:///sticky/next_2D.mp4", "next_2D.mp4")
	check(video.auto_depth and video.depth_requested and is_equal_approx(video.depth_strength, 1.65), "Next 2D video retains conversion and non-preset strength")
	video.open_local("file:///sticky/stereo_SBS.mp4", "stereo_SBS.mp4")
	check(video.stereo_sbs and not video.depth_requested and video.auto_depth, "Stereo video bypasses inference without erasing choice")
	video.open_local("file:///sticky/flat_2D.mp4", "flat_2D.mp4")
	check(video.depth_requested and is_equal_approx(video.depth_strength, 1.65), "Following flat video restores strength")
	main._on_depth_strength(0.0, false)
	video.open_local("file:///sticky/first_2D.mp4", "first_2D.mp4")
	check(not video.depth_requested and not video.auto_depth, "Manual Off wins over a file's previous 3D memory")
	main.settings.set_value("video", "mode_lock", {})
	main.settings.save(main.settings_path)
	_check_device_status()
	video.open_local("file:///menu.mp4", "测试电影 😀")
	menu.section = 0
	main.video_queue = [{"uri": "file:///menu.mp4", "title": "测试电影 😀"}, {"uri": "file:///next.mp4", "title": "Next"}]
	menu.refresh()
	check(not click(menu, 101), "First video disables previous")
	check(click(menu, 103) and video.local_uri == "file:///next.mp4" and host.calls.any(func(c): return c[0] == "open" and c[1] == "file:///next.mp4"), "Pointer next opens the next video through the production backend")
	check(not click(menu, 103) and menu.visible, "Last video disables next and keeps controls open")
	check(click(menu, 101) and video.local_uri == "file:///menu.mp4", "Pointer previous returns to the original video")
	check(menu._tips[101] == "Previous video" and menu._tips[103] == "Next video", "Navigation tooltips replace seek labels")
	check(menu._buttons.filter(func(b): return b.target == 101)[0].node.get_child(1).material_override.albedo_texture == menu.Icons.texture("previous_video"), "Previous button uses the skip icon")
	check(menu._buttons.filter(func(b): return b.target == 103)[0].node.get_child(1).material_override.albedo_texture == menu.Icons.texture("next_video"), "Next button uses the skip icon")
	main.video_queue.clear()
	menu.refresh_values()
	var navigation_calls := host.calls.size()
	check(not click(menu, 101) and not click(menu, 103) and host.calls.size() == navigation_calls, "A video opened without a browse queue cannot navigate or seek via skip buttons")
	_check_control_sticks(main, video, menu, host)
	video.free()
	menu.free()
	recent.free()
	main.free()
	var report := {"state": "passed" if failures.is_empty() else "failed", "checks": checks, "failures": failures,
		"scope": "Production ray menus/Main/MPV video state and commands with mocked Android backend; physical Quest controls and native playback not verified"}
	FileAccess.open(directory.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	for failure in failures: push_error(failure)
	print("Player menu host checks: %s (%d), evidence=%s" % [report.state, checks, directory])
	quit(0 if failures.is_empty() else 1)

## Feed the production per-frame routing with real menus/video state and a mocked Android backend.
func _check_control_sticks(main: Node3D, video: Node3D, menu: Node3D, host: RefCounted) -> void:
	video.geometry = 0
	video._waiting_first = false
	video.requested_play = true
	video.media.state = "playing"
	video.control.reject()
	video.control.observe(40000, 120000)
	video.media.playback = {"details": {"audio_tracks": [{"id": 1}], "subtitle_tracks": []}}
	for index in 9: video.media.playback.details.subtitle_tracks.append({"id": index + 1, "codec": "subrip"})
	menu._reset_navigation()
	menu.visible = true
	menu.refresh()
	main._menu_touched_ms = Time.get_ticks_msec()
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	main._process_sticks(Vector2(.99, 0), Vector2(-.99, 0), 0.1)
	check(video.control.target_ms == 50000 and menu._elapsed.text == "00:50", "Visible transport bar dispatches left +20s and right -10s and immediately displays the target")
	var calls: int = host.calls.size()
	main._process_sticks(Vector2(.99, 0), Vector2(-.99, 0), 0.1)
	check(host.calls.size() == calls, "Holding visible-bar sticks does not repeat seeks")
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	main._process_sticks(Vector2(-.99, 0), Vector2(.99, 0), 0.1)
	check(video.control.target_ms == 40000 and menu._elapsed.text == "00:40", "Recentered sticks reverse direction with their original step sizes")
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	video.audio_volume = 50.0
	main._process_sticks(Vector2(0, .99), Vector2.ZERO, 0.1)
	check(video.audio_volume == 60.0, "Visible transport bar retains left vertical volume")
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	video.geometry = 1
	var zoom: float = video.view_zoom
	main._process_sticks(Vector2.ZERO, Vector2(0, .9), 0.2)
	main._process_sticks(Vector2.ZERO, Vector2(0, .9), 0.2)
	check(video.view_zoom > zoom and main.stick_controls.right_zooming, "Visible immersive controls retain continuous right vertical zoom")
	video.geometry = 0
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	# Lists and settings consume the same axes without playback side effects.
	menu._subtitle_open = true
	menu.refresh()
	calls = host.calls.size()
	main._process_sticks(Vector2(0, -.99), Vector2(.99, 0), 1.0)
	check(menu._subtitle_offset > 0 and host.calls.size() == calls, "Subtitle popup scrolls without volume or seek commands")
	menu._subtitle_open = false
	menu.refresh()
	main._process_sticks(Vector2.ZERO, Vector2(.99, 0), 0.1)
	check(host.calls.size() == calls, "Closing a list with a held stick cannot cause a seek")
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	menu._activate(111)
	main._process_sticks(Vector2(0, -.99), Vector2(.99, 0), 0.5)
	check(menu.choices.opened == "audio_track" and host.calls.size() == calls, "Audio track popup owns sticks without selecting, seeking or changing volume")
	menu.choices.reset(); menu.refresh()
	main._process_sticks(Vector2.ZERO, Vector2(.99, 0), 0.1)
	check(host.calls.size() == calls, "Audio popup exit also requires stick recenter before playback shortcuts")
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	video.bookmark_store.add(video.local_uri, str(video._bookmark_metadata.get("basename", "")), video._bookmark_metadata.get("size", -1), 1000)
	menu.bookmarks.opened = true
	menu.refresh()
	main._process_sticks(Vector2(.99, 0), Vector2(0, .99), 0.2)
	check(host.calls.size() == calls and not main.stick_controls.right_zooming, "Bookmark list also owns the sticks")
	menu.bookmarks.opened = false
	menu.section = 1
	menu.refresh()
	main._process_sticks(Vector2(.99, 0), Vector2(.99, 0), 0.1)
	check(host.calls.size() == calls, "Expanded settings cannot seek")
	menu.section = 0
	menu._mode_open = true
	menu.refresh()
	main._process_sticks(Vector2(.99, 0), Vector2(.99, 0), 0.1)
	check(host.calls.size() == calls, "Projection popup cannot seek")
	menu._mode_open = false
	menu.refresh()
	var original_recent: Node3D = main.recent_menu
	var library := Library.new()
	library.section = Library.Section.LOCAL
	for index in 30: library._local_entries.append({"uri": "file:///item%d.mp4" % index, "title": "Video %d" % index})
	root.add_child(library)
	main.recent_menu = library
	library.toggle()
	main._process_sticks(Vector2(0, -.99), Vector2(.99, 0), 0.3)
	check(library.scroll > 0 and host.calls.size() == calls, "Media library scrolls without controlling the current video")
	library.dismiss()
	main.recent_menu = original_recent
	library.free()
	# Actual ray timeline capture remains exclusive, including the other hand's stick.
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	var origin: Vector3 = menu.to_global(Vector3(0, -0.08, 0.1))
	var direction: Vector3 = -menu.global_basis.z
	main.test_rays.left_hand = [origin, direction]
	main.stick_controls.right_zooming = true
	check(main._update_menu_pointer("left_hand", true), "Timeline press starts a real pointer capture through Main")
	check(main.stick_controls.left_latched and main.stick_controls.right_latched and not main.stick_controls.right_zooming, "Capture suspends sticks immediately before the next process frame")
	main._process_sticks(Vector2.ZERO, Vector2(.99, 0), 0.1)
	check(host.calls.size() == calls and not menu.allows_playback_sticks(), "Timeline drag blocks the other stick without submitting the preview")
	menu.release_pointer("left_hand", origin, direction, true)
	main.test_rays.clear()
	calls = host.calls.size()
	main._process_sticks(Vector2.ZERO, Vector2(.99, 0), 0.1)
	check(video.control.target_ms == 60000 and host.calls.size() == calls, "Capture release submits its own target; held stick remains blocked until center")
	for property in ["_volume_hand", "_depth_hand", "_adjust_hand"]:
		menu.set(property, "left_hand")
		check(menu.has_pointer_capture() and not menu.allows_playback_sticks(), "Slider capture disables playback sticks: " + property)
		menu.set(property, "")
	menu.bookmarks.capture = {"hand": "left_hand"}
	check(menu.has_pointer_capture() and not menu.allows_playback_sticks(), "Bookmark press also captures playback input")
	menu.bookmarks.capture.clear()
	main.test_rays.left_hand = [origin, direction]
	main._update_menu_pointer("left_hand", true)
	main.test_rays.clear()
	main._process_sticks(Vector2.ZERO, Vector2(.99, 0), 0.1)
	check(menu._seek_hand.is_empty() and host.calls.size() == calls, "Tracking cancellation before the first capture frame cannot turn a held stick into a seek")
	# Focus and hidden transport behavior share the same latch state.
	main.display.preview = false
	main.display.session_state = "session_visible"
	main._process_sticks(Vector2.ZERO, Vector2(.99, 0), 0.1)
	main.display.preview = true
	main._process_sticks(Vector2.ZERO, Vector2(.99, 0), 0.1)
	check(host.calls.size() == calls, "Focus recovery with a held stick waits for center")
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	main._menu_touched_ms = Time.get_ticks_msec() - main.CONTROLS_HIDE_MS - 1
	main._process_sticks(Vector2.ZERO, Vector2(.99, 0), 0.1)
	check(menu.visible and menu._elapsed.text == "01:10" and Time.get_ticks_msec() - main._menu_touched_ms < 1000, "A visible-bar seek refreshes feedback and resets its hide timer")
	menu.dismiss()
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	main._process_sticks(Vector2(-.99, 0), Vector2.ZERO, 0.1)
	check(video.control.target_ms == 50000, "Hidden transport retains the same left -20s seek")
	# Hover misses are not interaction, paused/awaiting seeks keep their controls visible.
	menu.toggle()
	video.control.reject()
	video.control.observe(50000, 120000)
	video.requested_play = false
	main._menu_touched_ms = Time.get_ticks_msec() - main.CONTROLS_HIDE_MS - 1
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	check(menu.visible, "Paused video does not hide controls")
	video.requested_play = true
	video.control.seek_absolute(55000)
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	check(menu.visible, "Queued seek keeps the target visible")
	video.control.take_pending()
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	check(menu.visible, "Waiting for a new source frame keeps controls visible")
	video.control.reject()
	main.test_rays.right_hand = [menu.to_global(Vector3(0, 0.025, 0.1)), direction]
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	check(menu.visible and Time.get_ticks_msec() - main._menu_touched_ms < 1000, "A real button hover resets the idle timer")
	main.test_rays.clear()
	main._menu_touched_ms = Time.get_ticks_msec() - main.CONTROLS_HIDE_MS - 1
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	check(not menu.visible and menu._hover.is_empty(), "Playing video hides after inactivity even when both rays recorded NONE")
