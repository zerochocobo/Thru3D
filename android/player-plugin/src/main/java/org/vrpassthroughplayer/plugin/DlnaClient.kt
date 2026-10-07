package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.w3c.dom.Element
import java.io.ByteArrayInputStream
import java.net.DatagramPacket
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.Inet4Address
import java.net.MulticastSocket
import java.net.NetworkInterface
import java.net.SocketTimeoutException
import java.net.URL
import javax.xml.parsers.DocumentBuilderFactory

/** Minimal UPnP AV client: SSDP discovery of MediaServers and ContentDirectory Browse.
 * Network calls block; run them on a worker. Parsing helpers are pure (JVM tested). */
internal object DlnaClient {
    /** Diagnostics sink (android.util.Log on device; silent in JVM tests). */
    @Volatile var log: (String) -> Unit = {}
    data class Server(val id: String, val name: String, val location: String, val controlUrl: String) {
        fun json(): JSONObject = JSONObject().put("id", id).put("name", name).put("location", location).put("control_url", controlUrl)
    }

    private const val CONTENT_DIRECTORY = "urn:schemas-upnp-org:service:ContentDirectory:1"

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
        val base = doc.getElementsByTagName("URLBase").item(0)?.textContent?.trim()?.takeIf { it.isNotEmpty() } ?: location
        val name = doc.getElementsByTagName("friendlyName").item(0)?.textContent?.trim() ?: location
        val udn = doc.getElementsByTagName("UDN").item(0)?.textContent?.trim() ?: location
        val services = doc.getElementsByTagName("service")
        for (i in 0 until services.length) {
            val service = services.item(i) as Element
            val type = child(service, "serviceType") ?: continue
            if (!type.startsWith("urn:schemas-upnp-org:service:ContentDirectory:")) continue
            val control = child(service, "controlURL") ?: continue
            return Server(udn, name, location, URL(URL(base), control).toString())
        }
        return null
    }

    /** One level of a container: containers first, then playable video items. */
    fun browse(server: Server, objectId: String): JSONArray {
        val body = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:Browse xmlns:u="$CONTENT_DIRECTORY"><ObjectID>${escape(objectId)}</ObjectID>
<BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>0</StartingIndex>
<RequestedCount>1000</RequestedCount><SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>"""
        val connection = URL(server.controlUrl).openConnection() as HttpURLConnection
        connection.connectTimeout = 5000; connection.readTimeout = 15000
        connection.requestMethod = "POST"; connection.doOutput = true
        connection.setRequestProperty("Content-Type", "text/xml; charset=\"utf-8\"")
        connection.setRequestProperty("SOAPACTION", "\"$CONTENT_DIRECTORY#Browse\"")
        connection.outputStream.use { it.write(body.toByteArray()) }
        val response = connection.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
        val result = parse(response).getElementsByTagName("Result").item(0)?.textContent ?: return JSONArray()
        return didl(result)
    }

    /** DIDL-Lite -> entries {id, title, container, uri?, size?, duration_ms?, width?, height?}. */
    fun didl(xml: String): JSONArray {
        val doc = parse(xml)
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
                .put("uri", res.textContent.trim()).put("kind", if (imageItem) "image" else "video")
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
        val nodes = element.getElementsByTagName(name)
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
        return connection.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
    }
}
