extends SceneTree
const Photo := preload("res://scripts/photo_display.gd")
var failures: Array[String] = []
var checks := 0
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func _initialize() -> void:
	var path := "user://photo_depth_payload_%d.bin" % Time.get_ticks_usec()
	var image := Image.create(518,518,false,Image.FORMAT_RF)
	image.fill(Color(.75,0,0))
	FileAccess.open(path,FileAccess.WRITE).store_buffer(image.get_data())
	var payload := {"state":"ready", "width":518, "height":518, "path":path, "rect":[76.0/518,0,366.0/518,1]}
	var decoded := Photo._read_depth(JSON.stringify(payload))
	check(not decoded.is_empty() and decoded.image.get_size() == Vector2i(518,518), "Accept photo model output")
	check(not decoded.is_empty() and is_equal_approx(decoded.image.get_pixel(200,200).r,.75), "Keep RF precision")
	check(not decoded.is_empty() and is_equal_approx(decoded.rect.x,76.0/518), "Keep content rectangle")
	var pair_path := path + ".png"
	var pair := Image.create(64,32,false,Image.FORMAT_RGB8)
	pair.fill(Color.GREEN); pair.fill_rect(Rect2i(0,0,32,32),Color.RED); pair.save_png(pair_path)
	var stereo_payload := payload.duplicate(true)
	stereo_payload.merge({"stereo_path":pair_path,"stereo_width":64,"stereo_height":32,"stereo_strength":1.25,"stereo_strategy":"video_soft_shift_gpu"})
	decoded = Photo._read_depth(JSON.stringify(stereo_payload))
	check(decoded.has("stereo_image") and decoded.stereo_image.get_pixel(4,4).r > .9 and decoded.stereo_image.get_pixel(40,4).g > .9, "Preserve generated eye packing and colors")
	check(decoded.get("strength",0) == 1.25 and decoded.stereo_image.has_mipmaps(), "Carry render strength and generate mips")
	for invalid in [{"stereo_strength":3},{"stereo_strategy":"inverse"},{"stereo_width":8194},{"stereo_height":2},{"stereo_strength":"bad"}]:
		var broken := stereo_payload.duplicate(true); broken.merge(invalid,true)
		check(Photo._read_depth(JSON.stringify(broken)).is_empty(), "Reject incompatible or malformed generated pair")
	DirAccess.remove_absolute(pair_path)
	# Android hands over the GPU pair as raw RGBA rows (no PNG): same packing, exact length.
	var raw_path := path + ".rgba"
	var raw := pair.duplicate(); raw.convert(Image.FORMAT_RGBA8)
	FileAccess.open(raw_path,FileAccess.WRITE).store_buffer(raw.get_data())
	var raw_payload := stereo_payload.duplicate(true); raw_payload.stereo_path = raw_path
	decoded = Photo._read_depth(JSON.stringify(raw_payload))
	check(decoded.has("stereo_image") and decoded.stereo_image.get_pixel(4,4).r > .9 and decoded.stereo_image.get_pixel(40,4).g > .9 and decoded.stereo_image.has_mipmaps(), "Read raw RGBA pair without decoding")
	FileAccess.open(raw_path,FileAccess.WRITE).store_buffer(raw.get_data().slice(0,100))
	check(Photo._read_depth(JSON.stringify(raw_payload)).is_empty(), "Reject truncated raw pair")
	DirAccess.remove_absolute(raw_path)
	for rect in [[0,0,1],[-.1,0,1,1],[0,0,0,1],[.5,0,1,1],[0,0,"1",1],[0,0,null,1]]:
		payload.rect = rect
		check(Photo._read_depth(JSON.stringify(payload)).is_empty(), "Reject invalid rectangle: " + str(rect))
	payload.rect = [0,0,1,1]
	payload.width = 8192; payload.height = 8192
	check(Photo._read_depth(JSON.stringify(payload)).is_empty(), "Reject oversized allocation")
	payload.width = 518; payload.height = 518
	FileAccess.open(path,FileAccess.WRITE).store_8(0)
	check(Photo._read_depth(JSON.stringify(payload)).is_empty(), "Reject truncated depth")
	DirAccess.remove_absolute(path)
	check(Photo._read_depth(JSON.stringify(payload)).is_empty(), "Reject missing depth")
	for failure in failures: push_error(failure)
	print("Photo depth payload: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
