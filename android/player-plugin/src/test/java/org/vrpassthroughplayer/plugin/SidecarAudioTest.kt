package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class SidecarAudioTest {
    private val video = "4k2.com@sivr00434_8k_part1.mp4"
    // The SITEST folder layout produced by the clone-voice tool.
    private val folder = listOf(video, "4k2.com@sivr00434_8k_part1.si.duck.wav", "4k2.com@sivr00434_8k_part1.si.mix.json",
        "4k2.com@sivr00434_8k_part1.si.mix.m4a", "4k2.com@sivr00434_8k_part1.si.wav", "4k2.com@sivr00434_8k_part1.srt",
        "4k2.com@sivr00434_8k_part2.si.mix.m4a", "4k2.com@sivr00434_8k_part1.clone")

    @Test fun onlyThisVideosM4aCloneVoiceFirst() {
        val names = folder + listOf("4k2.com@sivr00434_8k_part1.commentary.M4A", "4k2.com@sivr00434_8k_part1.m4a")
        assertEquals(listOf("4k2.com@sivr00434_8k_part1.si.mix.m4a", "4k2.com@sivr00434_8k_part1.commentary.M4A",
            "4k2.com@sivr00434_8k_part1.m4a"), SidecarAudio.select(video, names))
    }
    @Test fun titlesNameTheTrack() {
        assertEquals(SidecarAudio.CLONE_TITLE, SidecarAudio.title(video, "4k2.com@sivr00434_8k_part1.si.mix.m4a"))
        assertEquals("commentary", SidecarAudio.title(video, "4k2.com@sivr00434_8k_part1.commentary.M4A"))
        assertEquals("M4A", SidecarAudio.title("a.mkv", "a.m4a"))
    }
    @Test fun otherFormatsAndNamelessVideosAddNothing() {
        assertTrue(SidecarAudio.select(video, folder.filter { !it.endsWith(".m4a") }).isEmpty())
        assertTrue(SidecarAudio.select(".mp4", listOf(".m4a", "x.m4a")).isEmpty())
        // Another video whose name merely starts the same way keeps its own tracks.
        assertTrue(SidecarAudio.select("part1.mp4", listOf("part10.si.mix.m4a", "part1_old.m4a")).isEmpty())
    }
}
