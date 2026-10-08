package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class AccountSessionGuardTest {
    @Test fun cancelledNetworkResponseCannotSave() {
        val gate = AccountSessionGuard()
        val ready = CountDownLatch(1); val response = CountDownLatch(1)
        val saved = AtomicInteger()
        val worker = Executors.newSingleThreadExecutor()
        try {
            val future = worker.submit<Boolean> {
                ready.countDown(); check(response.await(3, TimeUnit.SECONDS))
                runCatching { gate.commitSession { saved.incrementAndGet() } }.isSuccess
            }
            assertTrue(ready.await(3, TimeUnit.SECONDS))
            gate.cancelSession {}; response.countDown()
            assertFalse(future.get(3, TimeUnit.SECONDS)); assertEquals(0, saved.get())
        } finally { response.countDown(); worker.shutdownNow() }
    }
    @Test fun cancellationClearsInputsAndCannotBeReused() {
        val gate = AccountSessionGuard(); val secret = AccountInput()
        secret.append("transient")
        gate.commitSession { assertEquals(9, secret.length) }
        gate.cancelSession { secret.clear() }
        assertTrue(gate.cancelled); assertEquals(0, secret.length)
        assertTrue(runCatching { gate.commitSession { secret.append("late") } }.isFailure)
        assertEquals(0, secret.length)
    }
}
