package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.net.URLEncoder
import java.util.UUID

internal fun mediaId(id: String): String {
    mediaRequire(id.matches(Regex("[A-Za-z0-9-]{1,64}")), "Invalid media identity")
    return id
}
internal fun mediaQuery(values: Map<String, Any>): String = values.entries.joinToString("&") {
    URLEncoder.encode(it.key, "UTF-8") + "=" + URLEncoder.encode(it.value.toString(), "UTF-8")
}
internal fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }

/** Emby and Jellyfin share the user-scoped library contract, but keep separate profiles. */
internal class EmbyClient(private val account: MediaServerAccount, private val http: MediaServerHttp) : MediaLibraryClient {
    private fun get(path: String, args: Map<String, Any> = emptyMap(), body: JSONObject? = null): JSONObject =
        JSONObject(String(http.bytes(account.endpoint(path + if (args.isEmpty()) "" else "?" + mediaQuery(args)), 4 * 1024 * 1024, body), Charsets.UTF_8))
    private fun user() = mediaId(account.userId)
    fun login(username: String, password: String): MediaServerAccount {
        val auth = get("Users/AuthenticateByName", body = JSONObject().put("Username", username).put("Pw", password))
        val token = auth.getString("AccessToken")
        mediaRequire(token.isNotBlank(), "Server authentication required")
        return account.copy(key = token, userId = mediaId(auth.getJSONObject("User").getString("Id")), username = username)
    }
    override fun probe(): String {
        val info = get("System/Info/Public")
        val product = info.optString("ProductName").lowercase()
        mediaRequire(!(account.provider == "emby" && product.contains("jellyfin")) &&
            !(account.provider == "jellyfin" && product.contains("emby")), "Wrong server type")
        get("Users/${user()}/Items", mapOf("Limit" to 1, "Recursive" to true, "IncludeItemTypes" to "Movie,Episode,Video"))
        return info.optString("Version")
    }
    override fun browse(request: JSONObject): JSONObject {
        val page = request.optInt("page", 1).coerceIn(1, 100000)
        val args = linkedMapOf<String, Any>("Recursive" to true, "IncludeItemTypes" to "Movie,Episode,Video",
            "StartIndex" to (page - 1) * 48, "Limit" to 48, "EnableTotalRecordCount" to true,
            "Fields" to "MediaSources,MediaStreams,Overview,People,Genres,Studios,Chapters",
            "SortBy" to (mapOf("title" to "SortName", "date" to "PremiereDate", "duration" to "Runtime", "rating100" to "CommunityRating")[request.optString("sort")] ?: "DateCreated"),
            "SortOrder" to if (request.optString("direction") == "ASC") "Ascending" else "Descending")
        val q = request.optString("q").take(200)
        if (q.isNotBlank()) args["SearchTerm"] = q
        if (request.has("watched")) args["IsPlayed"] = request.getBoolean("watched")
        if (request.optInt("min_rating") > 0) args["MinCommunityRating"] = request.getInt("min_rating") / 10.0
        val result = get("Users/${user()}/Items", args)
        return JSONObject().put("entries", JSONArray(result.getJSONArray("Items").objects().map(::summary)))
            .put("total", result.getInt("TotalRecordCount")).put("page", page)
    }
    override fun candidates(request: JSONObject): JSONObject = throw MediaServerFailure("Server query unsupported")
    private fun item(id: String) = get("Users/${user()}/Items/${mediaId(id)}")
    private fun summary(data: JSONObject): JSONObject {
        val id = mediaId(data.getString("Id"))
        val sources = data.optJSONArray("MediaSources") ?: JSONArray()
        val source = if (sources.length() == 1) sources.getJSONObject(0) else JSONObject()
        val video = (source.optJSONArray("MediaStreams") ?: data.optJSONArray("MediaStreams") ?: JSONArray()).objects().firstOrNull { it.optString("Type") == "Video" }
        return JSONObject().put("id", id).put("uri", MediaLibraryUri.scene(account.id, id)).put("kind", "video")
            .put("title", data.optString("Name", "Video").take(256)).put("duration_ms", data.optLong("RunTimeTicks").coerceAtLeast(0) / 10000)
            .put("basename", source.optString("Path").substringAfterLast('/').substringAfterLast('\\'))
            .put("width", video?.optInt("Width") ?: 0).put("height", video?.optInt("Height") ?: 0)
            .put("description", data.optString("Overview").take(2000)).put("rating", (data.optDouble("CommunityRating", 0.0) * 10).toInt())
    }
    override fun detail(id: String): JSONObject {
        val data = item(id)
        val markers = (data.optJSONArray("Chapters") ?: JSONArray()).objects().take(500).map {
            JSONObject().put("title", it.optString("Name").take(150)).put("position_ms", it.optLong("StartPositionTicks").coerceAtLeast(0) / 10000)
        }
        // Metadata remains display-only until provider-specific facet filtering is implemented.
        val people = (data.optJSONArray("People") ?: JSONArray()).objects().take(20).map { it.optString("Name") }
        return summary(data).put("markers", JSONArray(markers)).put("description",
            (data.optString("Overview").take(1700) + if (people.isEmpty()) "" else "\n" + people.joinToString(" · ")).take(2000))
    }
    override fun cover(id: String): URI = account.endpoint("Items/${mediaId(id)}/Images/Primary?maxWidth=512&quality=85")
    override fun stream(id: String): MediaStreamLink {
        val data = get("Items/${mediaId(id)}/PlaybackInfo", mapOf("UserId" to user()))
        val sources = data.optJSONArray("MediaSources") ?: throw MediaServerFailure("Video unavailable")
        // Direct play preserves the file and enables true byte seeking through our proxy.
        val source = sources.objects().firstOrNull { it.optBoolean("SupportsDirectPlay", true) &&
            it.optString("Protocol", "File") == "File" && !it.optBoolean("IsRemote") && !it.optBoolean("RequiresOpening") }
            ?: throw MediaServerFailure("Original stream unavailable")
        val sourceId = source.getString("Id")
        mediaRequire(sourceId.length in 1..256)
        val args = mapOf("Static" to true, "MediaSourceId" to sourceId,
            "PlaySessionId" to data.optString("PlaySessionId").ifBlank { UUID.randomUUID().toString().replace("-", "") })
        return MediaStreamLink(account.endpoint("Videos/${mediaId(id)}/stream?" + mediaQuery(args)),
            sourceId + ":" + source.optLong("Size") + ":" + source.optString("ETag"))
    }
}
