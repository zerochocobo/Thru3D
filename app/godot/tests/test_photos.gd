extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Info := preload("res://scripts/image_info.gd")
const Menu := preload("res://scripts/photo_menu.gd")
const Library := preload("res://scripts/library_menu.gd")
const Catalog := preload("res://scripts/recent_files.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Main := preload("res://scripts/main.gd")
var failures: Array[String] = []
var checks := 0
var folder := "user://photo_test_%d" % Time.get_ticks_usec()

class PhotoHost extends RefCounted:
	var ready: Callable
	var depth: Callable
	var depth_path := ""
	var requests := 100
	var inference := 0
	func open_photo(uri: String) -> int:
		requests += 1
		ready.call_deferred(requests, JSON.stringify({"state":"ready", "path":uri.trim_prefix("file://")}))
		return requests
	func prepare_photo_depth(id: int) -> bool:
		inference += 1
		depth.call_deferred(id, JSON.stringify({"state":"ready", "path":depth_path, "width":252, "height":140, "rect":[0,0,1,1]}))
		return true
	func cancel_photo(_id: int) -> void: pass
	func release_photo(_id: int) -> void: pass

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func settle(photo: Node3D) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while photo.loading and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout
	check(not photo.loading, "Async decode completes within deadline")

func check_mode_lock(entries: Array, pano: String) -> void:
	var photo := Photo.new()
	photo.mode_memory = Memory.new(folder.path_join("lock_modes"))
	root.add_child(photo)
	photo.open_image(entries[0].uri, entries[0].title, entries)
	await settle(photo)
	photo.set_projection(3)
	var menu := Menu.new()
	menu.state_provider = photo.snapshot
	menu.action_requested.connect(func(op):
		if op == "lock_mode": photo.toggle_mode_lock())
	root.add_child(menu)
	menu.toggle(); menu._activate(menu.MODE)
	var tile: Dictionary = menu._buttons.filter(func(b): return b.target == menu.MODE_PROJECTION + 3)[0]
	menu.press_pointer("right_hand", tile.node.global_position + Vector3(0,0,1), Vector3.FORWARD, true)
	menu.release_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
	check(photo.mode_lock.get("geometry") == 3 and menu._state.mode_lock == photo.mode_lock, "Same-hand trigger on selected 360 tile locks and refreshes photo menu")
	for i in 2:
		photo.navigate(1); await settle(photo)
		check(photo.geometry == 3 and not photo.stereo_sbs, "360 lock survives next photo %d" % i)
	menu.refresh(); menu._activate(menu.MODE_STEREO)
	check(photo.mode_lock.is_empty(), "Pressing current layout unlocks photo mode just like video")
	photo.navigate(-1); await settle(photo)
	check(photo.geometry == 0, "Unlocked photo resumes automatic mode; lock was not written into per-file memory")
	photo.set_projection(0)
	photo.load_mode_lock({"geometry":3, "layout":2, "depth":false, "fisheye_fov":180})
	photo.open_image(entries[1].uri, entries[1].title); await settle(photo)
	check(photo.geometry == 0 and not photo.stereo_sbs, "Explicit per-photo correction takes priority over default lock")
	photo.open_image(entries[2].uri, "sample_180_SBS.jpg"); await settle(photo)
	check(photo.geometry == 1 and photo.stereo_sbs and not photo.top_bottom, "Explicit VR filename takes priority over default lock")
	photo.open_image(entries[2].uri, entries[2].title); await settle(photo)
	check(photo.geometry == 3 and photo.stereo_sbs and photo.top_bottom, "Photo lock also preserves stereo layout")
	photo.load_mode_lock({"geometry":0, "layout":0, "depth":false, "fisheye_fov":180})
	photo.open_image("file://" + pano, "pano.jpg"); await settle(photo)
	check(photo.geometry == 3 and not photo.stereo_sbs, "GPano metadata retains its panorama projection under a flat default lock")
	for invalid in [null, {}, {"geometry":3.5,"layout":0,"depth":false,"fisheye_fov":180}, {"geometry":3,"layout":4,"depth":false,"fisheye_fov":180}]:
		photo.load_mode_lock(invalid)
		check(photo.mode_lock.is_empty(), "Malformed stored lock is ignored")
	menu.queue_free(); photo.queue_free(); await process_frame

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	var rgb := Image.create(320, 160, false, Image.FORMAT_RGB8)
	rgb.fill(Color(0.2, 0.4, 0.6))
	var paths: Array[String] = []
	for extension in ["jpg", "png", "webp"]:
		var path := ProjectSettings.globalize_path(folder.path_join("wide." + extension))
		var bytes: PackedByteArray = rgb.save_jpg_to_buffer() if extension == "jpg" else (rgb.save_png_to_buffer() if extension == "png" else rgb.save_webp_to_buffer())
		FileAccess.open(path, FileAccess.WRITE).store_buffer(bytes)
		paths.append(path)
		var header := Info.read_header(path)
		check(header.get("width") == 320 and header.get("height") == 160 and not header.get("panorama"), extension + " bounded dimensions, ordinary 2:1 is flat")
	check(Info.is_image("https://host/PHOTO.JPG?token=a#b"), "Query/case-insensitive image extension")
	check(not Info.is_image("https://host/movie.mp4?cover=a.jpg"), "Video URL query is not a photo")
	var bomb := rgb.save_png_to_buffer()
	bomb.encode_u32(16, 0xffffffff)
	var bad_path := ProjectSettings.globalize_path(folder.path_join("oversize.png"))
	FileAccess.open(bad_path, FileAccess.WRITE).store_buffer(bomb)
	check(Photo._decode({"info":{"path":bad_path}}).get("error") == "Image too large", "Oversize header rejected before image allocation")
	# EXIF orientation and GPano are in APP1 before the compressed JPEG payload.
	var exif := PackedByteArray([69,120,105,102,0,0,73,73,42,0,8,0,0,0,1,0,18,1,3,0,1,0,0,0,6,0,0,0,0,0,0,0])
	var jpg := rgb.save_jpg_to_buffer()
	var xml := 'http://ns.adobe.com/xap/1.0/'.to_utf8_buffer()
	xml.append(0)
	xml.append_array('<x GPano:ProjectionType="equirectangular" GPano:FullPanoWidthPixels="640" GPano:FullPanoHeightPixels="320" GPano:CroppedAreaImageWidthPixels="320" GPano:CroppedAreaImageHeightPixels="160" GPano:CroppedAreaLeftPixels="160" GPano:CroppedAreaTopPixels="80"/>'.to_utf8_buffer())
	var metadata := jpg.slice(0, 2)
	for segment in [exif, xml]:
		metadata.append_array(PackedByteArray([255,225,(segment.size()+2)>>8,(segment.size()+2)&255]))
		metadata.append_array(segment)
	metadata.append_array(jpg.slice(2))
	var pano := ProjectSettings.globalize_path(folder.path_join("pano.jpg"))
	FileAccess.open(pano, FileAccess.WRITE).store_buffer(metadata)
	var header := Info.read_header(pano)
	check(header.get("panorama", false) and header.get("orientation") == 6, "EXIF orientation and positive panorama tag")
	check(Info.panorama_rect(header).is_equal_approx(Vector4(.25,.25,.5,.5)), "GPano cropped area maps to full sphere")
	check(Info.panorama_rect({"FullPanoWidthPixels": 1}).is_equal_approx(Vector4(0,0,1,1)), "Incomplete panorama bounds fall back safely")
	var photo := Photo.new()
	photo.mode_memory = Memory.new(folder.path_join("modes"))
	photo.catalog = Catalog.new(folder.path_join("recent"))
	root.add_child(photo)
	var entries: Array = []
	for path in paths: entries.append({"uri": "file://" + path, "title": path.get_file(), "kind": "image"})
	await check_mode_lock(entries, pano)
	entries.append({"uri": "file://ignored.mp4", "title": "ignored.mp4", "kind": "video"})
	photo.open_image(entries[0].uri, entries[0].title, entries)
	await settle(photo)
	check(photo.index == 0 and photo.queue.size() == 3 and photo.geometry == 0 and not photo.stereo_sbs, "Photo queue excludes videos; wide photo is flat mono")
	check(photo.catalog.lookup(entries[0].uri).get("kind") == "image", "Photo recent entry persists its type")
	check(not photo.navigate(-1), "No wrap before first photo")
	photo.navigate(1); photo.navigate(1)
	await settle(photo)
	check(photo.index == 2 and photo.local_uri == entries[2].uri, "Rapid navigation displays only final request")
	photo._on_ready(-9, JSON.stringify({"state":"ready","path":paths[0]}))
	check(photo.index == 2 and photo._next_decode.is_empty(), "Late result cannot replace the current photo")
	check(not photo.navigate(1), "No wrap past final photo")
	photo.queue.append({"uri":"file://" + bad_path, "title":"oversize.png", "kind":"image"})
	photo.navigate(1)
	await settle(photo)
	check(photo.error == "Image too large" and photo.index == 2 and photo.panel.visible, "Failed load preserves the last successful picture")
	photo.queue.append(entries[0].duplicate(true))
	photo.navigate(1)
	await settle(photo)
	check(photo.index == 4 and photo.error.is_empty(), "Next skips past an unreadable image instead of retrying it forever")
	photo.set_projection(3)
	photo.toggle_inspect()
	check(photo._detail.visible and photo.inspect and photo.magnification == 2.0, "Spherical inspect opens independent detail window")
	photo.inspect_ray(Vector3.ZERO, Vector3.RIGHT)
	check(photo._detail_direction.is_equal_approx(Vector3.RIGHT), "Controller ray selects panorama detail direction")
	photo.zoom_view(100)
	check(photo.magnification == 8.0 and photo.view_zoom == 0.0, "Detail zoom clamps without moving sphere")
	photo.set_projection(0)
	photo.set_screen_curve(1.0)
	photo.toggle_inspect()
	var hit := photo.panel.to_global(Vector3.ZERO)
	check(photo.inspect_ray(hit + Vector3(0,0,2), Vector3.FORWARD), "Curved flat photo supports ray inspection")
	photo.pan_content(Vector2(100,100))
	check(photo.crop_center.x <= .75 and photo.crop_center.y >= .25, "Detail crop never exposes empty borders")
	photo.set_stereo_layout(2)
	check(photo.top_bottom and photo.stereo_sbs and not photo.set_depth(true), "Stereo photos cannot stack inferred depth")
	photo.open_image("file://" + pano, "pano.jpg")
	await settle(photo)
	check(photo.geometry == 3 and photo._size == Vector2(160,320), "Tagged JPEG opens spherical and applies orientation")
	var library := Library.new()
	library.catalog = photo.catalog
	root.add_child(library)
	library.section = library.Section.LOCAL
	library._local_entries = [{"title":"Folder", "id":"folder", "container":true}, {"title":"Clip.mp4", "uri":"file://clip.mp4"}, {"title":"No extension", "uri":"https://host/object/5", "kind":"image"}]
	library.refresh()
	check(library.image_queue().size() == 1 and library.is_image_uri("https://host/object/5"), "Extensionless DLNA images retain their explicit media type")
	library._activate(library.FILTER_BASE + 2)
	check(library.rows.size() == 2 and library.rows[0].has("container"), "Photo filter retains navigation folders")
	var menu := Menu.new()
	menu.state_provider = photo.snapshot
	menu.queue_provider = func(): return photo.queue
	root.add_child(menu)
	menu.toggle()
	check(not menu._buttons.any(func(b): return b.target in [menu.SEEK, menu.VOLUME, 102, 109]), "Photo controls have no playback/timeline/volume controls")
	var commands: Array[String] = []
	menu.action_requested.connect(func(op): commands.append(op))
	menu._activate(menu.PHOTO_INSPECT)
	check(commands == ["photo_inspect"], "Photo bar emits photo-specific action")
	menu._activate(menu.PHOTO_GALLERY)
	var thumb: Dictionary = menu._buttons.filter(func(b): return b.target == menu.PHOTO_THUMB)[0]
	var centre: Vector3 = thumb.node.global_position
	menu.press_pointer("left_hand", centre + Vector3(0,0,1), Vector3.FORWARD, true)
	check(commands.back() == "photo_index_0", "Same-hand ray and trigger select gallery photo")
	photo._select(0)
	photo.close_image()
	await create_timer(.05).timeout
	check(not photo.panel.visible and not photo._detail.visible and not photo.loading and photo._texture == null, "Close releases textures and detail window")
	# Exercise app-level routing, preserving separate video controls and screen settings.
	var main := Main.new()
	main.settings_path = folder.path_join("settings.cfg")
	root.add_child(main)
	main.photo.history_enabled = false
	main.photo.mode_memory = Memory.new(folder.path_join("main_modes"))
	main.recent_menu._local_entries = entries
	main.recent_menu.section = main.recent_menu.Section.LOCAL
	main.recent_menu.refresh()
	main._on_library_chosen(entries[0].uri, entries[0].title)
	await settle(main.photo)
	check(main.photo_active and main.player_menu == main.photo_menu and main.video.local_uri.is_empty(), "Main routes images to photo session and closes video")
	check(main.photo_menu.visible and not main.video_menu.visible and not main.recent_menu.visible, "Only photo floating controls open")
	main.photo_menu.dismiss()
	var photo_controls := preload("res://scripts/player_stick_controls.gd").new()
	main._apply_stick_actions(photo_controls.poll(Vector2(.99, 0), Vector2.ZERO, true))
	check(main.photo.index == 0, "Left video-seek shortcut does not change photos")
	main._apply_stick_actions([{"operation":"seek", "direction":1}])
	await settle(main.photo)
	check(main.photo.index == 1, "Right horizontal shortcut changes photo")
	main._apply_stick_actions([{"operation":"zoom", "amount":1.0}], .2)
	var enlarged: float = main.photo.screen_scale
	check(enlarged > 1.0 and not main.photo.inspect and main.photo.material.get_shader_parameter("content_zoom") == 1.0,
		"Right vertical shortcut enlarges the complete photo without cropping or entering inspect")
	main.photo.set_corner_hover(1)
	for curve in [0.0, 1.0]:
		main.photo.set_screen_curve(curve)
		var before: Vector3 = main.photo.screen_corner(1)
		var handle: Vector3 = main.photo._handles[1].position
		main._apply_stick_actions([{"operation":"zoom", "amount":-1.0}], .1)
		var after: Vector3 = main.photo.screen_corner(1)
		check(after.y < before.y and main.photo._handles[1].position.y < handle.y, "Flat/curved photo mesh and visible corner shrink together: %s" % curve)
		var origin: Vector3 = main.photo.panel.to_global(Vector3(0,0,2))
		check(main.photo.corner_at(origin, (main.photo.panel.to_global(after)-origin).normalized()) == 1, "Resized corner ray hit follows the visible photo: %s" % curve)
	main._apply_stick_actions([{"operation":"zoom", "amount":1.0}], 10)
	check(main.photo.screen_scale == main.photo.SCALE_LIMITS.y, "Whole-photo enlargement clamps at screen limit")
	main._apply_stick_actions([{"operation":"zoom", "amount":-1.0}], 10)
	check(main.photo.screen_scale == main.photo.SCALE_LIMITS.x, "Whole-photo shrink clamps at screen limit")
	main._reset_picture()
	check(main.photo.screen_scale == 1.0 and not main.photo.inspect, "Right stick press restores photo size")
	main._apply_stick_actions([{"operation":"seek", "direction":1}])
	await settle(main.photo)
	check(main.photo.index == 2, "Zooming does not block next-photo shortcut")
	main.photo.set_projection(3)
	main._apply_stick_actions([{"operation":"zoom", "amount":1.0}], .2)
	check(main.photo.inspect and main.photo._detail.visible and main.photo.screen_scale == 1.0, "Panorama stick zoom retains its independent detail window")
	main.photo.set_projection(0)
	main._on_library_chosen("file://fake.mp4", "fake.mp4")
	check(not main.photo_active and main.player_menu == main.video_menu and not main.photo.panel.visible, "Video reopen restores video controller and hides photos")
	var host := PhotoHost.new()
	host.ready = main.photo._on_ready; host.depth = main.photo._on_depth
	host.depth_path = folder.path_join("near.bin")
	var near := Image.create(252,140,false,Image.FORMAT_RF)
	near.fill(Color(.8,0,0))
	FileAccess.open(host.depth_path, FileAccess.WRITE).store_buffer(near.get_data())
	main.photo.platform = host
	main._on_library_chosen(entries[0].uri, entries[0].title)
	await settle(main.photo)
	main.photo_menu._activate(Menu.PHOTO_DEPTH)
	await process_frame
	check(main.photo.depth_requested and main.photo.depth_enabled and main.photo_menu._depth_open, "Photo icon opens slider and prepares one depth map")
	var original_knob: Object = main.photo_menu._depth_knob
	var original_texture: Object = main.photo._depth_texture
	var y := lerpf(Menu.DEPTH_SPAN.x, Menu.DEPTH_SPAN.y, Menu.DepthStrength.to_fraction(1.75))
	var controls: Node3D = main.photo_menu
	controls.press_pointer("left_hand", controls.to_global(Vector3(Menu.DEPTH_X,y,1)), -controls.global_basis.z, true)
	check(is_equal_approx(main.photo.depth_strength, 1.75) and is_equal_approx(main.photo.material.get_shader_parameter("depth_strength"),1.75)
		and is_equal_approx(main.photo._detail_material.get_shader_parameter("depth_strength"),1.75), "Photo and detail shaders receive live 175% strength")
	check(host.inference == 1 and main.photo._depth_texture == original_texture and controls._depth_knob == original_knob, "Dragging reuses depth map and UI meshes")
	controls.release_pointer("left_hand",Vector3.ZERO,Vector3.ZERO,false)
	main._on_photo_action("photo_next")
	await settle(main.photo); await process_frame
	check(main.photo.index == 1 and main.photo.depth_requested and main.photo.depth_enabled and main.photo.depth_strength == 1.75 and host.inference == 2,
		"Next photo retains 3D choice and strength, estimates the new image once")
	main.photo.set_projection(3)
	check(not main.photo.depth_enabled and main.photo.auto_depth, "Panorama temporarily bypasses 3D without clearing preference")
	main.photo.set_projection(0)
	check(main.photo.depth_enabled and main.photo.depth_strength == 1.75, "Returning to flat photo restores 3D")
	main._on_depth_strength(0.0,true)
	main._on_photo_action("photo_next")
	await settle(main.photo); await process_frame
	check(not main.photo.depth_requested and not main.photo.auto_depth and not main.video.auto_depth and host.inference == 2,
		"Manual Off applies to both media types and stays off on the next photo")
	main._on_depth_strength(1.5,true); main._save_depth_strength()
	var saved := ConfigFile.new(); saved.load(main.settings_path)
	check(is_equal_approx(saved.get_value("photo","depth_strength"), 1.5) and saved.get_value("effects","auto_3d") and main.video.auto_depth,
		"Photo preference also enables following videos and saves independent photo strength")
	main.photo.set_projection(3)
	main._on_photo_action("lock_mode")
	saved.load(main.settings_path)
	check(saved.get_value("photo", "mode_lock").geometry == 3 and main.video.mode_lock.is_empty(), "Photo lock saves independently of video mode")
	var restored := Main.new()
	restored.settings_path = main.settings_path
	root.add_child(restored)
	check(restored.video.auto_depth and restored.photo.auto_depth and is_equal_approx(restored.photo.depth_strength, 1.5) and restored.video.depth_strength == 1.0,
		"Restart restores shared auto-3D choice and separate strengths")
	check(restored.photo.mode_lock.geometry == 3 and restored.video.mode_lock.is_empty(), "Restart restores panorama photo lock without locking videos")
	main._on_photo_action("lock_mode"); saved.load(main.settings_path)
	check(saved.get_value("photo", "mode_lock").is_empty(), "Unlock is saved across restarts")
	restored.queue_free()
	main.queue_free(); library.queue_free(); menu.queue_free(); photo.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("Photo regression: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
