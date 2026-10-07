package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.opengl.EGL14
import android.opengl.EGLContext
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.CRC32
import kotlin.math.abs

/** R02 controlled video/immutable slots. AudioTrack and production scheduling remain R03/R04.
 * Player mode transfers complete pairs to Godot display claims; probes save bounded evidence.
 */
internal class ControlledVideoBridge(
    private val context: () -> Context?,
    private val render: (Runnable) -> Unit,
    private val emit: (String, Int, String) -> Unit,
) {
    private val thread = HandlerThread("QuestControlledDecoder").apply { start() }
    private val worker = Handler(thread.looper)
    private val rvmWorker = RvmWorkers.video
    private val gate = MediaSessionGate()
    private val sessions = ConcurrentHashMap<Int, Session>()
    @Volatile private var foreground = true

    private data class Format(val width: Int, val height: Int, val rotation: Int, val crop: List<Int>,
                              val standard: Int, val range: Int, val transfer: Int, val revision: Int = 1,
                              val stride: Int = -1, val sliceHeight: Int = -1)
    private data class Lease(val ticket: DecodedFrameGate.Ticket, val format: Format, val token: Long, val texture: Int,
                             val left: ByteBuffer, val right: ByteBuffer, val transform: FloatArray)
    private data class AlphaPacket(val pair: JSONObject, val left: ByteBuffer, val right: ByteBuffer,
                                   val uploadNs: Long, val checks: JSONArray)
    private class Session(val scope: MediaSessionGate.Scope, val uri: String, val startMs: Int,
                          val stereo: Boolean, val profile: String, val probe: Boolean, val rvmProbe: Boolean,
                          val vulkan: Boolean, val display: Boolean) {
        val id = scope.decoderId
        val disposed = AtomicBoolean(false)
        val frames = DecodedFrameGate(scope)
        val lock = Any()
        @Volatile var format: Format? = null
        @Volatile var releasedFormat: Format? = null
        var extractor: MediaExtractor? = null // worker only
        var codec: MediaCodec? = null // worker only
        var selectedFormat: MediaFormat? = null
        var durationUs = -1L
        var audioPresent = false
        var requestedPlay = true
        var inputEos = false
        var outputEos = false
        var ended = false
        var nextFrame = 0L
        var dropped = 0L
        var heldOutput: Pair<Int, MediaCodec.BufferInfo>? = null
        var anchorNs = 0L
        var anchorPtsUs = 0L
        var clockRunning = false
        var clockStarted = false
        var decoder = ""
        @Volatile var renderer = 0L // GL under lock
        var owner: EGLContext? = null
        var texture: SurfaceTexture? = null
        var surface: Surface? = null
        var copying: Pair<DecodedFrameGate.Ticket, Long>? = null
        var copyingTransform: FloatArray? = null
        var latched: DecodedFrameGate.Ticket? = null
        val leases = ConcurrentHashMap<Long, Lease>()
        val buffers = HashMap<Int, Pair<ByteBuffer, ByteBuffer>>() // GL only, max3
        @Volatile var captured = 0L
        @Volatile var latestFrame = "{}"
        @Volatile var latestState = "{}"
        val saveQueued = AtomicBoolean(false)
        @Volatile var model: RvmVideoProbe? = null
        val rvmPairs = JSONArray() // Guarded by lock; capped at eight.
        val alphaUploads = HashMap<Long, AlphaPacket>() // GL/lock; bounded by the three color leases.
        val displayGate = PairDisplayGate(scope)
        val displayPairs = HashMap<Long, JSONObject>() // ready/claimed only, max three.
        val retirements = HashSet<Long>() // GL only; fences checked before another capture.
        @Volatile var workerReleased = false
        var displayedToken = 0L
        var displayDraws = 0L
        var lastDisplayed = "{}"
    }
    private fun enqueueAlpha(session: Session, pair: JSONObject, left: ByteBuffer, right: ByteBuffer): Boolean {
        if (!active(session)) return false
        render(Runnable {
            synchronized(session.lock) {
                if (!active(session)) return@Runnable
                try {
                    val token = pair.getLong("slot_token")
                    val lease = session.leases[token] ?: error("RVM color lease missing")
                    check(lease.ticket.frameId == pair.getLong("frame_id") && lease.ticket.ptsUs == pair.getLong("pts_us"))
                    if (session.model?.acceptsPair(pair) != true) { retire(session, token); return@Runnable }
                    val checks = JSONArray()
                    if (session.probe && pair.getInt("probe_ordinal") == 1) {
                        rejectAlpha(checks, "no_mask_before_upload") { RenderBridgeNative.alphaTexture(session.renderer, token) }
                        rejectAlpha(checks, "wrong_right_capacity") {
                            RenderBridgeNative.uploadAlpha(session.renderer, token, left, ByteBuffer.allocateDirect(right.capacity()-4))
                        }
                        rejectAlpha(checks, "overlapping_eyes") { RenderBridgeNative.uploadAlpha(session.renderer, token, left, left) }
                        val bad = ByteBuffer.allocateDirect(right.capacity()).order(ByteOrder.LITTLE_ENDIAN).apply { putFloat(0, Float.NaN) }
                        rejectAlpha(checks, "bad_right_no_partial_upload") { RenderBridgeNative.uploadAlpha(session.renderer, token, left, bad) }
                    }
                    val upload = {
                        val started = System.nanoTime()
                        check(RenderBridgeNative.uploadAlpha(session.renderer, token, left, right))
                        pair.put("alpha_upload_submit_ms", (System.nanoTime()-started)/1e6)
                        if (session.probe && pair.getInt("probe_ordinal") == 1) {
                            rejectAlpha(checks, "immutable_mask_rejects_second_upload") { RenderBridgeNative.uploadAlpha(session.renderer, token, left, right) }
                        }
                    }
                    if (session.probe) {
                        withAlphaPixelStoreStress(upload)
                        checks.put(JSONObject().put("case", "upload_gl_state_restore").put("state", "passed"))
                    } else upload()
                    session.alphaUploads[token] = AlphaPacket(pair, left, right, System.nanoTime(), checks)
                } catch (error: Throwable) { fail(session, "CONTROLLED_ALPHA_UPLOAD_FAILED", error) }
            }
        })
        return true
    }

    private fun finishAlphaUploads(session: Session) {
        val iterator = session.alphaUploads.entries.iterator()
        while (iterator.hasNext()) {
            val (token, packet) = iterator.next()
            if (session.model?.acceptsPair(packet.pair) != true) { iterator.remove(); retire(session, token); continue }
            if (!RenderBridgeNative.alphaReady(session.renderer, token)) continue
            val dims = session.profile.split('x').map { it.toInt() }
            val pixels = dims[0]*dims[1]*2
            packet.pair.put("alpha_texture_id", RenderBridgeNative.alphaTexture(session.renderer, token))
                .put("alpha_gpu_uploaded", true).put("alpha_fence_ready", true).put("alpha_width", dims[0]*2)
                .put("alpha_height", dims[1]).put("alpha_texture_format", "GL_R8_numeric")
                .put("alpha_slot_token", token).put("alpha_frame_id", packet.pair.getLong("frame_id"))
                .put("alpha_pts_us", packet.pair.getLong("pts_us"))
                .put("alpha_fence_wait_ms", (System.nanoTime()-packet.uploadNs)/1e6)
                .put("alpha_upload_checks", packet.checks)
            if (session.display) {
                iterator.remove()
                offerPair(session, packet.pair)
                continue
            }
            val packed = ByteBuffer.allocateDirect(pixels)
            if (packet.pair.getInt("probe_ordinal") == 1) {
                rejectAlpha(packet.checks, "wrong_readback_capacity") { RenderBridgeNative.readAlpha(session.renderer, token, ByteBuffer.allocateDirect(pixels-1)) }
            }
            withAlphaPixelStoreStress { check(RenderBridgeNative.readAlpha(session.renderer, token, packed)) }
            packet.checks.put(JSONObject().put("case", "readback_gl_state_restore").put("state", "passed"))
            val bytes = ByteArray(pixels); packed.get(bytes)
            iterator.remove()
            // Keep the lease until evidence is validated and committed. EOS cannot run ahead.
            worker.post {
                try {
                    if (!active(session) || session.model?.acceptsPair(packet.pair) != true) return@post
                    var maximum = 0.0
                    for (y in 0 until dims[1]) for (eye in 0..1) for (x in 0 until dims[0]) {
                        val value = if (eye == 0) packet.left else packet.right
                        val expected = value.getFloat((y*dims[0]+x)*4).toDouble()
                        val observed = (bytes[y*dims[0]*2+eye*dims[0]+x].toInt() and 255)/255.0
                        maximum = maxOf(maximum, abs(expected-observed))
                    }
                    check(maximum <= 1.0/510.0+1e-7) { "Alpha GPU quantization/eye/row mismatch: $maximum" }
                    val host = context() ?: error("Activity unavailable")
                    val directory = File(host.filesDir, "diagnostics/${packet.pair.getString("evidence_directory")}")
                    val filename = "pair_${packet.pair.getInt("probe_ordinal")}_${packet.pair.getLong("frame_id")}_alpha_gpu.u8"
                    File(directory, filename).writeBytes(bytes)
                    packet.pair.put("alpha_gpu_evidence", JSONObject().put("file", filename).put("bytes", pixels)
                        .put("crc32", CRC32().apply { update(bytes) }.value).put("max_abs_quantization", maximum))
                    synchronized(session.lock) {
                        if (active(session) && session.model?.acceptsPair(packet.pair) == true) {
                            session.rvmPairs.put(packet.pair)
                            event("controlled_rvm_pair", session, packet.pair)
                        }
                    }
                } catch (error: Throwable) { fail(session, "CONTROLLED_ALPHA_VERIFY_FAILED", error) }
                finally { release(session.id, token) }
            }
        }
    }

    private fun rejectAlpha(checks: JSONArray, name: String, action: () -> Any?) {
        var rejected = false
        try { action() } catch (_: IllegalStateException) { rejected = true }
        check(rejected) { "Alpha boundary did not reject $name" }
        checks.put(JSONObject().put("case", name).put("state", "passed"))
    }

    private fun withAlphaPixelStoreStress(action: () -> Unit) {
        val names = intArrayOf(GLES30.GL_PIXEL_PACK_BUFFER_BINDING, GLES30.GL_PIXEL_UNPACK_BUFFER_BINDING,
            GLES30.GL_PACK_ALIGNMENT, GLES30.GL_PACK_ROW_LENGTH, GLES30.GL_PACK_SKIP_ROWS, GLES30.GL_PACK_SKIP_PIXELS,
            GLES30.GL_UNPACK_ALIGNMENT, GLES30.GL_UNPACK_ROW_LENGTH, GLES30.GL_UNPACK_SKIP_ROWS, GLES30.GL_UNPACK_SKIP_PIXELS,
            GLES30.GL_UNPACK_IMAGE_HEIGHT, GLES30.GL_UNPACK_SKIP_IMAGES)
        fun snapshot() = names.map { name -> IntArray(1).also { GLES30.glGetIntegerv(name, it, 0) }[0] }
        val saved = snapshot()
        val pbo = IntArray(1); GLES30.glGenBuffers(1, pbo, 0)
        try {
            GLES30.glBindBuffer(GLES30.GL_PIXEL_UNPACK_BUFFER, pbo[0]); GLES30.glBufferData(GLES30.GL_PIXEL_UNPACK_BUFFER, 64, null, GLES30.GL_STREAM_DRAW)
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, pbo[0])
            for ((index, value) in listOf(2 to 8, 3 to 19, 4 to 2, 5 to 3, 6 to 8, 7 to 19, 8 to 2, 9 to 3, 10 to 23, 11 to 1)) {
                GLES30.glPixelStorei(names[index], value)
            }
            val before = snapshot()
            action()
            check(snapshot() == before) { "Alpha bridge changed caller GL pixel/PBO state" }
        } finally {
            for (index in 2 until names.size) GLES30.glPixelStorei(names[index], saved[index])
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, saved[0]); GLES30.glBindBuffer(GLES30.GL_PIXEL_UNPACK_BUFFER, saved[1])
            GLES30.glDeleteBuffers(1, pbo, 0)
        }
    }


    @Synchronized fun open(uri: String, startMs: Int, stereo: Boolean, profile: String, probe: Boolean,
                           rvmProbe: Boolean = false, vulkan: Boolean = true, display: Boolean = false, replaceId: Int = 0): Int {
        if (profile !in RvmProfiles.keys || startMs < 0 || Uri.parse(uri).scheme !in setOf("content", "file")) return -1
        if (sessions.size >= 2) return -1
        val id = if (replaceId > 0) gate.replace(replaceId) else gate.begin()
        if (id <= 0) return id
        val session = Session(gate.current(id) ?: return -1, uri, startMs, stereo, profile, probe || (rvmProbe && !display), rvmProbe, vulkan, display)
        sessions[id] = session
        sessions.values.filter { it.id != id }.forEach(::dispose)
        worker.post { prepare(session) }
        return id
    }
    private fun active(session: Session) = gate.accepts(session.id) && !session.disposed.get()
    fun setPlaying(id: Int, playing: Boolean) { worker.post { sessions[id]?.let { if (active(it)) { it.requestedPlay = playing; updateClock(it); state(it) } } } }
    fun requestStatus(id: Int) { worker.post { sessions[id]?.let { if (active(it)) state(it) } } }
    fun close(id: Int) { gate.invalidate(id); sessions[id]?.let(::dispose) }
    fun cancelProbe(id: Int): Boolean {
        val session = sessions[id] ?: return false
        if (!session.probe) return false
        close(id)
        return true
    }
    fun pause() { foreground = false; worker.post { sessions.values.forEach { if (active(it)) updateClock(it) } } }
    fun resume() { foreground = true; worker.post { sessions.values.forEach { if (active(it)) updateClock(it) } } }
    fun contextCreated() {
        sessions.values.forEach {
            synchronized(it.lock) {
                if (it.renderer > 0) { RenderBridgeNative.abandon(it.renderer); it.renderer = 0 }
            }
            if (active(it)) fail(it, "CONTROLLED_GL_CONTEXT_RECREATED") else dispose(it)
        }
    }
    fun shutdown() {
        gate.shutdown(); sessions.values.forEach(::dispose)
        worker.post { thread.quitSafely() }
    }

    private fun prepare(session: Session) {
        if (!active(session)) return dispose(session)
        try {
            val host = context() ?: error("Activity unavailable")
            val extractor = MediaExtractor().also { session.extractor = it }
            extractor.setDataSource(host, Uri.parse(session.uri), null)
            var video = -1
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) session.audioPresent = true
                if (video < 0 && mime.startsWith("video/")) video = index
            }
            check(video >= 0) { "No video track" }
            val format = extractor.getTrackFormat(video)
            check(format.getString(MediaFormat.KEY_MIME) in setOf("video/avc", "video/hevc")) { "H264/HEVC required" }
            val rotation = integer(format, MediaFormat.KEY_ROTATION, 0)
            check(rotation in listOf(0, 90, 180, 270)) { "Invalid rotation" }
            session.format = describe(format, rotation)
            checkSdr(session.format!!)
            session.durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else -1
            // Keep raw packed-eye orientation; Godot applies the explicit source rotation once.
            format.setInteger(MediaFormat.KEY_ROTATION, 0)
            format.setInteger(MediaFormat.KEY_ALLOW_FRAME_DROP, 0)
            session.selectedFormat = format
            extractor.selectTrack(video)
            if (session.startMs > 0) extractor.seekTo(session.startMs * 1000L, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            render(Runnable { createSurface(session) })
        } catch (error: Exception) { fail(session, "CONTROLLED_PREPARE_FAILED", error) }
    }
    private fun describe(format: MediaFormat, rotation: Int, revision: Int = 1): Format {
        val w = format.getInteger(MediaFormat.KEY_WIDTH); val h = format.getInteger(MediaFormat.KEY_HEIGHT)
        val left = integer(format, "crop-left", 0); val top = integer(format, "crop-top", 0)
        val right = integer(format, "crop-right", w-1); val bottom = integer(format, "crop-bottom", h-1)
        check(w > 0 && h > 0 && left >= 0 && top >= 0 && right in left until w && bottom in top until h)
        return Format(right-left+1, bottom-top+1, rotation, listOf(left, top, right, bottom),
            integer(format, MediaFormat.KEY_COLOR_STANDARD, -1), integer(format, MediaFormat.KEY_COLOR_RANGE, -1),
            integer(format, MediaFormat.KEY_COLOR_TRANSFER, -1), revision,
            integer(format, MediaFormat.KEY_STRIDE, -1), integer(format, MediaFormat.KEY_SLICE_HEIGHT, -1))
    }
    private fun integer(format: MediaFormat, key: String, fallback: Int) = if (format.containsKey(key)) format.getInteger(key) else fallback
    private fun checkSdr(format: Format) {
        check(format.transfer !in setOf(MediaFormat.COLOR_TRANSFER_ST2084, MediaFormat.COLOR_TRANSFER_HLG)) { "HDR controlled Alpha path unsupported" }
    }
    private fun createSurface(session: Session) {
        if (!active(session)) return
        try {
            synchronized(session.lock) {
                if (!active(session)) return
                val format = session.format ?: error("Missing source format")
                val dims = session.profile.split('x').map { it.toInt() }
                session.owner = EGL14.eglGetCurrentContext()
                check(session.owner != EGL14.EGL_NO_CONTEXT)
                session.renderer = RenderBridgeNative.create(format.width, format.height, dims[0], dims[1], session.stereo)
                val source = preserveOes { SurfaceTexture(RenderBridgeNative.oesTexture(session.renderer)) }
                session.texture = source
                source.setDefaultBufferSize(format.width, format.height)
                source.setOnFrameAvailableListener({
                    if (active(session)) try { session.frames.notifyAvailable() }
                    catch (error: Exception) { fail(session, "CONTROLLED_SURFACE_NOTIFICATION_INVALID", error) }
                }, worker)
                session.surface = Surface(source)
            }
            if (session.rvmProbe) {
                val model = RvmVideoProbe(session.scope, session.profile, session.vulkan, context, rvmWorker,
                    { token -> release(session.id, token) },
                    { worker.post { if (active(session)) startCodec(session) } },
                    { pair, left, right -> enqueueAlpha(session, pair, left, right) },
                    { error -> fail(session, "CONTROLLED_VIDEO_RVM_FAILED", error) }, diagnostic = session.probe)
                synchronized(session.lock) {
                    if (active(session)) { session.model = model; model.start() } else model.close()
                }
            } else worker.post { startCodec(session) }
        } catch (error: Exception) { fail(session, "CONTROLLED_SURFACE_FAILED", error) }
        catch (error: LinkageError) { fail(session, "CONTROLLED_NATIVE_UNAVAILABLE", error) }
    }
    private fun startCodec(session: Session) {
        if (!active(session)) return
        try {
            val format = session.selectedFormat ?: error("Missing codec format")
            val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            session.codec = codec
            codec.configure(format, session.surface, null, 0)
            codec.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)
            codec.start(); session.decoder = codec.name
            event("controlled_state", session, JSONObject().put("state", "ready").put("decoder", session.decoder)
                .put("audio_present", session.audioPresent).put("audio_implemented", false).put("probe", session.probe))
            pump(session)
        } catch (error: Exception) { fail(session, "CONTROLLED_CODEC_FAILED", error) }
    }
    private fun position(session: Session, now: Long = System.nanoTime()): Long = session.anchorPtsUs +
        if (session.clockRunning) (now-session.anchorNs).coerceAtLeast(0)/1000 else 0
    private fun updateClock(session: Session) {
        val now = System.nanoTime(); val running = session.clockStarted && session.requestedPlay && foreground && !session.ended
        if (running != session.clockRunning) {
            session.anchorPtsUs = position(session, now); session.anchorNs = now; session.clockRunning = running
        }
    }
    private fun pump(session: Session) {
        if (!active(session) || session.ended) return
        try {
            val codec = session.codec ?: return
            val extractor = session.extractor ?: return
            updateClock(session)
            // Feed bounded codec buffers. Never construct a decoded-frame queue in Java.
            if (foreground && (session.requestedPlay || !session.clockStarted)) repeat(4) {
                if (!session.inputEos) {
                    val index = codec.dequeueInputBuffer(0)
                    if (index >= 0) {
                        val data = codec.getInputBuffer(index) ?: error("Input buffer unavailable")
                        data.clear(); val count = extractor.readSampleData(data, 0)
                        if (count < 0) {
                            codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); session.inputEos = true
                        } else {
                            check(extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_ENCRYPTED == 0) { "Encrypted media unsupported" }
                            codec.queueInputBuffer(index, 0, count, extractor.sampleTime, 0); extractor.advance()
                        }
                    }
                }
            }
            if (!session.outputEos && session.heldOutput == null && session.frames.idle()) {
                val info = MediaCodec.BufferInfo(); val index = codec.dequeueOutputBuffer(info, 0)
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val old = session.format!!
                    val next = describe(codec.outputFormat, old.rotation, old.revision + 1); checkSdr(next)
                    check(next.width == old.width && next.height == old.height) { "Dynamic source dimensions require a new renderer generation" }
                    session.model?.setFormat(next.revision)
                    session.format = next
                    codec.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)
                } else if (index >= 0) {
                    val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (config || info.size <= 0) { codec.releaseOutputBuffer(index, false); if (eos) session.outputEos = true }
                    else session.heldOutput = index to info
                }
            }
            val held = session.heldOutput
            if (held != null && session.frames.idle()) {
                val (index, info) = held
                val frame = session.nextFrame++
                val pts = info.presentationTimeUs
                val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                if (pts < session.startMs * 1000L || (session.clockStarted && pts < position(session)-100000)) {
                    codec.releaseOutputBuffer(index, false); session.heldOutput = null; session.dropped++
                    if (eos) session.outputEos = true
                } else if (foreground && (session.requestedPlay || !session.clockStarted) &&
                    (!session.clockStarted || pts <= position(session)+5000)) {
                    session.releasedFormat = session.format!!
                    val ticket = session.frames.begin(frame, pts, session.releasedFormat!!.revision, 1) ?: error("Surface release credit unavailable")
                    check(ticket.ptsUs >= 0)
                    if (!session.clockStarted) { session.anchorPtsUs = pts; session.anchorNs = System.nanoTime(); session.clockStarted = true; updateClock(session) }
                    // API>=29: boolean render propagates buffer PTS in ns. Verify after latch.
                    codec.releaseOutputBuffer(index, true); session.heldOutput = null
                    if (eos) session.outputEos = true
                } else session.nextFrame-- // Keep this held output's immutable frame identity until release/drop.
            }
            if (session.outputEos && session.frames.idle() && session.heldOutput == null &&
                (!session.rvmProbe || synchronized(session.lock) {
                    session.leases.keys.all { session.display && session.displayGate.owns(it) }
                })) {
                session.anchorPtsUs = position(session); session.anchorNs = System.nanoTime()
                session.ended = true; session.clockRunning = false
                state(session)
            } else worker.postDelayed({ pump(session) }, if (foreground) 4 else 40)
        } catch (error: Exception) { fail(session, "CONTROLLED_DECODE_FAILED", error) }
    }
    fun draw() {
        for (session in sessions.values) {
            if (session.disposed.get()) { cleanupClosing(session); continue }
            if (!active(session) || session.renderer == 0L) continue
            try {
                synchronized(session.lock) {
                    if (!active(session)) return@synchronized
                    check(session.owner == EGL14.eglGetCurrentContext()) { "GL context changed" }
                    pollRetirements(session)
                    if (session.displayGate.drawn(session.displayedToken)) session.displayDraws++
                    finishAlphaUploads(session)
                    val copying = session.copying
                    if (copying != null) {
                        if (!RenderBridgeNative.ready(session.renderer, copying.second)) return@synchronized
                        val textureId = RenderBridgeNative.texture(session.renderer, copying.second)
                        val dims = session.profile.split('x').map { it.toInt() }; val bytes = dims[0]*dims[1]*3*4
                        val buffers = session.buffers.getOrPut(textureId) {
                            ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN) to ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN)
                        }
                        check(RenderBridgeNative.readInputs(session.renderer, copying.second, buffers.first, buffers.second))
                        val copiedFormat = session.releasedFormat ?: error("Released output format missing")
                        check(copiedFormat.revision == copying.first.formatRevision)
                        val lease = Lease(copying.first, copiedFormat, copying.second, textureId, buffers.first, buffers.second,
                            session.copyingTransform ?: error("Captured transform missing"))
                        session.leases[copying.second] = lease
                        session.copying = null; session.latched = null
                        session.copyingTransform = null
                        session.releasedFormat = null
                        session.captured++
                        if (!session.display) event("controlled_frame", session, descriptor(session, lease).put("captured_frames", session.captured)
                            .put("left_rgb_crc32", crc(buffers.first)).put("right_rgb_crc32", crc(buffers.second))
                            .put("rgb_probes", if (session.probe) rgbProbes(buffers.first, buffers.second, dims[0], dims[1]) else JSONArray()))
                        if (session.rvmProbe) session.model!!.submit(lease.ticket, lease.token, lease.left, lease.right,
                            descriptor(session, lease))
                        else if (session.probe) retire(session, copying.second)
                        // Return decoder credit after the probe finishes reading/retiring.
                        // Otherwise the worker can publish EOS with an unfinished last lease.
                        check(session.frames.complete(copying.first))
                    }
                    val ticket = session.frames.available() ?: return@synchronized
                    val source = session.texture ?: return@synchronized
                    if (session.latched == null) {
                        preserveOes { source.updateTexImage() }
                        check(session.frames.verify(ticket, source.timestamp))
                        session.latched = ticket
                    }
                    val matrix = FloatArray(16); source.getTransformMatrix(matrix)
                    val token = RenderBridgeNative.capture(session.renderer, matrix)
                    if (token > 0) {
                        session.copying = ticket to token // Full pool holds OES and decoder credit, never overwrites.
                        session.copyingTransform = matrix
                    }
                }
            } catch (error: Exception) { fail(session, "CONTROLLED_COPY_FAILED", error) }
            catch (error: LinkageError) { fail(session, "CONTROLLED_NATIVE_UNAVAILABLE", error) }
        }
    }
    private fun crc(buffer: ByteBuffer): Long {
        val crc = CRC32(); crc.update(buffer.duplicate().apply { clear() }); return crc.value
    }
    private fun rgbProbes(left: ByteBuffer, right: ByteBuffer, width: Int, height: Int): JSONArray {
        val result = JSONArray()
        for ((eye, buffer) in listOf(left, right).withIndex()) {
            for (y in listOf(0.125, 0.25, 0.5, 0.75, 0.875)) for (x in listOf(0.0, 0.125, 0.25, 0.5, 0.75, 0.875, 0.999999)) {
                val px = (x*width).toInt(); val py = (y*height).toInt()
                val rgb = (0..2).map { buffer.getFloat((it*width*height+py*width+px)*4).toDouble() }
                result.put(JSONObject().put("eye", eye).put("pixel", JSONArray(listOf(px, py))).put("rgb", JSONArray(rgb)))
            }
        }
        return result
    }
    private fun descriptor(session: Session, lease: Lease): JSONObject {
        val format = lease.format; val dims = session.profile.split('x').map { it.toInt() }
        val sourceAspect = format.width.toDouble() / (if (session.stereo) 2 else 1) / format.height
        val inputAspect = dims[0].toDouble()/dims[1]
        val rect = if (sourceAspect > inputAspect) { val h = inputAspect/sourceAspect; listOf(0.0,(1-h)*0.5,1.0,h) }
                   else { val w = sourceAspect/inputAspect; listOf((1-w)*0.5,0.0,w,1.0) }
        return JSONObject().put("frame_id", lease.ticket.frameId).put("pts_us", lease.ticket.ptsUs)
            .put("format_revision", lease.ticket.formatRevision).put("effect_revision", lease.ticket.effectRevision)
            .put("slot_token", lease.token).put("color_texture_id", lease.texture).put("color_target", "GL_TEXTURE_2D")
            .put("width", format.width).put("height", format.height).put("source_crop", JSONArray(format.crop))
            .put("rotation_degrees", format.rotation).put("color_standard", format.standard).put("color_range", format.range)
            .put("color_transfer", format.transfer).put("source_pts_verified", true).put("immutable_color_frame", true)
            .put("decoder_stride", format.stride).put("decoder_slice_height", format.sliceHeight)
            .put("surface_texture_transform", JSONArray(lease.transform.map { it.toDouble() }))
            .put("coords", "top-left; SurfaceTexture transform already applied; rotation deferred")
            .put("profile_key", session.profile).put("model_content_rect", JSONArray(rect)).put("stereo_sbs", session.stereo)
            .put("input_layout", "float32_CHW_RGB_0_1").put("input_width", dims[0]).put("input_height", dims[1])
            .put("inference_ran", false).put("audio_implemented", false).put("probe", session.probe)
    }
    private fun pairIdentity(pair: JSONObject) = FramePairGate.Identity(pair.getInt("session_id"), pair.getInt("logical_session_id"),
        pair.getInt("generation"), pair.getLong("frame_id"), pair.getLong("pts_us"), pair.getInt("format_revision"),
        pair.getLong("effect_revision"), pair.getLong("model_generation"), pair.getLong("slot_token"))

    private fun offerPair(session: Session, pair: JSONObject) {
        val token = pair.getLong("slot_token")
        val obsolete = session.displayGate.offer(pairIdentity(pair))
        if (obsolete == token) { retire(session, token); return }
        if (obsolete != null) retire(session, obsolete)
        session.displayPairs[token] = pair
        session.latestFrame = pair.toString()
        emit("controlled_pair_available", session.id, pair.toString())
    }
    /** Called by Godot at a process boundary. These methods never call GL. */
    fun claimPair(id: Int, token: Long): String {
        val session = sessions[id] ?: return ""
        synchronized(session.lock) {
            val pair = session.displayPairs[token] ?: return ""
            if (!active(session) || session.model?.acceptsPair(pair) != true || session.displayGate.claim(token) == null) return ""
            return pair.toString()
        }
    }
    fun acknowledgePair(id: Int, token: Long): Boolean {
        val session = sessions[id] ?: return false
        synchronized(session.lock) {
            val pair = session.displayPairs[token] ?: return false
            if (!active(session) || session.model?.presented(pair) != true || !session.displayGate.acknowledge(token)) return false
            session.displayedToken = token
            pair.put("pair_presented", true)
            session.lastDisplayed = pair.toString()
            return true
        }
    }
    fun detachPair(id: Int, token: Long): Boolean {
        val session = sessions[id] ?: return false
        synchronized(session.lock) {
            if (!session.displayGate.detach(token)) return false
            if (session.displayedToken == token) session.displayedToken = 0
        }
        // onGLDrawFrame follows GodotLib.step, including the last engine draw.
        render(Runnable {
            synchronized(session.lock) {
                if (session.renderer > 0 && session.owner == EGL14.eglGetCurrentContext()) retire(session, token)
            }
        })
        return true
    }
    private fun pollRetirements(session: Session) {
        val iterator = session.retirements.iterator()
        while (iterator.hasNext()) if (RenderBridgeNative.retired(session.renderer, iterator.next())) iterator.remove()
    }
    private fun displaySnapshot(session: Session): JSONObject = JSONObject()
        .put("claims", session.displayGate.heldClaims()).put("ready_token", session.displayGate.readyToken() ?: 0)
        .put("claim_count", session.displayGate.claimCount).put("ack_count", session.displayGate.ackCount)
        .put("detach_count", session.displayGate.detachCount).put("replaced_ready_count", session.displayGate.replacedCount)
        .put("post_draw_frames", session.displayDraws).put("pending_release_fences", session.retirements.size)
        .put("last_presented", JSONObject(session.lastDisplayed))

    private fun cleanupClosing(session: Session) {
        if (!session.workerReleased) return
        synchronized(session.lock) {
            if (!sessions.containsKey(session.id)) return
            if (session.renderer > 0) {
                if (session.owner != EGL14.eglGetCurrentContext()) {
                    RenderBridgeNative.abandon(session.renderer); session.renderer = 0; session.retirements.clear()
                } else {
                    session.leases.keys.toList().filter { !session.displayGate.owns(it) }.forEach { retire(session, it) }
                    session.copying?.let {
                        RenderBridgeNative.retire(session.renderer, it.second); session.retirements.add(it.second)
                        session.copying = null
                    }
                    pollRetirements(session)
                }
            }
            // Godot wrappers must be detached even when the old EGL context died.
            if (session.displayGate.heldClaims() > 0 || session.retirements.isNotEmpty()) return
            if (session.renderer > 0) RenderBridgeNative.close(session.renderer)
            session.renderer = 0; session.leases.clear(); session.buffers.clear(); session.displayPairs.clear()
            sessions.remove(session.id)
            val report = JSONObject().put("session_id", session.id).put("logical_session_id", session.scope.logicalSessionId)
                .put("generation", session.scope.generation).put("diagnostic_process", DiagnosticRequests.processId)
                .put("renderer_closed", true).put("held_slots", 0).put("display", displaySnapshot(session)).toString()
            emit("controlled_released", session.id, report)
            worker.post {
                try { File(context()?.filesDir ?: return@post, "diagnostics/controlled_release_${session.id}.json").writeText(report) }
                catch (error: Exception) { Log.w("VRPassthroughPlayer", "Display release evidence", error) }
            }
        }
    }
    fun release(id: Int, token: Long): Boolean {
        val session = sessions[id] ?: return false
        synchronized(session.lock) {
            if (!active(session) || !session.leases.containsKey(token) || session.displayGate.owns(token)) return false
        }
        render(Runnable {
            synchronized(session.lock) {
                if (active(session)) try { retire(session, token) }
                catch (error: Exception) { fail(session, "CONTROLLED_RETIRE_FAILED", error) }
            }
        })
        return true
    }
    private fun retire(session: Session, token: Long) {
        if (session.leases.remove(token) != null) {
            check(!session.displayGate.owns(token)) { "Cannot retire a Godot display claim" }
            session.displayPairs.remove(token)
            RenderBridgeNative.retire(session.renderer, token)
            session.retirements.add(token)
        }
    }
    private fun state(session: Session) {
        event("controlled_state", session, JSONObject().put("state", if (session.ended) "ended" else "ready")
            .put("position_ms", position(session)/1000).put("duration_ms", session.durationUs/1000)
            .put("playing", session.clockRunning).put("captured_frames", session.captured).put("dropped_frames", session.dropped)
            .put("held_slots", session.leases.size).put("slot_capacity", 3).put("clock", "video-only monotonic development clock")
            .put("rvm_probe", session.rvmProbe).put("rvm_probe_pairs", synchronized(session.lock) { session.rvmPairs.length() })
            .put("rvm_player", session.display).put("display", synchronized(session.lock) { displaySnapshot(session) })
            .put("audio_present", session.audioPresent).put("audio_implemented", false).put("probe", session.probe))
    }
    private fun event(name: String, session: Session, data: JSONObject) {
        if (!active(session)) return
        val encoded = data.put("session_id", session.id).put("logical_session_id", session.scope.logicalSessionId)
            .put("generation", session.scope.generation).put("backend", "MediaExtractor_MediaCodec_R02").toString()
        synchronized(session.lock) {
            if (name == "controlled_frame") session.latestFrame = encoded
            else if (name != "controlled_rvm_pair") session.latestState = encoded
            save(session)
        }
        emit(name, session.id, encoded)
    }
    private fun save(session: Session) {
        if (!session.saveQueued.compareAndSet(false, true)) return
        worker.post {
            // Take a coherent snapshot and return save credit before IO. An event
            // arriving during the write must enqueue another save, especially EOS.
            val snapshot = synchronized(session.lock) {
                session.saveQueued.set(false)
                Triple(session.latestFrame, session.latestState, session.rvmPairs.toString())
            }
            try {
                val host = context() ?: return@post
                val directory = File(host.filesDir, "diagnostics").apply { mkdirs() }
                val target = File(directory, "controlled_session_${session.id}.json")
                val temporary = File.createTempFile("controlled-", ".tmp", directory)
                try {
                    temporary.writeText(JSONObject().put("schema_version", 1).put("session_id", session.id)
                        .put("diagnostic_process", DiagnosticRequests.processId)
                        .put("frame", JSONObject(snapshot.first)).put("state", JSONObject(snapshot.second))
                        .put("rvm_probe", session.rvmProbe).put("rvm_pairs", JSONArray(snapshot.third)).toString())
                    check(temporary.renameTo(target))
                } finally { temporary.delete() }
            } catch (error: Exception) { Log.w("VRPassthroughPlayer", "Controlled report storage failed", error) }
        }
    }
    private fun fail(session: Session, code: String, error: Throwable? = null) {
        if (error != null) Log.e("VRPassthroughPlayer", "$code session=${session.id}", error)
        event("controlled_error", session, JSONObject().put("code", code).put("detail", error?.message ?: ""))
        gate.invalidate(session.id); dispose(session)
    }
    private fun dispose(session: Session) {
        if (!session.disposed.compareAndSet(false, true)) return
        session.frames.close()
        session.model?.close()
        synchronized(session.lock) {
            session.displayGate.close()
            if (session.display) emit("controlled_detach", session.id,
                JSONObject().put("session_id", session.id).put("generation", session.scope.generation).toString())
        }
        worker.post {
            try { session.codec?.release() } catch (error: Exception) { Log.w("VRPassthroughPlayer", "Controlled codec release", error) }
            session.codec = null
            try { session.extractor?.release() } catch (error: Exception) { Log.w("VRPassthroughPlayer", "Controlled extractor release", error) }
            session.extractor = null
            synchronized(session.lock) {
                session.texture?.setOnFrameAvailableListener(null); session.surface?.release(); session.texture?.release()
                session.surface = null; session.texture = null; session.alphaUploads.clear()
                session.workerReleased = true
            }
            render(Runnable {
                synchronized(session.lock) {
                    cleanupClosing(session)
                }
            })
        }
    }
    private inline fun <T> preserveOes(action: () -> T): T {
        val active = IntArray(1); val binding = IntArray(1)
        GLES30.glGetIntegerv(GLES30.GL_ACTIVE_TEXTURE, active, 0); GLES30.glGetIntegerv(GLES11Ext.GL_TEXTURE_BINDING_EXTERNAL_OES, binding, 0)
        return try { action() } finally { GLES30.glActiveTexture(active[0]); GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, binding[0]) }
    }
}
