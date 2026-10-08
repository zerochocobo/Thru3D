package org.vrpassthroughplayer.plugin

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Cold OpenCL compilation/audit must not overlap between the independent prepare workers. */
internal object ModelPreparationGate {
    private val lock = ReentrantLock(true)
    fun <T> run(block: () -> T): T = lock.withLock { block() }
}
