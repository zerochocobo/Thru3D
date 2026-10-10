package org.vrpassthroughplayer.plugin

import android.content.Context
import java.nio.ByteBuffer

/** Source-frame build only. GL methods run in an actual Godot draw callback.
 * The native worker shares its context and owns all MPV render calls; control
 * methods enqueue work for a separate ordinary-client thread.
 */
internal object MpvSourceNative {
    private val loaded = try { System.loadLibrary("quest_mpv"); true } catch (_: UnsatisfiedLinkError) { false }
    fun supported() = loaded && available()
    @JvmStatic private external fun available(): Boolean
    /** Starts paused; the caller must apply focus policy before setPlaying(true). */
    /** maxWidth > 0 scales the decoded color down to that width (aspect kept); 0 keeps the source size.
     * audioFiles: location/title pairs added as unselected audio tracks once the video loads. */
    @JvmStatic external fun create(context: Context, localPath: String, startMs: Int, hardware: Boolean, audio: Boolean,
                                   maxWidth: Int = 0, audioFiles: Array<String> = emptyArray(),
                                   subtitleFiles: Array<String> = emptyArray(), exactStart: Boolean = true): Long
    /** Empty string when no completed image is available. Never waits for the GPU. */
    @JvmStatic external fun acquire(handle: Long): String
    /** Insert consumer-context fence after its last copy/draw; rejects double release. */
    @JvmStatic external fun release(handle: Long, producerToken: Long): Boolean
    @JvmStatic external fun setPlaying(handle: Long, playing: Boolean)
    /** Positive playback rate; media timestamps and subtitle timing remain in source time. */
    @JvmStatic external fun setSpeed(handle: Long, speed: Double): Boolean
    /** Coalesced control request. -1 auto, 0 disabled, or an actual track-list id; volume 0..100. */
    @JvmStatic external fun setAudio(handle: Long, trackId: Int, volume: Double, muted: Boolean): Boolean
    /** 0 rejected; positive coalesced command serial. -1 auto, 0 off, actual subtitle id. */
    @JvmStatic external fun setSubtitle(handle: Long, trackId: Int): Long
    /** Plain text in a separate UI layer; empty when no newer snapshot is available. */
    @JvmStatic external fun subtitleStatus(handle: Long, afterSequence: Long): String
    /** Cropped premultiplied RGBA for this exact bitmap version, empty if superseded. */
    @JvmStatic external fun subtitleBitmap(handle: Long, version: Long): ByteArray
    @JvmStatic external fun seek(handle: Long, positionMs: Long, exact: Boolean = true): Boolean
    /** Present at most fps source frames per second (0 = all), chosen by scheduled display time before rendering. */
    @JvmStatic external fun setFrameCap(handle: Long, fps: Int)
    /** Direct mode: publish MediaCodec images; Profile 5 always retains converted SDR RGBA. */
    @JvmStatic external fun setDirect(handle: Long, enabled: Boolean)
    /** Re-render a retained paused frame; its original frame ID/PTS/epoch remain unchanged. */
    @JvmStatic external fun requestFrame(handle: Long)
    /** Debug calibration only: 24 sparse RGBA samples, no full source readback. */
    @JvmStatic external fun readFrameCode(handle: Long, producerToken: Long, output: ByteBuffer)
    /** position_seconds is a playback clock observation, never a source-frame PTS. */
    @JvmStatic external fun status(handle: Long): String
    /** Begin teardown but retain status/handle until close, so cleanup can be checked. */
    @JvmStatic external fun requestClose(handle: Long)
    /** Asynchronous. Repeat until true. abandon is only for a dead owner context. */
    @JvmStatic external fun close(handle: Long, abandon: Boolean): Boolean
}
