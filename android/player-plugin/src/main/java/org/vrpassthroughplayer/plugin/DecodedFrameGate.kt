package org.vrpassthroughplayer.plugin

/** One released Surface buffer at a time. Never relabel a coalesced/latest OES frame. */
internal class DecodedFrameGate(val scope: MediaSessionGate.Scope) {
    data class Ticket(val scope: MediaSessionGate.Scope, val frameId: Long, val ptsUs: Long,
                      val formatRevision: Int, val effectRevision: Int) {
        val timestampNs: Long get() = Math.multiplyExact(ptsUs, 1000L)
    }
    private var pending: Ticket? = null
    private var notified = false
    private var closed = false
    private var lastFrame = -1L

    @Synchronized fun begin(frameId: Long, ptsUs: Long, formatRevision: Int, effectRevision: Int): Ticket? {
        if (closed || pending != null) return null
        require(frameId > lastFrame && ptsUs in 0..Long.MAX_VALUE / 1000 && formatRevision > 0 && effectRevision > 0)
        return Ticket(scope, frameId, ptsUs, formatRevision, effectRevision).also {
            pending = it; notified = false; lastFrame = frameId
        }
    }
    @Synchronized fun notifyAvailable(): Boolean {
        if (closed) return false
        check(pending != null && !notified) { "Unexpected/coalesced Surface notification" }
        notified = true
        return true
    }
    @Synchronized fun available(): Ticket? = if (!closed && notified) pending else null
    @Synchronized fun verify(ticket: Ticket, timestampNs: Long): Boolean {
        if (closed || pending != ticket || !notified) return false
        check(timestampNs == ticket.timestampNs) { "Surface timestamp differs from controlled output PTS" }
        return true
    }
    /** Credit is returned after the GPU copy/staging fence, not after codec release. */
    @Synchronized fun complete(ticket: Ticket): Boolean {
        if (closed || pending != ticket || !notified) return false
        pending = null; notified = false
        return true
    }
    @Synchronized fun idle() = !closed && pending == null
    @Synchronized fun close() { closed = true; pending = null; notified = false }
}
