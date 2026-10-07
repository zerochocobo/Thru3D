package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
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
    private val emit: (String, Int, String) -> Unit,
) : Closeable {
    private val current = AtomicInteger(0)
    private val depthGeneration = AtomicInteger(0)
    private val files = ConcurrentHashMap<Int, File>()
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(1),
        { Thread(it, "QuestPhotoIO") }, ThreadPoolExecutor.DiscardOldestPolicy())
    @Volatile private var connection: HttpURLConnection? = null
    @Volatile private var closed = false
    private var cachePrepared = false // IO worker only; discard leftovers from a previous process.

    fun open(id: Int, uri: String): Boolean {
        if (closed) return false
        current.set(id); depthGeneration.incrementAndGet(); connection?.disconnect()
        worker.execute {
            if (current.get() != id || closed) return@execute
            var directory: File? = null
            var resolved = ""
            try {
                val app = context() ?: error("PHOTO_UNAVAILABLE")
                if (!cachePrepared) {
                    File(app.cacheDir, "photos").listFiles()?.forEach { it.deleteRecursively() }
                    cachePrepared = true
                }
                directory = File(app.cacheDir, "photos/$id").apply { mkdirs() }
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
                checkCurrent(id)
                files[id] = source
                metadata.put("path", output.path).put("sample", sample)
                emit("photo_ready", id, metadata.toString())
            } catch (_: InterruptedException) { }
            catch (error: Throwable) {
                if (!closed && current.get() == id) emit("photo_ready", id, JSONObject().put("state", "error")
                    .put("error", if (error.message == "PHOTO_TOO_LARGE") "PHOTO_TOO_LARGE" else "PHOTO_DECODE_FAILED").toString())
            } finally {
                connection?.disconnect(); connection = null
                if (uri.startsWith("smb://") || uri.startsWith("cloud://")) releaseStream(resolved)
                if (!files.containsKey(id)) directory?.deleteRecursively()
            }
        }
        return true
    }

    fun cancel(id: Int) {
        if (current.compareAndSet(id, 0)) { depthGeneration.incrementAndGet(); connection?.disconnect() }
        release(id)
    }
    fun release(id: Int) { files.remove(id)?.parentFile?.deleteRecursively() }
    private fun checkCurrent(id: Int) { if (closed || current.get() != id) throw InterruptedException() }

    /** One inference per photo. Depth runs on the existing persistent model thread, reset between
     * photos. Color stays at source display resolution; letterboxing preserves portrait geometry. */
    fun depth(id: Int): Boolean {
        val source = files[id] ?: return false
        val generation = depthGeneration.incrementAndGet()
        fun checkDepth() { if (closed || !files.containsKey(id) || generation != depthGeneration.get()) throw InterruptedException() }
        DepthWorker.handler.post {
            var handle = 0L
            try {
                checkDepth()
                if (generation != depthGeneration.get()) return@post
                val app = context() ?: error("PHOTO_UNAVAILABLE")
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(source.path, bounds)
                var sample = 1
                while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 1024) sample *= 2
                val original = BitmapFactory.decodeFile(source.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: error("PHOTO_DECODE_FAILED")
                val orientation = runCatching { ExifInterface(source.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) }.getOrDefault(1)
                val matrix = Matrix().apply { when (orientation) {
                    2 -> setScale(-1f, 1f); 3 -> setRotate(180f); 4 -> setScale(1f, -1f)
                    5 -> { setRotate(90f); postScale(-1f, 1f) }; 6 -> setRotate(90f)
                    7 -> { setRotate(90f); postScale(1f, -1f) }; 8 -> setRotate(270f)
                } }
                val upright = Bitmap.createBitmap(original, 0, 0, original.width, original.height, matrix, true)
                val w = 252; val h = 140
                val scale = minOf(w.toDouble() / upright.width, h.toDouble() / upright.height)
                val cw = (upright.width * scale).roundToInt().coerceIn(1, w)
                val ch = (upright.height * scale).roundToInt().coerceIn(1, h)
                val x = (w - cw) / 2; val y = (h - ch) / 2
                val input = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                try {
                    Canvas(input).apply { drawColor(Color.BLACK); drawBitmap(upright, null, Rect(x, y, x + cw, y + ch), Paint(Paint.FILTER_BITMAP_FLAG)) }
                } finally { if (upright !== original) upright.recycle(); original.recycle() }
                val pixels = IntArray(w * h)
                try { input.getPixels(pixels, 0, w, 0, 0, w, h) } finally { input.recycle() }
                val rgb = ByteBuffer.allocateDirect(w * h * 12).order(ByteOrder.LITTLE_ENDIAN)
                for (shift in listOf(16, 8, 0)) for (pixel in pixels) rgb.putFloat(((pixel shr shift) and 255) / 255f)
                rgb.rewind()
                val near = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.LITTLE_ENDIAN)
                checkDepth()
                handle = DepthNative.create(app.assets, DepthWarmup.cacheDirectory(app).path)
                require(handle != 0L)
                val result = JSONObject(DepthNative.process(handle, rgb, near, true, 1))
                require(result.optString("state") == "ready")
                checkDepth()
                if (generation != depthGeneration.get()) return@post
                near.rewind(); val bytes = ByteArray(near.remaining()); near.get(bytes)
                val target = File(source.parentFile, "depth.bin")
                target.writeBytes(bytes)
                emit("photo_depth", id, JSONObject().put("state", "ready").put("path", target.path).put("width", w).put("height", h)
                    .put("rect", org.json.JSONArray(listOf(x.toDouble()/w, y.toDouble()/h, cw.toDouble()/w, ch.toDouble()/h))).toString())
            } catch (_: InterruptedException) { }
            catch (_: Throwable) { if (!closed && files.containsKey(id) && generation == depthGeneration.get()) emit("photo_depth", id, "{\"state\":\"error\",\"error\":\"PHOTO_DEPTH_FAILED\"}") }
            finally { if (handle != 0L) DepthNative.close(handle) }
        }
        return true
    }

    override fun close() {
        closed = true; current.set(0); depthGeneration.incrementAndGet(); connection?.disconnect(); worker.shutdownNow()
        files.keys.toList().forEach(::release)
    }
    companion object { const val MAX_BYTES = 256L * 1024 * 1024; const val MAX_PIXELS = 32L * 1024 * 1024 }
}
