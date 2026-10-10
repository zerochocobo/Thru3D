package org.vrpassthroughplayer.plugin

import android.content.Context
import java.util.concurrent.atomic.AtomicLong

/** Foreground and preloads share the DepthWorker's single photo session. */
internal object PhotoDepthRuntime {
    const val IDLE_MS = 60_000L
    private val session by lazy { PhotoDepthSession(DepthNative::close) }
    private val idle = Runnable { session.close() }
    private val activity = AtomicLong()

    fun <T> run(context: Context, checkCurrent: () -> Unit, process: (Long, Boolean) -> T): T {
        val worker = DepthWorker.handler
        activity.incrementAndGet()
        worker.removeCallbacks(idle)
        try {
            return session.use({ ModelPreparationGate.run {
                checkCurrent()
                DepthNative.createPhoto(context.assets, PhotoDepthInput.cacheDirectory(context).path)
            } }, process)
        } finally { worker.postDelayed(idle, IDLE_MS) }
    }

    fun release() {
        val worker = DepthWorker.handler
        val version = activity.incrementAndGet()
        worker.removeCallbacks(idle)
        // All earlier selections are cancelled before this is posted. Never close during inference.
        worker.post { if (activity.get() == version) session.close() }
    }
}
