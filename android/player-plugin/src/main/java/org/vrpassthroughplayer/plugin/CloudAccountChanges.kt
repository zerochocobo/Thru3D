package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArraySet

/** In-process store events contain no account data and do not depend on Activity resume. */
internal object CloudAccountChanges {
    private val listeners = CopyOnWriteArraySet<() -> Unit>()
    fun subscribe(listener: () -> Unit) { listeners.add(listener) }
    fun unsubscribe(listener: () -> Unit) { listeners.remove(listener) }
    fun emit() { listeners.forEach { it() } }

    fun renamed(accounts: JSONArray, id: String, name: String): JSONArray {
        val title = name.trim().take(80)
        require(title.isNotEmpty())
        var found = false
        val updated = JSONArray()
        for (i in 0 until accounts.length()) {
            val item = JSONObject(accounts.getJSONObject(i).toString())
            if (item.getString("id") == id) { item.put("name", title); found = true }
            updated.put(item)
        }
        if (!found) throw CloudFailure("cloud_login_required")
        return updated
    }
}
