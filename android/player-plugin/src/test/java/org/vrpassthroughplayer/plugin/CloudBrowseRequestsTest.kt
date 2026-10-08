package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.Collections

class CloudBrowseRequestsTest {
    @Test fun switchingDirectoryDisconnectsOldRequestAndOnlyNewPageIsEmitted() {
        val requests = CloudBrowseRequests()
        val started = CountDownLatch(1)
        val disconnected = CountDownLatch(1)
        val done = CountDownLatch(1)
        val emitted = Collections.synchronizedList(ArrayList<Int>())
        val connection = object : HttpURLConnection(URL("https://webapi.115.com/files")) {
            override fun connect() {}
            override fun usingProxy() = false
            override fun disconnect() { disconnected.countDown() }
        }
        try {
            requests.submit(1, { cancellation ->
                cancellation.attach(connection); started.countDown()
                try { disconnected.await(5, TimeUnit.SECONDS) } catch (_: InterruptedException) {}
                "obsolete"
            }, { id, _ -> emitted.add(id) })
            assertTrue(started.await(5, TimeUnit.SECONDS))
            requests.submit(2, { "new page" }, { id, _ -> emitted.add(id); done.countDown() })
            requests.cancel(1) // An old UI callback must not cancel the new directory.
            assertTrue(disconnected.await(5, TimeUnit.SECONDS))
            assertTrue(done.await(5, TimeUnit.SECONDS))
            assertEquals(listOf(2), emitted)
        } finally { requests.close() }
    }
    @Test fun cancelledRequestCannotAttachAnotherConnection() {
        val cancellation = CloudCancellation()
        var disconnected = false
        cancellation.cancel()
        val connection = object : HttpURLConnection(URL("https://webapi.115.com/files")) {
            override fun connect() {}
            override fun usingProxy() = false
            override fun disconnect() { disconnected = true }
        }
        try { cancellation.attach(connection); fail() } catch (_: CloudFailure) {}
        assertTrue(disconnected)
    }
}
