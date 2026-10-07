package org.vrpassthroughplayer.plugin

import android.content.res.AssetManager
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicLong

/** Blocking scaled-RGB bridge for the future R02 worker. Never call from XR/GL/UI threads.
 * Caller owns buffers until process returns and must reject results after reset/close.
 * No decoder, immutable color frame, or verified source PTS is provided by this class.
 */
internal class RvmRuntime private constructor(
    private val assets: AssetManager, // Retain manager for the native backend's entire lifetime.
    val profile: String,
    val sessionId: Long,
    generation: Long,
    handle: Long,
) : AutoCloseable {
    private val handle = AtomicLong(handle)
    private val epoch = AtomicLong(generation)
    private val dimensions = profile.split('x').map { it.toInt() }
    private val alphaBytes = dimensions[0] * dimensions[1] * 4

    fun reset(nextGeneration: Long): Boolean {
        var previous = epoch.get()
        while (true) {
            require(nextGeneration > previous) { "Reset requires a newer generation" }
            if (epoch.compareAndSet(previous, nextGeneration)) break
            previous = epoch.get()
        }
        val id = handle.get()
        check(id > 0) { "RVM runtime closed" }
        return RvmNative.resetRuntime(id, nextGeneration) && handle.get() == id && epoch.get() == nextGeneration
    }

    fun process(generation: Long, frameId: Long, ptsUs: Long, left: ByteBuffer, right: ByteBuffer,
                leftAlpha: ByteBuffer, rightAlpha: ByteBuffer): JSONObject =
        process(generation, frameId, ptsUs, left, right, leftAlpha, rightAlpha, 0, false)

    fun process(generation: Long, frameId: Long, ptsUs: Long, left: ByteBuffer, right: ByteBuffer,
                leftAlpha: ByteBuffer, rightAlpha: ByteBuffer, stream: Int, resetFirst: Boolean): JSONObject {
        val id = handle.get()
        check(id > 0 && epoch.get() == generation) { "RVM runtime closed or stale" }
        checkBuffer(left, alphaBytes * 3, false)
        checkBuffer(right, alphaBytes * 3, false)
        checkBuffer(leftAlpha, alphaBytes, true)
        checkBuffer(rightAlpha, alphaBytes, true)
        val result = JSONObject(RvmNative.processRuntimeStream(id, generation, frameId, ptsUs, left, right,
            leftAlpha, rightAlpha, stream, resetFirst))
        return if (handle.get() == id && epoch.get() == generation) result else JSONObject().put("state", "stale")
    }

    fun processAhb(generation: Long, frameId: Long, ptsUs: Long, buffers: LongArray, alpha: LongArray,
                   stream: Int, resetFirst: Boolean): JSONObject {
        val id = handle.get()
        check(id > 0 && epoch.get() == generation) { "RVM runtime closed or stale" }
        require(buffers.size == 2 && alpha.size == 2 && (buffers + alpha).all { it != 0L }) { "Zero-copy buffers missing" }
        val result = JSONObject(RvmNative.processRuntimeAhb(id, generation, frameId, ptsUs, buffers[0], buffers[1],
            alpha[0], alpha[1], stream, resetFirst))
        return if (handle.get() == id && epoch.get() == generation) result else JSONObject().put("state", "stale")
    }

    private fun checkBuffer(buffer: ByteBuffer, bytes: Int, writable: Boolean) {
        require(buffer.isDirect && buffer.order() == ByteOrder.LITTLE_ENDIAN && buffer.capacity() == bytes &&
            buffer.position() == 0 && buffer.limit() == bytes && (!writable || !buffer.isReadOnly)) {
            "Expected exact-size little-endian direct ByteBuffer; position=0, full limit, writable Alpha"
        }
    }

    override fun close() {
        val id = handle.getAndSet(0)
        if (id > 0) RvmNative.closeRuntime(id)
    }

    companion object {
        fun capabilities(): JSONObject {
            check(RvmNative.unavailable == null) { "RVM native library unavailable" }
            return JSONObject(RvmNative.runtimeCapabilities())
        }
        fun prepare(assets: AssetManager, vulkan: Boolean, profile: String, sessionId: Long, generation: Long): RvmRuntime {
            require(profile in RvmProfiles.keys && sessionId > 0 && generation > 0)
            check(RvmNative.unavailable == null) { "RVM native library unavailable" }
            val id = RvmNative.prepareRuntime(assets, vulkan, profile, sessionId, generation)
            check(id > 0) { "RVM prepare failed" }
            return RvmRuntime(assets, profile, sessionId, generation, id)
        }
    }
}
