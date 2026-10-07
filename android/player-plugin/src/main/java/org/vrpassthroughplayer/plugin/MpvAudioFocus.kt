package org.vrpassthroughplayer.plugin

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper

/** API 29+ focus owner shared by this player's active MPV source. No background
 * service: production releases focus when its Godot activity pauses. */
internal class MpvAudioFocus(context: Context, private val changed: (MpvAudioFocusGate.Change) -> Unit) {
    private val manager = context.applicationContext.getSystemService(AudioManager::class.java)
    private val gate = MpvAudioFocusGate()
    private var request: AudioFocusRequest? = null
    @Synchronized fun state(): String = gate.state.name.lowercase()
    @Synchronized fun acquire(explicit: Boolean = false): Boolean {
        val token = gate.begin(explicit) ?: return gate.canPlay
        request?.let { manager.abandonAudioFocusRequest(it) }
        val candidate = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
            .setAcceptsDelayedFocusGain(false).setWillPauseWhenDucked(true)
            .setOnAudioFocusChangeListener({ change ->
                val event = when (change) {
                    AudioManager.AUDIOFOCUS_GAIN -> MpvAudioFocusGate.Change.GAIN
                    AudioManager.AUDIOFOCUS_LOSS -> MpvAudioFocusGate.Change.LOSS
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> MpvAudioFocusGate.Change.TRANSIENT_LOSS
                    else -> null
                }
                if (event != null && synchronized(this) { gate.changed(token, event) }) changed(event)
            }, Handler(Looper.getMainLooper())).build()
        request = candidate
        gate.resolved(token, manager.requestAudioFocus(candidate) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
        if (!gate.canPlay) { request = null; manager.abandonAudioFocusRequest(candidate) }
        return gate.canPlay
    }
    @Synchronized fun release() {
        gate.clear()
        val old = request; request = null
        old?.let { manager.abandonAudioFocusRequest(it) }
    }
}
