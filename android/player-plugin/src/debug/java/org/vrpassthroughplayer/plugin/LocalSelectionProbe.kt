package org.vrpassthroughplayer.plugin

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/** Real production selection coordinator + provider/worker/Handler, no Activity needed. */
internal object LocalSelectionProbe {
    private val ids = AtomicInteger()
    fun request(context: Context, case: String): Int {
        require(case in setOf("unicode", "long", "blank", "no_column", "metadata_denied", "missing", "permission_denied", "cancel", "timeout", "replace_late", "close_late", "external"))
        val id = ids.incrementAndGet()
        val main = Handler(Looper.getMainLooper())
        main.post {
            val events = JSONArray()
            val started = SystemClock.elapsedRealtime()
            var lastBeat = started
            var beats = 0
            var maxGap = 0L
            var returnMs = 0L
            var allEventsMain = true
            val selection = LocalVideoSelection({ context }) { payload ->
                allEventsMain = allEventsMain && Looper.myLooper() == Looper.getMainLooper()
                events.put(JSONObject(payload).put("elapsed_ms", SystemClock.elapsedRealtime() - started))
            }
            val authority = "content://${context.packageName}.accessfixture/"
            val path = when (case) {
                "unicode" -> "name_unicode"
                "long" -> "name_long"
                "blank" -> "name_blank"
                "no_column" -> "name_no_column"
                "metadata_denied" -> "name_denied"
                "missing" -> "missing"
                "permission_denied" -> "denied"
                "replace_late", "close_late" -> "name_late"
                else -> "name_slow"
            }
            val uri = if (case == "external") "content://org.vrpassthroughplayer.urifixture.documents/document/clip" else authority+path
            val before = SystemClock.elapsedRealtime()
            val accepted = selection.start(uri, if (case == "external") Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION else 0)
            returnMs = SystemClock.elapsedRealtime()-before
            if (case == "cancel") main.postDelayed({ selection.cancel() }, 200)
            if (case == "replace_late") main.postDelayed({ selection.start(authority+"name_unicode", 0) }, 100)
            if (case == "close_late") main.postDelayed({ selection.close() }, 100)
            val duration = when (case) {
                "timeout" -> 11000L
                "replace_late", "close_late" -> 1800L
                "cancel" -> 800L
                else -> 400L
            }
            lateinit var heartbeat: Runnable
            heartbeat = Runnable {
                val now = SystemClock.elapsedRealtime()
                maxGap = maxOf(maxGap, now-lastBeat)
                lastBeat = now
                beats++
                main.postDelayed(heartbeat, 50)
            }
            main.postDelayed(heartbeat, 50)
            main.postDelayed({
                main.removeCallbacks(heartbeat)
                selection.close()
                val report = JSONObject().put("request_id", id).put("case", case).put("uri", uri)
                    .put("events", events).put("diagnostic_process", DiagnosticRequests.processId)
                    .put("accepted", accepted).put("start_return_ms", returnMs).put("main_heartbeat_count", beats)
                    .put("main_max_gap_ms", maxGap).put("all_events_main", allEventsMain)
                    .put("elapsed_ms", SystemClock.elapsedRealtime()-started)
                    .put("scope", "Actual production selection/metadata worker/Handler and private provider; real system picker result, external grant, Godot/XR and decode not exercised")
                val directory = File(context.filesDir, "diagnostics").apply { mkdirs() }
                val temporary = File.createTempFile("selection-probe-", ".tmp", directory)
                try { temporary.writeText(report.toString()); check(temporary.renameTo(File(directory, "selection_$id.json"))) }
                finally { temporary.delete() }
            }, duration)
        }
        return id
    }
}
