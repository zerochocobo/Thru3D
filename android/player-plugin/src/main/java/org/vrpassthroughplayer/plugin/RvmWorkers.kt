package org.vrpassthroughplayer.plugin

import android.os.Handler
import android.os.HandlerThread
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Process-owned OpenMP roots; sessions own and close every model separately.
 * NDK 29 libomp aborts in kmp_affinity.cpp:4755 when its final root exits and a
 * new thread initializes it. The minimal four-thread reproducer is in
 * benchmarks/openmp_reinit_android.cpp. Keep these idle workers across player
 * recreation; do not retain an Activity, model, video, callback or GL context.
 */
internal object RvmWorkers {
    val validation by lazy {
        ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(1),
            { task -> Thread(task, "QuestRvmValidation") }, ThreadPoolExecutor.AbortPolicy())
    }
    /** ROI decisions off the inference worker; never touches GL, MNN or bridge buffers. */
    val roi: Handler by lazy {
        val thread = HandlerThread("QuestRvmRoi").apply { start() }
        Handler(thread.looper)
    }
    val video: Handler by lazy {
        val thread = HandlerThread("QuestVideoRvm").apply { start() }
        Handler(thread.looper)
    }
    /** Warmup compiles: a cold profile compiles and tunes OpenCL kernels for 30-60 s. Kept off
     * [video], which also opens sources and resumes playback, so a compile never stalls the player.
     * Session prepares queue here behind a running compile, then build on [video]. */
    val prepare: Handler by lazy {
        val thread = HandlerThread("QuestRvmPrepare").apply { start() }
        Handler(thread.looper)
    }
}
