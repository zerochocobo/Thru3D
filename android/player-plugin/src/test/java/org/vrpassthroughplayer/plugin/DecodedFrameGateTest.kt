package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class DecodedFrameGateTest {
    private fun gate() = DecodedFrameGate(MediaSessionGate.Scope(1, 1, 1))
    @Test fun oneReleaseUntilCopyFenceAndExactPts() {
        val gate = gate()
        val frame = gate.begin(0, 0, 1, 1)!!
        assertNull(gate.available())
        assertNull(gate.begin(1, 33333, 1, 1))
        assertTrue(gate.notifyAvailable())
        assertEquals(frame, gate.available())
        assertTrue(gate.verify(frame, 0))
        assertFalse(gate.idle())
        assertTrue(gate.complete(frame))
        assertFalse(gate.complete(frame))
        assertTrue(gate.idle())
        assertEquals(33333000L, gate.begin(1, 33333, 1, 1)!!.timestampNs)
    }
    @Test fun duplicateNotificationAndWrongTimestampFailClosed() {
        val gate = gate()
        val frame = gate.begin(4, 123456, 2, 3)!!
        gate.notifyAvailable()
        assertThrows(IllegalStateException::class.java) { gate.notifyAvailable() }
        assertThrows(IllegalStateException::class.java) { gate.verify(frame, frame.timestampNs + 1) }
        gate.close()
        assertFalse(gate.verify(frame, frame.timestampNs))
        assertFalse(gate.complete(frame))
        assertNull(gate.begin(5, 123457, 2, 3))
        assertFalse(gate.notifyAvailable())
    }
    @Test fun oldScopeAndTimestampOverflowCannotBeAccepted() {
        val gate = gate()
        val frame = gate.begin(0, 7, 1, 1)!!
        gate.notifyAvailable()
        assertFalse(gate.verify(frame.copy(scope=MediaSessionGate.Scope(2, 1, 2)), 7000))
        assertFalse(gate.complete(frame.copy(frameId=1)))
        assertTrue(gate.complete(frame))
        assertThrows(IllegalArgumentException::class.java) { gate.begin(0, 7, 1, 1) }
        assertThrows(IllegalArgumentException::class.java) { gate.begin(1, Long.MAX_VALUE, 1, 1) }
        assertThrows(IllegalArgumentException::class.java) { gate.begin(1, 8, 0, 1) }
    }
}
