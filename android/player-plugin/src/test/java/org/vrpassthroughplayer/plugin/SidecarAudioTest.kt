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
    @Test fun cloudCloneMixIsFirstAndKeepsItsListedIdentity() {
        val files = listOf(CloudFile("part1.commentary.m4a", false, 10, "/movie/commentary-id"),
            CloudFile("part1.si.mix.m4a", false, 20, "/movie/clone-id"),
            CloudFile("part10.si.mix.m4a", false, 20, "/movie/other-id"),
            CloudFile("part1.srt", false, 10, "/movie/subtitle-id"),
            CloudFile("part1.si.wav", false, 10, "/movie/wav-id"),
            CloudFile("part1.folder.m4a", true, 20, "/movie/folder-id"))
        val client = object : CloudClient {
            override fun list(path: String): List<CloudFile> { assertEquals("/movie", path); return files }
            override fun page(path: String, offset: Int, refresh: Boolean): CloudPage = error("Use all pages")
            override fun find(path: String): CloudFile = error("Use listed identity")
            override fun resolve(file: CloudFile): CloudLink = error("Do not resolve unrelated files")
        }
        val ids = ArrayList<String>()
        val tracks = SidecarAudio.forCloud("/movie/part1.mp4", client) { file -> ids.add(file.id); "fixture-stream" }
        assertEquals(listOf("/movie/clone-id", "/movie/commentary-id"), ids)
        assertEquals(listOf(SidecarAudio.CLONE_TITLE, "commentary"), tracks.map { it.title })
        val available = SidecarAudio.forCloud("/movie/part1.mp4", client) { file ->
            if (file.id == "/movie/clone-id") throw CloudFailure()
            "fixture-stream"
        }
        assertEquals(listOf("commentary"), available.map { it.title })
        assertTrue(SidecarAudio.select("part1.mp4", listOf("part1.dir/bad.m4a", "part1.dir\\bad.m4a")).isEmpty())
    }
}
