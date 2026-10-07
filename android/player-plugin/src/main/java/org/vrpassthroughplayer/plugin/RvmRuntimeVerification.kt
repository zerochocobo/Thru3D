package org.vrpassthroughplayer.plugin

import android.content.res.AssetManager
import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max

/** Device-only synthetic checks of the actual JNI boundary. No host pass is claimed. */
internal object RvmRuntimeVerification {
    fun run(assets: AssetManager, vulkan: Boolean, profile: String, cancelled: () -> Boolean,
            publish: (RvmRuntime?) -> Unit): JSONObject {
        check(!cancelled()) { "Runtime validation cancelled" }
        val capabilities = RvmRuntime.capabilities()
        val matching = (0 until capabilities.getJSONArray("profiles").length())
            .map { capabilities.getJSONArray("profiles").getJSONObject(it) }.single { it.getString("key") == profile }
        val alphaBytes = matching.getInt("width") * matching.getInt("height") * 4
        val prefix = if (profile == "256x144") "rvm/reference/" else "rvm/reference/$profile/"
        fun buffer(bytes: Int) = ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN)
        fun fixture(eye: String, frame: Int, output: String, bytes: Int): ByteBuffer {
            val data = assets.open("$prefix${eye}_$frame.$output.f32").use { it.readBytes() }
            check(data.size == bytes) { "Runtime oracle size mismatch" }
            return buffer(bytes).apply { put(data); clear() }
        }
        val left = Array(2) { fixture("left", it, "src", alphaBytes * 3) }
        val right = Array(2) { fixture("right", it, "src", alphaBytes * 3) }
        val expected = arrayOf(Array(2) { fixture("left", it, "pha", alphaBytes) },
                               Array(2) { fixture("right", it, "pha", alphaBytes) })
        val alpha = arrayOf(buffer(alphaBytes), buffer(alphaBytes))
        val checks = JSONArray()
        val frames = JSONArray()
        var maximum = 0.0
        // MNN runs the ratio=1 branch (no refiner) and may use FP16, so the ncnn FP32
        // oracle cannot gate it. State commit/reset is then checked against this
        // runtime's own initial-state frame 0, which must reproduce exactly.
        var baseline: Array<FloatArray>? = null
        var selfMaximum = 0.0
        var mnn = false
        fun compareInitial(eye: Int, offset: Int, actual: Float) {
            selfMaximum = max(selfMaximum, abs(actual.toDouble() - baseline!![eye][offset / 4]))
        }
        fun expectRejection(name: String, action: () -> Unit) {
            var rejected = false
            try { action() } catch (_: IllegalArgumentException) { rejected = true }
            catch (_: IllegalStateException) { rejected = true }
            check(rejected) { "Runtime accepted invalid request: $name" }
            checks.put(name)
        }
        val runtime = RvmRuntime.prepare(assets, vulkan, profile, 1, 1)
        publish(runtime)
        fun process(generation: Long, frame: Int) {
            check(!cancelled()) { "Runtime validation cancelled" }
            val report = runtime.process(generation, frame.toLong(), frame * 33333L, left[frame], right[frame], alpha[0], alpha[1])
            frames.put(report)
            mnn = report.optString("backend") == "MNN_OpenCL"
            val record = frame == 0 && baseline == null
            if (record) baseline = Array(2) { FloatArray(alphaBytes / 4) }
            check(report.getString("state") == "ready" && report.getLong("generation") == generation &&
                report.getLong("frame_id") == frame.toLong() && report.getLong("pts_us") == frame * 33333L &&
                report.getLong("session_id") == 1L && report.getString("profile_key") == profile)
            for (eye in 0..1) for (offset in 0 until alphaBytes step 4) {
                val actual = alpha[eye].getFloat(offset)
                check(actual.isFinite()) { "Runtime Alpha nonfinite" }
                maximum = max(maximum, abs(actual.toDouble() - expected[eye][frame].getFloat(offset)))
                if (record) baseline!![eye][offset / 4] = actual else if (frame == 0) compareInitial(eye, offset, actual)
            }
        }
        fun numericGate(message: String) {
            if (mnn) check(selfMaximum <= 1e-6) { "$message (MNN initial-state reproduction)" }
            else check(maximum <= 1e-4) { message }
        }
        try {
            process(1, 0)
            process(1, 1)
            checks.put("stereo_two_frame_oracle")
            expectRejection("duplicate_frame") { process(1, 1) }
            expectRejection("equal_generation_reset") { runtime.reset(1) }
            check(runtime.reset(2))
            expectRejection("stale_generation") { process(1, 0) }
            val original = right[0].getFloat(0)
            right[0].putFloat(0, Float.NaN)
            try { expectRejection("invalid_right_eye") { process(2, 0) } }
            finally { right[0].putFloat(0, original) }
            // Successful retry must be initial state in both eyes, despite left inference above.
            process(2, 0)
            checks.put("failed_stereo_no_state_commit")
            val aliasedAlpha = left[1].duplicate().apply { limit(alphaBytes) }.slice().order(ByteOrder.LITTLE_ENDIAN)
            expectRejection("overlapping_output") {
                runtime.process(2, 1, 33333, left[1], right[1], aliasedAlpha, alpha[1])
            }
            expectRejection("wrong_buffer_size") {
                runtime.process(2, 1, 33333, buffer(4), right[1], alpha[0], alpha[1])
            }
            process(2, 1)
            checks.put("rejected_buffer_no_state_commit")
            numericGate("Runtime Alpha exceeds FP32 oracle bound")
        } finally { runtime.close(); publish(null) }
        check(!cancelled()) { "Runtime validation cancelled" }
        runtime.close()
        expectRejection("closed_runtime") { process(2, 1) }
        // New runtime must allocate fresh states and registry identity after close.
        RvmRuntime.prepare(assets, vulkan, profile, 2, 1).use { fresh ->
            publish(fresh)
            try {
                check(!cancelled()) { "Runtime validation cancelled" }
                val report = fresh.process(1, 0, 0, left[0], right[0], alpha[0], alpha[1])
                check(report.getLong("session_id") == 2L)
                frames.put(report)
                for (eye in 0..1) for (offset in 0 until alphaBytes step 4) {
                    val actual = alpha[eye].getFloat(offset)
                    check(actual.isFinite())
                    maximum = max(maximum, abs(actual.toDouble() - expected[eye][0].getFloat(offset)))
                    compareInitial(eye, offset, actual)
                }
                numericGate("Fresh runtime differs from initial-state oracle")
            } finally { publish(null) }
        }
        checks.put("close_and_prepare_new_session")
        return JSONObject().put("state", "passed").put("checks", checks).put("alpha_max_abs", maximum)
            .put("backend", if (mnn) "MNN_OpenCL" else "ncnn")
            .put("alpha_oracle_gate", if (mnn) "not_applicable_ratio1_branch_see_mnn_sequence_test" else "fp32_1e-4")
            .put("initial_state_reproduction_max_abs", selfMaximum)
            .put("frame_reports", frames)
            .put("scope", "Device synthetic JNI boundary; no video, quality, thermal or concurrent cancellation test")
    }
}
