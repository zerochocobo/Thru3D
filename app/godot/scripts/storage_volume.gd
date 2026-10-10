extends RefCounted

static func contains_uri(volume: Dictionary, uri: String) -> bool:
	if not bool(volume.get("removable", false)): return false
	var root := str(volume.get("id", "")).trim_suffix("/").simplify_path()
	if root.is_empty() or root == "/": return false
	if uri.begins_with("file://"):
		var path := uri.substr(7).uri_decode().simplify_path()
		return path == root or path.begins_with(root + "/")
	if uri.begins_with("content://com.android.externalstorage.documents/"):
		var uuid := str(volume.get("uuid", ""))
		if uuid.is_empty(): return false
		var path := uri.get_slice("?",0).uri_decode()
		for marker in ["/document/", "/tree/"]:
			if path.contains(marker): return path.get_slice(marker,1).get_slice(":",0).nocasecmp_to(uuid) == 0
	return false
