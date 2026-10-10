package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.Bitmap
import android.opengl.GLES30
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Bounded diagnostics of the actual production Source, absent from Release.
 * Pixel readback occurs only on the initial paused frame; paced playback has
 * no readback. Accept only a pre-pushed fixture in this app's private directory. */
internal object MpvDolbyDiagnostics {
    private val ids = AtomicInteger()
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(1),
        { task -> Thread(task, "QuestMpvDolbyProbe") }, ThreadPoolExecutor.AbortPolicy())

    fun request(context: Context, fixture: String, direct: Boolean, audio: Boolean,
                hardware: Boolean = true, pixelsOnly: Boolean = false): Int {
        require(fixture.matches(Regex("[a-z0-9_-]+\\.(mkv|mp4)")))
        val id = ids.incrementAndGet()
        return try { worker.execute { run(context.applicationContext, id, fixture, direct, audio, hardware, pixelsOnly) }; id }
        catch (_: Exception) { -1 }
    }

    private fun run(context: Context, id: Int, fixture: String, direct: Boolean, audio: Boolean,
                    hardware: Boolean, pixelsOnly: Boolean) {
        val report = JSONObject().put("request_id", id).put("diagnostic_process", DiagnosticRequests.processId)
            .put("fixture", fixture).put("hardware_requested", hardware).put("direct_requested", direct)
            .put("pixels_only", pixelsOnly)
            .put("audio_requested", audio).put("scope", "production Source in offscreen GLES; Godot/XR not exercised")
        val owner = MpvSharedDiagnostics.Owner()
        val directory = File(context.filesDir, "diagnostics").apply { mkdirs() }
        var source = 0L
        var held = 0L
        val records = JSONArray()
        val audioSnapshots = JSONArray()
        try {
            val input = File(context.filesDir, "fixtures/$fixture")
            check(input.isFile)
            owner.start()
            report.put("gl_extensions", GLES30.glGetString(GLES30.GL_EXTENSIONS))
            source = MpvSourceNative.create(context, input.absolutePath, 0, hardware, audio)
            MpvSourceNative.setDirect(source, direct)
            fun nextFrame(timeoutMs: Long): JSONObject {
                val deadline = System.nanoTime() + timeoutMs * 1_000_000
                while (System.nanoTime() < deadline) {
                    val status = JSONObject(MpvSourceNative.status(source))
                    check(status.optString("state") != "failed" && !status.optBoolean("render_failed")) { status.toString() }
                    val raw = MpvSourceNative.acquire(source)
                    if (raw.isNotEmpty()) return JSONObject(raw)
                    Thread.sleep(2)
                }
                error("Frame timeout: ${MpvSourceNative.status(source)}")
            }
            fun savePixels(pair: JSONObject, label: String) {
                if (pair.optLong("hardware_buffer") != 0L) return
                val w = pair.getInt("width"); val h = pair.getInt("height")
                val fbo = IntArray(1)
                GLES30.glGenFramebuffers(1, fbo, 0)
                try {
                    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo[0])
                    GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
                        GLES30.GL_TEXTURE_2D, pair.getInt("color_texture_id"), 0)
                    check(GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER) == GLES30.GL_FRAMEBUFFER_COMPLETE)
                    val bytes = ByteBuffer.allocateDirect(w * h * 4)
                    GLES30.glReadPixels(0, 0, w, h, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, bytes)
                    check(GLES30.glGetError() == GLES30.GL_NO_ERROR)
                    val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                    bytes.rewind(); bitmap.copyPixelsFromBuffer(bytes)
                    File(directory, "mpv_dolby_${id}_$label.png").outputStream().use {
                        check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it))
                    }
                    bitmap.recycle()
                    report.put("${label}_frame", pair)
                } finally {
                    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
                    GLES30.glDeleteFramebuffers(1, fbo, 0)
                }
            }
            val first = nextFrame(20_000); held = first.getLong("producer_token")
            savePixels(first, "initial")
            check(MpvSourceNative.release(source, held)); held = 0
            val started = System.nanoTime()
            if (!pixelsOnly) MpvSourceNative.setPlaying(source, true)
            var firstNs = 0L; var lastNs = 0L
            var audioSequence = -1L
            val deadline = started + 30_000_000_000L
            while (!pixelsOnly && System.nanoTime() < deadline) {
                val status = JSONObject(MpvSourceNative.status(source))
                check(status.optString("state") != "failed" && !status.optBoolean("render_failed")) { status.toString() }
                val details = status.optJSONObject("details")
                if (audio && details != null && details.optLong("snapshot_sequence") != audioSequence) {
                    audioSequence = details.optLong("snapshot_sequence")
                    audioSnapshots.put(details)
                }
                val raw = MpvSourceNative.acquire(source)
                if (raw.isNotEmpty()) {
                    val pair = JSONObject(raw); held = pair.getLong("producer_token")
                    val now = System.nanoTime()
                    if (firstNs == 0L) firstNs = now
                    lastNs = now
                    records.put(pair.put("observed_ns", now))
                    check(MpvSourceNative.release(source, held)); held = 0
                }
                if (status.optBoolean("eof_source_resolved")) break
                Thread.sleep(1)
            }
            report.put("paced_frames", records).put("paced_elapsed_ns", lastNs - firstNs)
                .put("audio_snapshots", audioSnapshots)
                .put("after_playback", JSONObject(MpvSourceNative.status(source)))
            if (!pixelsOnly) {
                check(records.length() >= 24)
                check(JSONObject(MpvSourceNative.status(source)).optBoolean("eof_source_resolved"))
            }
            MpvSourceNative.setPlaying(source, false)
            check(MpvSourceNative.seek(source, 2000))
            var seek = nextFrame(15_000); held = seek.getLong("producer_token")
            val seekDeadline = System.nanoTime() + 15_000_000_000L
            while (seek.getLong("source_epoch") <= first.getLong("source_epoch")) {
                check(MpvSourceNative.release(source, held)); held = 0
                check(System.nanoTime() < seekDeadline)
                seek = nextFrame(15_000); held = seek.getLong("producer_token")
            }
            check(seek.getLong("source_epoch") > first.getLong("source_epoch"))
            check(seek.getLong("pts_us") >= 2_000_000)
            savePixels(seek, "seek")
            check(MpvSourceNative.release(source, held)); held = 0
            report.put("seek_frame", seek).put("state", "passed_native_checks")
        } catch (failure: Throwable) {
            report.put("state", "failed").put("error", failure.toString())
            if (source != 0L) report.put("failure_native_status", JSONObject(MpvSourceNative.status(source)))
        } finally {
            if (source != 0L) {
                if (held != 0L) runCatching { MpvSourceNative.release(source, held) }
                MpvSourceNative.requestClose(source)
                val deadline = System.nanoTime() + 10_000_000_000L
                var closed = false
                while (!closed && System.nanoTime() < deadline) {
                    closed = MpvSourceNative.close(source, false)
                    if (!closed) Thread.sleep(2)
                }
                report.put("source_closed", closed)
            }
            report.put("owner_closed", owner.close())
            File(directory, "mpv_dolby_$id.json").writeText(report.toString())
        }
    }
}
