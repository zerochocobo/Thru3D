package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URI
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.FutureTask
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** App-private server profiles. UI requests never return the key. */
internal object MediaServerStore {
    private fun store(context: Context) = CloudAccountStore(context, "media-servers-v1.bin", "quest_media_servers_v1")
    @Synchronized fun accounts(context: Context): List<MediaServerAccount> {
        val data = store(context).load()
        return (0 until data.length()).map { data.getJSONObject(it).let { a ->
            MediaServerAccount(a.getString("id"), a.getString("name"), a.getString("base"), a.getString("key"),
                a.optString("provider", "stash"), a.optString("user_id"), a.optString("username"))
        } }
    }
    fun get(context: Context, id: String) = accounts(context).find { it.id == id } ?: throw MediaServerFailure("Server removed")
    @Synchronized fun save(context: Context, value: MediaServerAccount) {
        val all = accounts(context).filterNot { it.id == value.id } + value
        mediaRequire(all.size <= 16, "Too many servers")
        store(context).save(JSONArray().apply { all.forEach { put(it.json(true)) } })
        MediaServerLibrary.invalidate(value.id)
    }
    @Synchronized fun remove(context: Context, id: String) {
        mediaRequire(id.matches(Regex("[A-Za-z0-9-]{1,64}")))
        get(context, id)
        store(context).save(JSONArray().apply { accounts(context).filterNot { it.id == id }.forEach { put(it.json(true)) } })
        MediaServerLibrary.invalidate(id)
        File(context.cacheDir, "media-servers/$id").deleteRecursively()
    }
}

internal class MediaServerLibrary(private val context: () -> Context?, private val streams: () -> LocalStreamServer,
    private val nextId: () -> Int,
    private val accounts: () -> List<MediaServerAccount> = {
        MediaServerStore.accounts(context() ?: throw MediaServerFailure("Server unavailable"))
    }, private val getAccount: (String) -> MediaServerAccount = { id ->
        MediaServerStore.get(context() ?: throw MediaServerFailure("Server unavailable"), id)
    }, private val emit: (Int, String) -> Unit) {
    private val pool = ThreadPoolExecutor(3, 3, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(24), { Thread(it, "QuestMediaServer") })
    private class Job(val server: String) { @Volatile var http: MediaServerHttp? = null; @Volatile var future: FutureTask<Unit>? = null }
    private val jobs = ConcurrentHashMap<Int, Job>()
    private val leases = ConcurrentHashMap<String, Pair<String, LocalStreamServer>>()
    private data class Playback(val account: MediaServerAccount, val scene: String,
        val stream: MediaStreamLink, val videoUrl: String)
    private val playback = ConcurrentHashMap<String, Playback>()
    @Volatile private var closed = false
    init { instances.add(this) }
    fun request(raw: String): Int {
        if (closed || raw.length > 32768) return -1
        val req = runCatching { JSONObject(raw) }.getOrNull() ?: return -1
        val id = nextId(); val job = Job(if (req.optString("action") == "remove") "" else req.optString("server_id")); jobs[id] = job
        val task = FutureTask<Unit> {
            val result = try {
                val payload = if (req.optString("action") == "servers") JSONObject().put("servers", JSONArray().apply { accounts().forEach { account ->
                    val capabilities = MediaServerHttp(account).use { http -> mediaClient(account, http).capabilities() }
                    put(account.json().put("capabilities", capabilities))
                } })
                else if (req.optString("action") == "remove") {
                    val app = context() ?: throw MediaServerFailure("Server unavailable")
                    MediaServerStore.remove(app, req.getString("server_id"))
                    JSONObject()
                } else {
                    val app = context() ?: throw MediaServerFailure("Server unavailable")
                    val account = MediaServerStore.get(app, job.server)
                    MediaServerHttp(account).use { http ->
                        job.http = http
                        mediaRequire(jobs[id] === job && !closed, "Request cancelled")
                        val client = mediaClient(account, http)
                        when (req.optString("action")) {
                            "home" -> client.home(req)
                            "favorite" -> client.favorite(req)
                            "browse" -> client.browse(req)
                            "candidates" -> client.candidates(req)
                            "detail" -> JSONObject().put("detail", client.detail(req.getString("scene_id")))
                            "cover" -> cover(app, account, client, http, req.getString("scene_id"))
                            else -> throw MediaServerFailure("Invalid server request")
                        }
                    }
                }
                // Mark every successful branch, including the local account list.
                payload.put("state", "ready")
            } catch (e: Exception) { JSONObject().put("state", "error").put("error", if (e is MediaServerFailure) e.code else "Server unavailable") }
            if (jobs.remove(id, job) && !closed && !Thread.currentThread().isInterrupted)
                emit(id, result.put("source", "medialib").put("server_id", req.optString("server_id")).put("action", req.optString("action"))
                    .put("generation", req.optInt("generation")).toString())
        }
        job.future = task
        try { pool.execute(task) } catch (_: Exception) { jobs.remove(id); return -1 }
        return id
    }
    fun cancel(id: Int) { jobs.remove(id)?.let { it.http?.close(); it.future?.cancel(true); it.future?.let(pool::remove) } }
    private fun cover(app: Context, account: MediaServerAccount, client: MediaLibraryClient, http: MediaServerHttp, id: String): JSONObject {
        mediaRequire(id.matches(Regex("[A-Za-z0-9-]{1,64}")))
        val directory = File(app.cacheDir, "media-servers/${account.id}").apply { mkdirs() }
        val file = File(directory, "$id.jpg")
        if (!file.isFile || System.currentTimeMillis() - file.lastModified() > 86400000) {
            val bitmap = runCatching { decodeCover(http.bytes(client.cover(id), 8 * 1024 * 1024)) }.getOrElse { original ->
                if (original is MediaServerFailure && original.code in setOf("Request cancelled", "Server authentication required")) throw original
                val fallback = client.coverFallback(id) ?: throw MediaServerFailure("Cover unavailable")
                decodeCover(http.bytes(fallback.uri, 16 * 1024 * 1024), fallback)
            }
            val temporary = File(directory, "$id.${UUID.randomUUID()}.tmp")
            try {
                temporary.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) }
                synchronized(MediaServerStore) {
                    mediaRequire(!Thread.currentThread().isInterrupted && MediaServerStore.get(app, account.id) == account, "Request cancelled")
                    mediaRequire(temporary.renameTo(file), "Cover unavailable")
                }
            } finally { bitmap.recycle(); temporary.delete() }
            val cached = File(app.cacheDir, "media-servers").walkTopDown().filter { it.isFile && it.extension == "jpg" }.toList()
            var total = cached.sumOf { it.length() }
            for (old in cached.sortedBy { it.lastModified() }) { if (total <= 128L * 1024 * 1024) break; if (old != file) { val size = old.length(); if (old.delete()) total -= size } }
        }
        return JSONObject().put("scene_id", id).put("path", file.absolutePath)
    }
    private fun decodeCover(bytes: ByteArray, region: MediaCover? = null): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        mediaRequire(bounds.outWidth in 1..32768 && bounds.outHeight in 1..32768, "Cover unavailable")
        val width = region?.width ?: bounds.outWidth; val height = region?.height ?: bounds.outHeight
        mediaRequire(width.toLong() * height <= 64000000, "Cover too large")
        var sample = 1
        while (maxOf(width, height) / sample > 512) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        if (region == null) return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: throw MediaServerFailure("Cover unavailable")
        mediaRequire(region.x.toLong() + width <= bounds.outWidth && region.y.toLong() + height <= bounds.outHeight, "Invalid server response")
        val decoder = android.graphics.BitmapRegionDecoder.newInstance(bytes, 0, bytes.size, false) ?: throw MediaServerFailure("Cover unavailable")
        try { return decoder.decodeRegion(android.graphics.Rect(region.x, region.y, region.x + width, region.y + height), options)
            ?: throw MediaServerFailure("Cover unavailable") } finally { decoder.recycle() }
    }
    fun playable(uri: String): String {
        val (server, scene) = MediaLibraryUri.parse(uri)
        val account = getAccount(server)
        val source = HttpRangeStreamSource(account) { http ->
            mediaClient(account, http).stream(scene)
        }
        try {
            synchronized(MediaServerStore) {
                mediaRequire(!closed && getAccount(server) == account, "Server changed")
                val local = streams()
                val url = local.publish(source, "video")
                leases[url] = server to local
                playback[uri] = Playback(account, scene, source.original(), url)
                return url
            }
        } catch (e: Exception) { source.close(); throw e }
    }
    fun sidecarAudio(uri: String): List<SidecarAudio.Track> {
        val selected = playback[uri] ?: return emptyList()
        fun current() = mediaRequire(!closed && playback[uri] === selected &&
            getAccount(selected.account.id) == selected.account, "Server changed")
        synchronized(MediaServerStore) { current() }
        return MediaServerHttp(selected.account).use { http ->
            mediaClient(selected.account, http).audio(selected.scene, selected.stream).take(4).mapNotNull { audio ->
                runCatching {
                    var initial = true
                    val source = HttpRangeStreamSource(selected.account) { refresh ->
                        val fresh = if (initial) { initial = false; audio } else
                            mediaClient(selected.account, refresh).audio(selected.scene, selected.stream)
                                .firstOrNull { it.identity == audio.identity } ?: throw MediaServerFailure("Audio changed; reopen it")
                        MediaStreamLink(fresh.url, fresh.identity)
                    }
                    try {
                        synchronized(MediaServerStore) {
                            current()
                            val local = streams()
                            val url = local.publish(source, "audio.m4a")
                            leases[url] = selected.account.id to local
                            SidecarAudio.Track(url, audio.title)
                        }
                    } catch (error: Exception) { source.close(); throw error }
                }.getOrNull()
            }
        }
    }
    fun sidecarSubtitles(uri: String): List<SidecarSubtitles.Track> {
        val selected = playback[uri] ?: return emptyList()
        fun current() = mediaRequire(!closed && playback[uri] === selected &&
            getAccount(selected.account.id) == selected.account, "Server changed")
        synchronized(MediaServerStore) { current() }
        return MediaServerHttp(selected.account).use { http ->
            val captions = mediaClient(selected.account, http).subtitles(selected.scene, selected.stream)
            SidecarSubtitles.forServer(http, captions) { source, name ->
                synchronized(MediaServerStore) {
                    current()
                    val local = streams()
                    val url = local.publish(source, name)
                    leases[url] = selected.account.id to local
                    url
                }
            }
        }
    }
    fun release(uri: String) {
        leases.remove(uri)?.second?.revoke(uri)
        playback.entries.filter { it.value.videoUrl == uri }.forEach { playback.remove(it.key, it.value) }
    }
    fun close() { closed = true; jobs.keys.toList().forEach(::cancel); pool.shutdownNow(); instances.remove(this)
        leases.keys.toList().forEach(::release) }
    companion object {
        private val instances = ConcurrentHashMap.newKeySet<MediaServerLibrary>()
        fun invalidate(server: String) {
            instances.forEach { instance ->
                instance.jobs.filterValues { it.server == server }.keys.toList().forEach(instance::cancel)
                instance.leases.filterValues { it.first == server }.keys.toList().forEach(instance::release)
                // Quest can keep the player resumed behind the native account window.
                // Notify after persistence instead of relying on another onMainResume.
                if (!instance.closed) instance.emit(0, JSONObject().put("source", "medialib")
                    .put("state", "accounts_changed").toString())
            }
        }
    }
}
