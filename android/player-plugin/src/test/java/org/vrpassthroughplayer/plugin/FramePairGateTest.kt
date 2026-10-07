package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class FramePairGateTest {
    private val scope = MediaSessionGate.Scope(7, 3, 2)
    private fun ticket(frame: Long = 10, pts: Long = 1000, revision: Int = 1) =
        DecodedFrameGate.Ticket(scope, frame, pts, revision, 1)

    @Test fun runtimeMustMatchSourceAndModelEpoch() {
        val gate = FramePairGate(scope)
        val id = gate.identify(ticket(), 42)!!
        assertTrue(gate.matchesRuntime(id, 3, 1, 10, 1000))
        assertFalse(gate.matchesRuntime(id, 7, 1, 10, 1000))
        assertFalse(gate.matchesRuntime(id, 3, 2, 10, 1000))
        assertFalse(gate.matchesRuntime(id, 3, 1, 11, 1000))
        assertFalse(gate.matchesRuntime(id, 3, 1, 10, 1001))
        assertNull(gate.identify(ticket().copy(scope = MediaSessionGate.Scope(6, 3, 1)), 42))
    }
    @Test fun modeChangeRejectsInFlightButCanProcessPausedColor() {
        val gate = FramePairGate(scope)
        val normal = gate.identify(ticket(), 42)!!
        assertTrue(gate.presented(normal))
        assertEquals(2L, gate.setAlpha(true))
        assertFalse(gate.accepts(normal))
        val masked = gate.identify(ticket(), 43)!!
        assertEquals(normal.frameId, masked.frameId)
        assertEquals(normal.generation, masked.generation)
        assertEquals(2L, masked.modelGeneration)
        assertTrue(gate.presented(masked))
        assertEquals(2L, gate.setAlpha(true))
        gate.setAlpha(false)
        assertFalse(gate.accepts(masked))
    }
    @Test fun formatChangeAndCloseRejectCompletion() {
        val gate = FramePairGate(scope)
        val old = gate.identify(ticket(), 42)!!
        gate.setFormat(2)
        assertFalse(gate.accepts(old))
        assertNull(gate.identify(ticket(), 43))
        val next = gate.identify(ticket(revision = 2), 43)!!
        assertTrue(gate.accepts(next))
        gate.close()
        assertFalse(gate.presented(next))
        assertNull(gate.identify(ticket(revision = 2), 44))
    }
    @Test fun olderCompletedPairCannotMovePresentationBackwards() {
        val gate = FramePairGate(scope)
        val old = gate.identify(ticket(), 42)!!
        val newer = gate.identify(ticket(12, 1200), 43)!!
        assertTrue(gate.presented(newer))
        assertFalse(gate.presented(old))
        assertFalse(gate.accepts(newer.copy(ptsUs = 1100)))
    }
}
