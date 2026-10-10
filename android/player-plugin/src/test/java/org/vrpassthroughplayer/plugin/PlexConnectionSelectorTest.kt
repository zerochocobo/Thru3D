package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class PlexConnectionSelectorTest {
    private fun resource(required: Boolean = false) = PlexAuth.parseServers(JSONArray("""[{
        "clientIdentifier":"machine","provides":"server","accessToken":"private-token","httpsRequired":$required,
        "connections":[
          {"uri":"https://10-147-20-7.machine.plex.direct:32400","address":"10.147.20.7","port":32400,"local":true},
          {"uri":"https://192-168-31-185.machine.plex.direct:32400","address":"192.168.31.185","port":32400,"local":true},
          {"uri":"https://relay.plex.direct:8443","address":"45.79.112.167","port":8443,"relay":true}
        ]}]""")).single()
    private fun account(connection: PlexAuth.Connection) = MediaServerAccount("fixture", "Plex", connection.base, "token", "plex", "machine")
    @Test fun advertisedHttpsOnlyUrisAlsoExposePermittedLanIpAndPreferCurrentSubnet() {
        val server = resource()
        assertEquals(5, server.connections.size)
        val preferred = PlexAuth.preferredConnections(server.connections, listOf(MediaServerDiscovery.Subnet("192.168.31.112", 24)))
        assertEquals("https://192-168-31-185.machine.plex.direct:32400", preferred[0].base)
        assertEquals("http://192.168.31.185:32400", preferred[1].base)
        assertEquals("http://10.147.20.7:32400", preferred[3].base)
        assertTrue(preferred.last().relay)
        assertFalse(server.publicJson().toString().contains("private-token"))
    }
    @Test fun secureOnlyAndRemoteRelayConnectionsNeverGeneratePlaintextFallbacks() {
        val required = resource(true)
        assertTrue(required.httpsRequired)
        assertEquals(3, required.connections.size)
        assertTrue(required.connections.all { it.base.startsWith("https://") })
        val parsed = PlexAuth.parseServers(JSONArray("""[{"clientIdentifier":"m","provides":"server","accessToken":"t","connections":[
          {"uri":"https://remote.plex.direct:32400","address":"192.168.31.185","port":32400,"local":false},
          {"uri":"https://relay.plex.direct:443","address":"192.168.31.185","port":443,"local":true,"relay":true},
          {"uri":"https://public.plex.direct:32400","address":"8.8.8.8","port":32400,"local":true},
          {"uri":"https://loop.plex.direct:32400","address":"127.0.0.1","port":32400,"local":true}
        ]}]""")).single()
        assertEquals(3, parsed.connections.size)
        assertTrue(parsed.connections.all { it.base.startsWith("https://") })
    }
    @Test fun failedTlsAndUnreachableVirtualInterfaceDoNotHideWorkingLanConnection() {
        val targets = PlexAuth.preferredConnections(resource().connections, listOf(MediaServerDiscovery.Subnet("192.168.31.112", 24)))
        val blocked = CountDownLatch(1); val closed = AtomicBoolean()
        val start = System.nanoTime()
        val selected = PlexConnectionSelector.select(targets, { false }, { closed.set(true); blocked.countDown() }, 1000) { connection ->
            when {
                connection.base == "http://192.168.31.185:32400" -> account(connection)
                connection.address == "10.147.20.7" -> { blocked.await(); throw MediaServerFailure("Server unavailable") }
                else -> throw MediaServerFailure("Server unavailable")
            }
        }
        assertEquals("http://192.168.31.185:32400", selected.base)
        assertTrue(closed.get())
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start) < 1500)
    }
    @Test fun canonicalPlexDirectLanHostCanBeUsedWhenAddressFieldIsMissing() {
        val parsed = PlexAuth.parseServers(JSONArray("""[{"clientIdentifier":"m","provides":"server","accessToken":"t","connections":[
          {"uri":"https://192-168-31-185.5fa48f8ca123479db4874176c0108a69.plex.direct:32400","local":true},
          {"uri":"https://127-0-0-1.5fa48f8ca123479db4874176c0108a69.plex.direct:32400","local":true}
        ]}]""")).single()
        assertEquals(2, parsed.connections.size)
        assertEquals("192.168.31.185", parsed.connections.first().address)
        assertEquals("http://192.168.31.185:32400", parsed.connections.last().base)
    }
    @Test fun deadlineCanUseValidatedFallbackAndCancelsHungPreferredProbe() {
        val blocked = CountDownLatch(1); val closed = AtomicBoolean()
        val targets = listOf(PlexAuth.Connection("https://nas", true, false), PlexAuth.Connection("http://nas", true, false))
        val start = System.nanoTime()
        val selected = PlexConnectionSelector.select(targets, { false }, { closed.set(true); blocked.countDown() }, 200) { connection ->
            if (connection.base.startsWith("https://")) { blocked.await(); throw MediaServerFailure("Server unavailable") }
            account(connection)
        }
        assertEquals("http://nas", selected.base); assertTrue(closed.get())
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start) < 1200)
    }
    @Test fun healthyPreferredHttpsWinsEvenIfHttpFinishesFirst() {
        val fallbackReady = CountDownLatch(1)
        val targets = listOf(PlexAuth.Connection("https://nas", true, false), PlexAuth.Connection("http://nas", true, false))
        val selected = PlexConnectionSelector.select(targets, { false }, {}, 1000) { connection ->
            if (connection.base.startsWith("https://")) assertTrue(fallbackReady.await(1, TimeUnit.SECONDS))
            else fallbackReady.countDown()
            account(connection)
        }
        assertEquals("https://nas", selected.base)
    }
    @Test fun cancelledSelectionDoesNotReturnLateAccountOrLoseAuthFailures() {
        val cancelled = AtomicBoolean(); val closed = AtomicBoolean()
        val target = listOf(PlexAuth.Connection("http://nas", true, false))
        val error = assertThrows(MediaServerFailure::class.java) {
            PlexConnectionSelector.select(target, { cancelled.get() }, { closed.set(true) }, 1000) {
                cancelled.set(true); account(it)
            }
        }
        assertEquals("Request cancelled", error.code); assertTrue(closed.get())
        assertEquals("Server authentication required", assertThrows(MediaServerFailure::class.java) {
            PlexConnectionSelector.select(target, { false }, {}, 1000) { throw MediaServerFailure("Server authentication required", 401) }
        }.code)
    }
}
