package org.vrpassthroughplayer.plugin

/** The system shell launches an exported component, but only our own UI can arm it. */
internal class PanelLaunchGate(private val now: () -> Long) {
    private val pending = HashMap<String, Pair<String, Long>>()
    private val active = HashMap<String, String>()
    @Synchronized fun arm(name: String, token: String) { pending[name] = token to now() }
    @Synchronized fun enter(name: String, restored: String?): String? {
        if (restored != null) return restored.takeIf { active[name] == it }
        val permit = pending.remove(name) ?: return null
        if (now() - permit.second !in 0..15_000) return null
        active[name] = permit.first
        return permit.first
    }
    @Synchronized fun cancel(name: String) { pending.remove(name) }
    @Synchronized fun cancelPending(name: String, token: String): Boolean {
        if (pending[name]?.first != token) return false
        pending.remove(name)
        return true
    }
    @Synchronized fun leave(name: String, token: String) {
        if (active[name] == token) active.remove(name)
    }
}
