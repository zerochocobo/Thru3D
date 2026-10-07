package org.vrpassthroughplayer.plugin

import android.content.res.AssetManager
import java.nio.ByteBuffer

/** Realtime 2D->3D depth (Depth Anything V2 Small, MNN OpenCL) in libquest_rvm. Not thread-safe per handle. */
internal object DepthNative {
    // Loads libquest_rvm on first use of this object.
    val unavailable: String? = RvmNative.unavailable
    /** Compiled-program cache this model uses under [cacheDirectory]. */
    @JvmStatic external fun cachePath(assets: AssetManager, cacheDirectory: String?): String
    /** Builds the OpenCL session (a cold cache compiles for tens of seconds). */
    @JvmStatic external fun create(assets: AssetManager, cacheDirectory: String?): Long
    /** {"width","height","prepare_ms","gpu_ops","cpu_fallback_ops"} */
    @JvmStatic external fun describe(handle: Long): String
    /** rgb float32 CHW [0,1] -> near float32 HxW [0,1] (1 = nearest). reset restarts the shot's depth band. */
    @JvmStatic external fun process(handle: Long, rgb: ByteBuffer, near: ByteBuffer, reset: Boolean, frameStep: Int): String
    @JvmStatic external fun close(handle: Long)

    /** Model input: 16:9 multiples of the 14 px patch, fixed in the converted graph (tools/models/prepare_depth_mnn.py). */
    const val PROFILE = "252x140"
}
