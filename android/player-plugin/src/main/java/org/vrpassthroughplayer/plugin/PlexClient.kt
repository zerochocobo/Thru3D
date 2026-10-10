package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

/** Plex video libraries use the same ray browser and authenticated Range proxy as other servers. */
internal class PlexClient(private val account: MediaServerAccount, private val http: MediaServerHttp) : MediaLibraryClient {
    private fun get(path: String, args: Map<String, Any> = emptyMap()): JSONObject = container(http.bytes(
        account.endpoint(path + if (args.isEmpty()) "" else "?" + mediaQuery(args)), 4 * 1024 * 1024))
    override fun capabilities() = MediaLibraryPresentation.capabilities(
        facets = listOf("genres", "tags", "performers", "studios"), navigation = listOf("genres", "tags", "folders"),
        filters = listOf("watched", "min_rating"), tree = true)
    override fun probe(): String {
        val info = get("identity")
        mediaRequire(info.optString("machineIdentifier").isNotBlank(), "Wrong server type")
        if (account.userId.isNotBlank()) mediaRequire(info.optString("machineIdentifier") == account.userId, "Wrong server type")
        sections() // /identity is public: a successful identity request alone does not prove authorization.
        return info.optString("version")
    }
    private fun sections() = (get("library/sections").optJSONArray("Directory") ?: JSONArray()).objects()
        .filter { it.optString("type") in setOf("movie", "show") }
    private fun section(request: JSONObject): JSONObject? {
        val all = sections(); val selected = request.optString("library_id")
        if (selected.isBlank()) return all.firstOrNull()
        return all.firstOrNull { it.optString("key") == selected } ?: throw MediaServerFailure("Video unavailable")
    }
    private fun library(data: JSONObject) = JSONObject().put("id", numeric(data.getString("key")))
        .put("title", data.optString("title").take(256)).put("kind", "container").put("container", true).put("has_cover", false)
    override fun home(request: JSONObject): JSONObject {
        val all = sections(); val selected = section(request)
        val id = selected?.getString("key").orEmpty()
        val recent = browse(JSONObject().put("library_id", id).put("sort", "created_at"))
        val resume = if (id.isEmpty()) emptyList() else nodes(get("library/sections/${numeric(id)}/onDeck",
            mapOf("X-Plex-Container-Start" to 0, "X-Plex-Container-Size" to 4))).filter { it.optString("type") in VIDEO }.map(::summary)
        return JSONObject().put("capabilities", capabilities()).put("total", recent.optInt("total"))
            .put("recent", JSONArray(recent.getJSONArray("entries").objects().take(4))).put("resume", JSONArray(resume))
            .put("libraries", JSONArray(all.map(::library))).put("library_id", id)
    }
    override fun browse(request: JSONObject): JSONObject {
        val page = request.optInt("page", 1).coerceIn(1, 100000)
        val selected = section(request) ?: return JSONObject().put("entries", JSONArray()).put("total", 0).put("page", page)
        val folder = request.optString("mode") == "folders"
        val parent = request.optString("parent_id")
        val args = linkedMapOf<String, Any>("X-Plex-Container-Start" to (page - 1) * 48, "X-Plex-Container-Size" to 48)
        val path = if (folder && parent.isNotBlank()) "library/metadata/${numeric(parent)}/children" else {
            args["type"] = if (selected.optString("type") == "show") { if (folder) 2 else 4 } else 1
            "library/sections/${numeric(selected.getString("key"))}/all"
        }
        val sort = mapOf("created_at" to "addedAt", "title" to "titleSort", "date" to "originallyAvailableAt",
            "duration" to "duration", "rating100" to "rating")[request.optString("sort", "created_at")]
            ?: throw MediaServerFailure("Server query unsupported")
        args["sort"] = sort + if (request.optString("direction") == "ASC") ":asc" else ":desc"
        if (request.optString("q").isNotBlank()) args["title"] = request.optString("q").take(200)
        if (request.has("watched")) args["unwatched"] = if (request.getBoolean("watched")) 0 else 1
        if (request.optInt("min_rating") > 0) args["rating>="] = request.getInt("min_rating") / 10.0
        for ((local, remote) in FACETS) {
            val values = request.optJSONArray(local) ?: continue
            mediaRequire(values.length() <= 100, "Server query unsupported")
            if (values.length() > 0) args[remote] = values.objectsOrStrings().distinct().joinToString(",") { facetId(it) }
        }
        mediaRequire(request.optString("unclassified").isBlank() && FACETS.keys.none { request.optJSONArray("exclude_$it")?.length()?.let { n -> n > 0 } == true }, "Server query unsupported")
        val result = get(path, args)
        val entries = nodes(result).filter { it.optString("type") in VIDEO || (folder && it.optString("type") in CONTAINERS) }.map(::summary)
        return JSONObject().put("entries", JSONArray(entries)).put("total", result.optInt("totalSize", result.optInt("size", entries.size))).put("page", page)
    }
    override fun candidates(request: JSONObject): JSONObject {
        val selected = section(request)
        val page = request.optInt("page", 1).coerceIn(1, 100000)
        val remote = FACETS[request.optString("kind")] ?: throw MediaServerFailure("Server query unsupported")
        val entries = if (selected == null) emptyList() else (get("library/sections/${numeric(selected.getString("key"))}/$remote",
            mapOf("type" to if (selected.optString("type") == "show") 4 else 1)).optJSONArray("Directory") ?: JSONArray()).objects()
            .filter { it.optString("title").contains(request.optString("q").take(200), true) }.map {
                JSONObject().put("id", facetId(it.getString("key"))).put("name", it.optString("title").take(256)).put("count", -1)
            }
        return JSONObject().put("entries", JSONArray(entries.drop((page - 1) * 48).take(48))).put("total", entries.size).put("page", page)
    }
    private fun item(id: String): JSONObject = nodes(get("library/metadata/${numeric(id)}", mapOf("includeChapters" to 1)))
        .firstOrNull { it.optString("ratingKey") == id } ?: throw MediaServerFailure("Video unavailable")
    private fun facets(data: JSONObject, remote: String): JSONArray = JSONArray((data.optJSONArray(remote) ?: JSONArray()).objects()
        .take(100).mapNotNull { tag ->
            val id = tag.optString("id"); val name = tag.optString("tag")
            if (!id.matches(Regex("[0-9]{1,20}")) || name.isBlank()) null else JSONObject().put("id", id).put("name", name.take(256))
        })
    private fun summary(data: JSONObject): JSONObject {
        val id = numeric(data.getString("ratingKey")); val type = data.optString("type")
        val container = type in CONTAINERS
        val sources = data.optJSONArray("Media") ?: JSONArray()
        val source = if (sources.length() == 1) sources.getJSONObject(0) else JSONObject()
        val parts = source.optJSONArray("Part") ?: JSONArray()
        val part = if (parts.length() == 1) parts.getJSONObject(0) else JSONObject()
        val title = if (type == "episode") listOf(data.optString("grandparentTitle"), data.optString("title")).filter { it.isNotBlank() }.joinToString(" · ") else data.optString("title", "Video")
        return JSONObject().put("id", id).put("kind", if (container) "container" else "video").put("container", container)
            .put("title", title.take(256)).put("duration_ms", data.optLong("duration").coerceAtLeast(0))
            .put("basename", part.optString("file").substringAfterLast('/').substringAfterLast('\\'))
            .put("width", source.optInt("width")).put("height", source.optInt("height"))
            .put("description", data.optString("summary").take(2000)).put("rating", (data.optDouble("rating", 0.0) * 10).toInt())
            .put("year", data.optInt("year")).put("type", type).put("child_count", data.optInt("leafCount", -1))
            .put("watched", data.optInt("viewCount") > 0).put("position_ms", data.optLong("viewOffset").coerceAtLeast(0))
            .put("genres", facets(data, "Genre")).put("tags", facets(data, "Label")).put("performers", facets(data, "Role"))
            .put("studios", JSONArray().apply { if (data.optString("studio").isNotBlank()) put(JSONObject()
                .put("id", data.optString("studio")).put("name", data.optString("studio").take(256))) })
            .put("studio", JSONObject().put("name", data.optString("studio")))
            .put("has_cover", data.optString("thumb").isNotBlank()).apply { if (!container) put("uri", MediaLibraryUri.scene(account.id, id)) }
    }
    override fun detail(id: String): JSONObject {
        val data = item(id)
        return summary(data).put("markers", JSONArray((data.optJSONArray("Chapter") ?: JSONArray()).objects().take(500).map {
            JSONObject().put("title", it.optString("title").take(150)).put("position_ms", it.optLong("startTimeOffset").coerceAtLeast(0))
        }))
    }
    override fun cover(id: String): URI = endpoint(item(id).optString("thumb"), "/library/metadata/")
    private fun endpoint(key: String, prefix: String): URI {
        mediaRequire(key.startsWith(prefix), "Media address differs from server")
        val uri = account.endpoint(key)
        mediaRequire(account.accepts(uri) && uri.rawQuery == null && !uri.path.contains("/../"), "Media address differs from server")
        return uri
    }
    override fun stream(id: String): MediaStreamLink {
        val data = item(id)
        mediaRequire(data.optString("type") in VIDEO, "Video unavailable")
        val parts = (data.optJSONArray("Media") ?: JSONArray()).objects().mapNotNull { media ->
            val parts = media.optJSONArray("Part") ?: return@mapNotNull null
            if (parts.length() == 1 && parts.getJSONObject(0).optBoolean("exists", true) &&
                parts.getJSONObject(0).optBoolean("accessible", true)) parts.getJSONObject(0) else null
        }
        val part = parts.firstOrNull() ?: throw MediaServerFailure("Original stream unavailable")
        val url = endpoint(part.getString("key"), "/library/parts/")
        val subtitles = (part.optJSONArray("Stream") ?: JSONArray()).objects().filter {
            it.optInt("streamType") == 3 && it.optString("key").isNotBlank() && it.optString("codec") in setOf("srt", "ass", "ssa", "vtt")
        }.take(8).map { caption -> MediaSubtitleLink(endpoint(caption.getString("key"), "/library/streams/"),
            caption.optString("displayTitle").ifBlank { caption.optString("language", "Subtitles") }.take(150), caption.optString("codec")) }
        return MediaStreamLink(url, "${numeric(part.optString("id"))}:${part.optLong("size")}:${data.optLong("updatedAt")}", subtitles,
            basename = part.optString("file").substringAfterLast('/').substringAfterLast('\\'))
    }
    companion object {
        private val VIDEO = setOf("movie", "episode")
        private val CONTAINERS = setOf("show", "season")
        private val FACETS = mapOf("genres" to "genre", "tags" to "label", "performers" to "actor", "studios" to "studio")
        private fun facetId(value: String): String {
            mediaRequire(value.isNotBlank() && value.length <= 256 && value.none { it == ',' || it.isISOControl() }, "Server query unsupported")
            return value
        }
        internal fun numeric(id: String): String { mediaRequire(id.matches(Regex("[0-9]{1,20}")), "Invalid media identity"); return id }
        internal fun container(bytes: ByteArray): JSONObject = try { JSONObject(String(bytes, Charsets.UTF_8)).getJSONObject("MediaContainer") }
            catch (_: Exception) { throw MediaServerFailure("Invalid server response") }
        private fun nodes(container: JSONObject) = (container.optJSONArray("Metadata") ?: JSONArray()).objects()
        private fun JSONArray.objectsOrStrings() = (0 until length()).map { getString(it) }
    }
}
