package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class PhotoDepthInputTest {
    @Test fun everyAspectFillsTheModelInput() {
        for ((w,h) in listOf(1357 to 1920, 1920 to 1357, 8192 to 8192, 32768 to 1, 1 to 32768, 1 to 1, 7680 to 2160, 2160 to 7680))
            assertEquals(PhotoDepthInput.Content(0, 0, 518, 518), PhotoDepthInput.fit(w,h))
    }
    @Test(expected = IllegalArgumentException::class) fun invalidDimensionsAreRejected() { PhotoDepthInput.fit(0,1920) }
}
