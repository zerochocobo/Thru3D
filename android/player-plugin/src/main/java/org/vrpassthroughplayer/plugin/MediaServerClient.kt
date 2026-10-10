package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.ConcurrentHashMap

/** Errors crossing into Godot are codes, never server bodies or credential-bearing URLs. */
internal class MediaServerFailure(val code: String, val httpStatus: Int = 0, val transportError: String = "") : Exception(code)
internal fun mediaRequire(value: Boolean, code: String = "Invalid server response") {
    if (!value) throw MediaServerFailure(code)
}

internal data class MediaServerAccount(val id: String, val name: String, val base: String, val key: String,
    val provider: String = "stash", val userId: String = "", val username: String = "") {
    fun json(secret: Boolean = false) = JSONObject().put("id", id).put("name", name).put("base", base)
        .put("provider", provider).apply { if (secret) { put("key", key); put("user_id", userId); put("username", username) } }
    fun endpoint(path: String) = URI(base.trimEnd('/') + "/" + path.trimStart('/'))
    fun accepts(uri: URI): Boolean {
        val home = URI(base)
        fun port(u: URI) = if (u.port >= 0) u.port else if (u.scheme == "https") 443 else 80
        return uri.scheme == home.scheme && uri.host?.equals(home.host, true) == true && port(uri) == port(home) &&
            uri.rawUserInfo == null && uri.fragment == null
    }
    companion object {
        fun address(raw: String): String {
            val uri = try { URI(raw.trim()) } catch (_: Exception) { throw MediaServerFailure("Invalid server address") }
            mediaRequire(uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank() && uri.rawUserInfo == null &&
                uri.rawQuery == null && uri.fragment == null && uri.port in -1..65535, "Invalid server address")
            return uri.toASCIIString().trimEnd('/')
        }
    }
}

internal object MediaLibraryUri {
    fun scene(server: String, id: String): String {
        mediaRequire(server.matches(Regex("[A-Za-z0-9-]{1,64}")) && id.matches(Regex("[A-Za-z0-9-]{1,64}")))
        return "medialib://$server/scene/$id"
    }
    fun parse(value: String): Pair<String, String> {
        val u = try { URI(value) } catch (_: Exception) { throw MediaServerFailure("Invalid media identity") }
        val id = u.path.orEmpty().removePrefix("/scene/")
        mediaRequire(u.scheme == "medialib" && u.port == -1 && u.rawUserInfo == null && u.rawQuery == null && u.fragment == null &&
            u.host != null && scene(u.host, id) == value, "Invalid media identity")
        return u.host to id
    }
}

/** A request scope; close disconnects live calls as well as preventing late requests. */
internal class MediaServerHttp(private val account: MediaServerAccount,
    private val connectTimeoutMs: Int = 10000, private val readTimeoutMs: Int = 15000) : Closeable {
    private val live = ConcurrentHashMap.newKeySet<HttpURLConnection>()
    @Volatile private var closed = false
    fun open(uri: URI, range: String? = null, json: JSONObject? = null,
        method: String = if (json == null) "GET" else "POST"): HttpURLConnection {
        mediaRequire(method in setOf("GET", "POST", "DELETE"), "Invalid server request")
        var target = uri
        repeat(6) {
            mediaRequire(account.accepts(target), "Media address differs from server")
            mediaRequire(!closed && !Thread.currentThread().isInterrupted, "Request cancelled")
            val c = target.toURL().openConnection() as HttpURLConnection
            synchronized(this) {
                if (closed) { c.disconnect(); throw MediaServerFailure("Request cancelled") }
                live.add(c)
            }
            try {
                c.connectTimeout = connectTimeoutMs; c.readTimeout = readTimeoutMs; c.instanceFollowRedirects = false; c.useCaches = false
                c.setRequestProperty("Accept-Encoding", "identity")
                when (account.provider) {
                    "plex" -> {
                        c.setRequestProperty("Accept", "application/json")
                        c.setRequestProperty("X-Plex-Product", "Thru3D")
                        c.setRequestProperty("X-Plex-Version", "0.5.0")
                        c.setRequestProperty("X-Plex-Platform", "Android")
                        c.setRequestProperty("X-Plex-Device", "VR headset")
                        c.setRequestProperty("X-Plex-Client-Identifier", account.id)
                        if (account.key.isNotEmpty()) c.setRequestProperty("X-Plex-Token", account.key)
                    }
                    "stash" -> if (account.key.isNotEmpty()) c.setRequestProperty("ApiKey", account.key)
                    "emby", "jellyfin" -> {
                        val scheme = if (account.provider == "emby") "Emby" else "MediaBrowser"
                        var authorization = "$scheme Client=\"Quest Player\", Device=\"Quest\", DeviceId=\"${account.id}\", Version=\"0.2\""
                        if (account.key.isNotEmpty()) {
                            // Jellyfin 12 disables legacy token headers; keep its token in the MediaBrowser header.
                            if (account.provider == "jellyfin") authorization += ", Token=\"${account.key}\""
                            else c.setRequestProperty("X-Emby-Token", account.key)
                        }
                        c.setRequestProperty("Authorization", authorization)
                    }
                    "xbvr" -> if (account.username.isNotEmpty()) c.setRequestProperty("Authorization", "Basic " +
                        java.util.Base64.getEncoder().encodeToString("${account.username}:${account.key}".toByteArray(Charsets.UTF_8)))
                    else -> throw MediaServerFailure("Unsupported server")
                }
                if (range != null) c.setRequestProperty("Range", range)
                c.requestMethod = method
                if (json != null) {
                    c.doOutput = true
                    c.setRequestProperty("Content-Type", "application/json")
                    val bytes = json.toString().toByteArray(Charsets.UTF_8)
                    c.setFixedLengthStreamingMode(bytes.size)
                    c.outputStream.use { it.write(bytes) }
                }
                val status = c.responseCode
                if (status in setOf(301, 302, 303, 307, 308)) {
                    // Do not replay POST credentials through ambiguous redirect semantics.
                    mediaRequire(method == "GET" && json == null, "Check server address")
                    val location = c.getHeaderField("Location") ?: throw MediaServerFailure("Invalid server response")
                    target = target.resolve(location); release(c)
                } else {
                    if (status == 401 || status == 403) throw MediaServerFailure("Server authentication required", status)
                    if (status !in 200..299) throw MediaServerFailure("Server request failed", status)
                    return c
                }
            } catch (e: Exception) { release(c); throw if (e is MediaServerFailure) e else MediaServerFailure("Server unavailable", transportError = e.javaClass.simpleName) }
        }
        throw MediaServerFailure("Too many redirects")
    }
    fun bytes(uri: URI, limit: Int, json: JSONObject? = null, textSubtitle: Boolean = false,
        method: String = if (json == null) "GET" else "POST"): ByteArray {
        val c = open(uri, json = json, method = method)
        try {
            mediaRequire(c.contentLengthLong <= limit, "Server response too large")
            if (textSubtitle) {
                val type = c.contentType.orEmpty().lowercase()
                mediaRequire(!type.contains("html") && !type.contains("json"), "Invalid subtitle response")
            }
            return c.inputStream.use { stream ->
                val result = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(16384)
                while (true) {
                    val n = stream.read(buffer); if (n < 0) break
                    mediaRequire(result.size() + n <= limit, "Server response too large")
                    result.write(buffer, 0, n)
                }
                result.toByteArray()
            }
        } finally { release(c) }
    }
    fun release(c: HttpURLConnection) { live.remove(c); c.disconnect() }
    override fun close() { synchronized(this) { closed = true }; java.util.ArrayList(live).forEach(::release) }
}

internal interface MediaLibraryClient {
    fun capabilities(): JSONObject = MediaLibraryPresentation.capabilities()
    fun home(request: JSONObject): JSONObject = MediaLibraryPresentation.home(this, request)
    fun favorite(request: JSONObject): JSONObject = throw MediaServerFailure("Server query unsupported")
    fun probe(): String
    fun browse(request: JSONObject): JSONObject
    fun candidates(request: JSONObject): JSONObject
    fun detail(id: String): JSONObject
    fun cover(id: String): URI
    fun coverFallback(id: String): MediaCover? = null
    fun stream(id: String): MediaStreamLink
    fun subtitles(id: String, stream: MediaStreamLink): List<MediaSubtitleLink> = stream.subtitles
    fun audio(id: String, stream: MediaStreamLink): List<MediaAudioLink> = stream.audio
}
internal data class MediaCover(val uri: URI, val x: Int, val y: Int, val width: Int, val height: Int)
internal fun mediaClient(account: MediaServerAccount, http: MediaServerHttp): MediaLibraryClient = when (account.provider) {
    "stash" -> StashClient(account, http)
    "emby", "jellyfin" -> EmbyClient(account, http)
    "xbvr" -> XbvrClient(account, http)
    "plex" -> PlexClient(account, http)
    else -> throw MediaServerFailure("Unsupported server")
}
internal class StashClient(private val account: MediaServerAccount, private val http: MediaServerHttp) : MediaLibraryClient {
    override fun capabilities(): JSONObject = MediaLibraryPresentation.capabilities(
        facets = listOf("tags", "performers", "studios"),
        filters = listOf("watched", "min_duration", "min_rating", "resolution"),
        excludes = listOf("tags", "performers", "studios"), tagMatchAll = true, descendants = true)
    fun query(query: String, variables: JSONObject = JSONObject()): JSONObject {
        val raw = http.bytes(account.endpoint("graphql"), 4 * 1024 * 1024,
            JSONObject().put("query", query).put("variables", variables))
        val body = try { JSONObject(String(raw, Charsets.UTF_8)) } catch (_: Exception) { throw MediaServerFailure("Invalid server response") }
        mediaRequire(body.optJSONArray("errors")?.length().let { it == null || it == 0 }, "Server query unsupported")
        return body.optJSONObject("data") ?: throw MediaServerFailure("Invalid server response")
    }
    override fun probe(): String {
        val data = query("query { version { version } findScenes(filter: {per_page: 1}) { count } }")
        return data.optJSONObject("version")?.optString("version", "") ?: ""
    }
    override fun browse(request: JSONObject): JSONObject {
        val vars = variables(request)
        val found = query("query Browse(\$page: FindFilterType, \$criteria: SceneFilterType) { findScenes(filter: \$page, scene_filter: \$criteria) { count scenes { $SUMMARY } } }", vars)
            .getJSONObject("findScenes")
        val entries = JSONArray()
        val scenes = found.getJSONArray("scenes")
        for (i in 0 until scenes.length()) entries.put(summary(scenes.getJSONObject(i)))
        return JSONObject().put("entries", entries).put("total", found.getInt("count")).put("page", vars.getJSONObject("page").getInt("page"))
    }
    override fun candidates(request: JSONObject): JSONObject {
        val kind = request.optString("kind", "tags")
        mediaRequire(kind in setOf("tags", "performers", "studios"))
        val method = mapOf("tags" to "findTags", "performers" to "findPerformers", "studios" to "findStudios").getValue(kind)
        val page = request.optInt("page", 1).coerceIn(1, 100000)
        val vars = JSONObject().put("filter", JSONObject().put("q", request.optString("q").take(200)).put("page", page)
            .put("per_page", 48).put("sort", "name").put("direction", "ASC"))
        val result = query("query Candidates(\$filter: FindFilterType) { $method(filter: \$filter) { count $kind { id name } } }", vars).getJSONObject(method)
        return JSONObject().put("entries", result.getJSONArray(kind)).put("total", result.getInt("count")).put("page", page)
    }
    fun rawScene(id: String): JSONObject {
        mediaRequire(id.matches(Regex("[0-9]{1,20}")))
        return query("query Scene(\$id: ID!) { findScene(id: \$id) { $SUMMARY details tags { id name } performers { id name } scene_markers { id title seconds } paths { stream screenshot } } }",
            JSONObject().put("id", id)).optJSONObject("findScene") ?: throw MediaServerFailure("Video unavailable")
    }
    override fun detail(id: String): JSONObject {
        val scene = rawScene(id)
        val result = summary(scene).put("description", scene.optString("details").take(2000))
            .put("tags", scene.optJSONArray("tags") ?: JSONArray()).put("performers", scene.optJSONArray("performers") ?: JSONArray())
        val markers = JSONArray(); val original = scene.optJSONArray("scene_markers") ?: JSONArray()
        for (i in 0 until minOf(original.length(), 500)) {
            val m = original.getJSONObject(i); val seconds = m.optDouble("seconds", -1.0)
            if (seconds.isFinite() && seconds >= 0 && seconds <= 2147483) markers.put(JSONObject().put("title", m.optString("title").take(150)).put("position_ms", (seconds * 1000).toLong()))
        }
        return result.put("markers", markers)
    }
    private fun summary(scene: JSONObject): JSONObject {
        val files = scene.optJSONArray("files") ?: JSONArray()
        // Keep all names; only an unambiguous single file is used to infer projection.
        val file = if (files.length() == 1) files.getJSONObject(0) else JSONObject()
        return JSONObject().put("id", scene.getString("id")).put("uri", MediaLibraryUri.scene(account.id, scene.getString("id")))
            .put("title", scene.optString("title").take(256).ifBlank { file.optString("basename", "Video") })
            .put("basename", file.optString("basename")).put("duration_ms", (file.optDouble("duration", 0.0) * 1000).toLong().coerceAtLeast(0))
            .put("width", file.optInt("width")).put("height", file.optInt("height"))
            .put("rating", scene.optInt("rating100")).put("studio", scene.optJSONObject("studio") ?: JSONObject())
            .put("updated", scene.optString("updated_at")).put("kind", "video")
    }
    override fun cover(id: String): URI {
        val link = rawScene(id).getJSONObject("paths").optString("screenshot")
        mediaRequire(link.isNotBlank(), "Cover unavailable")
        return account.endpoint("").resolve(link)
    }
    override fun coverFallback(id: String): MediaCover? {
        mediaRequire(id.matches(Regex("[0-9]{1,20}")))
        val paths = query("query Cover(\$id: ID!) { findScene(id: \$id) { paths { vtt } } }", JSONObject().put("id", id))
            .optJSONObject("findScene")?.optJSONObject("paths") ?: return null
        val link = paths.optString("vtt")
        if (link.isBlank()) return null
        val vtt = account.endpoint("").resolve(link)
        return spriteCover(vtt, String(http.bytes(vtt, 512 * 1024), Charsets.UTF_8))
    }
    override fun stream(id: String): MediaStreamLink {
        val data = rawScene(id)
        val link = account.endpoint("").resolve(data.getJSONObject("paths").getString("stream"))
        mediaRequire(link.path.endsWith("/stream"), "Original stream unavailable")
        val files = data.getJSONArray("files")
        mediaRequire(files.length() > 0, "Video unavailable")
        return MediaStreamLink(link, data.optString("updated_at") + files.toString(), basename = files.getJSONObject(0).optString("basename"))
    }
    override fun audio(id: String, stream: MediaStreamLink): List<MediaAudioLink> {
        mediaRequire(id.matches(Regex("[0-9]{1,20}")))
        if (stream.basename.isBlank()) return emptyList()
        // Only consume audio endpoints the server advertises. A sibling disk path is not a URL.
        val scene = query("query CompanionAudio(\$id: ID!) { findScene(id: \$id) { sceneStreams { url label mime_type } } }",
            JSONObject().put("id", id)).optJSONObject("findScene") ?: return emptyList()
        val candidates = (scene.optJSONArray("sceneStreams") ?: JSONArray()).objects().mapNotNull { endpoint ->
            val url = runCatching { account.endpoint("").resolve(endpoint.getString("url")) }.getOrNull() ?: return@mapNotNull null
            if (!account.accepts(url)) return@mapNotNull null
            val label = endpoint.optString("label")
            val name = if (label.endsWith(".m4a", true)) label else url.path.substringAfterLast('/')
            if (!name.endsWith(".m4a", true)) return@mapNotNull null
            name to url
        }.toMap()
        return SidecarAudio.select(stream.basename, candidates.keys).map { name ->
            MediaAudioLink(candidates.getValue(name), stream.identity + ":audio:" + name, SidecarAudio.title(stream.basename, name))
        }
    }
    override fun subtitles(id: String, stream: MediaStreamLink): List<MediaSubtitleLink> {
        mediaRequire(id.matches(Regex("[0-9]{1,20}")))
        val scene = query("query Captions(\$id: ID!) { findScene(id: \$id) { captions { language_code caption_type } paths { caption } } }",
            JSONObject().put("id", id)).optJSONObject("findScene") ?: return emptyList()
        val path = scene.optJSONObject("paths")?.optString("caption").orEmpty()
        if (path.isBlank()) return emptyList()
        val origin = account.endpoint("").resolve(path)
        mediaRequire(account.accepts(origin), "Media address differs from server")
        return (scene.optJSONArray("captions") ?: JSONArray()).objects().mapNotNull { caption ->
            val type = caption.optString("caption_type").lowercase()
            val language = caption.optString("language_code")
            if (type !in setOf("srt", "vtt") || language.length > 80) return@mapNotNull null
            // Signed Stash caption URLs already contain a query. Preserve it when adding lang/type.
            val base = origin.toASCIIString()
            val query = mediaQuery(mapOf("lang" to language, "type" to type))
            MediaSubtitleLink(URI(base + (if (origin.rawQuery == null) "?" else "&") + query),
                (language.ifBlank { "Subtitles" } + " · " + type.uppercase()).take(150), "vtt")
        }.distinctBy { it.url }.take(8)
    }
    companion object {
        internal fun spriteCover(vtt: URI, text: String): MediaCover? {
            val cue = text.lineSequence().map { it.trim() }.firstOrNull { it.contains("#xywh=") } ?: return null
            val parts = cue.substringAfter("#xywh=").split(',').map { it.toIntOrNull() ?: return null }
            if (parts.size != 4 || parts[0] !in 0..32767 || parts[1] !in 0..32767 || parts[2] !in 1..32768 || parts[3] !in 1..32768) return null
            val uri = runCatching { vtt.resolve(cue.substringBefore('#')) }.getOrNull() ?: return null
            return MediaCover(uri, parts[0], parts[1], parts[2], parts[3])
        }
        private const val SUMMARY = "id title updated_at rating100 studio { id name } files { id basename width height duration size }"
        fun variables(request: JSONObject): JSONObject {
            val filter = JSONObject().put("page", request.optInt("page", 1).coerceIn(1, 100000)).put("per_page", 48)
                .put("q", request.optString("q").take(200)).put("sort", request.optString("sort", "created_at").let {
                    if (it in setOf("created_at", "title", "date", "duration", "rating100")) it else "created_at"
                }).put("direction", if (request.optString("direction") == "ASC") "ASC" else "DESC")
            val criteria = JSONObject()
            for (kind in listOf("tags", "performers", "studios")) {
                fun ids(key: String): List<String> { val a = request.optJSONArray(key) ?: return emptyList()
                    mediaRequire(a.length() <= 100)
                    return (0 until a.length()).map { a.getString(it) }.distinct().onEach { mediaRequire(it.matches(Regex("[0-9]{1,20}"))) }
                }
                val include = ids(kind); val exclude = ids("exclude_$kind").filterNot { it in include }
                if (include.isNotEmpty() || exclude.isNotEmpty()) {
                    val c = JSONObject().put("value", JSONArray(include)).put("excludes", JSONArray(exclude))
                        .put("modifier", if (kind == "tags" && request.optBoolean("all_tags", true)) "INCLUDES_ALL" else "INCLUDES")
                    if (kind != "performers") c.put("depth", if (request.optBoolean("descendants")) -1 else 0)
                    // An exclusion-only query must not depend on the empty-INCLUDES interpretation.
                    if (include.isEmpty()) { c.put("value", JSONArray(exclude)).put("modifier", "EXCLUDES"); c.remove("excludes") }
                    criteria.put(kind, c)
                }
            }
            if (request.has("watched")) criteria.put("play_count", JSONObject().put("value", 0).put("modifier", if (request.optBoolean("watched")) "GREATER_THAN" else "EQUALS"))
            for ((key, remote) in listOf("min_duration" to "duration", "min_rating" to "rating100")) {
                val value = request.optInt(key, 0)
                if (value > 0) criteria.put(remote, JSONObject().put("value", value - 1).put("modifier", "GREATER_THAN"))
            }
            val resolution = request.optString("resolution")
            if (resolution in setOf("FOUR_K", "FIVE_K", "SIX_K", "SEVEN_K", "EIGHT_K", "FULL_HD"))
                criteria.put("resolution", JSONObject().put("value", resolution).put("modifier", "EQUALS"))
            return JSONObject().put("page", filter).put("criteria", criteria)
        }
    }
}
