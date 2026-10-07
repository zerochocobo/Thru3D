package org.vrpassthroughplayer.plugin

import org.json.JSONObject

/** Cumulative per-frame times of the RVM worker, split by the extra work a frame carried:
 * an ROI Alpha readback, a scout inference, both, or neither. Histograms only grow, so a
 * benchmark takes the difference over its own window and computes exact percentiles there
 * (warm-up and ROI start-up frames stay out of the result).
 *
 * queue: submit -> worker starts it; service: worker start -> done (inference, readback,
 * scout, hand-off); latency: submit -> done. */
internal class FrameTimeline {
    private val service = Array(KINDS.size) { IntArray(BINS + 1) }
    private val queue = Array(KINDS.size) { IntArray(BINS + 1) }
    private val latency = Array(KINDS.size) { IntArray(BINS + 1) }

    @Synchronized fun record(readback: Boolean, scout: Boolean, queueMs: Double, serviceMs: Double, latencyMs: Double) {
        val kind = (if (readback) 1 else 0) + (if (scout) 2 else 0)
        service[kind][bin(serviceMs)]++
        queue[kind][bin(queueMs)]++
        latency[kind][bin(latencyMs)]++
    }

    /** Non-empty bins only, as "bin:count bin:count" strings: the status travels to Godot four
     * times a second and is parsed on its main thread, so it must stay small. */
    @Synchronized fun json(): JSONObject {
        val out = JSONObject().put("bin_ms", BIN_MS).put("bins", BINS + 1)
        for ((k, name) in KINDS.withIndex()) {
            out.put(name, JSONObject().put("service", sparse(service[k])).put("queue", sparse(queue[k]))
                .put("latency", sparse(latency[k])))
        }
        return out
    }

    private fun sparse(bins: IntArray) = buildString {
        for ((i, count) in bins.withIndex()) if (count > 0) { if (isNotEmpty()) append(' '); append(i).append(':').append(count) }
    }

    companion object {
        val KINDS = listOf("plain", "readback", "scout", "both")
        const val BIN_MS = 0.25
        const val BINS = 320 // 0 .. 80 ms; the last bin also holds everything slower

        fun bin(ms: Double) = (ms / BIN_MS).toInt().coerceIn(0, BINS)
    }
}
