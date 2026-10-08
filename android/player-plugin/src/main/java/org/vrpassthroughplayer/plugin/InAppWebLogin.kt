package org.vrpassthroughplayer.plugin

import android.annotation.SuppressLint
import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.ViewGroup
import android.view.View
import android.widget.FrameLayout
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.webkit.*
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicBoolean

/** Web content stays behind the main Godot surface, in the same Activity. Only a memory
 * image is sent to the VR panel; touch and input connection events return to the WebView.
 * No Android dialog, separate Activity, shell launch, JS credential bridge or image files. */
@SuppressLint("SetJavaScriptEnabled")
internal class InAppWebLogin(private val host: () -> Activity?, private val provider: String,
    private val connected: (String) -> Boolean) {
    companion object { const val WIDTH = 1200; const val HEIGHT = 720 }
    private val handler = Handler(Looper.getMainLooper())
    private val capturing = AtomicBoolean()
    private val finished = AtomicBoolean()
    @Volatile private var closed = false
    @Volatile private var paused = false
    @Volatile private var frameBytes = ByteArray(0)
    @Volatile private var status = "Loading…"
    @Volatile private var editing = false
    @Volatile private var progress = 0
    private var web: LoginView? = null
    private var viewport: FrameLayout? = null
    private var bitmap: Bitmap? = null
    private var editor: InputConnection? = null
    private var downAt = 0L
    @Volatile private var touchActive = false
    @Volatile private var scrollY = 0
    @Volatile private var scrollRange = HEIGHT
    @Volatile private var debugInputs = JSONObject()
    @Volatile private var inputAccepted = false
    private var debugFixture = false
    private val start = if (provider == CloudDrive.P115) "https://115.com/" else "https://pan.baidu.com/disk/main"

    private inner class LoginView(activity: Activity) : WebView(activity) {
        override fun onCreateInputConnection(info: EditorInfo): InputConnection? {
            val connection = super.onCreateInputConnection(info)
            editor = connection
            editing = connection != null && info.inputType != 0
            // Input is supplied by the app's ray keyboard, never a vendor 2D IME window.
            handler.post {
                (context.getSystemService(Activity.INPUT_METHOD_SERVICE) as? InputMethodManager)?.hideSoftInputFromWindow(windowToken, 0)
            }
            return null
        }
        fun documentHeight() = computeVerticalScrollRange().coerceAtLeast(HEIGHT)
        fun captureEditor() {
            val info = EditorInfo()
            val connection = super.onCreateInputConnection(info)
            if (connection != null && info.inputType != 0) { editor = connection; editing = true }
        }
        override fun onScrollChanged(x: Int, y: Int, oldX: Int, oldY: Int) {
            super.onScrollChanged(x, y, oldX, oldY)
            updateScroll()
        }
    }

    fun snapshot() = JSONObject().put("status", status).put("editing", editing && !touchActive).put("progress", progress)
        .put("width", WIDTH).put("height", HEIGHT).put("scroll_y", scrollY).put("scroll_range", scrollRange)
        .put("failed", web == null && status != "Loading…")
        .apply { if (BuildConfig.DEBUG) put("debug_inputs", debugInputs).put("input_accepted", inputAccepted) }

    fun open() { handler.post {
        if (closed || web != null) return@post
        try {
            val activity = host() ?: error("Activity unavailable")
            val view = LoginView(activity)
            web = view
            view.isSaveEnabled = false
            view.importantForAutofill = android.view.View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
            view.importantForContentCapture = android.view.View.IMPORTANT_FOR_CONTENT_CAPTURE_NO_EXCLUDE_DESCENDANTS
            val root = activity.findViewById<ViewGroup>(android.R.id.content)
            val container = FrameLayout(activity)
            viewport = container
            container.addView(view, FrameLayout.LayoutParams(WIDTH, HEIGHT))
            root.addView(container, 0, ViewGroup.LayoutParams(WIDTH, HEIGHT))
            // drawChild supplies WebView's scroll transform and clipping. Drawing WebView
            // alone into a bitmap bypasses this path after focused inputs scroll the page.
            view.setLayerType(View.LAYER_TYPE_SOFTWARE, null)
            view.isVerticalScrollBarEnabled = true
            view.isScrollbarFadingEnabled = false
            container.measure(android.view.View.MeasureSpec.makeMeasureSpec(WIDTH, android.view.View.MeasureSpec.EXACTLY),
                android.view.View.MeasureSpec.makeMeasureSpec(HEIGHT, android.view.View.MeasureSpec.EXACTLY))
            container.layout(0, 0, WIDTH, HEIGHT)
            view.settings.apply {
                javaScriptEnabled = true; domStorageEnabled = true
                allowFileAccess = false; allowContentAccess = false
                mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                cacheMode = WebSettings.LOAD_NO_CACHE; userAgentString = CloudHttp.UA
                useWideViewPort = true; loadWithOverviewMode = true
                setSupportMultipleWindows(false); setSupportZoom(true)
                builtInZoomControls = true; displayZoomControls = false
            }
            WebView.setWebContentsDebuggingEnabled(false)
            view.webChromeClient = object : WebChromeClient() {
                override fun onProgressChanged(view: WebView, value: Int) { progress = value }
                override fun onJsAlert(view: WebView, url: String, message: String, result: JsResult): Boolean { result.confirm(); return true }
                override fun onJsConfirm(view: WebView, url: String, message: String, result: JsResult): Boolean { result.cancel(); return true }
                override fun onJsPrompt(view: WebView, url: String, message: String, defaultValue: String, result: JsPromptResult): Boolean { result.cancel(); return true }
            }
            view.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) =
                    !CloudWebNavigation.allowed(request.url.toString(), provider, request.isForMainFrame)
                override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) { status = "Loading…"; editing = false; editor = null }
                override fun onPageFinished(view: WebView, url: String) { status = ""; checkSession() }
                override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                    if (request.isForMainFrame) status = "Page unavailable. Try reloading."
                }
                override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: android.net.http.SslError) {
                    handler.cancel(); status = "Page unavailable. Try reloading."
                }
                override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                    detach(); status = "Web sign-in is unavailable on this device."; return true
                }
            }
            view.setDownloadListener { _, _, _, _, _ -> status = "Page unavailable. Try reloading." }
            val cookies = CookieManager.getInstance()
            cookies.setAcceptCookie(true); cookies.setAcceptThirdPartyCookies(view, true)
            cookies.removeAllCookies {
                if (!closed && web === view) { WebStorage.getInstance().deleteAllData(); view.loadUrl(start) }
            }
        } catch (_: Exception) { detach(); status = "Web sign-in is unavailable on this device." }
    } }

    /** Polling is driven by the visible VR panel; invisible/paused panels have no capture loop. */
    fun frame(): ByteArray {
        if (!closed && !paused && capturing.compareAndSet(false, true)) handler.post {
            try {
                val view = web
                if (!closed && !paused && view != null) {
                    if (bitmap == null) bitmap = Bitmap.createBitmap(WIDTH, HEIGHT, Bitmap.Config.ARGB_8888)
                    val canvas = Canvas(bitmap!!); canvas.drawColor(android.graphics.Color.WHITE)
                    viewport?.draw(canvas)
                    val bytes = ByteArrayOutputStream()
                    bitmap!!.compress(Bitmap.CompressFormat.JPEG, 88, bytes)
                    frameBytes = bytes.toByteArray()
                    updateScroll()
                    checkSession()
                }
            } catch (_: Exception) { status = "Page unavailable. Try reloading." }
            finally { capturing.set(false) }
        }
        return if (closed || paused) ByteArray(0) else frameBytes
    }

    private fun checkSession() {
        if (closed || finished.get() || debugFixture) return
        val cookie = CookieManager.getInstance().getCookie(start).orEmpty()
        val names = cookie.split(';').map { it.substringBefore('=').trim() }.toSet()
        val valid = if (provider == CloudDrive.P115) names.containsAll(listOf("UID", "CID", "SEID")) else "BDUSS" in names
        if (valid && CloudHttp.validCookie(cookie) && finished.compareAndSet(false, true)) {
            status = "Connecting…"
            if (!connected(cookie)) finished.set(false)
        }
    }

    fun action(action: String, x: Float, y: Float, text: String) {
        if (closed || paused || !x.isFinite() || !y.isFinite() || text.length > 4096) return
        handler.post {
            val view = web
            if (closed || paused) return@post
            if (action == "reload" && view == null) { status = "Loading…"; finished.set(false); open(); return@post }
            if (view == null) return@post
            when (action) {
                "down", "move", "up", "cancel" -> {
                    if (action == "down") { downAt = SystemClock.uptimeMillis(); touchActive = true }
                    val code = when (action) { "down" -> MotionEvent.ACTION_DOWN; "move" -> MotionEvent.ACTION_MOVE; "up" -> MotionEvent.ACTION_UP; else -> MotionEvent.ACTION_CANCEL }
                    val event = MotionEvent.obtain(downAt, SystemClock.uptimeMillis(), code,
                        x.coerceIn(0f, 1f) * WIDTH, y.coerceIn(0f, 1f) * HEIGHT, 0)
                    try { view.dispatchTouchEvent(event) } finally { event.recycle() }
                    if (action in setOf("up", "cancel")) touchActive = false
                    if (action == "up") handler.postDelayed({
                        if (!closed && web === view && !touchActive) view.captureEditor()
                    }, 100)
                }
                "scroll" -> view.scrollBy(0, (y.coerceIn(-1f, 1f) * 160).toInt())
                "scroll_to" -> view.scrollTo(view.scrollX, (y.coerceIn(0f, 1f) * (view.documentHeight() - HEIGHT)).toInt())
                "zoom_in" -> view.zoomBy(1.25f)
                "zoom_out" -> view.zoomBy(0.8f)
                "text" -> if (text.none { it == '\u0000' }) { inputAccepted = editor?.commitText(text, 1) == true }
                "paste" -> {
                    val clipboard = view.context.getSystemService(Activity.CLIPBOARD_SERVICE) as? android.content.ClipboardManager
                    val value = clipboard?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()?.take(2048).orEmpty()
                    if (value.none { it == '\u0000' }) editor?.commitText(value, 1)
                }
                "backspace" -> editor?.deleteSurroundingText(1, 0)
                "enter" -> { editor?.performEditorAction(EditorInfo.IME_ACTION_GO); editing = false; editor = null; view.clearFocus() }
                "keyboard_close" -> { editing = false; editor = null; view.clearFocus() }
                "back" -> if (view.canGoBack()) view.goBack()
                "reload" -> { finished.set(false); view.reload() }
                "finish" -> { finished.set(false); checkSession() }
                "debug_inspect" -> if (BuildConfig.DEBUG) inspectInputs(view)
                "debug_fixture" -> if (BuildConfig.DEBUG) {
                    debugFixture = true
                    view.loadDataWithBaseURL("https://example.invalid/", """<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font:28px sans-serif;background:#d9e7ed;padding:30px}input{display:block;width:70%;font:28px sans-serif;margin:40px;padding:20px}section{height:1600px;background:linear-gradient(#b1dfdf,#548ba0)}</style><h1>Web input and scroll fixture</h1><input type="tel" placeholder="Phone"><input type="password" placeholder="Password"><section></section>""", "text/html", "UTF-8", null)
                }
            }
        }
    }

    fun pause(value: Boolean) {
        paused = value
        handler.post { web?.let { view ->
            if (value) { actionCancel(view); view.onPause() } else view.onResume()
        } }
    }
    private fun actionCancel(view: WebView) {
        val event = MotionEvent.obtain(downAt, SystemClock.uptimeMillis(), MotionEvent.ACTION_CANCEL, 0f, 0f, 0)
        try { view.dispatchTouchEvent(event) } finally { event.recycle() }
        touchActive = false
    }
    private fun updateScroll() {
        val view = web ?: return
        scrollY = view.scrollY
        scrollRange = view.documentHeight()
    }
    /** Debug-only geometry/types, never reads input values, page HTML, cookies or storage. */
    private fun inspectInputs(view: LoginView) {
        view.evaluateJavascript("""JSON.stringify((function(){var result={width:innerWidth,height:innerHeight,inputs:[]};function scan(doc,ox,oy){Array.from(doc.querySelectorAll('input,iframe')).slice(0,32).forEach(function(e){var r=e.getBoundingClientRect();if(r.width<=0||r.height<=0)return;if(e.tagName==='IFRAME'){try{scan(e.contentDocument,ox+r.x,oy+r.y)}catch(_){}}else if(result.inputs.length<24){result.inputs.push({type:e.type,x:(ox+r.x)/innerWidth,y:(oy+r.y)/innerHeight,w:r.width/innerWidth,h:r.height/innerHeight})}})}scan(document,0,0);return result})())""") { raw ->
            if (closed || web !== view) return@evaluateJavascript
            debugInputs = runCatching { JSONObject(org.json.JSONArray("[$raw]").getString(0)) }.getOrElse { JSONObject() }
        }
    }
    private fun detach() {
        web?.let { view ->
            viewport?.let { (it.parent as? ViewGroup)?.removeView(it) }
            view.stopLoading(); view.clearHistory(); view.clearCache(true); view.destroy()
        }
        web = null; viewport = null; editor = null; editing = false; touchActive = false; frameBytes = ByteArray(0)
        bitmap?.recycle(); bitmap = null
    }
    fun close() {
        closed = true; frameBytes = ByteArray(0)
        handler.post { detach(); CookieManager.getInstance().removeAllCookies { CookieManager.getInstance().flush() }; WebStorage.getInstance().deleteAllData() }
    }
}
