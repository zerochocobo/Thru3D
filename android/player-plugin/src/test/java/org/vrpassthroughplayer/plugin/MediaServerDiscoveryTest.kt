package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.net.HttpURLConnection
import java.net.URL

class MediaServerDiscoveryTest {
    private fun scanner(provider: String) = MediaServerDiscovery { url ->
        object : HttpURLConnection(url) {
            override fun connect() {}
            override fun disconnect() {}
            override fun usingProxy() = false
            override fun getOutputStream() = java.io.ByteArrayOutputStream()
            override fun getResponseCode() = if (provider == "locked") 401 else 200
            override fun getInputStream(): java.io.InputStream {
                assertNull(getRequestProperty("Authorization"))
                assertNull(getRequestProperty("ApiKey"))
                assertFalse(instanceFollowRedirects)
                val body = when {
                    url.path == "/System/Info/Public" && provider == "emby" -> """{"Id":"1","Version":"4","LocalAddresses":[],"RemoteAddresses":[],"ServerName":"NAS"}"""
                    url.path == "/System/Info/Public" && provider == "jellyfin" -> """{"Id":"2","Version":"10","ProductName":"Jellyfin Server"}"""
                    url.path == "/graphql" && provider == "stash" -> """{"data":{"version":{"version":"v0.31"}}}"""
                    url.path == "/api.json" && provider == "xbvr" -> """{"info":{"title":"XBVR API"},"paths":{"/api/scene/list":{}}}"""
                    else -> "<html>Unrelated server</html>"
                }
                return body.byteInputStream()
            }
        }
    }
    @Test fun identifiesAllProvidersWithoutCredentialsOrPortGuessing() {
        for (provider in listOf("emby", "jellyfin", "stash", "xbvr")) scanner(provider).use {
            assertEquals(provider, it.identify("http://192.168.31.185:12345")?.provider)
        }
        scanner("other").use { assertNull(it.identify("http://192.168.31.185:9999")) }
        scanner("locked").use { assertEquals("", it.identify("http://192.168.31.185:9999")?.provider) }
    }
    @Test fun subnetBoundsAndBroadcastValidation() {
        val small = MediaServerDiscovery.Subnet("192.168.31.185", 24)
        assertEquals("192.168.31.255", small.broadcast)
        assertEquals(254, small.hosts().size)
        assertTrue(small.contains("192.168.31.10")); assertFalse(small.contains("192.168.32.10"))
        val large = MediaServerDiscovery.Subnet("10.20.30.40", 16)
        assertTrue(large.limited); assertEquals(254, large.hosts().size)
        assertEquals("10.20.255.255", large.broadcast)
        assertEquals("http://192.168.31.185:1234/emby", MediaServerDiscovery.advertised("http://192.168.31.185:1234/emby/", "192.168.31.185", small))
        for (bad in listOf("https://evil.invalid/", "http://192.168.31.186/", "file:///etc/passwd", "http://user:pass@192.168.31.185/", "http://192.168.31.185/?key=secret"))
            assertNull(MediaServerDiscovery.advertised(bad, "192.168.31.185", small))
    }
    @Test fun closedScanCannotMakeRequests() {
        var requests = 0
        val scanner = MediaServerDiscovery { requests++; throw IllegalStateException() }
        scanner.close()
        assertNull(scanner.identify("http://192.168.31.185:9999"))
        assertEquals(0, requests)
    }
    @Test fun optionalRealServers() {
        val host = System.getenv("VRPP_DISCOVERY_TEST_HOST").orEmpty()
        assumeTrue(host.isNotBlank())
        MediaServerDiscovery().use {
            assertEquals("emby", it.identify("http://$host:8096")?.provider)
            assertEquals("stash", it.identify("http://$host:9999")?.provider)
        }
        MediaServerDiscovery().use {
            val found = java.util.concurrent.CopyOnWriteArrayList<MediaServerDiscovery.Found>()
            // Restrict the integration test to the explicitly supplied machine.
            assertEquals(2, it.scan(MediaServerDiscovery.Subnet(host, 32)) { server -> found.add(server) })
            assertEquals(setOf("emby", "stash"), found.map { server -> server.provider }.toSet())
            assertEquals(2, found.map { server -> server.address }.distinct().size)
        }
    }
}
