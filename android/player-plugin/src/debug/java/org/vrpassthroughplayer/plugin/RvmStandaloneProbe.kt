package org.vrpassthroughplayer.plugin

import android.content.Context
import android.content.res.AssetManager
import android.os.SystemClock
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** DUMP-protected standalone calls into the same model/JNI/backend used by the player. */
internal object RvmStandaloneProbe {
    private val ids = AtomicInteger()
    private val busy = AtomicBoolean(false)
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(1),
        { task -> Thread(task, "QuestResidentDiagnostic") }, ThreadPoolExecutor.AbortPolicy())

    fun request(context: Context, mode: String, profile: String): Int {
        require(mode in setOf("cpu", "vulkan", "resident", "resident_fp16_storage") && profile in RvmProfiles.keys)
        check(DiagnosticRequests.current() == null) { "Close the running player before standalone validation" }
        if (!busy.compareAndSet(false, true)) return -1
        val id = ids.incrementAndGet()
        val started = SystemClock.elapsedRealtime()
        fun save(result: JSONObject) {
            result.put("probe_id", id).put("mode", mode).put("requested_profile", profile)
                .put("diagnostic_process", DiagnosticRequests.processId).put("elapsed_ms", SystemClock.elapsedRealtime()-started)
                .put("activity_launched", false).put("standalone", true)
            val directory = File(context.filesDir, "diagnostics").apply { check(isDirectory || mkdirs()) }
            val temp = File.createTempFile("resident-", ".tmp", directory)
            try {
                temp.writeText(result.toString(), Charsets.UTF_8)
                check(temp.renameTo(File(directory, "rvm_standalone_$id.json")))
            } finally { temp.delete() }
        }
        try {
            worker.execute {
                var callbackOwnsClose = false
                try {
                    if (mode in setOf("resident", "resident_fp16_storage")) {
                        check(RvmNative.unavailable == null) { "Native RVM unavailable" }
                        val directory = File(context.filesDir, "rvm-resident-fixtures/$profile").canonicalFile
                        check(directory.isDirectory && directory.path.startsWith(context.filesDir.canonicalPath+"/"))
                        val payload = if (mode == "resident_fp16_storage") {
                            RvmResidentValidationNative.runHalfStorage(context.assets, profile, directory.path)
                        } else RvmResidentValidationNative.run(context.assets, profile, directory.path)
                        save(JSONObject(payload))
                    } else {
                        lateinit var runner: RvmBenchmarkRunner
                        runner = RvmBenchmarkRunner({ context.applicationContext }) { _, payload ->
                            try { save(JSONObject(payload)) }
                            finally { runner.close(); busy.set(false) }
                        }
                        val accepted = runner.request(mode == "vulkan", profile)
                        if (accepted <= 0) {
                            runner.close()
                            error("RVM benchmark rejected")
                        }
                        callbackOwnsClose = true
                        return@execute // callback owns close and busy release
                    }
                } catch (failure: Throwable) {
                    runCatching { save(JSONObject().put("state", "error").put("code", "STANDALONE_RVM_FAILED")
                        .put("exception", failure.javaClass.simpleName).put("message", failure.message)) }
                } finally {
                    if (!callbackOwnsClose) busy.set(false)
                }
            }
        } catch (failure: Exception) { busy.set(false); throw failure }
        return id
    }
}

internal object RvmResidentValidationNative {
    @JvmStatic external fun run(assets: AssetManager, profile: String, directory: String): String
    @JvmStatic external fun runHalfStorage(assets: AssetManager, profile: String, directory: String): String
}
