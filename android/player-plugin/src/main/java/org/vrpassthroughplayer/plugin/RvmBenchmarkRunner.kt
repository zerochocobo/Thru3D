package org.vrpassthroughplayer.plugin

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

internal class RvmBenchmarkRunner(
    private val context: () -> Context?,
    private val event: (Int, String) -> Unit,
) {
    private val worker = RvmWorkers.validation
    private val busy = AtomicBoolean(false)
    private val lock = Any()
    @Volatile private var closed = false
    private var sequence = 0
    private var nativeInitialized = false
    private val activeRuntime = AtomicReference<RvmRuntime?>(null)

    fun request(vulkan: Boolean, profile: String = "256x144"): Int = synchronized(lock) {
        if (profile !in RvmProfiles.keys) return@synchronized -1
        if (closed || !busy.compareAndSet(false, true)) return@synchronized -1
        val id = ++sequence
        val unavailable = RvmNative.unavailable
        nativeInitialized = true
        val nativeReady = if (unavailable == null) try { RvmNative.setGeneration(id); true }
            catch (_: LinkageError) { false } else false
        try {
            worker.execute {
                try {
                    if (closed) return@execute
                    val host = context() ?: throw IllegalStateException("Activity unavailable")
                    val result = if (nativeReady) {
                        JSONObject(RvmNative.runBenchmark(host.assets, vulkan, id, profile))
                    } else JSONObject().put("state", "error").put("code", "RVM_NATIVE_LIBRARY_UNAVAILABLE")
                    result.put("request_id", id).put("requested_vulkan", vulkan).put("requested_profile", profile)
                        .put("diagnostic_process", DiagnosticRequests.processId)
                    if (!closed && result.optString("state") == "passed") {
                        try {
                            result.put("runtime_bridge", RvmRuntimeVerification.run(host.assets, vulkan, profile, { closed }) { runtime ->
                                activeRuntime.set(runtime)
                                if (closed) activeRuntime.getAndSet(null)?.close()
                            })
                        }
                        catch (error: Exception) {
                            Log.e("VRPassthroughPlayer", "RVM runtime bridge verification failed", error)
                            result.put("state", "failed").put("runtime_bridge", JSONObject().put("state", "failed")
                                .put("error", error.javaClass.simpleName))
                        }
                    }
                    try {
                        val directory = File(host.filesDir, "diagnostics")
                        if (!directory.isDirectory && !directory.mkdirs()) throw IllegalStateException("Diagnostics directory unavailable")
                        for (filename in listOf("rvm_benchmark_${if (vulkan) "vulkan" else "cpu"}.json",
                            "rvm_benchmark_${if (vulkan) "vulkan" else "cpu"}_$profile.json")) {
                            val target = File(directory, filename)
                            val temporary = File.createTempFile("rvm-", ".tmp", directory)
                            try {
                                temporary.writeText(result.toString(), Charsets.UTF_8)
                                if (!temporary.renameTo(target)) throw IllegalStateException("Diagnostics rename failed")
                            } finally { if (temporary.exists()) temporary.delete() }
                        }
                    } catch (error: Exception) { result.put("storage_error", error.javaClass.simpleName) }
                    if (!closed) event(id, result.toString())
                } catch (error: Exception) {
                    Log.e("VRPassthroughPlayer", "RVM validation request failed", error)
                    if (!closed) event(id, JSONObject().put("request_id", id).put("state", "error")
                        .put("code", "RVM_VALIDATION_FAILED").toString())
                } catch (error: LinkageError) {
                    Log.e("VRPassthroughPlayer", "RVM JNI unavailable", error)
                    if (!closed) event(id, JSONObject().put("request_id", id).put("state", "error")
                        .put("code", "RVM_NATIVE_LIBRARY_UNAVAILABLE").toString())
                } finally { busy.set(false) }
            }
        } catch (_: RejectedExecutionException) { busy.set(false); return@synchronized -1 }
        id
    }

    fun close() = synchronized(lock) {
        if (!closed) {
            closed = true
            activeRuntime.getAndSet(null)?.close()
            if (nativeInitialized && RvmNative.unavailable == null) try { RvmNative.setGeneration(0) }
                catch (error: LinkageError) { Log.e("VRPassthroughPlayer", "RVM close JNI unavailable", error) }
            // Queued work checks closed; native generation/runtime are invalidated
            // above. The process-owned OpenMP root must survive this runner.
        }
    }
}
