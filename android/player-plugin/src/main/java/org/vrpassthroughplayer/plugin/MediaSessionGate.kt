package org.vrpassthroughplayer.plugin

/** Invalidates queued work immediately, before UI/GL resource teardown completes. */
internal class MediaSessionGate {
    data class Scope(val decoderId: Int, val logicalSessionId: Int, val generation: Int)
    private var sequence = 0
    private var logicalSequence = 0
    @Volatile private var scope: Scope? = null
    @Volatile private var closed = false

    @Synchronized fun begin(): Int {
        if (closed) return -1
        check(sequence < Int.MAX_VALUE && logicalSequence < Int.MAX_VALUE) { "Media session ID exhausted" }
        sequence += 1
        logicalSequence += 1
        scope = Scope(sequence, logicalSequence, 1)
        return sequence
    }

    fun accepts(id: Int): Boolean = !closed && id > 0 && id == scope?.decoderId

    @Synchronized fun current(id: Int): Scope? = if (accepts(id)) scope else null

    /** New producer resources, same logical media. The old decoder is stale immediately. */
    @Synchronized fun replace(id: Int): Int {
        val previous = current(id) ?: return -1
        check(sequence < Int.MAX_VALUE && previous.generation < Int.MAX_VALUE) { "Media generation exhausted" }
        sequence += 1
        scope = Scope(sequence, previous.logicalSessionId, previous.generation + 1)
        return sequence
    }

    @Synchronized fun invalidate(id: Int): Boolean {
        if (!accepts(id)) return false
        scope = null
        return true
    }

    @Synchronized fun shutdown() {
        closed = true
        scope = null
    }
}
