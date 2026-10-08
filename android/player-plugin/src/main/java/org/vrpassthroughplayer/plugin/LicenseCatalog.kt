package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONArray

/** Only the checked-in catalog can select a packaged license; no arbitrary filesystem paths. */
internal object LicenseCatalog {
    fun text(context: Context, id: String): String {
        return try {
            val index = JSONArray(context.assets.open("licenses.json").bufferedReader().use { it.readText() })
            val entry = (0 until index.length()).map(index::getJSONObject).firstOrNull { it.getString("id") == id } ?: return ""
            val paths = entry.getJSONArray("assets")
            (0 until paths.length()).joinToString("\n\n") { i ->
                val path = paths.getString(i)
                require(!path.startsWith('/') && !path.contains(".."))
                context.assets.open(path).use { input ->
                    val bytes = input.readBytes(); require(bytes.size <= 256 * 1024); String(bytes, Charsets.UTF_8)
                }
            }
        } catch (_: Exception) { "" }
    }
}
