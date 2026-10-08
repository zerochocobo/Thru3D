extends Node
## Debug-receiver-only JNI/UI contract probe. Lists local accounts, never remote files.
const Menu := preload("res://scripts/library_menu.gd")
var menu: Node
var platform: Object
var request := -1
var finished := false

func start(value: Object) -> void:
	platform = value
	menu = Menu.new()
	add_child(menu)
	menu.attach_platform(platform)
	platform.connect("media_list", _receive)
	menu.section = Menu.Section.CLOUD
	# Empty path lists locally stored accounts; synthetic page two tests a nonzero offset.
	menu._cloud_stack = [{"id": "", "title": ""}]
	menu._cloud_offsets.assign([0, 48])
	menu._load_cloud(false, false, 1)
	if not menu._pending.is_empty(): request = int(menu._pending.keys()[0])
	get_tree().create_timer(10.0).timeout.connect(_finish.bind(false))

func _receive(id: int, payload: String) -> void:
	if id != request: return
	var data: Variant = JSON.parse_string(payload)
	_finish(data is Dictionary and data.get("state") == "ready" and int(data.get("offset", -1)) == 48 \
		and menu._cloud_page == 1 and not menu._cloud_busy and menu.status.is_empty())

func _finish(passed: bool) -> void:
	if finished: return
	finished = true
	var report := {"passed": passed, "object_has_method": platform.has_method("media_cloud_page"),
		"java_page_supported": Menu.PlatformMethods.supports(platform, "media_cloud_page"),
		"java_cancel_supported": Menu.PlatformMethods.supports(platform, "media_cloud_cancel"),
		"committed_page": menu._cloud_page, "busy": menu._cloud_busy}
	DiagnosticLog.record("cloud_page_jni_probe", report)
	platform.disconnect("media_list", _receive)
	menu._cancel_cloud()
	queue_free()
