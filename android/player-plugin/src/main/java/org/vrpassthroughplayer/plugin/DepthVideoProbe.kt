package org.vrpassthroughplayer.plugin

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Realtime 2D->3D: every presented mono frame carries a near map in the pair's R8 mask (both
 * halves), sharing the color's immutable slot, fences and display gates with Alpha. The shader
 * shifts each eye's color sampling by the near map (flat SBS 3D, not VR).
 *
 * The video never waits for depth. Each frame is published at once with the latest near map;
 * whenever the model is idle, a copy of that frame's model input is sent to [DepthWorker], and its
 * result becomes the latest map (Quest 3, 252x140: ~52 ms, ~19 updates/s). Depth changes slowly
 * against the frame rate, so a map one or two frames old reads as the same scene.
 * Before the first result (cold compile) and for good if the model cannot run, frames show in 2D
 * (depth_ran=false) and the reason is reported in stats. */
internal class DepthVideoProbe(
    private val scope: MediaSessionGate.Scope,
    private val context: () -> Context?,
    private val release: (Long) -> Unit,
    private val ready: () -> Unit,
    private val completed: (JSONObject, ByteBuffer, ByteBuffer) -> Boolean,
) : AutoCloseable {
    private val worker = DepthWorker.handler
    private val lock = Any()
    private val gate = FramePairGate(scope).apply { setAlpha(true) }
    private var closed = false
    @Volatile private var handle = 0L // set on the depth worker once compiled
    @Volatile private var error = ""   // non-empty: depth cannot run, frames stay 2D
    // Latest finished map (one copy per eye half: the bridge's upload rejects aliased inputs) and the
    // frame it belongs to. Published maps are never written again.
    private var latest: Pair<ByteBuffer, ByteBuffer>? = null // lock
    private var latestFrame = -1L          // lock
    private var lastSubmitted = -1L        // lock: a backwards jump (seek, loop) drops the old scene's map
    private var busy = false               // lock: one inference at a time
    private var lastStartNs = 0L           // lock: start of the latest inference
    /** Minimum time between inference starts: the GPU left between them goes to decode and display. */
    private val intervalNs = debugIntervalMs() * 1_000_000L
    private var count = 0L
    private var lastInferred = -1L // depth worker only: source frame of the previous inference
    private var inferred = 0L
    private val dims = DepthNative.PROFILE.split('x').map { it.toInt() }
    @Volatile var processMs = 0.0; private set
    @Volatile private var stabilizeMs = 0.0 // CPU part of processMs (near-map stabilizer)
    @Volatile private var info = ""
    fun stats(): Map<String, Any> = mapOf("depth_process_ms_avg" to processMs, "depth_stabilize_ms_avg" to stabilizeMs, "depth_updates" to inferred,
        "depth_interval_ms" to intervalNs / 1_000_000L,
        "depth_runtime" to info, "depth_ready" to (handle > 0), "depth_error" to error)

    fun start() {
        worker.post {
            try {
                if (synchronized(lock) { closed }) return@post
                val host = context() ?: error("Depth activity unavailable")
                val created = DepthNative.create(host.assets, DepthWarmup.cacheDirectory(host).absolutePath)
                check(created > 0) { "Depth prepare failed" }
                val kept = synchronized(lock) { if (closed) false else { handle = created; true } }
                if (!kept) DepthNative.close(created) else { info = DepthNative.describe(created); ready() }
            } catch (failure: Throwable) {
                error = failure.message ?: failure.javaClass.simpleName
                android.util.Log.w("QuestDepth", "2D->3D unavailable, playing 2D: $error")
            }
        }
    }

    fun acceptsPair(pair: JSONObject): Boolean = synchronized(lock) { !closed && gate.accepts(identity(pair)) }
    fun presented(pair: JSONObject): Boolean = synchronized(lock) { !closed && gate.presented(identity(pair)) }
    private fun identity(pair: JSONObject) = FramePairGate.Identity(pair.getInt("session_id"), pair.getInt("logical_session_id"),
        pair.getInt("generation"), pair.getLong("frame_id"), pair.getLong("pts_us"), pair.getInt("format_revision"),
        pair.getLong("effect_revision"), pair.getLong("model_generation"), pair.getLong("slot_token"))

    /** The next frame's model input would be used: stage it (otherwise the bridge skips the readback). */
    fun wantsInput(): Boolean = synchronized(lock) {
        !closed && !busy && handle > 0L && System.nanoTime() - lastStartNs >= intervalNs
    }

    /** [rgb] is the bridge's staged mono input (float32 CHW), valid only during this call; null when
     * this frame was not staged for the model. */
    fun submit(ticket: DecodedFrameGate.Ticket, token: Long, rgb: ByteBuffer?, descriptor: JSONObject) {
        var near: Pair<ByteBuffer, ByteBuffer>
        var nearFrame: Long
        var input: ByteBuffer? = null
        val id = synchronized(lock) {
            val identity = gate.identify(ticket, token)
            if (closed || identity == null) null else {
                if (identity.frameId < lastSubmitted) { latest = null; latestFrame = -1L }
                lastSubmitted = identity.frameId
                if (rgb != null && !busy && handle > 0L) {
                    // Copy: the slot (and its staged input) is handed to the display below.
                    input = ByteBuffer.allocateDirect(rgb.capacity()).order(ByteOrder.LITTLE_ENDIAN)
                        .put(rgb.duplicate().apply { clear() }).apply { clear() }
                    busy = true; lastStartNs = System.nanoTime()
                }
                identity
            }
        }
        if (id == null) { release(token); return }
        synchronized(lock) { near = latest ?: FLAT; nearFrame = latestFrame }
        val ran = near !== FLAT
        val kernel = JSONObject().put("near_frame_id", nearFrame).put("frames_behind", if (ran) id.frameId - nearFrame else -1)
        if (!publish(id, descriptor.toString(), near, ran, kernel)) release(token)
        input?.let { copy -> worker.post { infer(copy, id.frameId) } }
    }

    /** True hands the color lease to the GL uploader. */
    private fun publish(id: FramePairGate.Identity, descriptor: String, near: Pair<ByteBuffer, ByteBuffer>, ran: Boolean,
                        kernel: JSONObject): Boolean {
        val result = JSONObject(descriptor).put("effect_revision", id.effectRevision)
            .put("session_id", id.decoderId).put("logical_session_id", id.logicalSessionId).put("generation", id.generation)
            .put("model_generation", id.modelGeneration).put("inference_ran", ran).put("depth_ran", ran)
            .put("pair_identity_verified", true).put("alpha_kind", "depth_near_map")
            .put("alpha_transport", "cpu").put("alpha_gpu_uploaded", false).put("pair_presented", false)
            .put("depth_kernel", kernel).put("depth_error", error)
        val accepted = synchronized(lock) {
            if (closed || !gate.accepts(id)) false else { count++; result.put("depth_pairs", count); true }
        }
        return accepted && completed(result, near.first, near.second)
    }

    private fun infer(rgb: ByteBuffer, frameId: Long) {
        try {
            val active = handle
            if (active <= 0L || synchronized(lock) { closed }) return
            val near = ByteBuffer.allocateDirect(dims[0] * dims[1] * 4).order(ByteOrder.LITTLE_ENDIAN)
            val started = System.nanoTime()
            val reset = synchronized(lock) { latest == null } || lastInferred < 0 || frameId <= lastInferred
            // The stabilizer's rates are per source frame: skipped frames count.
            val step = if (reset) 1 else (frameId - lastInferred).coerceIn(1L, 1000L).toInt()
            lastInferred = frameId
            val kernel = try {
                JSONObject(DepthNative.process(active, rgb, near, reset, step))
            } catch (failure: Throwable) {
                // A model that cannot run stays off for this session; the video goes on in 2D.
                error = failure.message ?: failure.javaClass.simpleName
                android.util.Log.w("QuestDepth", "2D->3D inference failed, playing 2D: $error")
                synchronized(lock) { handle = 0L; latest = null }
                DepthNative.close(active)
                return
            }
            processMs = processMs * 0.9 + (System.nanoTime() - started) / 1e6 * 0.1
            stabilizeMs = stabilizeMs * 0.9 + kernel.optDouble("stabilize_ms", 0.0) * 0.1
            if (kernel.optString("state") != "ready") return
            synchronized(lock) {
                // A seek while this ran: its scene is gone.
                if (!closed && frameId <= lastSubmitted && (latestFrame < 0 || frameId >= latestFrame)) {
                    // Second plane: the source frame's luminance, so the bridge can tell where the
                    // picture has moved since this map (its stale-edge attenuation).
                    val luma = ByteBuffer.allocateDirect(near.capacity()).order(ByteOrder.LITTLE_ENDIAN)
                    val plane = near.capacity() / 4
                    for (i in 0 until plane)
                        luma.putFloat(i * 4, (rgb.getFloat(i * 4) + rgb.getFloat((plane + i) * 4) + rgb.getFloat((2 * plane + i) * 4)) / 3f)
                    latest = near to luma; latestFrame = frameId; inferred++
                }
            }
        } finally {
            synchronized(lock) { busy = false }
        }
    }

    override fun close() {
        val previous: Long
        synchronized(lock) {
            if (closed) return
            closed = true; gate.close()
            previous = handle; handle = 0; latest = null
        }
        // The worker serializes this after any in-flight process of the same handle.
        if (previous > 0) worker.post { DepthNative.close(previous) }
    }

    companion object {
        /** Default gap between depth starts. Debug builds: adb shell setprop debug.vrpp.depth.interval_ms N. */
        // 0: start the next inference as soon as the last ends. At ~75 ms per inference the 1080p
        // display rate is unchanged (58.8/30.0 fps) while depth updates rise ~30% (Quest 3).
        private const val INTERVAL_MS = 0L
        private fun debugIntervalMs(): Long {
            if (!BuildConfig.DEBUG) return INTERVAL_MS
            return try {
                val value = Class.forName("android.os.SystemProperties").getMethod("get", String::class.java)
                    .invoke(null, "debug.vrpp.depth.interval_ms") as String
                value.toLongOrNull()?.coerceIn(0L, 2000L) ?: INTERVAL_MS
            } catch (_: Throwable) { INTERVAL_MS }
        }
        /** Pass-through mask: never written, so every 2D pair can share it (two distinct planes). */
        private val FLAT: Pair<ByteBuffer, ByteBuffer> by lazy {
            fun plane() = ByteBuffer.allocateDirect(DepthNative.PROFILE.split('x').map { it.toInt() }.let { it[0] * it[1] * 4 })
                .order(ByteOrder.LITTLE_ENDIAN)
            plane() to plane()
        }
    }
}

/** The depth model's own thread: compiles, warms and runs it. Kept for the process lifetime like
 * the RVM workers (one OpenCL/OpenMP root, never re-created). */
internal object DepthWorker {
    val handler: Handler by lazy { Handler(HandlerThread("QuestDepth").apply { start() }.looper) }
}

/** First use compiles and tunes the depth model's OpenCL kernels; do it before anyone asks for 3D. */
internal object DepthWarmup {
    fun cacheDirectory(context: Context) = File(context.cacheDir, "depth-mnn").apply { mkdirs() }

    fun ready(context: Context): Boolean = DepthNative.unavailable == null &&
        File(DepthNative.cachePath(context.assets, cacheDirectory(context).absolutePath)).length() > 4096

    /** Runs on [DepthWorker], so a session that starts meanwhile waits for this compile and then
     * opens from the cache instead of compiling a second time. */
    fun schedule(context: Context, report: (JSONObject) -> Unit) {
        if (DepthNative.unavailable != null) return
        val app = context.applicationContext
        DepthWorker.handler.post {
            val base = JSONObject().put("profile_key", "depth").put("model", "depth")
            try {
                val keep = File(DepthNative.cachePath(app.assets, cacheDirectory(app).absolutePath))
                cacheDirectory(app).listFiles { file -> file != keep }?.forEach { it.delete() }
                if (ready(app)) { report(base.put("state", "cached")); return@post }
                report(JSONObject(base.toString()).put("state", "warming"))
                val started = System.nanoTime()
                val handle = DepthNative.create(app.assets, cacheDirectory(app).absolutePath)
                val described = JSONObject(DepthNative.describe(handle))
                DepthNative.close(handle)
                report(described.put("profile_key", "depth").put("model", "depth").put("state", "ready")
                    .put("compile_ms", (System.nanoTime() - started) / 1_000_000))
            } catch (error: Throwable) {
                android.util.Log.w("QuestDepth", "Depth warmup failed: ${error.message}")
                report(base.put("state", "failed").put("message", error.message))
            }
        }
    }
}
