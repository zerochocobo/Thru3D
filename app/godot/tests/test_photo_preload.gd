extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Thumbnails := preload("res://scripts/thumbnail_cache.gd")
var folder := "user://photo_preload_%d" % Time.get_ticks_usec()
var failures: Array[String] = []
var checks := 0

class Host extends RefCounted:
	var ready: Callable
	var folder := ""
	var next_id := 100
	var opens := 0
	var preloads := 0
	var held := {}
	var pending := {}
	var cancelled: Array[int] = []
	var activated: Array[int] = []
	var depth: Callable
	var preload_depth: Callable
	var depth_pending := {}
	var background_depth := {}
	var depth_paths := {}
	var depth_values := {}
	var depth_calls := 0
	var model_calls := 0
	var use_stereo := false
	var strengths := {}
	var pair_paths := {}
	var runtime_releases := 0
	func has_java_method(method: String) -> bool:
		return method in ["preload_photo", "activate_photo", "prepare_photo_depth", "prepare_preloaded_photo_depth", "cancel_preloaded_photo_depth"] \
			or method == "release_photo_depth_runtime" \
			or (use_stereo and method in ["prepare_photo_3d", "prepare_preloaded_photo_3d", "update_photo_3d_strength"])
	func make_file(uri: String) -> Dictionary:
		next_id += 1
		var path := folder.path_join("cache_%d.jpg" % next_id)
		DirAccess.copy_absolute(uri.trim_prefix("file://"), path)
		held[next_id] = path
		return {"id": next_id, "path": path}
	func open_photo(uri: String) -> int:
		opens += 1
		var file := make_file(uri)
		ready.call_deferred(file.id, JSON.stringify({"state":"ready", "path":file.path, "cache_bytes":4096}))
		return int(file.id)
	func preload_photo(uri: String) -> int:
		preloads += 1
		var file := make_file(uri)
		pending[file.id] = file.path
		return int(file.id)
	func complete() -> void:
		for id in pending.keys():
			ready.call_deferred(int(id), JSON.stringify({"state":"ready", "path":pending[id], "cache_bytes":4096}))
		pending.clear()
	func activate_photo(id: int) -> bool:
		if not held.has(id): return false
		activated.append(id)
		return true
	func release_photo(id: int) -> void:
		if held.has(id): DirAccess.remove_absolute(str(held[id])); held.erase(id)
		if depth_paths.has(id): DirAccess.remove_absolute(str(depth_paths[id])); depth_paths.erase(id)
		if pair_paths.has(id): DirAccess.remove_absolute(str(pair_paths[id])); pair_paths.erase(id)
		depth_pending.erase(id); background_depth.erase(id)
	func cancel_photo(id: int) -> void: cancelled.append(id); release_photo(id)
	func prepare_photo_depth(id: int) -> bool:
		if not held.has(id): return false
		if depth_pending.has(id): return true
		depth_calls += 1; depth_pending[id] = true
		if not depth_paths.has(id): model_calls += 1
		return true
	func prepare_preloaded_photo_depth(id: int) -> bool:
		if not prepare_photo_depth(id): return false
		background_depth[id] = true
		return true
	func prepare_photo_3d(id: int, strength: float) -> bool:
		strengths[id] = strength
		return prepare_photo_depth(id)
	func prepare_preloaded_photo_3d(id: int, strength: float) -> bool:
		strengths[id] = strength
		return prepare_preloaded_photo_depth(id)
	func cancel_preloaded_photo_depth() -> void:
		for id in background_depth: depth_pending.erase(id)
		background_depth.clear()
	func update_photo_3d_strength(strength: float) -> void:
		for id in depth_pending: strengths[id] = strength
	func release_photo_depth_runtime() -> void: runtime_releases += 1
	func complete_depth(id: int, success: bool = true) -> void:
		var callback: Callable = preload_depth if background_depth.has(id) else depth
		depth_pending.erase(id); background_depth.erase(id)
		if not success:
			callback.call_deferred(id, '{"state":"error"}')
			return
		var image := Image.create(518,518,false,Image.FORMAT_RF)
		var value := .2 + float(id % 6) * .1
		image.fill(Color(value,0,0))
		var path := folder.path_join("depth_%d.bin" % id)
		FileAccess.open(path,FileAccess.WRITE).store_buffer(image.get_data())
		depth_paths[id] = path; depth_values[id] = value
		var payload := {"state":"ready", "path":path, "width":518, "height":518, "rect":[76.0/518.0,0,366.0/518.0,1]}
		if use_stereo:
			var pair := Image.create(640,160,false,Image.FORMAT_RGB8)
			pair.fill(Color(value,.3,.4))
			var pair_path := folder.path_join("pair_%d.png" % id)
			pair.save_png(pair_path); pair_paths[id] = pair_path
			payload.merge({"stereo_path":pair_path,"stereo_width":640,"stereo_height":160,"stereo_strength":strengths[id],"stereo_strategy":"video_soft_shift_gpu"})
		callback.call_deferred(id, JSON.stringify(payload))

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func settle(photo: Node3D) -> void:
	var deadline := Time.get_ticks_msec() + 4000
	while photo.loading and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	check(not photo.loading, "Foreground settles")

func warm(photo: Node3D, host: RefCounted) -> void:
	photo.finish_transition()
	var deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline:
		host.complete()
		for id in host.depth_pending.keys(): host.complete_depth(int(id))
		photo._pump_prefetch()
		if preloads_ready(photo,host): break
		await create_timer(.01).timeout
	check(preloads_ready(photo,host), "Adjacent preloads settle at the selected strength")

func preloads_ready(photo: Node3D, host: RefCounted) -> bool:
	for target in photo._neighbors(photo.index):
		if not photo._prefetched.has(target): return false
		var entry: Dictionary = photo._prefetched[target]
		if not entry.get("decoded", false): return false
		if photo.auto_depth:
			if not entry.has("depth_data"): return false
			if host.use_stereo and not is_equal_approx(float(entry.depth_data.get("strength", -1)), photo.depth_strength): return false
	return true

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	var entries: Array[Dictionary] = []
	for i in 4:
		var image := Image.create(320,160,false,Image.FORMAT_RGB8)
		image.fill(Color(float(i)/4.0,.4,.6))
		var path := ProjectSettings.globalize_path(folder.path_join("photo_%d.jpg" % i))
		image.save_jpg(path)
		entries.append({"uri":"file://"+path, "title":"photo_%d.jpg" % i, "kind":"image"})
	var photo := Photo.new()
	photo.mode_memory = Memory.new(folder.path_join("modes")); photo.history_enabled = false
	root.add_child(photo)
	var host := Host.new(); host.folder = ProjectSettings.globalize_path(folder); host.ready = photo._on_ready
	photo.platform = host
	photo.open_image(entries[0].uri, entries[0].title, entries)
	await settle(photo); await warm(photo,host)
	check(host.opens == 1 and host.preloads == 2, "Initial display preloads next and wrapping previous through independent API")
	check(photo._prefetched.has(1) and photo._prefetched.has(3) and photo._prefetched.size() == 2, "Only two circular neighbours retained")
	check(Thumbnails.has(entries[1].uri) and Thumbnails.has(entries[3].uri), "Preloading persists thumbnails before neighbours are viewed")
	check(photo._prefetched[3].result.get("thumbnail_cached", false), "Cached decoded data remembers its persisted thumbnail")
	DirAccess.remove_absolute(Thumbnails.path_for(entries[3].uri))
	var first_request: int = photo._display_request
	var count: int = host.opens
	photo.navigate(-1)
	check(not photo.loading and photo.index == 3 and host.opens == count, "First-to-last uses decoded cache without foreground transfer")
	check(photo._transition_direction == -1, "Wrapping previous still enters from left")
	check(Thumbnails.has(entries[3].uri), "Cache hit restores a thumbnail removed by cache cleanup")
	await warm(photo,host)
	check(photo._prefetched.has(0) and int(photo._prefetched[0].id) == first_request, "Departing photo keeps its source and decoded data for return")
	photo.navigate(1)
	check(photo.index == 0 and not photo.loading and host.opens == count and photo._transition_direction == 1, "Last-to-first returns from cache with right entry")
	await warm(photo,host)
	photo.navigate(-1); photo.navigate(-1); photo.navigate(1)
	await settle(photo)
	check(photo.index == 3 and photo.pending_index == -1, "Rapid reversal back to displayed photo cancels stale request")
	host.complete(); await create_timer(.05).timeout
	check(photo.index == 3, "Late preload/foreground responses cannot overwrite chosen photo")
	await warm(photo,host)
	var invalid_id: int = photo._prefetched[2].id
	host.release_photo(invalid_id)
	count = host.opens
	photo.navigate(-1); await settle(photo)
	check(photo.index == 2 and host.opens == count + 1, "Missing cached source retries through normal foreground loading")
	await warm(photo,host)
	# A cancelled decoder owns its file until the worker returns.
	while photo._thread: await create_timer(.01).timeout
	photo.set_process(false)
	var neighbour: int = photo._neighbors(photo.index)[0]
	var id: int = photo._prefetched[neighbour].id
	var source_path: String = host.held[id]
	var entered := Semaphore.new(); var release := Semaphore.new()
	photo._decoding = {"id":id, "index":neighbour, "prefetch":true, "epoch":photo._cache_epoch}
	photo._thread = Thread.new()
	photo._thread.start(func(): entered.post(); release.wait(); return {"uncached":true})
	entered.wait()
	photo._drop_prefetch(neighbour)
	check(FileAccess.file_exists(source_path) and photo._deferred_release_ids.has(id), "Pruning does not unlink an active decoder source")
	release.post()
	while photo._thread.is_alive(): await create_timer(.01).timeout
	photo._process(0)
	check(not FileAccess.file_exists(source_path) and not photo._deferred_release_ids.has(id), "Worker completion releases the cancelled file lease")
	photo.set_process(true)
	photo.set_projection(3)
	photo._pump_prefetch()
	check(photo._prefetched.is_empty() and not photo.navigate(5), "Panorama keeps bounded navigation and has no background neighbour cache")
	photo.close_image()
	check(host.held.is_empty() and photo._prefetched.is_empty(), "Closing releases displayed and neighbouring sources")
	photo.open_image(entries[0].uri, entries[0].title)
	await settle(photo)
	count = host.preloads
	check(not photo.navigate(-1) and not photo.navigate(1) and not photo.snapshot().can_next, "Single-photo queue cannot navigate to itself")
	photo._pump_prefetch(); check(host.preloads == count, "Single photo starts no redundant preload")
	photo.open_image(entries[0].uri, entries[0].title, entries.slice(0,2))
	await settle(photo); await warm(photo,host)
	check(photo._prefetched.size() == 1, "Two-photo queue deduplicates previous/next to one preload")
	photo.navigate(-1)
	check(photo.index == 1 and photo._transition_direction == -1, "Two-photo reverse direction survives identical neighbour target")
	photo.queue_free(); await process_frame
	check(host.held.is_empty(), "Exiting releases all cache file ownership")
	# Large sources are retained as files; their tiny preview can still be cached.
	var large := Image.create(1,1,false,Image.FORMAT_RGB8).save_png_to_buffer()
	large[16]=0; large[17]=0; large[18]=32; large[19]=0
	large[20]=0; large[21]=0; large[22]=16; large[23]=0
	var large_path := ProjectSettings.globalize_path(folder.path_join("large-header.png"))
	FileAccess.open(large_path, FileAccess.WRITE).store_buffer(large)
	var bounded := Photo._decode({"prefetch":true, "info":{"path":large_path, "thumbnail_path":str(entries[0].uri).trim_prefix("file://"), "orientation":6}})
	check(bounded.get("uncached", false) and not bounded.has("image"), "8K predecode is skipped before allocating pixels above the cache budget")
	check(bounded.has("thumbnail") and bounded.thumbnail.get_height() > bounded.thumbnail.get_width(), "Large-file thumbnail remains available with EXIF orientation")
	await check_converted(entries)
	await check_baked(entries)
	await check_joined(entries, false)
	await check_joined(entries, true)
	await check_recent_files(entries)
	for failure in failures: push_error(failure)
	print("Photo preload/cycle: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func wait_depth(photo: Node3D) -> void:
	var deadline := Time.get_ticks_msec() + 4000
	while photo._pending_display.is_empty() and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	check(not photo._pending_display.is_empty(), "Decoded photo waits for its conversion result")

func check_converted(entries: Array[Dictionary]) -> void:
	var photo := Photo.new(); photo.auto_depth = true; photo.history_enabled = false
	photo.mode_memory = Memory.new(folder.path_join("converted_modes"))
	root.add_child(photo)
	var host := Host.new(); host.folder = ProjectSettings.globalize_path(folder)
	host.ready = photo._on_ready; host.depth = photo._on_depth; host.preload_depth = photo._on_prefetch_depth; photo.platform = host
	photo.open_image(entries[0].uri, entries[0].title, entries)
	await wait_depth(photo)
	check(photo.loading and not photo.panel.visible and photo.index == -1, "First photo cannot appear as 2D while conversion is pending")
	host.complete_depth(photo._request); await settle(photo)
	check(photo.depth_enabled and photo.material.get_shader_parameter("photo_depth"), "Initial display starts with its colour and depth together")
	await warm(photo,host)
	var original_id: int = photo._display_request
	var original_value: float = host.depth_values[original_id]
	var next_id: int = photo._prefetched[3].id
	var next_value: float = host.depth_values[next_id]
	var calls: int = host.depth_calls
	photo.navigate(-1)
	check(not photo.loading and photo.index == 3 and photo.depth_enabled and host.depth_calls == calls, "Preconverted neighbour switches immediately without another inference")
	check(is_equal_approx(photo._depth_texture.get_image().get_pixel(0,0).r, next_value), "Incoming photo uses its own preloaded depth map")
	check(photo._departing.material_override.get_shader_parameter("photo_depth") \
		and is_equal_approx(photo._departing.material_override.get_shader_parameter("depth_texture").get_image().get_pixel(0,0).r, original_value),
		"Departing transition keeps the previous photo's depth")
	photo.set_hand_scale(2)
	var depth_texture: Texture2D = photo._depth_texture
	photo.pan_hand(Vector2(.1,.05))
	check(photo.depth_enabled and photo._depth_texture == depth_texture and host.depth_calls == calls, "Whole-photo zoom and pan preserve depth without reinference")
	photo.finish_transition()
	photo.navigate(1)
	check(photo.index == 0 and photo.depth_enabled and is_equal_approx(photo._depth_texture.get_image().get_pixel(0,0).r, original_value), "Wrapping back restores original depth with its colour")
	photo.finish_transition()
	photo._drop_prefetch(1)
	photo.navigate(1)
	await wait_depth(photo)
	check(photo.index == 0 and photo.depth_enabled and photo.loading, "Uncached conversion keeps the previous 3D photo visible")
	photo._on_prefetch_depth(photo._request, '{"state":"error"}')
	check(photo.loading and not photo._pending_display.is_empty(), "Late background error cannot fail a foreground retry with the same file ID")
	host.complete_depth(photo._request, false); await process_frame
	check(photo.index == 0 and photo.depth_enabled and photo.error == "3D unavailable" and not photo.loading, "Conversion failure never flashes a new 2D photo")
	photo.close_image(); photo.queue_free(); await process_frame
	check(host.held.is_empty() and host.depth_paths.is_empty(), "Converted colour and depth caches release together")

func check_baked(entries: Array[Dictionary]) -> void:
	var photo := Photo.new(); photo.auto_depth = true; photo.history_enabled = false
	photo.mode_memory = Memory.new(folder.path_join("baked_modes")); root.add_child(photo)
	var host := Host.new(); host.use_stereo = true; host.folder = ProjectSettings.globalize_path(folder)
	host.ready = photo._on_ready; host.depth = photo._on_depth; host.preload_depth = photo._on_prefetch_depth; photo.platform = host
	photo.open_image(entries[0].uri,entries[0].title,entries)
	await wait_depth(photo)
	check(not photo.panel.visible, "Native first photo remains hidden until repaired eyes decode")
	host.complete_depth(photo._request); await settle(photo)
	check(photo.depth_enabled and photo._stereo_texture != null and photo.material.get_shader_parameter("photo_stereo"), "Native photo atomically starts with a repaired stereo pair")
	await warm(photo,host)
	var calls: int = host.depth_calls
	var original: Texture2D = photo._stereo_texture
	photo.navigate(-1)
	check(photo.index == 3 and not photo.loading and host.depth_calls == calls and photo._stereo_texture != original, "Preloaded generated eyes wrap immediately with the matching source")
	check(photo._departing.material_override.get_shader_parameter("stereo_texture") == original and photo._departing.material_override.get_shader_parameter("photo_stereo"), "Departing transition retains its own repaired eyes")
	photo.finish_transition(); original = photo._stereo_texture
	photo.set_hand_scale(2); photo.pan_hand(Vector2(.1,.05))
	check(photo._stereo_texture == original and host.depth_calls == calls, "Pinch pan/zoom reuse repaired eyes")
	photo.set_depth_strength(0.75)
	check(photo._stereo_texture == original, "Strength adjustment keeps the previous repaired pair during rebuilding")
	await create_timer(.2).timeout
	var id: int = photo._display_request
	check(host.strengths[id] == 0.75, "Debounced strength rebuild requests the selected strength")
	host.complete_depth(id)
	var until := Time.get_ticks_msec()+4000
	while photo.snapshot().render_strength != 0.75 and Time.get_ticks_msec()<until: await create_timer(.01).timeout
	check(photo.snapshot().render_strength == 0.75 and photo._stereo_texture != original, "Latest rebuilt pair replaces the old pair after decoding")
	await warm(photo,host)
	check(photo._neighbors(photo.index).all(func(target): return is_equal_approx(float(photo._prefetched[target].depth_data.strength), .75)),
		"Strength changes refresh preloaded stereo pairs to the selected value")
	photo.set_projection(3)
	check(not photo.material.get_shader_parameter("photo_stereo"), "Panorama bypasses generated eyes")
	photo.close_image(); photo.queue_free(); await process_frame
	check(host.held.is_empty() and host.pair_paths.is_empty(), "Generated pair files release with their source")
	check(host.runtime_releases > 0, "Closing the viewer releases the resident photo model")

func check_joined(entries: Array[Dictionary], baked: bool) -> void:
	var photo := Photo.new(); photo.auto_depth = true; photo.history_enabled = false
	photo.mode_memory = Memory.new(folder.path_join("joined_%s_modes" % baked)); root.add_child(photo)
	var host := Host.new(); host.use_stereo = baked; host.folder = ProjectSettings.globalize_path(folder)
	host.ready = photo._on_ready; host.depth = photo._on_depth; host.preload_depth = photo._on_prefetch_depth; photo.platform = host
	photo.open_image(entries[0].uri,entries[0].title,entries)
	await wait_depth(photo); host.complete_depth(photo._request); await settle(photo)
	photo.finish_transition()
	var deadline := Time.get_ticks_msec()+4000
	while photo._prefetch_depth_request == 0 and Time.get_ticks_msec()<deadline:
		host.complete(); photo._pump_prefetch(); await create_timer(.01).timeout
	var id: int = photo._prefetch_depth_request
	check(id != 0 and host.depth_pending.has(id), "Background conversion is in flight before promotion")
	while photo._thread: await create_timer(.01).timeout
	photo.set_process(false)
	photo._prefetched[1].erase("result") # Force colour decoding to finish after the joined depth.
	var calls: int = host.depth_calls
	photo.navigate(1)
	check(photo._promoted_depth_request == id and host.depth_pending.has(id) and host.depth_calls == calls,
		"Selecting a converting neighbour retains its original work")
	if baked:
		photo.set_depth_strength(.65)
		check(is_equal_approx(float(host.strengths[id]), .65), "Promoted work receives the latest strength without restarting depth")
	host.complete_depth(id)
	await process_frame
	if baked:
		photo._process_depth_jobs()
		while photo._depth_thread and photo._depth_thread.is_alive(): await create_timer(.01).timeout
		photo._process_depth_jobs()
	check(int(photo._incoming_depth_result.get("id", 0)) == id, "Early joined result waits for its matching colour decoder")
	photo.set_process(true); await settle(photo)
	check(photo.index == 1 and photo.depth_enabled and host.depth_calls == calls,
		"Joined preload becomes the displayed photo with no duplicate conversion")
	if baked: check(is_equal_approx(float(photo.snapshot().render_strength), .65), "Promoted eyes use the new strength")
	photo.finish_transition()
	deadline = Time.get_ticks_msec()+4000
	while photo._prefetch_depth_request == 0 and Time.get_ticks_msec()<deadline:
		host.complete(); photo._pump_prefetch(); await create_timer(.01).timeout
	var late: int = photo._prefetch_depth_request
	photo.navigate(1); photo.navigate(-1)
	photo._on_prefetch_depth(late, '{"state":"error"}')
	check(photo.index == 1 and not photo.loading and photo.depth_enabled, "Reversing a promoted selection rejects its late result and keeps the displayed photo")
	photo.finish_transition()
	photo._navigation_direction = -1
	check(photo._neighbors(1) == [0,2], "Previous direction gets preload priority")
	photo.close_image(); photo.queue_free(); await process_frame
	check(host.held.is_empty() and host.depth_pending.is_empty(), "Joined work and source ownership release together")

func check_recent_files(entries: Array[Dictionary]) -> void:
	var photo := Photo.new(); photo.auto_depth = true; photo.history_enabled = false
	photo.mode_memory = Memory.new(folder.path_join("recent_modes")); root.add_child(photo)
	var host := Host.new(); host.use_stereo = true; host.folder = ProjectSettings.globalize_path(folder)
	host.ready = photo._on_ready; host.depth = photo._on_depth; host.preload_depth = photo._on_prefetch_depth; photo.platform = host
	photo.open_image(entries[0].uri,entries[0].title,entries)
	await wait_depth(photo); host.complete_depth(photo._request); await settle(photo); await warm(photo,host)
	var original: int = photo._display_request
	photo.navigate(1); await warm(photo,host)
	photo.navigate(1); await warm(photo,host)
	check(photo._recent_files.has(0) and int(photo._recent_files[0].id) == original, "Recently viewed source survives outside the adjacent window")
	check(not photo._recent_files[0].has("result") and not photo._recent_files[0].has("depth_data"), "Recent cache retains files without decoded images")
	var opens: int = host.opens; var models: int = host.model_calls
	photo._select(0,-1); await wait_depth(photo)
	host.complete_depth(photo._request); await settle(photo)
	check(photo.index == 0 and photo._display_request == original and host.opens == opens and host.model_calls == models,
		"Returning to a recent file reuses its source and depth without transfer or model inference")
	photo.finish_transition()
	var neighbours: Array = photo._neighbors(photo.index)
	await warm(photo,host)
	for target in neighbours:
		photo._prefetched[target].info.cache_bytes = Photo.RECENT_FILE_BYTES
		photo._remember_files(int(target))
	check(photo._recent_files.size() == 1, "Recent disk cache evicts older files at its byte limit")
	photo.close_image()
	check(host.held.is_empty() and photo._recent_files.is_empty(), "Closing removes recent source and converted files")
	for target in range(10,16):
		var cached: Dictionary = host.make_file(entries[0].uri)
		photo._prefetched[target] = {"id":cached.id, "info":{"path":cached.path,"cache_bytes":4096}}
		photo._remember_files(target)
	check(photo._recent_files.size() == Photo.RECENT_FILE_COUNT and not photo._recent_files.has(10), "Recent file count evicts the oldest entries")
	photo.close_image()
	check(host.held.is_empty(), "Count-evicted and retained file leases all close")
	photo.queue_free(); await process_frame
