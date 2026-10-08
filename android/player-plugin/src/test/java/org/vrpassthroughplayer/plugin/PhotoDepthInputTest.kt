package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class PhotoDepthInputTest {
    @Test fun portraitUsesFullHeightAndLandscapeUsesFullWidth() {
        assertEquals(PhotoDepthInput.Content(76, 0, 366, 518), PhotoDepthInput.fit(1357, 1920))
        assertEquals(PhotoDepthInput.Content(0, 76, 518, 366), PhotoDepthInput.fit(1920, 1357))
        assertEquals(PhotoDepthInput.Content(0, 0, 518, 518), PhotoDepthInput.fit(8192, 8192))
    }
    @Test fun resolutionDoesNotChangeContentGeometry() {
        assertEquals(PhotoDepthInput.fit(1357,1920), PhotoDepthInput.fit(2714,3840))
        for ((w,h) in listOf(32768 to 1, 1 to 32768, 1 to 1, 7680 to 2160, 2160 to 7680)) {
            val r = PhotoDepthInput.fit(w,h)
            assertTrue(r.width >= 1 && r.height >= 1 && r.x >= 0 && r.y >= 0)
            assertTrue(r.x+r.width <= 518 && r.y+r.height <= 518)
            assertTrue(r.width == 518 || r.height == 518)
        }
    }
    @Test(expected = IllegalArgumentException::class) fun invalidDimensionsAreRejected() { PhotoDepthInput.fit(0,1920) }
}
