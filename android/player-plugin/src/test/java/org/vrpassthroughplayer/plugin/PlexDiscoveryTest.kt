package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.net.HttpURLConnection

class PlexDiscoveryTest {
    @Test fun recognizesPublicIdentityWithoutCredentialsAndRejectsDtdOrUnrelatedXml() {
        for ((body, expected) in listOf(
            """<?xml version="1.0"?><MediaContainer machineIdentifier="machine-123" version="1.43" claimed="1"/>""" to "plex",
            """<!DOCTYPE MediaContainer><MediaContainer machineIdentifier="machine" version="1.43"/>""" to null,
            """<MediaContainer size="0"/>""" to null,
            """<html>unrelated</html>""" to null)) {
            MediaServerDiscovery { url -> object : HttpURLConnection(url) {
                override fun connect() {}
                override fun disconnect() {}
                override fun usingProxy() = false
                override fun getOutputStream() = java.io.ByteArrayOutputStream()
                override fun getResponseCode() = 200
                override fun getInputStream(): java.io.InputStream {
                    assertNull(getRequestProperty("X-Plex-Token")); assertNull(getRequestProperty("Authorization"))
                    assertFalse(instanceFollowRedirects)
                    return (if (url.path == "/identity") body else "{}").byteInputStream()
                }
            } }.use { assertEquals(expected, it.identify("http://192.168.31.185:32400")?.provider) }
        }
    }
    @Test fun optionalLiveIdentityAndBoundedScan() {
        assumeTrue(System.getenv("VRPP_PLEX_DISCOVERY_LIVE") == "true")
        MediaServerDiscovery().use { assertEquals("plex", it.identify("http://192.168.31.185:32400")?.provider) }
        MediaServerDiscovery().use { scanner ->
            val found = java.util.concurrent.CopyOnWriteArrayList<MediaServerDiscovery.Found>()
            scanner.scan(MediaServerDiscovery.Subnet("192.168.31.185", 32)) { found.add(it) }
            assertTrue(found.any { it.provider == "plex" && it.address == "http://192.168.31.185:32400" })
        }
    }
}
