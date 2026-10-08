package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class PhotoStereoTest {
    @Test fun boundStereoAllocationWithoutUpscaling() {
        for ((w,h) in listOf(640 to 480,8192 to 8192,8192 to 4000,100 to 32000,32000 to 100)) {
            val (a,b)=PhotoStereo.size(w,h)
            assertTrue(a in 1..PhotoStereo.MAX_EDGE && b in 1..PhotoStereo.MAX_EDGE)
            assertTrue(a.toLong()*b<=PhotoStereo.MAX_PIXELS)
            assertTrue(a<=w && b<=h)
            assertTrue(kotlin.math.abs(a-b*w.toDouble()/h)<=1.01 || kotlin.math.abs(b-a*h.toDouble()/w)<=1.01)
        }
        assertEquals(640 to 480,PhotoStereo.size(640,480))
    }
}
