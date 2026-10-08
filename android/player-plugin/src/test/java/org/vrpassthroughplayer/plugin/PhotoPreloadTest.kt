package org.vrpassthroughplayer.plugin

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class PhotoPreloadTest {
    private fun bridge() = PhotoBridge({ null }, { it }, {}, emit = { _, _, _ -> })
    private fun source(root: File, id: Int) = File(root, "$id/source").apply {
        parentFile!!.mkdirs(); writeText("photo $id")
    }

    @Test fun preloadPromotionTransfersFileOwnershipWithoutDeletingIt() {
        val root = Files.createTempDirectory("vrpp-photo-preload").toFile()
        val foreground = bridge(); val background = bridge()
        try {
            val first = source(root, 1); val next = source(root, 2)
            assertTrue(foreground.adopt(1, first))
            assertTrue(background.adopt(2, next))
            assertTrue(foreground.activate(1))
            assertEquals(next, background.take(2))
            assertTrue(foreground.adopt(2, next))
            background.release(2); background.close()
            assertTrue("Background cleanup must not unlink the displayed photo", next.isFile)
            assertTrue(foreground.activate(1))
            foreground.release(2)
            assertFalse(next.parentFile!!.exists())
            assertTrue(first.isFile)
        } finally { foreground.close(); background.close(); root.deleteRecursively() }
    }

    @Test fun cancelledAndClosedCacheEntriesCannotBeActivated() {
        val root = Files.createTempDirectory("vrpp-photo-cancel").toFile()
        val background = bridge()
        try {
            assertFalse(background.activate(99))
            val next = source(root, 3)
            assertTrue(background.adopt(3, next))
            background.cancel(3)
            assertFalse(background.activate(3)); assertFalse(next.exists())
            background.close()
            val fresh = source(root, 4)
            assertFalse(background.adopt(4, fresh))
            assertTrue("Failed adoption leaves source with its caller", fresh.exists())
        } finally { background.close(); root.deleteRecursively() }
    }
}
