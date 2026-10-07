package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.net.InetAddress
import java.net.Socket
import java.util.Base64
import java.util.concurrent.atomic.AtomicInteger

class CloudWebDavServerTest {
    private val bytes = ByteArray(10000) { (it % 251).toByte() }
    private val metadata = AtomicInteger()
    private val streams = AtomicInteger()
    private val files = object : CloudDavFiles {
        override fun stat(path: String): DavEntry {
            metadata.incrementAndGet()
            return when (path) {
                "/" -> DavEntry("/", "Cloud", true)
                "/盘" -> DavEntry("/盘", "盘", true)
                "/empty.txt" -> DavEntry(path, "empty.txt", false, 0)
                "/盘/a #?%&.mp4" -> DavEntry(path, "a #?%&.mp4", false, bytes.size.toLong())
                else -> throw CloudFailure("cloud_file_missing")
            }
        }
        override fun list(path: String): List<DavEntry> {
            metadata.incrementAndGet()
            return if (path == "/") listOf(stat("/盘")) else listOf(stat("/盘/a #?%&.mp4"))
        }
        override fun source(path: String): StreamSource {
            streams.incrementAndGet()
            return object : StreamSource {
                override val size = bytes.size.toLong()
                override fun open() = object : StreamSource.Reader {
                    override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                        val count = minOf(length, bytes.size - offset.toInt())
                        bytes.copyInto(buffer, 0, offset.toInt(), offset.toInt() + count); return count
                    }
                    override fun close() {}
                }
            }
        }
    }
    private val password = "fixture-password-12345"
    private val auth get() = "Authorization: Basic " + Base64.getEncoder().encodeToString("quest:$password".toByteArray()) + "\r\n"
    private fun server() = CloudWebDavServer(files, password, 0, InetAddress.getByName("127.0.0.1"))
    private fun request(server: CloudWebDavServer, method: String, path: String = "/", headers: String = "", body: String = "", authorized: Boolean = true): ByteArray =
        Socket("127.0.0.1", server.port).use { socket ->
            socket.soTimeout = 5000
            socket.getOutputStream().write(("$method $path HTTP/1.1\r\nHost: localhost\r\n" + (if (authorized) auth else "") +
                headers + "Content-Length: ${body.toByteArray().size}\r\n\r\n$body").toByteArray())
            socket.getInputStream().readBytes()
        }
    private fun text(bytes: ByteArray) = String(bytes, Charsets.UTF_8)
    @Test fun unauthenticatedAndWriteRequestsNeverReachProviders() = server().use { server ->
        assertTrue(text(request(server, "PROPFIND", authorized = false)).startsWith("HTTP/1.1 401"))
        for (method in listOf("PUT", "DELETE", "MKCOL", "MOVE", "COPY", "PROPPATCH")) {
            assertTrue(text(request(server, method)).startsWith("HTTP/1.1 405"))
        }
        assertEquals(0, metadata.get()); assertEquals(0, streams.get())
        assertTrue(text(request(server, "OPTIONS")).contains("DAV: 1"))
    }
    @Test fun propfindEscapesNamesAndPercentEncodedPathsWithoutVideoReads() = server().use { server ->
        val response = text(request(server, "PROPFIND", "/%E7%9B%98/", "Depth: 1\r\n"))
        assertTrue(response.startsWith("HTTP/1.1 207"))
        assertTrue(response.contains("a #?%&amp;.mp4"))
        assertTrue(response.contains("/%E7%9B%98/a%20%23%3F%25&amp;.mp4"))
        assertTrue(response.contains("<d:collection/>"))
        assertEquals(0, streams.get())
        val explicit = text(request(server, "PROPFIND", headers = "Depth: 0\r\n",
            body = "<d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:unknown/></d:prop></d:propfind>"))
        assertTrue(explicit.contains("HTTP/1.1 404 Not Found"))
        assertTrue(explicit.contains("<d:displayname>Cloud</d:displayname>"))
    }
    @Test fun rangesHeadAndMissingFilesBehaveAsWebDavMediaClientsExpect() = server().use { server ->
        val path = "/%E7%9B%98/a%20%23%3F%25%26.mp4"
        val head = text(request(server, "HEAD", path))
        assertTrue(head.contains("Content-Length: 10000")); assertEquals(0, streams.get())
        val response = request(server, "GET", path, "Range: bytes=9000-9099\r\n")
        val split = String(response, Charsets.ISO_8859_1).indexOf("\r\n\r\n") + 4
        assertTrue(text(response.copyOfRange(0, split)).startsWith("HTTP/1.1 206"))
        assertArrayEquals(bytes.copyOfRange(9000, 9100), response.copyOfRange(split, response.size))
        assertTrue(text(request(server, "GET", path, "Range: bytes=10000-\r\n")).startsWith("HTTP/1.1 416"))
        assertTrue(text(request(server, "GET", "/missing")).startsWith("HTTP/1.1 404"))
        val before = streams.get()
        assertTrue(text(request(server, "GET", "/empty.txt")).startsWith("HTTP/1.1 200"))
        assertTrue(text(request(server, "HEAD", "/empty.txt")).contains("Content-Length: 0"))
        assertEquals(before, streams.get())
    }
    @Test fun rejectsTraversalInfiniteDepthAndEntityDeclarations() = server().use { server ->
        for (path in listOf("/%2e%2e/secret", "/a%2fb", "//evil/path", "/a%5Cb", "/a?token=x")) {
            assertTrue(path, text(request(server, "GET", path)).startsWith("HTTP/1.1 400"))
        }
        assertTrue(text(request(server, "PROPFIND")).startsWith("HTTP/1.1 403"))
        val xml = "<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///secret'>]><x>&e;</x>"
        assertTrue(text(request(server, "PROPFIND", headers = "Depth: 1\r\n", body = xml)).startsWith("HTTP/1.1 400"))
        assertEquals(0, metadata.get())
        assertEquals("/literal%2F.mp4", CloudWebDavServer.decodePath("/literal%252F.mp4"))
    }
}
