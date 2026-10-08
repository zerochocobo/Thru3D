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
    }, private val emit: (Int, String) -> Unit) {
    private val pool = ThreadPoolExecutor(3, 3, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(24), { Thread(it, "QuestMediaServer") })
    private class Job(val server: String) { @Volatile var http: MediaServerHttp? = null; @Volatile var future: FutureTask<Unit>? = null }
    private val jobs = ConcurrentHashMap<Int, Job>()
    private val leases = ConcurrentHashMap<String, Pair<String, LocalStreamServer>>()
    @Volatile private var closed = false
    init { instances.add(this) }
    fun request(raw: String): Int {
        if (closed || raw.length > 32768) return -1
        val req = runCatching { JSONObject(raw) }.getOrNull() ?: return -1
        val id = nextId(); val job = Job(if (req.optString("action") == "remove") "" else req.optString("server_id")); jobs[id] = job
        val task = FutureTask<Unit> {
            val result = try {
                val payload = if (req.optString("action") == "servers") JSONObject().put("servers", JSONArray().apply { accounts().forEach { put(it.json()) } })
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
        val app = context() ?: throw MediaServerFailure("Server unavailable")
        val account = MediaServerStore.get(app, server)
        val source = HttpRangeStreamSource(account) { http ->
            mediaClient(account, http).stream(scene)
        }
        try {
            synchronized(MediaServerStore) {
                mediaRequire(!closed && MediaServerStore.get(app, server) == account, "Server changed")
                val url = streams().publish(source, "video")
                leases[url] = server to streams()
                return url
            }
        } catch (e: Exception) { source.close(); throw e }
    }
    fun release(uri: String) { leases.remove(uri)?.second?.revoke(uri) }
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
