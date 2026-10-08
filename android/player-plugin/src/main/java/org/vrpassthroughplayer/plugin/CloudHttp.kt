package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder

/** Only fixed provider API origins receive account cookies. No global cookie handler. */
internal fun interface CloudTransport {
    fun request(url: String, cookie: String, form: Map<String, String>?): CloudResponse
}
internal class CloudResponse(val json: JSONObject, val cookies: List<String> = emptyList())
internal class CloudCancellation : CloudTransport {
    @Volatile var cancelled = false
        private set
    private var active: HttpURLConnection? = null
    @Synchronized fun attach(connection: HttpURLConnection) {
        if (cancelled) { connection.disconnect(); throw CloudFailure() }
        active = connection
    }
    @Synchronized fun detach(connection: HttpURLConnection) { if (active === connection) active = null }
    fun cancel() {
        val connection = synchronized(this) { cancelled = true; active.also { active = null } }
        connection?.disconnect()
    }
    override fun request(url: String, cookie: String, form: Map<String, String>?): CloudResponse {
        if (cancelled) throw CloudFailure()
        return CloudHttp.request(url, cookie, form, this)
    }
}
internal class CloudFailure(val reason: String = "cloud_unavailable") : IOException(when (reason) {
    "cloud_login_required" -> "Please sign in to your cloud account again"
    "cloud_store_unavailable" -> "Cloud account storage unavailable"
    "cloud_file_missing" -> "Cloud file or account not found"
    "cloud_file_changed" -> "Cloud file changed. Refresh the folder"
    "cloud_folder_too_large" -> "Cloud folder too large"
    else -> "Cloud connection failed"
})

internal object CloudHttp : CloudTransport {
    val apiHosts = setOf("webapi.115.com", "proapi.115.com", "pan.baidu.com")
    const val UA = Cloud115Auth.USER_AGENT
    fun query(url: String, values: Map<String, String>): String = url + (if ('?' in url) "&" else "?") + form(values)
    fun form(values: Map<String, String>): String = values.entries.joinToString("&") {
        URLEncoder.encode(it.key, "UTF-8") + "=" + URLEncoder.encode(it.value, "UTF-8")
    }
    fun validCookie(value: String): Boolean = value.isNotBlank() && value.length <= 16384 &&
        value.all { it.code in 32..126 } && value.split(';').all { '=' in it && it.substringBefore('=').trim().matches(Regex("[A-Za-z0-9_-]+")) }

    override fun request(url: String, cookie: String, form: Map<String, String>?): CloudResponse {
        return request(url, cookie, form, null)
    }
    fun request(url: String, cookie: String, form: Map<String, String>?, cancellation: CloudCancellation?): CloudResponse {
        val uri = URI(url)
        require(uri.scheme == "https" && uri.host in apiHosts && uri.port == -1 && uri.rawUserInfo == null)
        require(validCookie(cookie))
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            cancellation?.attach(connection)
            connection.connectTimeout = 15000; connection.readTimeout = 20000
            connection.instanceFollowRedirects = false; connection.useCaches = false
            connection.setRequestProperty("User-Agent", UA)
            connection.setRequestProperty("Cookie", cookie)
            connection.setRequestProperty("Referer", if (uri.host.endsWith("115.com")) "https://115.com/" else "https://pan.baidu.com/disk/main")
            connection.setRequestProperty("Accept-Encoding", "identity")
            if (form != null) {
                connection.requestMethod = "POST"; connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
                connection.outputStream.use { it.write(form(form).toByteArray(Charsets.UTF_8)) }
            }
            if (connection.responseCode in setOf(301, 302, 401, 403)) throw CloudFailure("cloud_login_required")
            if (connection.responseCode != 200) throw CloudFailure()
            val bytes = connection.inputStream.use { input ->
                val out = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    if (Thread.currentThread().isInterrupted) throw CloudFailure()
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (out.size() + count > 8 * 1024 * 1024) throw CloudFailure()
                    out.write(buffer, 0, count)
                }
                out.toByteArray()
            }
            return CloudResponse(JSONObject(String(bytes, Charsets.UTF_8)), connection.headerFields.entries
                .filter { it.key.equals("Set-Cookie", true) }.flatMap { it.value })
        } catch (error: CloudFailure) { throw error }
        catch (_: Exception) { throw CloudFailure() }
        finally { cancellation?.detach(connection); connection.disconnect() }
    }
}
