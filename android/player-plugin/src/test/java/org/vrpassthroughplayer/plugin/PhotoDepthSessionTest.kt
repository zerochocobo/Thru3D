package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class PhotoDepthSessionTest {
    @Test fun consecutivePhotosReuseOneSessionUntilReleased() {
        var created = 0L
        val destroyed = mutableListOf<Long>()
        val session = PhotoDepthSession { destroyed.add(it) }
        repeat(4) { photo ->
            session.use({ ++created }) { handle, reused ->
                assertEquals(1L, handle)
                assertEquals(photo != 0, reused)
            }
        }
        assertEquals(1L, created)
        session.close(); session.close()
        assertEquals(listOf(1L), destroyed)
        session.use({ ++created }) { handle, reused -> assertEquals(2L, handle); assertFalse(reused) }
        session.close()
        assertEquals(listOf(1L, 2L), destroyed)
    }

    @Test fun cancellationKeepsSessionButInferenceFailureRecreatesIt() {
        var created = 0L
        val destroyed = mutableListOf<Long>()
        val session = PhotoDepthSession { destroyed.add(it) }
        try { session.use({ ++created }) { _, _ -> throw InterruptedException() } }
        catch (_: InterruptedException) { }
        session.use({ ++created }) { handle, reused -> assertEquals(1L, handle); assertTrue(reused) }
        try { session.use({ ++created }) { _, _ -> error("GPU failure") } }
        catch (_: IllegalStateException) { }
        assertEquals(listOf(1L), destroyed)
        session.use({ ++created }) { handle, reused -> assertEquals(2L, handle); assertFalse(reused) }
        session.close()
    }

    @Test fun failedCreationLeavesNoReusableHandle() {
        val session = PhotoDepthSession { fail("No handle was created") }
        try { session.use({ 0L }) { _, _ -> fail("Invalid handle") }; fail("Creation must fail") }
        catch (_: IllegalArgumentException) { }
        session.close()
    }
}
