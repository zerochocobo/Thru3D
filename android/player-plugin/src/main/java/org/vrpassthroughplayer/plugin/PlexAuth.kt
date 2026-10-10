package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.net.URI

/** PIN approval stays on Plex. Only the selected server's token is persisted by AccountManager. */
internal class PlexAuth(private val clientId: String, private val origin: String = "https://plex.tv") : Closeable {
    private val account = MediaServerAccount(clientId, "Plex", origin, "", "plex")
    private val http = MediaServerHttp(account)
    private val scopes = java.util.concurrent.ConcurrentHashMap.newKeySet<MediaServerHttp>()
    @Volatile private var closed = false
    private fun <T> scope(value: MediaServerAccount, connectTimeoutMs: Int = 10000, readTimeoutMs: Int = 15000,
        work: (MediaServerHttp) -> T): T {
        val scope = MediaServerHttp(value, connectTimeoutMs, readTimeoutMs)
        scopes.add(scope)
        try { mediaRequire(!closed, "Request cancelled"); return work(scope) }
        finally { scopes.remove(scope); scope.close() }
    }
    data class Pin(val id: String, val code: String, val expiresIn: Int) {
        fun link() = "https://plex.tv/link/?" + mediaQuery(mapOf("pin" to code))
    }
    data class Connection(val base: String, val local: Boolean, val relay: Boolean, val address: String = "")
    data class Server(val id: String, val name: String, val token: String, val connections: List<Connection>,
        val httpsRequired: Boolean = false) {
        fun publicJson() = JSONObject().put("id", id).put("name", name)
    }
    fun createPin(): Pin {
        val data = JSONObject(String(http.bytes(account.endpoint("api/v2/pins"), 256 * 1024, method = "POST"), Charsets.UTF_8))
        val id = PlexClient.numeric(data.optString("id")); val code = data.getString("code")
        mediaRequire(code.matches(Regex("[A-Za-z0-9]{4}")), "Invalid server response")
        return Pin(id, code, data.optInt("expiresIn", 300).coerceIn(1, 1800))
    }
    fun poll(pin: Pin): String? {
        val data = JSONObject(String(http.bytes(account.endpoint("api/v2/pins/${PlexClient.numeric(pin.id)}"), 256 * 1024), Charsets.UTF_8))
        mediaRequire(data.optString("id") == pin.id && data.optString("code") == pin.code, "Invalid server response")
        return if (data.isNull("authToken")) null else data.optString("authToken").takeIf { it.isNotBlank() }
    }
    fun confirm(pin: Pin): String = try {
        poll(pin) ?: throw MediaServerFailure("Pairing not completed")
    } catch (error: MediaServerFailure) {
        if (error.httpStatus in setOf(404, 410)) throw MediaServerFailure("Pairing code expired")
        throw error
    }
    fun servers(token: String): List<Server> = scope(account.copy(key = token)) { authenticated ->
        parseServers(JSONArray(String(authenticated.bytes(account.endpoint("api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=1"),
            4 * 1024 * 1024), Charsets.UTF_8)))
    }
    /** A manual address must identify a resource belonging to this authorized account before receiving a token. */
    fun identify(base: String, connectTimeoutMs: Int = 10000, readTimeoutMs: Int = 15000): String =
        scope(account.copy(base = MediaServerAccount.address(base)), connectTimeoutMs, readTimeoutMs) {
        PlexClient.container(it.bytes(URI(MediaServerAccount.address(base) + "/identity"), 256 * 1024)).getString("machineIdentifier")
    }
    fun probe(value: MediaServerAccount): MediaServerAccount = scope(value, 2500, 3000) {
        PlexClient(value, it).probe(); value
    }
    fun cancelProbes() { java.util.ArrayList(scopes).forEach { it.close() } }
    override fun close() { closed = true; http.close(); cancelProbes() }
    companion object {
        fun parseServers(data: JSONArray): List<Server> = data.objects().filter {
            it.optString("provides").split(',').contains("server") && it.optString("accessToken").isNotBlank()
        }.take(64).mapNotNull { server ->
            val id = server.optString("clientIdentifier")
            if (!id.matches(Regex("[A-Za-z0-9-]{1,64}"))) return@mapNotNull null
            val httpsRequired = server.optBoolean("httpsRequired")
            val connections = (server.optJSONArray("connections") ?: JSONArray()).objects().flatMap connection@ { connection ->
                val base = runCatching { MediaServerAccount.address(connection.getString("uri")) }.getOrNull() ?: return@connection emptyList()
                val uri = URI(base); val host = uri.host
                // An address published for the server must not resolve to the headset's loopback.
                if (host.equals("localhost", true) || host.startsWith("127.") || host in setOf("[::1]", "::1", "0.0.0.0")) return@connection emptyList()
                val address = ipv4(connection.optString("address")).ifBlank { ipv4(host) }.ifBlank {
                    val encoded = Regex("^([0-9]{1,3}(?:-[0-9]{1,3}){3})\\.[a-fA-F0-9]{32}\\.plex\\.direct$").matchEntire(host)
                    ipv4(encoded?.groupValues?.get(1).orEmpty().replace('-', '.'))
                }
                if (address.startsWith("127.") || address == "0.0.0.0" || connection.optString("address") in setOf("::1", "[::1]")) return@connection emptyList()
                val local = connection.optBoolean("local"); val relay = connection.optBoolean("relay")
                val result = ArrayList<Connection>()
                if (!httpsRequired || uri.scheme == "https") result.add(Connection(base, local, relay, address))
                // Plex supplies IP/port separately from the secure plex.direct URI. Use its
                // LAN endpoint only when this server permits HTTP; never bypass TLS validation.
                val port = connection.optInt("port", uri.port)
                if (!httpsRequired && local && !relay && privateIpv4(address) && port in 1..65535 &&
                    (host.endsWith(".plex.direct", true) || host == address)) {
                    result.add(Connection("http://$address:$port", true, false, address))
                }
                result
            }.distinctBy { it.base }.sortedWith(compareBy<Connection> { it.relay }.thenBy { !it.local }.thenBy { !it.base.startsWith("https://") })
            Server(id, server.optString("name", "Plex").take(80), server.getString("accessToken"), connections, httpsRequired)
        }
        private fun ipv4(value: String): String = if (value.matches(Regex("[0-9]{1,3}(\\.[0-9]{1,3}){3}")))
            runCatching { MediaServerDiscovery.Subnet.dotted(MediaServerDiscovery.Subnet.number(value)) }.getOrDefault("") else ""
        private fun privateIpv4(value: String): Boolean {
            val bytes = value.split('.').map { it.toIntOrNull() ?: return false }
            return bytes.size == 4 && (bytes[0] == 10 || (bytes[0] == 172 && bytes[1] in 16..31) || (bytes[0] == 192 && bytes[1] == 168))
        }
        fun preferredConnections(connections: List<Connection>, subnets: List<MediaServerDiscovery.Subnet>): List<Connection> =
            connections.sortedWith(compareBy<Connection> {
                when { it.relay -> 3; !it.local -> 2; subnets.any { subnet -> subnet.contains(it.address) } -> 0; else -> 1 }
            }.thenBy { !it.base.startsWith("https://") })
    }
}
