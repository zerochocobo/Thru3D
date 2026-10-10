package org.vrpassthroughplayer.plugin

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
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
 * No Android dialog, separate Activity, shell launch or image files. OAuth credentials stay in native code. */
@SuppressLint("SetJavaScriptEnabled")
internal class InAppWebLogin(private val host: () -> Activity?, private val provider: String,
    private val connected: (String) -> Boolean, private val authorized: ((OpenListAuth.Credential) -> Boolean)? = null) {
    companion object { const val WIDTH = WebLoginViewport.WIDTH; const val HEIGHT = WebLoginViewport.HEIGHT }
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
    private var geometry: WebLoginViewport.Geometry? = null
    private var bitmap: Bitmap? = null
    private var editor: InputConnection? = null
    private var downAt = 0L
    @Volatile private var touchActive = false
    @Volatile private var scrollY = 0
    @Volatile private var scrollRange = HEIGHT
    @Volatile private var debugInputs = JSONObject()
    @Volatile private var inputAccepted = false
    private var debugFixture = false
    @Volatile private var debugOAuthProbe = JSONObject()
    @Volatile private var oauthRejected = false
    private val oauth = OpenListAuth.supported(provider)
    private val recoveringOAuth = AtomicBoolean()
    private var oauthSession = if (oauth) OpenListOAuthSession(provider) else null
    private val start = if (oauth) OpenListAuth.requestUrl(provider) else if (provider == CloudDrive.P115) "https://115.com/" else "https://pan.baidu.com/disk/main"

    private inner class LoginView(context: Context) : WebView(context) {
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
        fun documentHeight() = computeVerticalScrollRange().coerceAtLeast(height)
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
        .apply { if (BuildConfig.DEBUG) put("debug_inputs", debugInputs).put("input_accepted", inputAccepted).put("oauth_probe", debugOAuthProbe).put("oauth_flow", oauthSession?.summary()) }

    fun open() { handler.post {
        if (closed || web != null) return@post
        try {
            val activity = host() ?: error("Activity unavailable")
            val layout = WebLoginViewport.Geometry(activity)
            geometry = layout
            val webContext = WebLoginViewport.context(activity)
            val view = LoginView(webContext)
            web = view
            view.isSaveEnabled = false
            view.importantForAutofill = android.view.View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
            view.importantForContentCapture = android.view.View.IMPORTANT_FOR_CONTENT_CAPTURE_NO_EXCLUDE_DESCENDANTS
            val root = activity.findViewById<ViewGroup>(android.R.id.content)
            val container = WebLoginViewport.container(webContext, layout)
            viewport = container
            container.addView(view, FrameLayout.LayoutParams(layout.width, layout.height))
            root.addView(container, 0, ViewGroup.LayoutParams(layout.width, layout.height))
            // drawChild supplies WebView's scroll transform and clipping. Drawing WebView
            // alone into a bitmap bypasses this path after focused inputs scroll the page.
            view.setLayerType(View.LAYER_TYPE_SOFTWARE, null)
            view.isVerticalScrollBarEnabled = true
            view.isScrollbarFadingEnabled = false
            container.measure(android.view.View.MeasureSpec.makeMeasureSpec(layout.width, android.view.View.MeasureSpec.EXACTLY),
                android.view.View.MeasureSpec.makeMeasureSpec(layout.height, android.view.View.MeasureSpec.EXACTLY))
            container.layout(0, 0, layout.width, layout.height)
            WebLoginViewport.configure(view, CloudHttp.UA)
            WebView.setWebContentsDebuggingEnabled(false)
            view.webChromeClient = object : WebChromeClient() {
                override fun onProgressChanged(view: WebView, value: Int) { progress = value }
                override fun onJsAlert(view: WebView, url: String, message: String, result: JsResult): Boolean { result.confirm(); return true }
                override fun onJsConfirm(view: WebView, url: String, message: String, result: JsResult): Boolean { result.cancel(); return true }
                override fun onJsPrompt(view: WebView, url: String, message: String, defaultValue: String, result: JsPromptResult): Boolean { result.cancel(); return true }
            }
            view.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    val url = request.url.toString()
                    if (!CloudWebNavigation.allowed(url, provider, request.isForMainFrame)) {
                        if (BuildConfig.DEBUG) debugOAuthProbe = JSONObject().put("stage", "blocked_navigation")
                            .put("main_frame", request.isForMainFrame).put("host", runCatching { java.net.URI(url).host }.getOrNull())
                        if (request.isForMainFrame) status = "Page unavailable. Try reloading."
                        return true
                    }
                    if (oauth && (request.isForMainFrame || OpenListAuth.atTool(url) ||
                        (provider == CloudDrive.QUARK && OpenListAuth.quarkBrokerCallback(url)))) {
                        if (oauthRejected) return true
                        if (consumeOAuth(url)) return true
                        if (OpenListAuth.callback(url, provider)) {
                            val session = oauthSession!!
                            if (!session.matchesCallback(url) && !session.allowCallback(url)) {
                                if (BuildConfig.DEBUG) debugOAuthProbe = session.callbackDiagnostics(url)
                                    .put("stage", "callback_rejected").put("main_frame", request.isForMainFrame)
                                rejectAuthorization()
                                return true
                            }
                            if (BuildConfig.DEBUG) debugOAuthProbe = session.callbackDiagnostics(url)
                                .put("stage", "callback_accepted").put("main_frame", request.isForMainFrame)
                            if (!request.isForMainFrame && provider != CloudDrive.QUARK) {
                                // A verified embedded callback must become first party so APIpage
                                // receives its SameSite login cookies. Its exact accepted URL is retained.
                                view.loadUrl(url); return true
                            }
                        }
                        if (provider == CloudDrive.QUARK && OpenListAuth.callback(url, provider)) {
                            exchangeQuark(view); return true
                        }
                        if (!OpenListAuth.atTool(url)) {
                            val next = runCatching {
                                oauthSession!!.providerNavigation(url, CookieManager.getInstance().getCookie(OpenListAuth.ORIGIN).orEmpty())
                            }.getOrNull()
                            if (next == null) { rejectAuthorization(); return true }
                            if (next != url) { view.loadUrl(next); return true }
                        }
                    }
                    return false
                }
                override fun doUpdateVisitedHistory(view: WebView, url: String, reload: Boolean) {
                    if (oauth) consumeOAuth(url)
                }
                override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                    if (oauthRejected) { view.stopLoading(); return }
                    status = if (url == "about:blank" && finished.get()) "Connecting…" else "Loading…"
                    editing = false; editor = null
                    if (oauth && provider == CloudDrive.QUARK && OpenListAuth.quarkBrokerCallback(url)) {
                        if (runCatching { oauthSession!!.providerNavigation(url, "") }.isFailure) {
                            view.stopLoading(); rejectAuthorization(); return
                        }
                    }
                    if (oauth && OpenListAuth.callback(url, provider)) {
                        val session = oauthSession!!
                        // Programmatic/redirect loads are not guaranteed to call shouldOverride.
                        if (!session.matchesCallback(url) && !session.allowCallback(url)) {
                            if (BuildConfig.DEBUG) debugOAuthProbe = session.callbackDiagnostics(url).put("stage", "callback_start_rejected")
                            view.stopLoading(); rejectAuthorization(); return
                        }
                        if (BuildConfig.DEBUG) debugOAuthProbe = session.callbackDiagnostics(url).put("stage", "callback_started")
                        if (provider == CloudDrive.QUARK) { exchangeQuark(view); return }
                    }
                    if (oauth) consumeOAuth(url)
                }
                override fun onPageFinished(view: WebView, url: String) {
                    if (oauthRejected) return
                    if (BuildConfig.DEBUG && url != "about:blank" && debugOAuthProbe.optString("stage") !in
                        setOf("callback_rejected", "callback_start_rejected", "result_rejected")) debugOAuthProbe = JSONObject().put("stage", "page")
                        .put("host", runCatching { java.net.URI(url).host }.getOrNull())
                    if (!oauthRejected && !finished.get()) status = ""
                    if (oauth && !consumeOAuth(url) && !finished.get()) {
                        if (OpenListAuth.requestPage(url, provider)) launchOAuth(view)
                        else if (OpenListAuth.atTool(url)) recoverOAuth(view)
                    }
                    checkSession()
                }
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
                    checkSession()
                    if (oauth && OpenListAuth.atTool(view.url.orEmpty())) return@post
                    val canvas = Canvas(bitmap!!); canvas.drawColor(android.graphics.Color.WHITE)
                    val scale = geometry?.density ?: 1f
                    canvas.save(); canvas.scale(1f / scale, 1f / scale)
                    viewport?.draw(canvas); canvas.restore()
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
        if (oauth) {
            web?.let { view -> if (!consumeOAuth(view.url.orEmpty())) recoverOAuth(view) }; return
        }
        val cookie = CookieManager.getInstance().getCookie(start).orEmpty()
        val names = cookie.split(';').map { it.substringBefore('=').trim() }.toSet()
        val valid = if (provider == CloudDrive.P115) names.containsAll(listOf("UID", "CID", "SEID")) else "BDUSS" in names
        if (valid && CloudHttp.validCookie(cookie) && finished.compareAndSet(false, true)) {
            status = "Connecting…"
            if (!connected(cookie)) finished.set(false)
        }
    }

    private fun rejectAuthorization() {
        oauthRejected = true
        status = "Authorization failed. Try again."
    }

    private fun exchangeQuark(view: WebView) {
        val session = oauthSession ?: return
        val nonce = session.quarkNonce ?: return
        if (!finished.compareAndSet(false, true)) return
        view.stopLoading(); view.loadUrl("about:blank"); frameBytes = ByteArray(0)
        status = "Connecting…"
        Thread({
            try {
                val data = OpenListQuarkExchange.exchange(nonce)
                val fields = data.optJSONObject("data") ?: JSONObject()
                debugOAuthProbe = JSONObject().put("stage", "exchange").put("code", data.optInt("code", -1))
                    .put("access_present", fields.optString("accessToken").isNotEmpty())
                    .put("refresh_present", fields.optString("refreshToken").isNotEmpty())
                    .put("app_id_present", fields.optString("appId").isNotEmpty())
                    .put("sign_key_present", fields.optString("signKey").isNotEmpty())
                val credential = session.quarkCredential(data)
                handler.post {
                    if (closed || web !== view || oauthSession !== session) return@post
                    if (credential == null) { rejectAuthorization(); finished.set(false) }
                    else if (authorized?.invoke(credential) != true) finished.set(false)
                }
            } catch (_: Exception) {
                handler.post { if (!closed && web === view && oauthSession === session) {
                    rejectAuthorization(); finished.set(false)
                } }
            }
        }, "QuarkPublicOAuth").start()
    }

    private fun consumeOAuth(url: String): Boolean {
        if (!oauth || closed || oauthRejected || finished.get() || !OpenListAuth.atTool(url)) return false
        val fragment = runCatching { java.net.URI(url).fragment }.getOrNull()
        if (fragment.isNullOrEmpty()) return false
        val credential = oauthSession?.credential(url)
        // Do not render the returned token fields in a VR frame.
        web?.stopLoading(); web?.loadUrl("about:blank"); frameBytes = ByteArray(0)
        if (credential == null) {
            if (BuildConfig.DEBUG) debugOAuthProbe = OpenListAuth.resultDiagnostics(url, provider)
                .put("stage", "result_rejected").put("session_returned", oauthSession?.awaitingTokens == true)
            rejectAuthorization(); return true
        }
        if (finished.compareAndSet(false, true)) {
            status = "Connecting…"
            if (authorized?.invoke(credential) != true) finished.set(false)
        }
        return true
    }

    private fun launchOAuth(view: WebView) {
        // This response is JSON from APIpage, not a configurable webpage or QR chooser.
        view.evaluateJavascript("document.body ? document.body.innerText : ''") { raw ->
            if (closed || web !== view || !OpenListAuth.requestPage(view.url.orEmpty(), provider)) return@evaluateJavascript
            try {
                require(raw.length <= 90000)
                val body = org.json.JSONTokener(raw).nextValue() as String
                val target = JSONObject(body).getString("text")
                require(!OpenListAuth.atTool(target) && OpenListAuth.allowed(target, provider, true))
                val next = oauthSession!!.providerNavigation(target,
                    CookieManager.getInstance().getCookie(OpenListAuth.ORIGIN).orEmpty())
                view.loadUrl(next)
            } catch (_: Exception) { rejectAuthorization() }
        }
    }
    /** APIpage may clear its fragment before the page-finished callback. Read only the
     * selected result fields, after the same session's state-checked provider callback. */
    private fun recoverOAuth(view: WebView) {
        if (closed || oauthRejected || finished.get() || oauthSession?.awaitingTokens != true || !OpenListAuth.atTool(view.url.orEmpty()) ||
            !recoveringOAuth.compareAndSet(false, true)) return
        view.evaluateJavascript(OpenListAuth.readResultScript(provider)) { raw ->
            recoveringOAuth.set(false)
            if (raw.length > 90000) return@evaluateJavascript
            if (closed || finished.get() || web !== view || !OpenListAuth.atTool(view.url.orEmpty())) return@evaluateJavascript
            val data = runCatching { (org.json.JSONTokener(raw).nextValue() as? String)?.takeIf { it.isNotEmpty() }?.let(::JSONObject) }.getOrNull() ?: return@evaluateJavascript
            val credential = oauthSession?.recovered(data)
            if (credential == null) {
                if (BuildConfig.DEBUG) debugOAuthProbe = OpenListAuth.dataDiagnostics(data, provider).put("stage", "result_fields_rejected")
                return@evaluateJavascript
            }
            view.stopLoading(); view.loadUrl("about:blank"); frameBytes = ByteArray(0)
            if (finished.compareAndSet(false, true)) {
                status = "Connecting…"; if (authorized?.invoke(credential) != true) finished.set(false)
            }
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
                        x.coerceIn(0f, 1f) * view.width, y.coerceIn(0f, 1f) * view.height, 0)
                    try { view.dispatchTouchEvent(event) } finally { event.recycle() }
                    if (action in setOf("up", "cancel")) touchActive = false
                    if (action == "up") handler.postDelayed({
                        if (!closed && web === view && !touchActive) view.captureEditor()
                    }, 100)
                }
                "scroll" -> view.scrollBy(0, (y.coerceIn(-1f, 1f) * 160 * (geometry?.density ?: 1f)).toInt())
                "scroll_to" -> view.scrollTo(view.scrollX, (y.coerceIn(0f, 1f) * (view.documentHeight() - view.height)).toInt())
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
                "reload" -> { oauthRejected = false; debugOAuthProbe = JSONObject(); finished.set(false); if (oauth) { oauthSession = OpenListOAuthSession(provider); view.loadUrl(start) } else view.reload() }
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
        val layout = geometry ?: return
        scrollY = layout.logical(view.scrollY)
        scrollRange = layout.logical(view.documentHeight()).coerceAtLeast(HEIGHT)
    }
    /** Debug-only geometry/types, never reads input values, page HTML, cookies or storage. */
    private fun inspectInputs(view: LoginView) {
        view.evaluateJavascript("""JSON.stringify((function(){var result={width:innerWidth,height:innerHeight,dpr:devicePixelRatio,inputs:[],buttons:[]};function scan(doc,ox,oy){Array.from(doc.querySelectorAll('input,button,iframe')).slice(0,48).forEach(function(e){var r=e.getBoundingClientRect();if(r.width<=0||r.height<=0)return;if(e.tagName==='IFRAME'){try{scan(e.contentDocument,ox+r.x,oy+r.y)}catch(_){}}else{var list=e.tagName==='BUTTON'?result.buttons:result.inputs;if(list.length<24)list.push({type:e.type,x:(ox+r.x)/innerWidth,y:(oy+r.y)/innerHeight,w:r.width/innerWidth,h:r.height/innerHeight})}})}scan(document,0,0);return result})())""") { raw ->
            if (closed || web !== view) return@evaluateJavascript
            debugInputs = runCatching { JSONObject(org.json.JSONArray("[$raw]").getString(0)) }.getOrElse { JSONObject() }
                .put("view_width", view.width).put("view_height", view.height)
                .put("density_dpi", view.resources.configuration.densityDpi).put("text_zoom", view.settings.textZoom)
        }
    }
    private fun detach() {
        web?.let { view ->
            viewport?.let { (it.parent as? ViewGroup)?.removeView(it) }
            view.stopLoading(); view.clearHistory(); view.clearCache(true); view.destroy()
        }
        web = null; viewport = null; geometry = null; editor = null; editing = false; touchActive = false; frameBytes = ByteArray(0)
        bitmap?.recycle(); bitmap = null
    }
    fun close() {
        closed = true; frameBytes = ByteArray(0)
        handler.post { detach(); CookieManager.getInstance().removeAllCookies { CookieManager.getInstance().flush() }; WebStorage.getInstance().deleteAllData() }
    }
}
