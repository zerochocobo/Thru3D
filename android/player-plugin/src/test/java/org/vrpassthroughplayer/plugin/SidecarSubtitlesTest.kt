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
    @Test fun cloudDiscoveryIncludesSubtitlesBeyondTheFirstLibraryPage() {
        val offsets = ArrayList<Int>()
        val stem = "片名 @SBS"
        val client = CloudDrive(CloudDrive.P115, "UID=fixture", CloudTransport { url, _, _ ->
            val offset = java.net.URI(url).query.split('&').first { it.startsWith("offset=") }.substringAfter('=').toInt()
            offsets.add(offset)
            val data = org.json.JSONArray()
            for (i in offset until minOf(offset + CloudDrive.PAGE_SIZE, 60)) {
                val name = when (i) { 2 -> "$stem.mp4"; 55 -> "$stem.zh-CN.srt"; else -> "unrelated-$i.bin" }
                data.put(org.json.JSONObject().put("fid", "${1000 + i}").put("n", name).put("s", 80).put("pc", "pick-$i"))
            }
            CloudResponse(org.json.JSONObject().put("state", true).put("offset", offset).put("count", 60).put("data", data))
        })
        val selected = ArrayList<CloudFile>()
        val tracks = SidecarSubtitles.forCloud("/$stem.mp4", client) { file -> selected.add(file); "fixture-stream" }
        assertEquals(listOf(0, 48), offsets)
        assertEquals(listOf("$stem.zh-CN.srt"), tracks.map { it.title })
        assertEquals("pick-55", selected.single().pickCode)
    }

    @Test fun cloudFoldersEmptyFilesAndOneUnavailableSubtitleDoNotHideAnotherTrack() {
        val files = listOf(CloudFile("film.srt", false, 10, "/folder/film.srt"),
            CloudFile("film.en.srt", false, 10, "/folder/film.en.srt"),
            CloudFile("film.zh.srt", true, 10, "/folder/film.zh.srt"),
            CloudFile("film.ja.srt", false, 0, "/folder/film.ja.srt"),
            CloudFile("other.srt", false, 10, "/folder/other.srt"))
        val client = object : CloudClient {
            override fun list(path: String): List<CloudFile> { assertEquals("/folder", path); return files }
            override fun page(path: String, offset: Int, refresh: Boolean): CloudPage = error("Must read all sibling pages")
            override fun find(path: String): CloudFile = error("Preserve listed file metadata")
            override fun resolve(file: CloudFile): CloudLink = error("Do not resolve unrelated files")
        }
        val tracks = SidecarSubtitles.forCloud("/folder/film.mp4", client) { file ->
            if (file.name == "film.srt") throw CloudFailure()
            assertEquals("/folder/film.en.srt", file.id)
            "fixture-stream"
        }
        assertEquals(listOf("film.en.srt"), tracks.map { it.title })
    }

    @Test fun cloudSubtitleProxyPreservesUtf8AndDoesNotRevokeTheVideo() {
        val caption = "1\n00:00:01,000 --> 00:00:02,000\n字幕测试\n".toByteArray(Charsets.UTF_8)
        val video = byteArrayOf(1, 2, 3, 4)
        fun bytesSource(data: ByteArray) = object : StreamSource {
            override val size = data.size.toLong()
            override fun open() = object : StreamSource.Reader {
                override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                    val count = minOf(length, data.size - offset.toInt())
                    if (count <= 0) return -1
                    data.copyInto(buffer, 0, offset.toInt(), offset.toInt() + count)
                    return count
                }
                override fun close() {}
            }
        }
        LocalStreamServer().use { upstream -> LocalStreamServer().use { local ->
            val origin = upstream.publish(bytesSource(caption), "film.srt")
            val videoUrl = local.publish(bytesSource(video), "film.mp4")
            val client = object : CloudClient {
                override fun list(path: String) = listOf(CloudFile("film.srt", false, caption.size.toLong(), "/film.srt"))
                override fun page(path: String, offset: Int, refresh: Boolean): CloudPage = error("Unexpected call")
                override fun find(path: String): CloudFile = error("Unexpected call")
                override fun resolve(file: CloudFile) = CloudLink(origin) { emptyMap() }
            }
            val track = SidecarSubtitles.forCloud("/film.mp4", client) { file ->
                val source = CloudStreamSource(file.size, { client.resolve(file) }) {
                    it.toURL().openConnection() as HttpURLConnection
                }
                source.prepare()
                local.publish(source, file.name)
            }.single()
            assertArrayEquals(caption, URL(track.location).readBytes())
            val range = URL(track.location).openConnection() as HttpURLConnection
            try {
                range.setRequestProperty("Range", "bytes=3-12")
                assertEquals(206, range.responseCode)
                assertArrayEquals(caption.copyOfRange(3, 13), range.inputStream.use { it.readBytes() })
            } finally { range.disconnect() }
            assertArrayEquals(video, URL(videoUrl).readBytes())
            local.revoke(track.location)
            val revoked = URL(track.location).openConnection() as HttpURLConnection
            try { assertEquals(404, revoked.responseCode) } finally { revoked.disconnect() }
            assertArrayEquals(video, URL(videoUrl).readBytes())
        } }
    }
}
