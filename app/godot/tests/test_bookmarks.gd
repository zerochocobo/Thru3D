extends SceneTree
const Store := preload("res://scripts/bookmark_store.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Timeline := preload("res://scripts/timeline_markers.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
var failures: Array[String] = []
var checks := 0
var requests: Array = []

class FailedWrite extends "res://scripts/bookmark_store.gd":
	func _commit(_staged: String, _target: String) -> Error: return ERR_CANT_CREATE

class Host extends RefCounted:
	var targets: Array = []
	func close_mpv_video(_id: int) -> void: pass
	func set_mpv_playing(_id: int, _playing: bool) -> void: pass
	func revise_mpv_video(id: int, _stereo: bool, _alpha: bool, _profile: String, time: int, _depth: bool, _top_bottom: bool, _exact: bool = false) -> int:
		targets.append([id, time]); return 0

func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok: failures.append(text)

func origin(menu: Node3D, target: int) -> Vector3:
	for button in menu._buttons:
		if button.target == target: return menu.to_global(Vector3(button.rect.get_center().x, button.rect.get_center().y, 1))
	return Vector3.ZERO

func tap(menu: Node3D, target: int, hand: String = "left_hand") -> void:
	var start := origin(menu, target)
	menu.press_pointer(hand, start, -menu.global_basis.z, true)
	menu.release_pointer(hand, start, -menu.global_basis.z, true)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var path := ProjectSettings.globalize_path("res://../../artifacts/bookmarks-host/" + str(Time.get_ticks_usec()))
	var store := Store.new(path)
	var uri := "smb://server/old/movie.mp4"
	var id := store.resolve(uri, "movie.mp4", 5000000)
	check(store.list_markers(id).is_empty() and not DirAccess.dir_exists_absolute(path), "Opening a movie performs no storage mutation")
	var a := store.add(uri, "movie.mp4", 5000000, 10000)
	var b := store.add(uri, "movie.mp4", 5000000, 30000)
	check(not a.is_empty() and not b.is_empty(), "Add two timestamps")
	check(a.keys().size() == 3 and not a.has("rating") and not a.has("title"), "User marker contains only ID, time and creation date")
	var moved := "cloud://account/new/movie.mp4"
	check(store.resolve(moved, "movie.mp4", 5000000) == id, "Matching real name and byte length survives directory and source changes")
	check(store.resolve(moved, "movie.mp4", -1) != id, "Unknown byte size never cross-matches")
	check(store.resolve(moved, "movie.mp4", 5000001) != id, "Same name with different size stays separate")
	check(store.resolve(uri, "movie.mp4", 5000001) != id, "Changed file at same path does not inherit old bookmarks")
	check(store.resolve(moved, "Movie.mp4", 5000000) != id, "Case-sensitive basename is preserved")
	var duplicate := store.add(moved, "movie.mp4", 5000000, 10900)
	check(duplicate.id == a.id and store.list_markers(id).size() == 2, "Repeated nearby add highlights original point and binds moved URI")
	var loaded := Store.new(path)
	check(loaded.resolve(moved) == id and loaded.list_markers(id) == store.list_markers(id), "Restart retains markers and newly bound alias")
	check(store.remove(id, a.id) and store.can_undo(), "Delete commits and offers undo")
	check(Store.new(path).list_markers(id).size() == 1, "Delete is persisted before normal shutdown")
	check(store.restore() and store.list_markers(id)[0] == a and not store.can_undo(), "Undo restores original ID and date and sorted position")
	store.remove(id, b.id)
	store.add("file:///other.mp4", "other.mp4", 50, 0)
	check(store.restore() and store.list_markers(id).size() == 2, "Undo after switching movie restores the original movie")
	store.remove(id, a.id); store.undo.until = Time.get_ticks_msec() - 1
	check(not store.can_undo() and not store.restore(), "Undo expires")
	check(store.add(uri, "movie.mp4", 5000000, -1).is_empty(), "Negative position is rejected")
	var failed := FailedWrite.new(path)
	var before := failed.list_markers(id)
	check(not failed.remove(id, b.id) and failed.list_markers(id) == before and not failed.can_undo(), "Failed delete preserves memory and creates no undo")
	check(failed.add(uri, "movie.mp4", 5000000, 60000).is_empty() and failed.list_markers(id) == before, "Failed add preserves memory")
	var damaged_path := path.path_join("damage")
	var damaged := Store.new(damaged_path)
	damaged.add(uri, "movie.mp4", 5000000, 10000)
	damaged.add(uri, "movie.mp4", 5000000, 30000)
	var corrupt := FileAccess.open(damaged._path(id, 0), FileAccess.WRITE)
	corrupt.store_string("broken"); corrupt.close()
	check(Store.new(damaged_path).list_markers(id).size() == 1, "Corrupt latest generation falls back to previous bank")
	var future := FileAccess.open(damaged._path(id, 0), FileAccess.WRITE)
	future.store_string('{"schema_version":2}'); future.close()
	var protected := Store.new(damaged_path)
	check(protected.add(uri, "movie.mp4", 5000000, 50000).is_empty() and protected.list_markers(id).size() == 1, "Future schema cannot be overwritten")
	for index in 34: store.add("file:///%d.mp4" % index, "%d.mp4" % index, index + 1, 10000)
	check(Store.new(path).records.size() == 36, "Bookmarks survive beyond 32 history entries without eviction")
	var limit_store := Store.new(path.path_join("limit"))
	var limit_id := limit_store.resolve(uri, "movie.mp4", 5000000)
	var limit_record := {"id": limit_id, "aliases": [Store.Memory.key_for(uri)], "fingerprint": Store.fingerprint("movie.mp4", 5000000), "markers": []}
	for index in Store.MAX_MARKERS:
		limit_record.markers.append({"id": "%032x" % (index + 1), "position_ms": index * 2000, "created_at_ms": 1})
	check(limit_store._save(limit_record) and limit_store.add(uri, "movie.mp4", 5000000, 1100000).is_empty() and limit_store.last_error == "Bookmark limit reached", "500 point limit rejects additions without eviction")

	var marks := [{"id": "a", "position_ms": 0}, {"id": "b", "position_ms": 10000}, {"id": "c", "position_ms": 1000000}, {"id": "outside", "position_ms": 7200000}]
	var clusters := Timeline.groups(marks, 7200000, 0.82)
	check(clusters.size() == 2 and clusters[0].markers.size() == 2, "Dense timestamps cluster by visible distance and EOS is excluded")
	var dense: Array = []
	for index in 500: dense.append({"id": str(index), "position_ms": index * 14000})
	check(Timeline.groups(dense, 7200000, 0.82).size() <= 17, "500 markers produce bounded, non-overlapping groups")

	var menu := Menu.new()
	var state := {"has_video": true, "duration_ms": 7200000, "position_ms": 30000,
		"bookmark_scope": "movieA", "bookmark_ready": true, "bookmark_seekable": true,
		"bookmarks": marks.slice(0, 3), "bookmark_revision": 1}
	menu.state_provider = func(): return state
	menu.bookmark_requested.connect(func(operation, marker_id, scope): requests.append([operation, marker_id, scope]))
	root.add_child(menu); menu.toggle(); menu.set_process(false)
	var start := origin(menu, menu.BookmarkMenu.ADD)
	menu.press_pointer("left_hand", start, -menu.global_basis.z, true)
	check(requests.is_empty(), "Bookmark press captures without acting")
	menu.release_pointer("right_hand", start, -menu.global_basis.z, true)
	check(requests.is_empty(), "Other hand cannot release owner action")
	menu.release_pointer("left_hand", start, -menu.global_basis.z, true)
	check(requests == [["add", "", "movieA"]], "Release commits one scoped add")
	start = origin(menu, menu.BookmarkMenu.ADD)
	menu.press_pointer("left_hand", start, -menu.global_basis.z, true)
	menu.update_pointer("left_hand", start, -menu.global_basis.z, false)
	menu.release_pointer("left_hand", start, -menu.global_basis.z, true)
	check(requests.size() == 1, "Lost tracking cancels add")
	menu.press_pointer("left_hand", start, -menu.global_basis.z, true)
	state.bookmark_scope = "movieB"; menu.refresh()
	menu.release_pointer("left_hand", start, -menu.global_basis.z, true)
	check(requests.size() == 1, "Switching movies cancels held actions")
	state.bookmark_scope = "movieA"; menu.refresh()
	tap(menu, menu.BookmarkMenu.GROUP)
	check(requests.size() == 1 and menu.bookmarks.opened and menu.bookmarks.subset.size() == 2, "Cluster expands choice list without seeking")
	tap(menu, menu.BookmarkMenu.ROW)
	check(requests.back() == ["seek", "a", "movieA"], "Timestamp row seeks stable marker ID")
	start = origin(menu, menu.BookmarkMenu.DELETE)
	menu.press_pointer("left_hand", start, -menu.global_basis.z, true)
	menu.update_pointer("left_hand", start + Vector3(0, 0.05, 0), -menu.global_basis.z, true)
	menu.release_pointer("left_hand", start, -menu.global_basis.z, true)
	check(requests.size() == 2, "Dragging from trash is a scroll/cancel, not a delete")
	tap(menu, menu.BookmarkMenu.DELETE)
	check(requests.back() == ["delete", "a", "movieA"], "Trash emits delete alone")
	var previous_count := requests.size()
	start = origin(menu, menu.BookmarkMenu.ADD)
	menu.press_pointer("left_hand", start, -menu.global_basis.z, true)
	menu.release_pointer("left_hand", start + Vector3(0.022, 0, 0), -menu.global_basis.z, true)
	check(requests.size() == previous_count, "Release movement cancels click even without an intermediate pointer update")
	tap(menu, menu.BookmarkMenu.GROUP + 1)
	check(requests.back() == ["seek", "c", "movieA"], "Single anchor requests seek without opening a cluster")
	var count := requests.size()
	state.bookmarks = dense; menu.bookmarks.subset.clear(); menu.refresh()
	menu.stick_scroll(-1, 1)
	check(menu.bookmarks.offset > 0 and requests.size() == count, "Stick only scrolls the bookmark list")
	start = origin(menu, menu.BookmarkMenu.ROW)
	menu.press_pointer("left_hand", start, -menu.global_basis.z, true)
	menu.dismiss(); menu.release_pointer("left_hand", start, -menu.global_basis.z, true)
	check(requests.size() == count, "Closing menu cancels pointer capture")
	menu.toggle(); state.bookmark_ready = false; menu.refresh()
	tap(menu, menu.BookmarkMenu.ADD)
	check(requests.size() == count, "Frozen/invalid time disables add")
	var seek_hit := menu.ray_hit(origin(menu, Menu.SEEK), -menu.global_basis.z)
	check(seek_hit.get("target") == Menu.SEEK, "Bookmark lane does not intercept slider")
	menu.free()

	var video := Video.new()
	video.bookmark_store = Store.new(path.path_join("video"))
	root.add_child(video); video.set_process(false)
	video.media.begin(7); video.media.generation = 3
	video.media.state = "paused"; video.media.playback = {"details": {"seekable": "yes", "partially_seekable": "no"}}
	video.control.duration_ms = 60000; video.local_uri = uri; video.panel.visible = true
	video._bookmark_metadata = {"basename": "movie.mp4", "size": 5000000}; video._bookmark_resolve()
	video._binding.ticket = {"session_id": 7, "generation": 3, "pts_us": 12345000, "source_pts_verified": true}
	check(video.bookmark_snapshot().position_ms == 12345, "Capture uses displayed source frame, not UI clock")
	check(video.bookmark_action("add", "", video.bookmark_scope()) == "Bookmark added" and video.bookmark_store.list_markers(video._bookmark_media_id)[0].position_ms == 12345, "Controller commits actual source timestamp")
	video.control.seek_absolute(40000)
	check(video.bookmark_snapshot().is_empty() and video.bookmark_action("add", "", video.bookmark_scope()).is_empty(), "Pending seek target cannot be bookmarked")
	video.control.reject(); video._binding.ticket.generation = 2
	check(video.bookmark_snapshot().is_empty(), "Stale processing generation is rejected")
	video._binding.ticket.generation = 3
	video._binding.ticket.frozen_frame_id = 1
	check(video.bookmark_snapshot().is_empty(), "Frozen source frame cannot become a bookmark")
	video._binding.ticket.erase("frozen_frame_id")
	video.media.state = "ended"
	check(video.bookmark_seekable(), "Bookmark jumps remain available at EOF")
	video.media.playback.details.partially_seekable = "yes"
	check(not video.bookmark_seekable(), "Partially seekable source disables bookmark jumps")
	check(video.bookmark_action("delete", "a", "stale scope").is_empty(), "Controller independently rejects stale UI scope")
	video.media.playback.details.partially_seekable = "no"
	var bridge := Host.new(); video.platform = bridge; video.requested_play = false
	video.bookmark_action("seek", str(video.bookmark_last_added.id), video.bookmark_scope())
	check(bridge.targets == [[7, 12345]] and video.control.target_ms == 12345 and not video.requested_play, "Stored marker reaches actual revision chain and preserves pause intent")
	video._binding.ticket.clear(); video.free()
	print("Bookmark checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
