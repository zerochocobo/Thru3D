package org.vrpassthroughplayer.plugin

/** Worker-confined: one model/session, with no temporal state between still photos. */
internal class PhotoDepthSession(private val destroy: (Long) -> Unit) {
    private var handle = 0L

    fun <T> use(create: () -> Long, process: (Long, Boolean) -> T): T {
        val reused = handle != 0L
        if (!reused) handle = create().also { require(it != 0L) }
        try { return process(handle, reused) }
        catch (error: Throwable) {
            // Cancelling a selection does not damage the GPU session.
            if (error !is InterruptedException) close()
            throw error
        }
    }

    fun close() {
        val previous = handle
        handle = 0L
        if (previous != 0L) destroy(previous)
    }
}
