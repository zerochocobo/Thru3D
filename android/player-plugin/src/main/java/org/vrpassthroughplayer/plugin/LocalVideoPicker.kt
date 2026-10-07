package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import org.json.JSONObject

/** System UI and selection coordination on main; all provider work is asynchronous. */
internal class LocalVideoPicker(
    private val host: () -> Activity?,
    private val event: (String) -> Unit,
) {
    private var pending = false
    private var code = 0x5650
    private var request = 0
    private val selection = LocalVideoSelection({ host()?.applicationContext }) { payload ->
        event(JSONObject(payload).put("picker_request", request).toString())
    }

    fun open(id: Int) {
        if (pending) return
        selection.cancel(false)
        request = id
        val activity = host() ?: return report("error", "ACTIVITY_UNAVAILABLE")
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "video/*"
            putExtra(Intent.EXTRA_LOCAL_ONLY, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try {
            pending = true
            code = if (code == 0x7fff) 0x5650 else code + 1
            activity.startActivityForResult(intent, code)
            report("opening")
        } catch (_: ActivityNotFoundException) {
            pending = false
            report("error", "DOCUMENT_PICKER_UNAVAILABLE")
        } catch (_: SecurityException) {
            pending = false
            report("error", "DOCUMENT_PICKER_DENIED")
        }
    }

    fun result(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != code || !pending) return
        pending = false
        if (resultCode != Activity.RESULT_OK) return report("cancelled")
        val uri: Uri = data?.data ?: return report("error", "DOCUMENT_URI_MISSING")
        if (uri.scheme != "content") return report("error", "DOCUMENT_URI_UNSUPPORTED")
        selection.start(uri.toString(), data.flags)
    }

    private fun report(state: String, error: String = "") {
        event(JSONObject().put("state", state).put("error", error).put("picker_request", request).toString())
    }

    fun cancel(id: Int) {
        if (id != request) return
        if (pending) host()?.finishActivity(code)
        pending = false
        selection.cancel()
    }

    fun close() { selection.close() }
}
