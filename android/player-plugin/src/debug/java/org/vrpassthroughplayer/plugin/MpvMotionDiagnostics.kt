package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.floor

/** Actual moving MPV source + production preprocessing, recurrent runtime and
 * R8 upload. Private test evidence only: no Godot, XR, audio or FPS claim.
 * Runs on the process-owned video worker, preserving the production OpenMP root.
 */
internal object MpvMotionDiagnostics {
    private val ids = AtomicInteger()
    private val busy = AtomicBoolean()
    private const val FIXTURE_SHA = "6e83e7cb05391d63512b14b46cafa381a48b5706b15a60ae33c407a2abbbb520"
    @JvmStatic private external fun stepFrame(handle: Long): Boolean
    fun request(context: Context, profile: String, ordered: Boolean = false): Int {
        require(profile in RvmProfiles.keys)
        if (!busy.compareAndSet(false, true)) return -1
        val id = ids.incrementAndGet()
        if (!RvmWorkers.video.post { try { run(context.applicationContext, id, profile, ordered) } finally { busy.set(false) } }) {
            busy.set(false); return -1
        }
        return id
    }
    private fun until(timeoutMs: Long, condition: () -> Boolean) {
        val end = System.nanoTime() + timeoutMs * 1_000_000
        while (!condition()) { check(System.nanoTime() < end) { "Motion probe timeout" }; Thread.sleep(2) }
    }
    private fun hash(buffer: ByteBuffer): String = MessageDigest.getInstance("SHA-256").run {
        update(buffer.duplicate().apply { clear() }); digest().joinToString("") { "%02x".format(it) }
    }
    private fun run(context: Context, id: Int, profile: String, ordered: Boolean) {
        val root = File(context.filesDir, "diagnostics").apply { mkdirs() }
        val directory = File(root, "mpv_motion_${DiagnosticRequests.processId}_$id").apply { check(mkdir()) }
        val records = JSONArray()
        val report = JSONObject().put("schema_version", 1).put("request_id", id).put("diagnostic_process", DiagnosticRequests.processId)
            .put("fixture", "mp07_motion_4k").put("profile", profile).put("state", "failed")
            .put("ordered_frames", ordered)
            .put("evidence_directory", directory.name).put("records", records).put("audio_enabled", false)
            .put("godot_context_shared", false).put("xr_entry", false).put("requested_hardware", true)
            .put("scope", "Continuous six-second moving source; all accepted recurrent inputs and outputs saved. Diagnostic I/O affects timing; no Godot/XR/audio/sustained FPS proof")
        val owner = MpvSharedDiagnostics.Owner()
        var source = 0L; var bridge = 0L; var runtime: RvmRuntime? = null
        var producer = 0L; var token = 0L
        var phase = "fixture"
        try {
            val fixture = File(context.filesDir, "fixtures/mp07_motion_4k.mp4")
            check(fixture.isFile && fixture.length() == 46_903_705L)
            val digest = MessageDigest.getInstance("SHA-256")
            fixture.inputStream().use { stream ->
                val bytes = ByteArray(65536)
                while (true) { val size = stream.read(bytes); if (size < 0) break; digest.update(bytes, 0, size) }
            }
            val fixtureHash = digest.digest().joinToString("") { "%02x".format(it) }
            check(fixtureHash == FIXTURE_SHA) { "Motion fixture differs from locked local source" }
            report.put("fixture_sha256", fixtureHash)
            phase = "prepare"
            owner.start()
            val dims = profile.split('x').map { it.toInt() }; val width = dims[0]; val height = dims[1]
            val pixels = width * height
            bridge = RenderBridgeNative.create(3840, 2160, width, height, true)
            check(bridge > 0)
            fun floats(size: Int) = ByteBuffer.allocateDirect(size * 4).order(ByteOrder.LITTLE_ENDIAN)
            val left = floats(pixels * 3); val right = floats(pixels * 3)
            val alphaLeft = floats(pixels); val alphaRight = floats(pixels)
            val mask = ByteBuffer.allocateDirect(pixels * 2)
            val session = 1_000_000L + id
            runtime = RvmRuntime.prepare(context.assets, true, profile, session, 1)
            source = MpvSourceNative.create(context, fixture.absolutePath, 0, true, false)
            check(source > 0)
            if (!ordered) MpvSourceNative.setPlaying(source, true)
            var lastPts = -1L; var lastFrame = -1L
            val deadline = System.nanoTime() + (if (ordered) 300_000_000_000L else 90_000_000_000L)
            phase = "continuous_source"
            while (true) {
                check(System.nanoTime() < deadline) { "Continuous motion deadline exceeded" }
                val status = JSONObject(MpvSourceNative.status(source))
                check(status.optString("state") != "failed" && !status.optBoolean("render_failed")) { status.toString() }
                val text = MpvSourceNative.acquire(source)
                if (text.isEmpty()) {
                    val terminal = status.optJSONObject("eof_source_ticket")
                    if (status.optBoolean("eof_source_resolved") && terminal != null &&
                        terminal.getLong("pts_us") == lastPts && terminal.getLong("frame_id") == lastFrame) break
                    Thread.sleep(2); continue
                }
                val pair = JSONObject(text)
                producer = pair.getLong("producer_token")
                check(pair.getInt("width") == 3840 && pair.getInt("height") == 2160 && pair.getInt("rotation_degrees") == 0)
                val pts = pair.getLong("pts_us"); val frame = pair.getLong("frame_id")
                if (pts == lastPts && frame == lastFrame) {
                    check(MpvSourceNative.release(source, producer)); producer = 0; continue
                }
                check(pts > lastPts && frame > lastFrame && records.length() < 180) { "Motion input sequence changed" }
                if (ordered) check(pts == (records.length() * 1_000_000L + 15) / 30) { "Ordered source frame skipped" }
                token = RenderBridgeNative.captureTexture(bridge, pair.getInt("color_texture_id"), true)
                check(token > 0)
                check(MpvSourceNative.release(source, producer)); producer = 0
                until(5000) { RenderBridgeNative.ready(bridge, token) }
                check(RenderBridgeNative.readInputs(bridge, token, left, right))
                val started = System.nanoTime()
                val kernel = runtime.process(1, frame, pts, left, right, alphaLeft, alphaRight)
                val processMs = (System.nanoTime() - started) / 1e6
                check(kernel.getString("state") == "ready" && kernel.getLong("session_id") == session &&
                    kernel.getLong("generation") == 1L && kernel.getLong("frame_id") == frame && kernel.getLong("pts_us") == pts)
                // ncnn reports a committed-frame counter; MNN commits per call and reports placement instead.
                kernel.optJSONObject("explicit_gpu_transfer_totals")?.let {
                    check(it.getLong("committed_stereo_frames") == records.length() + 1L)
                } ?: check(kernel.getString("backend") == "MNN_OpenCL" && kernel.getInt("cpu_fallback_ops") == 0)
                check(RenderBridgeNative.uploadAlpha(bridge, token, alphaLeft, alphaRight))
                until(5000) { RenderBridgeNative.alphaReady(bridge, token) }
                check(RenderBridgeNative.readAlpha(bridge, token, mask))
                var mismatches = 0
                for (eye in 0..1) for (y in 0 until height) for (x in 0 until width) {
                    val value = (if (eye == 0) alphaLeft else alphaRight).getFloat((y * width + x) * 4)
                    val expected = floor((value * 255f).toDouble() + .5).toInt()
                    if ((mask.get(y * width * 2 + eye * width + x).toInt() and 255) != expected) mismatches++
                }
                check(mismatches == 0) { "Same-frame GPU Alpha quantization differs" }
                val files = JSONObject()
                for ((name, buffer) in listOf("left_rgb" to left, "right_rgb" to right,
                    "left_alpha" to alphaLeft, "right_alpha" to alphaRight, "mask" to mask)) {
                    val filename = "frame_${records.length() + 1}_$name.${if (name == "mask") "r8" else "f32"}"
                    File(directory, filename).outputStream().channel.use { channel ->
                        val bytes = buffer.duplicate().apply { clear() }
                        while (bytes.hasRemaining()) check(channel.write(bytes) > 0)
                    }
                    files.put(name, JSONObject().put("file", filename).put("bytes", buffer.capacity()).put("sha256", hash(buffer)))
                }
                pair.put("ordinal", records.length() + 1).put("kernel", kernel).put("files", files)
                    .put("rvm_process_ms", processMs).put("alpha_byte_mismatches", mismatches)
                    .put("alpha_gpu_uploaded", true).put("alpha_fence_ready", true)
                    .put("alpha_slot_token", token).put("input_width", width).put("input_height", height)
                records.put(pair); lastPts = pts; lastFrame = frame
                RenderBridgeNative.retire(bridge, token)
                until(5000) { RenderBridgeNative.retired(bridge, token) }; token = 0
                if (ordered) {
                    // One final step lets MPV resolve EOF while retaining frame 179.
                    val eof = JSONObject(MpvSourceNative.status(source)).optBoolean("eof_source_resolved")
                    if (!eof) check(stepFrame(source)) { "Forward step rejected" }
                }
            }
            val terminal = JSONObject(MpvSourceNative.status(source))
            check(records.length() >= 12 && lastPts == 5_966_667L && terminal.getJSONObject("details").getString("hwdec_current") == "mediacodec")
            if (ordered) check(records.length() == 180 && terminal.getLong("debug_step_images") == 179L &&
                terminal.getLong("debug_steps_applied") in 179L..180L && terminal.getLong("seeks_started") == 0L)
            report.put("terminal_status", terminal).put("state", "passed_native_checks")
        } catch (failure: Throwable) {
            report.put("state", "failed").put("failure_phase", phase).put("error", failure.toString())
        } finally {
            try {
                runtime?.close(); runtime = null
                if (producer > 0) { check(MpvSourceNative.release(source, producer)); producer = 0 }
                if (token > 0) { RenderBridgeNative.retire(bridge, token); until(5000) { RenderBridgeNative.retired(bridge, token) }; token = 0 }
                if (bridge > 0) { RenderBridgeNative.close(bridge); bridge = 0 }
                if (source > 0) {
                    MpvSourceNative.requestClose(source)
                    until(15_000) { MpvSourceNative.close(source, false) }; source = 0
                }
                report.put("resources_closed", owner.close())
            } catch (failure: Throwable) {
                report.put("state", "failed").put("cleanup_error", failure.toString()).put("resources_closed", false)
            }
            val temporary = File.createTempFile("motion-", ".tmp", root)
            try {
                temporary.writeText(report.toString())
                check(temporary.renameTo(File(root, "mpv_motion_$id.json")))
            } finally { temporary.delete() }
        }
    }
}
