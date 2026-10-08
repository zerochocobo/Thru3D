package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.content.Context
import android.net.wifi.WifiManager
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** Library sources for the in-headset menu: local MediaStore, DLNA servers and SMB shares.
 * Every request returns an id at once; the result arrives as media_list(id, json) with
 * {source, state: ready|error|denied, entries|servers, error}. */
internal class MediaSources(
    private val host: () -> Activity?,
    private val emit: (Int, String) -> Unit,
) {
    private val ids = AtomicInteger()
    private val network = Executors.newSingleThreadExecutor { Thread(it, "QuestMediaNetwork") }
    private val cloudNetwork = Executors.newSingleThreadExecutor { Thread(it, "QuestCloudNetwork") }
    private val cloudBrowseRequests = CloudBrowseRequests()
    private val local = LocalVideoLibrary(host, emit)
    private val dlnaServers = HashMap<String, DlnaClient.Server>() // network worker only
    @Volatile private var server: LocalStreamServer? = null
    private val smb by lazy { SmbLibrary(context() ?: error("Activity unavailable")) { streams() } }
    private val mediaServers = MediaServerLibrary(::context, ::streams, ::nextId, emit = emit)
    fun serverRequest(json: String): Int = mediaServers.request(json)
    fun serverCancel(id: Int) = mediaServers.cancel(id)
    fun releaseMediaStream(uri: String) {
        mediaServers.release(uri)
        server?.revoke(uri)
    }

    private fun context(): Context? = host()?.applicationContext
    @Synchronized fun streams(): LocalStreamServer = server ?: LocalStreamServer().also { server = it }

    fun releasePhotoStream(uri: String) { if (uri.isNotEmpty()) server?.revoke(uri) }

    fun nextId(): Int = ids.incrementAndGet()
    /** Main thread: may show the media permission request. path "" lists the storage volumes. */
    fun browseLocal(id: Int, path: String) = local.browse(id, path)
    /** Main thread: opens the system "All files access" page; false when the device has none. */
    fun grantAllFiles() = local.grantAllFiles()
    fun onPermissionResult(requestCode: Int, granted: Boolean) = local.onPermissionResult(requestCode, granted)

    @Volatile private var stopped = false
    private val cloudAccountChanged: () -> Unit = {
        if (!stopped) emit(0, JSONObject().put("source", "cloud").put("state", "accounts_changed").toString())
    }
    init {
        CloudAccountChanges.subscribe(cloudAccountChanged)
        DlnaClient.log = { android.util.Log.i("QuestDlna", it) }
        cloudNetwork.execute {
            if (!stopped) runCatching { context()?.let { CloudWebDav.restore(it) } }
            if (stopped) CloudWebDav.stop()
        }
    }

    fun dlnaDiscover(): Int = run("dlna") {
        val lock = (context()?.getSystemService(Context.WIFI_SERVICE) as? WifiManager)?.createMulticastLock("QuestDlna")
        lock?.setReferenceCounted(false); lock?.acquire()
        try {
            val found = DlnaClient.discover()
            synchronized(dlnaServers) { found.forEach { dlnaServers[it.id] = it } }
            JSONObject().put("servers", JSONArray().apply { found.forEach { put(it.json()) } })
        } finally { lock?.release() }
    }

    fun dlnaBrowse(serverId: String, objectId: String): Int = run("dlna") {
        val server = synchronized(dlnaServers) { dlnaServers[serverId] } ?: error("DLNA server not discovered")
        JSONObject().put("server_id", serverId).put("object_id", objectId)
            .put("entries", DlnaClient.browse(server, objectId.ifEmpty { "0" }))
    }

    fun smbServers(): Int = run("smb") { JSONObject().put("servers", smb.serversJson()) }
    fun smbDiscover(): Int = run("smb") {
        // WS-Discovery answers arrive as multicast-addressed traffic too; Wi-Fi drops it without the lock.
        val lock = (context()?.getSystemService(Context.WIFI_SERVICE) as? WifiManager)?.createMulticastLock("QuestSmb")
        lock?.setReferenceCounted(false); lock?.acquire()
        try { JSONObject().put("discovered", smb.discover()) } finally { lock?.release() }
    }
    fun smbSave(request: String): Int = run("smb") {
        JSONObject().put("saved_id", smb.save(JSONObject(request))).put("servers", smb.serversJson())
    }
    fun smbRemove(id: String): Int = run("smb") { smb.remove(id); JSONObject().put("servers", smb.serversJson()) }
    fun smbBrowse(serverId: String, path: String): Int = run("smb") {
        JSONObject().put("server_id", serverId).put("path", path).put("entries", smb.browse(serverId, path))
    }

    fun cloudBrowse(path: String, refresh: Boolean, offset: Int = 0): Int {
        val id = nextId()
        cloudBrowseRequests.submit(id, { cancellation ->
            val result = try {
                CloudLibrary.start(context() ?: error("Activity unavailable"))
                CloudLibrary.browse(path, refresh, offset, cancellation).put("state", "ready")
            } catch (error: Exception) {
                JSONObject().put("state", "error").put("error", error.message ?: "Cloud connection failed")
            }
            result.put("source", "cloud").put("path", path).put("offset", offset).toString()
        }, emit)
        return id
    }
    fun cloudCancel(id: Int) = cloudBrowseRequests.cancel(id)

    fun cloudRemove(id: String): Int = run("cloud") {
        CloudLibrary.start(context() ?: error("Activity unavailable"))
        CloudLibrary.remove(id)
        JSONObject()
    }

    /** MPV-playable location for a library URI; blocks (SMB connects). Worker threads only. */
    fun playable(uri: String): String = when {
        uri.startsWith("medialib://") -> mediaServers.playable(uri)
        uri.startsWith("smb://") -> smb.stream(uri)
        uri.startsWith("cloud://") -> {
            CloudLibrary.start(context() ?: error("Activity unavailable"))
            CloudLibrary.playable(uri, streams())
        }
        else -> uri
    }

    /** Extra M4A tracks beside a video (clone voice first). Local files, the MediaStore library and
     * SMB; DLNA servers expose no sibling files. Blocks; worker threads only. Never throws. */
    fun sidecarAudio(uri: String): List<SidecarAudio.Track> = try {
        val source = android.net.Uri.parse(uri)
        when (source.scheme) {
            "file" -> source.path?.let { SidecarAudio.forFile(it) } ?: emptyList()
            "content" -> context()?.let { SidecarAudio.forMediaStore(it, source) } ?: emptyList()
            "smb" -> smb.sidecarAudio(uri)
            else -> emptyList()
        }
    } catch (error: Throwable) {
        android.util.Log.w("QuestSidecarAudio", "Sidecar audio lookup failed: ${error.message}")
        emptyList()
    }

    fun sidecarSubtitles(uri: String): List<SidecarSubtitles.Track> = try {
        if (uri.startsWith("smb://")) smb.sidecarSubtitles(uri) else emptyList()
    } catch (error: Exception) {
        android.util.Log.w("QuestSubtitles", "SMB subtitle lookup failed: ${error.javaClass.simpleName}")
        emptyList()
    }

    private fun run(source: String, block: () -> JSONObject): Int {
        val id = ids.incrementAndGet()
        (if (source == "cloud") cloudNetwork else network).execute {
            val result = try { block().put("state", "ready") }
            catch (error: Throwable) { JSONObject().put("state", "error").put("error", error.message ?: error.javaClass.simpleName) }
            emit(id, result.put("source", source).toString())
        }
        return id
    }

    fun close() {
        stopped = true
        CloudAccountChanges.unsubscribe(cloudAccountChanged)
        mediaServers.close()
        cloudBrowseRequests.close()
        network.shutdownNow(); cloudNetwork.shutdownNow(); local.close()
        CloudLibrary.stopStreams()
        CloudWebDav.stop()
        server?.close(); server = null
    }
}
