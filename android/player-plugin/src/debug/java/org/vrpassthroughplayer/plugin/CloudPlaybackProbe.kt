package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URI

/** On-device only: never records credentials, filenames, signed URLs or media bytes. */
internal object CloudPlaybackProbe {
    fun request(context: Context, request: String, play: Boolean): Int {
        Thread {
            val report = JSONObject().put("state", "running")
            val calls = JSONArray()
            report.put("api", calls)
            try {
                report.put("stage", "account")
                val accounts = CloudAccountStore(context).load()
                val account = (0 until accounts.length()).map { accounts.getJSONObject(it) }
                    .firstOrNull { it.getString("provider") == CloudDrive.P115 } ?: error("No account")
                val transport = CloudTransport { url, cookie, form ->
                    CloudHttp.request(url, cookie, form).also { response ->
                        val call = JSONObject().put("endpoint", URI(url).path).put("state", response.json.opt("state"))
                            .put("errno", response.json.opt("errno")).put("code", response.json.opt("code"))
                            .put("download_cookie_count", response.cookies.size)
                        calls.put(call)
                        if (URI(url).path == "/app/chrome/downurl" && response.json.optBoolean("state")) {
                            val decoded = JSONObject(Cloud115Cipher.decrypt(response.json.getString("data")))
                            val link = URI(decoded.getJSONObject(decoded.keys().next()).getJSONObject("url").getString("url"))
                            call.put("media_host", link.host).put("media_scheme", link.scheme).put("media_port", link.port)
                        }
                    }
                }
                val drive = CloudDrive(CloudDrive.P115, account.getString("cookie"), transport)
                report.put("stage", "select")
                val mount = account.getString("id")
                val recent = (0..1).mapNotNull { bank -> runCatching {
                    val envelope = JSONObject(File(context.filesDir, "settings/recent_files_$bank.json").readText())
                    envelope.optLong("sequence") to JSONObject(envelope.getString("payload_json")).getJSONObject("entries")
                }.getOrNull() }.maxByOrNull { it.first }?.second
                var uri = recent?.keys()?.asSequence()?.map { recent.getJSONObject(it) }
                    ?.filter { it.optString("uri").startsWith("cloud://$mount/") && it.optString("kind") != "image" }
                    ?.maxByOrNull { it.optLong("opened") }?.getString("uri")
                val file = if (uri != null) {
                    report.put("selection", "recent")
                    drive.find(URI(uri).path)
                } else {
                    report.put("selection", "bounded_search")
                    val pending = ArrayDeque<String>().apply { add("/") }
                    var selected: CloudFile? = null
                    repeat(12) {
                        if (selected == null && pending.isNotEmpty()) {
                            val path = pending.removeFirst()
                            val entries = drive.list(path)
                            selected = entries.firstOrNull { !it.folder && MediaKinds.kind(it.name) == "video" && MediaKinds.supported(it.name) }
                            selected?.let { uri = CloudPaths.uri("/$mount" + CloudPaths.child(path, it.name)) }
                            entries.filter { it.folder }.take(12).forEach { pending.add(CloudPaths.child(path, it.name)) }
                        }
                    }
                    selected ?: error("No recent video")
                }
                report.put("stage", "resolve").put("file_size", file.size).put("pickcode_present", file.pickCode.isNotEmpty())
                val source = CloudStreamSource(file.size, {
                    drive.resolve(file).also { link ->
                        val target = URI(link.url)
                        report.put("media_host", target.host).put("media_scheme", target.scheme)
                            .put("media_cookie_present", link.headers(target).containsKey("Cookie"))
                    }
                })
                source.use {
                    source.prepare()
                    report.put("stage", "read_head")
                    source.open().use { reader ->
                        val buffer = ByteArray(65536)
                        report.put("head_bytes", reader.read(0, buffer, buffer.size))
                        report.put("stage", "read_seek")
                        report.put("seek_bytes", reader.read((file.size / 2).coerceAtMost(file.size - 1), buffer, buffer.size))
                    }
                }
                if (play) {
                    report.put("stage", "player_open")
                    val plugin = DiagnosticRequests.current() ?: error("Player not running")
                    val id = plugin.requestMpvPlayerCommand(JSONObject().put("operation", "open").put("request_key", request)
                        .put("uri", uri).put("title", "115 playback check").put("stereo", false)
                        .put("profile", "384x216").put("enabled", false)
                        .put("benchmark", true).put("normal_fast", true).toString())
                    check(id > 0)
                    report.put("player_request", id)
                }
                report.put("stage", "complete").put("state", "passed")
            } catch (error: Exception) {
                report.put("state", "failed").put("error_type", error.javaClass.simpleName)
                    .put("reason", (error as? CloudFailure)?.reason)
                    .put("stack", JSONArray(error.stackTrace.filter { it.className.startsWith("org.vrpassthroughplayer") }
                        .take(8).map { "${it.className.substringAfterLast('.')}:${it.lineNumber}" }))
            } finally {
                File(context.filesDir, "diagnostics").mkdirs()
                File(context.filesDir, "diagnostics/cloud_probe_$request.json").writeText(report.toString())
            }
        }.start()
        return 1
    }
}
