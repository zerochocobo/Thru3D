package org.vrpassthroughplayer.plugin

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** A still is warped once on the depth worker, then displayed/cached as an ordinary SBS texture. */
internal object PhotoStereo {
    const val MAX_EDGE = 4096 // The shared z-buffer's source column occupies 12 bits.
    const val MAX_PIXELS = 8 * 1024 * 1024

    fun size(width: Int, height: Int): Pair<Int, Int> {
        require(width > 0 && height > 0)
        val ratio = minOf(1.0, MAX_EDGE.toDouble()/maxOf(width,height), sqrt(MAX_PIXELS.toDouble()/width/height))
        return maxOf(1,(width*ratio).toInt()) to maxOf(1,(height*ratio).toInt())
    }

    fun prepare(source: File, near: ByteBuffer, rect: FloatArray, strength: Float, generation: Int): JSONObject {
        require(strength.isFinite() && strength in 0f..2f)
        val prefix = "stereo-${(strength*100).roundToInt()}-"
        // Raw RGBA pair named with its size: a hit is checked by length, with nothing to decode.
        source.parentFile?.listFiles()?.firstOrNull { it.name.startsWith(prefix) && it.extension == "rgba" }?.let { cached ->
            val size = Regex("""-(\d+)x(\d+)$""").find(cached.nameWithoutExtension)?.groupValues
            val w = size?.get(1)?.toIntOrNull() ?: 0; val h = size?.get(2)?.toIntOrNull() ?: 0
            if (w > 0 && h > 0 && cached.length() == w.toLong()*h*4) return metadata(cached, w, h, strength, 0)
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(source.path, bounds)
        val targetSize = size(bounds.outWidth, bounds.outHeight)
        var sample = 1
        while (bounds.outWidth / (sample*2) >= targetSize.first && bounds.outHeight / (sample*2) >= targetSize.second) sample *= 2
        val original = BitmapFactory.decodeFile(source.path, BitmapFactory.Options().apply { inSampleSize=sample; inPreferredConfig=Bitmap.Config.ARGB_8888 })
            ?: error("PHOTO_DECODE_FAILED")
        var upright = original
        var color = original
        try {
            val orientation = runCatching { ExifInterface(source.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) }.getOrDefault(1)
            val matrix = Matrix().apply { when (orientation) {
                2 -> setScale(-1f,1f); 3 -> setRotate(180f); 4 -> setScale(1f,-1f)
                5 -> { setRotate(90f); postScale(-1f,1f) }; 6 -> setRotate(90f)
                7 -> { setRotate(90f); postScale(1f,-1f) }; 8 -> setRotate(270f)
            } }
            upright = Bitmap.createBitmap(original,0,0,original.width,original.height,matrix,true)
            val (w,h) = size(upright.width,upright.height)
            color = Bitmap.createScaledBitmap(upright,w,h,true)
            val rgba = ByteBuffer.allocateDirect(w*h*4).order(ByteOrder.LITTLE_ENDIAN)
            color.copyPixelsToBuffer(rgba); rgba.rewind(); near.rewind()
            val output = ByteBuffer.allocateDirect(w*h*8).order(ByteOrder.LITTLE_ENDIAN)
            val micros = RenderBridgeNative.photoStereo(rgba,w,h,near,PhotoDepthInput.WIDTH,PhotoDepthInput.HEIGHT,rect,strength,output)
            require(micros > 0)
            // The GPU pair is already RGBA rows: hand it over raw. PNG encoding a 16.8 MP pair took
            // 4.2-6.4 s on Quest 3 (1.4-1.8 s for 5 MP), most of a large photo's wait.
            val target = File(source.parentFile, "$prefix${w*2}x$h.rgba")
            val temporary = File(source.parentFile,"stereo-$generation.tmp")
            try {
                output.rewind()
                java.io.FileOutputStream(temporary).channel.use { channel -> while (output.hasRemaining()) channel.write(output) }
                require(temporary.renameTo(target))
            } finally { temporary.delete() }
            // Textures already decoded by Godot own their pixels. Retain the latest few disk pairs.
            source.parentFile?.listFiles()?.filter { it.name.startsWith("stereo-") && it.extension in setOf("png", "rgba") && it != target }
                ?.sortedByDescending { it.lastModified() }?.drop(2)?.forEach { it.delete() }
            return metadata(target,w*2,h,strength,micros)
        } finally {
            if (color !== upright && color !== original) color.recycle()
            if (upright !== original) upright.recycle()
            original.recycle()
        }
    }

    private fun metadata(file: File, width: Int, height: Int, strength: Float, micros: Long) = JSONObject()
        .put("stereo_path",file.path).put("stereo_width",width).put("stereo_height",height)
        .put("stereo_strength",strength.toDouble()).put("stereo_render_us",micros)
        .put("stereo_strategy","video_soft_shift_gpu")
}
