extends SceneTree
var checks := 0
var failures: Array[String] = []
class Reader extends Node3D:
	var local_uri := ""
	var queue: Array[Dictionary] = []
	var closes := 0
	func close_video() -> void: closes += 1; local_uri = ""
	func close_image() -> void: closes += 1; local_uri = ""; queue.clear()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void:
	var directory := ProjectSettings.globalize_path("res://../../artifacts/file-editing-memory/" + str(Time.get_ticks_usec()))
	var old := "file:///storage/test/old.mp4"
	var new := "file:///storage/test/new.mp4"
	var recent := preload("res://scripts/recent_files.gd").new(directory)
	recent.opened(old,"old.mp4",false); recent.progress(old,5000,100000)
	check(recent.relocate(old,new,"new.mp4") and recent.lookup(old).is_empty() and recent.resume_position(new) == 5000, "Rename keeps progress under new URI")
	check(recent.save(), "Renamed history persists")
	var reloaded := preload("res://scripts/recent_files.gd").new(directory); reloaded.load_saved()
	check(reloaded.lookup(new).title == "new.mp4" and reloaded.lookup(old).is_empty(), "History survives restart with renamed title and identity")
	var modes := preload("res://scripts/file_mode_memory.gd").new(directory)
	modes.remember(old,{"profile":"320x320","geometry":1,"stereo_sbs":true,"swap_eyes":false,"alpha_requested":false})
	check(modes.relocate(old,new) and modes.lookup(new).stereo_sbs and modes.lookup(old).is_empty(), "Rename keeps viewing mode")
	var store := preload("res://scripts/bookmark_store.gd").new(directory.path_join("bookmarks"))
	store.add(old,"old.mp4",5000,10000)
	check(store.relocate(old,new,"new.mp4",5000), "Rename migrates bookmark fingerprint and alias")
	check(store.list_markers(store.resolve(new,"new.mp4",5000)).size() == 1, "Renamed movie retains timestamp")
	check(store.list_markers(store.resolve(old,"old.mp4",5000)).is_empty(), "A replacement at old URI does not inherit renamed bookmarks")
	var cold := preload("res://scripts/bookmark_store.gd").new(directory.path_join("bookmarks"))
	check(cold.list_markers(cold.resolve(new,"new.mp4",5000)).size() == 1, "Renamed bookmarks survive restart")
	var shared := preload("res://scripts/bookmark_store.gd").new(directory.path_join("shared-bookmarks"))
	var copy := "smb://other/share/old.mp4"
	shared.add(old,"old.mp4",5000,10000); shared.add(copy,"old.mp4",5000,20000)
	check(shared.relocate(old,new,"new.mp4",5000), "Rename can separate one URI from a shared bookmark record")
	check(shared.list_markers(shared.resolve(new,"new.mp4",5000)).size() == 2 and shared.list_markers(shared.resolve(copy,"old.mp4",5000)).size() == 2, "Renaming one copy preserves both copies' bookmarks")
	var undo_store := preload("res://scripts/bookmark_store.gd").new(directory.path_join("undo-bookmarks"))
	var marker := undo_store.add(old,"old.mp4",5000,10000)
	undo_store.remove(undo_store.resolve(old,"old.mp4",5000), marker.id)
	check(undo_store.relocate(old,new,"new.mp4",5000) and undo_store.restore(), "A recent bookmark undo follows a renamed video")
	check(undo_store.list_markers(undo_store.resolve(new,"new.mp4",5000)).size() == 1 and undo_store.list_markers(undo_store.resolve(old,"old.mp4",5000)).is_empty(), "Undo cannot revive renamed markers at the old URI")
	var app := preload("res://scripts/main.gd").new()
	app.video = Reader.new(); app.photo = Reader.new()
	app.video.local_uri = "file:///storage/test/folder/movie.mp4"
	app.photo.local_uri = "file:///storage/test/folder/photo.jpg"
	app.photo_active = true
	app._prepare_file_delete("file:///storage/test/folder")
	check(app.video.closes == 1 and app.photo.closes == 1 and not app.photo_active, "Folder deletion releases descendant video and image readers before mutation")
	app.video.local_uri = "smb://other/share/movie.mp4"; app.photo.local_uri = "file:///storage/test/other/photo.jpg"
	app._prepare_file_delete("file:///storage/test/folder")
	check(app.video.closes == 1 and app.photo.closes == 1, "Deleting a folder leaves unrelated readers running")
	app.photo.queue.assign([{"uri":"file:///storage/test/folder/preloaded.jpg"}])
	app._prepare_file_delete("file:///storage/test/folder")
	check(app.photo.closes == 2, "A descendant preloaded image is released even with an unrelated current display")
	app.video.free(); app.photo.free(); app.free()
	print("file editing memory checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
