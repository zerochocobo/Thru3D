package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Only display metadata and stable cloud:// paths reach Godot. */
internal object CloudLibrary {
    private lateinit var store: CloudAccountStore
    private var saved = JSONArray()
    private var initialized = false
    val providers = CloudDrive.PROVIDERS
    private val activeStreams = HashMap<String, MutableList<Pair<LocalStreamServer, String>>>()

    @Synchronized fun start(context: Context) {
        if (initialized) return
        try {
            val candidate = CloudAccountStore(context.applicationContext)
            val accounts = candidate.load()
            store = candidate; saved = accounts; initialized = true
        } catch (_: Exception) { throw CloudFailure("cloud_store_unavailable") }
    }
    @Synchronized fun accounts(): JSONArray = JSONArray().also { result ->
        for (i in 0 until saved.length()) {
            val item = saved.getJSONObject(i)
            result.put(JSONObject().put("id", item.getString("id")).put("name", item.getString("name"))
                .put("provider", item.getString("provider")))
        }
    }
    @Synchronized private fun credentials(id: String): JSONObject = (0 until saved.length())
        .map { saved.getJSONObject(it) }.firstOrNull { it.getString("id") == id }
        ?.let { JSONObject(it.toString()) } ?: throw CloudFailure("cloud_login_required")
    private fun drive(account: JSONObject) = CloudDrive(account.getString("provider"), account.getString("cookie"))

    fun connect(provider: String, name: String, cookie: String, id: String? = null) = safe {
        require(provider in providers && name.isNotBlank() && CloudHttp.validCookie(cookie))
        val account = JSONObject().put("id", id ?: UUID.randomUUID().toString()).put("provider", provider)
            .put("name", name.trim().take(80)).put("cookie", cookie)
        drive(account).list("/")
        synchronized(this) {
            if (id != null && credentials(id).getString("provider") != provider) throw CloudFailure()
            val updated = JSONArray()
            for (i in 0 until saved.length()) if (saved.getJSONObject(i).getString("id") != id) updated.put(saved.getJSONObject(i))
            updated.put(account)
            store.save(updated); saved = updated
            if (id != null) revoke(id)
        }
    }
    @Synchronized fun remove(id: String) = safe {
        val updated = JSONArray()
        for (i in 0 until saved.length()) if (saved.getJSONObject(i).getString("id") != id) updated.put(saved.getJSONObject(i))
        store.save(updated); saved = updated; revoke(id)
    }
    private fun revoke(id: String, disconnectDav: Boolean = true) {
        activeStreams.remove(id)?.forEach { (server, url) -> server.revoke(url) }
        if (disconnectDav) CloudWebDav.disconnectClients()
    }
    @Synchronized fun stopStreams() { activeStreams.keys.toList().forEach { revoke(it, false) } }

    fun browse(path: String, @Suppress("UNUSED_PARAMETER") refresh: Boolean): JSONObject = safe {
        val entries = JSONArray()
        if (path.isEmpty() || path == "/") {
            val accounts = accounts()
            for (i in 0 until accounts.length()) {
                val account = accounts.getJSONObject(i)
                entries.put(JSONObject().put("id", "/" + account.getString("id")).put("title", account.getString("name")).put("container", true))
            }
        } else {
            val (id, remote) = split(path)
            val files = drive(credentials(id)).list(remote)
            for (file in files) {
                if (!file.folder && !MediaKinds.supported(file.name)) continue
                val child = CloudPaths.child(path, file.name)
                entries.put(JSONObject().put("id", child).put("title", file.name).put("container", file.folder)
                    .put("size", file.size).apply { if (!file.folder) put("uri", CloudPaths.uri(child)).put("kind", MediaKinds.kind(file.name)) })
            }
        }
        JSONObject().put("path", path).put("entries", entries)
    }
    fun playable(uri: String, server: LocalStreamServer): String = safe {
        val (id, remote) = split(CloudPaths.path(uri))
        val account = credentials(id)
        val client = drive(account)
        val file = client.find(remote)
        val source = CloudStreamSource(file.size, { client.resolve(file) })
        source.prepare()
        synchronized(this) {
            if (credentials(id).getString("cookie") != account.getString("cookie")) throw CloudFailure("cloud_login_required")
            stopStreams()
            val url = server.publish(source, file.name)
            activeStreams.getOrPut(id) { ArrayList() }.add(server to url)
            url
        }
    }
    private fun split(path: String): Pair<String, String> {
        val normalized = if ('/' !in path.removePrefix("/")) "$path/" else path
        val valid = CloudPaths.path(CloudPaths.uri(normalized))
        val id = valid.removePrefix("/").substringBefore('/')
        return id to valid.removePrefix("/$id").ifEmpty { "/" }
    }
    val dav: CloudDavFiles = object : CloudDavFiles {
        override fun stat(path: String): DavEntry = safe {
            if (path == "/") return@safe DavEntry("/", "Quest Cloud", true)
            val (id, remote) = split(path)
            val account = credentials(id)
            if (remote == "/") return@safe DavEntry(path, account.getString("name"), true)
            val item = drive(account).list(remote.substringBeforeLast('/').ifEmpty { "/" })
                .firstOrNull { it.name == remote.substringAfterLast('/') } ?: throw CloudFailure("cloud_file_missing")
            DavEntry(path, item.name, item.folder, item.size)
        }
        override fun list(path: String): List<DavEntry> = safe {
            if (path == "/") {
                val accounts = accounts()
                return@safe (0 until accounts.length()).map { accounts.getJSONObject(it) }.map {
                    DavEntry("/" + it.getString("id"), it.getString("name"), true)
                }
            }
            val (id, remote) = split(path)
            drive(credentials(id)).list(remote).map { DavEntry(CloudPaths.child(path, it.name), it.name, it.folder, it.size) }
        }
        override fun source(path: String): StreamSource = safe {
            val (id, remote) = split(path)
            val account = credentials(id)
            val client = drive(account)
            val file = client.find(remote)
            CloudStreamSource(file.size, {
                if (credentials(id).getString("cookie") != account.getString("cookie")) throw CloudFailure("cloud_login_required")
                client.resolve(file)
            })
        }
    }
    private inline fun <T> safe(block: () -> T): T = try { block() }
        catch (error: CloudFailure) { throw error }
        catch (_: Exception) { throw CloudFailure() }
}
