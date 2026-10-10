package org.vrpassthroughplayer.plugin

import android.content.Context
import android.content.res.Configuration
import android.util.DisplayMetrics
import android.view.ContextThemeWrapper
import android.view.View
import android.view.WindowManager
import android.webkit.WebSettings
import android.webkit.WebView
import android.widget.FrameLayout
import kotlin.math.roundToInt

/** The VR texture is a virtual desktop, independent of the headset's 2D window and DPI. */
internal object WebLoginViewport {
    const val WIDTH = 1200
    const val HEIGHT = 720

    class Geometry(host: Context) {
        // WebView/Chromium uses the attached display's density, including on old PICO OS.
        // Resource overrides alone do not change its devicePixelRatio.
        private val metrics = DisplayMetrics().also {
            @Suppress("DEPRECATION")
            (host.getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay.getMetrics(it)
        }
        val density = metrics.density.coerceAtLeast(1f)
        val width = (WIDTH * density).roundToInt()
        val height = (HEIGHT * density).roundToInt()
        fun logical(pixels: Int) = (pixels / density).roundToInt()
    }

    fun context(host: Context): Context = ContextThemeWrapper(host, 0).apply {
        // Override only this view's resources; never change the Activity's XR configuration.
        applyOverrideConfiguration(Configuration().apply {
            fontScale = 1f
            screenWidthDp = WIDTH
            screenHeightDp = HEIGHT
            smallestScreenWidthDp = HEIGHT
            orientation = Configuration.ORIENTATION_LANDSCAPE
            screenLayout = Configuration.SCREENLAYOUT_SIZE_LARGE or Configuration.SCREENLAYOUT_LONG_NO
        })
    }

    fun container(context: Context, geometry: Geometry): FrameLayout = object : FrameLayout(context) {
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            // A vendor window/IME resize must not constrain the bitmap's web viewport.
            super.onMeasure(View.MeasureSpec.makeMeasureSpec(geometry.width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(geometry.height, View.MeasureSpec.EXACTLY))
        }
    }

    fun configure(view: WebView, userAgent: String) {
        view.settings.apply {
            javaScriptEnabled = true; domStorageEnabled = true
            allowFileAccess = false; allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            cacheMode = WebSettings.LOAD_NO_CACHE; userAgentString = userAgent
            textZoom = 100; layoutAlgorithm = WebSettings.LayoutAlgorithm.NORMAL
            useWideViewPort = true; loadWithOverviewMode = true
            setSupportMultipleWindows(false); setSupportZoom(true)
            builtInZoomControls = true; displayZoomControls = false
        }
    }
}
