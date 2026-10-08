extends RefCounted
## Account operations are separate from cloud file browsing; no remote files are deleted.
const I18n := preload("res://scripts/i18n.gd")
const EDIT := 82
const REMOVE := 83
const BACK := 84
var menu: Node
var mode := ""
var removing := {}
var request_id := 0

func _init(owner: Node) -> void:
	menu = owner

func reset() -> void:
	mode = ""
	removing = {}

func changed() -> void:
	menu._cloud_setup = false
	reset()
	menu._cancel_cloud()
	menu._cloud_positions.clear()
	menu._cloud_location = ""
	menu._cloud_stack = []
	menu._cloud_entries = []
	menu._cloud_page = 0
	menu._cloud_offsets.assign([0])
	menu._cloud_next = -1
	menu._cloud_total = -1
	if menu.section == menu.Section.CLOUD:
		menu._load_cloud()
		menu.refresh()

func receive(id: int, payload: String) -> bool:
	if id != 0 and (request_id == 0 or id != request_id): return false
	var data: Variant = JSON.parse_string(payload)
	if id == 0:
		if data is Dictionary and data.get("source") == "cloud" and data.get("state") == "accounts_changed":
			changed()
			return true
		return false
	request_id = 0
	if data is Dictionary and data.get("state") == "ready":
		# Store notification normally refreshed already; older backends may only reply.
		if not mode.is_empty(): changed()
	elif menu.section == menu.Section.CLOUD and mode == "confirm":
		menu.status = str(data.get("error", "Cloud connection failed")) if data is Dictionary else "Cloud connection failed"
		menu.refresh()
	return true

func action(target: int) -> bool:
	if target not in [EDIT, REMOVE, BACK]: return false
	if request_id > 0: return true
	if target == EDIT:
		menu.account_panel.open("cloud", true)
	elif target == REMOVE:
		mode = "remove"
		removing = {}
		if not menu._cloud_stack.is_empty():
			menu._cloud_stack = []
			menu._load_cloud()
		menu._reset_navigation()
		menu.refresh()
	else:
		if mode == "confirm": mode = "remove"; removing = {}
		else: reset()
		menu._reset_navigation()
		menu.refresh()
	return true

func rows() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if mode == "confirm":
		result.append({"title": I18n.t("Remove account") + ": " + str(removing.title), "icon": "trash", "cloud_confirm_remove": true})
		result.append({"title": I18n.t("Cancel"), "icon": "up", "cloud_cancel_remove": true})
	else:
		for item in menu._cloud_entries:
			result.append({"title": str(item.title), "icon": "trash", "cloud_remove": item})
	return result

func choose(row: Dictionary) -> bool:
	if mode.is_empty(): return false
	if request_id > 0: return true
	if row.has("cloud_remove"):
		removing = row.cloud_remove.duplicate(true)
		mode = "confirm"
	elif row.has("cloud_cancel_remove"):
		mode = "remove"; removing = {}
	elif row.has("cloud_confirm_remove") and menu.platform and not removing.is_empty():
		# Only the root account ID is accepted; never a file/folder operation.
		var account_id := str(removing.id).trim_prefix("/")
		if account_id.is_empty() or account_id.contains("/"): return true
		request_id = menu.platform.media_cloud_remove(account_id)
		menu.status = "Loading…" if request_id > 0 else "Cloud connection failed"
	menu._reset_navigation()
	menu.refresh()
	return true

func draw() -> void:
	var available: bool = menu.platform != null and request_id == 0
	if mode.is_empty():
		menu._button(EDIT, "", Vector2(0.47, 0.46), Vector2(0.09, 0.07), available, "edit")
		menu._tips[EDIT] = I18n.t("Edit")
		menu._button(REMOVE, "", Vector2(0.58, 0.46), Vector2(0.09, 0.07), available and menu.PlatformMethods.supports(menu.platform, "media_cloud_remove") and (not menu._cloud_entries.is_empty() or not menu._cloud_stack.is_empty()), "trash")
		menu._tips[REMOVE] = I18n.t("Remove account")
	else:
		menu._button(BACK, "", Vector2(-0.52, 0.46), Vector2(0.09, 0.07), request_id == 0, "up")
		var label: Label3D = menu._label(I18n.t("Remove account"), Vector3(-0.42, 0.46, 0.004), 24)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
