package org.vrpassthroughplayer.plugin

import android.content.Context
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

/** Main-thread selection state; provider/grant/metadata work stays on the bounded worker. */
internal class LocalVideoSelection(context: () -> Context?, private val event: (String) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val closed = AtomicBoolean(false)
    private var nextId = 0
    private var current = 0
    private val access = LocalVideoAccess(context) { id, payload ->
        main.post {
            if (closed.get() || id != current) return@post
            current = 0
            val result = JSONObject(payload)
            result.put("selection_id", id)
            result.put("state", if (result.optString("state") == "readable") "selected" else if (result.optString("error") == "LOCAL_DOCUMENT_CANCELLED") "cancelled" else "error")
            event(result.toString())
        }
    }
    fun start(uri: String, flags: Int): Boolean {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (closed.get()) return false
        cancel(false)
        val id = ++nextId
        current = id
        if (!access.requestDocument(id, uri, flags)) {
            current = 0
            event(JSONObject().put("state", "error").put("error", "LOCAL_DOCUMENT_BUSY").put("selection_id", id).toString())
            return false
        }
        event(JSONObject().put("state", "checking").put("selection_id", id).toString())
        return true
    }
    fun cancel(notify: Boolean = true) {
        check(Looper.myLooper() == Looper.getMainLooper())
        val old = current
        current = 0 // Invalidate before cancellation can produce its callback.
        if (old > 0) {
            access.cancel(old)
            if (notify && !closed.get()) event(JSONObject().put("state", "cancelled").put("selection_id", old).toString())
        }
    }
    fun close() {
        closed.set(true)
        access.close()
    }
}
