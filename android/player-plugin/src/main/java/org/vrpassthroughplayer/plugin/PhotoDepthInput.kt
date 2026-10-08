package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.media.ExifInterface
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/** One orientation-preserving photo input; the full-resolution color is decoded separately. */
internal object PhotoDepthInput {
    const val WIDTH = 518
    const val HEIGHT = 518
    data class Content(val x: Int, val y: Int, val width: Int, val height: Int)
    data class Input(val rgb: ByteBuffer, val content: Content)

    // Video warmup removes obsolete files in its own directory. Keep photo programs separate.
    fun cacheDirectory(context: Context) = File(context.cacheDir, "photo-depth-mnn").apply { mkdirs() }

    fun fit(width: Int, height: Int): Content {
        require(width > 0 && height > 0)
        val scale = minOf(WIDTH.toDouble() / width, HEIGHT.toDouble() / height)
        val w = (width * scale).roundToInt().coerceIn(1, WIDTH)
        val h = (height * scale).roundToInt().coerceIn(1, HEIGHT)
        return Content((WIDTH - w) / 2, (HEIGHT - h) / 2, w, h)
    }

    fun prepare(source: File): Input {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(source.path, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "PHOTO_DECODE_FAILED" }
        // Retain at least 518 pixels on the longest edge before the final filtered resize.
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxOf(WIDTH, HEIGHT)) sample *= 2
        val original = BitmapFactory.decodeFile(source.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: error("PHOTO_DECODE_FAILED")
        var upright = original
        try {
            val orientation = runCatching { ExifInterface(source.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) }.getOrDefault(1)
            val matrix = Matrix().apply { when (orientation) {
                2 -> setScale(-1f, 1f); 3 -> setRotate(180f); 4 -> setScale(1f, -1f)
                5 -> { setRotate(90f); postScale(-1f, 1f) }; 6 -> setRotate(90f)
                7 -> { setRotate(90f); postScale(1f, -1f) }; 8 -> setRotate(270f)
            } }
            upright = Bitmap.createBitmap(original, 0, 0, original.width, original.height, matrix, true)
            val content = fit(upright.width, upright.height)
            val input = Bitmap.createBitmap(WIDTH, HEIGHT, Bitmap.Config.ARGB_8888)
            try {
                Canvas(input).apply {
                    drawColor(Color.BLACK)
                    drawBitmap(upright, null, Rect(content.x, content.y, content.x + content.width, content.y + content.height), Paint(Paint.FILTER_BITMAP_FLAG))
                }
                val pixels = IntArray(WIDTH * HEIGHT)
                input.getPixels(pixels, 0, WIDTH, 0, 0, WIDTH, HEIGHT)
                val rgb = ByteBuffer.allocateDirect(WIDTH * HEIGHT * 12).order(ByteOrder.LITTLE_ENDIAN)
                for (shift in listOf(16, 8, 0)) for (pixel in pixels) rgb.putFloat(((pixel shr shift) and 255) / 255f)
                rgb.rewind()
                return Input(rgb, content)
            } finally { input.recycle() }
        } finally { if (upright !== original) upright.recycle(); original.recycle() }
    }
}
