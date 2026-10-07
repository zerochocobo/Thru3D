package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger

/** Real production MPV source/control APIs and Android AO, with muted synthesized
 * audio. No speaker recording, RVM or Godot/XR AV synchronization assertion. */
internal object MpvAudioDiagnostics {
    private val ids = AtomicInteger()
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(1),
        { task -> Thread(task, "QuestMpvAudioProbe") }, ThreadPoolExecutor.AbortPolicy())
    fun request(context: Context, hardware: Boolean = true): Int {
        val id = ids.incrementAndGet()
        return try { worker.execute { run(context.applicationContext, id, hardware) }; id } catch (_: Exception) { -1 }
    }
    private fun run(context: Context, id: Int, hardware: Boolean) {
        val report = JSONObject().put("schema_version", 1).put("request_id", id)
            .put("diagnostic_process", DiagnosticRequests.processId).put("fixture", "mp06_audio_clock")
            .put("hardware_requested", hardware).put("audio_owner", "production_libmpv")
            .put("consumer_context_origin", "debug_offscreen_GLES_pbuffer")
            .put("godot_display_verified", false).put("xr_verified", false).put("rvm_verified", false)
            .put("audible_output_verified", false).put("av_sync_verified", false).put("performance_verified", false)
        val owner = MpvSharedDiagnostics.Owner(); var source = 0L
        var focus: MpvAudioFocus? = null
        val focusChanges = ConcurrentLinkedQueue<String>()
        val eofTimeline = JSONArray()
        val records = JSONArray(); var phase = "initialize"
        fun status(): JSONObject {
            if (phase != "initialize" && phase != "cleanup") check(focus?.state() == "held") { "Audio focus unavailable: ${focus?.state()}" }
            val value = JSONObject(MpvSourceNative.status(source))
            check(value.getString("state") != "failed" && !value.getBoolean("render_failed")) { value.toString() }
            return value
        }
        fun waitFor(predicate: (JSONObject) -> Boolean): JSONObject {
            val deadline = System.nanoTime()+15_000_000_000L
            var lastSequence = -1L
            while (true) {
                val value = status()
                // Bounded EOF timeline distinguishes a stopped clock from an
                // unobserved terminal source; these are observations, not passes.
                if (phase == "wait_audio_and_video_eof") {
                    val sequence = value.getJSONObject("details").getLong("snapshot_sequence")
                    if (sequence != lastSequence) {
                        eofTimeline.put(value)
                        lastSequence = sequence
                    }
                }
                if (predicate(value)) return value
                check(System.nanoTime() < deadline) { "Audio probe timeout in $phase" }
                Thread.sleep(10)
            }
        }
        fun record(label: String, value: JSONObject = status()) { records.put(JSONObject().put("phase", label).put("native", value)) }
        fun sample(label: String, milliseconds: Long) {
            val deadline = System.nanoTime()+milliseconds*1_000_000
            var last = -1L
            while (System.nanoTime() < deadline) {
                val value = status(); val sequence = value.getJSONObject("details").getLong("snapshot_sequence")
                if (sequence != last) { record(label, value); last = sequence }
                Thread.sleep(20)
            }
        }
        fun codedFrame(label: String): JSONObject {
            var pair: JSONObject? = null
            waitFor {
                val raw = MpvSourceNative.acquire(source)
                if (raw.isNotEmpty()) pair = JSONObject(raw)
                pair != null
            }
            val selected = pair!!; val token = selected.getLong("producer_token")
            try {
                val bytes = ByteBuffer.allocateDirect(96)
                MpvSourceNative.readFrameCode(source, token, bytes)
                selected.put("phase", label).put("source_code", JSONArray((0 until 24).map { pixel ->
                    JSONArray((0..3).map { bytes.get(pixel*4+it).toInt() and 255 }) }))
                return selected
            } finally { check(MpvSourceNative.release(source, token)) }
        }
        try {
            check(MpvSourceNative.supported())
            val target = File(context.filesDir, "fixtures/mp06_audio_clock.mp4").apply { parentFile!!.mkdirs() }
            context.assets.open("media/mp06_audio_clock.mp4").use { src -> target.outputStream().use { src.copyTo(it) } }
            focus = MpvAudioFocus(context) { change -> focusChanges.add(change.name.lowercase()) }
            check(focus!!.acquire(true)) { "Android audio focus request denied" }
            report.put("audio_focus_initial", focus!!.state())
            owner.start()
            source = MpvSourceNative.create(context, target.absolutePath, 0, hardware, true)
            MpvSourceNative.setPlaying(source, false)
            check(MpvSourceNative.setAudio(source, -1, 25.0, true))
            phase = "initial_paused_audio"
            waitFor { val d = it.getJSONObject("details"); d.optString("paused") == "yes" &&
                d.optString("audio_track_id") == "1" && d.optString("mute") == "yes" &&
                d.optString("audio_output").isNotEmpty() }
            record("initial_paused")
            report.put("first_frame", codedFrame("first_paused"))
            phase = "invalid_audio_controls"
            check(!MpvSourceNative.setAudio(source, 9999, 25.0, true))
            check(!MpvSourceNative.setAudio(source, -2, 25.0, true))
            check(!MpvSourceNative.setAudio(source, 1, Double.NaN, true))
            check(!MpvSourceNative.setAudio(source, 1, 101.0, true))
            report.put("invalid_controls_rejected", true)
            phase = "play_audio_clock"
            MpvSourceNative.setPlaying(source, true)
            waitFor { val d = it.getJSONObject("details"); d.getString("paused") == "no" && !d.isNull("audio_pts_us") }
            sample("playing_track_1", 1200)
            phase = "pause_audio_clock"
            MpvSourceNative.setPlaying(source, false)
            waitFor { it.getJSONObject("details").getString("paused") == "yes" }
            Thread.sleep(150)
            sample("paused_track_1", 700)
            phase = "switch_audio_track"
            check(MpvSourceNative.setAudio(source, 2, 40.0, true))
            waitFor { val d = it.getJSONObject("details"); d.optString("audio_track_id") == "2" &&
                d.optString("audio_output").isNotEmpty() &&
                d.optString("volume").toDoubleOrNull() == 40.0 }
            record("selected_track_2")
            MpvSourceNative.setPlaying(source, true)
            waitFor { val d = it.getJSONObject("details"); d.getString("paused") == "no" && !d.isNull("audio_pts_us") }
            sample("playing_track_2", 800)
            MpvSourceNative.setPlaying(source, false)
            waitFor { it.getJSONObject("details").getString("paused") == "yes" }
            Thread.sleep(150)
            sample("paused_track_2", 500)
            phase = "disable_audio"
            check(MpvSourceNative.setAudio(source, 0, 40.0, true))
            waitFor { val d = it.getJSONObject("details"); d.optString("audio_output").isEmpty() && d.optString("audio_track_id").isEmpty() }
            record("audio_disabled")
            MpvSourceNative.setPlaying(source, true)
            waitFor { it.getJSONObject("details").getString("paused") == "no" }
            sample("playing_without_audio", 900)
            MpvSourceNative.setPlaying(source, false)
            waitFor { it.getJSONObject("details").getString("paused") == "yes" }
            check(MpvSourceNative.setAudio(source, 2, 40.0, true))
            waitFor { val d = it.getJSONObject("details"); d.optString("audio_output").isNotEmpty() && d.optString("audio_track_id") == "2" }
            record("restored_track_2")
            phase = "seek_with_audio_paused"
            check(MpvSourceNative.seek(source, 2000))
            report.put("seek_frame", codedFrame("seek_paused_2s"))
            waitFor { val d = it.getJSONObject("details"); kotlin.math.abs(d.getString("position_seconds").toDouble()-2.0) < 0.01 }
            sample("paused_after_seek", 500)
            phase = "unmute_at_zero_volume"
            check(MpvSourceNative.setAudio(source, 2, 0.0, false))
            waitFor { val d = it.getJSONObject("details"); d.optString("mute") == "no" && d.optString("volume").toDoubleOrNull() == 0.0 }
            record("unmuted_zero_volume")
            phase = "restore_muted_audio"
            check(MpvSourceNative.setAudio(source, 1, 25.0, true))
            waitFor { val d = it.getJSONObject("details"); d.optString("mute") == "yes" &&
                d.optString("audio_track_id") == "1" && d.optString("volume").toDoubleOrNull() == 25.0 &&
                d.optString("audio_output").isNotEmpty() }
            record("restored_track_1")
            MpvSourceNative.setPlaying(source, true)
            waitFor { val d = it.getJSONObject("details"); d.getString("paused") == "no" && !d.isNull("audio_pts_us") }
            sample("playing_after_seek", 1000)
            phase = "wait_audio_and_video_eof"
            val ended = waitFor { it.getString("state") == "ended" && it.getBoolean("eof_source_resolved") }
            record("eof", ended)
            phase = "audio_restart_after_eof"
            MpvSourceNative.setPlaying(source, false)
            check(MpvSourceNative.seek(source, 0))
            report.put("restart_frame", codedFrame("restart_paused_0s"))
            waitFor { val d = it.getJSONObject("details"); d.getString("paused") == "yes" &&
                kotlin.math.abs(d.getString("position_seconds").toDouble()) < 0.01 }
            sample("restart_paused", 500)
            MpvSourceNative.setPlaying(source, true)
            waitFor { val d = it.getJSONObject("details"); d.getString("paused") == "no" && !d.isNull("audio_pts_us") }
            sample("playing_after_restart", 900)
            report.put("state", "passed_native_checks")
        } catch (failure: Throwable) {
            report.put("state", "failed").put("error", failure.javaClass.simpleName+": "+failure.message).put("failure_phase", phase)
            if (source > 0) try { report.put("failure_native_status", JSONObject(MpvSourceNative.status(source))) } catch (_: Throwable) {}
        } finally {
            phase = "cleanup"
            report.put("records", records).put("eof_wait_observations", eofTimeline)
            var cleanupFailure: Throwable? = null
            try {
                if (source > 0) {
                    MpvSourceNative.requestClose(source)
                    val closed = waitFor { it.getBoolean("done") }
                    report.put("closed_native_status", closed)
                    check(MpvSourceNative.close(source, false)); source = 0
                    check(closed.getInt("held_slots") == 0 && closed.getInt("retiring_slots") == 0)
                }
            } catch (failure: Throwable) {
                cleanupFailure = failure
                if (source > 0) try { MpvSourceNative.close(source, true) } catch (_: Throwable) {}
            }
            try { check(owner.close()) } catch (failure: Throwable) { if (cleanupFailure == null) cleanupFailure = failure }
            try { focus?.release() } catch (failure: Throwable) { if (cleanupFailure == null) cleanupFailure = failure }
            report.put("audio_focus_closed", focus?.state() ?: "none")
                .put("audio_focus_changes", JSONArray(focusChanges.toList()))
            if (cleanupFailure == null) report.put("resources_closed", true)
            else report.put("state", "failed").put("resources_closed", false).put("cleanup_error", cleanupFailure.message)
            val directory = File(context.filesDir, "diagnostics").apply { mkdirs() }
            val temporary = File.createTempFile("mpv-audio-", ".tmp", directory)
            try { temporary.writeText(report.toString()); check(temporary.renameTo(File(directory, "mpv_audio_$id.json"))) }
            finally { temporary.delete() }
        }
    }
}
