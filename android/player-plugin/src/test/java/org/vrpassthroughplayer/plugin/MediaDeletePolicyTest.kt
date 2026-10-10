package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class MediaDeletePolicyTest {
    @Test fun rejectsEscapesRootsDirectoriesAndNonMedia() {
        val root = Files.createTempDirectory("media-delete-policy").toFile()
        try {
            val file = root.resolve("video.mp4").apply { writeText("fixture") }
            assertEquals(file, MediaDeletePolicy.local(file, listOf(root)))
            assertTrue(MediaDeletePolicy.regular(file))
            assertThrows(IllegalArgumentException::class.java) { MediaDeletePolicy.local(file, listOf(root.resolve("other"))) }
            assertThrows(IllegalArgumentException::class.java) { MediaDeletePolicy.local(root, listOf(root)) }
            assertThrows(IllegalArgumentException::class.java) { MediaDeletePolicy.local(root.resolve("../escape.mp4"), listOf(root)) }
            assertThrows(IllegalArgumentException::class.java) { MediaDeletePolicy.local(root.resolve("subtitle.srt"), listOf(root)) }
            val folder = root.resolve("folder.mp4").apply { mkdir() }
            assertFalse(MediaDeletePolicy.regular(folder))
            MediaDeletePolicy.unchanged(7, 1, 7, 1)
            assertThrows(IllegalStateException::class.java) { MediaDeletePolicy.unchanged(8, 1, 7, 1) }
            assertThrows(IllegalStateException::class.java) { MediaDeletePolicy.unchanged(7, 2, 7, 1) }
        } finally { root.listFiles()?.forEach { it.delete() }; root.delete() }
    }
    @Test fun rejectsSmbShareAndDangerousPaths() {
        assertEquals("Video/旅行.mp4", MediaDeletePolicy.smbPath("Video/旅行.mp4"))
        for (path in listOf("Video", "Video/../other.mp4", "Video//a.mp4", "Video/a\\b.mp4", "Video/a?.mp4", "Video/a.srt", "Video/a%2f.mp4"))
            assertThrows(IllegalArgumentException::class.java) { MediaDeletePolicy.smbPath(path) }
    }
}
