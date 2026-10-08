extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
const Main := preload("res://scripts/main.gd")
const Player := preload("res://scripts/player_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const Policy := preload("res://scripts/seek_policy.gd")
const Store := preload("res://scripts/bookmark_store.gd")
var checks := 0
var failures: Array[String] = []

class BindingProbe extends "res://scripts/pair_texture_binding.gd":
	func bind(target: ShaderMaterial, pair: Dictionary) -> bool:
		material = target; ticket = pair.duplicate(true); return true

class Host extends RefCounted:
	var opens: Array = []
	var revisions: Array = []
	var pair: Dictionary = {}
	func mpv_supported() -> bool: return true
	func open_mpv_video(uri: String, start: int, _stereo: bool, _profile: String, _alpha: bool, _vulkan: bool,
		_depth: bool, _tb: bool, exact: bool) -> int:
		opens.append([uri, start, exact]); return 7
	func revise_mpv_video(id: int, _stereo: bool, _alpha: bool, _profile: String, target: int,
		_depth: bool, _tb: bool, exact: bool) -> int:
		revisions.append([id, target, exact]); return 0 # Keep the request queued to exercise busy retries.
	func set_mpv_playing(_id: int, _playing: bool) -> void: pass
	func close_mpv_video(_id: int) -> void: pass
	func claim_mpv_pair(_id: int, _token: int) -> String: return JSON.stringify(pair)
	func acknowledge_mpv_pair(_id: int, _token: int) -> bool: return true
	func detach_mpv_pair(_id: int, _token: int) -> bool: return true

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func origin(menu: Node3D, target: int) -> Vector3:
	for button in menu._buttons:
		if button.target == target:
			return menu.to_global(Vector3(button.rect.get_center().x, button.rect.get_center().y, 1))
	return Vector3.ZERO

func tap(menu: Node3D, target: int) -> void:
	var point := origin(menu, target)
	menu.press_pointer("left_hand", point, -menu.global_basis.z, true)
	menu.release_pointer("left_hand", point, -menu.global_basis.z, true)

func clear_pending(video: Node3D) -> void:
	video.control.reject(); video._pending_revision.clear(); video._waiting_first = false

func labels(menu: Node) -> String:
	return "\n".join(menu.find_children("*", "Label3D", true, false).map(func(label): return label.text))

func choose(menu: Node3D, key: String, value: Variant) -> void:
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.get("kind") == "open" and item.get("key") == key:
			tap(menu, int(target)); break
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.get("kind") == "choose" and item.get("key") == key and menu.choices.same(item.value, value):
			tap(menu, int(target)); return

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	preload("res://scripts/i18n.gd").use("zh")
	var directory := ProjectSettings.globalize_path("res://../../artifacts/seek-policy-host/" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(directory)
	var bridge := Host.new()
	var video := Video.new()
	root.add_child(video); video.set_process(false)
	video.platform = bridge; video.bookmark_store = Store.new(directory.path_join("bookmarks"))
	video._binding = BindingProbe.new()
	var main := Main.new()
	main.video = video; main.settings_path = directory.path_join("settings.cfg")
	main._restore_seek_settings()
	check(video.seek_mode == Policy.SPEED and video.bookmark_seek_mode == Policy.GLOBAL, "New and existing empty settings default to speed and inherited bookmark mode")
	check(Policy.normalize(null) == Policy.SPEED and Policy.normalize(17) == Policy.SPEED and Policy.normalize("bad") == Policy.SPEED,
		"Invalid stored global settings fall back to speed")
	check(Policy.bookmark_override("bad") == Policy.GLOBAL, "Invalid bookmark override inherits global")
	var uri := "https://fixture.example/mock.mp4"
	video.open_local(uri, "Movie", 12000, false)
	check(bridge.opens.back() == [uri, 12000, false], "Initial and resumed opening propagate keyframe mode to Android")
	main._on_setting_changed("seek_mode", Policy.EXACT)
	video.open_local(uri, "Movie", 12000, false)
	check(bridge.opens.back() == [uri, 12000, true], "Precise preference propagates to initial/resumed opening")
	video.control.observe(5000, 60000)
	video.seek_relative(10000)
	check(bridge.revisions.back() == [7, 15000, true], "Forward shortcut uses precise preference")
	clear_pending(video)
	video.seek_relative(-1000)
	check(bridge.revisions.back() == [7, 4000, true], "Backward shortcut uses precise preference")
	clear_pending(video)
	main._on_setting_changed("seek_mode", Policy.SPEED)
	main._on_menu_seek(23456)
	check(bridge.revisions.back() == [7, 23456, false], "Timeline route propagates speed without changing the requested timestamp")
	main._on_setting_changed("seek_mode", Policy.EXACT)
	video._try_revision()
	check(bridge.revisions.back() == [7, 23456, false], "A queued target retains its captured policy across a setting change")
	video.seek_relative(10000)
	check(bridge.revisions.back() == [7, 33456, true], "New coalesced shortcut takes the latest preference and replaces its target")
	clear_pending(video)
	video.media.playback = {"details": {"seekable": "yes", "partially_seekable": "no"}}
	video.media.state = "paused"
	video._bookmark_metadata = {"basename": "mock.mp4", "size": 123456}
	video._bookmark_resolve()
	var marker := video.bookmark_store.add(uri, "mock.mp4", 123456, 23456)
	var scope: String = video.bookmark_scope()
	video.bookmark_action("seek", str(marker.id), scope)
	check(bridge.revisions.back() == [7, 23456, true], "Inherited bookmark follows global precise mode")
	clear_pending(video)
	main._on_setting_changed("seek_mode", Policy.SPEED)
	video.bookmark_action("seek", str(marker.id), scope)
	check(bridge.revisions.back() == [7, 23456, false], "Inherited bookmark follows a later global speed change")
	clear_pending(video)
	main._on_bookmark_mode_requested(Policy.EXACT, scope)
	video.bookmark_action("seek", str(marker.id), scope)
	check(bridge.revisions.back() == [7, 23456, true] and video.seek_mode == Policy.SPEED, "Independent bookmark precise override leaves global speed unchanged")
	clear_pending(video)
	main._on_setting_changed("seek_mode", Policy.EXACT)
	main._on_bookmark_mode_requested(Policy.SPEED, scope)
	video.bookmark_action("seek", str(marker.id), scope)
	check(bridge.revisions.back() == [7, 23456, false] and video.seek_mode == Policy.EXACT, "Independent bookmark speed override leaves global precise unchanged")
	clear_pending(video)
	check(video.bookmark_store.list_markers(video._bookmark_media_id)[0].position_ms == 23456, "Mode changes never snap or rewrite the saved bookmark")
	main._on_bookmark_mode_requested(Policy.EXACT, "stale")
	main._on_bookmark_mode_requested("bad", scope)
	check(video.bookmark_seek_mode == Policy.SPEED, "Stale scope and invalid UI mode cannot alter bookmark preference")
	var restored := ConfigFile.new()
	check(restored.load(main.settings_path) == OK, "Preferences are saved to disk")
	main.settings = restored; video.seek_mode = Policy.SPEED; video.bookmark_seek_mode = Policy.GLOBAL
	main._restore_seek_settings()
	check(video.seek_mode == Policy.EXACT and video.bookmark_seek_mode == Policy.SPEED, "Startup restoration preserves both independent preferences")

	var player := Player.new()
	player.state_provider = func():
		return video.bookmarks_snapshot().merged({"has_video": true, "duration_ms": 60000, "position_ms": video.control.display_position_ms(), "title": "Movie"})
	player.seek_requested.connect(main._on_menu_seek)
	player.action_requested.connect(main._on_menu_action)
	player.setting_requested.connect(main._on_player_setting)
	player.bookmark_mode_requested.connect(main._on_bookmark_mode_requested)
	root.add_child(player); player.toggle(); player.set_process(false)
	player.bookmarks.opened = true; player.refresh()
	tap(player, player.BookmarkMenu.MODE_EXACT)
	check(video.bookmark_seek_mode == Policy.EXACT and video.seek_mode == Policy.EXACT, "Bookmark mode is selectable by real ray/trigger release")
	tap(player, player.BookmarkMenu.MODE_GLOBAL)
	main._on_setting_changed("seek_mode", Policy.SPEED)
	player.refresh_values()
	check(video.bookmark_seek_mode == Policy.GLOBAL and player._tips[player.BookmarkMenu.MODE_GLOBAL].contains("速度"), "Open inherited list reflects the changed global setting")
	var point := origin(player, player.BookmarkMenu.MODE_EXACT)
	player.press_pointer("left_hand", point, -player.global_basis.z, true)
	check(player.has_pointer_capture() and not player.allows_playback_sticks(), "Mode selector captures input and blocks playback shortcuts")
	player.release_pointer("right_hand", point, -player.global_basis.z, true)
	check(video.bookmark_seek_mode == Policy.GLOBAL, "Other hand cannot commit bookmark precision")
	player.cancel_pointer("left_hand")
	check(video.bookmark_seek_mode == Policy.GLOBAL, "Cancelled selector leaves precision unchanged")
	player.bookmarks.opened = false; player.section = 1; player.refresh()
	choose(player, "seek_mode", Policy.EXACT)
	check(video.seek_mode == Policy.EXACT and labels(player).contains("视频时间定位") and labels(player).contains("精确"),
		"Playback settings switch the shared global preference with user-facing labels")
	var library := Library.new()
	library.section = Library.Section.SETTINGS; library.tab = Library.VIDEO_TAB
	library.settings_provider = func(): return {"seek_mode": video.seek_mode}
	library.setting_changed.connect(main._on_setting_changed)
	root.add_child(library); library.toggle(); library.set_process(false)
	check(library.rows[0].key == "seek_mode" and library.rows[0].choices.size() == 2 and library.rows.size() == 2,
		"Global settings group both seek choices into one row alongside one resolution field")
	choose(library, "seek_mode", Policy.SPEED)
	check(video.seek_mode == Policy.SPEED and library.rows[0].value == Policy.SPEED and labels(library).contains("时间可能有偏差"),
		"Global settings ray selection applies speed and explains the precision tradeoff")

	clear_pending(video)
	video.control.observe(1000, 60000)
	video.seek_absolute(5500)
	video.control.take_pending(); video._pending_revision.clear()
	bridge.pair = {"session_id": 7, "logical_session_id": 7, "generation": 1,
		"format_revision": 1, "effect_revision": 1, "model_generation": 1,
		"frame_id": 70, "pts_us": 4000000, "source_epoch": 2, "slot_token": 10,
		"width": 8192, "height": 4096, "alpha_requested": false, "inference_ran": false,
		"source_pts_verified": true}
	video._pending_pair = bridge.pair
	video._present_pending()
	check(video.control.target_ms == 5500 and video.control.observed_position_ms == 4000 and video.control.display_position_ms() == 4000,
		"Actual first keyframe updates the timeline to its source PTS while preserving the requested target")
	video._on_state(7, JSON.stringify({"state": "paused", "details": {"position_seconds": "5.5", "duration_seconds": "60"}}))
	check(video.control.observed_position_ms == 4000 and video.control.display_position_ms() == 4000,
		"A later MPV request clock cannot overwrite the actual paused keyframe position")
	video.seek_relative(10000)
	check(bridge.revisions.back() == [7, 14000, false], "Next shortcut starts from the actual landed frame, not the previous desired time")
	main._on_player_setting("screen_curve", 0.7)
	check(video.screen_curve == 0.7 and video.panel.mesh == video._curved, "Screen curve dropdown rebuilds actual flat-screen geometry")
	video._binding.ticket.clear()
	video.platform = null
	library.free(); player.free(); main.free(); video.free()
	print("Seek policy checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
