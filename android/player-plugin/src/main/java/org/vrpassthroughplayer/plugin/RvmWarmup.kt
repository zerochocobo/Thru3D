package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONObject
import java.io.File

/** First use of a profile compiles and tunes MNN OpenCL kernels (~40 s on Quest 3).
 * Do it in the background on the prepare worker before playback asks for it; a playback
 * prepare posted meanwhile queues behind it and then hits the fresh cache. */
internal object RvmWarmup {
    fun cacheDirectory(context: Context) = File(context.cacheDir, "rvm-mnn").apply { mkdirs() }

    val models = if (BuildConfig.INCLUDE_DIAGNOSTIC_MODELS) listOf("fast", "quality") else listOf("fast")

    /** Warms only the models included in this build; normal playback has one model.
     * Emits {"state": "cached"|"warming"|"ready"|"failed", "model", ...} through [report]. */
    fun schedule(context: Context, profile: String, selected: String, report: (JSONObject) -> Unit) {
        if (profile !in RvmProfiles.keys || selected !in models || RvmNative.unavailable != null) return
        val app = context.applicationContext
        RvmWorkers.prepare.post {
            try {
                RvmNative.configureGpu(cacheDirectory(app).absolutePath, true)
                // Caches are named after model bytes; keep only the models shipped in this build.
                val keep = models.map { File(RvmNative.gpuCachePath(app.assets, profile, it)) }.toSet()
                cacheDirectory(app).listFiles { file -> file.name.startsWith("mnn_rvm_${profile}_") && file !in keep }
                    ?.forEach { it.delete() }
            } catch (error: Throwable) {
                report(JSONObject().put("profile_key", profile).put("state", "failed").put("message", error.message))
                return@post
            }
            for (model in listOf(selected) + models.filter { it != selected }) warm(app, profile, model, report)
        }
    }

    /** Compiled programs of [model] for [profile] are cached: an Alpha session starts in ~1 s. */
    fun ready(context: Context, profile: String, model: String): Boolean =
        profile in RvmProfiles.keys && model in models && RvmNative.unavailable == null &&
            // A cache under the size of compiled programs only holds the header.
            File(RvmNative.gpuCachePath(context.assets, profile, model)).length() > 4096

    private fun warm(app: Context, profile: String, model: String, report: (JSONObject) -> Unit) {
        val base = JSONObject().put("profile_key", profile).put("model", model)
        try {
            if (ready(app, profile, model)) {
                report(base.put("state", "cached")); return
            }
            report(JSONObject(base.toString()).put("state", "warming"))
            report(JSONObject(RvmNative.warmupGpu(app.assets, profile, model)).put("model", model).put("state", "ready"))
        } catch (error: Throwable) {
            report(base.put("state", "failed").put("message", error.message))
        }
    }
}
