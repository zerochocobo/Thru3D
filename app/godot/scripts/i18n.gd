extends RefCounted
## Shared UI catalog also packaged in the Android plugin for native account dialogs.
## User media titles, server names and unknown error codes pass through unchanged.
const CHOICES := ["auto", "zh", "zh_Hant", "ja", "en"]
const NAMES := {"auto": "System", "zh": "简体中文", "zh_Hant": "繁體中文", "ja": "日本語", "en": "English"}
static var translations: Dictionary = _load_catalog()
static var language := resolve_locale(OS.get_locale())
static var choice := "auto"

static func _load_catalog() -> Dictionary:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://i18n/translations.json"))
	if parsed is Dictionary:
		return parsed
	push_error("Unable to load UI translations")
	return {}

static func resolve_locale(locale: String) -> String:
	var parts := locale.replace("-", "_").to_lower().split("_")
	if parts[0] == "ja": return "ja"
	if parts[0] != "zh": return "en"
	# Explicit script takes precedence over country (e.g. zh-Hans-TW).
	if "hant" in parts: return "zh_Hant"
	if "hans" in parts: return "zh"
	return "zh_Hant" if "tw" in parts or "hk" in parts or "mo" in parts else "zh"

static func use(value: String) -> void:
	# Keep the existing saved "zh" preference compatible with Simplified Chinese.
	choice = value if value in CHOICES else "auto"
	language = resolve_locale(OS.get_locale()) if choice == "auto" else choice

static func t(text: String) -> String:
	return str(translations.get(language, {}).get(text, text))
