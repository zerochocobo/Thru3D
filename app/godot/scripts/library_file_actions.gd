extends RefCounted
## Editing changes a tile's trigger from playback to single selection. Mutations outlive dismissal.
const Order := preload("res://scripts/library_order.gd")
const SORT := 9100
const EDIT_MODE := 9101
const DELETE_FILE := 9102
const CANCEL := 9103
const CONFIRM := 9104
const CHECK_STATUS := 9105
const ORDER_BASE := 9120
var menu: Node3D
var editing := false
var enabled := false
var selected := ""
var modal := ""
var target: Dictionary = {}
var pending := 0
var checking := false
var uncertain := false
var failed := false
var preparing := false
var plan_ready := false
var orders := {}
var cloud_requested_order := ""
var cloud_committed_order := ""
var cloud_rollback := {}
const Rename := preload("res://scripts/library_rename.gd")
var rename: RefCounted

func _init(owner: Node3D) -> void:
	menu = owner; rename = Rename.new(owner)

func scope() -> String:
	return str(menu.section)

func folder() -> bool:
	return (menu.section == menu.Section.LOCAL and not menu._local_stack.is_empty()) or \
		(menu.section == menu.Section.SMB and not menu._smb_server.is_empty() and not menu._smb_path.is_empty()) or \
		(menu.section == menu.Section.CLOUD and not menu._cloud_stack.is_empty() and menu.cloud_accounts.mode.is_empty())

func order() -> String:
	return Order.normalize(orders.get(scope(), "name_asc"))

func load(value: Dictionary) -> void:
	orders = value.duplicate(true)

func reset() -> void:
	editing = false; selected = ""; modal = ""
	cloud_requested_order = ""; cloud_rollback = {}
	if pending == 0 and not uncertain: target = {}

func selected_row() -> Dictionary:
	for row in menu.rows:
		if not selected.is_empty() and row_uri(row) == selected:
			var result: Dictionary = row.duplicate(true)
			result["uri"] = row_uri(row)
			return result
	return {}

func row_uri(row: Dictionary) -> String:
	return str(row.get("delete_uri", "")) if row.get("folder", false) else str(row.get("uri", ""))

func set_enabled(value: bool) -> void:
	enabled = value
	sync_platform()
	if not enabled: reset()

func sync_platform() -> void:
	if menu.PlatformMethods.supports(menu.platform, "media_file_management_enabled"):
		menu.platform.media_file_management_enabled(enabled)

func can_delete(row: Dictionary) -> bool:
	return enabled and pending == 0 and not uncertain and row.get("can_delete", false) and menu.PlatformMethods.supports(menu.platform, "media_file_delete")

func select(row: Dictionary) -> bool:
	if not enabled or not editing: return false
	if not row_uri(row).is_empty():
		selected = "" if selected == row_uri(row) else row_uri(row)
		if pending == 0 and not uncertain:
			menu.status = str(row.get("delete_reason", "File deletion unavailable for this source")) if not selected.is_empty() and not can_delete(row) else ""
		menu.refresh()
	return true

func sort_rows() -> void:
	if not folder() or menu.section == menu.Section.CLOUD: return
	menu.rows.sort_custom(func(a, b): return Order.before(a, b, order()))

func choose_order(value: String) -> void:
	if value == "source" and menu.section != menu.Section.CLOUD: return
	if menu.section == menu.Section.CLOUD:
		if not menu.PlatformMethods.supports(menu.platform, "media_cloud_sorted_page"): return
		cloud_requested_order = value
		cloud_rollback = {"offsets": menu._cloud_offsets.duplicate(), "page": menu._cloud_page}
		menu._cloud_positions.clear()
		menu._cloud_offsets.assign([0])
		menu._load_cloud(false, false, 0)
	else:
		orders[scope()] = value
		menu.setting_changed.emit("library_orders", orders.duplicate(true))
		menu.scroll = 0.0
	modal = ""; selected = ""
	menu.refresh()

func commit_cloud(value: String) -> void:
	cloud_committed_order = value; cloud_requested_order = ""
	cloud_rollback = {}
	if not value.is_empty():
		orders[scope()] = value
		menu.setting_changed.emit("library_orders", orders.duplicate(true))

func cloud_order() -> String:
	return cloud_requested_order if not cloud_requested_order.is_empty() else Order.normalize(orders.get(str(menu.Section.CLOUD), "name_asc"))

func cloud_failed() -> void:
	if not cloud_rollback.is_empty():
		menu._cloud_offsets.assign(cloud_rollback.offsets)
		menu._cloud_requested_page = int(cloud_rollback.page)
	cloud_requested_order = ""; cloud_rollback = {}

func action(id: int) -> bool:
	if not modal.is_empty():
		if modal == "rename": rename.action(id); return true
		if id == CANCEL: modal = ""; menu.refresh()
		elif modal == "sort" and id >= ORDER_BASE and id < ORDER_BASE + Order.ORDERS.size(): choose_order(Order.ORDERS[id - ORDER_BASE])
		elif modal == "delete" and id == CONFIRM and enabled and pending == 0 and not uncertain and (not target.get("folder", false) or plan_ready): dispatch(false)
		elif id == CHECK_STATUS and uncertain and pending == 0: dispatch(true)
		return true # Modal gaps and stale targets cannot reach the browser.
	if id == SORT and folder() and not editing:
		modal = "sort"; menu.refresh(); return true
	if id == EDIT_MODE and enabled and folder():
		editing = not editing; selected = ""; menu.refresh(); return true
	if id == DELETE_FILE and editing:
		var row := selected_row()
		if can_delete(row):
			target = row.duplicate(true); modal = "delete"; failed = false; plan_ready = false
			if target.get("folder", false): prepare_folder()
			menu.refresh()
		return true
	if id == Rename.OPEN and editing:
		var row := selected_row()
		if rename.can_rename(row): rename.open(row)
		return true
	if id == CHECK_STATUS and uncertain:
		modal = "delete"; menu.refresh(); return true
	return false

func prepare_folder() -> void:
	if not menu.PlatformMethods.supports(menu.platform, "media_file_delete_prepare"):
		failed = true; menu.status = "File deletion unavailable for this source"; return
	preparing = true
	pending = int(menu.platform.media_file_delete_prepare(JSON.stringify(target)))
	if pending <= 0: pending = 0; preparing = false; failed = true

func dispatch(inspect: bool) -> void:
	if target.is_empty() or pending > 0: return
	checking = inspect
	if not inspect: menu.file_delete_preparing.emit(str(target.uri))
	var method := "media_file_delete_status" if inspect else "media_file_delete"
	if not menu.PlatformMethods.supports(menu.platform, method): return
	pending = int(menu.platform.call(method, JSON.stringify(target)))
	if pending <= 0: pending = 0; failed = true
	menu.refresh()

func receive(id: int, payload: String) -> bool:
	if rename.receive(id, payload): return true
	if pending <= 0 or id != pending: return false
	pending = 0
	var result: Variant = JSON.parse_string(payload)
	if not result is Dictionary or str(result.get("uri", "")) != str(target.get("uri", "")):
		uncertain = not preparing; failed = true; menu.status = "Delete result needs checking"
	elif preparing:
		plan_ready = result.get("state") == "ready" and result.get("preview", false)
		if plan_ready:
			for key in ["plan", "files", "folders"]: target[key] = result.get(key, 0)
		else: failed = true; menu.status = str(result.get("error", "File deletion failed"))
	elif result.get("state") == "ready" and (result.get("deleted", false) or (checking and not result.get("exists", true))):
		var uri := str(target.uri)
		uncertain = false; failed = false; modal = ""; selected = ""; target = {}
		for entries in [menu._local_entries, menu._smb_entries, menu._cloud_entries]:
			for i in range(entries.size() - 1, -1, -1):
				if str(entries[i].get("uri", entries[i].get("delete_uri", ""))) == uri: entries.remove_at(i)
		menu.file_deleted.emit(uri)
		menu.status = "File deleted"
	elif checking and result.get("state") == "ready" and result.get("changed", false):
		uncertain = false; failed = true; modal = ""; selected = ""; target = {}
		menu.status = "Cloud file changed. Refresh the folder"
	elif checking and result.get("state") == "ready":
		uncertain = false; failed = true; menu.status = "File still exists"
		if target.get("folder", false): plan_ready = false; prepare_folder()
	else:
		uncertain = checking or result.get("state") == "uncertain"
		failed = true
		menu.status = str(result.get("error", "Delete result needs checking")) if uncertain else str(result.get("error", "File deletion failed"))
	checking = false; preparing = pending > 0 and preparing
	if menu.visible: menu.refresh()
	return true

func draw_header() -> void:
	if not folder(): return
	menu._button(SORT, "", Vector2(0.25, 0.46), Vector2(0.09, 0.07), not editing and not menu._cloud_busy, "sort")
	menu._tips[SORT] = menu.I18n.t("Sort")
	if enabled:
		menu._button(EDIT_MODE, "", Vector2(0.36, 0.46), Vector2(0.09, 0.07), pending == 0, "check" if editing else "select", editing)
		menu._tips[EDIT_MODE] = menu.I18n.t("Done" if editing else "Edit files")

func draw_footer() -> void:
	var row := selected_row()
	var text: String = str(row.get("title", "")) if not row.is_empty() else menu.I18n.t("Select a file or folder")
	var label: Label3D = menu._label(menu._fit_title(text, "", 0.65, 18), Vector3(-0.43, -0.515, 0.004), 18)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	menu._button(Rename.OPEN, menu.I18n.t("Rename"), Vector2(0.38, -0.515), Vector2(0.24, 0.07), rename.can_rename(row), "edit")
	menu._button(DELETE_FILE, menu.I18n.t("Delete folder" if row.get("folder", false) else "Delete file"), Vector2(0.68, -0.515), Vector2(0.28, 0.07), can_delete(row), "trash")
	menu._tips[DELETE_FILE] = menu.I18n.t(str(row.get("delete_reason", "File deletion unavailable for this source"))) if not can_delete(row) else ""

func pending_text() -> String:
	if uncertain: return "Check status"
	if rename.request_id > 0: return "Checking…" if rename.phase == "input" else "Renaming…"
	return "Reading folder contents…" if preparing else "Checking…" if checking else "Deleting…"

func draw_modal() -> void:
	if modal == "rename": rename.draw(); return
	menu._set_backdrop(Vector2(1.12, 0.86), Vector2(0.13, 0))
	menu._label(menu.I18n.t("Sort" if modal == "sort" else "Delete folder" if target.get("folder", false) else "Delete file"), Vector3(0.13, 0.34, 0.004), 25)
	if modal == "sort":
		for i in Order.ORDERS.size():
			if Order.ORDERS[i] == "source" and menu.section != menu.Section.CLOUD: continue
			var field: String = Order.ORDERS[i].get_slice("_", 0)
			var enabled: bool = field in ["name", "source"] or menu.rows.any(func(row): return row.has("uri") and int(row.get(field, -1)) >= 0)
			if menu.section == menu.Section.CLOUD: enabled = enabled and menu.PlatformMethods.supports(menu.platform, "media_cloud_sorted_page")
			menu._button(ORDER_BASE + i, menu.I18n.t(Order.LABELS[i]), Vector2(-0.12 + (i % 2) * 0.50, 0.19 - (i / 2) * 0.135), Vector2(0.46, 0.095), enabled, "", order() == Order.ORDERS[i])
		menu._button(CANCEL, menu.I18n.t("Close"), Vector2(0.13, -0.32), Vector2(0.38, 0.08))
	else:
		var title: Label3D = menu._label(menu._fit_title(str(target.get("title", "")), "", 0.96, 22), Vector3(0.13, 0.21, 0.004), 22)
		title.modulate = menu.ACCENT
		var path: Label3D = menu._label(menu._fit_title(str(target.get("uri", "")), "", 0.96, 16), Vector3(0.13, 0.11, 0.004), 16)
		path.modulate = menu.MUTED
		var recycle: bool = target.get("delete_effect", "") == "recycle"
		var effect := ("Moves the folder and all contents to the cloud recycle bin" if target.get("folder", false) else "Moves the original file to the cloud recycle bin") if recycle else ("Permanently deletes the folder and all contents" if target.get("folder", false) else "Permanently deletes the original file")
		if menu.current_file_provider.is_valid():
			var current := str(menu.current_file_provider.call())
			if current == str(target.get("uri", "")): effect = "Stop playback and move to the cloud recycle bin" if recycle else "Stop playback and permanently delete"
			elif target.get("folder", false) and current.begins_with(str(target.get("uri", "")).trim_suffix("/") + "/"): effect = "Stop playback and move folder contents to the cloud recycle bin" if recycle else "Stop playback and permanently delete folder contents"
		menu._label(menu.I18n.t(effect), Vector3(0.13, -0.01, 0.004), 19)
		if target.get("folder", false) and plan_ready:
			menu._label(menu.I18n.t("%d files · %d folders") % [int(target.get("files", 0)), int(target.get("folders", 0))], Vector3(0.13, -0.10, 0.004), 17)
		menu._label(menu.I18n.t("Reading folder contents…" if preparing else "Checking…" if checking else "Deleting…") if pending > 0 else menu.I18n.t(menu.status) if failed or uncertain else "", Vector3(0.13, -0.19, 0.004), 16)
		menu._button(CANCEL, menu.I18n.t("Hide" if pending > 0 else "Cancel"), Vector2(-0.12, -0.32), Vector2(0.40, 0.08))
		menu._button(CHECK_STATUS if uncertain else CONFIRM, menu.I18n.t("Check status" if uncertain else "Delete folder" if target.get("folder", false) else "Delete file"), Vector2(0.38, -0.32), Vector2(0.40, 0.08), pending == 0 and (uncertain or (enabled and (not target.get("folder", false) or plan_ready))), "refresh" if uncertain else "trash")
		# Confirmation is spatially separate from the footer opener, requiring a fresh trigger press.
