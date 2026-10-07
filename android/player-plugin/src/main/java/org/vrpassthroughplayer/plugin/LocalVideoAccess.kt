package org.vrpassthroughplayer.plugin

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.OperationCanceledException
import android.os.Process
import android.provider.OpenableColumns
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Bounded, cancellable permission/readability preflight. Does not alter playback. */
internal class LocalVideoAccess(private val context: () -> Context?, private val emit: (Int, String) -> Unit) {
    private class Request(val uri: String) {
        val cancellation = CancellationSignal()
        val finished = AtomicBoolean(false)
        lateinit var timeout: Runnable
    }
    private val requests = ConcurrentHashMap<Int, Request>()
    private val closed = AtomicBoolean(false)
    private val main = Handler(Looper.getMainLooper())
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(1),
        { task -> Thread(task, "QuestLocalAccess") }, ThreadPoolExecutor.AbortPolicy())

    fun request(id: Int, text: String): Boolean = submit(id, text, null)

    fun requestDocument(id: Int, text: String, grantFlags: Int): Boolean =
        Uri.parse(text).scheme == "content" && submit(id, text, grantFlags)

    private fun submit(id: Int, text: String, grantFlags: Int?): Boolean {
        if (closed.get() || id <= 0 || text.length !in 1..8192 || Uri.parse(text).scheme !in setOf("content", "file")) return false
        val request = Request(text)
        request.timeout = Runnable {
            finish(id, request, "error", "LOCAL_DOCUMENT_TIMEOUT")
            request.cancellation.cancel()
        }
        requests[id] = request
        // Install the deadline before a fast worker can complete and remove it.
        main.postDelayed(request.timeout, 10_000)
        try {
            worker.execute {
                try {
                    if (request.finished.get() || closed.get()) return@execute
                    val host = context() ?: error("Activity unavailable")
                    val uri = Uri.parse(text)
                    if (grantFlags != null) LocalDocumentGrant.take(host, uri, grantFlags)
                    val persisted = if (uri.scheme == "content") {
                        host.contentResolver.openFileDescriptor(uri, "r", request.cancellation)?.use { }
                            ?: throw FileNotFoundException()
                        host.contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }
                    } else {
                        val file = File(uri.path ?: throw FileNotFoundException())
                        if (!file.isFile) throw FileNotFoundException()
                        file.inputStream().use { }
                        true
                    }
                    var name = "Local video"
                    if (grantFlags != null) {
                        try {
                            host.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null, request.cancellation)?.use { cursor ->
                                if (cursor.moveToFirst()) {
                                    val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                                    if (column >= 0) name = cursor.getString(column) ?: name
                                }
                            }
                        } catch (cancelled: OperationCanceledException) { throw cancelled }
                        catch (_: SecurityException) { /* Readable FD can lack optional metadata access. */ }
                        catch (_: Exception) { /* Metadata is optional once the FD is readable. */ }
                        name = name.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ')
                        name = name.substring(0, name.offsetByCodePoints(0, minOf(256, name.codePointCount(0, name.length))))
                        if (name.isBlank()) name = "Local video"
                    }
                    finish(id, request, "readable", persisted = persisted, displayName = name)
                } catch (_: SecurityException) { finish(id, request, "error", "LOCAL_DOCUMENT_PERMISSION_LOST") }
                catch (_: FileNotFoundException) {
                    // Android may hide an ungranted external provider and throw
                    // FileNotFoundException before its read-permission check.
                    val host = context()
                    val uri = Uri.parse(text)
                    val lost = host != null && uri.scheme == "content" && !runCatching { mayReadProvider(host, uri) }.getOrDefault(false)
                    finish(id, request, "error", if (lost) "LOCAL_DOCUMENT_PERMISSION_LOST" else "LOCAL_DOCUMENT_MISSING")
                }
                catch (_: OperationCanceledException) { finish(id, request, "error", "LOCAL_DOCUMENT_CANCELLED") }
                catch (_: Exception) { finish(id, request, "error", "LOCAL_DOCUMENT_UNREADABLE") }
            }
            return true
        } catch (_: RejectedExecutionException) {
            main.removeCallbacks(request.timeout)
            requests.remove(id)
            return false
        }
    }

    private fun mayReadProvider(host: Context, uri: Uri): Boolean {
        if (host.checkUriPermission(uri, Process.myPid(), Process.myUid(), Intent.FLAG_GRANT_READ_URI_PERMISSION) == PackageManager.PERMISSION_GRANTED) return true
        val info = host.packageManager.resolveContentProvider(uri.authority ?: return false, 0) ?: return false
        if (info.applicationInfo.uid == Process.myUid()) return true
        return info.exported && (info.readPermission == null || host.checkSelfPermission(info.readPermission) == PackageManager.PERMISSION_GRANTED)
    }

    private fun finish(id: Int, request: Request, state: String, error: String = "", persisted: Boolean = false, displayName: String = "Local video") {
        if (!request.finished.compareAndSet(false, true)) return
        main.removeCallbacks(request.timeout)
        requests.remove(id)
        if (!closed.get()) emit(id, JSONObject().put("uri", request.uri).put("state", state)
            .put("error", error).put("persisted_permission", persisted).put("display_name", displayName).toString())
    }

    fun cancel(id: Int) {
        val request = requests[id] ?: return
        finish(id, request, "error", "LOCAL_DOCUMENT_CANCELLED")
        request.cancellation.cancel()
    }

    fun close() {
        closed.set(true)
        requests.keys.toList().forEach(::cancel)
        worker.shutdownNow()
    }
}
