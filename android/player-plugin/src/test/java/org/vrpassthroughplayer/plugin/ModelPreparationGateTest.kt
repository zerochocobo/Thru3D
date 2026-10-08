package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class ModelPreparationGateTest {
    @Test fun serializeWorkersAndReleaseAfterFailure() {
        val running=AtomicInteger(); val maximum=AtomicInteger()
        val workers=Executors.newFixedThreadPool(4)
        try {
            val jobs=(1..40).map { workers.submit {
                ModelPreparationGate.run {
                    val n=running.incrementAndGet(); maximum.accumulateAndGet(n,::maxOf)
                    try { Thread.yield() } finally { running.decrementAndGet() }
                }
            } }
            jobs.forEach { it.get(5,TimeUnit.SECONDS) }
            assertEquals(1,maximum.get())
            try { ModelPreparationGate.run { throw IllegalStateException("test") } } catch (_: IllegalStateException) {}
            assertEquals(7,ModelPreparationGate.run { 7 })
        } finally { workers.shutdownNow() }
    }
}
