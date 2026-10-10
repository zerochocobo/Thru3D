package org.vrpassthroughplayer.plugin

import android.content.Context
import android.net.Uri
import android.opengl.EGL14
import android.opengl.EGLContext
import android.os.Handler
import android.os.ParcelFileDescriptor
import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Production MPV -> shared GPU color -> immutable RVM inputs -> complete display
 * pairs. Native MPV survives mode/layout/seek generations; old display claims
 * survive invalidation only until Godot detaches them after its last draw.
 */
internal class MpvVideoBridge(
    private val context: () -> Context?,
    private val render: (Runnable) -> Unit,
    private val emit: (String, Int, String) -> Unit,
    /** Library URI (smb://, http(s)://) -> MPV location; blocks, called on the worker. */
    private val resolveNetwork: (String) -> String = { it },
    /** Library URI -> extra M4A tracks beside the video (clone voice); blocks, called on the worker. */
    private val sidecarAudio: (String) -> List<SidecarAudio.Track> = { emptyList() },
    private val releaseNetwork: (String) -> Unit = {},
    private val sidecarSubtitles: (String) -> List<SidecarSubtitles.Track> = { emptyList() },
) {
    private val worker = RvmWorkers.video
    private val gate = MediaSessionGate()
    private val sessions = ConcurrentHashMap<Int, Session>()
    private val hosts = ConcurrentHashMap.newKeySet<Host>()
    @Volatile private var foreground = true
    @Volatile private var stopped = false
    private val freezePending = AtomicBoolean(false)
    private val frozenFrames = ConcurrentHashMap<Long, AtomicInteger>()
    @Volatile private var debugNormalFastPath = true
    internal fun debugNormalFramePath(enabled: Boolean) { if (BuildConfig.DEBUG) debugNormalFastPath = enabled }
    @Volatile private var debugFrameCapOverride = -1
    /** Debug cadence verification only: -1 keeps the mode default. */
    internal fun debugFrameCap(fps: Int) { if (BuildConfig.DEBUG) debugFrameCapOverride = fps }
    @Volatile private var debugRoiDisabled = false
    /** Debug A/B only: run Alpha on the whole eye instead of the ROI window. */
    internal fun debugRoi(enabled: Boolean) { if (BuildConfig.DEBUG) debugRoiDisabled = !enabled }
    @Volatile private var debugZeroCopyDisabled = false
    /** Debug A/B only: CPU readback/upload transport instead of AHardwareBuffer zero-copy. */
    internal fun debugZeroCopy(enabled: Boolean) { if (BuildConfig.DEBUG) debugZeroCopyDisabled = !enabled }
    @Volatile private var debugBorrowDisabled = false
    /** Debug A/B only: copy every captured 8K color instead of holding the MPV slot. */
    internal fun debugBorrowColor(enabled: Boolean) { if (BuildConfig.DEBUG) debugBorrowDisabled = !enabled }
    @Volatile private var debugDirectDisabled = false
    /** Debug A/B only: MPV renders an 8K RGBA copy instead of handing over the decoder's image. */
    internal fun debugDirect(enabled: Boolean) { if (BuildConfig.DEBUG) debugDirectDisabled = !enabled }
    /** Alpha pairs show the decoder's own YUV image (no full-resolution RGBA render); needs borrowing. */
    private fun direct(session: Session) = session.alpha && session.vulkan && !debugBorrowDisabled && !debugDirectDisabled &&
        !debugZeroCopyDisabled
    private var audioFocus: MpvAudioFocus? = null // worker only
    @Volatile private var audioFocusState = "none"

    private inner class Host(val uri: String, val startMs: Int, val hardware: Boolean, val audio: Boolean, val exactStart: Boolean) {
        private val openNs = System.nanoTime()
        val startup = ConcurrentHashMap<String, Double>()
        fun markStartup(stage: String) { startup.putIfAbsent(stage, (System.nanoTime() - openNs) / 1_000_000.0) }
        @Volatile var handle = 0L
        @Volatile var owner: EGLContext? = null
        @Volatile var closing = false
        @Volatile var playing = true
        var speed = 1.0 // synchronized(host), retained across processing revisions
        @Volatile var audioEnabled = audio
        @Volatile var audioAvailable = audio
        @Volatile var descriptor: ParcelFileDescriptor? = null
        @Volatile var sidecars: List<ParcelFileDescriptor> = emptyList()
        @Volatile var networkLease: String? = null
        @Volatile var subtitleLeases: List<String> = emptyList()
        @Volatile var audioLeases: List<String> = emptyList()
        /** Only once MPV no longer reads them. */
        fun closeDescriptors() {
            networkLease?.let(releaseNetwork); networkLease = null
            subtitleLeases.forEach(releaseNetwork); subtitleLeases = emptyList()
            audioLeases.forEach(releaseNetwork); audioLeases = emptyList()
            descriptor?.close(); descriptor = null
            sidecars.forEach { runCatching { it.close() } }; sidecars = emptyList()
        }
        @Volatile var subtitleCommand = 0L
        var nextStatusNs = 0L // GL only
    }
    private data class Lease(val ticket: DecodedFrameGate.Ticket, val pair: JSONObject,
                             val left: ByteBuffer, val right: ByteBuffer,
                             val producer: Long = 0L) // Borrowed MPV slot, released when this lease retires.
    private data class Alpha(val pair: JSONObject, val left: ByteBuffer, val right: ByteBuffer)
    /** depth: realtime 2D->3D on a mono source; its near map rides in the Alpha mask slot. Never with alpha. */
    private class Session(val scope: MediaSessionGate.Scope, val host: Host, val stereo: Boolean,
                          val profile: String, val alpha: Boolean, val vulkan: Boolean, val normalFastPath: Boolean,
                          val depth: Boolean = false, val topBottom: Boolean = false) {
        val id get() = scope.decoderId
        val lock = Any()
        val disposed = AtomicBoolean(false)
        val display = PairDisplayGate(scope, depth = 2)
        val end = MpvEndGate(scope, alpha)
        val normal = FramePairGate(scope)
        @Volatile var model: RvmVideoProbe? = null
        @Volatile var depthModel: DepthVideoProbe? = null
        // 2D->3D view: eye-width fraction of the full parallax and the near value on the screen plane.
        @Volatile var depthShift = 0.035f
        @Volatile var depthConvergence = 0.35f
        val depthViewQueued = AtomicBoolean(false)
        /** Both effects run a model on every presented frame and gate pairs through it. */
        val inference get() = alpha || depth
        fun accepts(pair: JSONObject) = if (alpha) model?.acceptsPair(pair) == true else depthModel?.acceptsPair(pair) == true
        fun presented(pair: JSONObject) = if (alpha) model?.presented(pair) == true else depthModel?.presented(pair) == true
        @Volatile var roi: RoiController? = null // Alpha only; created with the renderer on the GL thread.
        val roiEnabled = alpha
        var zeroCopy = false // GL thread: the bridge stages inputs into AHardwareBuffers shared with MNN
        var borrow = false // GL thread: pairs show the MPV slot itself; no 8K copy per captured frame
        var copyingProducer = 0L // GL thread: producer lease held by the slot being staged
        var renderer = 0L // GL only under lock
        var owner: EGLContext? = null
        var copying: Pair<DecodedFrameGate.Ticket, Long>? = null
        var copyingPair: JSONObject? = null
        var pendingSource: JSONObject? = null // Retain producer lease until a consumer slot accepts the copy.
        var deferredCopies = 0L
        val leases = HashMap<Long, Lease>()
        val buffers = HashMap<Int, Pair<ByteBuffer, ByteBuffer>>()
        val scoutBuffers = HashMap<Int, Pair<ByteBuffer, ByteBuffer>>()
        val alphaUploads = HashMap<Long, Alpha>()
        val pairs = HashMap<Long, JSONObject>()
        val retiring = HashSet<Long>()
        var sourceEpoch = 0L
        var latestPair = ""
        var firstPair = false
        var captured = 0L
        var ownerDraws = 0L
        var uniquePostDrawFrames = 0L
        var lastPostDrawFrame = -1L
        var lastPostDrawEpoch = -1L
        var drawnToken = 0L
        val dims = (if (depth) DepthNative.PROFILE else profile).split('x').map { it.toInt() }
        val opaque by lazy {
            fun plane() = ByteBuffer.allocateDirect(dims[0]*dims[1]*4).order(ByteOrder.LITTLE_ENDIAN).also {
                for (i in 0 until dims[0]*dims[1]) it.putFloat(i*4, 1f)
            }
            plane() to plane()
        }
    }
    fun supported() = !stopped && MpvSourceNative.supported()
    /** User setting: decoded color width cap for sources opened from now on (0 = source size). */
    @Volatile var outputWidthCap = 0
    /** Alpha passthrough reads the source at 30fps: one RVM pair per presented frame. */
    private fun frameCap(session: Session) = if (BuildConfig.DEBUG && debugFrameCapOverride >= 0) debugFrameCapOverride
        // 2D->3D shows every frame with the latest depth map; only Alpha needs one result per frame.
        else if (session.alpha) RVM_VIDEO_FPS else 0
    private fun active(session: Session) = !stopped && !session.disposed.get() && gate.accepts(session.id)
    private fun event(name: String, session: Session, json: JSONObject) {
        json.put("session_id", session.id).put("logical_session_id", session.scope.logicalSessionId)
            .put("generation", session.scope.generation).put("backend", "Android_libmpv")
        emit(name, session.id, json.toString())
    }
    @Synchronized fun open(uri: String, startMs: Int, stereo: Boolean, profile: String,
                           alpha: Boolean, vulkan: Boolean, hardware: Boolean = true, audio: Boolean = true,
                           depth: Boolean = false, topBottom: Boolean = false, exactSeek: Boolean = false): Int {
        if (!supported() || sessions.size >= 2 || startMs < 0 || profile !in RvmProfiles.keys || (depth && (alpha || stereo)) ||
            Uri.parse(uri).scheme !in setOf("content", "file", "smb", "cloud", "medialib", "http", "https")) return -1
        val id = gate.begin(); if (id <= 0) return -1
        val host = Host(uri, startMs, hardware, audio, exactSeek)
        val session = Session(gate.current(id) ?: return -1, host, stereo, profile, alpha, vulkan, debugNormalFastPath, depth,
            stereo && topBottom)
        sessions[id] = session; hosts.add(host)
        sessions.values.filter { it.id != id }.forEach { dispose(it, true) }
        prepareModel(session)
        worker.post {
            try {
                host.markStartup("worker_started_ms")
                if (host.closing || stopped) return@post
                val app = context() ?: error("Activity unavailable")
                val source = Uri.parse(uri)
                val path = if (source.scheme == "file") source.path ?: error("Local file path unavailable")
                else if (source.scheme in setOf("smb", "cloud", "medialib", "http", "https")) resolveNetwork(uri).also {
                    if (source.scheme in setOf("medialib", "cloud", "smb")) host.networkLease = it
                } else {
                    val fd = app.contentResolver.openFileDescriptor(source, "r") ?: error("Local document descriptor unavailable")
                    host.descriptor = fd
                    "fd://${fd.fd}"
                }
                host.markStartup("source_resolved_ms")
                // Extra audio is optional: a failed lookup plays the video without it.
                val extra = if (audio) sidecarAudio(uri) else emptyList()
                host.markStartup("audio_sidecars_resolved_ms")
                host.sidecars = extra.mapNotNull { it.descriptor }
                host.audioLeases = extra.filter { it.location.startsWith("http://127.0.0.1:") }.map { it.location }
                val captions = sidecarSubtitles(uri)
                host.markStartup("subtitle_sidecars_resolved_ms")
                host.subtitleLeases = captions.map { it.location }
                if (host.closing || stopped) { host.closeDescriptors(); return@post }
                render(Runnable {
                    if (host.closing || stopped) return@Runnable
                    try {
                        host.owner = EGL14.eglGetCurrentContext()
                        host.markStartup("native_create_started_ms")
                        host.handle = MpvSourceNative.create(app, path, startMs, hardware, audio, outputWidthCap,
                            extra.flatMap { listOf(it.location, it.title) }.toTypedArray(),
                            captions.flatMap { listOf(it.location, it.title) }.toTypedArray(), host.exactStart)
                        check(host.handle > 0)
                        host.markStartup("native_created_ms")
                        synchronized(host) { check(MpvSourceNative.setSpeed(host.handle, host.speed)) }
                        MpvSourceNative.setFrameCap(host.handle, frameCap(session))
                        MpvSourceNative.setDirect(host.handle, direct(session))
                        // Native creation stays paused until focus policy has
                        // run off the Godot GL thread.
                        refreshPlayback()
                    } catch (failure: Throwable) { fail(session, "MPV_SOURCE_START_FAILED", failure) }
                })
            } catch (failure: Throwable) { fail(session, "MPV_LOCAL_SOURCE_FAILED", failure) }
        }
        return id
    }
    private fun prepareModel(session: Session) {
        if (session.depth) {
            // Depth never ends the session: until (or unless) the model runs, frames show in 2D.
            session.depthModel = DepthVideoProbe(session.scope, context, { token -> release(session, token) },
                { if (active(session)) event("mpv_state", session, JSONObject().put("state", "effect_ready")) },
                { pair, left, right -> deliver(session, pair, left, right) })
            session.depthModel!!.start()
            return
        }
        if (!session.alpha) return
        session.model = RvmVideoProbe(session.scope, session.profile, session.vulkan, context, worker,
            { token -> release(session, token) },
            { if (active(session)) event("mpv_state", session, JSONObject().put("state", "effect_ready")) },
            { pair, left, right -> deliver(session, pair, left, right) },
            { failure -> fail(session, "MPV_RVM_FAILED", failure) }, diagnostic = false, roi = { session.roi })
        session.model!!.start()
    }
    /** Model result -> GL upload into the pair's mask. True hands the color lease to the uploader. */
    private fun deliver(session: Session, pair: JSONObject, left: ByteBuffer, right: ByteBuffer): Boolean {
        if (!active(session)) return false
        render(Runnable {
            synchronized(session.lock) {
                if (!active(session)) { retire(session, pair.getLong("slot_token")); return@synchronized }
                try { upload(session, pair, left, right) }
                catch (failure: Throwable) { fail(session, "MPV_ALPHA_UPLOAD_FAILED", failure) }
            }
        })
        return true
    }
    /** Returns a new processing generation without reopening the MPV media/audio core. */
    @Synchronized fun revise(id: Int, stereo: Boolean, alpha: Boolean, profile: String, positionMs: Int = -1,
                             depth: Boolean = false, topBottom: Boolean = false, exactSeek: Boolean = false): Int {
        val old = sessions[id] ?: return -1
        if (!active(old) || sessions.size >= 2 || profile !in RvmProfiles.keys || (depth && (alpha || stereo))) return -1
        val host = old.host
        if (positionMs >= 0 && (host.handle <= 0 || !MpvSourceNative.seek(host.handle, positionMs.toLong(), exactSeek))) return -1
        val next = gate.replace(id); if (next <= 0) return -1
        val session = Session(gate.current(next) ?: return -1, host, stereo, profile, alpha, old.vulkan, old.normalFastPath, depth,
            stereo && topBottom)
        sessions[next] = session; dispose(old, false); prepareModel(session)
        if (host.handle > 0) MpvSourceNative.setFrameCap(host.handle, frameCap(session))
        if (host.handle > 0) MpvSourceNative.setDirect(host.handle, direct(session))
        if (host.handle > 0 && positionMs < 0) MpvSourceNative.requestFrame(host.handle)
        return next
    }
    fun setPlaying(id: Int, playing: Boolean) {
        val session = sessions[id] ?: return
        if (!active(session)) return
        session.host.playing = playing
        if (!playing && session.host.handle > 0) MpvSourceNative.setPlaying(session.host.handle, false)
        refreshPlayback(explicit = playing)
    }
    fun setSpeed(id: Int, speed: Double): Boolean {
        if (!speed.isFinite() || speed !in 0.25..3.0) return false
        val session = sessions[id] ?: return false
        synchronized(session.host) {
            if (!active(session) || session.host.closing) return false
            if (session.host.handle > 0 && !MpvSourceNative.setSpeed(session.host.handle, speed)) return false
            session.host.speed = speed
            return true
        }
    }
    fun setAudio(id: Int, trackId: Int, volume: Double, muted: Boolean): Boolean {
        val session = sessions[id] ?: return false
        if (!active(session) || session.host.handle <= 0) return false
        if (trackId != 0 && !session.host.audioEnabled) MpvSourceNative.setPlaying(session.host.handle, false)
        val accepted = MpvSourceNative.setAudio(session.host.handle, trackId, volume, muted)
        if (accepted) session.host.audioEnabled = trackId != 0
        refreshPlayback(explicit = accepted && trackId != 0)
        return accepted
    }
    fun setSubtitle(id: Int, trackId: Int): Boolean {
        val session = sessions[id] ?: return false
        if (!active(session) || session.host.handle <= 0 || trackId < -1) return false
        val serial = MpvSourceNative.setSubtitle(session.host.handle, trackId)
        if (serial <= 0) return false
        synchronized(session.host) {
            session.host.subtitleCommand = maxOf(session.host.subtitleCommand, serial)
        }
        return true
    }
    fun subtitles(id: Int, afterSequence: Long): String {
        val session = sessions[id] ?: return ""
        if (!active(session) || session.host.handle <= 0 || afterSequence < 0) return ""
        val text = MpvSourceNative.subtitleStatus(session.host.handle, afterSequence)
        if (text.isEmpty() || !active(session)) return ""
        return JSONObject(text).put("session_id", session.id).put("generation", session.scope.generation)
            .put("mpv_source_handle", session.host.handle).put("required_command_id", session.host.subtitleCommand).toString()
    }
    fun subtitleBitmap(id: Int, version: Long): ByteArray {
        val session = sessions[id] ?: return ByteArray(0)
        if (!active(session) || session.host.handle <= 0 || version <= 0) return ByteArray(0)
        val pixels = MpvSourceNative.subtitleBitmap(session.host.handle, version)
        return if (active(session)) pixels else ByteArray(0)
    }
    private fun refreshPlayback(explicit: Boolean = false) {
        worker.post {
            val needsAudio = !stopped && foreground && hosts.any {
                !it.closing && it.handle > 0 && it.playing && it.audioEnabled && it.audioAvailable
            }
            if (needsAudio && audioFocus == null) context()?.let { app ->
                audioFocus = MpvAudioFocus(app) { change ->
                    // Stop as soon as loss arrives; waiting for RVM work to
                    // finish must not keep audio playing over another app.
                    if (change != MpvAudioFocusGate.Change.GAIN) hosts.filter { !stopped && !it.closing && it.audioEnabled && it.audioAvailable }.forEach {
                        if (change == MpvAudioFocusGate.Change.LOSS) it.playing = false
                        if (it.handle > 0) MpvSourceNative.setPlaying(it.handle, false)
                    }
                    if (change == MpvAudioFocusGate.Change.LOSS) sessions.values.filter { active(it) && it.host.audioEnabled && it.host.audioAvailable }.forEach {
                        event("mpv_state", it, JSONObject().put("state", "paused").put("audio_focus_change", "loss"))
                    }
                    refreshPlayback()
                }
            }
            val granted = if (needsAudio) audioFocus?.acquire(explicit) == true else {
                audioFocus?.release(); true
            }
            audioFocusState = if (needsAudio) audioFocus?.state() ?: "unavailable" else "none"
            hosts.forEach { host -> if (!stopped && !host.closing && host.handle > 0) {
                MpvSourceNative.setPlaying(host.handle, foreground && host.playing &&
                    (!(host.audioEnabled && host.audioAvailable) || granted))
            } }
        }
    }
    fun draw() {
        for (session in sessions.values) synchronized(session.lock) {
            try {
                if (session.disposed.get()) { cleanup(session); return@synchronized }
                if (!active(session) || session.host.handle == 0L) return@synchronized
                check(session.host.owner == EGL14.eglGetCurrentContext()) { "MPV owner GL context changed" }
                if (session.renderer > 0) {
                    pollRetirements(session); finishUploads(session)
                    if (session.display.drawn(session.drawnToken)) {
                        session.ownerDraws++
                        session.pairs[session.drawnToken]?.let { pair ->
                            val frame = pair.getLong("frame_id")
                            val epoch = pair.getLong("source_epoch")
                            if (frame != session.lastPostDrawFrame || epoch != session.lastPostDrawEpoch) {
                                session.uniquePostDrawFrames++
                                session.lastPostDrawFrame = frame
                                session.lastPostDrawEpoch = epoch
                            }
                            session.end.postDraw(identity(pair), pair.getLong("source_epoch"), pair.getBoolean("inference_ran"))
                        }
                    }
                }
                finishCopy(session)
                if (!session.inference && session.normalFastPath) finishUploads(session)
                if (session.copying != null) return@synchronized
                // Open/revise starts MPV paused until Godot displays the first complete pair.
                // Taking that frame before RVM is ready drops it in drain(); paused MPV then
                // has no new frame to offer and the Alpha transition never completes.
                val effectReady = !session.alpha || session.model?.isReady() == true
                if (effectReady) {
                    val source = session.pendingSource ?: MpvSourceNative.acquire(session.host.handle)
                        .takeIf { it.isNotEmpty() }?.let { JSONObject(it) }
                    session.pendingSource = null
                    if (source != null && !capture(session, source)) {
                        session.pendingSource = source
                        session.deferredCopies++
                    }
                }
                if (System.nanoTime() >= session.host.nextStatusNs) {
                    session.host.nextStatusNs = System.nanoTime()+250_000_000L
                    val status = JSONObject(MpvSourceNative.status(session.host.handle))
                    if (BuildConfig.DEBUG && session.renderer > 0)
                        status.put("bridge", JSONObject(RenderBridgeNative.stats(session.renderer)))
                    status.put("normal_fast_path", !session.inference && session.normalFastPath)
                        .put("rvm_video_fps_cap", frameCap(session))
                    session.roi?.status()?.forEach { (key, value) -> status.put(key, if (value is List<*>) JSONArray(value) else value) }
                    session.model?.stats()?.forEach { (key, value) -> status.put(key, value) }
                    session.depthModel?.stats()?.forEach { (key, value) -> status.put(key, value) }
                    val details = status.optJSONObject("details")
                    if (!details?.optString("codec").isNullOrEmpty()) {
                        val available = (details?.optJSONArray("audio_tracks")?.length() ?: 0) > 0 && session.host.audio
                        if (available != session.host.audioAvailable) {
                            session.host.audioAvailable = available; refreshPlayback()
                        }
                    }
                    val terminal = if (status.optBoolean("eof_source_resolved")) status.optJSONObject("eof_source_ticket") else null
                    session.end.observe(terminal?.let { MpvEndGate.Source(it.getLong("source_epoch"), it.getLong("frame_id"), it.getLong("pts_us")) })
                    event("mpv_state", session, status.put("alpha_requested", session.alpha).put("depth_requested", session.depth)
                        .put("startup_bridge", JSONObject(session.host.startup as Map<*, *>))
                        .put("captured_frames", session.captured)
                        .put("display_claims", session.display.heldClaims()).put("post_draw_frames", session.ownerDraws)
                        .put("unique_post_draw_frames", session.uniquePostDrawFrames).put("rvm_model_created", session.model != null)
                        .put("rvm_model_ready", session.model?.isReady() == true)
                        .put("producer_copy_deferred", session.deferredCopies).put("producer_copy_pending", session.pendingSource != null)
                        .put("eof_pair_post_draw", session.end.complete()).put("eof_presented_slot", session.end.completedSlot())
                        .put("audio_focus", audioFocusState))
                    if (status.optString("state") == "failed" || status.optBoolean("render_failed"))
                        error(status.optString("error") + " " + status.optString("render_error"))
                }
            } catch (failure: Throwable) { fail(session, "MPV_FRAME_PIPELINE_FAILED", failure) }
        }
        for (host in hosts) if (host.closing && sessions.values.none { it.host === host }) {
            try {
                if (host.handle == 0L || MpvSourceNative.close(host.handle, host.owner != EGL14.eglGetCurrentContext())) {
                    host.handle = 0; host.closeDescriptors(); hosts.remove(host)
                }
            } catch (_: Throwable) { /* Preserve ownership and retry; never close a descriptor still used by MPV. */ }
        }
    }
    private fun capture(session: Session, source: JSONObject): Boolean {
        val producer = source.getLong("producer_token")
        var releaseProducer = true
        try {
            check(source.getBoolean("source_ticket_valid") && source.getBoolean("producer_fence_ready") && source.getBoolean("owner_context_shared"))
            val width = source.getInt("width"); val height = source.getInt("height")
            check(!session.stereo || (if (session.topBottom) height else width) % 2 == 0)
            val eyeWidth = if (session.stereo && !session.topBottom) width / 2 else width
            val eyeHeight = if (session.topBottom) height / 2 else height
            val epoch = source.getLong("source_epoch")
            if (session.sourceEpoch == 0L) session.sourceEpoch = epoch
            check(session.sourceEpoch == epoch) { "Source epoch changed without processing generation reset" }
            if (session.renderer == 0L) {
                session.owner = EGL14.eglGetCurrentContext()
                session.renderer = RenderBridgeNative.create(width, height, session.dims[0], session.dims[1], session.stereo, session.topBottom)
                if (session.alpha && session.vulkan && !debugZeroCopyDisabled)
                    session.zeroCopy = RenderBridgeNative.enableZeroCopy(session.renderer)
                // Alpha keeps each captured MPV slot for the pair's life instead of copying 8K (~270MB
                // of bus traffic per frame); MPV has spare slots for the frames in flight.
                if (session.alpha && !debugBorrowDisabled)
                    session.borrow = RenderBridgeNative.enableBorrowedColor(session.renderer)
                if (session.roiEnabled && !debugRoiDisabled) session.roi = RoiController(RenderBridgeNative.fullInputRect(session.renderer),
                    session.dims[0], session.dims[1], eyeWidth, eyeHeight)
            }
            val buffer = source.optLong("hardware_buffer", 0L)
            // A decoder image published for an earlier Alpha session: release it and wait for the next frame.
            if (buffer != 0L && !(session.alpha && session.borrow)) return true
            val plan = session.roi?.plan()
            val token = if (buffer != 0L)
                RenderBridgeNative.captureBufferRoi(session.renderer, buffer, source.getInt("buffer_width"), source.getInt("buffer_height"),
                    plan?.rect ?: RenderBridgeNative.fullInputRect(session.renderer), plan?.scout ?: false)
            else if (!session.inference && session.normalFastPath)
                RenderBridgeNative.captureOpaqueTexture(session.renderer, source.getInt("color_texture_id"))
            else if (plan != null)
                RenderBridgeNative.captureTextureRoi(session.renderer, source.getInt("color_texture_id"), plan.rect, plan.scout)
            // 2D->3D stages (and later reads back) a model input only when the depth model will take it.
            else RenderBridgeNative.captureTexture(session.renderer, source.getInt("color_texture_id"),
                session.alpha || (session.depth && session.depthModel?.wantsInput() == true).also { source.put("depth_input_staged", it) })
            if (token == 0L) {
                // A full consumer ring must not consume the only remaining EOF
                // frame. Keep the immutable producer lease and retry next draw.
                releaseProducer = false
                return false
            }
            if (session.borrow) { session.copyingProducer = producer; releaseProducer = false }
            val ticket = DecodedFrameGate.Ticket(session.scope, source.getLong("frame_id"), source.getLong("pts_us"), 1, 1)
            val sourceAspect = eyeWidth.toDouble()/eyeHeight
            val inputAspect = session.dims[0].toDouble()/session.dims[1]
            val rect = plan?.rect?.map { it.toDouble() }
                ?: if (sourceAspect > inputAspect) { val h = inputAspect/sourceAspect; listOf(0.0, (1-h)*0.5, 1.0, h) }
                else { val w = sourceAspect/inputAspect; listOf((1-w)*0.5, 0.0, w, 1.0) }
            source.put("producer_color_texture_id", source.getInt("color_texture_id"))
                .put("mpv_source_handle", session.host.handle)
                .put("godot_context_shared", true)
                .put("slot_token", token).put("format_revision", 1).put("effect_revision", 1)
                .put("session_id", session.id).put("logical_session_id", session.scope.logicalSessionId).put("generation", session.scope.generation)
                .put("input_width", session.dims[0]).put("input_height", session.dims[1]).put("profile_key", session.profile)
                .put("input_layout", "float32_CHW_RGB_0_1").put("model_content_rect", JSONArray(rect)).put("stereo_sbs", session.stereo).put("top_bottom", session.topBottom)
                .put("source_pts_verified", true).put("source_ticket_origin", "private_same_mpv_render_transaction")
                .put("alpha_requested", session.alpha).put("depth_requested", session.depth).put("immutable_color_frame", true)
            if (plan != null) source.put("roi_window_id", plan.windowId).put("roi_scout", plan.scout).put("roi_zoomed", plan.zoomed)
            session.copying = ticket to token; session.copyingPair = source
            return true
        } finally {
            // This consumer fence follows the full-resolution GPU copy and small
            // input staging. There is never a CPU readback of the source image.
            if (releaseProducer)
                check(MpvSourceNative.release(session.host.handle, producer)) { "Producer lease release failed" }
        }
    }
    private fun finishCopy(session: Session) {
        val copying = session.copying ?: return
        if (!RenderBridgeNative.ready(session.renderer, copying.second)) return
        val texture = RenderBridgeNative.texture(session.renderer, copying.second)
        val bytes = session.dims[0]*session.dims[1]*3*4
        val pair = session.copyingPair ?: error("Immutable copy descriptor missing")
        // Decoder images get a new texture each frame and always use zero-copy: no CPU planes.
        val buffers = if (pair.has("hardware_buffer")) NO_PLANES else session.buffers.getOrPut(texture) {
            ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN) to ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN)
        }
        pair.put("color_texture_id", texture).put("consumer_copy_fence_ready", true)
        val image = RenderBridgeNative.colorImage(session.renderer, copying.second)
        // A string: Godot's JSON parses numbers as doubles, which cannot hold a 64-bit (tagged) pointer.
        if (image != 0L) pair.put("color_target", "external").put("color_egl_image", image.toString()).put("color_uv_scale", JSONArray(listOf(
            pair.getInt("width").toDouble() / pair.getInt("buffer_width"), pair.getInt("height").toDouble() / pair.getInt("buffer_height"))))
        val lease = Lease(copying.first, pair, buffers.first, buffers.second, session.copyingProducer)
        session.copyingProducer = 0L
        session.leases[copying.second] = lease
        session.copying = null; session.copyingPair = null; session.captured++
        if (session.alpha && session.zeroCopy) {
            pair.put("alpha_transport", "zero_copy")
            val shared = RenderBridgeNative.zeroCopyBuffers(session.renderer, copying.second, false)
            val scout = if (pair.optBoolean("roi_scout")) RenderBridgeNative.zeroCopyBuffers(session.renderer, copying.second, true) else null
            session.model!!.submitShared(copying.first, copying.second, shared, pair, scout)
        } else if (session.alpha) {
            check(RenderBridgeNative.readInputs(session.renderer, copying.second, buffers.first, buffers.second))
            val scout = if (pair.optBoolean("roi_scout")) session.scoutBuffers.getOrPut(texture) {
                ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN) to ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN)
            }.also { check(RenderBridgeNative.readScoutInputs(session.renderer, copying.second, it.first, it.second)) } else null
            session.model!!.submit(copying.first, copying.second, buffers.first, buffers.second, pair, scout?.first, scout?.second)
        } else if (session.depth) {
            // Mono: both staged eyes hold the same frame; the model reads one. Frames the model skips
            // were not staged: they show with the latest map and cost no readback.
            val staged = pair.optBoolean("depth_input_staged")
            if (staged) check(RenderBridgeNative.readInputs(session.renderer, copying.second, buffers.first, buffers.second))
            session.depthModel!!.submit(copying.first, copying.second, if (staged) buffers.first else null, pair)
        } else {
            pair.put("model_generation", 1).put("inference_ran", false).put("pair_identity_verified", true)
                .put("alpha_kind", "opaque_numeric_mask")
            if (session.normalFastPath) {
                check(RenderBridgeNative.alphaReady(session.renderer, copying.second)) { "Opaque mask must share the completed color fence" }
                session.alphaUploads[copying.second] = Alpha(pair, session.opaque.first, session.opaque.second)
            } else upload(session, pair, session.opaque.first, session.opaque.second)
        }
    }
    private fun upload(session: Session, pair: JSONObject, left: ByteBuffer, right: ByteBuffer) {
        val token = pair.getLong("slot_token")
        check(session.leases.containsKey(token)) { "Alpha color lease unavailable" }
        if (pair.optString("alpha_transport") == "zero_copy") check(RenderBridgeNative.commitZeroCopyAlpha(session.renderer, token))
        else check(RenderBridgeNative.uploadAlpha(session.renderer, token, left, right))
        if (session.depth && pair.optBoolean("depth_ran")) {
            val stereo = RenderBridgeNative.warp(session.renderer, token, session.depthShift, session.depthConvergence)
            if (stereo > 0) pair.put("warp_texture_id", stereo) else pair.remove("warp_texture_id")
        }
        session.alphaUploads[token] = Alpha(pair, left, right)
    }
    private fun finishUploads(session: Session) {
        val iterator = session.alphaUploads.iterator()
        while (iterator.hasNext()) {
            val (token, upload) = iterator.next()
            if (session.inference && !session.accepts(upload.pair)) {
                iterator.remove(); retire(session, token); continue
            }
            if (!RenderBridgeNative.alphaReady(session.renderer, token)) continue
            iterator.remove()
            val pair = upload.pair.put("alpha_texture_id", RenderBridgeNative.alphaTexture(session.renderer, token))
                .put("alpha_width", session.dims[0]*2).put("alpha_height", session.dims[1])
                .put("alpha_texture_format", "GL_R8_numeric").put("alpha_gpu_uploaded", true).put("alpha_fence_ready", true)
                .put("alpha_slot_token", token).put("alpha_frame_id", upload.pair.getLong("frame_id"))
                .put("alpha_pts_us", upload.pair.getLong("pts_us"))
            val obsolete = session.display.offer(identity(pair))
            if (obsolete == token) { retire(session, token); continue }
            obsolete?.let { retire(session, it) }
            session.pairs[token] = pair; session.latestPair = pair.toString()
            // Godot claims the oldest ready pair; a newer one is offered once that is claimed. When a full
            // queue drops the oldest (the one Godot was told about), tell Godot the new oldest: otherwise its
            // claim of the dropped pair fails and no notice ever comes again (frozen picture at high rates).
            val head = session.display.readyToken()
            if (head != null && (head == token || obsolete != null))
                session.pairs[head]?.let { emit("mpv_pair_available", session.id, it.toString()) }
        }
    }
    private fun identity(pair: JSONObject) = FramePairGate.Identity(pair.getInt("session_id"), pair.getInt("logical_session_id"),
        pair.getInt("generation"), pair.getLong("frame_id"), pair.getLong("pts_us"), pair.getInt("format_revision"),
        pair.getLong("effect_revision"), pair.getLong("model_generation"), pair.getLong("slot_token"))
    fun setDepthView(id: Int, shift: Double, convergence: Double): Boolean {
        val session = sessions[id] ?: return false
        if (!session.depth || shift !in 0.0..0.2 || convergence !in 0.0..1.0) return false
        session.depthShift = shift.toFloat(); session.depthConvergence = convergence.toFloat()
        // Rewarp the held display texture as well: paused videos have no new frame to upload.
        // Read current values on the render thread so rapid pointer updates coalesce naturally.
        if (session.depthViewQueued.compareAndSet(false, true)) render(Runnable { synchronized(session.lock) {
            session.depthViewQueued.set(false)
            if (active(session) && session.renderer > 0 && session.owner == EGL14.eglGetCurrentContext()) {
                val token = session.drawnToken
                val pair = session.pairs[token]
                if (pair != null && pair.optInt("warp_texture_id") > 0 && session.display.owns(token)) {
                    runCatching { RenderBridgeNative.warp(session.renderer, token, session.depthShift, session.depthConvergence) }
                        .onFailure { android.util.Log.w("QuestPlayer", "Depth view refresh failed", it) }
                }
            }
        } })
        return true
    }
    fun claim(id: Int, token: Long): String {
        val session = sessions[id] ?: return ""
        val next: String?
        val claimed: String
        synchronized(session.lock) {
            if (!active(session) || session.display.claim(token) == null) return ""
            claimed = session.pairs[token]?.toString() ?: ""
            next = session.display.readyToken()?.let { session.pairs[it]?.toString() }
        }
        // The next ready pair (a burst) is drawn on Godot's following frame.
        next?.let { emit("mpv_pair_available", session.id, it) }
        return claimed
    }
    /** Capture on a real owner draw callback, while the original display claim is pinned.
     * Its returned copy outlives the old processing session, without a decoder lease. */
    fun freeze(id: Int, token: Long, request: Int): Boolean {
        val session = sessions[id] ?: return false
        if (request <= 0 || !freezePending.compareAndSet(false, true)) return false
        synchronized(session.lock) {
            if (!active(session) || !session.display.pin(token)) { freezePending.set(false); return false }
        }
        try {
            render(Runnable { synchronized(session.lock) {
                val report = JSONObject().put("request_id", request).put("slot_token", token)
                try {
                    check(active(session)) { "Freeze source no longer active" }
                    val pair = JSONObject(session.pairs.getValue(token).toString())
                    val warp = pair.optInt("warp_texture_id") > 0 && !pair.getBoolean("stereo_sbs")
                    val copy = RenderBridgeNative.freezePair(session.renderer, token, warp)
                    frozenFrames[copy[0]] = AtomicInteger(1)
                    pair.put("frozen_frame_id", copy[0]).put("freeze_copy_us", copy[5])
                        .put("color_target", "texture").put("color_texture_id", copy[1])
                        .put("alpha_texture_id", copy[2]).put("color_egl_image", "0")
                        .put("warp_texture_id", if (warp) copy[1] else 0)
                    report.put("pair", pair).put("state", "ready")
                } catch (failure: Throwable) {
                    report.put("state", "failed").put("error", failure.message)
                } finally {
                    session.display.unpin(token); freezePending.set(false)
                    release(session, token)
                }
                emit("mpv_frozen_pair", session.id, report.toString())
            } })
            return true
        } catch (_: Throwable) {
            synchronized(session.lock) { session.display.unpin(token) }
            freezePending.set(false)
            return false
        }
    }
    fun releaseFrozen(id: Long) {
        if (id <= 0) return
        render(Runnable {
            val refs = frozenFrames[id] ?: return@Runnable
            if (refs.decrementAndGet() == 0 && frozenFrames.remove(id, refs)) RenderBridgeNative.releaseFrozen(id)
        })
    }
    fun retainFrozen(id: Long): Boolean {
        val refs = frozenFrames[id] ?: return false
        while (true) {
            val count = refs.get()
            if (count <= 0) return false
            if (refs.compareAndSet(count, count + 1)) return true
        }
    }
    fun acknowledge(id: Int, token: Long): Boolean {
        val session = sessions[id] ?: return false
        synchronized(session.lock) {
            val pair = session.pairs[token] ?: return false
            if (!active(session) || (session.inference && !session.presented(pair)) || !session.display.acknowledge(token)) return false
            session.drawnToken = token; pair.put("pair_presented", true); session.firstPair = true
            session.host.markStartup("first_pair_bound_ms")
            return true
        }
    }
    fun detach(id: Int, token: Long): Boolean {
        val session = sessions[id] ?: return false
        synchronized(session.lock) { if (!session.display.detach(token)) return false }
        render(Runnable { synchronized(session.lock) {
            if (session.renderer > 0 && session.owner == EGL14.eglGetCurrentContext() && !session.display.owns(token)) retire(session, token)
        } })
        return true
    }
    private fun release(session: Session, token: Long) {
        render(Runnable { synchronized(session.lock) {
            if (session.renderer > 0 && session.owner == EGL14.eglGetCurrentContext() && !session.display.owns(token)) retire(session, token)
        } })
    }
    private fun retire(session: Session, token: Long) {
        check(!session.display.owns(token)) { "Cannot retire a Godot display claim" }
        val lease = session.leases.remove(token) ?: return
        session.pairs.remove(token)
        RenderBridgeNative.retire(session.renderer, token); session.retiring.add(token)
        // After the bridge fence: the MPV slot may be reused once every draw of this pair completes.
        if (lease.producer > 0) check(MpvSourceNative.release(session.host.handle, lease.producer)) { "Borrowed producer release failed" }
    }
    fun requestPixelMask(request: Int, id: Int, token: Long): Boolean {
        if (!BuildConfig.DEBUG || request <= 0) return false
        val session = sessions[id] ?: return false
        val pair = synchronized(session.lock) {
            if (!active(session) || !session.pairs.containsKey(token) || !session.display.pin(token)) return false
            JSONObject(session.pairs.getValue(token).toString())
        }
        try {
            render(Runnable { synchronized(session.lock) {
                val report = JSONObject().put("request_id", request).put("pair", pair)
                try {
                    check(session.renderer > 0 && session.owner == EGL14.eglGetCurrentContext())
                    val pixels = pair.getInt("alpha_width") * pair.getInt("alpha_height")
                    val buffer = ByteBuffer.allocateDirect(pixels)
                    check(RenderBridgeNative.readAlpha(session.renderer, token, buffer))
                    val bytes = ByteArray(pixels); buffer.position(0); buffer.get(bytes)
                    val app = context() ?: error("Activity unavailable")
                    val directory = java.io.File(app.filesDir, "diagnostics").apply { mkdirs() }
                    val name = "mpv_pixel_mask_$request.r8"
                    val temporary = java.io.File.createTempFile("mask-", ".tmp", directory)
                    try { temporary.writeBytes(bytes); check(temporary.renameTo(java.io.File(directory, name))) }
                    finally { temporary.delete() }
                    report.put("state", "ready").put("mask_file", name).put("mask_bytes", pixels)
                        .put("mask_origin", "same_pinned_pair_native_R8_readback")
                } catch (failure: Throwable) {
                    report.put("state", "failed").put("error", failure.message)
                    unpinPixelPair(id, token)
                }
                emit("mpv_pixel_mask", request, report.toString())
            } })
            return true
        } catch (_: Throwable) {
            synchronized(session.lock) { session.display.unpin(token) }
            return false
        }
    }
    fun unpinPixelPair(id: Int, token: Long): Boolean {
        if (!BuildConfig.DEBUG) return false
        return unpinPair(id, token)
    }
    fun pinPair(id: Int, token: Long): Boolean {
        val session = sessions[id] ?: return false
        synchronized(session.lock) { return active(session) && session.display.pin(token) }
    }
    fun unpinPair(id: Int, token: Long): Boolean {
        val session = sessions[id] ?: return false
        synchronized(session.lock) { if (!session.display.unpin(token)) return false }
        release(session, token)
        return true
    }
    private fun pollRetirements(session: Session) {
        val iterator = session.retiring.iterator()
        while (iterator.hasNext()) if (RenderBridgeNative.retired(session.renderer, iterator.next())) iterator.remove()
    }
    private fun cleanup(session: Session) {
        session.pendingSource?.let { source ->
            if (session.host.owner == EGL14.eglGetCurrentContext()) {
                check(MpvSourceNative.release(session.host.handle, source.getLong("producer_token")))
            } else {
                // The lost owner context cannot insert a consumer release fence.
                session.host.closing = true
                MpvSourceNative.close(session.host.handle, true)
            }
            session.pendingSource = null
        }
        if (session.renderer > 0) {
            if (session.owner != EGL14.eglGetCurrentContext()) {
                RenderBridgeNative.abandon(session.renderer); session.renderer = 0; session.retiring.clear()
            } else {
                session.copying?.let { RenderBridgeNative.retire(session.renderer, it.second); session.retiring.add(it.second) }
                if (session.copyingProducer > 0) MpvSourceNative.release(session.host.handle, session.copyingProducer)
                session.copyingProducer = 0L
                session.copying = null; session.copyingPair = null; session.alphaUploads.clear()
                session.leases.keys.toList().filter { !session.display.owns(it) }.forEach { retire(session, it) }
                pollRetirements(session)
            }
        }
        if (session.display.heldClaims() > 0 || session.retiring.isNotEmpty()) return
        if (session.renderer > 0) RenderBridgeNative.close(session.renderer)
        session.renderer = 0; session.buffers.clear(); session.scoutBuffers.clear(); session.leases.clear(); session.pairs.clear()
        sessions.remove(session.id)
        event("mpv_released", session, JSONObject().put("renderer_closed", true).put("held_slots", 0))
    }
    private fun dispose(session: Session, closeHost: Boolean) {
        if (!session.disposed.compareAndSet(false, true)) return
        session.model?.close(); session.depthModel?.close(); session.normal.close()
        synchronized(session.lock) { session.display.close() }
        if (closeHost) {
            session.host.closing = true
            if (session.host.handle > 0) MpvSourceNative.setPlaying(session.host.handle, false)
            refreshPlayback()
        }
        event("mpv_detach", session, JSONObject().put("reason", "generation_invalidated"))
    }
    private fun fail(session: Session, code: String, failure: Throwable) {
        if (session.disposed.get()) return
        event("mpv_error", session, JSONObject().put("code", code).put("message", failure.message))
        gate.invalidate(session.id); dispose(session, true)
    }
    fun close(id: Int) { sessions[id]?.let { gate.invalidate(id); dispose(it, true) } }
    fun pause() {
        foreground = false; hosts.forEach { if (it.handle > 0) MpvSourceNative.setPlaying(it.handle, false) }
        refreshPlayback()
    }
    fun resume() { foreground = true; refreshPlayback() }
    fun contextCreated() {
        frozenFrames.keys.toList().forEach { RenderBridgeNative.releaseFrozen(it); frozenFrames.remove(it) }
        // A real recreated context invalidates the complete pipeline. Initial
        // creation has no sessions; UI can reopen the same authorized URI.
        sessions.values.forEach { fail(it, "MPV_GL_CONTEXT_RECREATED", IllegalStateException("Owner context recreated")) }
    }
    companion object {
        const val RVM_VIDEO_FPS = 30
        private val NO_PLANES: Pair<ByteBuffer, ByteBuffer> = ByteBuffer.allocateDirect(0) to ByteBuffer.allocateDirect(0)
    }
    fun shutdown() {
        stopped = true; gate.shutdown(); sessions.values.forEach { dispose(it, true) }
        // Android may never deliver another draw during termination. Forget old
        // owner references and let each shared native context release its objects.
        hosts.forEach { host -> if (host.handle > 0) MpvSourceNative.close(host.handle, true) }
        Thread({
            for (host in hosts.toList()) {
                while (host.handle > 0) {
                    if (MpvSourceNative.close(host.handle, true)) { host.handle = 0; break }
                    Thread.sleep(20)
                }
                host.closeDescriptors()
            }
        }, "QuestMpvDispose").start()
        // Sessions/models/resources close above; the shared RVM worker survives
        // Activity recreation so libomp never loses its final root thread.
    }
}
