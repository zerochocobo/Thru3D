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
            assertTrue(background.promoteTo(2, foreground))
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

    @Test fun promotionJoinsQueuedConversionAndCancellationKeepsItsFileLeased() {
        val root = Files.createTempDirectory("vrpp-photo-depth-promotion").toFile()
        val work = mutableListOf<Runnable>()
        fun queuedBridge() = PhotoBridge({ null }, { it }, {}, postDepth = { task, _ -> work.add(task) }, emit = { _, _, _ -> })
        val foreground = queuedBridge(); val background = queuedBridge()
        try {
            val next = source(root, 8)
            assertTrue(background.adopt(8, next))
            assertTrue(background.depth(8, 1f, true))
            assertEquals(1, work.size)
            assertTrue(background.promoteTo(8, foreground))
            background.cancelDepth(); background.close()
            assertTrue(foreground.depth(8, 1f, true))
            assertEquals("Promotion must join the original task", 1, work.size)
            foreground.cancel(8)
            assertTrue("Cancelled work owns the source until it returns", next.isFile)
            assertTrue(foreground.cacheDirectories().contains(next.parentFile!!))
            work.single().run()
            work.clear()
            assertFalse(next.parentFile!!.exists())
        } finally {
            foreground.close(); background.close(); work.forEach { it.run() }; root.deleteRecursively()
        }
    }

    @Test fun strengthUpdatesJoinWorkAndClosedPromotionCannotDeleteAnActiveSource() {
        val root = Files.createTempDirectory("vrpp-photo-depth-strength").toFile()
        val work = mutableListOf<Runnable>()
        val foreground = PhotoBridge({ null }, { it }, {}, postDepth = { task, _ -> work.add(task) }, emit = { _, _, _ -> })
        val closed = bridge().apply { close() }
        try {
            val first = source(root, 9)
            assertTrue(foreground.adopt(9, first))
            assertTrue(foreground.depth(9, 1f, true))
            assertFalse(foreground.promoteTo(9, closed))
            assertTrue(foreground.depth(9, .75f, true))
            assertEquals("Changing strength must not restart depth inference", 1, work.size)
            foreground.cancel(9)
            work[0].run(); assertFalse(first.exists())
            work.clear()
        } finally { foreground.close(); closed.close(); work.forEach { it.run() }; root.deleteRecursively() }
    }

    @Test fun backgroundCancellationDoesNotCancelForegroundWorkOnTheSameBridge() {
        val root = Files.createTempDirectory("vrpp-photo-depth-priority").toFile()
        val work = mutableListOf<Runnable>()
        val priorities = mutableListOf<Boolean>()
        val foreground = PhotoBridge({ null }, { it }, {}, postDepth = { task, priority ->
            work.add(task); priorities.add(priority)
        }, emit = { _, _, _ -> })
        try {
            assertTrue(foreground.adopt(1, source(root, 1)))
            assertTrue(foreground.adopt(2, source(root, 2)))
            assertTrue(foreground.depth(1, 1f, true))
            assertTrue(foreground.depth(2, 1f, true, true))
            assertEquals(listOf(true, false), priorities)
            foreground.cancelBackgroundDepth()
            assertTrue(foreground.depth(1, .8f, true))
            assertEquals("Foreground work must still be joined", 2, work.size)
            assertTrue(foreground.depth(2, .8f, true, true))
            assertEquals("Cancelled background work needs a new request", 3, work.size)
            assertTrue(foreground.activate(2))
            assertTrue(foreground.depth(2, .8f, true))
            assertEquals("Activation promotes the existing background work", 3, work.size)
        } finally { foreground.close(); work.forEach { it.run() }; root.deleteRecursively() }
    }
}
