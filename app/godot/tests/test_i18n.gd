extends SceneTree
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void:
	var locales := {"en_US": "en", "ja_JP": "ja", "ja": "ja", "zh_CN": "zh", "zh_SG": "zh",
		"zh_TW": "zh_Hant", "zh_HK": "zh_Hant", "zh_MO": "zh_Hant", "zh-Hant-CN": "zh_Hant",
		"zh-Hans-TW": "zh", "zh": "zh", "fr_FR": "en", "": "en"}
	for locale in locales:
		check(I18n.resolve_locale(locale) == locales[locale], "Locale: " + locale)
	var placeholders := RegEx.new()
	placeholders.compile("%[-+0-9.]*[sdif]")
	var source: Dictionary = I18n.translations["zh"]
	for language in ["zh", "zh_Hant", "ja"]:
		I18n.use(language)
		var catalog: Dictionary = I18n.translations[language]
		check(catalog.size() == source.size(), "Catalog key count: " + language)
		for key in source:
			check(catalog.has(key) and not I18n.t(key).is_empty(), language + " missing " + key)
			var expected := placeholders.search_all(key).map(func(hit): return hit.get_string())
			var actual := placeholders.search_all(I18n.t(key)).map(func(hit): return hit.get_string())
			check(expected == actual, language + " placeholders: " + key)
		check(I18n.t("user_movie_日本語.mp4") == "user_movie_日本語.mp4", "User media names unchanged")
	I18n.use("zh_Hant")
	check(I18n.t("Local files") == "本機檔案", "Traditional Chinese terminology")
	I18n.use("ja")
	check(I18n.t("Settings") == "設定" and I18n.t("Subtitles") == "字幕", "Japanese controls")
	I18n.use("zh")
	check(I18n.t("Local files") == "本地文件", "Existing saved zh choice preserved")
	I18n.use("bad-locale")
	check(I18n.choice == "auto", "Invalid stored choice falls back to system")
	I18n.use("en")
	check(I18n.t("Local files") == "Local files", "Switch back to English")
	print("i18n checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
