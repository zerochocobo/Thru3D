package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.w3c.dom.Document
import org.w3c.dom.Element
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.DatagramPacket
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.Inet4Address
import java.net.MulticastSocket
import java.net.NetworkInterface
import java.net.SocketTimeoutException
import java.net.URL
import java.net.URI
import javax.xml.parsers.DocumentBuilderFactory

/** Minimal UPnP AV client: SSDP discovery of MediaServers and ContentDirectory Browse.
 * Network calls block; run them on a worker. Parsing helpers are pure (JVM tested). */
internal object DlnaClient {
    /** Diagnostics sink (android.util.Log on device; silent in JVM tests). */
    @Volatile var log: (String) -> Unit = {}
    data class Server(val id: String, val name: String, val location: String, val controlUrl: String,
        val serviceType: String = CONTENT_DIRECTORY) {
        fun json(): JSONObject = JSONObject().put("id", id).put("name", name).put("location", location)
            .put("control_url", controlUrl).put("service_type", serviceType)
    }

    private const val CONTENT_DIRECTORY = "urn:schemas-upnp-org:service:ContentDirectory:1"
    private const val SEC = "http://www.sec.co.kr/"
    private const val PV = "http://www.pv.com/pvns/"

    fun address(host: String, port: String, scheme: String = "http"): String {
        val number = port.trim().toIntOrNull()?.takeIf { it in 1..65535 } ?: error("Invalid DLNA port")
        val name = host.trim().removeSurrounding("[", "]")
        if (name.isBlank() || name.any { it.isWhitespace() || it in "/?#@" } || "://" in name) error("Invalid DLNA address")
        val authority = if (':' in name) "[$name]" else name
        return httpUri("$scheme://$authority:$number")?.toString() ?: error("Invalid DLNA address")
    }

    /** A host:port probes common description paths; a full URL is used exactly as supplied. */
    fun descriptionLocations(address: String): List<String> {
        val input = address.trim().let { if ("://" in it) it else "http://$it" }
        val uri = httpUri(input) ?: error("Invalid DLNA address")
        if (uri.rawPath.orEmpty().trim('/').isNotEmpty() || uri.rawQuery != null) return listOf(uri.toString())
        val base = uri.toString().trimEnd('/') + "/"
        return listOf("description.xml", "rootDesc.xml", "DeviceDescription.xml", "", "upnp/desc.xml")
            .map { URI(base).resolve(it).toString() }
    }

    fun connect(address: String): Server {
        for (location in descriptionLocations(address)) {
            runCatching { describe(location, get(location)) }.getOrNull()?.let { return it }
        }
        error("DLNA server unavailable; check the address and port")
    }

    /** Up, non-loopback, multicast-capable interfaces with an IPv4 address (Wi-Fi, Ethernet...). */
    fun lanInterfaces(): List<NetworkInterface> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList().filter {
            it.isUp && !it.isLoopback && it.supportsMulticast() && it.inetAddresses.toList().any { a -> a is Inet4Address }
        }
    }.getOrDefault(emptyList())

    /** SSDP M-SEARCH for [timeoutMs]; returns servers that expose a ContentDirectory. The search goes
     * out on every LAN interface: the default multicast route need not be the Wi-Fi network. */
    fun discover(timeoutMs: Int = 2500): List<Server> {
        val locations = LinkedHashSet<String>()
        MulticastSocket().use { socket ->
            socket.soTimeout = 300
            val group = InetAddress.getByName("239.255.255.250")
            val interfaces: List<NetworkInterface?> = lanInterfaces().ifEmpty { listOf(null) }
            for (lan in interfaces) {
                if (lan != null) runCatching { socket.networkInterface = lan }
                for (target in listOf("urn:schemas-upnp-org:device:MediaServer:1", CONTENT_DIRECTORY)) {
                    val message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: $target\r\n\r\n"
                    val bytes = message.toByteArray()
                    repeat(2) { runCatching { socket.send(DatagramPacket(bytes, bytes.size, group, 1900)) } }
                }
            }
            val deadline = System.currentTimeMillis() + timeoutMs
            val buffer = ByteArray(4096)
            while (System.currentTimeMillis() < deadline) {
                val packet = DatagramPacket(buffer, buffer.size)
                try { socket.receive(packet) } catch (_: SocketTimeoutException) { continue }
                val location = ssdpLocation(String(packet.data, 0, packet.length))
                log("SSDP reply from ${packet.address.hostAddress}: $location")
                location?.let(locations::add)
            }
        }
        log("SSDP: ${locations.size} locations on ${lanInterfaces().map { it.name }}")
        return locations.mapNotNull { location ->
            runCatching { describe(location, get(location)) }
                .onFailure { log("Description failed $location: $it") }
                .onSuccess { log("Description $location -> ${it?.name ?: "no ContentDirectory"}") }
                .getOrNull()
        }.distinctBy { it.id }
    }

    fun ssdpLocation(response: String): String? = response.lineSequence()
        .firstOrNull { it.startsWith("LOCATION:", ignoreCase = true) }?.substringAfter(':')?.trim()?.takeIf { it.startsWith("http") }

    /** Device description -> server with an absolute ContentDirectory control URL, or null. */
    fun describe(location: String, xml: String): Server? {
        val doc = parse(xml)
        val base = doc.getElementsByTagNameNS("*", "URLBase").item(0)?.textContent?.trim()?.takeIf { it.isNotEmpty() } ?: location
        val name = doc.getElementsByTagNameNS("*", "friendlyName").item(0)?.textContent?.trim()?.takeIf { it.isNotEmpty() } ?: location
        val udn = doc.getElementsByTagNameNS("*", "UDN").item(0)?.textContent?.trim()?.takeIf { it.isNotEmpty() } ?: location
        val services = doc.getElementsByTagNameNS("*", "service")
        for (i in 0 until services.length) {
            val service = services.item(i) as Element
            val type = child(service, "serviceType") ?: continue
            if (!type.matches(Regex("urn:schemas-upnp-org:service:ContentDirectory:[1-9][0-9]*"))) continue
            val control = child(service, "controlURL") ?: continue
            val endpoint = httpUri(control, httpUri(base, location)?.toString() ?: location) ?: continue
            return Server(udn, name, location, endpoint.toString(), type)
        }
        return null
    }

    const val MAX_BROWSE_ITEMS = 20_000
    private const val BROWSE_PAGE_SIZE = 1000
    private const val MAX_BROWSE_BYTES = 8 * 1024 * 1024
    private data class BrowsePage(val entries: JSONArray, val ids: List<String>, val total: Int?, val update: String?)

    /** Read the complete level before client-side name sorting. Offsets include unsupported items. */
    fun browse(server: Server, objectId: String, metadata: Boolean = false): JSONArray {
        val deadline = System.nanoTime() + 60_000_000_000L
        if (metadata) return browsePage(server, objectId, 0, true, deadline).entries
        val entries = JSONArray()
        val seen = HashSet<String>()
        var offset = 0
        var total: Int? = null
        var update: String? = null
        while (true) {
            check(!Thread.currentThread().isInterrupted && System.nanoTime() < deadline) { "DLNA server unavailable" }
            val page = browsePage(server, objectId, offset, false, deadline)
            page.total?.let {
                check(total == null || total == it) { "DLNA server unavailable" }
                total = it
            }
            page.update?.let {
                check(update == null || update == it) { "DLNA server unavailable" }
                update = it
            }
            check((total ?: 0) <= MAX_BROWSE_ITEMS && offset + page.ids.size <= MAX_BROWSE_ITEMS) { "Folder too large to sort" }
            // Repeated pages or a changing directory must not produce a partly sorted listing.
            check(page.ids.all { it.isNotBlank() && seen.add(it) }) { "DLNA server unavailable" }
            offset += page.ids.size
            check(total == null || offset <= total!!) { "DLNA server unavailable" }
            for (i in 0 until page.entries.length()) entries.put(page.entries.getJSONObject(i))
            if (total != null && offset == total) return entries
            if (page.ids.isEmpty()) {
                check(total == null) { "DLNA server unavailable" }
                return entries
            }
            // Servers can impose a lower page size, so a short page is not an end marker.
        }
    }

    private fun browsePage(server: Server, objectId: String, offset: Int, metadata: Boolean, deadline: Long): BrowsePage {
        val body = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:Browse xmlns:u="${server.serviceType}"><ObjectID>${escape(objectId)}</ObjectID>
<BrowseFlag>${if (metadata) "BrowseMetadata" else "BrowseDirectChildren"}</BrowseFlag><Filter>*</Filter><StartingIndex>$offset</StartingIndex>
<RequestedCount>$BROWSE_PAGE_SIZE</RequestedCount><SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>"""
        val connection = URL(server.controlUrl).openConnection() as HttpURLConnection
        connection.connectTimeout = 5000; connection.readTimeout = 15000
        connection.requestMethod = "POST"; connection.doOutput = true
        connection.setRequestProperty("Content-Type", "text/xml; charset=\"utf-8\"")
        connection.setRequestProperty("SOAPACTION", "\"${server.serviceType}#Browse\"")
        try {
            connection.outputStream.use { it.write(body.toByteArray()) }
            val response = connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    check(!Thread.currentThread().isInterrupted && System.nanoTime() < deadline) { "DLNA server unavailable" }
                    val count = input.read(buffer)
                    if (count < 0) break
                    check(output.size() + count <= MAX_BROWSE_BYTES) { "Folder too large to sort" }
                    output.write(buffer, 0, count)
                }
                output.toString(Charsets.UTF_8.name())
            }
            check(System.nanoTime() < deadline) { "DLNA server unavailable" }
            val envelope = parse(response)
            fun value(name: String) = envelope.getElementsByTagNameNS("*", name).item(0)?.textContent?.trim()
            fun count(name: String): Int? = value(name)?.let { text ->
                text.toIntOrNull()?.takeIf { it >= 0 } ?: error("DLNA server unavailable")
            }
            val result = value("Result") ?: error("DLNA server unavailable")
            val doc = result.takeIf { it.isNotEmpty() }?.let(::parse)
            val ids = ArrayList<String>()
            for (tag in listOf("container", "item")) {
                val nodes = doc?.getElementsByTagNameNS("*", tag) ?: continue
                for (i in 0 until nodes.length) ids.add((nodes.item(i) as Element).getAttribute("id"))
            }
            check(count("NumberReturned")?.let { it == ids.size } != false) { "DLNA server unavailable" }
            return BrowsePage(doc?.let { didl(it, server.location) } ?: JSONArray(), ids, count("TotalMatches"), value("UpdateID"))
        } finally { connection.disconnect() }
    }

    /** DIDL-Lite -> entries {id, title, container, uri?, size?, duration_ms?, width?, height?}. */
    fun didl(xml: String, base: String = ""): JSONArray = didl(parse(xml), base)

    private fun didl(doc: Document, base: String): JSONArray {
        val out = JSONArray()
        val containers = doc.getElementsByTagNameNS("*", "container")
        for (i in 0 until containers.length) {
            val c = containers.item(i) as Element
            out.put(JSONObject().put("id", c.getAttribute("id")).put("title", title(c)).put("container", true)
                .put("child_count", c.getAttribute("childCount").toIntOrNull() ?: -1))
        }
        val items = doc.getElementsByTagNameNS("*", "item")
        for (i in 0 until items.length) {
            val item = items.item(i) as Element
            val resources = item.getElementsByTagNameNS("*", "res")
            val itemClass = item.getElementsByTagNameNS("*", "class").item(0)?.textContent.orEmpty()
            val imageItem = itemClass.startsWith("object.item.imageItem")
            var chosen: Element? = null
            var largest = -1L
            for (r in 0 until resources.length) {
                val res = resources.item(r) as Element
                val info = res.getAttribute("protocolInfo")
                if (!imageItem && (info.contains(":video/") || isVideoName(res.textContent))) { chosen = res; break }
                if (imageItem && (info.contains(":image/") || MediaKinds.image(res.textContent))) {
                    val dimensions = res.getAttribute("resolution").split('x').mapNotNull { it.toLongOrNull() }
                    val area = if (dimensions.size == 2) dimensions[0] * dimensions[1] else 0L
                    if (area > largest) { chosen = res; largest = area }
                }
            }
            val res = chosen ?: continue
            val entry = JSONObject().put("id", item.getAttribute("id")).put("title", title(item)).put("container", false)
                .put("uri", httpUri(res.textContent.trim(), base)?.toString() ?: res.textContent.trim()).put("kind", if (imageItem) "image" else "video")
            if (!imageItem) entry.put("subtitles", subtitles(item, base))
            res.getAttribute("size").toLongOrNull()?.let { entry.put("size", it) }
            parseDuration(res.getAttribute("duration"))?.let { entry.put("duration_ms", it) }
            res.getAttribute("resolution").split('x').mapNotNull { it.toIntOrNull() }.takeIf { it.size == 2 }?.let {
                entry.put("width", it[0]).put("height", it[1])
            }
            cover(item, resources)?.let { entry.put("cover", it) }
            out.put(entry)
        }
        return out
    }

    fun parseDuration(value: String?): Long? {
        val parts = value?.trim()?.split(':') ?: return null
        if (parts.size != 3) return null
        val h = parts[0].toLongOrNull() ?: return null
        val m = parts[1].toLongOrNull() ?: return null
        val s = parts[2].toDoubleOrNull() ?: return null
        return ((h * 3600 + m * 60) * 1000 + s * 1000).toLong()
    }

    /** Resource links carry languages; SEC/PV usually duplicate the preferred resource. */
    private fun subtitles(item: Element, base: String): JSONArray {
        val found = LinkedHashMap<String, JSONObject>()
        fun add(value: String, type: String = "", language: String = "") {
            val uri = httpUri(value.trim(), base) ?: return
            val extension = subtitleType(type).ifEmpty { subtitleType(uri.path.substringAfterLast('.', "")) }
            if (extension.isEmpty()) return
            val key = subtitleIdentity(uri)
            if (key in found || found.size >= 8) return
            val filename = uri.path.substringAfterLast('/').take(150)
            found[key] = JSONObject().put("url", uri.toString()).put("extension", extension)
                .put("title", if (language.isNotBlank()) "${language.take(40)} · ${extension.uppercase()}" else filename.ifBlank { extension.uppercase() })
        }
        val resources = item.getElementsByTagNameNS("*", "res")
        for (i in 0 until resources.length) {
            val res = resources.item(i) as Element
            val mime = res.getAttribute("protocolInfo").split(':').getOrNull(2).orEmpty()
            if (subtitleType(mime).isNotEmpty() || mime in listOf("text/plain", "application/octet-stream"))
                add(res.textContent, mime, res.getAttributeNS("http://www.w3.org/XML/1998/namespace", "lang"))
        }
        for (tag in listOf("CaptionInfoEx", "CaptionInfo")) {
            val captions = item.getElementsByTagNameNS(SEC, tag)
            for (i in 0 until captions.length) {
                val caption = captions.item(i) as Element
                add(caption.textContent, caption.getAttributeNS(SEC, "type").ifEmpty { caption.getAttribute("type") })
            }
        }
        for (i in 0 until resources.length) {
            val res = resources.item(i) as Element
            add(res.getAttributeNS(PV, "subtitleFileUri"), res.getAttributeNS(PV, "subtitleFileType"))
        }
        return JSONArray(found.values.toList())
    }

    fun subtitleType(type: String): String = when (type.lowercase().substringBefore(';').trim()) {
        "srt", "application/x-subrip", "application/srt", "text/srt", "text/x-srt" -> "srt"
        "ass", "application/x-ass", "text/x-ass" -> "ass"
        "ssa", "application/x-ssa", "text/x-ssa" -> "ssa"
        "vtt", "text/vtt" -> "vtt"
        "smi", "sami", "application/x-sami", "text/smi" -> "smi"
        else -> ""
    }

    private fun subtitleIdentity(uri: URI): String {
        // PTMediaServer's text/srt alternative differs only by this format hint.
        val query = uri.rawQuery.orEmpty().split('&').filter { it.isNotEmpty() && !it.equals("mime=text/srt", true) }
        return uri.toString().substringBefore('?') + if (query.isEmpty()) "" else "?" + query.joinToString("&")
    }

    fun httpUri(value: String, base: String = ""): URI? = runCatching {
        require(value.isNotBlank())
        val uri = if (base.isEmpty()) URI(value) else URI(base).resolve(value)
        require(uri.scheme?.lowercase() in listOf("http", "https") && !uri.host.isNullOrBlank() &&
            uri.rawUserInfo == null && uri.rawFragment == null && uri.port in -1..65535 && uri.port != 0)
        uri
    }.getOrNull()

    /** Header-only servers can advertise the default track without DIDL subtitle resources. */
    fun captionHeader(video: String): JSONArray {
        val url = httpUri(video) ?: return JSONArray()
        val connection = url.toURL().openConnection() as HttpURLConnection
        connection.connectTimeout = 3000; connection.readTimeout = 5000
        connection.requestMethod = "HEAD"
        connection.setRequestProperty("getCaptionInfo.sec", "1")
        return try {
            if (connection.responseCode !in 200..299) return JSONArray()
            val caption = httpUri(connection.getHeaderField("CaptionInfo.sec").orEmpty(), connection.url.toString()) ?: return JSONArray()
            val extension = subtitleType(caption.path.substringAfterLast('.', ""))
            if (extension.isEmpty()) JSONArray() else JSONArray().put(JSONObject().put("url", caption.toString())
                .put("extension", extension).put("title", caption.path.substringAfterLast('/')))
        } finally { connection.disconnect() }
    }

    fun isVideoName(name: String) = name.substringBefore('?').substringAfterLast('.', "").lowercase() in VIDEO_EXTENSIONS
    val VIDEO_EXTENSIONS = setOf("mp4", "mkv", "mov", "m4v", "webm", "ts", "m2ts", "avi", "wmv", "flv", "mpg", "mpeg")

    /** Cover picture the server offers for an item: upnp:albumArtURI, else an image resource
     * (DLNA thumbnail). Never derived from the video itself. */
    private fun cover(item: Element, resources: org.w3c.dom.NodeList): String? {
        val art = item.getElementsByTagNameNS("*", "albumArtURI").item(0)?.textContent?.trim()
        val image = (0 until resources.length).map { resources.item(it) as Element }
            .firstOrNull { it.getAttribute("protocolInfo").contains(":image/") }?.textContent?.trim()
        return listOf(art, image).firstOrNull { !it.isNullOrEmpty() && (it.startsWith("http://") || it.startsWith("https://")) }
    }

    private fun title(element: Element) = element.getElementsByTagNameNS("*", "title").item(0)?.textContent?.trim() ?: ""
    private fun child(element: Element, name: String): String? {
        val nodes = element.getElementsByTagNameNS("*", name)
        return if (nodes.length == 0) null else nodes.item(0).textContent.trim()
    }
    private fun escape(text: String) = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    private fun parse(xml: String) = DocumentBuilderFactory.newInstance().apply {
        isNamespaceAware = true
        // Device descriptions come from the LAN: never resolve external entities. Android's parser
        // rejects unknown features but never fetches external entities either.
        try { setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) } catch (_: Exception) {}
        isExpandEntityReferences = false
    }.newDocumentBuilder().parse(ByteArrayInputStream(xml.toByteArray(Charsets.UTF_8)))

    private fun get(url: String): String {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 3000; connection.readTimeout = 5000
        return try { connection.inputStream.use { it.readBytes().toString(Charsets.UTF_8) } }
        finally { connection.disconnect() }
    }
}
