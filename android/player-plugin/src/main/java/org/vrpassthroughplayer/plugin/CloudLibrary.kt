package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Only display metadata and stable cloud:// paths reach Godot. */
internal object CloudLibrary {
    private lateinit var store: CloudAccountStore
    private lateinit var appContext: Context
    private var saved = JSONArray()
    private var initialized = false
    val providers = CloudDrive.PROVIDERS
    private val activeStreams = HashMap<String, MutableList<Pair<LocalStreamServer, String>>>()
    private val metadata = HashMap<String, CloudMetadata>()

    @Synchronized fun start(context: Context) {
        if (initialized) return
        try {
            val candidate = CloudAccountStore(context.applicationContext)
            val accounts = candidate.load()
            store = candidate; saved = accounts; appContext = context.applicationContext; initialized = true
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
    @Synchronized private fun drive(account: JSONObject, http: CloudTransport = CloudHttp): CloudClient {
        if (identity(credentials(account.getString("id"))) != identity(account))
            throw CloudFailure("cloud_login_required")
        val cache = metadata.getOrPut(account.getString("id")) { CloudMetadata() }
        return if (OpenListBackend.supported(account.getString("provider"))) {
            val client = OpenListBackend.client(account) // Legacy Baidu cookies need OAuth reauthorization.
            OpenListBackend.start(appContext); client
        } else CloudDrive(account.getString("provider"), account.getString("cookie"), http, cache)
    }

    fun connect(provider: String, name: String, cookie: String, id: String? = null,
        commit: ((() -> Unit) -> Unit) = { it() }) = safe {
        require(provider == CloudDrive.P115 && id != null && name.isNotBlank() && CloudHttp.validCookie(cookie))
        val account = JSONObject().put("id", id).put("provider", provider)
            .put("name", name.trim().take(80)).put("cookie", cookie)
        // Validate the session with a single page, even when the root contains many files.
        CloudDrive(provider, cookie).page("/")
        commit { synchronized(this) {
            if (credentials(id).getString("provider") != provider) throw CloudFailure()
            val updated = JSONArray()
            for (i in 0 until saved.length()) if (saved.getJSONObject(i).getString("id") != id) updated.put(saved.getJSONObject(i))
            updated.put(account)
            store.save(updated); saved = updated
            revoke(id)
        } }
        CloudAccountChanges.emit()
    }
    private fun identity(account: JSONObject) = account.optString("cookie", account.optString("mount"))

    fun connectOAuth(credential: OpenListAuth.Credential, name: String, id: String? = null,
        commit: ((() -> Unit) -> Unit) = { it() }) = safe {
        require(name.isNotBlank() && OpenListAuth.supported(credential.provider))
        OpenListBackend.start(appContext)
        saveMount(OpenListBackend.create(credential), name, id, commit)
    }
    fun webDavMetadata(id: String): JSONObject = safe {
        val account = credentials(id)
        require(account.getString("provider") == CloudDrive.WEBDAV)
        JSONObject().put("base", account.getString("base")).put("username", account.optString("username"))
            .put("has_password", account.optBoolean("has_password"))
    }
    fun connectWebDav(name: String, base: String, username: String, password: String, id: String? = null,
        commit: ((() -> Unit) -> Unit) = { it() }) = safe {
        require(name.isNotBlank())
        val old = id?.let(::credentials)
        require(old == null || old.getString("provider") == CloudDrive.WEBDAV)
        OpenListBackend.start(appContext)
        val previous = old?.let(OpenListBackend::webDavConnection)
        val connection = RemoteWebDav.connection(base, username, password, previous)
        saveMount(OpenListBackend.createWebDav(connection), name, id, commit, old?.getString("mount"))
    }
    private fun saveMount(candidate: JSONObject, name: String, id: String?, commit: ((() -> Unit) -> Unit), expectedMount: String? = null) {
        candidate.put("id", id ?: UUID.randomUUID().toString()).put("name", name.trim().take(80))
        var accepted = false
        var retired = 0
        try {
            commit { synchronized(this) {
                if (id != null) {
                    val old = credentials(id)
                    require(old.getString("provider") == candidate.getString("provider"))
                    if (expectedMount != null) require(old.getString("mount") == expectedMount)
                    retired = old.optInt("core_id")
                }
                val updated = JSONArray()
                for (i in 0 until saved.length()) if (saved.getJSONObject(i).getString("id") != id) updated.put(saved.getJSONObject(i))
                updated.put(candidate)
                store.save(updated); saved = updated; accepted = true
                if (id != null) revoke(id)
            } }
        } finally {
            if (!accepted) runCatching { OpenListBackend.remove(candidate.getInt("core_id")) }
        }
        if (retired > 0) runCatching { OpenListBackend.remove(retired) }
        CloudAccountChanges.emit()
    }
    private fun source(account: JSONObject, client: CloudClient, file: CloudFile): CloudStreamSource {
        val resolve = {
            if (identity(credentials(account.getString("id"))) != identity(account)) throw CloudFailure("cloud_login_required")
            client.resolve(file)
        }
        return if (OpenListBackend.supported(account.getString("provider")))
            CloudStreamSource(file.size, resolve) { uri -> OpenListBackend.connection(uri, client.resolve(file)) }
        else CloudStreamSource(file.size, resolve)
    }

    fun rename(id: String, name: String) = safe {
        synchronized(this) {
            val updated = CloudAccountChanges.renamed(saved, id, name)
            store.save(updated); saved = updated
        }
        CloudAccountChanges.emit()
    }
    fun remove(id: String) = safe {
        var retired = 0
        synchronized(this) {
            retired = credentials(id).optInt("core_id")
            val updated = JSONArray()
            for (i in 0 until saved.length()) if (saved.getJSONObject(i).getString("id") != id) updated.put(saved.getJSONObject(i))
            store.save(updated); saved = updated; revoke(id)
        }
        if (retired > 0) runCatching { OpenListBackend.start(appContext); OpenListBackend.remove(retired) }
        CloudAccountChanges.emit()
    }
    private fun revoke(id: String, disconnectDav: Boolean = true) {
        synchronized(sortedPages) { sortedPages.remove(id) }
        if (disconnectDav) metadata.remove(id)
        activeStreams.remove(id)?.forEach { (server, url) -> server.revoke(url) }
        if (disconnectDav) CloudWebDav.disconnectClients()
    }
    @Synchronized fun stopStreams() { activeStreams.keys.toList().forEach { revoke(it, false) } }

    private val sortedPages = HashMap<String, CloudSortedPages>()
    fun browse(path: String, refresh: Boolean, offset: Int = 0, http: CloudTransport = CloudHttp, order: String = ""): JSONObject = safe {
        val entries = JSONArray()
        var nextOffset = -1
        var total = -1
        if (path.isEmpty() || path == "/") {
            val accounts = accounts()
            for (i in 0 until accounts.length()) {
                val account = accounts.getJSONObject(i)
                entries.put(JSONObject().put("id", "/" + account.getString("id")).put("title", account.getString("name")).put("container", true))
            }
        } else {
            val (id, remote) = split(path)
            val account = credentials(id)
            val client = drive(account, http)
            val page = if (order.isEmpty()) client.page(remote, offset, refresh) else
                synchronized(sortedPages) { sortedPages.getOrPut(id) { CloudSortedPages() } }.page(client, remote, offset, refresh, order)
            if (identity(credentials(id)) != identity(account)) throw CloudFailure("cloud_login_required")
            nextOffset = page.nextOffset
            total = page.total
            for (file in page.files) {
                if (!file.folder && !MediaKinds.supported(file.name)) continue
                val child = CloudPaths.child(path, file.name)
                entries.put(JSONObject().put("id", child).put("title", file.name).put("container", file.folder)
                    .put("size", file.size).put("modified", file.modified).put("can_delete", client.canDelete && file.canDelete)
                    .put("cloud_id", file.objectId).put("delete_effect", if (client.canDelete) "recycle" else "")
                    .put("delete_reason", "File deletion unavailable for this source").apply {
                        if (file.folder && client.canDelete) put("delete_uri", CloudPaths.uri(child))
                        if (!file.folder) put("uri", CloudPaths.uri(child)).put("kind", MediaKinds.kind(file.name))
                    })
            }
        }
        JSONObject().put("path", path).put("offset", offset).put("order", order).put("next_offset", nextOffset)
            .put("total", total).put("page_size", CloudDrive.PAGE_SIZE).put("entries", entries)
    }
    fun deleteFile(request: JSONObject, inspect: Boolean, prepare: Boolean, authorized: () -> Unit): JSONObject {
        val (id, remote) = split(CloudPaths.path(request.getString("uri")))
        val account = credentials(id)
        val client = drive(account)
        require(remote != "/" && client.canDelete) { "File deletion unavailable for this source" }
        return try {
            CloudDeletion(client) {
                authorized()
                if (identity(credentials(id)) != identity(account)) throw CloudFailure("cloud_login_required")
            }.run(remote, request, inspect, prepare)
        } finally {
            if (!inspect && !prepare) {
                synchronized(sortedPages) { sortedPages.remove(id) }
                synchronized(this) { metadata[id]?.invalidate("/") }
            }
        }
    }
    fun playable(uri: String, server: LocalStreamServer): String = safe {
        val (id, remote) = split(CloudPaths.path(uri))
        val account = credentials(id)
        val client = drive(account)
        val file = client.find(remote)
        val source = source(account, client, file)
        source.prepare()
        synchronized(this) {
            if (identity(credentials(id)) != identity(account)) throw CloudFailure("cloud_login_required")
            stopStreams()
            val url = server.publish(source, file.name)
            activeStreams.getOrPut(id) { ArrayList() }.add(server to url)
            url
        }
    }
    fun sidecarSubtitles(uri: String, server: LocalStreamServer): List<SidecarSubtitles.Track> = safe {
        val (id, remote) = split(CloudPaths.path(uri))
        val account = credentials(id)
        val client = drive(account)
        SidecarSubtitles.forCloud(remote, client) { publishCompanion(account, client, it, server) }
    }
    fun sidecarAudio(uri: String, server: LocalStreamServer): List<SidecarAudio.Track> = safe {
        val (id, remote) = split(CloudPaths.path(uri))
        val account = credentials(id)
        val client = drive(account)
        SidecarAudio.forCloud(remote, client) { publishCompanion(account, client, it, server) }
    }
    private fun publishCompanion(account: JSONObject, client: CloudClient, file: CloudFile, server: LocalStreamServer): String {
        val id = account.getString("id")
        val source = source(account, client, file)
        return try {
            source.prepare()
            synchronized(this) {
                if (identity(credentials(id)) != identity(account)) throw CloudFailure("cloud_login_required")
                // Add to the current video's leases; playable() would revoke the video stream.
                val url = server.publish(source, file.name)
                activeStreams.getOrPut(id) { ArrayList() }.add(server to url)
                url
            }
        } catch (error: Exception) { source.close(); throw error }
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
            source(account, client, file)
        }
    }
    private inline fun <T> safe(block: () -> T): T = try { block() }
        catch (error: CloudFailure) { throw error }
        catch (_: Exception) { throw CloudFailure() }
}
