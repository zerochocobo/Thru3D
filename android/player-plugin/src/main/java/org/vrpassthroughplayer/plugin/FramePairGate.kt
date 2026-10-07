package org.vrpassthroughplayer.plugin

/** Processing revisions are independent of the immutable decoder ticket. A mode
 * change may process the same retained color again, but never relabel its source. */
internal class FramePairGate(private val scope: MediaSessionGate.Scope) {
    data class Identity(val decoderId: Int, val logicalSessionId: Int, val generation: Int,
        val frameId: Long, val ptsUs: Long, val formatRevision: Int, val effectRevision: Long,
        val modelGeneration: Long, val slotToken: Long)
    private var alive = true
    private var format = 1
    private var effect = 1L
    private var model = 1L
    private var alpha = false
    private var presentedFrame = -1L
    private var presentedPts = -1L

    @Synchronized fun setAlpha(enabled: Boolean): Long {
        check(alive)
        if (alpha != enabled) { advance(); alpha = enabled }
        return effect
    }
    @Synchronized fun setFormat(revision: Int) {
        check(alive && revision >= format && revision > 0)
        if (revision != format) { advance(); format = revision }
    }
    private fun advance() {
        check(effect < Long.MAX_VALUE && model < Long.MAX_VALUE)
        effect++; model++
    }
    @Synchronized fun alphaRequested() = alive && alpha
    @Synchronized fun effectRevision() = effect
    @Synchronized fun modelGeneration() = model
    @Synchronized fun identify(ticket: DecodedFrameGate.Ticket, token: Long): Identity? {
        if (!alive || ticket.scope != scope || ticket.formatRevision != format || token <= 0 ||
            ticket.frameId < 0 || ticket.ptsUs < 0) return null
        return Identity(scope.decoderId, scope.logicalSessionId, scope.generation, ticket.frameId,
            ticket.ptsUs, ticket.formatRevision, effect, model, token)
    }
    @Synchronized fun accepts(id: Identity): Boolean = alive && id.decoderId == scope.decoderId &&
        id.logicalSessionId == scope.logicalSessionId && id.generation == scope.generation &&
        id.formatRevision == format && id.effectRevision == effect && id.modelGeneration == model &&
        id.slotToken > 0 && id.frameId >= presentedFrame && id.ptsUs >= presentedPts

    @Synchronized fun matchesRuntime(id: Identity, logicalSession: Long, modelGeneration: Long,
        frameId: Long, ptsUs: Long): Boolean = accepts(id) && logicalSession == id.logicalSessionId.toLong() &&
        modelGeneration == id.modelGeneration && frameId == id.frameId && ptsUs == id.ptsUs

    @Synchronized fun presented(id: Identity): Boolean {
        if (!accepts(id)) return false
        presentedFrame = id.frameId; presentedPts = id.ptsUs
        return true
    }
    @Synchronized fun close() { alive = false }
}
