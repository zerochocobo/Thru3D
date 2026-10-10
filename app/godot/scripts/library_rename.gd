extends RefCounted
const OPEN := 9160
const PREVIEW := 9161
const APPLY := 9162
const PREVIOUS := 9163
const NEXT := 9164
var menu: Node3D
var phase := ""
var name := ""
var moves: Array = []
var shifted := false
var symbols := false
var selected_all := true
var request_id := 0
var page := 0
var migration_failed := false

func _init(owner: Node3D) -> void: menu = owner
func can_rename(row: Dictionary) -> bool:
	return (str(row.get("uri", "")).begins_with("file://") or str(row.get("uri", "")).begins_with("smb://")) and menu.file_actions.can_delete(row) and row.get("kind", "") == "video" and not row.get("folder", false) and menu.PlatformMethods.supports(menu.platform, "media_file_rename_prepare")
func open(row: Dictionary) -> void:
	menu.file_actions.target = row.duplicate(true)
	phase = "input"; moves = []; page = 0; name = str(row.title).get_basename(); shifted = false; symbols = false; selected_all = true
	menu.file_actions.modal = "rename"; menu.refresh()
func action(id: int) -> void:
	var actions: RefCounted = menu.file_actions
	if id == actions.CANCEL:
		if actions.pending == 0: phase = ""
		actions.modal = ""; menu.refresh(); return
	if actions.pending > 0: return
	if id == PREVIOUS: page = maxi(0, page - 1)
	if id == NEXT: page = mini(maxi(0, ceili(moves.size() / 5.0) - 1), page + 1)
	if phase == "input":
		if id >= menu.KEY_BASE and id < menu.KEY_BASE + 40:
			if selected_all: name = ""; selected_all = false
			var layer: Array = menu.SYMBOLS if symbols else menu.KEYS
			var character: String = layer[(id - menu.KEY_BASE) / 10][(id - menu.KEY_BASE) % 10]
			if name.length() < 160: name += character.to_upper() if shifted else character
			shifted = false
		elif id == menu.BACKSPACE:
			name = "" if selected_all else name.left(-1); selected_all = false
		elif id == menu.SPACE:
			if selected_all: name = ""; selected_all = false
			name += " "
		elif id == menu.SHIFT: shifted = not shifted
		elif id == menu.SYMBOL_LAYER: symbols = not symbols
		elif id == 9190: selected_all = not selected_all
		elif id == PREVIEW and not name.is_empty(): dispatch(true)
	elif phase == "preview" and id == APPLY and actions.enabled: dispatch(false)
	menu.refresh()
func dispatch(prepare: bool) -> void:
	var actions: RefCounted = menu.file_actions
	actions.target["new_name"] = name
	if not prepare: menu.file_delete_preparing.emit(str(actions.target.uri))
	request_id = int(menu.platform.call("media_file_rename_prepare" if prepare else "media_file_rename", JSON.stringify(actions.target)))
	actions.pending = request_id
	if request_id <= 0: request_id = 0; actions.pending = 0; phase = "result"; menu.status = "Rename failed; check the folder"
func receive(id: int, payload: String) -> bool:
	if request_id <= 0 or id != request_id: return false
	request_id = 0
	var actions: RefCounted = menu.file_actions
	actions.pending = 0
	var result: Variant = JSON.parse_string(payload)
	if not result is Dictionary or result.get("uri", "") != actions.target.get("uri", ""):
		phase = "result"; menu.status = "Rename failed; check the folder"
	elif result.get("state") == "ready" and result.get("preview", false):
		actions.target["plan"] = result.get("plan", "")
		moves = result.get("moves", []); phase = "preview"
	elif result.get("state") == "ready" and result.get("renamed", false):
		var old_uri := str(actions.target.uri)
		var new_uri := str(result.get("new_uri", ""))
		var title := str(result.get("new_title", ""))
		migration_failed = false
		menu.file_renamed.emit(old_uri, new_uri, title)
		for entries in [menu._local_entries, menu._smb_entries]:
			for entry in entries:
				if str(entry.get("uri", "")) == old_uri:
					entry.uri = new_uri; entry.title = title
					entry.id = str(entry.get("id", "")).get_base_dir().path_join(title)
		actions.selected = new_uri; actions.target = {}; actions.modal = ""; phase = ""
		menu.status = "Files renamed; playback records could not be saved" if migration_failed else "Files renamed"
	else:
		moves = result.get("remaining", [])
		moves.append_array(result.get("unknown_moves", [])); page = 0; phase = "result"
		menu.status = str(result.get("error", "Rename failed; check the folder"))
	if menu.visible: menu.refresh()
	return true
func draw() -> void:
	var actions: RefCounted = menu.file_actions
	menu._set_backdrop(Vector2(1.46, 1.12), Vector2(0.13, 0))
	menu._label(menu.I18n.t("Rename video"), Vector3(0.13, 0.46, 0.004), 25)
	menu._label(menu._fit_title(str(actions.target.get("title", "")), "", 1.20, 18), Vector3(0.13, 0.36, 0.004), 18).modulate = menu.MUTED
	if phase == "input":
		menu._button(9190, menu._fit_title(name, "", 1.18, 22), Vector2(0.13, 0.24), Vector2(1.24, 0.095), actions.pending == 0, "", selected_all)
		var layer: Array = menu.SYMBOLS if symbols else menu.KEYS
		for r in layer.size():
			for c in 10:
				var character: String = layer[r][c]
				menu._button(menu.KEY_BASE + r * 10 + c, character.to_upper() if shifted else character, Vector2(-0.38 + c * 0.126, 0.09 - r * 0.098), Vector2(0.115, 0.085), actions.pending == 0)
		menu._button(menu.SHIFT, "⇧", Vector2(-0.32, -0.30), Vector2(0.18, 0.085), actions.pending == 0, "", shifted)
		menu._button(menu.SYMBOL_LAYER, "abc" if symbols else "#+=", Vector2(-0.13, -0.30), Vector2(0.18, 0.085), actions.pending == 0, "", symbols)
		menu._button(menu.SPACE, "␣", Vector2(0.15, -0.30), Vector2(0.34, 0.085), actions.pending == 0)
		menu._button(menu.BACKSPACE, "", Vector2(0.43, -0.30), Vector2(0.18, 0.085), actions.pending == 0, "backspace")
		menu._button(PREVIEW, menu.I18n.t("Check changes"), Vector2(0.60, -0.44), Vector2(0.38, 0.08), actions.pending == 0 and not name.is_empty())
	else:
		menu._label(menu.I18n.t("%d files will be renamed") % moves.size() if phase == "preview" else menu.I18n.t(menu.status), Vector3(0.13, 0.24, 0.004), 19)
		for i in mini(maxi(0, moves.size() - page * 5), 5):
			var move: Dictionary = moves[page * 5 + i]
			menu._label(menu._fit_title(str(move.from) + " → " + str(move.to), "", 1.22, 17), Vector3(0.13, 0.13 - i * 0.083, 0.004), 17)
		if moves.size() > 5:
			menu._button(PREVIOUS, "‹", Vector2(-0.06, -0.32), Vector2(0.09, 0.065), actions.pending == 0 and page > 0)
			menu._label("%d / %d" % [page + 1, ceili(moves.size() / 5.0)], Vector3(0.13, -0.32, 0.004), 17)
			menu._button(NEXT, "›", Vector2(0.32, -0.32), Vector2(0.09, 0.065), actions.pending == 0 and (page + 1) * 5 < moves.size())
		if phase == "preview": menu._button(APPLY, menu.I18n.t("Rename all"), Vector2(0.60, -0.44), Vector2(0.38, 0.08), actions.pending == 0 and actions.enabled)
	menu._button(actions.CANCEL, menu.I18n.t("Hide" if actions.pending > 0 else "Cancel" if phase in ["input", "preview"] else "Close"), Vector2(0.13, -0.44), Vector2(0.38, 0.08))
	if actions.pending > 0: menu._label(menu.I18n.t("Checking…" if phase == "input" else "Renaming…"), Vector3(-0.33, -0.44, 0.004), 16)
