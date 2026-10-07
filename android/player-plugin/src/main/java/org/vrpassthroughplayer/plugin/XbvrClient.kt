package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

/** XBVR's read-only scene/list and file APIs. No metadata mutation endpoints are used. */
internal class XbvrClient(private val account: MediaServerAccount, private val http: MediaServerHttp) : MediaLibraryClient {
    private fun get(path: String, body: JSONObject? = null) = JSONObject(String(http.bytes(account.endpoint(path), 4 * 1024 * 1024, body), Charsets.UTF_8))
    private fun scene(id: String): JSONObject {
        mediaRequire(id.matches(Regex("[0-9]{1,20}")))
        return get("api/scene/$id").also { mediaRequire(it.optLong("id") > 0, "Video unavailable") }
    }
    override fun probe(): String { browse(JSONObject()); return "XBVR" }
    override fun browse(request: JSONObject): JSONObject {
        val page = request.optInt("page", 1).coerceIn(1, 100000)
        val body = JSONObject().put("limit", 48).put("offset", (page - 1) * 48).put("isAvailable", true).put("isAccessible", true)
        val sort = mapOf("created_at" to "added", "title" to "title", "date" to "release", "rating100" to "rating")[request.optString("sort", "created_at")]
            ?: throw MediaServerFailure("Server query unsupported")
        mediaRequire(request.optString("q").isBlank(), "Server query unsupported")
        body.put("sort", sort + if (request.optString("direction") == "ASC") "_asc" else "_desc")
        if (request.has("watched")) body.put("isWatched", request.getBoolean("watched"))
        for ((local, remote) in listOf("tags" to "tags", "performers" to "cast", "studios" to "sites")) {
            val values = JSONArray()
            for (negative in listOf(false, true)) {
                val selected = request.optJSONArray((if (negative) "exclude_" else "") + local) ?: JSONArray()
                mediaRequire(selected.length() <= 100)
                for (i in 0 until selected.length()) {
                    val name = selected.getString(i)
                    mediaRequire(name.isNotBlank() && name.length <= 256 && !name.startsWith("!") && !name.startsWith("&"))
                    values.put((if (negative) "!" else if (local == "tags" && request.optBoolean("all_tags", true)) "&" else "") + name)
                }
            }
            body.put(remote, values)
        }
        val data = get("api/scene/list", body)
        return JSONObject().put("entries", JSONArray(data.getJSONArray("scenes").objects().map(::summary)))
            .put("total", data.getInt("results")).put("page", page)
    }
    override fun candidates(request: JSONObject): JSONObject {
        val field = mapOf("tags" to "tags", "performers" to "cast", "studios" to "sites")[request.optString("kind")]
            ?: throw MediaServerFailure("Server query unsupported")
        val all = get("api/scene/filters").getJSONArray(field)
        val q = request.optString("q").take(200)
        val names = (0 until all.length()).map { all.getString(it) }.filter { it.isNotBlank() && it.length <= 256 &&
            !it.startsWith("!") && !it.startsWith("&") && it.contains(q, ignoreCase = true) }.distinct().sorted()
        val page = request.optInt("page", 1).coerceIn(1, 100000)
        return JSONObject().put("entries", JSONArray(names.drop((page - 1) * 48).take(48).map { JSONObject().put("id", it).put("name", it) }))
            .put("total", names.size).put("page", page)
    }
    private fun video(data: JSONObject) = (data.optJSONArray("file") ?: JSONArray()).objects()
        .filter { it.optString("type") == "video" }.sortedWith(compareByDescending<JSONObject> { it.optInt("video_width") }.thenBy { it.optLong("id") }).firstOrNull()
    private fun summary(data: JSONObject): JSONObject {
        val id = data.getLong("id").toString(); val file = video(data) ?: JSONObject()
        return JSONObject().put("id", id).put("uri", MediaLibraryUri.scene(account.id, id)).put("title", data.optString("title", "Video").take(256))
            .put("basename", file.optString("filename")).put("duration_ms", (file.optDouble("duration", 0.0) * 1000).toLong().coerceAtLeast(0))
            .put("width", file.optInt("video_width")).put("height", file.optInt("video_height")).put("kind", "video")
            .put("description", data.optString("synopsis").take(2000)).put("rating", (data.optDouble("star_rating", 0.0) * 20).toInt())
    }
    override fun detail(id: String): JSONObject {
        val data = scene(id)
        val result = summary(data)
        for ((local, remote) in listOf("tags" to "tags", "performers" to "cast")) {
            result.put(local, JSONArray((data.optJSONArray(remote) ?: JSONArray()).objects().map {
                JSONObject().put("id", it.getString("name")).put("name", it.getString("name"))
            }))
        }
        val markers = (data.optJSONArray("cuepoints") ?: JSONArray()).objects().take(500).map {
            JSONObject().put("title", it.optString("name").take(150)).put("position_ms", (it.optDouble("time_start", 0.0) * 1000).toLong().coerceAtLeast(0))
        }
        return result.put("markers", JSONArray(markers))
    }
    override fun cover(id: String): URI {
        val cover = scene(id).optString("cover_url")
        mediaRequire(cover.startsWith("http://") || cover.startsWith("https://"), "Cover unavailable")
        // Fetch through XBVR's image cache, never attach server credentials to a remote image host.
        return account.endpoint("img/700x/" + cover.replace("://", ":/"))
    }
    override fun stream(id: String): MediaStreamLink {
        val file = video(scene(id)) ?: throw MediaServerFailure("Video unavailable")
        return MediaStreamLink(account.endpoint("api/dms/file/${file.getLong("id")}?dnt=1"),
            file.getLong("id").toString() + ":" + file.optLong("size") + ":" + file.optString("updated_at"))
    }
}
