package org.vrpassthroughplayer.webfixture

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.ContextThemeWrapper
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import org.json.JSONObject
import org.vrpassthroughplayer.plugin.WebLoginViewport
import java.io.File

/** Separate local-only APK: executes the production viewport on a real Android WebView. */
@SuppressLint("SetJavaScriptEnabled")
class WebLoginFixtureActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private class FixtureView(context: Context) : WebView(context) {
        override fun onCreateInputConnection(info: EditorInfo) = null
        fun editor() = super.onCreateInputConnection(EditorInfo())
    }
    private lateinit var web: FixtureView
    private lateinit var viewport: FrameLayout
    private lateinit var root: FrameLayout
    private lateinit var geometry: WebLoginViewport.Geometry
    private val report = JSONObject()
    private val checks = JSONObject()
    private var started = false
    private var fixed = true

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        fixed = !intent.getBooleanExtra("legacy", false)
        val density = intent.getIntExtra("density", 480).coerceIn(160, 640)
        val fontScale = intent.getFloatExtra("font_scale", 1.8f).coerceIn(1f, 2f)
        val portrait = intent.getBooleanExtra("portrait", false)
        val host = ContextThemeWrapper(this, 0).apply {
            applyOverrideConfiguration(Configuration().apply {
                this.fontScale = fontScale
                screenWidthDp = if (portrait) 240 else 400; screenHeightDp = if (portrait) 400 else 240
                orientation = if (portrait) Configuration.ORIENTATION_PORTRAIT else Configuration.ORIENTATION_LANDSCAPE
            })
        }
        val context = if (fixed) WebLoginViewport.context(host) else host
        geometry = WebLoginViewport.Geometry(this)
        web = FixtureView(context)
        viewport = if (fixed) WebLoginViewport.container(context, geometry) else FrameLayout(context)
        viewport.addView(web, FrameLayout.LayoutParams(if (fixed) geometry.width else WebLoginViewport.WIDTH,
            if (fixed) geometry.height else WebLoginViewport.HEIGHT))
        root = FrameLayout(this)
        root.addView(viewport, FrameLayout.LayoutParams(600, 240))
        setContentView(root)
        layoutViewport(600, 240)
        web.setLayerType(View.LAYER_TYPE_SOFTWARE, null)
        WebLoginViewport.configure(web, "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36")
        if (!fixed) { web.setInitialScale(0); web.settings.textZoom = (fontScale * 100).toInt() }
        report.put("fixed", fixed).put("host_density", density).put("host_font_scale", fontScale).put("host_portrait", portrait)
            .put("render_density", context.resources.configuration.densityDpi).put("display_density", geometry.density)
        web.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String) {
                if (started) return
                started = true
                handler.postDelayed({ inspect("initial") { testInput() } }, 500)
            }
        }
        web.loadDataWithBaseURL(null, assets.open("login.html").bufferedReader().use { it.readText() }, "text/html", "UTF-8", null)
    }

    private fun inspect(phase: String, next: () -> Unit) {
        web.evaluateJavascript("""JSON.stringify({width:innerWidth,height:innerHeight,dpr:devicePixelRatio,scale:visualViewport.scale,fields:['phone','password','login','code','confirm'].map(function(id){var r=document.getElementById(id).getBoundingClientRect();return {id:id,x:r.x,y:r.y,w:r.width,h:r.height}}),confirmed:document.body.dataset.confirmed==='yes'})""") { raw ->
            val geometry = JSONObject(org.json.JSONTokener(raw).nextValue() as String)
            geometry.put("view_width", web.width).put("view_height", web.height)
                .put("container_width", viewport.width).put("container_height", viewport.height)
            report.put(phase, geometry)
            if (phase == "initial") {
                checks.put("desktop_css_viewport", geometry.getInt("width") == 1200 && geometry.getInt("height") == 720)
                checks.put("full_container_despite_small_host", viewport.width == this.geometry.width && viewport.height == this.geometry.height)
                checks.put("login_controls_visible", visible(geometry, setOf("phone", "password", "login")))
            } else if (phase == "captcha") {
                checks.put("captcha_confirm_visible", visible(geometry, setOf("code", "confirm")))
            } else if (phase == "resized") {
                checks.put("viewport_survives_host_resize", web.width == this.geometry.width && web.height == this.geometry.height &&
                    viewport.width == this.geometry.width && viewport.height == this.geometry.height && geometry.getInt("height") == 720)
                checks.put("captcha_after_resize", visible(geometry, setOf("code", "confirm")))
            }
            var ready = false
            var completed = false
            fun complete() {
                if (completed) return
                completed = true
                report.put(phase + "_visual_ready", ready)
                snapshot(phase)
                next()
            }
            web.postVisualStateCallback(SystemClock.uptimeMillis(), object : WebView.VisualStateCallback() {
                override fun onComplete(requestId: Long) {
                    ready = true
                    complete()
                }
            })
            // Like the production VR panel, poll draw even when the vendor's window is hidden.
            val pump = object : Runnable {
                override fun run() {
                    if (completed || isFinishing || isDestroyed) return
                    snapshot(phase)
                    handler.postDelayed(this, 50)
                }
            }
            handler.post(pump)
            // Sleeping headsets can withhold compositor callbacks; retain geometry evidence
            // but explicitly mark these frames as unverified instead of hanging forever.
            handler.postDelayed({ complete() }, 2000)
        }
    }

    private fun visible(geometry: JSONObject, ids: Set<String>): Boolean {
        val fields = geometry.getJSONArray("fields")
        return (0 until fields.length()).map { fields.getJSONObject(it) }.filter { it.getString("id") in ids }.all {
            it.getDouble("w") > 0 && it.getDouble("h") > 0 && it.getDouble("x") >= 0 && it.getDouble("y") >= 0 &&
                (it.getDouble("x") + it.getDouble("w")) * geometry.getDouble("dpr") * geometry.getDouble("scale") <= minOf(viewport.width, web.width) + 1 &&
                (it.getDouble("y") + it.getDouble("h")) * geometry.getDouble("dpr") * geometry.getDouble("scale") <= minOf(viewport.height, web.height) + 1
        }
    }

    private fun testInput() {
        tap("phone") {
            val connection = web.editor()
            checks.put("input_connection_commit", connection?.commitText("13800138000", 1) == true)
            // Read only the fixture's known dummy text, never a remote login page.
            handler.postDelayed({ web.evaluateJavascript("document.activeElement.id==='phone' && document.getElementById('phone').value==='13800138000'") { raw ->
                checks.put("touch_focus_and_input_match_pixels", raw == "true")
                connection?.closeConnection()
                tap("login") { handler.postDelayed({ inspect("captcha") { resizeHost() } }, 300) }
            } }, 150)
        }
    }

    private fun resizeHost() {
        viewport.layoutParams = FrameLayout.LayoutParams(300, 100)
        layoutViewport(300, 100)
        handler.postDelayed({ inspect("resized") {
            tap("confirm") {
                web.evaluateJavascript("document.body.dataset.confirmed==='yes'") { raw ->
                    checks.put("captcha_confirmation_click", raw == "true")
                    report.put("checks", checks)
                    report.put("passed", checks.keys().asSequence().all { checks.getBoolean(it) })
                    File(filesDir, "report.json").writeText(report.toString(2))
                }
            }
        } }, 300)
    }

    private fun tap(id: String, next: () -> Unit) {
        web.evaluateJavascript("""JSON.stringify((function(){var r=document.getElementById('$id').getBoundingClientRect();var scale=devicePixelRatio*visualViewport.scale;return {x:(r.x+r.width/2)*scale,y:(r.y+r.height/2)*scale}})())""") { raw ->
            val point = JSONObject(org.json.JSONTokener(raw).nextValue() as String)
            val time = SystemClock.uptimeMillis()
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(time, SystemClock.uptimeMillis(), action, point.getDouble("x").toFloat(), point.getDouble("y").toFloat(), 0)
                try { web.dispatchTouchEvent(event) } finally { event.recycle() }
            }
            handler.postDelayed(next, 150)
        }
    }

    private fun snapshot(phase: String) {
        val bitmap = Bitmap.createBitmap(1200, 720, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        if (fixed) canvas.scale(1f / geometry.density, 1f / geometry.density)
        viewport.draw(canvas)
        File(filesDir, "$phase.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    private fun layoutViewport(width: Int, height: Int) {
        viewport.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
        viewport.layout(0, 0, viewport.measuredWidth, viewport.measuredHeight)
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        web.destroy()
        super.onDestroy()
    }
}
