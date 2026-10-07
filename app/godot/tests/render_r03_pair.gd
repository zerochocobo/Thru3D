extends SceneTree

const Probe := preload("res://scripts/pair_material_probe.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var report: Dictionary = await Probe.new().run(root)
	var output := OS.get_environment("QUEST_R03_PAIR_PATH")
	if output.is_empty():
		output = "user://r03-pair-render.json"
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(report, "\t"))
	else:
		report.failures.append("Cannot save render report")
		report.state = "failed"
	for failure in report.failures:
		push_error(failure)
	print("R03 native texture/shader samples: %d; failures: %d" % [report.samples.size(), report.failures.size()])
	quit(0 if report.state == "passed" else 1)