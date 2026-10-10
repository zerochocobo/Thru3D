package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.ExifInterface
import android.net.Uri
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.roundToInt

/** Compressed photo transfer and bounded decoding run off the render thread. Only private cache
 * paths/metadata reach Godot. A newer selection cancels old transfer and rejects late depth. */
internal class PhotoBridge(
    private val context: () -> Context?,
    private val resolve: (String) -> String,
    private val releaseStream: (String) -> Unit,
    private val cacheName: String = "photos",
    private val preload: Boolean = false,
    private val postDepth: ((Runnable, Boolean) -> Unit)? = null,
    private val emit: (String, Int, String) -> Unit,
) : Closeable {
    private val current = AtomicInteger(0)
    private val files = ConcurrentHashMap<Int, PhotoSource>()
    private class DepthJob(val id: Int, val source: PhotoSource, @Volatile var strength: Float, val stereo: Boolean,
                           @Volatile var owner: PhotoBridge, @Volatile var background: Boolean) {
        @Volatile var cancelled = false
    }
    private val depthJobs = ConcurrentHashMap<Int, DepthJob>()
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(1),
        { Thread(it, if (preload) "QuestPhotoPreload" else "QuestPhotoIO") }, ThreadPoolExecutor.DiscardOldestPolicy())
    @Volatile private var connection: HttpURLConnection? = null
    @Volatile private var closed = false
    private var cachePrepared = false // IO worker only; discard leftovers from a previous process.

    fun open(id: Int, uri: String): Boolean {
        if (closed) return false
        synchronized(PhotoCache.lock) { current.set(id) }
        cancelDepth(); connection?.disconnect()
        worker.execute {
            if (current.get() != id || closed) return@execute
            var directory: File? = null
            var resolved = ""
            var published = false
            try {
                val app = context() ?: error("PHOTO_UNAVAILABLE")
                if (!cachePrepared) {
                    File(app.cacheDir, cacheName).listFiles()?.forEach { it.deleteRecursively() }
                    cachePrepared = true
                }
                directory = File(app.cacheDir, "$cacheName/$id").apply { mkdirs() }
                val source = File(directory, "source")
                resolved = resolve(uri)
                checkCurrent(id)
                val location = Uri.parse(resolved)
                val stream: InputStream = when (location.scheme) {
                    "file" -> File(location.path ?: error("PHOTO_UNAVAILABLE")).inputStream()
                    "content" -> app.contentResolver.openInputStream(location) ?: error("PHOTO_UNAVAILABLE")
                    "http", "https" -> {
                        val http = URL(resolved).openConnection() as HttpURLConnection
                        connection = http; http.connectTimeout = 15000; http.readTimeout = 20000
                        require(http.responseCode in 200..299) { "PHOTO_UNAVAILABLE" }
                        require(http.contentLengthLong <= MAX_BYTES) { "PHOTO_TOO_LARGE" }
                        http.inputStream
                    }
                    else -> error("PHOTO_UNAVAILABLE")
                }
                stream.use { input -> source.outputStream().use { output ->
                    val bytes = ByteArray(65536); var total = 0L
                    while (true) {
                        checkCurrent(id)
                        val count = input.read(bytes); if (count < 0) break
                        total += count; require(total <= MAX_BYTES) { "PHOTO_TOO_LARGE" }
                        output.write(bytes, 0, count)
                    }
                } }
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(source.path, bounds)
                require(bounds.outWidth in 1..32768 && bounds.outHeight in 1..32768) { "PHOTO_DECODE_FAILED" }
                require(bounds.outMimeType in setOf("image/jpeg", "image/png", "image/webp")) { "PHOTO_FORMAT_UNSUPPORTED" }
                val metadata = JSONObject().put("state", "ready").put("width", bounds.outWidth).put("height", bounds.outHeight)
                val orientation = runCatching { ExifInterface(source.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) }.getOrDefault(1)
                metadata.put("orientation", orientation)
                // GPano is a positive hint only; ordinary 2:1 photos stay flat.
                val header = source.inputStream().use { input ->
                    val bytes = ByteArray(minOf(source.length(), 1024L * 1024).toInt())
                    var count = 0
                    while (count < bytes.size) {
                        val read = input.read(bytes, count, bytes.size - count)
                        if (read < 0) break
                        count += read
                    }
                    String(bytes, 0, count, Charsets.ISO_8859_1)
                }
                val panorama = header.contains("GPano:ProjectionType=\"equirectangular\"") || header.contains("<GPano:ProjectionType>equirectangular</GPano:ProjectionType>")
                metadata.put("panorama", panorama)
                fun field(name: String): Int = Regex("GPano:$name(?:=\"|>)([0-9]+)").find(header)?.groupValues?.get(1)?.toIntOrNull() ?: 0
                for (key in listOf("FullPanoWidthPixels", "FullPanoHeightPixels", "CroppedAreaImageWidthPixels", "CroppedAreaImageHeightPixels", "CroppedAreaLeftPixels", "CroppedAreaTopPixels")) metadata.put(key, field(key))
                var sample = 1
                while (bounds.outWidth / sample > 8192 || bounds.outHeight / sample > 8192 ||
                    bounds.outWidth.toLong() / sample * (bounds.outHeight / sample) > MAX_PIXELS) sample *= 2
                var output = source
                if (sample > 1) {
                    val bitmap = BitmapFactory.decodeFile(source.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: error("PHOTO_DECODE_FAILED")
                    try {
                        output = File(directory, "preview.png")
                        output.outputStream().use { require(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                    } finally { bitmap.recycle() }
                }
                if (preload) {
                    var thumbSample = 1
                    while (maxOf(bounds.outWidth, bounds.outHeight) / thumbSample > 768) thumbSample *= 2
                    val bitmap = BitmapFactory.decodeFile(source.path, BitmapFactory.Options().apply { inSampleSize = thumbSample })
                    if (bitmap != null) {
                        val ratio = 384.0 / maxOf(bitmap.width, bitmap.height)
                        var small = bitmap
                        try {
                            small = Bitmap.createScaledBitmap(bitmap, maxOf(1, (bitmap.width * ratio).roundToInt()),
                                maxOf(1, (bitmap.height * ratio).roundToInt()), true)
                            val thumbnail = File(directory, "thumbnail.jpg")
                            thumbnail.outputStream().use { if (small.compress(Bitmap.CompressFormat.JPEG, 85, it)) metadata.put("thumbnail_path", thumbnail.path) }
                        } finally { if (small !== bitmap) small.recycle(); bitmap.recycle() }
                    }
                }
                checkCurrent(id)
                files[id] = PhotoSource(source)
                published = true
                metadata.put("path", output.path).put("sample", sample)
                    .put("cache_bytes",directory.listFiles()?.sumOf { it.length() } ?: source.length())
                emit("photo_ready", id, metadata.toString())
            } catch (_: InterruptedException) { }
            catch (error: Throwable) {
                if (!closed && current.get() == id) emit("photo_ready", id, JSONObject().put("state", "error")
                    .put("error", if (error.message == "PHOTO_TOO_LARGE") "PHOTO_TOO_LARGE" else "PHOTO_DECODE_FAILED").toString())
            } finally {
                connection?.disconnect(); connection = null
                if (uri.startsWith("smb://") || uri.startsWith("cloud://")) releaseStream(resolved)
                // A published preload may already have been adopted by the foreground bridge.
                if (!published) directory?.deleteRecursively()
            }
        }
        return true
    }

    fun cancel(id: Int) {
        if (current.compareAndSet(id, 0)) connection?.disconnect()
        release(id)
    }
    fun release(id: Int) = synchronized(PhotoCache.lock) {
        depthJobs.remove(id)?.cancelled = true
        files.remove(id)?.release()
    }
    fun cancelDepth() = synchronized(PhotoCache.lock) {
        depthJobs.values.forEach { it.cancelled = true }
        depthJobs.clear()
    }
    fun cancelBackgroundDepth() = synchronized(PhotoCache.lock) {
        depthJobs.entries.filter { it.value.background }.forEach { it.value.cancelled = true; depthJobs.remove(it.key) }
    }
    fun updateDepthStrength(strength: Float) = synchronized(PhotoCache.lock) {
        if (strength.isFinite() && strength in 0f..1f)
            depthJobs.values.filter { it.stereo && !it.cancelled }.forEach { it.strength = strength }
    }
    /** Transfer both the source lease and unfinished work; its final signal follows the owner. */
    fun promoteTo(id: Int, target: PhotoBridge): Boolean = synchronized(PhotoCache.lock) {
        if (target.closed || files[id]?.file?.isFile != true) return@synchronized false
        target.cancelDepth()
        val source = files.remove(id) ?: return@synchronized false
        target.files[id] = source
        target.current.set(id)
        target.connection?.disconnect()
        depthJobs.remove(id)?.let { job -> job.owner = target; job.background = false; target.depthJobs[id] = job }
        true
    }
    // Includes a transfer not yet published, and files promoted from the preload bridge.
    fun cacheDirectories(): Set<File> = synchronized(PhotoCache.lock) {
        val active = files.values.mapNotNull { it.file.parentFile }.toMutableSet()
        // A cancelled worker still owns its input until its finally block runs.
        active.addAll(inFlightSources.values.mapNotNull { it.file.parentFile })
        val id = current.get()
        if (id != 0) context()?.let { active.add(File(it.cacheDir, "$cacheName/$id")) }
        active
    }
    fun activate(id: Int): Boolean {
        if (closed || files[id]?.file?.isFile != true) return false
        synchronized(PhotoCache.lock) {
            depthJobs.entries.filter { it.key != id }.forEach { it.value.cancelled = true; depthJobs.remove(it.key) }
            depthJobs[id]?.background = false
            current.set(id)
        }
        connection?.disconnect()
        return true
    }
    fun adopt(id: Int, file: File): Boolean {
        if (closed || !file.isFile) return false
        files[id] = PhotoSource(file)
        return activate(id)
    }
    private fun checkCurrent(id: Int) { if (closed || current.get() != id) throw InterruptedException() }

    /** One inference per photo on the shared model thread, using the independent photo model.
     * Color stays at source display resolution; only content contributes to depth normalization. */
    fun depth(id: Int, strength: Float = 1f, stereo: Boolean = false, background: Boolean = preload): Boolean {
        if (!strength.isFinite() || strength !in 0f..2f) return false
        val job = synchronized(PhotoCache.lock) {
            if (closed) return false
            val source = files[id] ?: return false
            val existing = depthJobs[id]
            if (existing != null && !existing.cancelled && existing.stereo == stereo) {
                existing.strength = strength
                existing.background = background
                return true
            }
            depthJobs.remove(id)?.cancelled = true
            DepthJob(id, source.retain(), strength, stereo, this, background).also {
                depthJobs[id] = it
                inFlightSources[it] = source
            }
        }
        val source = job.source.file
        fun checkDepth() { if (job.cancelled || job.owner.closed) throw InterruptedException() }
        // A new foreground selection passes cancelled background jobs still waiting in the queue.
        val work = Runnable {
            val started = System.nanoTime()
            try {
                checkDepth()
                val app = context() ?: error("PHOTO_UNAVAILABLE")
                val w = PhotoDepthInput.WIDTH; val h = PhotoDepthInput.HEIGHT
                val near = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.LITTLE_ENDIAN)
                val target = File(source.parentFile, "depth.bin")
                val metadata = File(source.parentFile, "depth.json")
                val cached = if (target.length() == w.toLong()*h*4 && metadata.isFile)
                    runCatching { JSONObject(metadata.readText()).takeIf { it.optString("photo_cache") == "da2-518-stretch-v1" } }.getOrNull() else null
                val result: JSONObject
                if (cached != null) {
                    near.put(target.readBytes()); near.rewind()
                    result = cached.put("depth_cached",true).put("model_reused",false)
                } else {
                    stage(id,"input")
                    val inputStarted = System.nanoTime()
                    val input = PhotoDepthInput.prepare(source)
                    val inputMs = (System.nanoTime() - inputStarted) / 1_000_000.0
                    val content = input.content
                    checkDepth()
                    stage(id,"waiting_model")
                    val modelStarted = System.nanoTime()
                    result = PhotoDepthRuntime.run(app,::checkDepth) { handle, reused ->
                        checkDepth()
                        val runtime = JSONObject(DepthNative.describe(handle)).put("session_reused", reused)
                        stage(id,"inference")
                        JSONObject(DepthNative.processPhoto(handle,input.rgb,near,content.x,content.y,content.width,content.height))
                            .put("runtime",runtime).put("model_reused",reused).put("depth_cached",false)
                    }
                    result.put("input_ms",inputMs).put("depth_total_ms",(System.nanoTime()-modelStarted)/1_000_000.0)
                    require(result.optString("state") == "ready")
                    checkDepth()
                    near.rewind(); val bytes = ByteArray(near.remaining()); near.get(bytes); near.rewind()
                    target.writeBytes(bytes)
                    result.put("path",target.path).put("width",w).put("height",h).put("photo_cache","da2-518-stretch-v1")
                        .put("rect",org.json.JSONArray(listOf(content.x.toDouble()/w,content.y.toDouble()/h,content.width.toDouble()/w,content.height.toDouble()/h)))
                    metadata.writeText(result.toString())
                }
                checkDepth()
                if (stereo) {
                    stage(id,"stereo")
                    val stereoStarted = System.nanoTime()
                    val rect = result.getJSONArray("rect")
                    val pair = PhotoStereo.prepare(source,near,FloatArray(4) { rect.getDouble(it).toFloat() },job.strength,id)
                    pair.keys().forEach { key -> result.put(key,pair.get(key)) }
                    result.put("stereo_total_ms",(System.nanoTime()-stereoStarted)/1_000_000.0)
                }
                result.put("total_ms",(System.nanoTime()-started)/1_000_000.0)
                    .put("cache_bytes",source.parentFile?.listFiles()?.sumOf { it.length() } ?: 0L)
                synchronized(PhotoCache.lock) {
                    checkDepth()
                    // Once a result is committed, a strength retry must enqueue fresh pair work.
                    job.owner.depthJobs.remove(id,job)
                    job.owner.stage(id,"ready")
                    android.util.Log.i("QuestPhotoDepth", "request=$id cached=${cached != null} reused=${result.optBoolean("model_reused")} total_ms=${result.optDouble("total_ms")} " +
                        "input_ms=${result.optDouble("input_ms")} depth_ms=${result.optDouble("depth_ms")} priority=${result.optJSONObject("runtime")?.optInt("priority",-1)} " +
                        "stereo_ms=${result.optDouble("stereo_total_ms")} stereo_gpu_us=${result.optLong("stereo_render_us")}")
                    job.owner.emit(if (job.background) "photo_preload_depth" else "photo_depth",id,result.toString())
                }
            } catch (_: InterruptedException) { }
            catch (error: Throwable) {
                synchronized(PhotoCache.lock) { if (!job.cancelled && !job.owner.closed) {
                    job.owner.depthJobs.remove(id,job)
                    job.owner.stage(id,"failed")
                    android.util.Log.w("QuestPhotoDepth", "Photo depth failed", error)
                    job.owner.emit(if (job.background) "photo_preload_depth" else "photo_depth", id, "{\"state\":\"error\",\"error\":\"PHOTO_DEPTH_FAILED\"}")
                } }
            }
            finally { synchronized(PhotoCache.lock) {
                job.owner.depthJobs.remove(id,job)
                inFlightSources.remove(job)
                job.source.release()
            } }
        }
        if (postDepth != null) postDepth.invoke(work,!background)
        else if (background) DepthWorker.handler.post(work) else DepthWorker.handler.postAtFrontOfQueue(work)
        return true
    }

    private fun stage(id: Int, phase: String) {
        android.util.Log.i("QuestPhotoDepth","request=$id preload=$preload phase=$phase")
        if (!BuildConfig.DEBUG) return
        runCatching {
            val app = context() ?: return@runCatching
            val directory = File(app.filesDir,"diagnostics").apply { mkdirs() }
            val report = JSONObject().put("pid",android.os.Process.myPid()).put("request",id).put("preload",preload)
                .put("phase",phase).put("uptime_ms",android.os.SystemClock.uptimeMillis())
            val file = android.util.AtomicFile(File(directory,"photo_pipeline.json"))
            val output = file.startWrite()
            try { output.write(report.toString().toByteArray(Charsets.UTF_8)); file.finishWrite(output) }
            catch (error: Throwable) { file.failWrite(output); throw error }
        }
    }

    override fun close() {
        closed = true; current.set(0); cancelDepth(); connection?.disconnect(); worker.shutdownNow()
        files.keys.toList().forEach(::release)
    }
    companion object {
        const val MAX_BYTES = 256L * 1024 * 1024; const val MAX_PIXELS = 32L * 1024 * 1024
        private val inFlightSources = ConcurrentHashMap<DepthJob, PhotoSource>()
    }
}
