package org.vrpassthroughplayer.plugin

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

internal object LocalAccessProbe {
    private val ids = AtomicInteger()
    fun request(context: Context, case: String): Int {
        require(case in setOf("file_present", "file_missing", "content_present", "content_missing", "content_denied", "cancel", "timeout", "external_check", "external_take", "external_release"))
        val id = ids.incrementAndGet()
        val path = if (case == "cancel" || case == "timeout") "slow" else case.substringAfter('_')
        val fixture = File(context.cacheDir, "local-access-file.bin")
        if (case == "file_present") fixture.writeBytes(byteArrayOf(0, 1, 2, 3))
        val uri = if (case.startsWith("external_")) "content://org.vrpassthroughplayer.urifixture.documents/document/clip"
            else if (case.startsWith("file_")) "file://${if (case == "file_present") fixture.absolutePath else File(context.cacheDir, "missing-access-file.bin").absolutePath}"
            else "content://${context.packageName}.accessfixture/$path"
        val taken = if (case == "external_take") LocalDocumentGrant.take(context, Uri.parse(uri), Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION) else false
        var released = false
        if (case == "external_release") {
            try { context.contentResolver.releasePersistableUriPermission(Uri.parse(uri), Intent.FLAG_GRANT_READ_URI_PERMISSION); released = true }
            catch (_: SecurityException) { }
        }
        val started = SystemClock.elapsedRealtime()
        lateinit var access: LocalVideoAccess
        access = LocalVideoAccess({ context }) { resultId, payload ->
            val report = JSONObject(payload).put("request_id", resultId).put("case", case)
                .put("diagnostic_process", DiagnosticRequests.processId)
                .put("elapsed_ms", SystemClock.elapsedRealtime()-started)
                .put("client_uid", android.os.Process.myUid()).put("grant_taken", taken).put("grant_released", released)
                .put("persisted_permission_snapshot", context.contentResolver.persistedUriPermissions.any { it.uri.toString() == uri && it.isReadPermission })
                .put("scope", if (case.startsWith("external_")) "Actual separate DocumentsProvider UID grant/readability; system picker UI, device reboot, catalog and MPV decode not exercised" else "Actual private Debug provider/file readability, cancellation and timeout; external SAF grant/reboot and video decode not exercised")
            val directory = File(context.filesDir, "diagnostics").apply { mkdirs() }
            val temporary = File.createTempFile("access-probe-", ".tmp", directory)
            try { temporary.writeText(report.toString()); check(temporary.renameTo(File(directory, "local_access_$id.json"))) }
            finally { temporary.delete(); access.close() }
        }
        if (!access.request(id, uri)) { access.close(); return -1 }
        if (case == "cancel") Handler(Looper.getMainLooper()).postDelayed({ access.cancel(id) }, 200)
        return id
    }
}
