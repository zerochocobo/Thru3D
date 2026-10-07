package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.net.Inet4Address
import java.net.NetworkInterface
import java.security.SecureRandom
import java.util.Base64

/** LAN serving is opt-in; its password is unrelated to any cloud account. */
internal object CloudWebDav {
    data class Status(val enabled: Boolean, val addresses: List<String>, val password: String)
    private var config: JSONObject? = null
    @Volatile private var server: CloudWebDavServer? = null
    private fun password() = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(18).also { SecureRandom().nextBytes(it) })
    private fun load(context: Context): JSONObject = config ?: run {
        val stored = CloudAccountStore(context, "cloud-webdav-v1.bin").load()
        (stored.optJSONObject(0) ?: JSONObject().put("enabled", false).put("password", password())).also { config = it }
    }
    @Synchronized fun restore(context: Context) {
        if (load(context).optBoolean("enabled")) start(context)
    }
    private fun start(context: Context) {
        if (server != null) return
        CloudLibrary.start(context)
        server = CloudWebDavServer(CloudLibrary.dav, load(context).getString("password"))
    }
    @Synchronized fun status(context: Context): Status {
        val settings = load(context)
        val addresses = if (server == null) emptyList() else runCatching {
            NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }
                .flatMap { it.inetAddresses.toList() }.filter { it is Inet4Address && it.isSiteLocalAddress }
                .map { "http://${it.hostAddress}:${server!!.port}/" }.distinct()
        }.getOrDefault(emptyList())
        return Status(server != null, addresses, settings.getString("password"))
    }
    @Synchronized fun setEnabled(context: Context, enabled: Boolean) {
        val updated = JSONObject(load(context).toString()).put("enabled", enabled)
        if (enabled) start(context)
        try { CloudAccountStore(context, "cloud-webdav-v1.bin").save(JSONArray().put(updated)); config = updated }
        catch (error: Exception) { stop(); throw error }
        if (!enabled) stop()
    }
    @Synchronized fun resetPassword(context: Context) {
        val updated = JSONObject(load(context).toString()).put("password", password())
        CloudAccountStore(context, "cloud-webdav-v1.bin").save(JSONArray().put(updated))
        config = updated; stop()
        if (updated.optBoolean("enabled")) start(context)
    }
    // No monitor here: account changes can call this while holding CloudLibrary's lock.
    fun disconnectClients() { server?.disconnectClients() }
    @Synchronized fun stop() { server?.close(); server = null }
}
