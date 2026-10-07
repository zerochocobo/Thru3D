package org.vrpassthroughplayer.plugin

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.min

/** Chooses where in each eye the fixed-size RVM input looks (validated offline in
 * benchmarks/rvm_layer_profile/roi_sim.py, "single_320x320").
 *
 * FULL: the whole eye (letterboxed by the bridge). ZOOM: a window around the people,
 * same pixel aspect as the model input, used once two consecutive checks agree that
 * it gives >= [minGain] x density. In ZOOM a full-eye scout with its own recurrent
 * state runs every [scoutPeriod] results; a solid person outside the window, or
 * people touching the window border, widens it (or returns to FULL).
 *
 * Coordinates are eye UV in [0, 1]. A rect maps eye UV to model UV:
 * model = rect.xy + eye * rect.zw. Window ids change whenever the rect changes, so
 * the inference worker resets the display stream's states for the first input of a
 * new window even if intermediate inputs were dropped. Thread-safe.
 */
internal class RoiController(
    private val fullRect: FloatArray,
    private val inputWidth: Int,
    private val inputHeight: Int,
    private val eyeWidth: Int,
    private val eyeHeight: Int,
    private val minGain: Double = 1.6,
    private val checkPeriod: Int = 10,
    private val zoomCheckPeriod: Int = 6,
    private val scoutPeriod: Int = 60,
    private val dwell: Int = 30,
    private val margin: Double = 0.18,
    private val maxZoom: Double = 4.0,
) {
    data class Plan(val rect: FloatArray, val windowId: Long, val scout: Boolean, val zoomed: Boolean)
    data class Box(val x0: Double, val y0: Double, val x1: Double, val y1: Double) {
        fun union(o: Box?) = if (o == null) this else Box(min(x0, o.x0), min(y0, o.y0), max(x1, o.x1), max(y1, o.y1))
    }
    private data class Window(val x: Double, val y: Double, val w: Double, val h: Double) {
        fun rect() = floatArrayOf((-x / w).toFloat(), (-y / h).toFloat(), (1 / w).toFloat(), (1 / h).toFloat())
        fun contains(b: Box, inset: Double) = b.x0 >= x + w * inset && b.y0 >= y + h * inset &&
            b.x1 <= x + w * (1 - inset) && b.y1 <= y + h * (1 - inset)
    }

    private val full = Window(-fullRect[0] / fullRect[2].toDouble(), -fullRect[1] / fullRect[3].toDouble(),
        1 / fullRect[2].toDouble(), 1 / fullRect[3].toDouble())
    private var window = full
    private var windowId = 1L
    private var zoomed = false
    private var results = 0L
    private var since = 0L
    private var agree = 0
    private var scoutWanted = false
    private var scoutIssuedAt = -1L // capture count when the pending scout was staged
    private var captures = 0L
    private var decided = 0L // results claimed by the inference worker (analysis runs later, in order)
    private val plane = FloatArray(inputWidth * inputHeight)
    var switches = 0L; private set
    var scouts = 0L; private set
    private var analysisMs = 0.0 // exponential average of onMain/onScout work on the inference worker

    init {
        require(fullRect.size == 4 && fullRect.all { it.isFinite() } && fullRect[2] > 0 && fullRect[3] > 0)
        require(inputWidth > 0 && inputHeight > 0 && eyeWidth > 0 && eyeHeight > 0)
    }

    /** One plan per capture. A scout is staged once and re-staged only if its input was dropped. */
    @Synchronized fun plan(): Plan {
        captures++
        val scout = zoomed && scoutWanted && (scoutIssuedAt < 0 || captures - scoutIssuedAt > 15)
        if (scout) scoutIssuedAt = captures
        return Plan(window.rect(), windowId, scout, zoomed)
    }

    @Synchronized fun status(): Map<String, Any> = mapOf("roi_mode" to if (zoomed) "zoom" else "full",
        "roi_window" to listOf(window.x, window.y, window.w, window.h), "roi_window_id" to windowId,
        "roi_switches" to switches, "roi_scouts" to scouts, "roi_results" to results, "roi_analysis_ms" to analysisMs)

    /** Loads one eye's Alpha (0..1) into the model-size plane. */
    private fun interface Alpha { fun load(eye: Int, into: FloatArray) }
    private fun floats(left: ByteBuffer, right: ByteBuffer) = Alpha { eye, into ->
        (if (eye == 0) left else right).duplicate().order(ByteOrder.LITTLE_ENDIAN).apply { clear() }.asFloatBuffer().get(into)
    }
    /** Zero-copy planes: round(alpha*255) bytes, left plane then right. */
    private fun bytes(planes: ByteBuffer) = Alpha { eye, into ->
        val offset = eye * into.size
        for (i in into.indices) into[i] = (planes.get(offset + i).toInt() and 255) / 255f
    }

    /** Inference worker, once per display result of window [id]: does the next result need its Alpha?
     * FULL only checks every [checkPeriod] results and ZOOM every [zoomCheckPeriod]; the other
     * results skip the Alpha readback and are counted with [onMainSkipped]. */
    @Synchronized fun wantsAlpha(id: Long): Boolean {
        if (id != windowId) return false
        decided++
        return decided % (if (zoomed) zoomCheckPeriod else checkPeriod).toLong() == 0L
    }

    /** A display result whose Alpha was not read (see [wantsAlpha]). */
    @Synchronized fun onMainSkipped(id: Long) {
        if (id != windowId) return
        results++; since++
        if (zoomed && results % scoutPeriod == 0L && !scoutWanted) { scoutWanted = true; scoutIssuedAt = -1 }
    }

    /** Display-stream Alpha for a capture made with [rect]/[id]. */
    @Synchronized fun onMain(id: Long, rect: FloatArray, left: ByteBuffer, right: ByteBuffer) = onMain(id, rect, floats(left, right))
    @Synchronized fun onMainPlanes(id: Long, rect: FloatArray, planes: ByteBuffer) = onMain(id, rect, bytes(planes))
    @Synchronized fun onScout(id: Long, left: ByteBuffer, right: ByteBuffer) = onScout(id, floats(left, right))
    @Synchronized fun onScoutPlanes(id: Long, planes: ByteBuffer) = onScout(id, bytes(planes))

    private fun onMain(id: Long, rect: FloatArray, alpha: Alpha) {
        if (id != windowId) return // Result of a window already replaced.
        results++; since++
        val started = System.nanoTime()
        val people = peopleBox(rect, alpha, 0.3f, 0)
        analysisMs = analysisMs * 0.9 + (System.nanoTime() - started) / 1e6 * 0.1
        if (!zoomed) {
            if (results % checkPeriod != 0L) return
            val want = people?.let { fit(it) }
            agree = if (want != null && full.w / want.w >= minGain) agree + 1 else 0
            if (agree >= 2 && since >= dwell) switchTo(want!!, true)
            return
        }
        if (results % scoutPeriod == 0L && !scoutWanted) { scoutWanted = true; scoutIssuedAt = -1 }
        if (people != null && !window.contains(people, 0.04)) widen(people)
    }

    /** Full-eye scout Alpha (separate recurrent state) captured during ZOOM. */
    private fun onScout(id: Long, alpha: Alpha) {
        scoutWanted = false; scoutIssuedAt = -1
        scouts++
        if (!zoomed || id != windowId) return
        // Only a solid blob (not fringes such as the camera person's hands) widens the window.
        // The zero-copy scout infers the left eye only (both eyes show the same scene).
        val outside = peopleBox(fullRect, alpha, 0.5f, (0.0008 * inputWidth * inputHeight).toInt(), eyes = 1)
            ?.takeIf { !window.contains(it, 0.0) } ?: return
        widen(outside)
    }

    private fun widen(people: Box) {
        val inner = Box(window.x + window.w * .1, window.y + window.h * .1, window.x + window.w * .9, window.y + window.h * .9)
        val want = fit(people.union(inner))
        if (full.w / want.w < minGain) switchTo(full, false) else switchTo(want, true)
    }

    private fun switchTo(next: Window, zoom: Boolean) {
        window = next; zoomed = zoom; windowId++; switches++; decided = results
        since = 0; agree = 0; scoutWanted = zoom; scoutIssuedAt = -1
    }

    /** Window around [box] (eye UV) with margin, model pixel aspect, zoom <= maxZoom, kept inside the eye. */
    private fun fit(box: Box): Window {
        val bw = box.x1 - box.x0; val bh = box.y1 - box.y0
        val x0 = box.x0 - bw * margin; val x1 = box.x1 + bw * margin
        val y0 = box.y0 - bh * margin; val y1 = box.y1 + bh * margin
        // h (eye UV) for width w keeps the model's pixel aspect.
        val hPerW = eyeWidth.toDouble() * inputHeight / (eyeHeight.toDouble() * inputWidth)
        var w = max(x1 - x0, (y1 - y0) / hPerW)
        w = max(w, full.w / maxZoom)
        if (w >= full.w) return full
        val h = w * hPerW
        val cx = ((x0 + x1) / 2).coerceIn(w / 2, max(w / 2, 1 - w / 2))
        val cy = ((y0 + y1) / 2).coerceIn(h / 2, max(h / 2, 1 - h / 2))
        return Window(cx - w / 2, cy - h / 2, w, h)
    }

    /** Union over both eyes of alpha > threshold, in eye UV; optional minimum blob size (model pixels). */
    private fun peopleBox(rect: FloatArray, alpha: Alpha, threshold: Float, minBlob: Int, eyes: Int = 2): Box? {
        var box: Box? = null
        for (eye in 0 until eyes) {
            alpha.load(eye, plane)
            val b = if (minBlob > 0) largeBlobs(plane, threshold, minBlob) else bounds(plane, threshold)
            if (b != null) box = Box(toEyeX(rect, b[0]), toEyeY(rect, b[1]), toEyeX(rect, b[2] + 1), toEyeY(rect, b[3] + 1)).union(box)
        }
        return box
    }
    private fun toEyeX(rect: FloatArray, px: Int) = (px.toDouble() / inputWidth - rect[0]) / rect[2]
    private fun toEyeY(rect: FloatArray, py: Int) = (py.toDouble() / inputHeight - rect[1]) / rect[3]

    private fun bounds(values: FloatArray, threshold: Float): IntArray? {
        var x0 = Int.MAX_VALUE; var y0 = Int.MAX_VALUE; var x1 = -1; var y1 = -1
        for (y in 0 until inputHeight) for (x in 0 until inputWidth) {
            if (values[y * inputWidth + x] > threshold) {
                if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y
            }
        }
        return if (x1 < 0) null else intArrayOf(x0, y0, x1, y1)
    }

    /** Bounding box of all 4-connected components with at least [minArea] pixels above [threshold]. */
    private fun largeBlobs(values: FloatArray, threshold: Float, minArea: Int): IntArray? {
        val n = inputWidth * inputHeight
        val seen = BooleanArray(n)
        val stack = IntArray(n)
        var result: IntArray? = null
        for (start in 0 until n) {
            if (seen[start] || values[start] <= threshold) continue
            var top = 0; stack[top++] = start; seen[start] = true
            var area = 0; var x0 = Int.MAX_VALUE; var y0 = Int.MAX_VALUE; var x1 = -1; var y1 = -1
            while (top > 0) {
                val p = stack[--top]; area++
                val x = p % inputWidth; val y = p / inputWidth
                if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y
                for (q in intArrayOf(if (x > 0) p - 1 else -1, if (x < inputWidth - 1) p + 1 else -1,
                                     if (y > 0) p - inputWidth else -1, if (y < inputHeight - 1) p + inputWidth else -1)) {
                    if (q >= 0 && !seen[q] && values[q] > threshold) { seen[q] = true; stack[top++] = q }
                }
            }
            if (area >= minArea) result = result?.let { intArrayOf(min(it[0], x0), min(it[1], y0), max(it[2], x1), max(it[3], y1)) }
                ?: intArrayOf(x0, y0, x1, y1)
        }
        return result
    }
}
