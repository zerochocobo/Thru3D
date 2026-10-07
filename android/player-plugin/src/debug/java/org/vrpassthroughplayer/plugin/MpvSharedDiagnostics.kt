package org.vrpassthroughplayer.plugin

import android.content.Context
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.floor

/** Runs the real native MPV source and RenderBridge/RVM primitives in a shared
 * offscreen consumer. No Godot owner, material, OpenXR, audio or 30fps assertion.
 */
internal object MpvSharedDiagnostics {
    private val ids = AtomicInteger()
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(1),
        { task -> Thread(task, "QuestMpvSharedProbe") }, ThreadPoolExecutor.AbortPolicy())

    fun request(context: Context, hardware: Boolean): Int {
        val id = ids.incrementAndGet()
        return try { worker.execute { run(context.applicationContext, id, hardware) }; id } catch (_: Exception) { -1 }
    }
    internal class Owner {
        val display: EGLDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        var context: EGLContext = EGL14.EGL_NO_CONTEXT
        var surface: EGLSurface = EGL14.EGL_NO_SURFACE
        fun start() {
            check(display != EGL14.EGL_NO_DISPLAY)
            val version = IntArray(2); check(EGL14.eglInitialize(display, version, 0, version, 1))
            check(EGL14.eglBindAPI(EGL14.EGL_OPENGL_ES_API))
            val attributes = intArrayOf(EGL14.EGL_RENDERABLE_TYPE, 0x40, EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8, EGL14.EGL_NONE)
            val configs = arrayOfNulls<EGLConfig>(1); val count = IntArray(1)
            check(EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) && count[0] == 1)
            context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0)
            check(context != EGL14.EGL_NO_CONTEXT)
            surface = EGL14.eglCreatePbufferSurface(display, configs[0], intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
            check(surface != EGL14.EGL_NO_SURFACE && EGL14.eglMakeCurrent(display, surface, surface, context))
        }
        fun close(): Boolean {
            var ok = EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (surface != EGL14.EGL_NO_SURFACE) { ok = EGL14.eglDestroySurface(display, surface) && ok; surface = EGL14.EGL_NO_SURFACE }
            if (context != EGL14.EGL_NO_CONTEXT) { ok = EGL14.eglDestroyContext(display, context) && ok; context = EGL14.EGL_NO_CONTEXT }
            return EGL14.eglReleaseThread() && ok // Never terminate Godot's process-global display.
        }
    }
    private fun until(timeoutMs: Long, action: () -> Boolean) {
        val deadline = System.nanoTime()+timeoutMs*1_000_000
        while (!action()) { check(System.nanoTime() < deadline) { "Shared probe condition timeout" }; Thread.sleep(2) }
    }
    private fun frame(source: Long): JSONObject {
        var result: JSONObject? = null
        until(15_000) {
            val status = JSONObject(MpvSourceNative.status(source))
            check(status.optString("state") != "failed" && !status.optBoolean("render_failed")) { status.toString() }
            val value = MpvSourceNative.acquire(source)
            if (value.isNotEmpty()) result = JSONObject(value)
            result != null
        }
        return result!!
    }
    private fun samples(source: Long, pair: JSONObject): JSONArray {
        val bytes = ByteBuffer.allocateDirect(96)
        MpvSourceNative.readFrameCode(source, pair.getLong("producer_token"), bytes)
        return JSONArray((0 until 24).map { pixel -> JSONArray((0..3).map { bytes.get(pixel*4+it).toInt() and 255 }) })
    }
    private fun run(context: Context, id: Int, hardware: Boolean) {
        val report = JSONObject().put("schema_version", 4).put("request_id", id)
            .put("diagnostic_process", DiagnosticRequests.processId).put("hardware_requested", hardware)
            .put("fixture", "mp03_frame_identity").put("profile", "384x216")
            .put("consumer_context_origin", "debug_offscreen_GLES_pbuffer")
            .put("godot_context_shared", false).put("godot_display_verified", false).put("xr_verified", false)
            .put("audio_verified", false).put("performance_verified", false).put("source_pts_verified", false)
        val owner = Owner(); var source = 0L; var bridge = 0L; var runtime: RvmRuntime? = null
        val producerHeld = HashSet<Long>(); val colorHeld = HashSet<Long>()
        val records = JSONArray(); val bounds = JSONArray()
        val holdTimeline = JSONArray()
        report.put("bounded_slots", bounds).put("producer_hold_timeline", holdTimeline)
        var phase = "initialize"
        try {
            check(MpvSourceNative.supported())
            val target = File(context.filesDir, "fixtures/mp03_frame_identity.mp4").apply { parentFile!!.mkdirs() }
            context.assets.open("media/mp03_frame_identity.mp4").use { input -> target.outputStream().use { input.copyTo(it) } }
            owner.start()
            source = MpvSourceNative.create(context, target.absolutePath, 0, hardware, false)
            check(source > 0)
            MpvSourceNative.setPlaying(source, true)
            // Hold all three producer colors while MPV continues decoding. Actual
            // moving code pixels must survive producer backpressure unchanged.
            repeat(3) {
                phase = "hold_producer_$it"
                val started = System.nanoTime()
                val pair = frame(source); producerHeld.add(pair.getLong("producer_token"))
                bounds.put(pair)
                holdTimeline.put(JSONObject().put("phase", phase).put("started_ns", started)
                    .put("finished_ns", System.nanoTime()).put("elapsed_ms", (System.nanoTime()-started)/1e6)
                    .put("producer_token", pair.getLong("producer_token")).put("pts_us", pair.getLong("pts_us"))
                    .put("native_status", JSONObject(MpvSourceNative.status(source))))
            }
            // Acquire all three before diagnostic readback. Mobile tile resolves
            // can take long enough for the six-second fixture to reach EOF;
            // interleaving them with acquire would never exercise backpressure.
            phase = "held_producer_baseline"
            for (index in 0 until bounds.length()) {
                val pair = bounds.getJSONObject(index)
                val started = System.nanoTime()
                pair.put("before", samples(source, pair))
                holdTimeline.put(JSONObject().put("phase", "baseline_$index").put("started_ns", started)
                    .put("finished_ns", System.nanoTime()).put("elapsed_ms", (System.nanoTime()-started)/1e6)
                    .put("native_status", JSONObject(MpvSourceNative.status(source))))
            }
            phase = "producer_backpressure"
            until(5000) { JSONObject(MpvSourceNative.status(source)).getLong("skipped") >= 3 }
            check(MpvSourceNative.acquire(source).isEmpty())
            for (index in 0 until bounds.length()) {
                val pair = bounds.getJSONObject(index); val after = samples(source, pair)
                check(after.toString() == pair.getJSONArray("before").toString()) { "Held producer color was overwritten" }
                pair.put("after", after)
                check(MpvSourceNative.release(source, pair.getLong("producer_token")))
                producerHeld.remove(pair.getLong("producer_token"))
                check(!MpvSourceNative.release(source, pair.getLong("producer_token"))) { "Double producer release accepted" }
            }
            report.put("bounded_slots", bounds).put("bounded_pool_status", JSONObject(MpvSourceNative.status(source)))
            phase = "prepare_render_bridge_and_rvm"
            bridge = RenderBridgeNative.create(1280, 640, 384, 216, true)
            val left = ByteBuffer.allocateDirect(384*216*3*4).order(ByteOrder.LITTLE_ENDIAN)
            val right = ByteBuffer.allocateDirect(left.capacity()).order(ByteOrder.LITTLE_ENDIAN)
            val a = ByteBuffer.allocateDirect(384*216*4).order(ByteOrder.LITTLE_ENDIAN)
            val b = ByteBuffer.allocateDirect(a.capacity()).order(ByteOrder.LITTLE_ENDIAN)
            val mask = ByteBuffer.allocateDirect(384*216*2)
            runtime = RvmRuntime.prepare(context.assets, true, "384x216", 900000L+id, 1)
            var generation = 1L
            var endGate: MpvEndGate? = null
            fun process(pair: JSONObject, phase: String) {
                val producer = pair.getLong("producer_token"); producerHeld.add(producer)
                pair.put("source_code", samples(source, pair)).put("phase", phase)
                val token = RenderBridgeNative.captureTexture(bridge, pair.getInt("color_texture_id"), true)
                check(token > 0); colorHeld.add(token)
                check(MpvSourceNative.release(source, producer)); producerHeld.remove(producer)
                until(5000) { RenderBridgeNative.ready(bridge, token) }
                check(RenderBridgeNative.readInputs(bridge, token, left, right))
                val rgb = JSONArray()
                // Independent host decoder verifies these 24 model-input centers
                // as well as the producer samples and source PTS.
                for (eye in 0..1) for (bit in 0 until 12) {
                    val px = floor(84.0+(36.5+50*bit)*216/640).toInt()
                    val py = floor(96.5*216/640).toInt()
                    val buffer = if (eye == 0) left else right
                    rgb.put(JSONArray((0..2).map { buffer.getFloat((it*384*216+py*384+px)*4).toDouble() }))
                }
                val kernel = runtime!!.process(generation, pair.getLong("frame_id"), pair.getLong("pts_us"), left, right, a, b)
                check(kernel.getString("state") == "ready" && kernel.getString("profile_key") == "384x216" &&
                    kernel.getLong("session_id") == 900000L+id && kernel.getLong("generation") == generation &&
                    kernel.getLong("frame_id") == pair.getLong("frame_id") && kernel.getLong("pts_us") == pair.getLong("pts_us")) { kernel.toString() }
                check(RenderBridgeNative.uploadAlpha(bridge, token, a, b))
                until(5000) { RenderBridgeNative.alphaReady(bridge, token) }
                check(RenderBridgeNative.readAlpha(bridge, token, mask))
                var mismatches = 0
                for (eye in 0..1) for (y in 0 until 216) for (x in 0 until 384) {
                    val value = (if (eye == 0) a else b).getFloat((y*384+x)*4)
                    val expected = floor((value*255f).toDouble()+0.5).toInt()
                    if ((mask.get(y*768+eye*384+x).toInt() and 255) != expected) mismatches++
                }
                check(mismatches == 0) { "GPU Alpha bytes differ from the same-ticket RVM outputs" }
                pair.put("model_code_rgb", rgb).put("kernel", kernel).put("model_generation", generation)
                    .put("alpha_pixels_checked", 384*216*2).put("alpha_byte_mismatches", mismatches)
                    .put("consumer_color_texture_id", RenderBridgeNative.texture(bridge, token))
                    .put("alpha_texture_id", RenderBridgeNative.alphaTexture(bridge, token)).put("consumer_slot", token)
                records.put(pair)
                if (phase == "eof_retained") {
                    // Exercise the production logical gates after the actual GPU
                    // Alpha fence, with a synthetic acknowledgement. This is not
                    // a Godot material binding or a real owner draw callback.
                    val scope = MediaSessionGate.Scope(id, id, generation.toInt())
                    val end = MpvEndGate(scope, true); endGate = end
                    val terminal = JSONObject(MpvSourceNative.status(source)).getJSONObject("eof_source_ticket")
                    end.observe(MpvEndGate.Source(terminal.getLong("source_epoch"), terminal.getLong("frame_id"), terminal.getLong("pts_us")))
                    val identity = FramePairGate.Identity(id, id, generation.toInt(), pair.getLong("frame_id"),
                        pair.getLong("pts_us"), 1, 1, generation, token)
                    val display = PairDisplayGate(scope)
                    val checks = JSONObject().put("context", "synthetic_ack_after_real_alpha_fence")
                    checks.put("before_draw_rejected", !end.complete())
                    checks.put("opaque_alpha_rejected", !end.postDraw(identity, pair.getLong("source_epoch"), false) && !end.complete())
                    check(end.postDraw(identity.copy(frameId=identity.frameId-1, ptsUs=identity.ptsUs-33333), pair.getLong("source_epoch"), true))
                    checks.put("penultimate_rejected", !end.complete())
                    checks.put("stale_generation_rejected", !end.postDraw(identity.copy(generation=scope.generation+1), pair.getLong("source_epoch"), true) && !end.complete())
                    check(display.offer(identity) == null && display.claim(token) == identity)
                    checks.put("unacknowledged_rejected", !display.drawn(token) && !end.complete())
                    check(display.acknowledge(token) && display.drawn(token))
                    check(end.postDraw(identity, pair.getLong("source_epoch"), true))
                    checks.put("final_accepted", end.complete()).put("completed_slot", end.completedSlot())
                    check(display.detach(token) && display.heldClaims() == 0)
                    check(listOf("before_draw_rejected", "opaque_alpha_rejected", "penultimate_rejected", "stale_generation_rejected", "unacknowledged_rejected", "final_accepted").all { checks.getBoolean(it) })
                    report.put("eof_gate_checks", checks)
                }
                RenderBridgeNative.retire(bridge, token)
                until(5000) { RenderBridgeNative.retired(bridge, token) }; colorHeld.remove(token)
            }
            var previousEpoch = 0L
            for ((index, position) in listOf(0L, 2000L, 0L).withIndex()) {
                phase = "seek_${index}_${position}_request"
                MpvSourceNative.setPlaying(source, false)
                check(MpvSourceNative.seek(source, position))
                generation++; check(runtime.reset(generation))
                MpvSourceNative.setPlaying(source, true)
                repeat(4) {
                    phase = "seek_${index}_${position}_frame_$it"
                    val pair = frame(source)
                    val epoch = pair.getLong("source_epoch")
                    if (it == 0) { check(epoch > previousEpoch); previousEpoch = epoch }
                    check(epoch == previousEpoch)
                    phase = "seek_${index}_${position}_rvm_$it"
                    process(pair, "seek_${index}_$position")
                }
            }
            // Keep-open must retain the real final hardware frame for a late
            // consumer, then close without depending on a Godot draw callback.
            phase = "wait_eof"
            var terminal: JSONObject? = null
            until(10_000) {
                val status = JSONObject(MpvSourceNative.status(source))
                check(!status.getBoolean("render_failed") && status.getString("state") != "failed") { status.toString() }
                if (status.getString("state") == "ended" && status.getBoolean("eof_source_resolved")) terminal = status.getJSONObject("eof_source_ticket")
                terminal != null
            }
            report.put("resolved_eof_source", terminal)
            phase = "retained_eof_pair"
            // Core EOF can precede the last GPU fence. A completed penultimate
            // image is a valid normal acquire, but is not evidence of final-frame
            // retention. Drain it and require the native resolved source identity.
            // Only the host's independent decoder knows the fixture's final PTS.
            val eofDiscarded = JSONArray()
            var finalPair: JSONObject? = null
            until(15_000) {
                val encoded = MpvSourceNative.acquire(source)
                if (encoded.isNotEmpty()) {
                    val pair = JSONObject(encoded)
                    if (listOf("source_epoch", "frame_id", "pts_us").all { pair.getLong(it) == terminal!!.getLong(it) }) finalPair = pair
                    else {
                        eofDiscarded.put(pair)
                        check(MpvSourceNative.release(source, pair.getLong("producer_token")))
                    }
                }
                finalPair != null
            }
            report.put("eof_discarded_before_final_fence", eofDiscarded)
            // Reproduce the production race: every release fence has signalled,
            // but the owner has not yet observed retired(). Capture must keep
            // all three old tokens intact until that explicit acknowledgement.
            phase = "retirement_ack_before_reuse"
            producerHeld.add(finalPair!!.getLong("producer_token"))
            val retirementTokens = (0 until 3).map {
                val token = RenderBridgeNative.captureTexture(bridge, finalPair!!.getInt("color_texture_id"), false)
                check(token > 0); colorHeld.add(token)
                until(5000) { RenderBridgeNative.ready(bridge, token) }
                token
            }
            retirementTokens.forEach { RenderBridgeNative.retire(bridge, it) }
            android.opengl.GLES30.glFinish()
            check(android.opengl.GLES30.glGetError() == android.opengl.GLES30.GL_NO_ERROR)
            val blocked = RenderBridgeNative.captureTexture(bridge, finalPair!!.getInt("color_texture_id"), false)
            if (blocked > 0) colorHeld.add(blocked)
            check(blocked == 0L) { "Capture reused a slot before retirement acknowledgement" }
            retirementTokens.forEach {
                check(RenderBridgeNative.retired(bridge, it)); colorHeld.remove(it)
            }
            val reused = RenderBridgeNative.captureTexture(bridge, finalPair!!.getInt("color_texture_id"), false)
            check(reused > 0 && reused !in retirementTokens); colorHeld.add(reused)
            until(5000) { RenderBridgeNative.ready(bridge, reused) }
            RenderBridgeNative.retire(bridge, reused)
            until(5000) { RenderBridgeNative.retired(bridge, reused) }; colorHeld.remove(reused)
            report.put("retirement_ack_checks", JSONObject().put("tokens", JSONArray(retirementTokens))
                .put("fences_finished", true).put("capture_before_ack", blocked).put("all_tokens_acknowledged", true)
                .put("capture_after_ack", reused).put("reused_slot_retired", true))
            process(finalPair!!, "eof_retained")
            report.put("native_status", JSONObject(MpvSourceNative.status(source)))
            phase = "restart_after_eof_seek"
            MpvSourceNative.setPlaying(source, false)
            check(MpvSourceNative.seek(source, 0))
            val invalidated = JSONObject(MpvSourceNative.status(source))
            endGate!!.observe(null)
            report.put("seek_invalidated_eof", !invalidated.getBoolean("eof_source_resolved") && invalidated.isNull("eof_source_ticket") && !endGate!!.complete())
            check(report.getBoolean("seek_invalidated_eof"))
            generation++; check(runtime.reset(generation))
            phase = "restart_after_eof_pair"
            val restarted = frame(source)
            check(restarted.getLong("source_epoch") > previousEpoch && restarted.getLong("pts_us") == 0L)
            process(restarted, "restart_after_eof")
            report.put("restart_native_status", JSONObject(MpvSourceNative.status(source))).put("records", records)
                .put("state", "passed_native_checks")
        } catch (failure: Throwable) {
            report.put("state", "failed").put("error", failure.javaClass.simpleName+": "+failure.message)
                .put("records", records).put("bounded_slots", bounds).put("failure_phase", phase)
            if (source > 0) try { report.put("failure_native_status", JSONObject(MpvSourceNative.status(source))) } catch (_: Throwable) {}
        } finally {
            var cleanupFailure: Throwable? = null
            try {
                runtime?.close()
                if (bridge > 0) {
                    colorHeld.forEach { token -> RenderBridgeNative.retire(bridge, token); until(5000) { RenderBridgeNative.retired(bridge, token) } }
                    RenderBridgeNative.close(bridge)
                }
                if (source > 0) {
                    producerHeld.forEach { MpvSourceNative.release(source, it) }
                    MpvSourceNative.requestClose(source)
                    until(15_000) { JSONObject(MpvSourceNative.status(source)).getBoolean("done") }
                    val closed = JSONObject(MpvSourceNative.status(source))
                    report.put("closed_native_status", closed)
                    check(MpvSourceNative.close(source, false)); source = 0
                    check(!closed.getBoolean("render_failed") && closed.getString("error").isEmpty() &&
                        closed.getString("render_error").isEmpty() && closed.getInt("held_slots") == 0 &&
                        closed.getInt("retiring_slots") == 0) { "Native teardown did not complete cleanly: $closed" }
                }
            } catch (failure: Throwable) {
                cleanupFailure = failure
                if (source > 0) try { MpvSourceNative.close(source, true) } catch (_: Throwable) {}
            }
            try { check(owner.close()) { "Consumer EGL teardown failed" } }
            catch (failure: Throwable) { if (cleanupFailure == null) cleanupFailure = failure }
            if (cleanupFailure == null) report.put("resources_closed", true)
            else report.put("state", "failed").put("cleanup_error", cleanupFailure.message).put("resources_closed", false)
            val directory = File(context.filesDir, "diagnostics").apply { mkdirs() }
            val temporary = File.createTempFile("mpv-shared-", ".tmp", directory)
            try { temporary.writeText(report.toString()); check(temporary.renameTo(File(directory, "mpv_shared_$id.json"))) }
            finally { temporary.delete() }
        }
    }
}
