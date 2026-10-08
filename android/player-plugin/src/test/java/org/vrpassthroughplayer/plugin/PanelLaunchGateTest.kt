package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class PanelLaunchGateTest {
    @Test fun requiresFreshOneTimeInAppRequestAndValidRecreation() {
        var now = 0L
        val gate = PanelLaunchGate { now }
        assertNull(gate.enter("cloud", null))
        gate.arm("cloud", "token")
        assertNull(gate.enter("servers", null))
        assertEquals("token", gate.enter("cloud", null))
        assertNull(gate.enter("cloud", null))
        assertNull(gate.enter("cloud", "forged"))
        assertEquals("token", gate.enter("cloud", "token"))
        gate.leave("cloud", "token")
        assertNull(gate.enter("cloud", "token"))
        gate.arm("cloud", "expired")
        now = 15_001
        assertNull(gate.enter("cloud", null))
        gate.arm("cloud", "cancelled")
        assertFalse(gate.cancelPending("cloud", "old-token"))
        assertTrue(gate.cancelPending("cloud", "cancelled"))
        assertFalse(gate.cancelPending("cloud", "cancelled"))
        gate.arm("cloud", "cancelled")
        gate.cancel("cloud")
        assertNull(gate.enter("cloud", null))
    }
}
