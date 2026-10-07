package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class MpvAudioFocusGateTest {
    @Test fun deniedRequestCannotStartAudioAndCanBeRetried() {
        val gate = MpvAudioFocusGate(); val first = gate.begin()!!
        assertFalse(gate.canPlay); gate.resolved(first, false); assertFalse(gate.canPlay)
        assertFalse(gate.changed(first, MpvAudioFocusGate.Change.GAIN))
        val retry = gate.begin(true)!!; gate.resolved(retry, true); assertTrue(gate.canPlay)
    }
    @Test fun transientLossWaitsForSameRequestGain() {
        val gate = MpvAudioFocusGate(); val token = gate.begin()!!; gate.resolved(token, true)
        assertTrue(gate.changed(token, MpvAudioFocusGate.Change.TRANSIENT_LOSS)); assertFalse(gate.canPlay)
        assertNull(gate.begin()); assertNull(gate.begin(true))
        assertTrue(gate.changed(token, MpvAudioFocusGate.Change.GAIN)); assertTrue(gate.canPlay)
    }
    @Test fun permanentLossRequiresNewPlayIntent() {
        val gate = MpvAudioFocusGate(); val token = gate.begin()!!; gate.resolved(token, true)
        assertTrue(gate.changed(token, MpvAudioFocusGate.Change.LOSS)); assertFalse(gate.canPlay)
        assertNull(gate.begin()); assertFalse(gate.changed(token, MpvAudioFocusGate.Change.GAIN))
        val fresh = gate.begin(true)!!; gate.resolved(fresh, true); assertTrue(gate.canPlay)
        assertFalse(gate.changed(token, MpvAudioFocusGate.Change.LOSS)); assertTrue(gate.canPlay)
    }
    @Test fun pauseCloseOrReplacementRejectsLateGrantAndGain() {
        val gate = MpvAudioFocusGate(); val old = gate.begin()!!; gate.clear()
        gate.resolved(old, true); assertFalse(gate.canPlay)
        val fresh = gate.begin()!!; gate.resolved(fresh, true)
        assertFalse(gate.changed(old, MpvAudioFocusGate.Change.GAIN)); assertTrue(gate.canPlay)
        gate.clear(); assertFalse(gate.changed(fresh, MpvAudioFocusGate.Change.GAIN)); assertFalse(gate.canPlay)
    }
}
