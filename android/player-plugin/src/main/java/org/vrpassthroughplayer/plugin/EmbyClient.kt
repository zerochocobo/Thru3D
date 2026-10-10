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

/** User-scoped Emby/Jellyfin APIs mapped to the common VR browsing contract. */
internal class EmbyClient(private val account: MediaServerAccount, private val http: MediaServerHttp) : MediaLibraryClient {
    private fun user() = mediaId(account.userId)
    private fun get(path: String, args: Map<String, Any> = emptyMap(), body: JSONObject? = null,
        method: String = if (body == null) "GET" else "POST"): JSONObject {
        val raw = String(http.bytes(account.endpoint(path + if (args.isEmpty()) "" else "?" + mediaQuery(args)),
            4 * 1024 * 1024, body, method = method), Charsets.UTF_8)
        return if (raw.isBlank()) JSONObject() else JSONObject(raw)
    }
    override fun capabilities(): JSONObject = MediaLibraryPresentation.capabilities(
        facets = listOf("genres", "tags", "performers", "studios"), navigation = listOf("genres", "tags", "folders"),
        filters = listOf("watched", "min_rating"), favoriteScope = "server", tree = true,
        excludes = if (account.provider == "emby") listOf("tags") else emptyList(), unclassified = listOf("genres", "tags"))
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
    override fun home(request: JSONObject): JSONObject {
        val libraries = get("Users/${user()}/Views").getJSONArray("Items").objects()
            .filter { it.optString("CollectionType") !in setOf("music", "books", "games", "livetv", "channels") }
        val requested = request.optString("library_id")
        mediaRequire(requested.isBlank() || libraries.any { it.getString("Id") == requested }, "Video unavailable")
        val library = if (requested.isNotBlank()) requested else libraries.singleOrNull()?.getString("Id").orEmpty()
        val q = JSONObject().put("library_id", library).put("page", 1).put("sort", "created_at")
        val recent = browse(q)
        val args = browseArgs(q).apply { put("Filters", "IsResumable"); put("Limit", 4); put("SortBy", "DatePlayed") }
        val resume = get("Users/${user()}/Items", args).getJSONArray("Items").objects().map(::summary)
        return JSONObject().put("capabilities", capabilities()).put("total", recent.optInt("total"))
            .put("recent", JSONArray(recent.getJSONArray("entries").objects().take(4))).put("resume", JSONArray(resume))
            .put("libraries", JSONArray(libraries.map(::summary))).put("library_id", library)
    }
    private fun browseArgs(request: JSONObject): LinkedHashMap<String, Any> {
        val page = request.optInt("page", 1).coerceIn(1, 100000)
        val folders = request.optString("mode") == "folders"
        val args = linkedMapOf<String, Any>("Recursive" to !folders, "IncludeItemTypes" to if (folders)
            "CollectionFolder,Folder,Series,Season,Movie,Episode,Video,BoxSet,Playlist" else "Movie,Episode,Video",
            "StartIndex" to (page - 1) * 48, "Limit" to 48, "EnableTotalRecordCount" to true,
            "Fields" to "MediaSources,MediaStreams,Overview,People,Genres,Studios,Chapters,Tags,ParentId,ChildCount,PrimaryImageAspectRatio",
            "SortBy" to (mapOf("title" to "SortName", "date" to "PremiereDate", "duration" to "Runtime", "rating100" to "CommunityRating")[request.optString("sort")] ?: "DateCreated"),
            "SortOrder" to if (request.optString("direction") == "ASC") "Ascending" else "Descending")
        val parent = request.optString("parent_id").ifBlank { request.optString("library_id") }
        if (parent.isNotBlank()) args["ParentId"] = mediaId(parent)
        val q = request.optString("q").take(200)
        if (q.isNotBlank()) args["SearchTerm"] = q
        if (request.has("watched")) args["IsPlayed"] = request.getBoolean("watched")
        if (request.optBoolean("favorites")) args["Filters"] = "IsFavorite"
        if (request.optInt("min_rating") > 0) args["MinCommunityRating"] = request.getInt("min_rating") / 10.0
        for ((local, remote) in listOf("genres" to "Genres", "tags" to "Tags", "exclude_tags" to "ExcludeTags",
            "performers" to "PersonIds", "studios" to "StudioIds")) {
            val values = request.optJSONArray(local) ?: continue
            mediaRequire(values.length() <= 100)
            if (values.length() > 0) {
                if (local == "exclude_tags") mediaRequire(account.provider == "emby", "Server query unsupported")
                val terms = (0 until values.length()).map { values.getString(it) }.distinct()
                mediaRequire(terms.all { it.isNotBlank() && it.length <= 256 && !it.contains('|') }, "Server query unsupported")
                args[remote] = terms.joinToString(if (local == "performers") "," else "|")
            }
        }
        return args
    }
    override fun browse(request: JSONObject): JSONObject {
        val page = request.optInt("page", 1).coerceIn(1, 100000)
        val args = browseArgs(request)
        val missing = request.optString("unclassified")
        if (missing.isNotBlank()) {
            mediaRequire(missing in setOf("genres", "tags"), "Server query unsupported")
            return unclassified(args, missing, page)
        }
        val result = get("Users/${user()}/Items", args)
        return JSONObject().put("entries", JSONArray(result.getJSONArray("Items").objects().map(::summary)))
            .put("total", result.getInt("TotalRecordCount")).put("page", page)
    }
    // No shared native 'has no genre/tag' predicate: scan bounded pages, retaining only the
    // requested result page. Closing this request's HTTP scope also cancels the scan.
    private fun unclassified(args: LinkedHashMap<String, Any>, kind: String, page: Int): JSONObject {
        args["Limit"] = 128; args["Fields"] = "MediaSources,MediaStreams,Genres,Tags,ParentId,PrimaryImageAspectRatio"
        val out = JSONArray(); var matched = 0; var offset = 0
        val start = (page - 1) * 48
        while (true) {
            args["StartIndex"] = offset
            val result = get("Users/${user()}/Items", args)
            val items = result.getJSONArray("Items").objects()
            for (item in items) {
                val node = summary(item)
                if (node.getJSONArray(kind).length() == 0) {
                    if (matched in start until start + 48) out.put(node)
                    matched++
                }
            }
            offset += items.size
            if (items.isEmpty() || offset >= result.optInt("TotalRecordCount", offset)) break
        }
        return JSONObject().put("entries", out).put("total", matched).put("page", page)
    }
    override fun candidates(request: JSONObject): JSONObject {
        val kind = request.optString("kind")
        val path = mapOf("genres" to "Genres", "tags" to "Tags", "performers" to "Persons", "studios" to "Studios")[kind]
            ?: throw MediaServerFailure("Server query unsupported")
        val page = request.optInt("page", 1).coerceIn(1, 100000)
        val args = linkedMapOf<String, Any>("UserId" to user(), "Recursive" to true,
            "IncludeItemTypes" to "Movie,Episode,Video", "StartIndex" to (page - 1) * 48, "Limit" to 48,
            "SortBy" to "SortName", "SortOrder" to "Ascending", "Fields" to "ItemCounts")
        val parent = request.optString("library_id")
        if (parent.isNotBlank()) args["ParentId"] = mediaId(parent)
        val q = request.optString("q").take(200)
        if (q.isNotBlank()) args["SearchTerm"] = q
        val result = get(path, args)
        val nodes = result.getJSONArray("Items").objects().map { data ->
            val name = data.getString("Name").take(256)
            JSONObject().put("id", if (kind in setOf("genres", "tags")) name else data.getString("Id"))
                .put("name", name).put("count", if (data.has("ChildCount")) data.optInt("ChildCount") else -1)
        }
        return JSONObject().put("entries", JSONArray(nodes)).put("total", result.optInt("TotalRecordCount", nodes.size)).put("page", page)
    }
    override fun favorite(request: JSONObject): JSONObject {
        val id = mediaId(request.getString("scene_id")); val selected = request.getBoolean("favorite")
        val data = get("Users/${user()}/FavoriteItems/$id", method = if (selected) "POST" else "DELETE")
        return JSONObject().put("scene_id", id).put("favorite", data.optBoolean("IsFavorite", selected))
    }
    private fun item(id: String) = get("Users/${user()}/Items/${mediaId(id)}")
    private fun facets(data: JSONObject, objects: String, strings: String, nameIdentity: Boolean): JSONArray {
        val nodes = (data.optJSONArray(objects) ?: JSONArray()).objects().take(100).mapNotNull {
            val name = it.optString("Name").take(256)
            val id = if (nameIdentity) name else it.optString("Id")
            if (name.isBlank() || id.isBlank()) null else JSONObject().put("id", id).put("name", name)
        }
        if (nodes.isNotEmpty()) return JSONArray(nodes)
        val values = data.optJSONArray(strings) ?: JSONArray()
        return JSONArray((0 until minOf(100, values.length())).map { values.getString(it).take(256) }
            .filter { it.isNotBlank() }.map { JSONObject().put("id", it).put("name", it) })
    }
    private fun summary(data: JSONObject): JSONObject {
        val id = mediaId(data.getString("Id"))
        val sources = data.optJSONArray("MediaSources") ?: JSONArray()
        val source = if (sources.length() == 1) sources.getJSONObject(0) else JSONObject()
        val video = (source.optJSONArray("MediaStreams") ?: data.optJSONArray("MediaStreams") ?: JSONArray()).objects().firstOrNull { it.optString("Type") == "Video" }
        val container = data.optBoolean("IsFolder") || data.optString("Type") in setOf("CollectionFolder", "Folder", "Series", "Season", "BoxSet", "Playlist")
        val userData = data.optJSONObject("UserData") ?: JSONObject()
        val result = JSONObject().put("id", id).put("kind", if (container) "container" else "video").put("container", container)
            .put("title", data.optString("Name", "Video").take(256)).put("duration_ms", data.optLong("RunTimeTicks").coerceAtLeast(0) / 10000)
            .put("basename", source.optString("Path").substringAfterLast('/').substringAfterLast('\\'))
            .put("width", video?.optInt("Width") ?: 0).put("height", video?.optInt("Height") ?: 0)
            .put("description", data.optString("Overview").take(2000)).put("rating", (data.optDouble("CommunityRating", 0.0) * 10).toInt())
            .put("year", data.optInt("ProductionYear")).put("type", data.optString("Type"))
            .put("child_count", data.optInt("ChildCount", -1)).put("favorite", userData.optBoolean("IsFavorite"))
            .put("watched", userData.optBoolean("Played")).put("position_ms", userData.optLong("PlaybackPositionTicks").coerceAtLeast(0) / 10000)
            .put("genres", facets(data, "GenreItems", "Genres", true)).put("tags", facets(data, "TagItems", "Tags", true))
            .put("performers", facets(data, "People", "", false)).put("studios", facets(data, "Studios", "", false))
            .put("has_cover", !container || data.optJSONObject("ImageTags")?.has("Primary") == true)
        if (!container) result.put("uri", MediaLibraryUri.scene(account.id, id))
        return result
    }
    override fun detail(id: String): JSONObject {
        val data = item(id)
        val markers = (data.optJSONArray("Chapters") ?: JSONArray()).objects().take(500).map {
            JSONObject().put("title", it.optString("Name").take(150)).put("position_ms", it.optLong("StartPositionTicks").coerceAtLeast(0) / 10000)
        }
        return summary(data).put("markers", JSONArray(markers))
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
            sourceId + ":" + source.optLong("Size") + ":" + source.optString("ETag"), runCatching { subtitleLinks(id, source) }.getOrDefault(emptyList()), runCatching { audioLinks(source) }.getOrDefault(emptyList()))
    }
    private fun audioLinks(source: JSONObject): List<MediaAudioLink> {
        val video = source.optString("Path").substringAfterLast('/').substringAfterLast('\\')
        if (video.isBlank()) return emptyList()
        val files = (source.optJSONArray("MediaStreams") ?: JSONArray()).objects().filter {
            it.optString("Type") == "Audio" && it.optBoolean("IsExternal") && it.optString("DeliveryUrl").isNotBlank()
        }.associateBy { it.optString("Path").substringAfterLast('/').substringAfterLast('\\') }
        return SidecarAudio.select(video, files.keys).mapNotNull { name ->
            val item = files.getValue(name)
            val url = account.endpoint("").resolve(item.getString("DeliveryUrl"))
            if (!account.accepts(url)) return@mapNotNull null
            MediaAudioLink(url, source.getString("Id") + ":audio:" + item.optInt("Index"), SidecarAudio.title(video, name))
        }
    }
    private fun subtitleLinks(id: String, source: JSONObject): List<MediaSubtitleLink> {
        val sourceId = source.getString("Id")
        mediaRequire(sourceId != "." && sourceId != "..")
        val segment = URLEncoder.encode(sourceId, "UTF-8").replace("+", "%20")
        val textCodecs = setOf("srt", "subrip", "ass", "ssa", "vtt", "webvtt", "smi", "sami", "subviewer", "microdvd", "mov_text")
        return (source.optJSONArray("MediaStreams") ?: JSONArray()).objects().filter {
            it.optString("Type") == "Subtitle" && it.optBoolean("IsExternal") && it.optInt("Index", -1) >= 0 &&
                (it.optBoolean("IsTextSubtitleStream") || it.optString("Codec").lowercase() in textCodecs)
        }.distinctBy { it.getInt("Index") }.take(8).map { caption ->
            val index = caption.getInt("Index")
            val title = caption.optString("DisplayTitle").ifBlank { caption.optString("Title") }
                .ifBlank { caption.optString("Language").ifBlank { "SRT ${index + 1}" } }.take(150)
            MediaSubtitleLink(account.endpoint("Videos/${mediaId(id)}/$segment/Subtitles/$index/Stream.srt"), title)
        }
    }
}
