package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.SurfaceTexture
import android.net.Uri
import android.opengl.EGL14
import android.opengl.EGLContext
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.os.Handler
import android.os.Looper
import android.view.Surface
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** C03 direct OES display. It does not preserve decoded frames for RVM. */
@UnstableApi
internal class LocalVideoBridge(
    private val context: () -> Context?,
    private val render: (Runnable) -> Unit,
    private val emit: (String, Int, String) -> Unit,
) {
    private val ui = Handler(Looper.getMainLooper())
    private val gate = MediaSessionGate()
    private val sessions = ConcurrentHashMap<Int, Session>()
    private var foreground = true // UI thread only

    private class Session(val scope: MediaSessionGate.Scope, val textureId: Int, val uri: String, val startMs: Int) {
        val id = scope.decoderId
        val disposing = AtomicBoolean(false)
        val pendingFrames = AtomicInteger(0)
        val resourceLock = Any()
        var texture: SurfaceTexture? = null // render thread only
        var surface: Surface? = null // created on render, released after UI player release
        var ownerContext: EGLContext? = null
        var frameCounter = 0L
        var coalescedNotifications = 0L
        var player: ExoPlayer? = null // UI thread only
        var requestedPlay = true
    }

    fun open(textureId: Int, uri: String, startMs: Int): Int {
        val id = gate.begin()
        if (id < 0) return id
        return createSession(id, textureId, uri, startMs)
    }

    /** C05 validation seek: replace the decoder and Surface, never relabel an old OES frame. */
    fun restart(id: Int, textureId: Int, startMs: Int): Int {
        val previous = sessions[id] ?: return -1
        if (textureId <= 0 || startMs < 0 || !active(previous)) return -1
        val replacement = gate.replace(id)
        if (replacement < 0) return replacement
        return createSession(replacement, textureId, previous.uri, startMs)
    }

    private fun createSession(id: Int, textureId: Int, uri: String, startMs: Int): Int {
        val scope = gate.current(id) ?: return -1
        val session = Session(scope, textureId, uri, startMs)
        sessions[id] = session
        ui.post {
            sessions.values.filter { it.id != id && !gate.accepts(it.id) }.forEach(::dispose)
            if (!active(session)) { dispose(session); return@post }
            val source = Uri.parse(uri)
            if (textureId <= 0 || startMs < 0) { fail(session, "INVALID_MEDIA_ARGUMENT"); return@post }
            if (source.scheme !in setOf("content", "file")) { fail(session, "LOCAL_URI_REQUIRED"); return@post }
            if (source.scheme == "file" && !File(source.path ?: "").canRead()) {
                fail(session, "FILE_UNREADABLE"); return@post
            }
            render(Runnable { createSurface(session) })
        }
        return id
    }

    fun setPlaying(id: Int, playing: Boolean) {
        ui.post {
            val session = sessions[id] ?: return@post
            if (!active(session)) return@post
            session.requestedPlay = playing
            session.player?.playWhenReady = foreground && playing
            state(session)
        }
    }

    fun requestStatus(id: Int) {
        ui.post { sessions[id]?.let { if (active(it)) state(it) } }
    }

    fun close(id: Int) {
        // Invalidation is immediate, even if the UI queue or codec is still busy.
        gate.invalidate(id)
        sessions[id]?.let(::dispose)
    }

    fun pause() {
        ui.post {
            foreground = false
            sessions.values.forEach { if (active(it)) { it.player?.playWhenReady = false; state(it) } }
        }
    }

    fun resume() {
        ui.post {
            foreground = true
            sessions.values.forEach { if (active(it)) { it.player?.playWhenReady = it.requestedPlay; state(it) } }
        }
    }

    /** Called by Godot after context recreation. Old Godot IDs cannot be reused. */
    fun contextCreated() {
        sessions.values.forEach { session ->
            if (active(session)) fail(session, "GL_CONTEXT_RECREATED") else dispose(session)
        }
    }

    fun shutdown() {
        gate.shutdown()
        sessions.values.forEach(::dispose)
    }

    private fun active(session: Session) = gate.accepts(session.id) && !session.disposing.get()

    private fun createSurface(session: Session) {
        if (!active(session)) { dispose(session); return }
        val current = EGL14.eglGetCurrentContext()
        if (current == EGL14.EGL_NO_CONTEXT) { fail(session, "GL_CONTEXT_UNAVAILABLE"); return }
        val extensionCount = IntArray(1)
        GLES30.glGetIntegerv(GLES30.GL_NUM_EXTENSIONS, extensionCount, 0)
        if ((0 until extensionCount[0]).none {
            GLES30.glGetStringi(GLES30.GL_EXTENSIONS, it) == "GL_OES_EGL_image_external_essl3"
        }) { fail(session, "EXTERNAL_OES_UNAVAILABLE"); return }
        try {
            session.ownerContext = current
            // Godot owns and deletes the texture ID. Do not detach/delete it here.
            synchronized(session.resourceLock) {
                if (!active(session)) return
                val texture = preserveOesBinding { SurfaceTexture(session.textureId) }
                session.texture = texture
                texture.setOnFrameAvailableListener({
                    if (active(session)) session.pendingFrames.incrementAndGet()
                }, ui)
                session.surface = Surface(texture)
            }
            ui.post {
                if (!active(session)) { dispose(session); return@post }
                createPlayer(session)
            }
        } catch (_: Exception) { fail(session, "SURFACE_CREATE_FAILED") }
    }

    private fun createPlayer(session: Session) {
        val host = context() ?: return fail(session, "ACTIVITY_UNAVAILABLE")
        try {
            val player = ExoPlayer.Builder(host).setLooper(Looper.getMainLooper()).build()
            session.player = player
            player.addListener(object : Player.Listener {
                override fun onEvents(player: Player, events: Player.Events) {
                    if (active(session)) state(session)
                }
                override fun onVideoSizeChanged(videoSize: VideoSize) {
                    event("media_format", session, JSONObject()
                        .put("width", videoSize.width).put("height", videoSize.height)
                        .put("pixel_aspect", videoSize.pixelWidthHeightRatio)
                        .put("unapplied_rotation_degrees", videoSize.unappliedRotationDegrees))
                }
                override fun onPlayerError(error: PlaybackException) {
                    fail(session, error.errorCodeName)
                }
            })
            player.addAnalyticsListener(object : AnalyticsListener {
                override fun onVideoDecoderInitialized(eventTime: AnalyticsListener.EventTime,
                    decoderName: String, initializedTimestampMs: Long, initializationDurationMs: Long) {
                    event("media_codec", session, JSONObject().put("decoder", decoderName)
                        .put("initialization_ms", initializationDurationMs))
                }
                override fun onDroppedVideoFrames(eventTime: AnalyticsListener.EventTime,
                    droppedFrames: Int, elapsedMs: Long) {
                    event("media_codec", session, JSONObject().put("dropped_frames", droppedFrames)
                        .put("elapsed_ms", elapsedMs))
                }
            })
            player.setVideoSurface(session.surface)
            player.setMediaItem(MediaItem.fromUri(session.uri), session.startMs.toLong())
            player.prepare()
            player.playWhenReady = foreground && session.requestedPlay
            state(session)
        } catch (_: Exception) { fail(session, "PLAYER_PREPARE_FAILED") }
    }

    /** Godot GL callback is after drawing; its signal is applied before the next draw. */
    fun draw() {
        for (session in sessions.values) {
            if (!active(session)) continue
            val pending = session.pendingFrames.getAndSet(0)
            if (pending == 0) continue
            if (session.ownerContext != EGL14.eglGetCurrentContext()) {
                fail(session, "GL_CONTEXT_CHANGED"); continue
            }
            try {
                synchronized(session.resourceLock) {
                    if (!active(session)) return@synchronized
                    val texture = session.texture ?: return@synchronized
                    preserveOesBinding { texture.updateTexImage() }
                    val matrix = FloatArray(16)
                    texture.getTransformMatrix(matrix)
                    session.frameCounter += 1
                    session.coalescedNotifications += (pending - 1).coerceAtLeast(0)
                    event("media_frame", session, JSONObject().put("frame_counter", session.frameCounter)
                        .put("surface_timestamp_ns", texture.timestamp)
                        .put("transform", JSONArray(matrix.toList()))
                        .put("coalesced_notifications", session.coalescedNotifications)
                        .put("timestamp_contract", "SurfaceTexture timestamp; not a guaranteed source PTS"))
                }
            } catch (_: Exception) { fail(session, "SURFACE_UPDATE_FAILED") }
        }
    }

    private fun state(session: Session) {
        val player = session.player ?: return
        val duration = player.duration
        event("media_state", session, JSONObject()
            .put("state", when (player.playbackState) {
                Player.STATE_BUFFERING -> "buffering"
                Player.STATE_READY -> "ready"
                Player.STATE_ENDED -> "ended"
                else -> "idle"
            }).put("playing", player.isPlaying).put("requested_play", session.requestedPlay)
            .put("foreground", foreground).put("position_ms", player.currentPosition)
            .put("duration_ms", if (duration == C.TIME_UNSET) -1 else duration)
            .put("start_position_ms", session.startMs)
            .put("clock", "Media3 playback position; controlled AudioTrack clock not implemented")
            .put("backend", "Media3_C03_direct_OES"))
    }

    private fun event(name: String, session: Session, fields: JSONObject) {
        if (active(session)) emit(name, session.id, fields.put("session_id", session.id)
            .put("logical_session_id", session.scope.logicalSessionId)
            .put("generation", session.scope.generation)
            .put("source_pts_verified", false).put("immutable_color_frame", false).toString())
    }

    private fun fail(session: Session, code: String) {
        event("media_error", session, JSONObject().put("code", code))
        gate.invalidate(session.id)
        dispose(session)
    }

    private fun dispose(session: Session) {
        if (!session.disposing.compareAndSet(false, true)) return
        // Stop producer first, then release consumer. Never block the Godot GL thread on codec release.
        ui.post {
            try { session.player?.release() } catch (error: Exception) {
                Log.w("VRPassthroughPlayer", "Player release failed", error)
            } finally {
                session.player = null
                // release() frees the buffer queue without GL calls. This also works
                // when the renderer is already terminating and cannot run queued work.
                synchronized(session.resourceLock) {
                    try {
                        try { session.surface?.release() } catch (error: Exception) {
                            Log.w("VRPassthroughPlayer", "Surface release failed", error)
                        }
                        try {
                            session.texture?.setOnFrameAvailableListener(null)
                            session.texture?.release()
                        } catch (error: Exception) {
                            Log.w("VRPassthroughPlayer", "SurfaceTexture release failed", error)
                        }
                    } finally {
                        session.surface = null
                        session.texture = null
                        sessions.remove(session.id)
                        emit("media_released", session.id, "{}")
                    }
                }
            }
        }
    }

    private inline fun <T> preserveOesBinding(operation: () -> T): T {
        val activeTexture = IntArray(1)
        val binding = IntArray(1)
        GLES30.glGetIntegerv(GLES30.GL_ACTIVE_TEXTURE, activeTexture, 0)
        GLES30.glGetIntegerv(GLES11Ext.GL_TEXTURE_BINDING_EXTERNAL_OES, binding, 0)
        return try { operation() } finally {
            GLES30.glActiveTexture(activeTexture[0])
            GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, binding[0])
        }
    }
}
