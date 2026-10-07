package org.vrpassthroughplayer.plugin

import android.content.Context
import android.net.Uri
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

internal object MpvNative {
    init { System.loadLibrary("quest_mpv") }
    @JvmStatic external fun probe(context: Context, path: String): String
    @JvmStatic external fun probeGpu(context: Context, path: String, hardware: Boolean, width: Int, height: Int, sourceFrame: Boolean): String
}

/** Optional MPV development candidate, entirely absent from Release. */
internal object MpvDiagnostics {
    private val busy = AtomicBoolean(false)
    private val sequence = AtomicInteger(0)
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(1),
        { task -> Thread(task, "QuestMpvCoreProbe") }, ThreadPoolExecutor.AbortPolicy())
    fun requestExternal(context: Context): Int {
        if (!busy.compareAndSet(false, true)) return -1
        val id = sequence.incrementAndGet()
        val uri = "content://org.vrpassthroughplayer.urifixture.documents/document/clip"
        try {
            worker.execute {
                var report = JSONObject()
                try {
                    context.contentResolver.openFileDescriptor(Uri.parse(uri), "r")?.use { descriptor ->
                        // Real source-frame MPV path, with the FD owned until native teardown.
                        report = JSONObject(MpvNative.probeGpu(context, "fd://${descriptor.fd}", true, 1280, 640, true))
                        report.put("descriptor_bytes", descriptor.statSize)
                    } ?: error("External document descriptor unavailable")
                } catch (error: Throwable) { report.put("state", "failed").put("detail", error.toString()) }
                finally {
                    report.put("request_id", id).put("diagnostic_process", DiagnosticRequests.processId)
                        .put("uri", uri).put("fixture", "mp03_frame_identity").put("probe_kind", "source").put("requested_hardware", true)
                        .put("client_uid", android.os.Process.myUid())
                        .put("scope", "Actual external granted document FD consumed by native source-frame MPV/EGL; Godot catalog/resume UI, RVM and XR not exercised")
                    try {
                        val directory = File(context.filesDir, "diagnostics").apply { check(mkdirs() || isDirectory) }
                        val tmp = File.createTempFile("mpv-uri-", ".tmp", directory)
                        try { tmp.writeText(report.toString()); check(tmp.renameTo(File(directory, "mpv_uri_$id.json"))) }
                        finally { tmp.delete() }
                    } finally { busy.set(false) }
                }
            }
        } catch (_: Exception) { busy.set(false); return -1 }
        return id
    }
    fun request(context: Context, fixture: String, gpu: Boolean = false, hardware: Boolean = false, sourceFrame: Boolean = false): Int {
        require(if (sourceFrame) gpu && fixture == "mp03_frame_identity"
            else fixture in listOf("c03_sbs_grid", "c04_alpha_f180", "c04_independent_alpha"))
        if (!busy.compareAndSet(false, true)) return -1
        val id = sequence.incrementAndGet()
        try {
            worker.execute {
                var report = JSONObject()
                try {
                    val fixtures = File(context.filesDir, "fixtures").apply { check(mkdirs() || isDirectory) }
                    val input = File(fixtures, "mpv_$fixture.mp4")
                    context.assets.open("media/$fixture.mp4").use { src -> input.outputStream().use { src.copyTo(it) } }
                    report = JSONObject(if (gpu) MpvNative.probeGpu(context, input.absolutePath, hardware,
                        if (fixture == "c03_sbs_grid") 1920 else 1280, if (fixture == "c03_sbs_grid") 1080 else 640, sourceFrame)
                        else MpvNative.probe(context, input.absolutePath))
                } catch (error: Throwable) { report.put("state", "failed").put("detail", error.javaClass.name+": "+error.message) }
                finally {
                    report.put("request_id", id).put("diagnostic_process", DiagnosticRequests.processId).put("fixture", fixture)
                        .put("probe_kind", if (sourceFrame) "source" else if (gpu) "gpu" else "core").put("requested_hardware", hardware)
                    try {
                        val directory = File(context.filesDir, "diagnostics").apply { check(mkdirs() || isDirectory) }
                        val tmp = File.createTempFile("mpv-core-", ".tmp", directory)
                        val kind = if (sourceFrame) "source" else if (gpu) "gpu" else "core"
                        try { tmp.writeText(report.toString()); check(tmp.renameTo(File(directory, "mpv_"+kind+"_$id.json"))) }
                        finally { tmp.delete() }
                    } finally { busy.set(false) }
                }
            }
        } catch (error: Exception) { busy.set(false); return -1 }
        return id
    }
}
