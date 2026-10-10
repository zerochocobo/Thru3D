package org.vrpassthroughplayer.plugin

import java.io.File

/** One owner plus any in-flight worker leases; cancellation cannot unlink a worker's input. */
internal class PhotoSource(val file: File) {
    private var references = 1
    @Synchronized fun retain(): PhotoSource {
        check(references > 0)
        references++
        return this
    }
    @Synchronized fun release() {
        check(references > 0)
        if (--references == 0) file.parentFile?.deleteRecursively()
    }
}
