package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class RoiControllerTest {
    private val size = 320
    private val full = floatArrayOf(0f, 0f, 1f, 1f) // square eye, square model

    /** Model-size Alpha with 1.0 inside the eye-UV box seen through [rect]. */
    private fun alpha(rect: FloatArray, vararg boxes: DoubleArray): ByteBuffer {
        val b = ByteBuffer.allocateDirect(size * size * 4).order(ByteOrder.LITTLE_ENDIAN)
        for (y in 0 until size) for (x in 0 until size) {
            val ex = ((x + .5) / size - rect[0]) / rect[2]; val ey = ((y + .5) / size - rect[1]) / rect[3]
            val on = boxes.any { ex >= it[0] && ex < it[2] && ey >= it[1] && ey < it[3] }
            b.putFloat((y * size + x) * 4, if (on) 1f else 0f)
        }
        return b
    }
    private fun eye(plan: RoiController.Plan) = doubleArrayOf(-plan.rect[0] / plan.rect[2].toDouble(),
        -plan.rect[1] / plan.rect[3].toDouble(), 1 / plan.rect[2].toDouble(), 1 / plan.rect[3].toDouble())
    private fun feed(roi: RoiController, n: Int, vararg people: DoubleArray) {
        repeat(n) {
            val p = roi.plan()
            val a = alpha(p.rect, *people)
            roi.onMain(p.windowId, p.rect, a, a)
        }
    }

    @Test fun startsFullAndZoomsOnlyAfterTwoAgreeingChecksAndDwell() {
        val roi = RoiController(full, size, size, 4096, 4096)
        val person = doubleArrayOf(.45, .45, .55, .6)
        assertFalse(roi.plan().zoomed)
        feed(roi, 29, person)
        assertFalse("dwell of 30 results before the first switch", roi.plan().zoomed)
        feed(roi, 1, person)
        val plan = roi.plan()
        assertTrue(plan.zoomed)
        val w = eye(plan)
        assertTrue("window contains the person", w[0] <= .45 && w[1] <= .45 && w[0] + w[2] >= .55 && w[1] + w[3] >= .6)
        assertTrue("zoom gives at least 1.6x", 1 / w[2] >= 1.6)
        assertEquals("square window for a square model and eye", w[2], w[3], 1e-9)
        assertTrue("scout requested right after zooming", plan.scout)
    }

    @Test fun largePeopleStayFull() {
        val roi = RoiController(full, size, size, 4096, 4096)
        feed(roi, 100, doubleArrayOf(.1, .1, .9, .95))
        assertFalse(roi.plan().zoomed)
        assertEquals(0L, roi.switches)
    }

    @Test fun personAtBorderWidensAndStaleResultsAreIgnored() {
        val roi = RoiController(full, size, size, 4096, 4096)
        val person = doubleArrayOf(.45, .45, .55, .6)
        feed(roi, 30, person)
        val zoomed = roi.plan()
        val w = eye(zoomed)
        // Person walks to the window edge.
        val moved = doubleArrayOf(w[0] + w[2] - .03, .5, w[0] + w[2] + .05, .6)
        feed(roi, 1, moved)
        val widened = roi.plan()
        assertNotEquals(zoomed.windowId, widened.windowId)
        // The window only sees inside itself, so it grows step by step until the person fits.
        feed(roi, 5, moved)
        val settled = roi.plan()
        val v = eye(settled)
        assertTrue(!settled.zoomed || (v[0] + v[2] >= moved[2] && v[0] <= moved[0]))
        // A late result from the old window must not move the new one.
        val stale = alpha(zoomed.rect, doubleArrayOf(0.0, 0.0, .02, .02))
        roi.onMain(zoomed.windowId, zoomed.rect, stale, stale)
        assertEquals(settled.windowId, roi.plan().windowId)
    }

    @Test fun scoutFindsSolidPersonOutsideWindowButIgnoresSpecks() {
        val roi = RoiController(full, size, size, 4096, 4096)
        feed(roi, 30, doubleArrayOf(.45, .45, .55, .6))
        val zoomed = roi.plan()
        assertTrue(zoomed.scout)
        val speck = alpha(full, doubleArrayOf(.05, .05, .06, .06))
        roi.onScout(zoomed.windowId, speck, speck)
        assertEquals("a speck outside does not widen", zoomed.windowId, roi.plan().windowId)
        assertFalse("scout satisfied", roi.plan().scout)
        val newcomer = alpha(full, doubleArrayOf(.45, .45, .55, .6), doubleArrayOf(.1, .4, .2, .65))
        roi.onScout(zoomed.windowId, newcomer, newcomer)
        val after = roi.plan()
        assertNotEquals(zoomed.windowId, after.windowId)
        if (after.zoomed) { val v = eye(after); assertTrue(v[0] <= .1) }
    }

    @Test fun letterboxedFullRectRoundTrips() {
        // Eye 1920x2160 letterboxed into a square model: content occupies x in [.0556, .9444].
        val rect = floatArrayOf(.0556f, 0f, .8889f, 1f)
        val roi = RoiController(rect, size, size, 1920, 2160)
        val p = roi.plan()
        assertArrayEquals(rect, p.rect, 1e-6f)
        feed(roi, 30, doubleArrayOf(.45, .5, .55, .62))
        val z = roi.plan()
        assertTrue(z.zoomed)
        val w = eye(z)
        // Window pixels keep the model aspect: w*1920 == h*2160.
        assertEquals(w[2] * 1920, w[3] * 2160, 1e-3) // rect is stored as float
    }
}
