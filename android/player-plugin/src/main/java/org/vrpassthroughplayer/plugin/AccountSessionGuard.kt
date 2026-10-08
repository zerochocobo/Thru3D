package org.vrpassthroughplayer.plugin

/** Authentication network work may finish after cancellation. Persistence and cancellation
 * use the same monitor so an expired workflow can never resurrect an account. */
internal open class AccountSessionGuard {
    @Volatile var cancelled = false
        private set
    @Synchronized fun cancelSession(clear: () -> Unit) { cancelled = true; clear() }
    @Synchronized fun commitSession(commit: () -> Unit) { check(!cancelled); commit() }
}
