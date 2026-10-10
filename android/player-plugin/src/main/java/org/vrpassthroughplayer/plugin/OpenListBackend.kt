package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONObject
import org.vrpassthroughplayer.cloudcore.Cloudcore
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.util.UUID

/** OAuth mounts live in the encrypted core database; account IDs keep existing cloud paths stable. */
internal object OpenListBackend {
    private val drivers = OpenListAuth.drivers + (CloudDrive.WEBDAV to "WebDav")
    fun supported(provider: String) = provider in drivers
    private var initialized = false
    @Synchronized fun start(context: Context) {
        if (initialized) return
        try {
            Cloudcore.start(File(context.noBackupFilesDir, "openlist-vr-v1").absolutePath, CloudSecret.key(context))
            initialized = true
        } catch (_: Exception) { throw CloudFailure("cloud_store_unavailable") }
    }
    fun request(method: String, route: String, body: JSONObject? = null): JSONObject {
        val result = try { JSONObject(Cloudcore.request(method, route, body?.toString() ?: "")) }
        catch (_: Exception) { throw CloudFailure() }
        if (result.optInt("code") != 200) throw CloudFailure()
        return result
    }
    fun create(credential: OpenListAuth.Credential) = create(credential.provider, credential.addition())
    fun createWebDav(connection: RemoteWebDav.Connection): JSONObject =
        create(CloudDrive.WEBDAV, connection.addition()).apply {
            val fields = connection.metadata()
            fields.keys().forEach { put(it, fields.get(it)) }
        }
    fun webDavConnection(account: JSONObject): RemoteWebDav.Connection {
        require(account.getString("provider") == CloudDrive.WEBDAV && account.getInt("core_id") > 0)
        val storage = request("GET", "/account?id=" + account.getInt("core_id")).getJSONObject("data")
        require(storage.getString("mount_path") == account.getString("mount") && storage.getString("driver") == "WebDav")
        return RemoteWebDav.fromAddition(JSONObject(storage.getString("addition")))
    }
    private fun create(provider: String, addition: JSONObject): JSONObject {
        val mount = "/" + UUID.randomUUID().toString()
        val body = JSONObject().put("mount_path", mount).put("driver", drivers.getValue(provider))
            .put("addition", addition.toString()).put("cache_expiration", 5)
            .put("web_proxy", true).put("webdav_policy", "native_proxy").put("down_proxy_url", "").put("disabled", false)
        var id = 0
        try {
            id = request("POST", "/create", body).getJSONObject("data").getInt("id")
            val account = JSONObject().put("core_id", id).put("mount", mount).put("provider", provider)
            client(account).page("/")
            return account
        } catch (error: Exception) {
            // CreateStorage persists failed initializations too. Remove only this attempted mount.
            if (id == 0) runCatching {
                val all = request("GET", "/accounts?page=1&per_page=10000").getJSONObject("data").getJSONArray("content")
                for (i in 0 until all.length()) if (all.getJSONObject(i).optString("mount_path") == mount) id = all.getJSONObject(i).getInt("id")
            }
            if (id > 0) runCatching { remove(id) }
            throw error
        }
    }
    fun remove(id: Int) { require(id > 0); request("POST", "/delete?id=$id") }
    fun client(account: JSONObject): CloudClient {
        if (!supported(account.optString("provider")) || !account.has("mount") || account.optInt("core_id") <= 0)
            throw CloudFailure("cloud_login_required")
        return Client(account.getString("mount"), account.getString("provider"))
    }

    private class Client(private val mount: String, provider: String) : CloudClient {
        override val canDelete = provider == CloudDrive.OPEN115
        init { require(mount.matches(Regex("/[0-9a-f-]{36}"))) }
        private fun absolutePath(remote: String): String {
            require(remote.startsWith('/') && remote.split('/').none { it == "." || it == ".." || '\u0000' in it })
            return mount + if (remote == "/") "" else remote
        }
        override fun page(path: String, offset: Int, refresh: Boolean): CloudPage {
            require(offset >= 0 && offset % CloudDrive.PAGE_SIZE == 0 && offset <= Int.MAX_VALUE - CloudDrive.PAGE_SIZE)
            val data = if (canDelete) request("POST", "/list115", JSONObject().put("mount", mount).put("path", path)
                .put("offset", offset).put("refresh", refresh && offset == 0)).getJSONObject("data")
            else request("POST", "/list", JSONObject().put("path", absolutePath(path)).put("password", "")
                .put("page", offset / CloudDrive.PAGE_SIZE + 1).put("per_page", CloudDrive.PAGE_SIZE)
                .put("refresh", refresh && offset == 0)).getJSONObject("data")
            val items = data.optJSONArray("content") ?: org.json.JSONArray()
            val total = data.getInt("total")
            if (total < 0 || items.length() > CloudDrive.PAGE_SIZE || offset > total ||
                (items.length() == 0 && offset < total)) throw CloudFailure()
            val files = (0 until items.length()).map { i ->
                val item = items.getJSONObject(i)
                val name = item.getString("name")
                val child = CloudPaths.child(path, name)
                CloudFile(name, item.getBoolean("is_dir"), item.optLong("size"), child,
                    modified = if (canDelete) item.optLong("modified_ms", -1) else runCatching { java.time.OffsetDateTime.parse(item.optString("modified")).toInstant().toEpochMilli() }.getOrDefault(-1),
                    objectId = if (canDelete) item.getString("id") else child, canDelete = canDelete && item.optBoolean("can_delete"))
            }
            if (files.map { it.name }.toSet().size != files.size) throw CloudFailure()
            return CloudPage(files, if (offset + items.length() < total) offset + items.length() else -1, total)
        }
        override fun list(path: String): List<CloudFile> {
            val files = ArrayList<CloudFile>()
            val seen = HashSet<String>()
            var offset = 0
            repeat(5000) {
                val page = page(path, offset)
                page.files.forEach { if (!seen.add(it.name)) throw CloudFailure() }
                files.addAll(page.files)
                if (page.nextOffset < 0) return files
                offset = page.nextOffset
            }
            throw CloudFailure("cloud_folder_too_large")
        }
        override fun find(path: String) = list(path.substringBeforeLast('/').ifEmpty { "/" })
            .firstOrNull { !it.folder && it.name == path.substringAfterLast('/') } ?: throw CloudFailure("cloud_file_missing")
        override fun remove(path: String, file: CloudFile) {
            check(canDelete && file.canDelete && path != "/" && file.id == path)
            request("POST", "/remove115", JSONObject().put("mount", mount).put("path", path).put("id", file.objectId)
                .put("folder", file.folder).put("size", file.size).put("modified", file.modified))
        }
        override fun resolve(file: CloudFile): CloudLink {
            require(!file.folder && file.size > 0)
            val stream = Cloudcore.stream(absolutePath(file.id))
            val origin = URI(stream)
            return CloudLink(stream) { emptyMap() }.also { require(origin.host == "127.0.0.1" && origin.scheme == "http") }
        }
    }
    /** The Go proxy owns all provider redirects. Kotlin only connects to this exact capability URL. */
    fun connection(uri: URI, link: CloudLink): HttpURLConnection {
        if (uri.toASCIIString() != link.url || uri.host != "127.0.0.1" || uri.scheme != "http" ||
            uri.rawUserInfo != null || uri.port !in 1..65535) throw CloudFailure()
        return uri.toURL().openConnection() as HttpURLConnection
    }
}
