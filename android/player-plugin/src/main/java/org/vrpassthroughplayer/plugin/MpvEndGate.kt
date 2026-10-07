package org.vrpassthroughplayer.plugin

/** EOF is complete only after its exact source has a complete pair acknowledged
 * by the display and observed in the subsequent owner draw callback. */
internal class MpvEndGate(private val scope: MediaSessionGate.Scope, private val alpha: Boolean) {
    data class Source(val epoch: Long, val frameId: Long, val ptsUs: Long)
    private var target: Source? = null
    private var drawn: Source? = null
    private var drawnSlot = 0L

    fun observe(source: Source?) {
        target = source?.takeIf { it.epoch > 0 && it.frameId > 0 && it.ptsUs >= 0 }
    }
    fun postDraw(pair: FramePairGate.Identity, sourceEpoch: Long, inferenceRan: Boolean): Boolean {
        if (pair.decoderId != scope.decoderId || pair.logicalSessionId != scope.logicalSessionId ||
            pair.generation != scope.generation || pair.slotToken <= 0 || pair.frameId <= 0 || pair.ptsUs < 0 ||
            pair.formatRevision <= 0 || pair.effectRevision <= 0 || pair.modelGeneration <= 0 ||
            sourceEpoch <= 0 || (alpha && !inferenceRan)) return false
        drawn = Source(sourceEpoch, pair.frameId, pair.ptsUs); drawnSlot = pair.slotToken
        return true
    }
    fun complete() = target != null && target == drawn
    fun completedSlot() = if (complete()) drawnSlot else 0L
}
