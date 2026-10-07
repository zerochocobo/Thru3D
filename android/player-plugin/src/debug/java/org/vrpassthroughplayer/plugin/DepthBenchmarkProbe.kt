package org.vrpassthroughplayer.plugin

import android.content.Context
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean

/** Debug: time the 2D->3D depth model on the device GPU without the player or XR (the headset
 * need not be worn). Same native runtime, assets and kernel cache as playback, on [DepthWorker].
 * Writes files/diagnostics/depth_bench.json: compile time (cold or cached), placement, and the
 * wall time of each process() call (upload, inference, readback, near-map band). Outside an XR
 * session the runtime does not raise CPU/GPU levels, so clocks may differ from playback. */
internal object DepthBenchmarkProbe {
    private val busy = AtomicBoolean(false)

    fun request(context: Context, runs: Int): Int {
        require(runs in 1..500)
        if (!busy.compareAndSet(false, true)) return -1
        val app = context.applicationContext
        DepthWorker.handler.post {
            val report = JSONObject().put("runs", runs).put("profile", DepthNative.PROFILE)
            try {
                check(DepthNative.unavailable == null) { "Native library unavailable: ${DepthNative.unavailable}" }
                val cache = DepthWarmup.cacheDirectory(app).absolutePath
                report.put("cache_ready_before", DepthWarmup.ready(app))
                val started = SystemClock.elapsedRealtime()
                val handle = DepthNative.create(app.assets, cache)
                report.put("create_ms", SystemClock.elapsedRealtime() - started).put("runtime", JSONObject(DepthNative.describe(handle)))
                try {
                    val (w, h) = DepthNative.PROFILE.split('x').map { it.toInt() }
                    // A smooth scene-like pattern in [0, 1]; the network's cost does not depend on content.
                    val rgb = ByteBuffer.allocateDirect(w * h * 3 * 4).order(ByteOrder.LITTLE_ENDIAN)
                    for (c in 0 until 3) for (y in 0 until h) for (x in 0 until w)
                        rgb.putFloat(((c * h + y) * w + x) * 4, (0.5f + 0.4f * kotlin.math.sin(x * 0.05f + y * 0.03f + c)).coerceIn(0f, 1f))
                    val near = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.LITTLE_ENDIAN)
                    repeat(5) { DepthNative.process(handle, rgb, near, false, 1) } // tuning and first-use costs
                    val wall = ArrayList<Double>()
                    val native = ArrayList<Double>()
                    repeat(runs) {
                        val t0 = System.nanoTime()
                        val out = JSONObject(DepthNative.process(handle, rgb, near, false, 1))
                        wall.add((System.nanoTime() - t0) / 1e6)
                        native.add(out.optDouble("depth_ms"))
                    }
                    val sorted = wall.sorted()
                    report.put("wall_ms", JSONArray(wall)).put("native_ms", JSONArray(native))
                        .put("median_ms", sorted[sorted.size / 2]).put("p90_ms", sorted[(sorted.size * 9) / 10])
                        .put("min_ms", sorted.first()).put("fps_from_median", 1000.0 / sorted[sorted.size / 2])
                    report.put("state", "ready")
                } finally { DepthNative.close(handle) }
            } catch (error: Throwable) {
                report.put("state", "failed").put("error", error.message ?: error.javaClass.simpleName)
            } finally {
                val directory = File(app.filesDir, "diagnostics").apply { mkdirs() }
                File(directory, "depth_bench.json").writeText(report.toString(), Charsets.UTF_8)
                busy.set(false)
            }
        }
        return 1
    }
}
