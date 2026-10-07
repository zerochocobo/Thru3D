package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.net.HttpURLConnection
import java.net.URL

class SidecarSubtitlesTest {
    @Test fun sitestMatchesOnlyTheSelectedPart() {
        val stem = "4k2.com@sivr00434_8k_part1"
        val names = listOf("$stem.mp4", "$stem.srt", "$stem.si.mix.m4a", "$stem.si.wav",
            "$stem.clone/", "4k2.com@sivr00434_8k_part2.srt", "${stem}0.srt", "${stem}_old.srt")
        assertEquals(listOf("$stem.srt"), SidecarSubtitles.select("$stem.mp4", names))
    }

    @Test fun languageVariantsAndCaseAreSupportedWithExactMatchFirst() {
        assertEquals(listOf("Film.SRT", "film.en.ass", "film.zh-CN.vtt"),
            SidecarSubtitles.select("film.mp4", listOf("film.zh-CN.vtt", "film.en.ass", "Film.SRT", "film.srt/")))
        assertTrue(SidecarSubtitles.select(".mp4", listOf(".srt")).isEmpty())
        assertEquals(8, SidecarSubtitles.select("film.mp4", (1..20).map { "film.$it.srt" }).size)
    }

    @Test fun subtitleProxyPreservesUtf8AndRevokesOnClose() {
        val bytes = "1\n00:00:01,000 --> 00:00:02,000\n字幕测试\n".toByteArray(Charsets.UTF_8)
        LocalStreamServer().use { server ->
            val location = server.publish(object : StreamSource {
                override val size = bytes.size.toLong()
                override fun open() = object : StreamSource.Reader {
                    override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                        val count = minOf(length, bytes.size - offset.toInt())
                        if (count <= 0) return -1
                        bytes.copyInto(buffer, 0, offset.toInt(), offset.toInt() + count)
                        return count
                    }
                    override fun close() {}
                }
            }, "film @中文.srt")
            assertArrayEquals(bytes, URL(location).readBytes())
            server.revoke(location)
            val connection = URL(location).openConnection() as HttpURLConnection
            try { assertEquals(404, connection.responseCode) } finally { connection.disconnect() }
        }
    }

    @Test fun commonTextFormatsAreDiscoveredWithoutAdvertisingBitmapCompanions() {
        for (extension in listOf("srt", "vtt", "ass", "ssa", "smi", "sami", "sub")) {
            assertEquals(listOf("film.$extension"), SidecarSubtitles.select("film.mkv", listOf("film.$extension")))
        }
        assertTrue(SidecarSubtitles.select("film.mp4", listOf("film.idx", "film.sup", "film.txt", "film.srt/child")).isEmpty())
    }
}
