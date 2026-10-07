package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.URI
import java.net.URL
import java.net.ServerSocket
import java.net.Socket
import java.io.Closeable
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class CloudStreamSourceTest {
    private val bytes = ByteArray(700000) { (it % 251).toByte() }
    private fun localConnection(uri: URI) = uri.toURL().openConnection() as HttpURLConnection
    // Android's compile classpath omits jdk.httpserver. Keep the fixture as real sockets.
    private class HttpServer private constructor(bind: InetSocketAddress) {
        private val socket = ServerSocket().apply { bind(bind) }
        val address = InetSocketAddress("127.0.0.1", socket.localPort)
        private val routes = HashMap<String, (Exchange) -> Unit>()
        private val workers = Executors.newCachedThreadPool { Thread(it).apply { isDaemon = true } }
        @Volatile private var error: Throwable? = null
        fun createContext(path: String, handle: (Exchange) -> Unit) { routes[path] = handle }
        fun start() {
            workers.execute {
                while (!socket.isClosed) {
                    val client = try { socket.accept() } catch (_: Exception) { break }
                    workers.execute {
                        client.use {
                            try {
                                val reader = it.getInputStream().bufferedReader()
                                val request = reader.readLine().split(' ')
                                val exchange = Exchange(it)
                                while (true) {
                                    val line = reader.readLine() ?: break
                                    if (line.isEmpty()) break
                                    exchange.requestHeaders.add(line.substringBefore(':'), line.substringAfter(':').trim())
                                }
                                routes.getValue(URI(request[1]).path)(exchange)
                            } catch (failure: Throwable) { error = failure }
                        }
                    }
                }
            }
        }
        fun stop(@Suppress("UNUSED_PARAMETER") delay: Int) {
            socket.close(); workers.shutdownNow()
            error?.let { throw AssertionError("HTTP fixture failed", it) }
        }
        class Headers {
            private val values = HashMap<String, String>()
            fun add(key: String, value: String) { values[key.lowercase()] = value }
            fun getFirst(key: String): String? = values[key.lowercase()]
            override fun toString() = values.entries.joinToString("") { "${it.key}: ${it.value}\r\n" }
        }
        class Exchange(private val client: Socket) : Closeable {
            val requestHeaders = Headers()
            val responseHeaders = Headers()
            val responseBody: OutputStream get() = client.getOutputStream()
            fun sendResponseHeaders(status: Int, length: Long) {
                responseBody.write(("HTTP/1.1 $status Fixture\r\nContent-Length: ${maxOf(0, length)}\r\nConnection: close\r\n" + responseHeaders + "\r\n").toByteArray())
            }
            override fun close() { client.close() }
        }
        companion object { fun create(bind: InetSocketAddress, @Suppress("UNUSED_PARAMETER") backlog: Int) = HttpServer(bind) }
    }
    @Test fun sequentialReadsReuseOneConnectionAndSeeksUseCorrectOffsets() {
        val requests = AtomicInteger()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/file") { exchange ->
            requests.incrementAndGet()
            assertEquals("fixture-agent", exchange.requestHeaders.getFirst("User-Agent"))
            assertNull(exchange.requestHeaders.getFirst("Cookie"))
            val start = exchange.requestHeaders.getFirst("Range")!!.removePrefix("bytes=").removeSuffix("-").toInt()
            exchange.responseHeaders.add("Content-Range", "bytes $start-${bytes.lastIndex}/${bytes.size}")
            exchange.sendResponseHeaders(206, (bytes.size - start).toLong())
            runCatching { exchange.responseBody.use { it.write(bytes, start, bytes.size - start) } }
            exchange.close()
        }
        server.start()
        try {
            val source = CloudStreamSource(bytes.size.toLong(), { CloudLink("http://127.0.0.1:${server.address.port}/file") { mapOf("User-Agent" to "fixture-agent") } }, ::localConnection)
            source.use {
                it.open().use { reader ->
                    val buffer = ByteArray(10000)
                    var offset = 100L
                    repeat(5) {
                        val count = reader.read(offset, buffer, buffer.size)
                        assertArrayEquals(bytes.copyOfRange(offset.toInt(), offset.toInt() + count), buffer.copyOf(count))
                        offset += count
                    }
                    assertEquals(1, requests.get())
                    val count = reader.read(600000, buffer, buffer.size)
                    assertArrayEquals(bytes.copyOfRange(600000, 600000 + count), buffer.copyOf(count))
                    assertEquals(2, requests.get())
                }
            }
        } finally { server.stop(0) }
    }
    @Test fun rejectedRangeBecomes502BeforeAnySuccessHeaders() {
        for (kind in listOf("ignored", "wrong-offset", "wrong-size")) {
            val upstream = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
            upstream.createContext("/file") { exchange ->
                if (kind != "ignored") exchange.responseHeaders.add("Content-Range", if (kind == "wrong-offset") "bytes 0-99/100" else "bytes 10-99/101")
                exchange.sendResponseHeaders(if (kind == "ignored") 200 else 206, 100)
                runCatching { exchange.responseBody.use { it.write(ByteArray(100)) } }; exchange.close()
            }
            upstream.start()
            try {
                LocalStreamServer().use { local ->
                    val source = CloudStreamSource(100, { CloudLink("http://127.0.0.1:${upstream.address.port}/file") { emptyMap() } }, ::localConnection)
                    val url = local.publish(source, "file.mp4")
                    val connection = URL(url).openConnection() as HttpURLConnection
                    connection.setRequestProperty("Range", "bytes=10-99")
                    assertEquals(kind, 502, connection.responseCode); connection.disconnect()
                }
            } finally { upstream.stop(0) }
        }
    }
    @Test fun expiredLinkIsRefreshedOnceAndRevocationStopsNewReads() {
        val resolutions = AtomicInteger()
        val upstream = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        upstream.createContext("/expired") { it.sendResponseHeaders(403, -1); it.close() }
        upstream.createContext("/valid") { exchange ->
            exchange.responseHeaders.add("Content-Range", "bytes 0-9/10")
            exchange.sendResponseHeaders(206, 10); exchange.responseBody.use { it.write(ByteArray(10) { 42 }) }; exchange.close()
        }
        upstream.start()
        try {
            val source = CloudStreamSource(10, {
                CloudLink("http://127.0.0.1:${upstream.address.port}/" + if (resolutions.incrementAndGet() == 1) "expired" else "valid") { emptyMap() }
            }, ::localConnection)
            val reader = source.open()
            val data = ByteArray(10)
            assertEquals(10, reader.read(0, data, 10)); assertEquals(2, resolutions.get())
            assertArrayEquals(ByteArray(10) { 42 }, data)
            source.close()
            try { reader.read(0, data, 10); fail() } catch (_: CloudFailure) {}
            try { source.open(); fail() } catch (_: CloudFailure) {}
        } finally { upstream.stop(0) }
    }
}
