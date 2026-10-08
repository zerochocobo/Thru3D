extends SceneTree
## Library pictures. Needs a renderer (run without --headless):
## godot --xr-mode off --rendering-driver opengl3 --path app/godot --script res://tests/test_thumbnails.gd

const Thumbnails := preload("res://scripts/thumbnail_cache.gd")
const Menu := preload("res://scripts/library_menu.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Recent := preload("res://scripts/recent_files.gd")

var checks := 0
var failures: Array[String] = []

class PhotoCacheHost extends RefCounted:
	var files := 3
	var bytes := 12582912
	var clears := 0
	func photo_cache_usage() -> String:
		return JSON.stringify({"files": files, "bytes": bytes})
	func clear_photo_cache() -> bool:
		clears += 1
		files = 0; bytes = 0
		return true

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	Thumbnails.clear()
	# Crop: a 16:9 piece of one eye.
	var flat := Thumbnails.crop_for(0, Vector2(1920, 1080))
	check(flat.is_equal_approx(Vector4(0, 0, 1, 1)), "Flat 16:9 eye is used whole: %s" % flat)
	var vr180 := Thumbnails.crop_for(1, Vector2(4096, 4096))
	check(is_equal_approx(vr180.z, 0.5) and is_equal_approx(vr180.w, 0.28125) and is_equal_approx(vr180.x, 0.25), "VR180 uses the centre of the eye: %s" % vr180)
	var tall := Thumbnails.crop_for(0, Vector2(1080, 1920))
	check(is_equal_approx(tall.z, 1.0) and tall.w < 1.0 and is_equal_approx(tall.y, (1.0 - tall.w) * 0.5), "A portrait eye gives its middle band: %s" % tall)

	# Capture renders the left eye of a side-by-side frame, top row on top.
	var frame := Image.create(640, 180, false, Image.FORMAT_RGBA8)
	frame.fill_rect(Rect2i(0, 0, 320, 90), Color(0, 1, 0))
	frame.fill_rect(Rect2i(0, 90, 320, 90), Color(1, 0, 0))
	frame.fill_rect(Rect2i(320, 0, 320, 180), Color(0, 0, 1))
	var source := ImageTexture.create_from_image(frame)
	var holder := Node.new()
	root.add_child(holder)
	var shot: Image = await Thumbnails.capture(holder, source.get_rid(), false, true, Vector4(0, 0, 1, 1))
	check(shot != null and shot.get_size() == Thumbnails.SIZE, "Capture has the picture size")
	if shot:
		var top := shot.get_pixel(160, 30)
		var bottom := shot.get_pixel(160, 150)
		check(top.g > 0.8 and top.r < 0.2 and top.b < 0.2, "Top of the left eye on top: %s" % top)
		check(bottom.r > 0.8 and bottom.g < 0.2 and bottom.b < 0.2, "Bottom of the left eye below: %s" % bottom)
		check(Thumbnails.store("file:///v.mp4", shot), "Stored")
	check(Thumbnails.has("file:///v.mp4") and Thumbnails.texture("file:///v.mp4") != null, "Stored picture loads")
	check(Thumbnails.usage().x == 1 and Thumbnails.usage().y > 0, "Usage counts the file")
	var wide := Image.create(800, 200, false, Image.FORMAT_RGB8)
	check(Thumbnails.fit(wide).get_size() == Thumbnails.SIZE, "Covers of any shape fill the tile")

	# Library tiles use the picture; DLNA covers only come from the server's URL.
	var menu := Menu.new()
	root.add_child(menu)
	menu.toggle()
	check(menu._picture({"uri": "file:///v.mp4", "icon": "video"}) != null, "Played video tile shows its frame")
	check(menu._picture({"uri": "smb://nas/new.mp4", "icon": "video"}) == null and menu._covers.is_empty(),
		"Unplayed SMB video: no picture and nothing fetched")
	menu._picture({"uri": "http://127.0.0.1:9/v.mp4", "cover": "http://127.0.0.1:9/cover.jpg", "icon": "video"})
	check(menu._covers.has("http://127.0.0.1:9/cover.jpg"), "DLNA cover is fetched from the server's URL")
	menu._cancel_covers()

	# Settings > general > clear cache: the first press arms, the second clears.
	menu.section = Menu.Section.SETTINGS
	menu.tab = menu.GENERAL_TAB
	menu.refresh()
	var index := menu.rows.find_custom(func(r): return r.has("clear_cache"))
	check(index >= 0 and str(menu.rows[index].detail) != "", "Clear cache row shows the size")
	menu._choose(menu.rows[index])
	check(Thumbnails.has("file:///v.mp4") and menu._confirm == "clear_cache", "First press only arms")
	menu._choose(menu.rows[menu.rows.find_custom(func(r): return r.has("clear_cache"))])
	check(not Thumbnails.has("file:///v.mp4") and Thumbnails.usage().x == 0, "Second press clears the cache")
	var photo_host := PhotoCacheHost.new()
	menu.platform = photo_host
	menu._cache_usage = null
	menu.refresh()
	var photo_row: Dictionary = menu.rows[menu.rows.find_custom(func(r): return r.has("clear_cache"))]
	check(not photo_row.empty and menu._cache_usage == Vector2i(3, 12582912), "Photo-only cache is counted and can be cleared without thumbnails")
	menu._choose(photo_row)
	check(photo_host.clears == 0, "First press does not delete photo files")
	menu._choose(menu.rows[menu.rows.find_custom(func(r): return r.has("clear_cache"))])
	check(photo_host.clears == 1 and menu._cache_usage == Vector2i.ZERO, "Confirmed clear reaches Android and refreshes the remaining size")
	menu.platform = null

	# Every stable playback source can keep its displayed frame; ephemeral proxies cannot.
	check(Video._thumbnail_source("smb://nas/a.mp4") and Video._thumbnail_source("content://media/1")
		and Video._thumbnail_source("http://192.168.31.185/a.mp4") and Video._thumbnail_source("https://nas/a.mp4")
		and Video._thumbnail_source("cloud://account/a.mp4") and Video._thumbnail_source("medialib://server/scene/1"),
		"Played local, SMB, DLNA, cloud and media-server videos get a frame")
	check(not Video._thumbnail_source("http://127.0.0.1:8765/proxy") and not Video._thumbnail_source("ftp://nas/a.mp4"),
		"Ephemeral proxy and unsupported sources are not persisted")
	var recent := Recent.new("user://thumbnail_recent_test")
	recent.clear_all(); recent.save()
	var uri := "http://192.168.31.185/movie.mp4"
	var cover := "http://192.168.31.185/cover.jpg"
	recent.opened(uri, "DLNA movie", false)
	check(recent.set_cover(uri, cover) and recent.save(), "DLNA cover is saved with the recent entry")
	recent.opened(uri, "DLNA movie reopened", false); recent.save()
	var reloaded := Recent.new("user://thumbnail_recent_test")
	reloaded.load_saved()
	check(reloaded.lookup(uri).get("cover") == cover, "Reopening and reloading history preserve the server cover URL")
	check(not reloaded.set_cover(uri, "file:///private/image.jpg") and not reloaded.set_cover(uri, "javascript:test"),
		"Recent covers accept only HTTP images")
	menu.catalog = reloaded; menu.section = Menu.Section.RECENT; menu.refresh()
	check(menu.rows.size() == 1 and menu.rows[0].get("cover") == cover, "Recent tiles retain DLNA cover metadata")
	Thumbnails.store(uri, frame)
	check(menu._picture(menu.rows[0]) != null, "Unavailable DLNA cover falls back to the played frame immediately")
	menu.refresh()
	var recent_tile: Dictionary = menu._buttons.filter(func(b): return b.target == menu.ROW_BASE)[0]
	var recent_area: MeshInstance3D = recent_tile.node.get_child(1)
	check(recent_area.material_override.albedo_texture == Thumbnails.texture(uri), "Actual recent card binds the screenshot when its DLNA cover is absent")
	menu._cancel_covers()
	Thumbnails.store(cover, wide)
	var server_picture := menu._picture(menu.rows[0])
	check(server_picture == Thumbnails.texture(cover), "Available server cover takes priority over a played frame")
	check(menu.video_queue()[0].metadata.cover == cover, "Previous/next playback queue keeps cover metadata")
	menu._cancel_covers(); reloaded.clear_all(); reloaded.save()
	Thumbnails.protect_keys([uri])
	for cache_index in 4: Thumbnails.store("http://nas/cache-test/%d" % cache_index, frame)
	Thumbnails.prune(2)
	check(Thumbnails.usage().x == 2 and Thumbnails.has(uri), "Bounded cache pruning preserves the current recent screenshot")
	Thumbnails.protect_keys([])
	Thumbnails.prune(256, 1)
	check(Thumbnails.usage().x == 0, "Byte limit also evicts generated thumbnails")

	Thumbnails.clear()
	print("thumbnail checks=%d failures=%d" % [checks, failures.size()])
	quit(1 if failures.size() > 0 else 0)
