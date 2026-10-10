package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.URI

class DlnaLibraryTest {
    private fun xml(body: String) = """<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:s="http://www.sec.co.kr/" xmlns:p="http://www.pv.com/pvns/">$body</DIDL-Lite>"""
    private fun item(body: String) = """<item id="v_1"><dc:title>Movie</dc:title>$body</item>"""
    private fun escape(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    private fun soap(didl: String) = """<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><u:Result>${escape(didl)}</u:Result></u:BrowseResponse></s:Body></s:Envelope>"""
    private val description = """<root><device><friendlyName>PT server</friendlyName><UDN>uuid:pt</UDN><serviceList><service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><controlURL>/control/cds</controlURL></service></serviceList></device></root>"""

    @Test fun manualLocationsValidateAndPreserveExplicitProxyPath() {
        assertEquals("http://192.168.2.10:8200", DlnaClient.address("192.168.2.10", "8200"))
        assertEquals("http://[::1]:8200", DlnaClient.address("::1", "8200"))
        assertEquals("https://nas.example:443", DlnaClient.address("nas.example", "443", "https"))
        for (port in listOf("", "0", "65536", "abc", "8200.0"))
            assertThrows(IllegalStateException::class.java) { DlnaClient.address("nas", port) }
        for (host in listOf("", "bad host", "nas:8200", "http://nas/description.xml", "user@nas"))
            assertThrows(IllegalStateException::class.java) { DlnaClient.address(host, "8200") }
        assertEquals("http://192.168.2.10:8200/description.xml", DlnaClient.descriptionLocations(" 192.168.2.10:8200 ").first())
        assertEquals(listOf("https://nas.example/proxy/device.xml?x=1"), DlnaClient.descriptionLocations("https://nas.example/proxy/device.xml?x=1"))
        assertTrue(DlnaClient.descriptionLocations("[::1]:8200").first().contains("[::1]:8200"))
        for (bad in listOf("", "ftp://nas/file", "http://user:key@nas/", "http://nas:99999/", "http://nas/#part", "bad host"))
            assertThrows(IllegalStateException::class.java) { DlnaClient.descriptionLocations(bad) }
    }

    @Test fun ptResourcesDeduplicateSecPvAndRetainLanguagesFormatsAndQueryIdentities() {
        val didl = xml(item("""<res protocolInfo="http-get:*:video/mp4:*" p:subtitleFileUri="/subs/movie.srt?mime=text/srt" p:subtitleFileType="srt">/media/movie.mp4</res>
            <res protocolInfo="http-get:*:application/x-subrip:*">/subs/movie.srt</res>
            <res protocolInfo="http-get:*:text/srt:*">/subs/movie.srt?mime=text/srt</res>
            <res protocolInfo="http-get:*:application/x-ass:*" xml:lang="zh">/subs/movie.zh.ASS</res>
            <res protocolInfo="http-get:*:application/x-ssa:*" xml:lang="ja">/subs/movie.ja.ssa</res>
            <res protocolInfo="http-get:*:text/vtt:*" xml:lang="en">/subs/movie.en.vtt</res>
            <res protocolInfo="http-get:*:text/srt:*">/caption?track=1</res>
            <res protocolInfo="http-get:*:text/srt:*">/caption?track=2</res>
            <s:CaptionInfoEx s:type="srt">/subs/movie.srt?mime=text/srt</s:CaptionInfoEx>
            <s:CaptionInfo s:type="srt">/subs/movie.srt?mime=text/srt</s:CaptionInfo>"""))
        val entries = DlnaClient.didl(didl, "http://nas:8200/description.xml")
        assertEquals(1, entries.length())
        assertEquals("http://nas:8200/media/movie.mp4", entries.getJSONObject(0).getString("uri"))
        val tracks = entries.getJSONObject(0).getJSONArray("subtitles")
        assertEquals(6, tracks.length())
        assertEquals("http://nas:8200/subs/movie.srt", tracks.getJSONObject(0).getString("url"))
        assertEquals("zh · ASS", tracks.getJSONObject(1).getString("title"))
        assertEquals("ja · SSA", tracks.getJSONObject(2).getString("title"))
        assertEquals("en · VTT", tracks.getJSONObject(3).getString("title"))
        assertNotEquals(tracks.getJSONObject(4).getString("url"), tracks.getJSONObject(5).getString("url"))
    }

    @Test fun secAndPvOnlyServersWorkAndUnsafeLinksNeverBecomeTracks() {
        for (caption in listOf("<s:CaptionInfoEx s:type=\"ass\">/captions/1</s:CaptionInfoEx>",
            "<s:CaptionInfo s:type=\"ssa\">/captions/1</s:CaptionInfo>",
            "<res protocolInfo=\"http-get:*:image/jpeg:*\" p:subtitleFileUri=\"/captions/1\" p:subtitleFileType=\"vtt\">/cover.jpg</res>")) {
            val tracks = DlnaClient.didl(xml(item("<res protocolInfo=\"http-get:*:video/mp4:*\">/movie.mp4</res>$caption")), "http://nas/desc.xml")
                .getJSONObject(0).getJSONArray("subtitles")
            assertEquals(1, tracks.length())
        }
        val unsafe = listOf("file:///private.srt", "http://user:pass@nas/a.srt", "javascript:alert(1)", "http://nas/a.srt#fragment")
        val body = unsafe.joinToString("") { "<s:CaptionInfoEx s:type=\"srt\">${escape(it)}</s:CaptionInfoEx>" }
        assertEquals(0, DlnaClient.didl(xml(item("<res protocolInfo=\"http-get:*:video/mp4:*\">http://nas/movie.mp4</res>$body")))
            .getJSONObject(0).getJSONArray("subtitles").length())
    }

    @Test fun manualServerPersistsWithoutMulticastMergesAndRollsBackFailedEdits() {
        var state = ""
        var fail = false
        var found = emptyList<DlnaClient.Server>()
        MediaServerClientTest.Fixture { request, _, _ ->
            MediaServerClientTest.Reply(if (request.contains("/rootDesc.xml")) 200 else 404, body = description.toByteArray())
        }.use { fixture ->
            fun library() = DlnaLibrary({ state }, { if (fail) error("disk full"); state = it }, { found })
            val first = library()
            val endpoint = URI(fixture.url)
            val id = first.save(JSONObject().put("host", endpoint.host).put("port", endpoint.port.toString()).put("name", "Remote NAS"))
            assertEquals("uuid:pt", id)
            assertEquals(fixture.url + "/rootDesc.xml", first.servers().getJSONObject(0).getString("location"))
            val restored = library()
            found = listOf(DlnaClient.Server(id, "Auto", fixture.url + "/other.xml", fixture.url + "/other"))
            assertEquals(1, restored.refresh().length())
            assertEquals("Remote NAS", restored.servers().getJSONObject(0).getString("name"))
            assertTrue(restored.servers().getJSONObject(0).getBoolean("manual"))
            fail = true
            assertThrows(IllegalStateException::class.java) { restored.save(JSONObject().put("id", id).put("location", fixture.url).put("name", "New")) }
            assertEquals("Remote NAS", restored.servers().getJSONObject(0).getString("name"))
            assertThrows(IllegalStateException::class.java) { restored.remove(id) }
            assertEquals(1, restored.servers().length())
            fail = false
            restored.remove(id)
            assertEquals(0, restored.servers().length())
            assertEquals(0, library().servers().length())
        }
    }

    @Test fun savedEndpointsSurviveDiscoveryFailure() {
        val row = DlnaClient.Server("id", "Saved", "http://nas/description.xml", "http://nas/cds").json()
        val library = DlnaLibrary({ JSONObject().put("servers", JSONArray().put(row)).toString() }, {}, { error("multicast blocked") })
        assertEquals("Saved", library.refresh().getJSONObject(0).getString("name"))
    }

    @Test fun namespacedDescriptionsKeepServiceVersionAcrossRestart() {
        val xml = """<d:root xmlns:d="urn:schemas-upnp-org:device-1-0"><d:URLBase>/proxy/</d:URLBase><d:device><d:friendlyName>Namespaced NAS</d:friendlyName><d:UDN>uuid:v2</d:UDN><d:service><d:serviceType>urn:schemas-upnp-org:service:ContentDirectory:2</d:serviceType><d:controlURL>cds</d:controlURL></d:service></d:device></d:root>"""
        val selected = DlnaClient.describe("http://nas:8200/description.xml", xml)!!
        assertEquals("Namespaced NAS", selected.name)
        assertEquals("http://nas:8200/proxy/cds", selected.controlUrl)
        assertEquals("urn:schemas-upnp-org:service:ContentDirectory:2", selected.serviceType)
        var endpoint = ""
        var state = ""
        var browsed = false
        MediaServerClientTest.Fixture { request, headers, body ->
            if (request.contains("/proxy/cds")) {
                assertEquals("\"urn:schemas-upnp-org:service:ContentDirectory:2#Browse\"", headers["soapaction"])
                assertTrue(body.contains("xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:2\""))
                browsed = true
                MediaServerClientTest.Reply(body = soap(this.xml("")).toByteArray())
            } else MediaServerClientTest.Reply(body = xml.toByteArray())
        }.use { fixture ->
            endpoint = fixture.url
            val library = DlnaLibrary({ state }, { state = it })
            val id = library.save(JSONObject().put("location", endpoint))
            assertEquals("Namespaced NAS", library.servers().getJSONObject(0).getString("name"))
            val restored = DlnaLibrary({ state }, {})
            assertEquals(0, restored.browse(id, "0").length())
            assertTrue(browsed)
        }
    }

    @Test fun browseReplayRefreshRemovalAndCaptionHeaderReachOriginalByteStreams() {
        var endpoint = ""
        var state = ""
        var metadata = false
        var captions = true
        var header = false
        val payload = "1\r\n00:00:00,000 --> 00:00:02,000\r\n字幕 & Subtitle\r\n".toByteArray()
        val flags = mutableListOf<String>()
        val fixture = MediaServerClientTest.Fixture { request, headers, body ->
            val path = request.split(' ')[1]
            when {
                path == "/description.xml" -> MediaServerClientTest.Reply(body = description.toByteArray())
                path == "/control/cds" -> {
                    metadata = body.contains("BrowseMetadata")
                    flags.add(if (metadata) "metadata" else "children")
                    assertTrue(body.contains("<ObjectID>${if (metadata) "v_1" else "0"}</ObjectID>"))
                    val caption = if (captions) "<res protocolInfo=\"http-get:*:application/x-subrip:*\" xml:lang=\"zh\">$endpoint/subs/movie.srt</res>" else ""
                    MediaServerClientTest.Reply(body = soap(xml(item("<res protocolInfo=\"http-get:*:video/mp4:*\">$endpoint/media/movie.mp4</res>$caption"))).toByteArray())
                }
                request.startsWith("HEAD ") -> {
                    assertEquals("1", headers["getcaptioninfo.sec"])
                    MediaServerClientTest.Reply(headers = if (header) "CaptionInfo.sec: /subs/movie.srt\r\n" else "", body = byteArrayOf())
                }
                path == "/subs/movie.srt" -> MediaServerClientTest.Reply(headers = "Content-Type: application/x-subrip\r\n", body = payload)
                else -> MediaServerClientTest.Reply(404, body = byteArrayOf())
            }
        }
        fixture.use {
            endpoint = fixture.url
            val library = DlnaLibrary({ state }, { state = it })
            val id = library.save(JSONObject().put("location", endpoint))
            val entries = library.browse(id, "0")
            val video = entries.getJSONObject(0).getString("uri")
            val restored = DlnaLibrary({ state }, { state = it })
            val links = restored.subtitles(video)
            assertTrue(metadata)
            assertEquals(1, links.size)
            val tracks = SidecarSubtitles.forDlna(links) { source, name ->
                assertEquals("subtitle-0.srt", name)
                val result = ByteArray(payload.size)
                source.open().use { reader -> assertEquals(payload.size, reader.read(0, result, result.size)) }
                assertArrayEquals(payload, result)
                source.close()
                "http://127.0.0.1/subtitle.srt"
            }
            assertEquals("zh · SRT", tracks.single().title)
            captions = false
            assertTrue(restored.subtitles(video).isEmpty())
            header = true
            assertEquals(endpoint + "/subs/movie.srt", restored.subtitles(video).single().url.toString())
            assertEquals(listOf("children", "metadata", "metadata", "metadata"), flags)
            assertTrue(restored.subtitles("http://unknown/video.mp4").isEmpty())
        }
    }

    @Test fun individualDownloadFailuresDoNotHideValidAssSsaOrVttBytes() {
        val originals = mapOf("ass" to "[Script Info]\n[Events]\nDialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,{\\i1}字幕{\\i0}\\NSubtitle\n".toByteArray(),
            "ssa" to "[Script Info]\nScriptType: v4.00\n[Events]\nDialogue: Marked=0,0:00:00.00,0:00:02.00,Default,,0,0,0,,字幕\n".toByteArray(),
            "vtt" to "WEBVTT\n\n00:00:00.000 --> 00:00:02.000 align:start\n<i>字幕</i> & Subtitle\n".toByteArray())
        MediaServerClientTest.Fixture { request, _, _ ->
            val ext = request.split(' ')[1].substringAfterLast('.')
            MediaServerClientTest.Reply(body = originals[ext] ?: "<html>login</html>".toByteArray())
        }.use { fixture ->
            val links = (listOf("srt") + originals.keys).map { MediaSubtitleLink(URI(fixture.url + "/movie.$it"), it, it) }
            val tracks = SidecarSubtitles.forDlna(links) { source, name ->
                val expected = originals.getValue(name.substringAfterLast('.'))
                val result = ByteArray(expected.size)
                source.open().use { it.read(0, result, result.size) }
                assertArrayEquals(expected, result)
                source.close()
                name
            }
            assertEquals(listOf("ass", "ssa", "vtt"), tracks.map { it.title })
        }
    }

    @Test fun earlyItemsOnLargePagesHaveSubtitlesAndSelectedHistorySurvivesRestart() {
        var endpoint = ""
        var state = ""
        MediaServerClientTest.Fixture { request, _, body ->
            if (request.contains("/description.xml")) MediaServerClientTest.Reply(body = description.toByteArray())
            else {
                val numbers = if (body.contains("BrowseMetadata")) listOf(0) else (0 until 1000).toList()
                val items = numbers.joinToString("") { id -> """<item id="$id"><dc:title>Movie $id</dc:title><res protocolInfo="http-get:*:video/mp4:*">$endpoint/$id.mp4</res><res protocolInfo="http-get:*:text/srt:*">$endpoint/$id.srt</res></item>""" }
                MediaServerClientTest.Reply(body = soap(xml(items)).toByteArray())
            }
        }.use { fixture ->
            endpoint = fixture.url
            val library = DlnaLibrary({ state }, { state = it })
            val id = library.save(JSONObject().put("location", endpoint))
            assertEquals(1000, library.browse(id, "0").length())
            assertEquals(256, JSONObject(state).getJSONArray("references").length())
            val video = "$endpoint/0.mp4"
            assertEquals("$endpoint/0.srt", library.subtitles(video).single().url.toString())
            val restored = DlnaLibrary({ state }, {})
            assertEquals("$endpoint/0.srt", restored.subtitles(video).single().url.toString())
        }
    }
}
