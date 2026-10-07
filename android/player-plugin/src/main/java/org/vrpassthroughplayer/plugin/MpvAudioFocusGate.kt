package org.vrpassthroughplayer.plugin

/** A focus callback belongs to one request; abandoned requests cannot resume a
 * paused, replaced or closed player. Android effects live in MpvAudioFocus. */
internal class MpvAudioFocusGate {
    enum class State { NONE, REQUESTING, HELD, TRANSIENT, LOST, DENIED }
    enum class Change { GAIN, TRANSIENT_LOSS, LOSS }
    var state = State.NONE
        private set
    private var generation = 0L
    val canPlay get() = state == State.HELD

    fun begin(explicit: Boolean = false): Long? {
        if (state in setOf(State.REQUESTING, State.HELD, State.TRANSIENT) ||
            (state == State.LOST && !explicit)) return null
        state = State.REQUESTING
        return ++generation
    }
    fun resolved(token: Long, granted: Boolean) {
        if (token == generation && state == State.REQUESTING)
            state = if (granted) State.HELD else State.DENIED
    }
    fun changed(token: Long, change: Change): Boolean {
        if (token != generation || state !in setOf(State.HELD, State.TRANSIENT)) return false
        state = when (change) {
            Change.GAIN -> State.HELD
            Change.TRANSIENT_LOSS -> State.TRANSIENT
            Change.LOSS -> State.LOST
        }
        return true
    }
    fun clear() { ++generation; state = State.NONE }
}
