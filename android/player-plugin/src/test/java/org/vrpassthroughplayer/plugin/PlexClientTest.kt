package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.net.URI
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Fixture
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Reply

class PlexClientTest {
    private val movie = """{"ratingKey":"12","type":"movie","title":"VR fixture","duration":60000,"viewOffset":1234,"rating":8.5,"thumb":"/library/metadata/12/thumb/1","Genre":[{"id":20,"tag":"Drama"}],"Media":[{"width":3840,"height":1920,"Part":[{"id":"91","key":"/library/parts/91/1/file.mp4","file":"C:\\VR\\sample_180_SBS.mp4","size":200000,"Stream":[{"streamType":3,"codec":"srt","key":"/library/streams/45/file.srt","language":"Chinese"}]}]}],"Chapter":[{"title":"Start","startTimeOffset":5000}]}"""
    private fun reply(data: String) = Reply(body = data.toByteArray())
    private fun json(request: String): Reply = when {
        request.contains("/identity") -> reply("""{"MediaContainer":{"machineIdentifier":"machine","version":"1.43"}}""")
        request.contains("/library/sections?") || request.contains("/library/sections ") -> reply("""{"MediaContainer":{"Directory":[{"key":"1","title":"Films","type":"movie"},{"key":"2","title":"TV","type":"show"},{"key":"3","type":"artist"}]}}""")
        request.contains("/onDeck") -> reply("""{"MediaContainer":{"Metadata":[]}}""")
        request.contains("/genre?") -> reply("""{"MediaContainer":{"Directory":[{"key":"20","title":"Drama"},{"key":"21","title":"Comedy"}]}}""")
        request.contains("/studio?") -> reply("""{"MediaContainer":{"Directory":[{"key":"Studio with spaces","title":"Studio with spaces"}]}}""")
        request.contains("/library/metadata/12?") -> reply("""{"MediaContainer":{"Metadata":[$movie]}}""")
        else -> reply("""{"MediaContainer":{"size":1,"totalSize":97,"Metadata":[$movie]}}""")
    }
    @Test fun librariesBrowseFiltersAndMetadataUseCommonContract() {
        val requests = mutableListOf<String>()
        Fixture { request, headers, _ ->
            assertEquals("server-token", headers["x-plex-token"])
            assertEquals("client", headers["x-plex-client-identifier"])
            assertEquals("application/json", headers["accept"])
            assertFalse(request.contains("server-token")); requests.add(request); json(request)
        }.use { fixture ->
            val account = MediaServerAccount("client", "Plex", fixture.url, "server-token", "plex", "machine")
            MediaServerHttp(account).use { http ->
                val client = mediaClient(account, http)
                assertEquals("1.43", client.probe())
                val home = client.home(JSONObject()); assertEquals(2, home.getJSONArray("libraries").length())
                assertEquals("1", home.getString("library_id"))
                val page = client.browse(JSONObject("""{"library_id":"1","page":2,"q":"中&?","genres":["20"],"studios":["Studio with spaces"],"watched":false,"sort":"title","direction":"ASC"}"""))
                assertEquals(97, page.getInt("total")); assertEquals(2, page.getInt("page"))
                val entry = page.getJSONArray("entries").getJSONObject(0)
                assertEquals("medialib://client/scene/12", entry.getString("uri")); assertEquals(1234, entry.getInt("position_ms"))
                assertEquals("sample_180_SBS.mp4", entry.getString("basename")); assertEquals(3840, entry.getInt("width"))
                val request = requests.last(); assertTrue(request.contains("X-Plex-Container-Start=48"))
                assertTrue(request.contains("unwatched=1")); assertTrue(request.contains("titleSort%3Aasc")); assertTrue(request.contains("genre=20"))
                assertEquals(1, client.candidates(JSONObject("""{"library_id":"1","kind":"genres","q":"drama"}""")).getJSONArray("entries").length())
                assertEquals("Studio with spaces", client.candidates(JSONObject("""{"kind":"studios"}""")).getJSONArray("entries").getJSONObject(0).getString("id"))
                assertEquals(5000, client.detail("12").getJSONArray("markers").getJSONObject(0).getInt("position_ms"))
                assertEquals("/library/metadata/12/thumb/1", client.cover("12").path)
                assertThrows(MediaServerFailure::class.java) { client.browse(JSONObject().put("library_id", "999")) }
            }
        }
    }
    @Test fun showsExposeSeriesNavigationAndFlatEpisodePlayback() {
        val requests = mutableListOf<String>()
        Fixture { request, _, _ -> requests.add(request); json(request) }.use { fixture ->
            val account = MediaServerAccount("client", "Plex", fixture.url, "", "plex")
            MediaServerHttp(account).use { http ->
                val client = PlexClient(account, http)
                client.browse(JSONObject("""{"library_id":"2"}""")); assertTrue(requests.last().contains("type=4"))
                client.browse(JSONObject("""{"library_id":"2","mode":"folders"}""")); assertTrue(requests.last().contains("type=2"))
                client.browse(JSONObject("""{"library_id":"2","mode":"folders","parent_id":"123"}""")); assertTrue(requests.last().contains("/metadata/123/children?"))
            }
        }
    }
    @Test fun directOriginalSupportsSeekingAndExternalSubtitles() {
        val bytes = ByteArray(200000) { (it % 251).toByte() }
        Fixture { request, headers, _ ->
            if (!request.contains("/library/parts/")) json(request) else {
                assertEquals("secret", headers["x-plex-token"])
                val bounds = headers.getValue("range").removePrefix("bytes=").split('-')
                val start = bounds[0].toInt(); val end = bounds[1].toIntOrNull() ?: bytes.lastIndex
                Reply(206, "Content-Range: bytes $start-$end/${bytes.size}\r\n", bytes.copyOfRange(start, end + 1))
            }
        }.use { fixture ->
            val account = MediaServerAccount("client", "Plex", fixture.url, "secret", "plex")
            HttpRangeStreamSource(account) { PlexClient(account, it).stream("12") }.use { source ->
                assertEquals(200000L, source.size); assertEquals(1, source.original().subtitles.size)
                assertEquals("/library/streams/45/file.srt", source.original().subtitles.single().url.path)
                source.open().use { reader ->
                    val buffer = ByteArray(123)
                    for (offset in listOf(0L, 95000L, 2000L)) {
                        assertEquals(123, reader.read(offset, buffer, buffer.size))
                        assertArrayEquals(bytes.copyOfRange(offset.toInt(), offset.toInt() + 123), buffer)
                    }
                }
            }
        }
    }
    @Test fun rejectsForeignStreamsMultipartAndChangedServer() {
        for (modified in listOf(movie.replace("/library/parts/91/1/file.mp4", "https://foreign.invalid/file.mp4"),
            movie.replace("\"Part\":[", "\"Part\":[{},"))) {
            Fixture { _, _, _ -> reply("""{"MediaContainer":{"Metadata":[$modified]}}""") }.use { fixture ->
                val account = MediaServerAccount("client", "Plex", fixture.url, "secret", "plex")
                MediaServerHttp(account).use { assertThrows(MediaServerFailure::class.java) { PlexClient(account, it).stream("12") } }
            }
        }
        Fixture { request, _, _ -> json(request) }.use { fixture ->
            val account = MediaServerAccount("client", "Plex", fixture.url, "secret", "plex", "another-server")
            MediaServerHttp(account).use { assertThrows(MediaServerFailure::class.java) { PlexClient(account, it).probe() } }
        }
    }
    @Test fun pinApprovalAndResourceTokensStayOutOfPublicSnapshots() {
        Fixture { request, headers, _ ->
            assertEquals("client", headers["x-plex-client-identifier"])
            if (request.contains("/resources")) {
                assertEquals("account-token", headers["x-plex-token"])
                reply("""[{"clientIdentifier":"machine","name":"NAS","provides":"server","accessToken":"server-token","connections":[{"uri":"http://nas:32400","local":true}]}]""")
            } else { assertNull(headers["x-plex-token"]); reply("""{"id":123,"code":"ABCD","expiresIn":300,"authToken":${if (request.startsWith("GET")) "\"account-token\"" else "null"}}""") }
        }.use { fixture ->
            PlexAuth("client", fixture.url).use { auth ->
                val pin = auth.createPin(); assertEquals("ABCD", pin.code); assertEquals("https://plex.tv/link/?pin=ABCD", pin.link())
                assertEquals("account-token", auth.confirm(pin))
                val server = auth.servers("account-token").single()
                assertEquals("server-token", server.token)
                assertFalse(server.publicJson().toString().contains("token"))
                assertThrows(MediaServerFailure::class.java) { auth.poll(PlexAuth.Pin("456", "ABCD", 300)) }
            }
        }
    }
    @Test fun confirmationRejectsUnapprovedExpiredAndCancelledPairing() {
        Fixture { _, _, _ -> reply("""{"id":123,"code":"ABCD","authToken":null}""") }.use { fixture ->
            val auth = PlexAuth("client", fixture.url)
            auth.use {
                val pin = PlexAuth.Pin("123", "ABCD", 300)
                assertEquals("Pairing not completed", assertThrows(MediaServerFailure::class.java) { it.confirm(pin) }.code)
                it.close()
                assertEquals("Request cancelled", assertThrows(MediaServerFailure::class.java) { it.confirm(pin) }.code)
            }
        }
        for (status in listOf(404, 410)) Fixture { _, _, _ -> Reply(status, body = "private-body".toByteArray()) }.use { fixture ->
            PlexAuth("client", fixture.url).use { auth ->
                assertEquals("Pairing code expired", assertThrows(MediaServerFailure::class.java) {
                    auth.confirm(PlexAuth.Pin("123", "ABCD", 300))
                }.code)
            }
        }
    }
    @Test fun resourceConnectionsPreferLanAndRejectLoopbackOrCredentialUrls() {
        val servers = PlexAuth.parseServers(JSONArray("""[{"clientIdentifier":"machine","provides":"server","accessToken":"token","connections":[{"uri":"https://relay.plex.direct:443","relay":true},{"uri":"https://remote.plex.direct:32400"},{"uri":"http://192.168.31.185:32400","local":true},{"uri":"http://127.0.0.1:32400","local":true},{"uri":"http://user:secret@nas:32400"},{"uri":"http://nas:32400?token=x"}]}]""")).single()
        assertEquals(3, servers.connections.size)
        assertEquals("http://192.168.31.185:32400", servers.connections[0].base)
        assertTrue(servers.connections.last().relay)
    }
    @Test fun optionalLivePlexLibraryAndRangeRead() {
        val base = System.getenv("VRPP_PLEX_TEST_URL").orEmpty(); val token = System.getenv("VRPP_PLEX_TEST_TOKEN").orEmpty()
        val pinId = System.getenv("VRPP_PLEX_PIN_ID").orEmpty(); val pinCode = System.getenv("VRPP_PLEX_PIN_CODE").orEmpty()
        assumeTrue(base.isNotBlank() && (token.isNotBlank() || (pinId.isNotBlank() && pinCode.isNotBlank())))
        val account = if (pinId.isNotBlank()) PlexAuth("thru3d-live-test").use { auth ->
            val approved = auth.confirm(PlexAuth.Pin(pinId, pinCode, 900))
            val machine = auth.identify(base)
            val resource = auth.servers(approved).firstOrNull { it.id == machine } ?: throw AssertionError("Authorized server not found")
            println("Plex live: native PIN approval, resources and server identity passed")
            MediaServerAccount("thru3d-live-test", "Plex", base, resource.token, "plex", machine)
        } else MediaServerAccount("thru3d-live-test", "Plex", base, token, "plex")
        MediaServerHttp(account).use { http ->
            val client = PlexClient(account, http); assertTrue(client.probe().isNotBlank())
            val home = client.home(JSONObject()); assertTrue(home.getJSONArray("libraries").length() > 0)
            val nodes = client.browse(JSONObject()).getJSONArray("entries"); assertTrue(nodes.length() > 0)
            val id = nodes.getJSONObject(0).getString("id"); client.detail(id)
            val cover = http.bytes(client.cover(id), 8 * 1024 * 1024); assertTrue(cover.isNotEmpty())
            HttpRangeStreamSource(account) { PlexClient(account, it).stream(id) }.use { source ->
                source.open().use { reader ->
                    val bytes = ByteArray(1024)
                    assertTrue(reader.read(0, bytes, bytes.size) > 0)
                    assertTrue(reader.read(source.size / 2, bytes, bytes.size) > 0)
                }
            }
            println("Plex live: authenticated library, metadata, cover and original Range reads passed")
        }
    }
    @Test fun optionalLiveUnapprovedPairingCannotConfirm() {
        assumeTrue(System.getenv("VRPP_PLEX_PAIRING_LIVE") == "true")
        PlexAuth(java.util.UUID.randomUUID().toString()).use { auth ->
            val pin = auth.createPin()
            assertEquals("Pairing not completed", assertThrows(MediaServerFailure::class.java) { auth.confirm(pin) }.code)
            println("Plex live: fresh unapproved official PIN correctly rejected by confirmation")
        }
    }
}
