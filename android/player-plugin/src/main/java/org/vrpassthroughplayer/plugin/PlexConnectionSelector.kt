package org.vrpassthroughplayer.plugin

import java.util.concurrent.Callable
import java.util.concurrent.ExecutorCompletionService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit

/** Race bounded probes while preserving the preferred address order. No probe persists an account. */
internal object PlexConnectionSelector {
    fun select(connections: List<PlexAuth.Connection>, cancelled: () -> Boolean, closeProbes: () -> Unit,
        timeoutMs: Long = 12000, probe: (PlexAuth.Connection) -> MediaServerAccount): MediaServerAccount {
        mediaRequire(connections.isNotEmpty(), "Server unavailable")
        val pool = Executors.newFixedThreadPool(4) { Thread(it, "PlexConnect").apply { isDaemon = true } }
        data class Attempt(val index: Int, val account: MediaServerAccount?, val failure: MediaServerFailure?)
        val completion = ExecutorCompletionService<Attempt>(pool)
        val futures = ArrayList<Future<Attempt>>()
        val targets = connections.take(12)
        val done = HashSet<Int>(); val ready = HashMap<Int, MediaServerAccount>()
        var failure = MediaServerFailure("Server unavailable")
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        try {
            targets.forEachIndexed { index, connection -> futures.add(completion.submit(Callable {
                try {
                    mediaRequire(!cancelled() && !Thread.currentThread().isInterrupted, "Request cancelled")
                    Attempt(index, probe(connection), null)
                } catch (error: Exception) {
                    Attempt(index, null, error as? MediaServerFailure)
                }
            })) }
            while (done.size < targets.size) {
                mediaRequire(!cancelled(), "Request cancelled")
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0) break
                val future = completion.poll(minOf(remaining, TimeUnit.MILLISECONDS.toNanos(100)), TimeUnit.NANOSECONDS) ?: continue
                val attempt = future.get(); done.add(attempt.index)
                attempt.account?.let { ready[attempt.index] = it }
                if (attempt.failure?.code == "Server authentication required") failure = attempt.failure
                val preferred = ready.keys.minOrNull()
                mediaRequire(!cancelled(), "Request cancelled")
                if (preferred != null && (0 until preferred).all { it in done }) return ready.getValue(preferred)
            }
            mediaRequire(!cancelled(), "Request cancelled")
            return ready.keys.minOrNull()?.let { ready.getValue(it) } ?: throw failure
        } finally {
            futures.forEach { it.cancel(true) }
            closeProbes(); pool.shutdownNow()
        }
    }
}
