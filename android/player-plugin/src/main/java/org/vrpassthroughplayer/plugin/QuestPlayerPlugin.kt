package org.vrpassthroughplayer.plugin

import android.opengl.GLES30
import android.opengl.EGL14
import android.content.Intent
import android.os.BatteryManager
import android.text.format.DateFormat
import androidx.media3.common.util.UnstableApi
import android.util.Log
import org.godotengine.godot.Godot
import org.godotengine.godot.GodotHost
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

@UnstableApi
class QuestPlayerPlugin(godot: Godot) : GodotPlugin(godot) {
    private val closed = AtomicBoolean(false)
    @Volatile private var signalsReady = false
    private val requestId = AtomicInteger(0)
    private val probe = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(1), { task -> Thread(task, "QuestCapabilityProbe") },
        ThreadPoolExecutor.DiscardOldestPolicy())
    @Volatile private var graphicsSnapshot = "{\"observed\":false}"
    private val media = LocalVideoBridge({ activity?.applicationContext }, { runOnRenderThread(it) }) { name, id, json ->
        if (!closed.get()) emitSignal(name, id, json)
    }
    private val picker = LocalVideoPicker({ activity }) { json ->
        if (!closed.get()) emitSignal("local_video_selected", json)
    }
    private val localAccess = LocalVideoAccess({ activity?.applicationContext }) { id, json ->
        if (!closed.get()) emitSignal("local_video_access", id, json)
    }
    private val rvm = RvmBenchmarkRunner({ activity?.applicationContext }) { id, json ->
        if (!closed.get()) emitSignal("rvm_benchmark_result", id, json)
    }
    // queueEvent runs on the GL thread, but Godot can have released its EGL context
    // there. Native GL work must wait for an actual draw callback with a current context.
    private val controlledRenderTasks = ArrayBlockingQueue<Runnable>(16)
    private val controlled = ControlledVideoBridge({ activity?.applicationContext }, {
        check(controlledRenderTasks.offer(it)) { "Controlled render task capacity exhausted" }
    }) { name, id, json ->
        if (!closed.get()) emitSignal(name, id, json)
    }
    private val sources = MediaSources({ activity }) { id, json -> if (!closed.get()) emitSignal("media_list", id, json) }
    private val accounts = AccountManager { activity }
    private val mpv = MpvVideoBridge({ activity?.applicationContext }, {
        check(controlledRenderTasks.offer(it)) { "Player render task capacity exhausted" }
    }, { name, id, json -> if (!closed.get()) emitSignal(name, id, json) }, sources::playable, sources::sidecarAudio,
        sources::releaseMediaStream, sources::sidecarSubtitles)
    private val photos = PhotoBridge({ activity?.applicationContext }, sources::playable, sources::releasePhotoStream) { name, id, json ->
        if (!closed.get()) emitSignal(name, id, json)
    }
    private val photoPreloads = PhotoBridge({ activity?.applicationContext }, sources::playable, sources::releasePhotoStream,
        "photo-preloads", true) { name, id, json ->
        if (!closed.get()) emitSignal(if (name == "photo_depth") "photo_preload_depth" else name, id, json)
    }
    @UsedByGodot fun open_photo(uri: String): Int {
        if (closed.get()) return -1
        val id = requestId.incrementAndGet()
        return if (photos.open(id, uri)) id else -1
    }
    @UsedByGodot fun preload_photo(uri: String): Int {
        if (closed.get()) return -1
        val id = requestId.incrementAndGet()
        return if (photoPreloads.open(id, uri)) id else -1
    }
    @UsedByGodot fun activate_photo(id: Int): Boolean = synchronized(PhotoCache.lock) {
        if (closed.get()) return@synchronized false
        if (photos.activate(id)) return@synchronized true
        val file = photoPreloads.take(id) ?: return@synchronized false
        if (photos.adopt(id, file)) return@synchronized true
        file.parentFile?.deleteRecursively()
        false
    }
    @UsedByGodot fun cancel_photo(id: Int) { photos.cancel(id); photoPreloads.cancel(id) }
    @UsedByGodot fun release_photo(id: Int) { photos.release(id); photoPreloads.release(id) }
    @UsedByGodot fun prepare_photo_depth(id: Int): Boolean = !closed.get() && photos.depth(id)
    @UsedByGodot fun prepare_preloaded_photo_depth(id: Int): Boolean = !closed.get() && photoPreloads.depth(id)
    @UsedByGodot fun prepare_photo_3d(id: Int, strength: Double): Boolean = !closed.get() && photos.depth(id,strength.toFloat(),true)
    @UsedByGodot fun prepare_preloaded_photo_3d(id: Int, strength: Double): Boolean = !closed.get() && photoPreloads.depth(id,strength.toFloat(),true)
    @UsedByGodot fun cancel_preloaded_photo_depth() { photoPreloads.cancelDepth() }
    @UsedByGodot fun photo_cache_usage(): String {
        val app = activity?.applicationContext ?: return "{}"
        return runCatching {
            val (files, bytes) = PhotoCache.usage(app.cacheDir)
            JSONObject().put("files", files).put("bytes", bytes).toString()
        }.getOrDefault("{}")
    }
    @UsedByGodot fun clear_photo_cache(): Boolean {
        if (closed.get()) return false
        val app = activity?.applicationContext ?: return false
        return runCatching {
            synchronized(PhotoCache.lock) {
                PhotoCache.clear(app.cacheDir, photos.cacheDirectories() + photoPreloads.cacheDirectories())
            }
            true
        }.getOrElse { Log.w("QuestPhotoCache", "Photo cache cleanup failed", it); false }
    }
    init { DiagnosticRequests.attach(this) }

    override fun getPluginName() = "QuestPlayer"

    /** Use the engine host's process restart/termination path so XR is created afresh. */
    @UsedByGodot fun finish_app(restart: Boolean) {
        if (!closed.get()) runOnHostThread {
            val host = activity as? GodotHost ?: return@runOnHostThread
            if (restart) host.onGodotRestartRequested(godot) else host.onGodotForceQuit(godot)
        }
    }

    @UsedByGodot fun set_ui_language(choice: String) {
        activity?.applicationContext?.let { UiLanguage.setChoice(it, choice) }
    }

    override fun getPluginSignals() = setOf(
        SignalInfo("capabilities_ready", Int::class.javaObjectType, String::class.java),
        SignalInfo("android_lifecycle", String::class.java),
        SignalInfo("rvm_warmup", String::class.java),
        SignalInfo("photo_ready", Int::class.javaObjectType, String::class.java),
        SignalInfo("photo_depth", Int::class.javaObjectType, String::class.java),
        SignalInfo("photo_preload_depth", Int::class.javaObjectType, String::class.java),
        SignalInfo("media_list", Int::class.javaObjectType, String::class.java),
        SignalInfo("local_video_selected", String::class.java),
        SignalInfo("local_video_access", Int::class.javaObjectType, String::class.java),
        SignalInfo("media_state", Int::class.javaObjectType, String::class.java),
        SignalInfo("media_format", Int::class.javaObjectType, String::class.java),
        SignalInfo("media_frame", Int::class.javaObjectType, String::class.java),
        SignalInfo("media_codec", Int::class.javaObjectType, String::class.java),
        SignalInfo("media_error", Int::class.javaObjectType, String::class.java),
        SignalInfo("media_released", Int::class.javaObjectType, String::class.java),
        SignalInfo("rvm_benchmark_result", Int::class.javaObjectType, String::class.java),
        SignalInfo("controlled_state", Int::class.javaObjectType, String::class.java),
        SignalInfo("controlled_frame", Int::class.javaObjectType, String::class.java),
        SignalInfo("controlled_rvm_pair", Int::class.javaObjectType, String::class.java),
        SignalInfo("controlled_error", Int::class.javaObjectType, String::class.java),
        SignalInfo("controlled_released", Int::class.javaObjectType, String::class.java),
        SignalInfo("mpv_state", Int::class.javaObjectType, String::class.java),
        SignalInfo("mpv_pair_available", Int::class.javaObjectType, String::class.java),
        SignalInfo("mpv_error", Int::class.javaObjectType, String::class.java),
        SignalInfo("mpv_detach", Int::class.javaObjectType, String::class.java),
        SignalInfo("mpv_released", Int::class.javaObjectType, String::class.java),
        SignalInfo("mpv_debug_command", Int::class.javaObjectType, String::class.java),
        SignalInfo("mpv_pixel_mask", Int::class.javaObjectType, String::class.java),
        SignalInfo("mpv_frozen_pair", Int::class.javaObjectType, String::class.java),
    )

    @UsedByGodot fun pick_local_video(): Int {
        if (closed.get()) return -1
        val id = requestId.incrementAndGet()
        runOnHostThread { if (!closed.get()) picker.open(id) }
        return id
    }
    @UsedByGodot fun cancel_local_video_pick(id: Int) { if (!closed.get()) runOnHostThread { picker.cancel(id) } }
    @UsedByGodot fun request_local_video_access(uri: String): Int {
        if (closed.get()) return -1
        val id = requestId.incrementAndGet()
        return if (localAccess.request(id, uri)) id else -1
    }
    @UsedByGodot fun cancel_local_video_access(id: Int) { localAccess.cancel(id) }
    @UsedByGodot fun open_local_video(textureId: Int, uri: String, startMs: Int): Int =
        if (closed.get()) -1 else media.open(textureId, uri, startMs)
    @UsedByGodot fun set_video_playing(id: Int, playing: Boolean) { if (!closed.get()) media.setPlaying(id, playing) }
    @UsedByGodot fun restart_video_at(id: Int, textureId: Int, positionMs: Int): Int =
        if (closed.get()) -1 else media.restart(id, textureId, positionMs)
    @UsedByGodot fun request_video_status(id: Int) { if (!closed.get()) media.requestStatus(id) }
    @UsedByGodot fun close_video(id: Int) { media.close(id) }
    @UsedByGodot fun request_rvm_benchmark(vulkan: Boolean): Int = if (closed.get() || !BuildConfig.INCLUDE_DIAGNOSTIC_MODELS) -1 else rvm.request(vulkan)
    @UsedByGodot fun request_rvm_profile_benchmark(vulkan: Boolean, profile: String): Int =
        if (closed.get() || !BuildConfig.INCLUDE_DIAGNOSTIC_MODELS) -1 else rvm.request(vulkan, profile)
    @UsedByGodot fun open_controlled_video(uri: String, startMs: Int, stereo: Boolean, profile: String): Int =
        if (closed.get()) -1 else controlled.open(uri, startMs, stereo, profile, false)
    @UsedByGodot fun request_controlled_probe(uri: String, startMs: Int, stereo: Boolean, profile: String): Int =
        if (closed.get()) -1 else controlled.open(uri, startMs, stereo, profile, true)
    internal fun requestRvmVideoProbe(uri: String, stereo: Boolean, profile: String, vulkan: Boolean): Int =
        if (closed.get()) -1 else controlled.open(uri, 0, stereo, profile, true, true, vulkan)
    internal fun cancelControlledProbe(id: Int): Int = if (controlled.cancelProbe(id)) id else -1
    @UsedByGodot fun release_controlled_frame(id: Int, token: Long): Boolean =
        !closed.get() && controlled.release(id, token)
    @UsedByGodot fun close_controlled_video(id: Int) { controlled.close(id) }
    @UsedByGodot fun set_controlled_playing(id: Int, playing: Boolean) { if (!closed.get()) controlled.setPlaying(id, playing) }
    @UsedByGodot fun request_controlled_status(id: Int) { if (!closed.get()) controlled.requestStatus(id) }
    /** Headset battery and clock style for the menus' status pill: {"level": 0..100 or -1, "charging", "clock24"}. */
    @UsedByGodot fun device_status(): String {
        val host = activity ?: return "{}"
        val battery = host.getSystemService(BatteryManager::class.java)
        val level = battery?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
        return JSONObject().put("level", if (level in 0..100) level else -1)
            .put("charging", battery?.isCharging ?: false)
            .put("clock24", DateFormat.is24HourFormat(host)).toString()
    }
    @UsedByGodot fun mpv_supported(): Boolean = !closed.get() && mpv.supported()
    @UsedByGodot fun set_mpv_output_width(width: Int) { if (width in 0..8192) mpv.outputWidthCap = width }
    // Library sources: each returns a request id; the result arrives as media_list(id, json).
    /** Headset storage: path "" lists the volumes, otherwise one folder's subfolders and videos. */
    @UsedByGodot fun media_local_browse(path: String): Int {
        if (closed.get()) return -1
        val id = sources.nextId()
        runOnHostThread { if (!closed.get()) sources.browseLocal(id, path) }
        return id
    }
    @UsedByGodot fun media_list_local(): Int = media_local_browse("")
    @UsedByGodot fun media_cloud_browse(path: String, refresh: Boolean): Int = if (closed.get()) -1 else sources.cloudBrowse(path, refresh)
    @UsedByGodot fun media_cloud_page(path: String, offset: Int, refresh: Boolean): Int = if (closed.get()) -1 else sources.cloudBrowse(path, refresh, offset)
    @UsedByGodot fun media_cloud_cancel(id: Int) { if (!closed.get()) sources.cloudCancel(id) }
    @UsedByGodot fun account_open(kind: String, provider: String, id: String, json: String): Int = if (closed.get()) -1 else accounts.open(kind, provider, id, json)
    @UsedByGodot fun account_list(kind: String): String = if (closed.get()) "null" else accounts.accounts(kind)
    @UsedByGodot fun account_snapshot(id: Int): String = if (closed.get()) "{}" else accounts.snapshot(id)
    @UsedByGodot fun account_input(id: Int, field: String, action: String, text: String) { if (!closed.get()) accounts.input(id, field, action, text) }
    @UsedByGodot fun account_action(id: Int, action: String, json: String) { if (!closed.get()) accounts.action(id, action, json) }
    @UsedByGodot fun account_cancel(id: Int) { accounts.cancel(id) }
    @UsedByGodot fun license_text(id: String): String = activity?.applicationContext?.let { LicenseCatalog.text(it, id) } ?: ""
    @UsedByGodot fun account_web_frame(id: Int): ByteArray = if (closed.get()) ByteArray(0) else accounts.webFrame(id)
    @UsedByGodot fun account_web_action(id: Int, action: String, x: Float, y: Float, text: String) { if (!closed.get()) accounts.webAction(id, action, x, y, text) }
    @UsedByGodot fun media_cloud_remove(id: String): Int = if (closed.get()) -1 else sources.cloudRemove(id)
    @UsedByGodot fun media_server_request(json: String): Int = if (closed.get()) -1 else sources.serverRequest(json)
    @UsedByGodot fun media_server_cancel(id: Int) { sources.serverCancel(id) }
    /** Opens the system "All files access" page (folders beyond media ones, files beside videos). */
    @UsedByGodot fun media_local_grant_all_files() { if (!closed.get()) runOnHostThread { sources.grantAllFiles() } }
    @UsedByGodot fun media_dlna_discover(): Int = if (closed.get()) -1 else sources.dlnaDiscover()
    @UsedByGodot fun media_dlna_browse(server: String, objectId: String): Int = if (closed.get()) -1 else sources.dlnaBrowse(server, objectId)
    @UsedByGodot fun media_smb_servers(): Int = if (closed.get()) -1 else sources.smbServers()
    @UsedByGodot fun media_smb_discover(): Int = if (closed.get()) -1 else sources.smbDiscover()
    /** {id?, name, host, domain, user, password}; an empty password keeps the saved one. */
    @UsedByGodot fun media_smb_save(json: String): Int = if (closed.get()) -1 else sources.smbSave(json)
    @UsedByGodot fun media_smb_remove(id: String): Int = if (closed.get()) -1 else sources.smbRemove(id)
    @UsedByGodot fun media_smb_browse(server: String, path: String): Int = if (closed.get()) -1 else sources.smbBrowse(server, path)
    /** Background OpenCL compile/tune for an Alpha profile; progress via "rvm_warmup". */
    @UsedByGodot fun warm_rvm(profile: String) {
        val host = activity ?: return
        if (!closed.get()) RvmWarmup.schedule(host, profile, rvmModel) { emitSignal("rvm_warmup", it.toString()) }
    }
    /** The selected model's kernels for [profile] are compiled; otherwise Alpha waits ~40 s for warm_rvm. */
    @UsedByGodot fun rvm_profile_ready(profile: String): Boolean {
        val host = activity ?: return false
        return !closed.get() && RvmWarmup.ready(host, profile, rvmModel)
    }
    @Volatile private var rvmModel = "fast"
    /** "fast" (default) or "quality"; Alpha sessions opened afterwards use it. */
    @UsedByGodot fun set_rvm_model(model: String): Boolean {
        if (model !in RvmWarmup.models || RvmNative.unavailable != null) return false
        RvmNative.selectGpuModel(model); rvmModel = model
        return true
    }
    /** depth: realtime 2D->3D (mono sources only, never with alpha). */
    /** topBottom: a stereo source with the views above each other (top = left eye) instead of side by side. */
    @UsedByGodot fun open_mpv_video(uri: String, startMs: Int, stereo: Boolean, profile: String, alpha: Boolean, vulkan: Boolean,
                                    depth: Boolean, topBottom: Boolean, exactSeek: Boolean): Int =
        if (closed.get()) -1 else mpv.open(uri, startMs, stereo, profile, alpha, vulkan, depth = depth, topBottom = topBottom,
            exactSeek = exactSeek)
    @UsedByGodot fun revise_mpv_video(id: Int, stereo: Boolean, alpha: Boolean, profile: String, positionMs: Int, depth: Boolean,
                                      topBottom: Boolean, exactSeek: Boolean): Int =
        if (closed.get()) -1 else mpv.revise(id, stereo, alpha, profile, positionMs, depth, topBottom, exactSeek)
    /** Background OpenCL compile of the 2D->3D depth model; progress via "rvm_warmup" (profile_key "depth"). */
    @UsedByGodot fun warm_depth() {
        val host = activity ?: return
        if (!closed.get()) DepthWarmup.schedule(host) { emitSignal("rvm_warmup", it.toString()) }
    }
    @UsedByGodot fun depth_ready(): Boolean {
        val host = activity ?: return false
        return !closed.get() && runCatching { DepthWarmup.ready(host) }.getOrDefault(false)
    }
    @UsedByGodot fun set_mpv_playing(id: Int, playing: Boolean) { if (!closed.get()) mpv.setPlaying(id, playing) }
    @UsedByGodot fun set_mpv_audio(id: Int, trackId: Int, volume: Double, muted: Boolean): Boolean =
        !closed.get() && mpv.setAudio(id, trackId, volume, muted)
    @UsedByGodot fun set_mpv_subtitle(id: Int, trackId: Int): Boolean = !closed.get() && mpv.setSubtitle(id, trackId)
    @UsedByGodot fun get_mpv_subtitles(id: Int, afterSequence: Long): String = if (closed.get()) "" else mpv.subtitles(id, afterSequence)
    @UsedByGodot fun set_mpv_depth_view(id: Int, shift: Double, convergence: Double): Boolean =
        !closed.get() && mpv.setDepthView(id, shift, convergence)
    @UsedByGodot fun claim_mpv_pair(id: Int, token: Long): String = if (closed.get()) "" else mpv.claim(id, token)
    @UsedByGodot fun acknowledge_mpv_pair(id: Int, token: Long): Boolean = !closed.get() && mpv.acknowledge(id, token)
    @UsedByGodot fun detach_mpv_pair(id: Int, token: Long): Boolean = mpv.detach(id, token)
    @UsedByGodot fun freeze_mpv_pair(id: Int, token: Long, request: Int): Boolean = !closed.get() && mpv.freeze(id, token, request)
    @UsedByGodot fun release_mpv_frozen_frame(id: Long) { mpv.releaseFrozen(id) }
    @UsedByGodot fun retain_mpv_frozen_frame(id: Long): Boolean = !closed.get() && mpv.retainFrozen(id)
    @UsedByGodot fun pin_mpv_pair(id: Int, token: Long): Boolean = !closed.get() && mpv.pinPair(id, token)
    @UsedByGodot fun release_mpv_pair_pin(id: Int, token: Long): Boolean = mpv.unpinPair(id, token)
    @UsedByGodot fun close_mpv_video(id: Int) { mpv.close(id) }
    @UsedByGodot fun request_mpv_pixel_mask(request: Int, id: Int, token: Long): Boolean =
        !closed.get() && mpv.requestPixelMask(request, id, token)
    @UsedByGodot fun release_mpv_pixel_pin(id: Int, token: Long): Boolean = mpv.unpinPixelPair(id, token)
    internal fun requestMpvPlayerCommand(json: String): Int {
        if (closed.get()) return -1
        if (BuildConfig.DEBUG) {
            val command = JSONObject(json)
            if (command.optString("operation") == "open") {
                mpv.debugNormalFramePath(command.optBoolean("normal_fast", true))
                mpv.debugFrameCap(command.optInt("frame_cap", -1))
                mpv.debugRoi(command.optBoolean("roi", true))
                mpv.debugZeroCopy(command.optBoolean("zero_copy", true))
                mpv.debugBorrowColor(command.optBoolean("borrow_color", true))
                mpv.debugDirect(command.optBoolean("direct_yuv", true))
            }
        }
        val id = requestId.incrementAndGet()
        emitSignal("mpv_debug_command", id, json)
        return id
    }
    @UsedByGodot fun save_mpv_player_report(id: Int, json: String): String {
        if (id <= 0) return "ERROR:INVALID_REQUEST"
        return try {
            JSONObject(json)
            val host = activity?.applicationContext ?: return "ERROR:ACTIVITY_UNAVAILABLE"
            val directory = File(host.filesDir, "diagnostics").apply { mkdirs() }
            val temporary = File.createTempFile("mpv-player-", ".tmp", directory)
            try {
                temporary.writeText(json)
                check(temporary.renameTo(File(directory, "mpv_player_$id.json")))
            } finally { temporary.delete() }
            "mpv_player_$id.json"
        } catch (failure: Exception) { "ERROR:" + failure.javaClass.simpleName }
    }

    override fun onMainRequestPermissionsResult(requestCode: Int, permissions: Array<String?>?, grantResults: IntArray?) {
        if (!closed.get()) sources.onPermissionResult(requestCode,
            grantResults != null && grantResults.isNotEmpty() && grantResults.all { it == android.content.pm.PackageManager.PERMISSION_GRANTED })
    }
    override fun onMainActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!closed.get()) picker.result(requestCode, resultCode, data)
    }

    override fun onGLDrawFrame(gl: GL10?) {
        if (EGL14.eglGetCurrentContext() == EGL14.EGL_NO_CONTEXT) return
        repeat(16) { controlledRenderTasks.poll()?.run() ?: return@repeat }
        if (!closed.get()) { media.draw(); controlled.draw(); mpv.draw() }
    }

    @UsedByGodot
    fun request_capabilities(): Int {
        if (closed.get()) return -1
        val id = requestId.incrementAndGet()
        try {
            probe.execute {
                if (closed.get() || id != requestId.get()) return@execute
                val result = try {
                    DeviceCapabilities.collect(graphicsSnapshot)
                } catch (error: Exception) {
                    JSONObject().put("probe_error", error.javaClass.simpleName + ": " + (error.message ?: ""))
                }
                if (!closed.get() && id == requestId.get()) {
                    emitSignal("capabilities_ready", id, result.toString())
                }
            }
        } catch (_: RejectedExecutionException) {
            return -1
        }
        return id
    }

    @UsedByGodot
    fun save_capability_report(json: String): String {
        val host = activity ?: return "ERROR:ACTIVITY_UNAVAILABLE"
        return try {
            JSONObject(json)
            val directory = File(host.filesDir, "diagnostics")
            if (!directory.isDirectory && !directory.mkdirs()) return "ERROR:DIRECTORY_UNAVAILABLE"
            val target = File(directory, "capabilities.json")
            val temporary = File.createTempFile("capabilities-", ".tmp", directory)
            try {
                temporary.writeText(json, Charsets.UTF_8)
                if (!temporary.renameTo(target)) return "ERROR:REPORT_RENAME_FAILED"
            } finally {
                if (temporary.exists()) temporary.delete()
            }
            target.absolutePath
        } catch (error: Exception) {
            Log.e("VRPassthroughPlayer", "Capability report could not be saved", error)
            "ERROR:" + error.javaClass.simpleName
        }
    }

    override fun onGLSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        media.contextCreated()
        controlled.contextCreated()
        mpv.contextCreated()
        val report = JSONObject().put("observed", true)
            .put("vendor", GLES30.glGetString(GLES30.GL_VENDOR))
            .put("renderer", GLES30.glGetString(GLES30.GL_RENDERER))
            .put("version", GLES30.glGetString(GLES30.GL_VERSION))
        val count = IntArray(1)
        GLES30.glGetIntegerv(GLES30.GL_NUM_EXTENSIONS, count, 0)
        val extensions = JSONArray()
        for (index in 0 until count[0]) extensions.put(GLES30.glGetStringi(GLES30.GL_EXTENSIONS, index))
        graphicsSnapshot = report.put("extensions", extensions).toString()
        Log.i("VRPassthroughPlayer", "GLES context observed")
    }

    // Android can resume before Godot registers the plugin's native signals.
    override fun onGodotSetupCompleted() { signalsReady = true }
    override fun onMainPause() { if (!closed.get()) { accounts.pause(true); media.pause(); controlled.pause(); mpv.pause(); if (signalsReady) emitSignal("android_lifecycle", "pause") } }
    override fun onMainResume() { if (!closed.get()) { accounts.pause(false); media.resume(); controlled.resume(); mpv.resume(); if (signalsReady) emitSignal("android_lifecycle", "resume") } }
    override fun onMainDestroy() { close() }
    override fun onGodotTerminating() { close() }

    private fun close() {
        if (closed.compareAndSet(false, true)) { accounts.close(); photos.close(); photoPreloads.close(); picker.close(); localAccess.close(); probe.shutdownNow(); media.shutdown(); controlled.shutdown(); mpv.shutdown(); rvm.close(); sources.close() }
    }
}
