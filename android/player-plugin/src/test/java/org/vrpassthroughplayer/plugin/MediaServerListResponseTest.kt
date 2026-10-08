package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class MediaServerListResponseTest {
    private fun response(accounts: () -> List<MediaServerAccount>): JSONObject {
        val done = CountDownLatch(1)
        var result: JSONObject? = null
        var responseId = 0
        val library = MediaServerLibrary({ null }, { error("No network required to list accounts") }, { 73 }, accounts) { id, json ->
            responseId = id; result = JSONObject(json); done.countDown()
        }
        try {
            assertEquals(73, library.request("""{"action":"servers","server_id":"","generation":12}"""))
            assertTrue("Native worker must answer", done.await(5, TimeUnit.SECONDS))
            assertEquals(73, responseId)
            return result!!.also {
                assertEquals("servers", it.getString("action"))
                assertEquals("medialib", it.getString("source"))
                assertEquals("", it.getString("server_id"))
                assertEquals(12, it.getInt("generation"))
            }
        } finally { library.close() }
    }

    @Test fun storedServersHaveReadyStateAndDisplayMetadataWithoutCredentials() {
        val result = response { listOf(
            MediaServerAccount("stash-local", "Local Stash", "http://nas:9999", "private-api-key"),
            MediaServerAccount("emby", "Emby", "http://nas:8096", "private-token", "emby", "private-user-id", "private-username")
        ) }
        assertEquals("ready", result.optString("state"))
        val servers = result.getJSONArray("servers")
        assertEquals(2, servers.length())
        assertEquals("stash", servers.getJSONObject(0).getString("provider"))
        assertEquals("Local Stash", servers.getJSONObject(0).getString("name"))
        assertEquals("emby", servers.getJSONObject(1).getString("provider"))
        assertFalse(result.toString().contains("private-"))
    }
    @Test fun emptyStoreStillReturnsReadyRatherThanAnError() {
        val result = response { emptyList() }
        assertEquals("ready", result.optString("state"))
        assertEquals(0, result.getJSONArray("servers").length())
    }
    @Test fun unreadableStoreReturnsExplicitSanitizedError() {
        val result = response { throw IllegalStateException("private-key-details") }
        assertEquals("error", result.getString("state"))
        assertEquals("Server unavailable", result.getString("error"))
        assertFalse(result.toString().contains("private-"))
    }
}
