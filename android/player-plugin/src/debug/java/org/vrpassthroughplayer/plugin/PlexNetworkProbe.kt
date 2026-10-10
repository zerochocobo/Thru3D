package org.vrpassthroughplayer.plugin

import android.content.Context
import android.net.ConnectivityManager
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.Inet4Address
import java.util.UUID

/** Token-free network diagnostics using exactly the production parser and selector. */
internal object PlexNetworkProbe {
    fun run(context: Context, request: String, raw: String): JSONObject {
        require(raw.length <= 16384)
        val server = PlexAuth.parseServers(JSONArray(raw)).single()
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val subnets = manager.activeNetwork?.let { manager.getLinkProperties(it) }?.linkAddresses.orEmpty()
            .filter { it.address is Inet4Address }.map { MediaServerDiscovery.Subnet(it.address.hostAddress!!, it.prefixLength) }
        val connections = PlexAuth.preferredConnections(server.connections, subnets)
        val attempts = JSONArray(); val report = JSONObject().put("request", request)
        val started = System.nanoTime()
        PlexAuth(UUID.randomUUID().toString()).use { auth ->
            try {
                val selected = PlexConnectionSelector.select(connections, { false }, { auth.cancelProbes() }) { connection ->
                    val begin = System.nanoTime()
                    try {
                        mediaRequire(auth.identify(connection.base, 2500, 3000) == server.id, "Wrong server type")
                        synchronized(attempts) { attempts.put(JSONObject().put("base", connection.base).put("state", "identified")
                            .put("elapsed_ms", (System.nanoTime() - begin) / 1000000)) }
                        // Only /identity: never send the supplied placeholder key to any endpoint.
                        MediaServerAccount("debug-network", "Plex", connection.base, "", "plex", server.id)
                    } catch (error: Exception) {
                        synchronized(attempts) { attempts.put(JSONObject().put("base", connection.base).put("state", "failed")
                            .put("error", (error as? MediaServerFailure)?.code ?: "Server unavailable")
                            .put("transport", (error as? MediaServerFailure)?.transportError.orEmpty())
                            .put("elapsed_ms", (System.nanoTime() - begin) / 1000000)) }
                        throw error
                    }
                }
                report.put("state", "identity_selected").put("selected_base", selected.base)
            } catch (error: Exception) { report.put("state", "error").put("error", (error as? MediaServerFailure)?.code ?: "Server unavailable") }
        }
        // Workers are cancelled by select; serialize a frozen snapshot, never live mutable data.
        val snapshot = synchronized(attempts) { JSONArray(attempts.toString()) }
        report.put("attempts", snapshot).put("elapsed_ms", (System.nanoTime() - started) / 1000000)
        val directory = File(context.cacheDir, "diagnostics").apply { mkdirs() }
        File(directory, "plex-network-$request.json").writeText(report.toString())
        return report
    }
}
