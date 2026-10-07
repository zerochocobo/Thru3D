package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class MpvEndGateTest {
    private val scope = MediaSessionGate.Scope(3, 2, 4)
    private val final = MpvEndGate.Source(7, 180, 5966667)
    private fun pair() = FramePairGate.Identity(3, 2, 4, 180, 5966667, 1, 2, 2, 9)
    @Test fun coreEofCannotCompleteWithoutExactDrawnAlpha() {
        val gate = MpvEndGate(scope, true)
        gate.observe(final); assertFalse(gate.complete())
        assertFalse(gate.postDraw(pair(), 7, false)); assertFalse(gate.complete())
        assertTrue(gate.postDraw(pair().copy(frameId=179, ptsUs=5933333), 7, true)); assertFalse(gate.complete())
        assertTrue(gate.postDraw(pair(), 7, true)); assertTrue(gate.complete()); assertEquals(9L, gate.completedSlot())
    }
    @Test fun invalidationAndWrongScopeCannotReuseOldCompletion() {
        val gate = MpvEndGate(scope, true)
        gate.observe(final); gate.postDraw(pair(), 7, true); assertTrue(gate.complete())
        gate.observe(null); assertFalse(gate.complete()); assertEquals(0L, gate.completedSlot())
        gate.observe(final.copy(epoch=8)); assertFalse(gate.complete())
        assertFalse(gate.postDraw(pair().copy(generation=5), 8, true)); assertFalse(gate.complete())
        assertFalse(gate.postDraw(pair().copy(decoderId=4), 8, true)); assertFalse(gate.complete())
        gate.postDraw(pair(), 8, true); assertTrue(gate.complete())
    }
    @Test fun finalPairMayDrawBeforeCoreResolvesEofAndNormalNeedsNoInference() {
        val gate = MpvEndGate(scope, false)
        assertTrue(gate.postDraw(pair(), 7, false)); assertFalse(gate.complete())
        gate.observe(final.copy(ptsUs=5966666)); assertFalse(gate.complete())
        gate.observe(final); assertTrue(gate.complete())
        gate.observe(final.copy(frameId=0)); assertFalse(gate.complete())
    }
}
