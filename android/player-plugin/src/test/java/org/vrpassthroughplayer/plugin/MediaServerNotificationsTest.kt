package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class MediaServerNotificationsTest {
    @Test fun accountInvalidationNotifiesLiveMenusWithoutLifecycleOrCredentials() {
        val events = ArrayList<Pair<Int, String>>()
        val library = MediaServerLibrary({ null }, { error("No stream needed") }, { 1 }) { id, json ->
            events.add(id to json)
        }
        try {
            MediaServerLibrary.invalidate("private-server-id")
            assertEquals(1, events.size)
            assertEquals(0, events.single().first)
            val event = JSONObject(events.single().second)
            assertEquals("medialib", event.getString("source"))
            assertEquals("accounts_changed", event.getString("state"))
            assertEquals(setOf("source", "state"), event.keys().asSequence().toSet())
        } finally { library.close() }
        MediaServerLibrary.invalidate("private-server-id")
        assertEquals("Closed libraries must stop receiving changes", 1, events.size)
    }
}
