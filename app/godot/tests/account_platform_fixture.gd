extends Object
## No native window methods exist: UI tests must use the in-process account contract.
var account_sessions := {}
var account_next := 0
var account_calls: Array = []
var account_cancels: Array = []
var web_calls: Array = []
func account_open(kind: String, provider: String, id: String, json: String) -> int:
	account_next += 1
	account_sessions[account_next] = {"id": account_next, "state": "form", "busy": false, "revision": 1,
		"editing_account": not id.is_empty(), "fields": {"name": provider, "base": "http://", "username": ""}, "password_length": 0, "sms_length": 0}
	account_calls.append(["open", kind, provider, id, JSON.parse_string(json)])
	return account_next
func account_list(_kind: String) -> String:
	return '[{"id":"first","name":"115 home","provider":"115"},{"id":"second","name":"Baidu","provider":"baidu"}]'
func account_snapshot(id: int) -> String: return JSON.stringify(account_sessions.get(id, {}))
func account_cancel(id: int) -> void: account_cancels.append(id); account_sessions.erase(id)
func account_input(id: int, field: String, action: String, text: String) -> void:
	if not account_sessions.has(id): return
	var data: Dictionary = account_sessions[id]
	if field in ["password", "sms"]:
		data[field + "_length"] = maxi(0, int(data.get(field + "_length", 0)) + (text.length() if action == "append" else -1))
	else: data.fields[field] = str(data.fields.get(field, "")) + text
	data.revision += 1
func account_action(id: int, action: String, json: String) -> void: account_calls.append([id, action, JSON.parse_string(json)])
func account_web_frame(_id: int) -> PackedByteArray: return PackedByteArray()
func account_web_action(id: int, action: String, x: float, y: float, text: String) -> void: web_calls.append([id, action, x, y, text])
