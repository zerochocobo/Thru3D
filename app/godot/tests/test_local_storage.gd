extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_library_menu.gd")
const Volume := preload("res://scripts/storage_volume.gd")
const Main := preload("res://scripts/main.gd")
const Photo := preload("res://scripts/photo_display.gd")
var checks := 0
var failures: Array[String] = []
class Reader extends Node3D:
	var local_uri := ""
	var queue: Array[Dictionary] = []
	var closes := 0
	func close_video() -> void: closes += 1; local_uri = ""
	func close_image() -> void: closes += 1; local_uri = ""
	func release_storage(volume: Dictionary) -> bool:
		queue = queue.filter(func(item): return not Volume.contains_uri(volume,str(item.uri)))
		if Volume.contains_uri(volume, local_uri): close_image(); return true
		return false
class Library extends Node3D:
	var finished := ""
	func finish_storage_release(path: String) -> void: finished = path
class PhotoHost extends RefCounted:
	var cancelled: Array[int] = []
	var released: Array[int] = []
	func cancel_photo(id: int) -> void: cancelled.append(id)
	func release_photo(id: int) -> void: released.append(id)
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func settle() -> void:
	await process_frame; await process_frame; await process_frame
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	preload("res://scripts/i18n.gd").use("en")
	var external := {"id":"/storage/1234-5678","uuid":"1234-5678","removable":true}
	check(Volume.contains_uri(external,"file:///storage/1234-5678/%E5%9B%BE.jpg"),"Encoded file paths belong to the selected volume")
	check(not Volume.contains_uri(external,"file:///storage/1234-56780/other.mp4"),"Similar path prefixes cannot stop another volume")
	check(not Volume.contains_uri(external,"file:///storage/1234-5678/../emulated/0/internal.mp4"),"Path normalization prevents another volume matching")
	check(Volume.contains_uri(external,"content://com.android.externalstorage.documents/document/1234-5678%3AMovies%2Fa.mp4"),"USB document URI belongs to the selected volume")
	check(not Volume.contains_uri(external,"content://com.android.externalstorage.documents/document/primary%3AMovies%2Fa.mp4"),"Internal document URI does not belong to USB")
	check(not Volume.contains_uri(external,"content://other.provider/document/1234-5678%3Aa.mp4"),"Other providers cannot spoof a volume")
	check(not Volume.contains_uri(external,"content://com.android.externalstorage.documents/tree/1234-5678%3A/document/primary%3Aa.mp4"),"Document identity takes precedence over the tree")
	check(not Volume.contains_uri({"id":"/","removable":true},"file:///storage/1234-5678/a.mp4"),"Invalid root cannot release arbitrary playback")
	var app := Main.new()
	app.video = Reader.new(); app.photo = Reader.new(); app.recent_menu = Library.new()
	app.video.local_uri = "file:///storage/1234-5678/movie.mp4"
	app.photo.local_uri = "file:///storage/1234-5678/image.jpg"
	app.photo.queue.assign([{"uri":app.photo.local_uri}]); app.photo_active = true
	app.video_queue.assign([{"uri":app.video.local_uri},{"uri":"smb://server/movie.mp4"}])
	app._on_storage_eject_requested(external)
	check(app.video.closes == 1 and app.photo.closes == 1 and not app.photo_active,"Release closes target video and photo")
	check(app.recent_menu.finished == external.id and app.video_queue.size() == 1,"Release completes after pruning playback references")
	app.video.local_uri = "smb://server/movie.mp4"
	app.photo.local_uri = "file:///storage/emulated/0/internal.jpg"; app.photo_active = true
	app.photo.queue.assign([{"uri":app.photo.local_uri},{"uri":"file:///storage/1234-5678/image.jpg"}])
	app._on_storage_eject_requested(external)
	check(app.video.closes == 1 and app.photo.closes == 1 and app.photo_active and app.photo.queue.size() == 1,"Unrelated current media continues while USB queue entries are removed")
	app.video.free(); app.photo.free(); app.recent_menu.free(); app.free()
	var photo := Photo.new(); root.add_child(photo); photo.set_process(false)
	var host := PhotoHost.new(); photo.platform = host
	photo.local_uri = "file:///storage/emulated/0/internal.jpg"
	photo.queue.assign([{"uri":"file:///storage/1234-5678/a.jpg"},{"uri":photo.local_uri},{"uri":"smb://server/other.jpg"}])
	photo.index = 1; photo.pending_index = 0; photo.loading = true
	photo._display_request = 20; photo._request = 21
	photo._prefetched = {0:{"id":11},2:{"id":12}}; photo._recent_files = {0:{"id":13}}
	check(not photo.release_storage(external) and photo.local_uri.ends_with("internal.jpg") and photo.index == 0,"Production photo keeps an unrelated display and remaps its queue")
	check(photo.queue.size() == 2 and photo._prefetched.is_empty() and photo._recent_files.is_empty() and 11 in host.cancelled and 13 in host.cancelled and 21 in host.cancelled,"Queued and cached USB photo requests are cancelled")
	check(not photo.loading and photo.pending_index == -1 and photo._request == 20 and 20 not in host.cancelled and 20 not in host.released,"Pending USB navigation cannot replace the unrelated displayed photo")
	photo.local_uri = "file:///storage/1234-5678/b.jpg"; photo.queue.append({"uri":photo.local_uri})
	check(photo.release_storage(external) and photo.local_uri.is_empty() and photo.queue.size() == 2,"Displayed USB photo closes and USB queue references disappear")
	photo.queue_free(); await process_frame
	var platform := Fixture.FakePlatform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	var releases: Array = []; var removals: Array = []
	menu.storage_eject_requested.connect(func(volume): releases.append(volume); menu.finish_storage_release.call_deferred(volume.id))
	menu.storage_removed.connect(func(volume): removals.append(volume))
	menu._activate(Menu.NAV_BASE+Menu.Section.LOCAL); await settle()
	check(menu._buttons.any(func(button): return button.target == Menu.USB_STORAGE),"Connected volume exposes a quick entry")
	menu._activate(Menu.ROW_BASE); await settle()
	check(not menu._buttons.any(func(button): return button.target == Menu.EJECT_STORAGE),"Internal storage has no release action")
	menu._activate(Menu.USB_STORAGE); await settle()
	check(menu._local_path() == external.id and menu._local_stack.size() == 1,"USB quick entry opens the removable root")
	check(menu._tips[Menu.EJECT_STORAGE] == "Stop using storage","Release tooltip describes the software action")
	menu._activate(Menu.EJECT_STORAGE); menu._activate(Menu.EJECT_STORAGE); await settle()
	check(releases.size() == 1 and platform.storage_settings.is_empty(),"Release never opens system settings or duplicates a pending request")
	check(menu._local_eject_pending.is_empty() and menu._local_path().is_empty() and menu.status == "Storage access stopped. You can unplug.","Completion returns to roots and shows the unplug message")
	check(menu._external_volumes().size() == 1,"Software release keeps the physically connected volume mounted")
	menu._activate(Menu.USB_STORAGE); await settle()
	platform.usb_connected = false
	platform.media_list.emit(0,JSON.stringify({"source":"local_storage","state":"changed","volumes":platform.storage_volumes()})); await settle()
	check(menu._local_stack.is_empty() and not menu._buttons.any(func(button): return button.target == Menu.USB_STORAGE) and removals.size() == 1,"Removal updates the path and shortcut and signals reader cleanup")
	var calls := platform.calls.size()
	platform.media_list.emit(0,JSON.stringify({"source":"local_storage","state":"changed","volumes":platform.storage_volumes()})); await settle()
	check(platform.calls.size() == calls and removals.size() == 1,"Duplicate snapshots do not repeat cleanup or list reads")
	menu._request("local",201); menu._request("local",202)
	menu._on_media_list(201,JSON.stringify({"state":"ready","path":"","entries":[external],"volumes":[external]}))
	check(menu._external_volumes().is_empty(),"Superseded responses cannot restore stale volumes")
	menu._on_media_list(202,JSON.stringify({"state":"ready","path":"","entries":platform.storage_volumes(),"volumes":platform.storage_volumes()}))
	platform.usb_connected = true
	platform.extra_usb = [{"id":"/storage/9876-ABCD","title":"Second USB","uuid":"9876-ABCD","removable":true,"volume":true,"container":true}]
	platform.media_list.emit(0,JSON.stringify({"source":"local_storage","state":"changed","volumes":platform.storage_volumes()})); await settle()
	check(menu._external_volumes().size() == 2 and menu._buttons.any(func(button): return button.target == Menu.USB_STORAGE),"Insertion updates entries and the shortcut without manual refresh")
	menu._activate(Menu.USB_STORAGE); await settle()
	check(menu._local_path().is_empty() and menu._eject_volume().is_empty(),"Multiple devices require an explicit target")
	menu._activate(Menu.ROW_BASE+2); await settle()
	check(menu._eject_volume().get("id") == "/storage/9876-ABCD","Release follows the selected volume")
	menu.queue_free(); await process_frame; platform.free()
	for failure in failures: push_error(failure)
	print("Local removable storage: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
