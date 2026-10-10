package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject

/** Saved endpoints and bounded playback references. HTTP video URIs stay compatible with history. */
internal class DlnaLibrary(
    load: () -> String,
    private val persist: (String) -> Unit,
    private val discover: () -> List<DlnaClient.Server> = { DlnaClient.discover() },
) {
    private val saved = LinkedHashMap<String, JSONObject>()
    private val found = LinkedHashMap<String, DlnaClient.Server>()
    private val references = LinkedHashMap<String, JSONObject>()
    init {
        runCatching { JSONObject(load()) }.getOrNull()?.let { data ->
            data.optJSONArray("servers")?.let { list ->
                for (i in 0 until minOf(list.length(), 64)) {
                    val row = list.optJSONObject(i) ?: continue
                    if (server(row) != null) saved[row.getString("id")] = row
                }
            }
            data.optJSONArray("references")?.let { list ->
                for (i in 0 until minOf(list.length(), 256)) {
                    val row = list.optJSONObject(i) ?: continue
                    val uri = DlnaClient.httpUri(row.optString("uri")) ?: continue
                    if (server(row.optJSONObject("server") ?: continue) != null) references[uri.toString()] = row
                }
            }
        }
    }

    @Synchronized fun servers(): JSONArray {
        val merged = LinkedHashMap<String, JSONObject>()
        found.values.forEach { merged[it.id] = it.json().put("manual", false) }
        saved.forEach { (id, row) -> merged[id] = JSONObject(row.toString()).put("manual", true) }
        return JSONArray(merged.values.toList())
    }

    fun refresh(): JSONArray {
        // Saved routes remain usable when multicast is blocked or unavailable.
        val discovered = runCatching { discover() }.getOrDefault(emptyList())
        synchronized(this) { found.clear(); discovered.forEach { found[it.id] = it } }
        return servers()
    }

    fun save(request: JSONObject): String {
        val location = request.optString("location").takeIf { it.isNotBlank() }
            ?: DlnaClient.address(request.optString("host"), request.optString("port"), request.optString("scheme", "http"))
        val connected = DlnaClient.connect(location)
        val row = connected.json().put("name", request.optString("name").trim().take(150).ifEmpty { connected.name })
        synchronized(this) {
            val previous = LinkedHashMap(saved)
            val oldId = request.optString("id")
            if (oldId.isNotEmpty()) saved.remove(oldId)
            check(saved.size < 64 || saved.containsKey(connected.id)) { "Too many DLNA servers" }
            saved[connected.id] = row
            try { store() } catch (error: Exception) { saved.clear(); saved.putAll(previous); throw error }
        }
        return connected.id
    }

    @Synchronized fun remove(id: String) {
        val previous = saved.remove(id) ?: return
        try { store() } catch (error: Exception) { saved[id] = previous; throw error }
        // A saved server may also have been discovered; refresh can find it again.
        found.remove(id)
    }

    fun browse(id: String, objectId: String): JSONArray {
        val selected = synchronized(this) { saved[id]?.let(::server) ?: found[id] } ?: error("DLNA server unavailable")
        val entries = DlnaClient.browse(selected, objectId)
        synchronized(this) {
            for (i in 0 until entries.length()) {
                val entry = entries.getJSONObject(i)
                if (entry.optString("kind") != "video") continue
                val uri = entry.getString("uri")
                references.remove(uri)
                references[uri] = JSONObject().put("uri", uri).put("object_id", entry.getString("id"))
                    .put("server", selected.json()).put("subtitles", entry.optJSONArray("subtitles") ?: JSONArray())
            }
            // Keep every video in the complete displayed directory available for subtitle selection.
            while (references.size > DlnaClient.MAX_BROWSE_ITEMS) references.remove(references.keys.first())
            // Reference caching must never turn a successful browse into an error.
            runCatching { store() }
        }
        return entries
    }

    fun subtitles(uri: String): List<MediaSubtitleLink> {
        val original = synchronized(this) { references[uri] } ?: return emptyList()
        val reference = JSONObject(original.toString())
        var captions = reference.optJSONArray("subtitles") ?: JSONArray()
        // Refresh metadata for history replay: added/removed/language tracks can change on the server.
        runCatching {
            val selected = server(reference.getJSONObject("server")) ?: return@runCatching
            val entries = DlnaClient.browse(selected, reference.getString("object_id"), metadata = true)
            val entry = (0 until entries.length()).map { entries.getJSONObject(it) }.firstOrNull { it.optString("uri") == uri }
            captions = entry?.optJSONArray("subtitles") ?: JSONArray()
        }
        if (captions.length() == 0) captions = runCatching { DlnaClient.captionHeader(uri) }.getOrDefault(JSONArray())
        synchronized(this) {
            if (references[uri] === original) {
                references.remove(uri)
                references[uri] = reference.put("subtitles", captions)
                // The selected item must survive restart even if it was early in a large page.
                runCatching { store() }
            }
        }
        return (0 until captions.length()).mapNotNull {
            val track = captions.optJSONObject(it) ?: return@mapNotNull null
            val url = DlnaClient.httpUri(track.optString("url")) ?: return@mapNotNull null
            val type = DlnaClient.subtitleType(track.optString("extension"))
            if (type.isEmpty()) null else MediaSubtitleLink(url, track.optString("title"), type)
        }.take(8)
    }

    private fun store() = persist(JSONObject().put("servers", JSONArray(saved.values.toList()))
        .put("references", JSONArray(references.values.toList().takeLast(256))).toString())

    private fun server(row: JSONObject): DlnaClient.Server? {
        val location = DlnaClient.httpUri(row.optString("location")) ?: return null
        val control = DlnaClient.httpUri(row.optString("control_url")) ?: return null
        val id = row.optString("id").takeIf { it.isNotBlank() } ?: return null
        val type = row.optString("service_type", "urn:schemas-upnp-org:service:ContentDirectory:1")
        if (!type.matches(Regex("urn:schemas-upnp-org:service:ContentDirectory:[1-9][0-9]*"))) return null
        return DlnaClient.Server(id, row.optString("name"), location.toString(), control.toString(), type)
    }
}
