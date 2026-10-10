extends SceneTree
const Patch := preload("res://scripts/projected_subtitles.gd")
const Depth := preload("res://scripts/subtitle_depth.gd")
var failures: Array[String] = []
var checks := 0
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("VERTICAL_SUBTITLE_OUTPUT")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	preload("res://scripts/i18n.gd").use("zh")
	var patch := Patch.new()
	root.add_child(patch)
	var caption := Label3D.new()
	caption.visible = true
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/video_rvm_pair.gdshader")
	var samples := {"alignment_wrapped": "田".repeat(40), "alignment": "田田田田\n田田田田", "bilingual": "今天的风景很美。\nBeautiful scenery today.",
		"wrapped": "今天的风景很美，我们继续向前走，一起欣赏远处的群山和湖泊。\nWe keep walking and enjoy the mountains and the lake.",
		"punctuation": "你好（世界）！\nこんにちは、世界。\nVR 2026 😀 é", "empty_line": "第一列\n\n第三列"}
	var report := {"samples": {}, "checks": 0, "failures": failures}
	for key in samples:
		caption.text = samples[key]
		patch.update_patch(caption, material, Depth.anchor(0, true), 0.1, 0.063, true)
		await process_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var image := patch.viewport.get_texture().get_image()
		image.save_png(output.path_join(key + ".png"))
		var columns: Array = []
		var reconstructed := ""
		for column in patch.vertical_text.columns:
			columns.append({"text": column.text, "point": [column.point.x, column.point.y], "size": [column.size.x, column.size.y]})
			reconstructed += column.text
		check(reconstructed == str(samples[key]).replace("\n", ""), "All text preserved: " + key)
		check(not patch.label.visible and patch.vertical_text.visible, "Only vertical canvas visible")
		report.samples[key] = columns
		if key.begins_with("alignment"):
			check(columns.size() == 2 if key == "alignment" else columns.size() >= 3, "Explicit newline and automatic wrapping produce separate columns")
			for column in patch.vertical_text.columns:
				var centres: Array[float] = []
				for row in 4:
					var mass := 0.0
					var total := 0.0
					for y in range(int(column.point.y + row * 40), int(column.point.y + (row + 1) * 40)):
						for x in range(int(column.point.x - 28), int(column.point.x + 28)):
							var c := image.get_pixel(x, y)
							var w := minf(c.r, minf(c.g, c.b)) * c.a
							if w < 0.5: continue
							mass += w; total += x * w
					check(mass > 10, "Each glyph cell has visible text")
					centres.append(total / maxf(0.001, mass))
				check(absf(centres[0] - centres[1]) < 0.5 and absf(centres[0] - centres[3]) < 0.5,
					"First glyph shares subsequent glyph centres")
				report.samples[key].append({"glyph_centres": centres})
		if key == "bilingual":
			check(patch.vertical_text.columns.size() == 2 and not patch.vertical_text.columns[0].get("sideways", false)
				and patch.vertical_text.columns[1].get("sideways", false), "Chinese upright and English whole words sideways")
		if key == "wrapped": check(columns.size() > 2, "Long bilingual lines wrap into additional columns")
		if key == "empty_line": check(columns.size() == 3, "Blank lines retain separation")
	caption.text = samples.bilingual
	patch.update_patch(caption, material, Basis(), 5, 0.063, false)
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	patch.viewport.get_texture().get_image().save_png(output.path_join("horizontal.png"))
	check(patch.label.visible and not patch.vertical_text.visible, "Direction switch replaces same cue immediately")
	for angle in [-60.0, 0.0, 60.0]:
		var direction := Depth.anchor(angle, true) * Vector3.FORWARD
		check(is_equal_approx(direction.x, sin(deg_to_rad(angle))) and is_zero_approx(direction.y), "Vertical slider moves left to right")
	check(is_equal_approx(2 * atan(0.063 / (2 * Depth.distance(0))), 2 * atan(0.063 / 0.2)), "0.1m disparity reaches shader")
	caption.free()
	patch.queue_free()
	await process_frame
	report.checks = checks
	report.state = "passed" if failures.is_empty() else "failed"
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	for failure in failures: push_error(failure)
	print("Vertical subtitle render checks=", checks, " failures=", failures.size())
	quit(0 if failures.is_empty() else 1)
