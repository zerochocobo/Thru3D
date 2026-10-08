package org.vrpassthroughplayer.plugin

import java.util.concurrent.Executors
import java.util.concurrent.Future

/** One active browse, including its HTTP connection. Obsolete work never emits a result. */
internal class CloudBrowseRequests {
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "QuestCloudBrowse") }
    private var active: Pair<Int, CloudCancellation>? = null
    private var future: Future<*>? = null
    @Synchronized fun submit(id: Int, work: (CloudCancellation) -> String, emit: (Int, String) -> Unit) {
        cancel()
        val cancellation = CloudCancellation()
        active = id to cancellation
        future = executor.submit {
            val result = work(cancellation)
            synchronized(this) {
                if (active?.second === cancellation && !cancellation.cancelled) {
                    active = null
                    emit(id, result)
                }
            }
        }
    }
    @Synchronized fun cancel(id: Int? = null) {
        if (id != null && active?.first != id) return
        future?.cancel(true)
        active?.second?.cancel()
        active = null
        future = null
    }
    @Synchronized fun close() { cancel(); executor.shutdownNow() }
}
