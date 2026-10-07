package org.vrpassthroughplayer.plugin

/** Logical ownership only: no EGL calls. All methods run under the session lock.
 * Up to [depth] ready pairs, claimed oldest first; up to two claims while Godot replaces a
 * material binding. depth 1 keeps only the latest. A deeper queue keeps pairs that become
 * ready in a burst (GL uploads finishing together when RVM holds the GPU) instead of
 * replacing all but the newest unseen: the display runs at 72 Hz, the source at 30.
 * Closing rejects offers/claims/acks but still accepts detach of existing claims.
 */
internal class PairDisplayGate(private val scope: MediaSessionGate.Scope, private val depth: Int = 1) {
    private var alive = true
    private val ready = ArrayDeque<FramePairGate.Identity>()
    private val claims = LinkedHashMap<Long, FramePairGate.Identity>()
    private val acknowledged = HashSet<Long>()
    private val pins = HashSet<Long>()
    private var frame = -1L
    private var pts = -1L
    var claimCount = 0L; private set
    var ackCount = 0L; private set
    var detachCount = 0L; private set
    var replacedCount = 0L; private set

    private fun accepts(id: FramePairGate.Identity) = alive && id.decoderId == scope.decoderId &&
        id.logicalSessionId == scope.logicalSessionId && id.generation == scope.generation &&
        id.slotToken > 0 && id.frameId >= frame && id.ptsUs >= pts && id.formatRevision > 0 &&
        id.effectRevision > 0 && id.modelGeneration > 0

    /** Retire the returned token. A rejected input returns its own token. */
    fun offer(id: FramePairGate.Identity): Long? {
        if (!accepts(id) || claims.containsKey(id.slotToken) || ready.any { it.slotToken == id.slotToken }) return id.slotToken
        val obsolete = if (ready.size >= depth) ready.removeFirst().slotToken else null
        if (obsolete != null) replacedCount++
        ready.addLast(id)
        return obsolete
    }
    /** Only the oldest ready pair can be claimed. */
    fun claim(token: Long): FramePairGate.Identity? {
        val id = ready.firstOrNull() ?: return null
        if (id.slotToken != token || !accepts(id) || claims.size >= 2) return null
        ready.removeFirst(); claims[token] = id; claimCount++
        return id
    }
    fun acknowledge(token: Long): Boolean {
        val id = claims[token] ?: return false
        if (!accepts(id) || token in acknowledged) return false
        frame = id.frameId; pts = id.ptsUs; acknowledged.add(token); ackCount++
        return true
    }
    fun detach(token: Long): Boolean {
        if (claims.remove(token) == null) return false
        acknowledged.remove(token); detachCount++
        return true
    }
    /** A readback observer keeps the same immutable pair across display detach. */
    fun pin(token: Long): Boolean = alive && token in acknowledged && pins.add(token)
    fun unpin(token: Long): Boolean = pins.remove(token)
    fun owns(token: Long) = ready.any { it.slotToken == token } || claims.containsKey(token) || token in pins
    fun drawn(token: Long) = alive && token in acknowledged
    /** The pair to offer Godot next (oldest ready). */
    fun readyToken() = ready.firstOrNull()?.slotToken
    fun heldClaims() = (claims.keys + pins).toSet().size
    /** Returns the newest ready token; every ready pair stops being owned. */
    fun close(): Long? {
        alive = false
        val obsolete = ready.lastOrNull()?.slotToken; ready.clear()
        return obsolete
    }
}
