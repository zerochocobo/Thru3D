package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class MediaSessionGateTest {
    @Test fun repeatedSeekPreservesLogicalSessionButInvalidatesEveryPreviousProducer() {
        val gate = MediaSessionGate()
        val original = gate.begin()
        val logical = gate.current(original)!!.logicalSessionId
        var current = original
        repeat(100) { index ->
            val previous = current
            val captured = gate.current(previous)!!
            current = gate.replace(previous)
            assertFalse(gate.accepts(previous))
            assertFalse(gate.invalidate(previous))
            assertEquals(logical, gate.current(current)!!.logicalSessionId)
            assertEquals(index + 2, gate.current(current)!!.generation)
            assertEquals(index + 1, captured.generation)
        }
        assertEquals(-1, gate.replace(original))
        val differentFile = gate.begin()
        assertNotEquals(logical, gate.current(differentFile)!!.logicalSessionId)
        assertEquals(1, gate.current(differentFile)!!.generation)
        assertFalse(gate.accepts(current))
    }

    @Test fun staleSeekCannotReplaceNewFileOrReviveClosedSession() {
        val gate = MediaSessionGate()
        val old = gate.begin()
        val active = gate.begin()
        assertEquals(-1, gate.replace(old))
        assertTrue(gate.accepts(active))
        gate.invalidate(active)
        assertEquals(-1, gate.replace(active))
        gate.shutdown()
        assertNull(gate.current(active))
    }

    @Test fun delayedCallbackAndCloseCannotAffectReplacement() {
        val gate = MediaSessionGate()
        val previous = gate.begin()
        val replacement = gate.begin()
        assertFalse(gate.accepts(previous))
        assertTrue(gate.accepts(replacement))
        assertFalse(gate.invalidate(previous))
        assertTrue(gate.accepts(replacement))
        assertTrue(gate.invalidate(replacement))
        assertFalse(gate.accepts(replacement))
    }

    @Test fun closePreventsQueuedWorkBeforeResourcesAreReleased() {
        val gate = MediaSessionGate()
        val session = gate.begin()
        assertTrue(gate.accepts(session))
        gate.shutdown()
        assertFalse(gate.accepts(session))
        assertFalse(gate.accepts(0))
        assertEquals(-1, gate.begin())
    }
}
