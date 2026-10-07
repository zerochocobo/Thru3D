package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class CloudPathsTest {
    @Test fun cloudNamesRoundTripWithoutDoubleDecoding() {
        for (name in listOf("中文 3D.mp4", "a#b?c%.mkv", "%2F literal.mp4", "a+b.mp4")) {
            val path = CloudPaths.child("/mount-id/folder", name)
            assertEquals(path, CloudPaths.path(CloudPaths.uri(path)))
        }
    }

    @Test fun rejectsTraversalCredentialsAndForeignSchemes() {
        for (uri in listOf("https://mount/a.mp4", "cloud://user:secret@mount/a", "cloud://mount:80/a",
            "cloud://mount/a?token=secret", "cloud://mount/../a", "cloud://mount/%2E%2E/a", "cloud://mount/a#x")) {
            assertThrows(IllegalArgumentException::class.java) { CloudPaths.path(uri) }
        }
        assertThrows(IllegalArgumentException::class.java) { CloudPaths.child("/mount", "../video.mp4") }
    }
}
