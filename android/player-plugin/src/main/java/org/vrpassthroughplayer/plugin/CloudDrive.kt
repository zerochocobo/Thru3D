package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.net.HttpCookie
import java.net.URI
import java.util.Base64

internal class CloudFile(val name: String, val folder: Boolean, val size: Long, val id: String, val pickCode: String = "")
internal class CloudLink(val url: String, val headers: (URI) -> Map<String, String>)

/** Small, read-only web-session adapters. No OpenList runtime or driver code. */
internal class CloudDrive(val provider: String, private val cookie: String, private val http: CloudTransport = CloudHttp) {
    init { require(provider in PROVIDERS && CloudHttp.validCookie(cookie)) }
    private fun get(url: String, values: Map<String, String> = emptyMap()) = http.request(CloudHttp.query(url, values), cookie, null)
    private fun checked(response: CloudResponse): JSONObject {
        val json = response.json
        if (provider == P115) {
            if (json.opt("state") != true && json.opt("state")?.toString() != "1") {
                if (json.optInt("errno") in setOf(99, 911, 990001, 40101032) || json.optInt("code") == 99) throw CloudFailure("cloud_login_required")
                throw CloudFailure()
            }
        } else if (!json.has("errno") || json.optInt("errno", -1) != 0) {
            if (json.optInt("errno") in setOf(-6, -9, 110, 111)) throw CloudFailure("cloud_login_required")
            throw CloudFailure()
        }
        return json
    }

    fun list(path: String): List<CloudFile> {
        require(path.startsWith('/') && path.split('/').none { it == "." || it == ".." || '\u0000' in it })
        return if (provider == P115) list115(path) else listBaidu(path)
    }
    private fun list115(path: String): List<CloudFile> {
        val folder = if (path == "/") "0" else checked(get("https://webapi.115.com/files/getid", mapOf("path" to path))).get("id").toString()
        if (folder == "0" && path != "/") throw CloudFailure("cloud_file_missing")
        val result = ArrayList<CloudFile>()
        var offset = 0
        val seen = HashSet<String>()
        repeat(200) {
            val json = checked(get("https://webapi.115.com/files", mapOf("cid" to folder, "offset" to "$offset",
                "limit" to "500", "show_dir" to "1", "o" to "file_name", "asc" to "1", "format" to "json")))
            val items = json.getJSONArray("data")
            if (items.length() == 0) return result
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                val directory = !item.has("fid") || item.optString("fid").isEmpty()
                val id = item.get(if (directory) "cid" else "fid").toString()
                if (!seen.add((if (directory) "d" else "f") + id)) throw CloudFailure()
                result.add(CloudFile(item.getString("n"), directory, item.optLong("s"), id, item.optString("pc")))
            }
            offset += items.length()
            if (offset >= json.getInt("count")) return result
        }
        throw CloudFailure("cloud_folder_too_large")
    }
    private fun listBaidu(path: String): List<CloudFile> {
        val result = ArrayList<CloudFile>()
        val seen = HashSet<String>()
        for (page in 1..200) {
            val json = checked(get("https://pan.baidu.com/api/list", mapOf("dir" to path, "page" to "$page",
                "num" to "1000", "order" to "name", "desc" to "0", "showempty" to "0", "web" to "1", "clienttype" to "0")))
            val items = json.getJSONArray("list")
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                val id = item.get("fs_id").toString()
                if (!seen.add(id)) throw CloudFailure()
                result.add(CloudFile(item.getString("server_filename"), item.optInt("isdir") == 1, item.optLong("size"), id))
            }
            if (items.length() < 1000) return result
        }
        throw CloudFailure("cloud_folder_too_large")
    }

    fun find(path: String): CloudFile = list(path.substringBeforeLast('/').ifEmpty { "/" })
        .firstOrNull { !it.folder && it.name == path.substringAfterLast('/') } ?: throw CloudFailure("cloud_file_missing")

    fun resolve(file: CloudFile): CloudLink {
        if (file.folder || file.size <= 0) throw CloudFailure("cloud_file_missing")
        return if (provider == P115) {
            // The plain web endpoint is capped at 200 MB. Use the RSA app endpoint for original videos.
            val response = http.request("https://proapi.115.com/app/chrome/downurl", cookie,
                mapOf("data" to Cloud115Cipher.encrypt(JSONObject().put("pickcode", file.pickCode).toString())))
            val json = checked(response)
            val files = JSONObject(Cloud115Cipher.decrypt(json.getString("data")))
            val entry = files.optJSONObject(file.id) ?: throw CloudFailure("cloud_file_missing")
            if (entry.getLong("file_size") != file.size) throw CloudFailure("cloud_file_changed")
            val url = secureMediaUrl(entry.getJSONObject("url").getString("url"), provider)
            val origin = URI(url)
            val downloadCookies = response.cookies.flatMap { runCatching { HttpCookie.parse(it) }.getOrDefault(emptyList()) }
                .filter { it.name !in setOf("UID", "CID", "SEID", "KID") && !it.hasExpired() }
                .joinToString("; ") { "${it.name}=${it.value}" }
            CloudLink(url) { target -> mediaHeaders().also {
                if (target.host == origin.host && CloudHttp.validCookie(downloadCookies)) it["Cookie"] = downloadCookies
            } }
        } else {
            val variables = checked(get("https://pan.baidu.com/api/gettemplatevariable", mapOf(
                "fields" to "[\"sign1\",\"sign3\",\"timestamp\",\"bdstoken\"]", "web" to "1", "clienttype" to "0"))).getJSONObject("result")
            require(file.id.matches(Regex("[0-9]+")))
            val json = checked(get("https://pan.baidu.com/api/download", mapOf("type" to "dlink", "fidlist" to "[${file.id}]",
                "sign" to baiduSign(variables.getString("sign3"), variables.getString("sign1")),
                "timestamp" to variables.get("timestamp").toString(), "bdstoken" to variables.getString("bdstoken"),
                "web" to "1", "clienttype" to "0", "channel" to "chunlei")))
            val items = json.optJSONArray("dlink") ?: json.optJSONArray("list") ?: throw CloudFailure()
            val entry = (0 until items.length()).map { items.getJSONObject(it) }
                .firstOrNull { it.opt("fs_id")?.toString() == file.id } ?: throw CloudFailure()
            val url = secureMediaUrl(entry.getString("dlink"), provider)
            CloudLink(url) { target -> mediaHeaders().also {
                if (within(target.host, "baidu.com")) it["Cookie"] = cookie
            } }
        }
    }
    private fun mediaHeaders() = mutableMapOf("User-Agent" to CloudHttp.UA,
        "Referer" to if (provider == P115) "https://115.com/" else "https://pan.baidu.com/disk/main")

    companion object {
        const val P115 = "115"
        const val BAIDU = "baidu"
        val PROVIDERS = linkedMapOf(P115 to "115", BAIDU to "百度网盘")
        private val mediaDomains = mapOf(P115 to listOf("115.com", "115cdn.com", "115cdn.net"),
            BAIDU to listOf("baidu.com", "baidupcs.com"))
        fun within(host: String?, domain: String): Boolean = host == domain || host?.endsWith(".$domain") == true
        // Both initial links and every CDN redirect must use the same policy.
        fun allowedMediaUri(uri: URI, provider: String? = null): Boolean {
            val allowed = if (provider == null) mediaDomains.values.flatten() else mediaDomains[provider].orEmpty()
            return uri.scheme == "https" && uri.port in setOf(-1, 443) && uri.rawUserInfo == null &&
                allowed.any { within(uri.host, it) }
        }
        fun secureMediaUrl(value: String, provider: String): String {
            val original = URI(value)
            val uri = if (original.scheme == "http") URI("https:" + value.substringAfter(':')) else original
            if (!allowedMediaUri(uri, provider)) throw CloudFailure()
            return uri.toASCIIString()
        }
        /** Web download signature: standard RC4(sign3, sign1), then Base64. */
        fun baiduSign(key: String, value: String): String {
            require(key.isNotEmpty())
            val bytes = key.toByteArray(Charsets.UTF_8)
            val state = IntArray(256) { it }
            var j = 0
            for (i in state.indices) {
                j = (j + state[i] + (bytes[i % bytes.size].toInt() and 255)) and 255
                val old = state[i]; state[i] = state[j]; state[j] = old
            }
            var i = 0; j = 0
            val result = value.toByteArray(Charsets.UTF_8).map { byte ->
                i = (i + 1) and 255; j = (j + state[i]) and 255
                val old = state[i]; state[i] = state[j]; state[j] = old
                (byte.toInt() xor state[(state[i] + state[j]) and 255]).toByte()
            }.toByteArray()
            return Base64.getEncoder().encodeToString(result)
        }
    }
}
