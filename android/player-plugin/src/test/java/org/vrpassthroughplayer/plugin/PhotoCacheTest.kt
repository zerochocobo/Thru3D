package org.vrpassthroughplayer.plugin

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class PhotoCacheTest {
    private fun put(root: File, path: String, size: Int): File = File(root, path).apply {
        parentFile!!.mkdirs(); writeBytes(ByteArray(size))
    }

    @Test fun clearRemovesCrashLeftoversButPreservesLivePhotosAndOtherCaches() {
        val cache = Files.createTempDirectory("photo-cache-clear").toFile()
        try {
            put(cache, "photos/old/source", 11)
            put(cache, "photos/old/depth.bin", 13)
            put(cache, "photos/old/stereo-100.png", 17)
            put(cache, "photo-preloads/old/stereo-150.png", 19)
            val live = put(cache, "photo-preloads/live/stereo-100.png", 23)
            val transferring = put(cache, "photos/loading/source", 29)
            val model = put(cache, "photo-depth-mnn/program", 31)
            val cover = put(cache, "media-servers/cover.jpg", 37)
            assertEquals(6L to 112L, PhotoCache.usage(cache))
            PhotoCache.clear(cache, setOf(live.parentFile!!, transferring.parentFile!!))
            assertFalse(File(cache, "photos/old").exists())
            assertFalse(File(cache, "photo-preloads/old").exists())
            assertTrue(live.isFile); assertTrue(transferring.isFile)
            assertTrue(model.isFile); assertTrue(cover.isFile)
            assertEquals(2L to 52L, PhotoCache.usage(cache))
            PhotoCache.clear(cache, emptySet())
            assertEquals(0L to 0L, PhotoCache.usage(cache))
        } finally { cache.deleteRecursively() }
    }

    @Test fun missingDirectoriesAreAnEmptyCache() {
        val cache = Files.createTempDirectory("photo-cache-empty").toFile()
        try {
            assertEquals(0L to 0L, PhotoCache.usage(cache))
            PhotoCache.clear(cache, emptySet())
            assertFalse(File(cache, "photos").exists())
        } finally { cache.deleteRecursively() }
    }
}
