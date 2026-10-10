package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.io.Closeable
import java.net.*
import java.util.concurrent.*

/** Credential-free, bounded discovery. HTTP redirects and advertised foreign hosts are not followed. */
internal class MediaServerDiscovery(
    private val open: (URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection },
) : Closeable {
    data class Found(val address: String, val provider: String, val name: String)
    data class Subnet(val address: String, val prefix: Int) {
        private val ip = number(address)
        private val bits = prefix.coerceIn(0, 32)
        private val mask = if (bits == 0) 0L else (0xffffffffL shl (32 - bits)) and 0xffffffffL
        fun contains(value: String) = runCatching { (number(value) and mask) == (ip and mask) }.getOrDefault(false)
        val broadcast: String get() = dotted((ip and mask) or (mask xor 0xffffffffL))
        val limited: Boolean get() = bits < 24
        fun hosts(): List<String> {
            // Large networks get a bounded nearby /24, not a blind /16 scan.
            val scanMask = if (bits < 24) 0xffffff00L else mask
            val first = ip and scanMask
            val last = first or (scanMask xor 0xffffffffL)
            return if (bits >= 31) (first..last).map(::dotted) else ((first + 1) until last).map(::dotted)
        }
        companion object {
            fun number(value: String): Long {
                val parts = value.split('.')
                require(parts.size == 4)
                return parts.fold(0L) { n, s -> val part = s.toInt(); require(part in 0..255); (n shl 8) or part.toLong() }
            }
            fun dotted(value: Long) = (3 downTo 0).joinToString(".") { ((value shr (it * 8)) and 255).toString() }
        }
    }
    private val connections = ConcurrentHashMap.newKeySet<HttpURLConnection>()
    private val found = ConcurrentHashMap<String, Found>()
    private val pool = Executors.newFixedThreadPool(24)
    @Volatile private var closed = false
    @Volatile private var udp: DatagramSocket? = null
    private data class Response(val status: Int, val text: String)
    private fun request(address: String, path: String, body: String? = null): Response? {
        if (closed || Thread.currentThread().isInterrupted) return null
        val connection = open(URL(address.trimEnd('/') + path))
        synchronized(this) { if (closed) { connection.disconnect(); return null }; connections.add(connection) }
        return try {
            connection.connectTimeout = 350; connection.readTimeout = 600; connection.instanceFollowRedirects = false
            connection.useCaches = false
            if (body != null) {
                connection.requestMethod = "POST"; connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                val bytes = body.toByteArray(Charsets.UTF_8); connection.setFixedLengthStreamingMode(bytes.size)
                connection.outputStream.use { it.write(bytes) }
            }
            val code = connection.responseCode
            val content = if (code == 200) connection.inputStream.use { stream ->
                val bytes = java.io.ByteArrayOutputStream(); val buffer = ByteArray(4096)
                while (!closed && bytes.size() < 256 * 1024) {
                    val size = stream.read(buffer, 0, minOf(buffer.size, 256 * 1024 - bytes.size()))
                    if (size < 0) break
                    bytes.write(buffer, 0, size)
                }
                bytes.toString("UTF-8")
            } else ""
            Response(code, content)
        } catch (_: Exception) { null } finally { connections.remove(connection); connection.disconnect() }
    }
    private fun identifyPlex(address: String): Found? {
        val identity = request(address, "/identity")
        val text = identity?.text.orEmpty()
        // Identity is public; reject DTDs and only recognize Plex's bounded identity document.
        val plex = text.length < 8192 && !text.contains("<!DOCTYPE", true) &&
            Regex("<MediaContainer\\b").containsMatchIn(text) &&
            Regex("machineIdentifier=\"[A-Za-z0-9-]{1,64}\"").containsMatchIn(text) &&
            Regex("version=\"[^\"]{1,80}\"").containsMatchIn(text)
        if (identity?.status == 200 && plex) return Found(address, "plex", "Plex")
        return null
    }
    fun identify(address: String): Found? {
        val info = request(address, "/System/Info/Public") ?: return null
        val data = runCatching { JSONObject(info.text) }.getOrNull()
        if (data != null && data.has("Id") && data.has("Version")) {
            val product = data.optString("ProductName")
            val provider = when {
                product.contains("Jellyfin", true) -> "jellyfin"
                product.contains("Emby", true) || (data.optJSONArray("LocalAddresses") != null && data.optJSONArray("RemoteAddresses") != null) -> "emby"
                else -> ""
            }
            return Found(address, provider, data.optString("ServerName").take(80))
        }
        identifyPlex(address)?.let { return it }
        val graph = request(address, "/graphql", JSONObject().put("query", "query { version { version } }").toString())
        val version = runCatching { JSONObject(graph?.text.orEmpty()).getJSONObject("data").getJSONObject("version").getString("version") }.getOrNull()
        if (!version.isNullOrBlank()) return Found(address, "stash", "Stash")
        val api = request(address, "/api.json")
        val schema = runCatching { JSONObject(api?.text.orEmpty()) }.getOrNull()
        if (schema?.optJSONObject("info")?.optString("title")?.contains("XBVR", true) == true &&
            schema.optJSONObject("paths")?.has("/api/scene/list") == true) return Found(address, "xbvr", "XBVR")
        if (listOf(info.status, graph?.status, api?.status).any { it == 401 || it == 403 }) return Found(address, "", "")
        return null
    }
    fun scan(subnet: Subnet, onFound: (Found) -> Unit): Int {
        fun publish(item: Found) {
            if (!closed && found.putIfAbsent(item.address, item) == null) onFound(item)
        }
        val tasks = ArrayList<Callable<Unit>>()
        tasks.add(Callable {
            val socket = DatagramSocket(InetSocketAddress(subnet.address, 0))
            synchronized(this) { if (closed) { socket.close(); return@Callable }; udp = socket }
            try {
                socket.broadcast = true; socket.soTimeout = 500
                for (query in listOf("who is EmbyServer?", "who is JellyfinServer?")) {
                    val bytes = query.toByteArray()
                    socket.send(DatagramPacket(bytes, bytes.size, InetAddress.getByName(subnet.broadcast), 7359))
                }
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
                while (!closed && System.nanoTime() < deadline) {
                    val packet = DatagramPacket(ByteArray(8192), 8192)
                    try { socket.receive(packet) } catch (_: SocketTimeoutException) { continue }
                    val payload = JSONObject(String(packet.data, 0, packet.length, Charsets.UTF_8))
                    val address = advertised(payload.optString("Address"), packet.address.hostAddress.orEmpty(), subnet) ?: continue
                    identify(address)?.let(::publish)
                }
            } catch (_: Exception) { } finally { socket.close(); udp = null }
        })
        for (port in listOf(32400, 8096, 9999)) for (host in subnet.hosts()) tasks.add(Callable {
            if (!closed) (if (port == 32400) identifyPlex("http://$host:$port") else identify("http://$host:$port"))?.let(::publish)
        })
        try { pool.invokeAll(tasks, 12, TimeUnit.SECONDS) } finally { close() }
        return found.size
    }
    override fun close() {
        synchronized(this) { closed = true; udp?.close(); connections.forEach { it.disconnect() }; connections.clear() }
        pool.shutdownNow()
    }
    companion object {
        fun advertised(raw: String, sender: String, subnet: Subnet): String? = runCatching {
            val uri = URI(raw)
            // Numeric, on-link, originating host only. Never probe an arbitrary advertised URL.
            if (uri.scheme !in setOf("http", "https") || uri.host != sender || !subnet.contains(sender) || uri.userInfo != null ||
                uri.query != null || uri.fragment != null || uri.port !in -1..65535) return null
            raw.trimEnd('/')
        }.getOrNull()
    }
}
