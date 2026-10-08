package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test

class CloudAccountChangesTest {
    @Test fun renamePreservesLoginIdentityOrderAndOtherAccountsWithoutNetworking() {
        val saved = JSONArray("""[{"id":"a","provider":"115","name":"Old","cookie":"private-session"},{"id":"b","name":"Other","cookie":"other-session"}]""")
        val result = CloudAccountChanges.renamed(saved, "a", "  New name  ")
        assertEquals("New name", result.getJSONObject(0).getString("name"))
        assertEquals("a", result.getJSONObject(0).getString("id"))
        assertEquals("115", result.getJSONObject(0).getString("provider"))
        assertEquals("private-session", result.getJSONObject(0).getString("cookie"))
        assertEquals(saved.getJSONObject(1).toString(), result.getJSONObject(1).toString())
        assertEquals("Old", saved.getJSONObject(0).getString("name"))
        assertEquals(80, CloudAccountChanges.renamed(saved, "a", "x".repeat(100)).getJSONObject(0).getString("name").length)
    }
    @Test fun renameRejectsBlankNamesAndRemovedAccounts() {
        val saved = JSONArray("""[{"id":"a","name":"Old"}]""")
        try { CloudAccountChanges.renamed(saved, "a", "  "); fail() } catch (_: IllegalArgumentException) {}
        try { CloudAccountChanges.renamed(saved, "missing", "New"); fail() } catch (_: CloudFailure) {}
        assertEquals("Old", saved.getJSONObject(0).getString("name"))
    }
    @Test fun changeNotificationsDoNotNeedResumeAndUnsubscribeStopsDelivery() {
        var first = 0; var second = 0
        val a: () -> Unit = { first++ }; val b: () -> Unit = { second++ }
        CloudAccountChanges.subscribe(a); CloudAccountChanges.subscribe(b)
        try {
            CloudAccountChanges.emit()
            assertEquals(1, first); assertEquals(1, second)
            CloudAccountChanges.unsubscribe(a)
            CloudAccountChanges.emit()
            assertEquals(1, first); assertEquals(2, second)
        } finally { CloudAccountChanges.unsubscribe(a); CloudAccountChanges.unsubscribe(b) }
    }
}
