package org.vrpassthroughplayer.plugin

import java.io.BufferedInputStream
import java.io.Closeable
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLEncoder
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/** Random-access byte source (SMB or cloud). Each HTTP connection opens its own reader. */
internal interface StreamSource : Closeable {
    val size: Long
    fun open(): Reader
    override fun close() {}
    interface Reader : Closeable { fun read(offset: Long, buffer: ByteArray, length: Int): Int }
}

/** Loopback-only HTTP/1.1 server that lets MPV/FFmpeg read network files with seeks
 * (Range requests). Paths are unguessable tokens; nothing listens beyond 127.0.0.1. */
internal class LocalStreamServer : Closeable {
    private val socket = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
    private val sources = ConcurrentHashMap<String, StreamSource>()
    private val clients = ConcurrentHashMap.newKeySet<Socket>()
    private val pool = Executors.newCachedThreadPool { Thread(it, "QuestStreamServer").apply { isDaemon = true } }
    private val random = SecureRandom()
    @Volatile private var closed = false

    init {
        pool.execute {
            while (!closed) {
                val client = try { socket.accept() } catch (_: Throwable) { break }
                clients.add(client)
                pool.execute { serve(client) }
            }
        }
    }

    /** Returns http://127.0.0.1:port/<token>/<name> for MPV; the name only helps container probing. */
    fun publish(source: StreamSource, name: String): String {
        val token = ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it) }
        sources[token] = source
        return "http://127.0.0.1:${socket.localPort}/$token/${URLEncoder.encode(name, "UTF-8").replace("+", "%20")}"
    }

    fun revoke(url: String) { sources.remove(url.substringAfter(":${socket.localPort}/").substringBefore('/'))?.close() }

    private fun serve(client: Socket) = client.use {
        try {
            client.soTimeout = 30_000
            val input = BufferedInputStream(client.getInputStream())
            val request = readLine(input) ?: return
            val headers = HashMap<String, String>()
            while (true) {
                val line = readLine(input) ?: return
                if (line.isEmpty()) break
                val colon = line.indexOf(':')
                if (colon > 0) headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
            }
            val parts = request.split(' ')
            val output = client.getOutputStream()
            if (parts.size < 3 || parts[0] !in setOf("GET", "HEAD")) return respond(output, 405, "Method Not Allowed")
            val source = sources[parts[1].trimStart('/').substringBefore('/')] ?: return respond(output, 404, "Not Found")
            val range = parseRange(headers["range"], source.size) ?: return respond(output, 416, "Range Not Satisfiable",
                "Content-Range: bytes */${source.size}\r\n")
            val (start, end) = range
            val partial = headers.containsKey("range")
            val head = StringBuilder()
                .append("HTTP/1.1 ").append(if (partial) "206 Partial Content" else "200 OK").append("\r\n")
                .append("Content-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\n")
                .append("Content-Length: ").append(end - start + 1).append("\r\n")
            if (partial) head.append("Content-Range: bytes ").append(start).append('-').append(end).append('/').append(source.size).append("\r\n")
            val responseHead = head.append("Connection: close\r\n\r\n").toString().toByteArray()
            if (parts[0] == "HEAD") { output.write(responseHead); return }
            val opened = try { source.open() } catch (_: Exception) { return respond(output, 502, "Bad Gateway") }
            opened.use { reader ->
                val buffer = ByteArray(512 * 1024)
                var offset = start
                // Validate the upstream status/range before committing a successful HTTP response.
                val first = try { reader.read(offset, buffer, minOf(buffer.size.toLong(), end - offset + 1).toInt()) }
                    catch (_: Exception) { return respond(output, 502, "Bad Gateway") }
                if (first <= 0) return respond(output, 502, "Bad Gateway")
                output.write(responseHead)
                output.write(buffer, 0, first); offset += first
                while (offset <= end && !closed) {
                    val count = reader.read(offset, buffer, minOf(buffer.size.toLong(), end - offset + 1).toInt())
                    if (count <= 0) break
                    output.write(buffer, 0, count)
                    offset += count
                }
                output.flush()
            }
        } catch (_: Throwable) {
            // Client seeks close connections mid-body; that is normal for MPV.
        } finally { clients.remove(client) }
    }

    private fun respond(output: OutputStream, code: Int, text: String, extra: String = "") {
        output.write("HTTP/1.1 $code $text\r\n${extra}Content-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
    }

    private fun readLine(input: BufferedInputStream): String? {
        val line = StringBuilder()
        while (true) {
            val c = input.read()
            if (c < 0) return if (line.isEmpty()) null else line.toString()
            if (c == '\n'.code) return line.toString().trimEnd('\r')
            if (line.length > 8192) return null
            line.append(c.toChar())
        }
    }

    override fun close() {
        closed = true
        try { socket.close() } catch (_: Throwable) {}
        pool.shutdownNow()
        clients.toList().forEach { runCatching { it.close() } }; clients.clear()
        sources.values.forEach { runCatching { it.close() } }
        sources.clear()
    }

    companion object {
        /** Inclusive [start, end] for a single "bytes=" range, whole file when absent; null if unsatisfiable. */
        fun parseRange(header: String?, size: Long): Pair<Long, Long>? {
            if (size <= 0) return null
            if (header == null) return 0L to size - 1
            if (',' in header) return null
            val spec = header.trim().removePrefix("bytes=").trim()
            val dash = spec.indexOf('-')
            if (!header.trim().startsWith("bytes=") || dash < 0) return null
            val first = spec.substring(0, dash).trim(); val last = spec.substring(dash + 1).trim()
            return try {
                if (first.isEmpty()) {
                    val suffix = last.toLong()
                    if (suffix <= 0) null else maxOf(0L, size - suffix) to size - 1
                } else {
                    val start = first.toLong()
                    val end = if (last.isEmpty()) size - 1 else minOf(last.toLong(), size - 1)
                    if (start < 0 || start >= size || start > end) null else start to end
                }
            } catch (_: NumberFormatException) { null }
        }
    }
}
