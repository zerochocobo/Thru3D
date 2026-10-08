extends SceneTree
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Store := preload("res://scripts/bookmark_store.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var accepted := true
	var calls: Array = []
	func set_mpv_audio(id: int, track: int, volume: float, muted: bool) -> bool:
		calls.append([id, track, volume, muted]); return accepted
	func close_mpv_video(_id: int) -> void: pass

func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures.append(text)

func button(menu: Node3D, target: int) -> Dictionary:
	for item in menu._buttons:
		if item.target == target: return item
	return {}

func point(menu: Node3D, target: int) -> Vector3:
	var item := button(menu, target)
	return item.node.to_global(Vector3(0, 0, 1)) if not item.is_empty() else Vector3.ZERO

func tap(menu: Node3D, target: int) -> void:
	var origin := point(menu, target)
	menu.press_pointer("left_hand", origin, -menu.global_basis.z, true)
	menu.release_pointer("left_hand", origin, -menu.global_basis.z, true)

func choice(menu: Node3D, value: int) -> int:
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.kind == "choose" and int(item.value) == value: return target
	return -1

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	I18n.use("en")
	var directory := ProjectSettings.globalize_path("res://../../artifacts/audio-popup-host/" + str(Time.get_ticks_usec()))
	var video := Video.new()
	video.bookmark_store = Store.new(directory.path_join("bookmarks"))
	root.add_child(video); video.set_process(false)
	var host := Host.new(); video.platform = host
	video.local_uri = "file:///movie.mp4"; video.media.begin(7); video.media.state = "playing"
	video.control.duration_ms = 7200000
	video._bookmark_metadata = {"basename": "movie.mp4", "size": 1000000}; video._bookmark_resolve()
	video.media.playback = {"details": {"audio_track_id": "1", "audio_tracks": [
		{"id": 1, "language": "eng"}, {"id": 2, "language": "jpn"}]}}
	var main := Main.new(); main.video = video; main.settings_path = directory.path_join("settings.cfg")
	var menu := Menu.new(); main.player_menu = menu
	menu.state_provider = main._menu_state
	menu.setting_requested.connect(main._on_player_setting)
	menu.bookmark_requested.connect(main._on_bookmark_request)
	root.add_child(menu); menu.toggle(); menu.set_process(false)
	check(button(menu, menu.BookmarkMenu.LIST).is_empty(), "Empty movie hides bookmark-list button")
	var audio := button(menu, 111)
	var add := button(menu, menu.BookmarkMenu.ADD)
	check(not audio.is_empty() and audio.enabled and menu._tips[111] == "Audio track", "Audio icon is present without a dubbed sidecar")
	check(add.rect.get_center().x > audio.rect.get_center().x and is_equal_approx(add.rect.get_center().y, audio.rect.get_center().y), "Add bookmark is immediately right of audio on the control bar")
	check(add.rect.position.x > audio.rect.end.x and add.rect.end.x < button(menu, 101).rect.position.x, "Audio/add/previous ray hit areas do not overlap")
	var marker := video.bookmark_store.add(video.local_uri, "movie.mp4", 1000000, 10000)
	menu.refresh_values()
	check(not button(menu, menu.BookmarkMenu.LIST).is_empty(), "First bookmark automatically reveals list entry")
	tap(menu, menu.BookmarkMenu.LIST); tap(menu, menu.BookmarkMenu.DELETE)
	check(button(menu, menu.BookmarkMenu.LIST).is_empty() and not menu.bookmarks.opened and video.bookmark_store.can_undo(), "Deleting final bookmark hides entry and closes list but keeps undo")
	tap(menu, menu.BookmarkMenu.UNDO)
	check(not button(menu, menu.BookmarkMenu.LIST).is_empty() and video.bookmark_store.list_markers(video._bookmark_media_id)[0].id == marker.id, "Undo automatically restores list entry")
	tap(menu, 111)
	check(menu.choices.opened == "audio_track" and not menu.allows_playback_sticks(), "Audio popup blocks playback stick shortcuts")
	check(menu.text_snapshot().contains("movie.si.mix.m4a") and menu.choices.popup.choices.size() == 4, "No-sidecar popup explains sibling naming and keeps all audio choices")
	check(menu.choices.popup.choices.any(func(item): return str(item.label).contains("English")) and menu.choices.popup.choices.any(func(item): return str(item.label).contains("Japanese")), "Foreign audio tracks show language labels")
	var angled_origin := menu.to_global(Vector3(0, 0, 0.5))
	var angled_direction: Vector3 = (button(menu, choice(menu, 2)).node.global_position - angled_origin).normalized()
	menu.press_pointer("left_hand", angled_origin, angled_direction, true)
	menu.update_pointer("left_hand", angled_origin, angled_direction, true)
	check(not menu.choices.capture.get("moved", false), "Stationary angled ray does not falsely become a drag on raised popup plane")
	menu.cancel_pointer("left_hand")
	main._menu_touched_ms = Time.get_ticks_msec() - main.CONTROLS_HIDE_MS - 1
	menu._hover.clear(); main._update_controls_visibility(menu)
	check(menu.visible, "An idle open audio list does not auto-hide")
	var before := host.calls.size()
	var selected := choice(menu, 2); var origin := point(menu, selected)
	menu.press_pointer("left_hand", origin, -menu.global_basis.z, true)
	menu.release_pointer("right_hand", origin, -menu.global_basis.z, true)
	check(host.calls.size() == before, "Other hand cannot commit captured audio choice")
	menu.release_pointer("left_hand", origin, -menu.global_basis.z, true)
	check(host.calls.back() == [7, 2, video.audio_volume, video.audio_muted] and menu.choices.opened.is_empty(), "Owning release selects exact native track ID and closes popup")
	check(video.media.session_id == 7 and video.control.snapshot().state == "idle", "Track switching does not restart the video or seek")
	video.media.playback.details.audio_tracks.append({"id": 4, "external": true, "title": "Clone voice"})
	menu.refresh_values(); tap(menu, 111)
	check(menu.choices.popup.choices[1].label == "Dubbing" and choice(menu, 4) >= 0, "Dubbed sidecar appears on initial popup page with native ID")
	video._clone_applied = false; video.prefer_clone_voice = true
	tap(menu, choice(menu, 1))
	check(not video.prefer_clone_voice and video._clone_applied and video.audio_track_id == 1, "Explicit original track cannot be overridden by pending auto dubbing")
	tap(menu, 111); tap(menu, choice(menu, 4))
	check(video.prefer_clone_voice and video.audio_track_id == 4 and main.settings.get_value("audio", "prefer_clone_voice", false), "Selecting Dubbing uses same audio path and preserves the preference")
	tap(menu, 111); before = host.calls.size()
	menu.stick_scroll(-1.0, 0.5)
	check(menu.choices.offset > 0 and host.calls.size() == before, "Audio popup stick only scrolls, never switches tracks")
	menu.choices.offset = 0; menu.refresh()
	origin = point(menu, choice(menu, 2))
	menu.press_pointer("left_hand", origin, -menu.global_basis.z, true)
	menu.update_pointer("left_hand", origin + Vector3(0, 0.04, 0), -menu.global_basis.z, true)
	menu.release_pointer("left_hand", origin, -menu.global_basis.z, true)
	check(host.calls.size() == before and video.audio_track_id == 4, "Dragging audio rows cannot choose a track")
	menu.choices.offset = 0; menu.refresh(); host.accepted = false
	tap(menu, choice(menu, 1))
	check(video.audio_track_id == 4 and video.prefer_clone_voice, "Rejected native change preserves current track and dubbing preference")
	host.accepted = true; tap(menu, 111)
	origin = point(menu, choice(menu, 1))
	menu.press_pointer("left_hand", origin, -menu.global_basis.z, true)
	video.local_uri = "file:///next.mp4"; menu.refresh()
	before = host.calls.size(); menu.release_pointer("left_hand", origin, -menu.global_basis.z, true)
	check(host.calls.size() == before and menu.choices.capture.is_empty() and menu.choices.opened.is_empty(), "Changing movie cancels held audio choice")
	video.media.playback.details.audio_tracks = []; menu.refresh(); tap(menu, 111)
	check(not menu.choices.opened.is_empty() and menu.text_snapshot().contains("movie.si.mix.m4a"), "Silent video still offers the naming explanation")
	I18n.use("zh")
	check(main._audio_option_label({"id": 4, "external": true, "title": "Clone voice"}) == "配音", "Clone voice title is localized without changing native identity")
	check(main._audio_option_label({"id": 1, "language": "eng"}) == "音轨 1 · 英语", "Audio labels localize language and track number")
	I18n.use("en"); menu.free(); video.free(); main.free()
	print("Audio popup checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
