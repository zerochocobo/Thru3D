package org.vrpassthroughplayer.plugin

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject

/** Queries advertised codec support. Actual playback has a separate C03/C04 gate. */
internal object DeviceCapabilities {
    fun collect(graphicsJson: String): JSONObject {
        val report = JSONObject()
            .put("schema_version", 1)
            .put("captured_elapsed_realtime_us", SystemClock.elapsedRealtimeNanos() / 1000)
            .put("manufacturer", Build.MANUFACTURER)
            .put("model", Build.MODEL)
            .put("device", Build.DEVICE)
            .put("android_release", Build.VERSION.RELEASE)
            .put("android_api", Build.VERSION.SDK_INT)
            .put("build_display", Build.DISPLAY)
            .put("build_fingerprint", Build.FINGERPRINT)
            .put("abis", JSONArray(Build.SUPPORTED_ABIS.toList()))
            .put("graphics", JSONObject(graphicsJson))
            .put("codec_report_kind", "advertised_capabilities_not_playback_validation")
        val decoders = JSONArray()
        val codecs = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
        for (codec in codecs) {
            if (codec.isEncoder || codec.isAlias) continue
            for (mime in codec.supportedTypes) {
                if (mime != "video/avc" && mime != "video/hevc") continue
                decoders.put(describeDecoder(codec, mime))
            }
        }
        return report.put("video_decoders", decoders)
    }

    private fun describeDecoder(codec: MediaCodecInfo, mime: String): JSONObject {
        val result = JSONObject()
            .put("name", codec.name)
            .put("mime", mime)
            .put("hardware_accelerated", codec.isHardwareAccelerated)
            .put("software_only", codec.isSoftwareOnly)
            .put("vendor", codec.isVendor)
        try {
            val capabilities = codec.getCapabilitiesForType(mime)
            val video = capabilities.videoCapabilities
                ?: throw IllegalStateException("Video capabilities were not returned")
            result.put("width_range", JSONArray(listOf(video.supportedWidths.lower, video.supportedWidths.upper)))
            result.put("height_range", JSONArray(listOf(video.supportedHeights.lower, video.supportedHeights.upper)))
            result.put("width_alignment", video.widthAlignment)
            result.put("height_alignment", video.heightAlignment)
            result.put("max_instances", capabilities.maxSupportedInstances)
            result.put("profile_levels", JSONArray(capabilities.profileLevels.map {
                JSONObject().put("profile", it.profile).put("level", it.level)
            }))
            val candidates = JSONArray()
            for ((width, height) in listOf(1920 to 1080, 3840 to 1920, 3840 to 2160)) {
                val candidate = JSONObject().put("width", width).put("height", height).put("fps", 30)
                candidate.put("advertised_size_rate_support", video.areSizeAndRateSupported(width, height, 30.0))
                candidates.put(candidate)
            }
            result.put("candidates", candidates)
        } catch (error: Exception) {
            result.put("query_error", error.javaClass.simpleName + ": " + (error.message ?: ""))
        }
        return result
    }
}

