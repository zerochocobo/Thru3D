package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.Closeable
import java.net.ServerSocket
import java.net.URI
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class MediaServerClientTest {
    private data class Reply(val code: Int = 200, val headers: String = "", val body: ByteArray)
    private class Fixture(val handle: (String, Map<String, String>, String) -> Reply) : Closeable {
        private val socket = ServerSocket(0)
        val url = "http://127.0.0.1:${socket.localPort}"
        private val pool = Executors.newCachedThreadPool { Thread(it).apply { isDaemon = true } }
        init { pool.execute { while (!socket.isClosed) {
            val peer = try { socket.accept() } catch (_: Exception) { break }
            pool.execute { peer.use {
                val input = peer.getInputStream()
                fun line(): String { val out = StringBuilder(); while (true) { val b = input.read(); if (b < 0 || b == 10) return out.toString().trimEnd('\r'); out.append(b.toChar()) } }
                val request = line(); val headers = HashMap<String, String>()
                while (true) { val l = line(); if (l.isEmpty()) break; headers[l.substringBefore(':').lowercase()] = l.substringAfter(':').trim() }
                val body = ByteArray(headers["content-length"]?.toInt() ?: 0)
                var at = 0; while (at < body.size) { val n = input.read(body, at, body.size - at); if (n < 0) break; at += n }
                val response = handle(request, headers, String(body, Charsets.UTF_8))
                runCatching { peer.getOutputStream().apply {
                    write(("HTTP/1.1 ${response.code} Test\r\nContent-Length: ${response.body.size}\r\nConnection: close\r\n${response.headers}\r\n").toByteArray())
                    write(response.body); flush()
                } }
            } }
        } } }
        override fun close() { socket.close(); pool.shutdownNow() }
    }
    @Test fun identityRejectsSecretsAndPreservesServerScope() {
        val uri = MediaLibraryUri.scene("abc-123", "89")
        assertEquals("abc-123" to "89", MediaLibraryUri.parse(uri))
        for (bad in listOf("medialib://user:key@abc/scene/89", "$uri?apikey=secret", "$uri/../2", "http://abc/scene/89"))
            assertThrows(MediaServerFailure::class.java) { MediaLibraryUri.parse(bad) }
        assertNotEquals(uri, MediaLibraryUri.scene("other", "89"))
    }
    @Test fun stashSpriteFallbackUsesFirstCueAndRejectsInvalidRectangles() {
        val base = URI("http://nas:9999/scene/hash_thumbs.vtt")
        val cue = StashClient.spriteCover(base, "WEBVTT\n\n00:00:00.000 --> 00:00:10.000\nhash_sprite.jpg#xywh=160,80,160,80\n")!!
        assertEquals("http://nas:9999/scene/hash_sprite.jpg", cue.uri.toString())
        assertEquals(160, cue.x); assertEquals(80, cue.y); assertEquals(160, cue.width); assertEquals(80, cue.height)
        for (rect in listOf("-1,0,160,80", "0,0,0,80", "0,0,999999,80", "0,0,x,80", "0,0,80"))
            assertNull(StashClient.spriteCover(base, "hash.jpg#xywh=$rect"))
        assertNull(StashClient.spriteCover(base, "WEBVTT\n"))
    }
    @Test fun filtersHaveExplicitAllAnyExclusionAndVariables() {
        val v = StashClient.variables(JSONObject("""{"q":"quote\"\\中","tags":["1","2","1"],"exclude_tags":["1","3"],"performers":["5"],"watched":false,"min_duration":600,"page":2}"""))
        assertEquals("quote\"\\中", v.getJSONObject("page").getString("q"))
        val c = v.getJSONObject("criteria")
        assertEquals("INCLUDES_ALL", c.getJSONObject("tags").getString("modifier"))
        assertEquals("[\"1\",\"2\"]", c.getJSONObject("tags").getJSONArray("value").toString())
        assertEquals("[\"3\"]", c.getJSONObject("tags").getJSONArray("excludes").toString())
        assertEquals("INCLUDES", c.getJSONObject("performers").getString("modifier"))
        assertEquals("EQUALS", c.getJSONObject("play_count").getString("modifier"))
        assertEquals(599, c.getJSONObject("duration").getInt("value"))
        val exclusion = StashClient.variables(JSONObject("""{"exclude_tags":["9"]}""")).getJSONObject("criteria").getJSONObject("tags")
        assertEquals("EXCLUDES", exclusion.getString("modifier")); assertFalse(exclusion.has("excludes"))
        assertThrows(MediaServerFailure::class.java) { StashClient.variables(JSONObject("""{"tags":["not-an-id"]}""")) }
    }
    @Test fun scopeAndAddressValidationPreserveProxyPath() {
        val a = MediaServerAccount("id", "test", MediaServerAccount.address("https://nas.test/stash/"), "secret")
        assertEquals("https://nas.test/stash/graphql", a.endpoint("graphql").toString())
        assertTrue(a.accepts(URI("https://nas.test:443/scene/1/stream?signature=x")))
        for (u in listOf("http://nas.test/a", "https://nas.test.evil/a", "https://nas.test:8443/a", "https://user@nas.test/a")) assertFalse(a.accepts(URI(u)))
        for (u in listOf("file:///tmp", "https://user:pass@nas/", "http://nas/?key=x")) assertThrows(MediaServerFailure::class.java) { MediaServerAccount.address(u) }
        assertFalse(a.json().has("key"))
    }
    @Test fun graphqlErrorsAndForeignRedirectDoNotExposeCredentials() {
        Fixture { _, _, _ -> Reply(body = """{"errors":[{"message":"private-secret-url"}]}""".toByteArray()) }.use { fixture ->
            val a = MediaServerAccount("id", "test", fixture.url, "secret")
            MediaServerHttp(a).use { http ->
                val error = assertThrows(MediaServerFailure::class.java) { StashClient(a, http).probe() }
                assertEquals("Server query unsupported", error.message)
            }
        }
        Fixture { _, _, _ -> Reply(302, "Location: https://foreign.invalid/\r\n", byteArrayOf()) }.use { fixture ->
            val a = MediaServerAccount("id", "test", fixture.url, "secret")
            MediaServerHttp(a).use { http -> assertEquals("Media address differs from server",
                assertThrows(MediaServerFailure::class.java) { http.bytes(URI(fixture.url), 100) }.code) }
        }
    }
    @Test fun actualRangeSeekAndLocalProxyPreserveBytes() {
        val bytes = ByteArray(180000) { (it % 251).toByte() }
        val requests = AtomicInteger()
        Fixture { _, headers, _ ->
            requests.incrementAndGet()
            val r = headers.getValue("range").removePrefix("bytes=").split('-')
            val start = r[0].toInt(); val end = r[1].toIntOrNull() ?: bytes.lastIndex
            Reply(if (headers["apikey"] == "fixture-key") 206 else 403,
                "Content-Range: bytes $start-$end/${bytes.size}\r\nContent-Type: video/mp4\r\n", bytes.copyOfRange(start, end + 1))
        }.use { fixture ->
            val a = MediaServerAccount("id", "test", fixture.url, "fixture-key")
            val source = HttpRangeStreamSource(a) { MediaStreamLink(URI(fixture.url), "identity") }
            assertEquals(bytes.size.toLong(), source.size)
            source.open().use { reader ->
                val buffer = ByteArray(80)
                assertEquals(80, reader.read(10, buffer, 80)); assertArrayEquals(bytes.copyOfRange(10, 90), buffer)
                reader.read(90, buffer, 80); assertEquals(2, requests.get())
                reader.read(90000, buffer, 80); assertArrayEquals(bytes.copyOfRange(90000, 90080), buffer)
            }
            LocalStreamServer().use { local ->
                val url = local.publish(source, "fixture.mp4")
                val c = URI(url).toURL().openConnection() as java.net.HttpURLConnection
                c.setRequestProperty("Range", "bytes=150000-150039")
                assertEquals(206, c.responseCode)
                assertArrayEquals(bytes.copyOfRange(150000, 150040), c.inputStream.use { it.readBytes() }); c.disconnect()
                local.revoke(url)
                assertThrows(MediaServerFailure::class.java) { source.open() }
            }
        }
    }
    @Test fun ignoresRangeAndInvalidContentFailBeforePublication() {
        for ((status, headers) in listOf(200 to "", 206 to "Content-Range: bytes 1-1/10\r\n", 206 to "Content-Range: bytes 0-0/10\r\nContent-Type: text/html\r\n")) {
            Fixture { _, _, _ -> Reply(status, headers, byteArrayOf(1)) }.use { fixture ->
                val a = MediaServerAccount("id", "test", fixture.url, "")
                assertThrows(MediaServerFailure::class.java) { HttpRangeStreamSource(a) { MediaStreamLink(URI(fixture.url), "id") } }
            }
        }
    }
    @Test fun embyAndJellyfinLoginBrowseChaptersAndDirectStream() {
        for (provider in listOf("emby", "jellyfin")) {
            val failures = java.util.concurrent.ConcurrentLinkedQueue<String>()
            val media = """{"Id":"ab12-cd34","Name":"Film","RunTimeTicks":600000000,"MediaSources":[{"Id":"source","Protocol":"File","Size":100,"Path":"/private/Film_180_SBS.mkv"}],"Chapters":[{"Name":"Part 2","StartPositionTicks":300000000}]}"""
            Fixture { request, headers, body ->
                fun verify(value: Boolean, message: String) { if (!value) failures.add(message) }
                verify(headers["apikey"] == null, "Stash key sent to $provider")
                val path = request.split(' ')[1]
                val authorization = headers["authorization"].orEmpty()
                verify(authorization.startsWith(if (provider == "jellyfin") "MediaBrowser " else "Emby "), "provider authorization scheme")
                verify(authorization.contains("DeviceId=\"device\""), "stable device identity")
                if (path.endsWith("/Users/AuthenticateByName")) {
                    verify(!authorization.contains("Token="), "token sent on login")
                } else if (provider == "jellyfin") {
                    verify(headers["x-emby-token"] == null, "legacy Jellyfin token header")
                    // Jellyfin 12 disables legacy authentication: metadata alone is not authentication.
                    if (!authorization.contains("Token=\"private-token\""))
                        return@Fixture Reply(401, body = byteArrayOf())
                } else {
                    verify(headers["x-emby-token"] == "private-token", "missing Emby user token")
                }
                val response = when {
                    path.endsWith("/Users/AuthenticateByName") -> {
                        verify(JSONObject(body).getString("Pw") == "password", "login body")
                        verify(headers["x-emby-token"] == null, "stale token sent on login")
                        """{"AccessToken":"private-token","User":{"Id":"user1"}}"""
                    }
                    path.contains("System/Info/Public") -> """{"Version":"test","ProductName":"$provider"}"""
                    path.contains("PlaybackInfo") -> """{"PlaySessionId":"session1","MediaSources":[{"Id":"source","Protocol":"File","Size":100,"SupportsDirectPlay":true}]}"""
                    path.contains("/Items/ab12-cd34") -> media
                    else -> {
                        if (path.contains("StartIndex")) verify(path.contains("StartIndex=48") && path.contains("SearchTerm=A%26B"), "paging/escaped search")
                        """{"Items":[$media],"TotalRecordCount":100}"""
                    }
                }
                Reply(body = response.toByteArray())
            }.use { fixture ->
                val anonymous = MediaServerAccount("device", "Test", fixture.url + "/proxy", "", provider)
                val account = MediaServerHttp(anonymous).use { EmbyClient(anonymous, it).login("user", "password") }
                assertFalse(account.json().toString().contains("private-token"))
                assertFalse(account.json(true).toString().contains("password"))
                MediaServerHttp(account).use { http ->
                    val client = mediaClient(account, http)
                    assertEquals("test", client.probe())
                    val result = client.browse(JSONObject("""{"page":2,"q":"A&B"}"""))
                    assertEquals(100, result.getInt("total"))
                    val detail = client.detail("ab12-cd34")
                    assertEquals(30000, detail.getJSONArray("markers").getJSONObject(0).getInt("position_ms"))
                    assertEquals("Film_180_SBS.mkv", detail.getString("basename"))
                    assertFalse(detail.toString().contains("/private/"))
                    val stream = client.stream("ab12-cd34")
                    assertTrue(stream.url.toString().contains("Static=true"))
                    assertFalse(stream.url.toString().contains("private-token"))
                    assertTrue(client.cover("ab12-cd34").path.startsWith("/proxy/Items/"))
                    assertTrue(http.bytes(client.cover("ab12-cd34"), 1024 * 1024).isNotEmpty())
                    val ranged = http.open(stream.url, range = "bytes=0-0")
                    http.release(ranged)
                }
                assertTrue(failures.toString(), failures.isEmpty())
            }
        }
    }
    @Test fun xbvrNativeFiltersNumericIdsAndFileSelection() {
        val failures = java.util.concurrent.ConcurrentLinkedQueue<String>()
        val scene = """{"id":7,"title":"Scene","cover_url":"https://images.invalid/cover.jpg","file":[{"id":12,"type":"video","filename":"film_180_SBS.mp4","video_width":4096,"duration":60,"size":100}],"tags":[{"name":"Tag A"}],"cast":[],"cuepoints":[{"name":"Part","time_start":12}]}"""
        Fixture { request, _, body ->
            val response = when {
                request.contains("/list") -> {
                    val data = JSONObject(body)
                    if (data.getInt("offset") == 48 && data.getJSONArray("tags").toString() != "[\"&Tag A\",\"!Tag B\"]") failures.add("filter semantics")
                    """{"results":49,"scenes":[$scene]}"""
                }
                request.contains("/filters") -> """{"tags":["Tag A","Tag B"],"cast":[],"sites":[]}"""
                else -> scene
            }
            Reply(body = response.toByteArray())
        }.use { fixture ->
            val a = MediaServerAccount("xbvr-test", "XBVR", fixture.url, "", "xbvr")
            MediaServerHttp(a).use { http ->
                val client = mediaClient(a, http)
                client.probe()
                val result = client.browse(JSONObject("""{"page":2,"tags":["Tag A"],"exclude_tags":["Tag B"]}"""))
                assertEquals("7", result.getJSONArray("entries").getJSONObject(0).getString("id"))
                assertEquals("Tag A", client.candidates(JSONObject("""{"kind":"tags","q":"Tag A"}""")).getJSONArray("entries").getJSONObject(0).getString("id"))
                assertEquals(12000, client.detail("7").getJSONArray("markers").getJSONObject(0).getInt("position_ms"))
                assertEquals("/api/dms/file/12", client.stream("7").url.path)
                assertEquals("dnt=1", client.stream("7").url.query)
                assertTrue(a.accepts(client.cover("7")))
                assertThrows(MediaServerFailure::class.java) { client.browse(JSONObject("""{"q":"unsupported"}""")) }
                assertTrue(failures.toString(), failures.isEmpty())
            }
        }
    }
    @Test fun liveEmbyPublicPasswordlessUser() {
        val url = System.getenv("VRPP_EMBY_TEST_URL").orEmpty()
        assumeTrue("Optional local Emby integration", url.isNotEmpty())
        val anonymous = MediaServerAccount(java.util.UUID.randomUUID().toString(), "Emby test", MediaServerAccount.address(url), "", "emby")
        val account = MediaServerHttp(anonymous).use { http ->
            val users = org.json.JSONArray(String(http.bytes(anonymous.endpoint("Users/Public"), 1024 * 1024), Charsets.UTF_8)).objects()
            assumeTrue("Only an unambiguous public passwordless account is used", users.size == 1 && !users[0].optBoolean("HasPassword", true))
            EmbyClient(anonymous, http).login(users[0].getString("Name"), "")
        }
        MediaServerHttp(account).use { http ->
            try {
                val client = EmbyClient(account, http)
                assertTrue(client.probe().isNotBlank())
                val result = client.browse(JSONObject())
                val count = result.getInt("total")
                assertTrue(count >= 0)
                val items = result.getJSONArray("entries")
                if (items.length() > 0) {
                    val id = items.getJSONObject(0).getString("id")
                    assertEquals(id, client.detail(id).getString("id"))
                    HttpRangeStreamSource(account) { EmbyClient(account, it).stream(id) }.use { source ->
                        source.open().use { reader ->
                            val sample = ByteArray(64)
                            assertTrue(reader.read(0, sample, sample.size) > 0)
                            assertTrue(reader.read(source.size / 2, sample, sample.size) > 0)
                        }
                    }
                }
                println("Live Emby: library count=$count; original stream tested=${items.length() > 0}")
            } finally {
                http.bytes(account.endpoint("Sessions/Logout"), 1024, JSONObject())
            }
        }
    }
    @Test fun liveJellyfinLoginBrowseAndDirectStream() {
        val url = System.getenv("VRPP_JELLYFIN_TEST_URL").orEmpty()
        val username = System.getenv("VRPP_JELLYFIN_TEST_USERNAME").orEmpty()
        val password = System.getenv("VRPP_JELLYFIN_TEST_PASSWORD")
        assumeTrue("Optional local Jellyfin integration", url.isNotEmpty() && username.isNotEmpty() && password != null)
        val anonymous = MediaServerAccount(java.util.UUID.randomUUID().toString(), "Jellyfin test",
            MediaServerAccount.address(url), "", "jellyfin")
        val account = MediaServerHttp(anonymous).use { EmbyClient(anonymous, it).login(username, password!!) }
        MediaServerHttp(account).use { http ->
            try {
                val client = EmbyClient(account, http)
                assertTrue(client.probe().isNotBlank())
                val result = client.browse(JSONObject())
                val count = result.getInt("total")
                assertTrue(count >= 0)
                val items = result.getJSONArray("entries")
                if (items.length() > 0) {
                    val id = items.getJSONObject(0).getString("id")
                    assertEquals(id, client.detail(id).getString("id"))
                    HttpRangeStreamSource(account) { EmbyClient(account, it).stream(id) }.use { source ->
                        source.open().use { reader ->
                            val sample = ByteArray(64)
                            assertTrue(reader.read(0, sample, sample.size) > 0)
                            assertTrue(reader.read(source.size / 2, sample, sample.size) > 0)
                        }
                    }
                }
                println("Live Jellyfin: library count=$count; original stream tested=${items.length() > 0}")
            } finally {
                http.bytes(account.endpoint("Sessions/Logout"), 1024, JSONObject())
            }
        }
    }
    @Test fun readOnlyLiveStash() {
        val url = System.getenv("VRPP_STASH_TEST_URL").orEmpty()
        assumeTrue("Optional local Stash integration", url.isNotEmpty())
        val a = MediaServerAccount("live-test", "Stash", MediaServerAccount.address(url), System.getenv("VRPP_STASH_TEST_KEY").orEmpty())
        MediaServerHttp(a).use { http ->
            val client = StashClient(a, http)
            assertTrue(client.probe().isNotEmpty())
            val spriteId = System.getenv("VRPP_STASH_SPRITE_TEST_ID").orEmpty()
            if (spriteId.isNotBlank()) {
                val fallback = client.coverFallback(spriteId)!!
                assertTrue(a.accepts(fallback.uri)); assertTrue(fallback.width > 0 && fallback.height > 0)
                assertTrue(http.bytes(fallback.uri, 16 * 1024 * 1024).size > 1024)
            }
            val result = client.browse(JSONObject().put("page", 1))
            assertTrue(result.getInt("total") > 0)
            val item = result.getJSONArray("entries").getJSONObject(0)
            val detail = client.detail(item.getString("id"))
            assertEquals(item.getString("uri"), detail.getString("uri"))
            assertFalse(detail.toString().contains("apikey=")); assertFalse(detail.has("paths"))
            for (kind in listOf("tags", "performers", "studios")) assertTrue(client.candidates(JSONObject().put("kind", kind)).getInt("total") >= 0)
            HttpRangeStreamSource(a) { transport ->
                val scene = StashClient(a, transport).rawScene(item.getString("id"))
                MediaStreamLink(URI(scene.getJSONObject("paths").getString("stream")), scene.getJSONArray("files").toString())
            }.use { source -> source.open().use { reader ->
                val sample = ByteArray(256)
                assertTrue(reader.read(0, sample, sample.size) > 0)
                assertTrue(reader.read(source.size / 2, sample, sample.size) > 0)
            } }
        }
    }
}
