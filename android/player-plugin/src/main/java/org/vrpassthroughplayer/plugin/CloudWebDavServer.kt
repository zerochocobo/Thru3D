package org.vrpassthroughplayer.plugin

import java.io.BufferedInputStream
import java.io.Closeable
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import javax.xml.parsers.DocumentBuilderFactory

internal class DavEntry(val path: String, val name: String, val folder: Boolean, val size: Long = 0)
internal interface CloudDavFiles {
    fun stat(path: String): DavEntry
    fun list(path: String): List<DavEntry>
    fun source(path: String): StreamSource
}

/** Read-only WebDAV Class 1 subset: authenticated metadata and original-file range reads.
 * One request per connection; bounded headers, bodies, workers and directory depth.
 */
internal class CloudWebDavServer(
    private val files: CloudDavFiles,
    password: String,
    port: Int = 9867,
    bind: InetAddress = InetAddress.getByName("0.0.0.0"),
) : Closeable {
    private val socket = ServerSocket(port, 16, bind)
    val port: Int get() = socket.localPort
    private val authorization = ("Basic " + Base64.getEncoder().encodeToString("quest:$password".toByteArray(Charsets.UTF_8))).toByteArray(Charsets.US_ASCII)
    private val clients = ConcurrentHashMap.newKeySet<Socket>()
    private val sources = ConcurrentHashMap.newKeySet<StreamSource>()
    private val workers = ThreadPoolExecutor(4, 4, 0, TimeUnit.SECONDS, ArrayBlockingQueue(16),
        { work -> Thread(work, "QuestWebDav").apply { isDaemon = true } })
    @Volatile private var closed = false
    init {
        require(password.length >= 16)
        Thread({
            while (!closed) {
                val client = try { socket.accept() } catch (_: Exception) { break }
                if (!client.inetAddress.isSiteLocalAddress && !client.inetAddress.isLoopbackAddress && !client.inetAddress.isLinkLocalAddress) {
                    client.close(); continue
                }
                clients.add(client)
                try { workers.execute { serve(client) } }
                catch (_: Exception) { clients.remove(client); runCatching { client.close() } }
            }
        }, "QuestWebDavAccept").apply { isDaemon = true; start() }
    }
    private fun serve(client: Socket) = client.use {
        var sent = false
        val output = client.getOutputStream()
        try {
            client.soTimeout = 10000
            val input = BufferedInputStream(client.getInputStream())
            val request = line(input).split(' ')
            if (request.size != 3 || request[2] !in setOf("HTTP/1.1", "HTTP/1.0")) return reply(output, 400)
            val headers = HashMap<String, String>()
            var headerBytes = 0
            while (true) {
                val header = line(input)
                headerBytes += header.length
                if (headerBytes > 32768) return reply(output, 431)
                if (header.isEmpty()) break
                val colon = header.indexOf(':')
                if (colon <= 0) return reply(output, 400)
                val name = header.substring(0, colon).lowercase()
                if (headers.put(name, header.substring(colon + 1).trim()) != null) return reply(output, 400)
            }
            val auth = headers["authorization"].orEmpty().toByteArray(Charsets.US_ASCII)
            if (!MessageDigest.isEqual(authorization, auth)) return reply(output, 401, extra = "WWW-Authenticate: Basic realm=\"Quest WebDAV\"\r\n")
            val method = request[0]
            if (method !in setOf("OPTIONS", "PROPFIND", "GET", "HEAD")) return reply(output, 405, extra = "Allow: OPTIONS, PROPFIND, GET, HEAD\r\n")
            if (headers.containsKey("transfer-encoding")) return reply(output, 400)
            val length = headers["content-length"]?.toLongOrNull() ?: if (headers.containsKey("content-length")) -1 else 0
            if (length !in 0..65536) return reply(output, 413)
            if (headers["expect"].equals("100-continue", true)) { output.write("HTTP/1.1 100 Continue\r\n\r\n".toByteArray()); output.flush() }
            val body = ByteArray(length.toInt())
            var received = 0
            while (received < body.size) {
                val count = input.read(body, received, body.size - received)
                if (count < 0) return reply(output, 400)
                received += count
            }
            val path = try { decodePath(request[1]) } catch (_: Exception) { return reply(output, 400) }
            if (method == "OPTIONS") return reply(output, 200, extra = "DAV: 1\r\nAllow: OPTIONS, PROPFIND, GET, HEAD\r\n")
            if (method == "PROPFIND") {
                val depth = headers["depth"] ?: "infinity"
                if (depth !in setOf("0", "1")) return reply(output, 403, "<?xml version=\"1.0\"?><d:error xmlns:d=\"DAV:\"><d:propfind-finite-depth/></d:error>".toByteArray(), "Content-Type: application/xml; charset=utf-8\r\n")
                val props = try { requestedProperties(body) } catch (_: Exception) { return reply(output, 400) }
                val entry = files.stat(path)
                val entries = listOf(entry) + if (depth == "1" && entry.folder) files.list(path) else emptyList()
                val xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><d:multistatus xmlns:d=\"DAV:\">" +
                    entries.joinToString("") { propResponse(it, props) } + "</d:multistatus>"
                return reply(output, 207, xml.toByteArray(Charsets.UTF_8), "Content-Type: application/xml; charset=utf-8\r\nDAV: 1\r\n")
            }
            val entry = files.stat(path)
            if (entry.folder) return reply(output, 405)
            if (entry.size == 0L && !headers.containsKey("range")) return reply(output, 200, extra = "Accept-Ranges: bytes\r\n")
            val range = LocalStreamServer.parseRange(headers["range"], entry.size)
                ?: return reply(output, 416, extra = "Content-Range: bytes */${entry.size}\r\n")
            val (start, end) = range
            val response = "HTTP/1.1 ${if (headers.containsKey("range")) "206 Partial Content" else "200 OK"}\r\n" +
                "Content-Length: ${end - start + 1}\r\nContent-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\n" +
                (if (headers.containsKey("range")) "Content-Range: bytes $start-$end/${entry.size}\r\n" else "") + "Connection: close\r\n\r\n"
            if (method == "HEAD") { output.write(response.toByteArray()); return }
            if (closed || client.isClosed) return
            val source = files.source(path)
            sources.add(source)
            try {
                source.use {
                    if (closed || client.isClosed || source.size != entry.size) throw CloudFailure()
                    it.open().use { reader ->
                        val buffer = ByteArray(256 * 1024)
                        var offset = start
                        val first = reader.read(offset, buffer, minOf(buffer.size.toLong(), end - offset + 1).toInt())
                        if (first <= 0) throw CloudFailure()
                        sent = true; output.write(response.toByteArray())
                        output.write(buffer, 0, first); offset += first
                        while (offset <= end && !closed && !client.isClosed) {
                            val count = reader.read(offset, buffer, minOf(buffer.size.toLong(), end - offset + 1).toInt())
                            if (count <= 0) break
                            output.write(buffer, 0, count); offset += count
                        }
                        output.flush()
                    }
                }
            } finally { sources.remove(source) }
        } catch (error: Exception) {
            if (!sent) runCatching { reply(output, if (error is CloudFailure && error.reason == "cloud_file_missing") 404 else 502) }
        } finally { clients.remove(client) }
    }
    private fun reply(output: OutputStream, status: Int, body: ByteArray = ByteArray(0), extra: String = "") {
        val reason = mapOf(200 to "OK", 207 to "Multi-Status", 400 to "Bad Request", 401 to "Unauthorized", 403 to "Forbidden",
            404 to "Not Found", 405 to "Method Not Allowed", 413 to "Content Too Large", 416 to "Range Not Satisfiable",
            431 to "Request Header Fields Too Large", 502 to "Bad Gateway")[status] ?: "Error"
        output.write("HTTP/1.1 $status $reason\r\n${extra}Content-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
        output.write(body); output.flush()
    }
    private fun line(input: BufferedInputStream): String {
        val result = StringBuilder()
        while (true) {
            val c = input.read()
            if (c < 0 || result.length > 8192) throw CloudFailure()
            if (c == 10) return result.toString().trimEnd('\r')
            result.append(c.toChar())
        }
    }
    fun disconnectClients() {
        clients.toList().forEach { runCatching { it.close() } }
        sources.toList().forEach { runCatching { it.close() } }
    }
    override fun close() {
        closed = true; runCatching { socket.close() }
        disconnectClients(); workers.shutdownNow()
    }
    companion object {
        fun decodePath(target: String): String {
            val uri = URI(target)
            require(target.startsWith('/') && !target.startsWith("//") && uri.rawAuthority == null && uri.rawQuery == null && uri.rawFragment == null)
            require(!Regex("%2f|%5c", RegexOption.IGNORE_CASE).containsMatchIn(uri.rawPath))
            val path = uri.path
            require(path.none { it < ' ' || it == '\u007f' || it == '\\' } && path.split('/').none { it == "." || it == ".." })
            require(!path.contains("//"))
            return path.trimEnd('/').ifEmpty { "/" }
        }
        private fun xml(value: String) = value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&apos;")
        private val supported = listOf("displayname", "resourcetype", "getcontentlength", "getcontenttype")
        private fun requestedProperties(body: ByteArray): List<Pair<String, String>>? {
            if (body.isEmpty()) return null
            // Restrict this tiny DAV request to UTF-8 and reject declarations before parsing;
            // Android's XML implementation does not support every desktop SAX feature.
            val text = String(body, Charsets.UTF_8)
            require('\u0000' !in text && !text.contains("<!DOCTYPE", true) && !text.contains("<!ENTITY", true))
            val factory = DocumentBuilderFactory.newInstance().apply {
                isNamespaceAware = true
                runCatching { setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
                runCatching { setFeature("http://xml.org/sax/features/external-general-entities", false) }
                runCatching { setFeature("http://xml.org/sax/features/external-parameter-entities", false) }
                isExpandEntityReferences = false
            }
            val builder = factory.newDocumentBuilder().apply {
                setEntityResolver { _, _ -> org.xml.sax.InputSource(java.io.StringReader("")) }
            }
            val document = builder.parse(org.xml.sax.InputSource(java.io.StringReader(text)))
            val props = document.getElementsByTagNameNS("DAV:", "prop")
            if (props.length == 0) return null
            val children = props.item(0).childNodes
            return (0 until children.length).map { children.item(it) }.filter { it.nodeType == 1.toShort() }
                .map { it.namespaceURI.orEmpty() to it.localName }.also { require(it.size <= 64) }
        }
        private fun propResponse(entry: DavEntry, requested: List<Pair<String, String>>?): String {
            val href = URI(null, null, entry.path.trimEnd('/') + if (entry.folder) "/" else "", null).toASCIIString()
            val values = mapOf("displayname" to xml(entry.name), "resourcetype" to if (entry.folder) "<d:collection/>" else "",
                "getcontentlength" to if (entry.folder) "0" else "${entry.size}",
                "getcontenttype" to if (entry.folder) "httpd/unix-directory" else "application/octet-stream")
            val properties = requested ?: supported.map { "DAV:" to it }
            val known = properties.filter { it.first == "DAV:" && it.second in supported }
            val unknown = properties - known.toSet()
            var result = "<d:response><d:href>${xml(href)}</d:href><d:propstat><d:prop>" +
                known.joinToString("") { "<d:${it.second}>${values.getValue(it.second)}</d:${it.second}>" } +
                "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>"
            if (unknown.isNotEmpty()) result += "<d:propstat><d:prop>" + unknown.joinToString("") {
                "<${it.second} xmlns=\"${xml(it.first)}\"/>"
            } + "</d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>"
            return result + "</d:response>"
        }
    }
}
