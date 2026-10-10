package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONObject
import java.io.File

/** Debug-only read/play probe. Reports counts and byte ranges, never filenames,
 * credentials, signed URLs, response bodies or screenshots of a logged-in account. */
internal object OpenListCloudProbe {
    fun request(context: Context, request: String, provider: String, play: Boolean): Int {
        require(provider in setOf(CloudDrive.ALIYUN, CloudDrive.QUARK))
        Thread {
            val report = JSONObject().put("provider", provider).put("state", "running").put("stage", "account")
            try {
                CloudLibrary.start(context); OpenListBackend.start(context)
                val accounts = CloudAccountStore(context).load()
                val account = (0 until accounts.length()).map(accounts::getJSONObject)
                    .lastOrNull { it.optString("provider") == provider } ?: throw CloudFailure("cloud_login_required")
                val client = OpenListBackend.client(account)
                report.put("stage", "directory")
                var pages = 0; var entries = 0; var folders = 0
                val pending = ArrayDeque<String>().apply { add("/") }
                var selected: CloudFile? = null
                var selectedPath = ""
                while (pending.isNotEmpty() && pages < 64 && selected == null) {
                    val path = pending.removeFirst()
                    var offset = 0
                    do {
                        val page = client.page(path, offset, pages == 0)
                        pages++; entries += page.files.size
                        val videos = page.files.filter { !it.folder && it.size > 0 && MediaKinds.kind(it.name) == "video" && MediaKinds.supported(it.name) }
                        selected = videos.minByOrNull { it.size }
                        if (selected != null) selectedPath = CloudPaths.child(path, selected!!.name)
                        page.files.filter { it.folder }.take(24).forEach {
                            folders++; if (pending.size < 24) pending.add(CloudPaths.child(path, it.name))
                        }
                        offset = page.nextOffset
                    } while (offset >= 0 && selected == null && pages < 64)
                }
                report.put("directory_pages", pages).put("directory_entries", entries).put("directory_folders", folders)
                val file = selected ?: throw CloudFailure("cloud_file_missing")
                report.put("stage", "range").put("file_size", file.size)
                val resolve = { client.resolve(file) }
                CloudStreamSource(file.size, resolve) { uri -> OpenListBackend.connection(uri, resolve()) }.use { source ->
                    source.prepare()
                    source.open().use { reader ->
                        val buffer = ByteArray(65536)
                        val head = reader.read(0, buffer, buffer.size)
                        val seek = reader.read(file.size / 2, buffer, buffer.size)
                        require(head > 0 && seek > 0)
                        report.put("head_bytes", head).put("seek_bytes", seek)
                        buffer.fill(0)
                    }
                }
                if (play) {
                    report.put("stage", "player")
                    val plugin = DiagnosticRequests.current() ?: error("Player unavailable")
                    val id = plugin.requestMpvPlayerCommand(JSONObject().put("operation", "open").put("request_key", request)
                        .put("uri", CloudPaths.uri("/" + account.getString("id") + selectedPath)).put("title", "Cloud playback check")
                        .put("stereo", false).put("profile", "384x216").put("enabled", false)
                        .put("benchmark", true).put("normal_fast", true).toString())
                    require(id > 0); report.put("player_request", id)
                }
                // Actual decoded frames/playhead must be checked in the player report separately.
                report.put("state", "ranges_passed").put("stage", "complete")
            } catch (e: Exception) {
                report.put("state", "failed").put("error_type", e.javaClass.simpleName)
                    .put("reason", (e as? CloudFailure)?.reason)
            } finally {
                val directory = File(context.filesDir, "diagnostics").apply { mkdirs() }
                File(directory, "cloud_probe_$request.json").writeText(report.toString())
            }
        }.start()
        return 1
    }
}
