package org.vrpassthroughplayer.plugin

import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.ConcurrentHashMap

/** Reuses one upstream range stream per MPV connection, never buffers the whole video. */
internal class CloudStreamSource(
    override val size: Long,
    private val resolve: () -> CloudLink,
    private val connect: (URI) -> HttpURLConnection = ::openMediaConnection,
) : StreamSource {
    @Volatile private var link: CloudLink? = null
    private var resolvedAt = 0L
    @Volatile private var closed = false
    private val readers = ConcurrentHashMap.newKeySet<RemoteReader>()

    fun prepare() { currentLink() }
    @Synchronized private fun currentLink(failed: CloudLink? = null): CloudLink {
        if (closed) throw CloudFailure()
        if (link == null || failed === link || System.nanoTime() - resolvedAt > 300_000_000_000L) {
            val resolved = resolve()
            if (closed) throw CloudFailure()
            link = resolved; resolvedAt = System.nanoTime()
        }
        return link!!
    }
    override fun open(): StreamSource.Reader = synchronized(this) {
        if (closed) throw CloudFailure()
        RemoteReader().also { readers.add(it) }
    }
    override fun close() {
        closed = true
        readers.toList().forEach { it.close() }
        link = null
    }

    private inner class RemoteReader : StreamSource.Reader {
        @Volatile private var done = false
        @Volatile private var connection: HttpURLConnection? = null
        private var input: InputStream? = null
        private var next = -1L
        private var end = -1L

        override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
            try {
                if (closed || done || Thread.currentThread().isInterrupted) throw CloudFailure()
                require(offset in 0 until size && length in 1..buffer.size)
                if (offset != next || offset > end || input == null) openRange(offset)
                val count = input!!.read(buffer, 0, minOf(length.toLong(), end - offset + 1).toInt())
                if (count <= 0) throw CloudFailure()
                next = offset + count
                return count
            } catch (_: Exception) {
                close()
                throw CloudFailure()
            }
        }

        private fun openRange(offset: Long) {
            disconnect()
            var selected = currentLink()
            for (attempt in 0..1) {
                var target = URI(selected.url)
                for (redirect in 0..5) {
                    if (closed || done || Thread.currentThread().isInterrupted) throw CloudFailure()
                    val request = connect(target)
                    synchronized(this) {
                        if (closed || done) { request.disconnect(); throw CloudFailure() }
                        connection = request
                    }
                    request.connectTimeout = 15000; request.readTimeout = 20000
                    request.instanceFollowRedirects = false; request.useCaches = false
                    request.setRequestProperty("Accept-Encoding", "identity")
                    selected.headers(target).forEach { (name, value) -> request.setRequestProperty(name, value) }
                    request.setRequestProperty("Range", "bytes=$offset-")
                    val status = request.responseCode
                    if (status in setOf(301, 302, 303, 307, 308)) {
                        val location = request.getHeaderField("Location") ?: throw CloudFailure()
                        target = target.resolve(location)
                        disconnect()
                        continue
                    }
                    if (status in setOf(401, 403, 410) && attempt == 0) {
                        disconnect(); selected = currentLink(selected)
                        break
                    }
                    if (status == 206) {
                        val match = Regex("bytes (\\d+)-(\\d+)/(\\d+)").matchEntire(request.getHeaderField("Content-Range") ?: "") ?: throw CloudFailure()
                        val start = match.groupValues[1].toLong()
                        end = match.groupValues[2].toLong()
                        if (start != offset || end < offset || end >= size || match.groupValues[3].toLong() != size) throw CloudFailure()
                        val length = request.getHeaderField("Content-Length")?.toLongOrNull()
                        if (length != null && length != end - offset + 1) throw CloudFailure()
                    } else if (status == 200 && offset == 0L && request.getHeaderField("Content-Length")?.toLongOrNull() == size) {
                        end = size - 1
                    } else throw CloudFailure()
                    val type = request.contentType.orEmpty().lowercase()
                    if (type.contains("text/html") || type.contains("application/json")) throw CloudFailure()
                    input = request.inputStream
                    next = offset
                    return
                }
            }
            throw CloudFailure()
        }
        private fun disconnect() {
            // Disconnect first to unblock a pending read during logout or player shutdown.
            connection?.disconnect(); connection = null
            runCatching { input?.close() }; input = null
        }
        override fun close() {
            synchronized(this) { done = true; disconnect() }
            readers.remove(this)
        }
    }
    companion object {
        private fun openMediaConnection(uri: URI): HttpURLConnection {
            if (!CloudDrive.allowedMediaUri(uri)) throw CloudFailure()
            return uri.toURL().openConnection() as HttpURLConnection
        }
    }
}
