extends RefCounted
## Folder priority never reverses. Missing metadata stays last in either direction.
const ORDERS := ["name_asc", "name_desc", "modified_desc", "modified_asc", "size_desc", "size_asc", "source"]
const LABELS := ["Name · A–Z", "Name · Z–A", "Modified · newest", "Modified · oldest", "Size · largest", "Size · smallest", "Source order"]

static func normalize(value: Variant) -> String:
	return str(value) if str(value) in ORDERS else "name_asc"

static func before(a: Dictionary, b: Dictionary, order: String) -> bool:
	var folder_a := a.has("container")
	var folder_b := b.has("container")
	if folder_a != folder_b: return folder_a
	var field := order.get_slice("_", 0)
	if field != "name" and not folder_a:
		var av := int(a.get(field, -1))
		var bv := int(b.get(field, -1))
		if (av < 0) != (bv < 0): return bv < 0
		if av != bv: return av > bv if order.ends_with("desc") else av < bv
	var comparison := str(a.title).naturalnocasecmp_to(str(b.title))
	if comparison != 0: return comparison > 0 if field == "name" and order.ends_with("desc") else comparison < 0
	return str(a.get("uri", a.get("container", {}).get("id", ""))) < str(b.get("uri", b.get("container", {}).get("id", "")))
