package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.net.HttpURLConnection
import java.net.URL

class MediaSourcesTest {
    @Test fun rangeParsing() {
        assertEquals(0L to 99L, LocalStreamServer.parseRange(null, 100))
        assertEquals(10L to 99L, LocalStreamServer.parseRange("bytes=10-", 100))
        assertEquals(10L to 19L, LocalStreamServer.parseRange("bytes=10-19", 100))
        assertEquals(90L to 99L, LocalStreamServer.parseRange("bytes=-10", 100))
        assertEquals(50L to 99L, LocalStreamServer.parseRange("bytes=50-500", 100))
        assertNull(LocalStreamServer.parseRange("bytes=100-", 100))
        assertNull(LocalStreamServer.parseRange("bytes=20-10", 100))
        assertNull(LocalStreamServer.parseRange("items=0-1", 100))
        assertNull(LocalStreamServer.parseRange("bytes=x-1", 100))
    }

    @Test fun loopbackServerServesRanges() {
        val data = ByteArray(1_000_000) { (it * 31 % 251).toByte() }
        val source = object : StreamSource {
            override val size = data.size.toLong()
            override fun open() = object : StreamSource.Reader {
                override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                    val n = minOf(length.toLong(), size - offset).toInt()
                    System.arraycopy(data, offset.toInt(), buffer, 0, n); return n
                }
                override fun close() {}
            }
        }
        LocalStreamServer().use { server ->
            val url = server.publish(source, "a b.mp4")
            assertTrue(url.startsWith("http://127.0.0.1:") && url.endsWith("/a%20b.mp4"))
            val whole = URL(url).openConnection() as HttpURLConnection
            assertEquals(200, whole.responseCode)
            assertArrayEquals(data, whole.inputStream.readBytes())
            val part = URL(url).openConnection() as HttpURLConnection
            part.setRequestProperty("Range", "bytes=999000-")
            assertEquals(206, part.responseCode)
            assertEquals("bytes 999000-999999/1000000", part.getHeaderField("Content-Range"))
            assertArrayEquals(data.copyOfRange(999000, 1000000), part.inputStream.readBytes())
            val bad = URL(url).openConnection() as HttpURLConnection
            bad.setRequestProperty("Range", "bytes=2000000-")
            assertEquals(416, bad.responseCode)
            server.revoke(url)
            assertEquals(404, (URL(url).openConnection() as HttpURLConnection).responseCode)
        }
    }

    @Test fun dlnaDescriptionAndDidl() {
        val description = """<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0">
            <device><friendlyName>NAS 媒体</friendlyName><UDN>uuid:1234</UDN><serviceList>
            <service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><controlURL>/cm</controlURL></service>
            <service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><controlURL>ctl/cd</controlURL></service>
            </serviceList></device></root>"""
        val server = DlnaClient.describe("http://192.168.1.5:8200/rootDesc.xml", description)!!
        assertEquals("NAS 媒体", server.name)
        assertEquals("uuid:1234", server.id)
        assertEquals("http://192.168.1.5:8200/ctl/cd", server.controlUrl)
        assertEquals("http://192.168.1.5:8200/rootDesc.xml",
            DlnaClient.ssdpLocation("HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLocation: http://192.168.1.5:8200/rootDesc.xml\r\n\r\n"))
        val didl = """<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
            <container id="64$1" parentID="64" childCount="3"><dc:title>VR180</dc:title></container>
            <item id="64$1$0"><dc:title>Concert 8K</dc:title>
              <res protocolInfo="http-get:*:image/jpeg:*">http://192.168.1.5:8200/thumb.jpg</res>
              <res protocolInfo="http-get:*:video/mp4:*" size="1234567" duration="0:03:05.500" resolution="8192x4096">http://192.168.1.5:8200/MediaItems/1.mp4</res></item>
            <item id="64$1$1"><dc:title>Song</dc:title><res protocolInfo="http-get:*:audio/mpeg:*">http://192.168.1.5:8200/2.mp3</res></item>
            </DIDL-Lite>"""
        val entries = DlnaClient.didl(didl)
        assertEquals(2, entries.length())
        assertTrue(entries.getJSONObject(0).getBoolean("container"))
        assertEquals(3, entries.getJSONObject(0).getInt("child_count"))
        val video = entries.getJSONObject(1)
        assertEquals("http://192.168.1.5:8200/MediaItems/1.mp4", video.getString("uri"))
        assertEquals(185500L, video.getLong("duration_ms"))
        assertEquals(8192, video.getInt("width"))
        assertEquals(1234567L, video.getLong("size"))
        // The server's thumbnail resource is the cover; the video itself is never read for one.
        assertEquals("http://192.168.1.5:8200/thumb.jpg", video.getString("cover"))
    }

    @Test fun dlnaCoverPrefersAlbumArtAndIsOptional() {
        val didl = """<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
            <item id="1"><dc:title>A</dc:title><upnp:albumArtURI>http://nas:8200/art/1.jpg</upnp:albumArtURI>
              <res protocolInfo="http-get:*:image/jpeg:*">http://nas:8200/thumb/1.jpg</res>
              <res protocolInfo="http-get:*:video/mp4:*">http://nas:8200/1.mp4</res></item>
            <item id="2"><dc:title>B</dc:title><res protocolInfo="http-get:*:video/mp4:*">http://nas:8200/2.mp4</res></item>
            <item id="3"><dc:title>C</dc:title><upnp:albumArtURI>file:///etc/x.jpg</upnp:albumArtURI>
              <res protocolInfo="http-get:*:video/mp4:*">http://nas:8200/3.mp4</res></item>
            </DIDL-Lite>"""
        val entries = DlnaClient.didl(didl)
        assertEquals("http://nas:8200/art/1.jpg", entries.getJSONObject(0).getString("cover"))
        assertFalse(entries.getJSONObject(1).has("cover"))
        assertFalse("only http(s) covers", entries.getJSONObject(2).has("cover"))
    }

    @Test fun videoNames() {
        assertTrue(DlnaClient.isVideoName("a.MKV"))
        assertTrue(DlnaClient.isVideoName("http://x/y.mp4?token=1"))
        assertFalse(DlnaClient.isVideoName("a.srt"))
    }
}
