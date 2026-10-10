package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.net.HttpCookie
import java.net.URI

internal class CloudFile(val name: String, val folder: Boolean, val size: Long, val id: String, val pickCode: String = "", val modified: Long = -1, val objectId: String = id, val canDelete: Boolean = false)
internal class CloudLink(val url: String, val headers: (URI) -> Map<String, String>)
internal class CloudPage(val files: List<CloudFile>, val nextOffset: Int, val total: Int = -1)

/** Read-only legacy 115 adapter. Baidu accounts use OpenList OAuth exclusively. */
internal class CloudDrive(val provider: String, private val cookie: String, private val http: CloudTransport = CloudHttp,
    private val metadata: CloudMetadata = CloudMetadata()) : CloudClient {
    init { require(provider == P115 && CloudHttp.validCookie(cookie)) }
    private fun get(url: String, values: Map<String, String> = emptyMap()) = http.request(CloudHttp.query(url, values), cookie, null)
    private fun checked(response: CloudResponse): JSONObject {
        val json = response.json
        if (json.opt("state") != true && json.opt("state")?.toString() != "1") {
            if (json.optInt("errno") in setOf(99, 911, 990001, 40101032) || json.optInt("code") == 99) throw CloudFailure("cloud_login_required")
            throw CloudFailure()
        }
        return json
    }

    override fun list(path: String): List<CloudFile> {
        val result = ArrayList<CloudFile>()
        visit(path) { result.addAll(it); false }
        return result
    }
    override fun page(path: String, offset: Int, refresh: Boolean): CloudPage {
        require(path.startsWith('/') && path.split('/').none { it == "." || it == ".." || '\u0000' in it })
        require(offset >= 0 && offset <= Int.MAX_VALUE - PAGE_SIZE)
        if (Thread.currentThread().isInterrupted) throw CloudFailure()
        if (refresh) metadata.invalidate(path)
        metadata.page(path, offset)?.let { return it }
        val page = page115(path, offset)
        val keys = page.files.map { (if (it.folder) "d" else "f") + it.id }
        if (keys.toSet().size != keys.size) throw CloudFailure()
        // An endpoint ignoring offset must not create an endless series of identical pages.
        if (offset > 0 && page.files.isNotEmpty()) {
            val previous = metadata.previous(path, offset)
            if (previous != null && previous.files.map { (if (it.folder) "d" else "f") + it.id } == keys) throw CloudFailure()
        }
        if (Thread.currentThread().isInterrupted) throw CloudFailure()
        page.files.forEach { metadata.put(CloudPaths.child(path, it.name), it) }
        metadata.put(path, offset, page)
        return page
    }
    private fun page115(path: String, offset: Int): CloudPage {
        val folder = if (path == "/") "0" else metadata.file(path)?.takeIf { it.folder }?.id
            ?: checked(get("https://webapi.115.com/files/getid", mapOf("path" to path))).get("id").toString()
        if (folder == "0" && path != "/") throw CloudFailure("cloud_file_missing")
        if (path != "/") metadata.put(path, CloudFile(path.substringAfterLast('/'), true, 0, folder))
        val result = ArrayList<CloudFile>()
        val json = checked(get("https://webapi.115.com/files", mapOf("cid" to folder, "offset" to "$offset",
            "limit" to "$PAGE_SIZE", "show_dir" to "1", "count_folders" to "1", "cur" to "1", "fc_mix" to "0",
            "o" to "file_name", "asc" to "1", "format" to "json")))
        val items = json.getJSONArray("data")
        if (json.has("offset") && json.getInt("offset") != offset) throw CloudFailure()
        if (items.length() > PAGE_SIZE) throw CloudFailure()
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val directory = !item.has("fid") || item.optString("fid").isEmpty()
            val id = item.get(if (directory) "cid" else "fid").toString()
            result.add(CloudFile(item.getString("n"), directory, item.optLong("s"), id, item.optString("pc"), item.optLong("te", -1).takeIf { it > 0 }?.times(1000) ?: -1))
        }
        val next = offset + items.length()
        val count = json.getInt("count")
        if (items.length() == 0 && offset < count) throw CloudFailure()
        if (count < 0) throw CloudFailure()
        return CloudPage(result, if (next < count) next else -1, count)
    }
    private fun visit(path: String, accept: (List<CloudFile>) -> Boolean) {
        var offset = 0
        val seen = HashSet<String>()
        repeat(5000) {
            val page = page(path, offset)
            for (file in page.files) if (!seen.add((if (file.folder) "d" else "f") + file.id)) throw CloudFailure()
            if (accept(page.files) || page.nextOffset < 0) return
            offset = page.nextOffset
        }
        throw CloudFailure("cloud_folder_too_large")
    }

    override fun find(path: String): CloudFile {
        metadata.file(path)?.takeIf { !it.folder }?.let { return it }
        var found: CloudFile? = null
        visit(path.substringBeforeLast('/').ifEmpty { "/" }) { files ->
            found = files.firstOrNull { !it.folder && it.name == path.substringAfterLast('/') }
            found != null
        }
        return found ?: throw CloudFailure("cloud_file_missing")
    }

    override fun resolve(file: CloudFile): CloudLink {
        if (file.folder || file.size <= 0) throw CloudFailure("cloud_file_missing")
        return run {
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
        }
    }
    private fun mediaHeaders() = mutableMapOf("User-Agent" to CloudHttp.UA,
        "Referer" to "https://115.com/")

    companion object {
        const val PAGE_SIZE = 48
        const val P115 = "115"
        const val BAIDU = "baidu"
        const val OPEN115 = "115_open"
        const val ONEDRIVE = "onedrive"
        const val ALIYUN = "aliyun_open"
        const val QUARK = "quark_open"
        const val WEBDAV = "webdav"
        val PROVIDERS = linkedMapOf(OPEN115 to "115", BAIDU to "百度网盘", ALIYUN to "阿里云盘", QUARK to "夸克网盘", ONEDRIVE to "OneDrive", WEBDAV to "WebDAV")
        // Candidate providers are opened explicitly by Debug diagnostics only.
        val TRIAL_PROVIDERS = emptyMap<String, String>()
        fun providerName(provider: String) = PROVIDERS[provider] ?: TRIAL_PROVIDERS.getValue(provider)
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
    }
}
