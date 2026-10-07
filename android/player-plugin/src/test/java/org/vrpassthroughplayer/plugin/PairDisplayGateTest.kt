package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class PairDisplayGateTest {
    private val scope = MediaSessionGate.Scope(3, 2, 4)
    private fun pair(token: Long, frame: Long = token) = FramePairGate.Identity(3, 2, 4, frame, frame*33333, 2, 2, 3, token)
    @Test fun replaceReadyKeepsExistingDisplayClaim() {
        val gate = PairDisplayGate(scope)
        assertNull(gate.offer(pair(1))); assertNotNull(gate.claim(1)); assertTrue(gate.acknowledge(1))
        assertNull(gate.offer(pair(2))); assertEquals(2L, gate.offer(pair(3)))
        assertTrue(gate.owns(1)); assertTrue(gate.owns(3)); assertFalse(gate.owns(2)); assertNull(gate.claim(2))
    }
    @Test fun queueOfTwoKeepsABurstInOrder() {
        val gate = PairDisplayGate(scope, depth = 2)
        assertNull(gate.offer(pair(1))); assertNull(gate.offer(pair(2)))
        assertEquals(1L, gate.readyToken()); assertNull(gate.claim(2)); assertNotNull(gate.claim(1))
        assertEquals(2L, gate.readyToken()); assertTrue(gate.acknowledge(1))
        assertNull(gate.offer(pair(3))); assertEquals(2L, gate.offer(pair(4))) // a third drops the oldest
        assertEquals(1L, gate.replacedCount); assertTrue(gate.owns(3)); assertTrue(gate.owns(4)); assertFalse(gate.owns(2))
        assertNotNull(gate.claim(3)); assertEquals(4L, gate.readyToken())
        assertEquals(4L, gate.close()); assertFalse(gate.owns(4)); assertTrue(gate.owns(3))
    }
    @Test fun closingWaitsForDetachAndNeverResurrectsClaims() {
        val gate = PairDisplayGate(scope)
        gate.offer(pair(1)); gate.claim(1); gate.acknowledge(1); gate.offer(pair(2))
        assertEquals(2L, gate.close()); assertEquals(1, gate.heldClaims()); assertTrue(gate.owns(1))
        assertEquals(3L, gate.offer(pair(3))); assertNull(gate.claim(3)); assertFalse(gate.acknowledge(1)); assertFalse(gate.drawn(1))
        assertTrue(gate.detach(1)); assertFalse(gate.detach(1)); assertEquals(0, gate.heldClaims())
    }
    @Test fun claimAndAckAreBoundedAndSingleUse() {
        val gate = PairDisplayGate(scope)
        for (token in 1L..2L) { gate.offer(pair(token)); assertNotNull(gate.claim(token)) }
        gate.offer(pair(3)); assertNull(gate.claim(3)); assertTrue(gate.acknowledge(2)); assertFalse(gate.acknowledge(2))
        assertFalse(gate.acknowledge(1)); assertTrue(gate.detach(1)); assertNotNull(gate.claim(3)); assertTrue(gate.acknowledge(3))
        assertEquals(3L, gate.claimCount); assertEquals(2L, gate.ackCount)
    }
    @Test fun rejectsWrongScopeAndBackwardPts() {
        val gate = PairDisplayGate(scope)
        assertEquals(1L, gate.offer(pair(1).copy(generation=3)))
        gate.offer(pair(2)); gate.claim(2); gate.acknowledge(2)
        assertEquals(3L, gate.offer(pair(3).copy(ptsUs=0))); assertEquals(4L, gate.offer(pair(4,1)))
    }
    @Test fun pinnedObserverSurvivesDetachAndClosingUntilExplicitRelease() {
        val gate = PairDisplayGate(scope)
        gate.offer(pair(1)); gate.claim(1)
        assertFalse(gate.pin(1)); assertTrue(gate.acknowledge(1)); assertTrue(gate.pin(1)); assertFalse(gate.pin(1))
        assertTrue(gate.detach(1)); assertTrue(gate.owns(1)); assertEquals(1, gate.heldClaims())
        gate.close(); assertFalse(gate.pin(1)); assertTrue(gate.owns(1)); assertTrue(gate.unpin(1))
        assertFalse(gate.owns(1)); assertEquals(0, gate.heldClaims()); assertFalse(gate.unpin(1))
    }
}
