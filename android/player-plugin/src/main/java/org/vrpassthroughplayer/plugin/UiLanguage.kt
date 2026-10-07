package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONObject
import java.util.Locale

/** The Godot setting is mirrored here so recreated native activities keep the same language. */
internal object UiLanguage {
    private val choices = setOf("auto", "zh", "zh_Hant", "ja", "en")
    @Volatile private var catalog: JSONObject? = null

    fun setChoice(context: Context, value: String) {
        context.getSharedPreferences("ui_language", Context.MODE_PRIVATE).edit()
            .putString("choice", if (value in choices) value else "auto").apply()
    }

    fun resolve(choice: String, locale: String): String {
        if (choice in choices && choice != "auto") return choice
        val parts = locale.replace('-', '_').lowercase(Locale.ROOT).split('_')
        if (parts.first() == "ja") return "ja"
        if (parts.first() != "zh") return "en"
        if ("hant" in parts) return "zh_Hant"
        if ("hans" in parts) return "zh"
        return if (parts.any { it in setOf("tw", "hk", "mo") }) "zh_Hant" else "zh"
    }

    fun tr(context: Context, english: String, simplified: String): String {
        val choice = context.getSharedPreferences("ui_language", Context.MODE_PRIVATE).getString("choice", "auto") ?: "auto"
        val language = resolve(choice, context.resources.configuration.locales[0].toLanguageTag())
        if (language == "en") return english
        val data = catalog ?: synchronized(this) {
            catalog ?: runCatching {
                context.assets.open("translations.json").bufferedReader(Charsets.UTF_8).use { JSONObject(it.readText()) }
            }.getOrNull()?.also { catalog = it }
        }
        return data?.optJSONObject(language)?.optString(english, if (language == "zh") simplified else english)
            ?: if (language == "zh") simplified else english
    }
}
