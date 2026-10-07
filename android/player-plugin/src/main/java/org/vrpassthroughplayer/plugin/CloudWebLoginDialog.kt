package org.vrpassthroughplayer.plugin

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.graphics.Bitmap
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

/** The provider handles passwords/captcha. No JS bridge or page-script credential extraction. */
@SuppressLint("SetJavaScriptEnabled")
internal class CloudWebLoginDialog(activity: Activity, provider: String, connected: (String) -> Unit) :
    Dialog(activity, android.R.style.Theme_Material_Light_NoActionBar) {
    private val web = WebView(activity)
    private var closed = false
    private fun tr(en: String, zh: String) = UiLanguage.tr(context, en, zh)

    init {
        val start = if (provider == CloudDrive.P115) "https://115.com/" else "https://pan.baidu.com/disk/main"
        val cookies = CookieManager.getInstance()
        val body = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
        val status = TextView(activity).apply { setPadding(20, 8, 20, 8) }
        val progress = ProgressBar(activity, null, android.R.attr.progressBarStyleHorizontal)
        body.addView(progress, LinearLayout.LayoutParams(-1, 4))
        body.addView(status)
        body.addView(web, LinearLayout.LayoutParams(-1, 0, 1f))
        val buttons = LinearLayout(activity)
        body.addView(buttons)
        fun finishSignIn(): Boolean {
            val cookie = cookies.getCookie(start).orEmpty()
            val names = cookie.split(';').map { it.substringBefore('=').trim() }.toSet()
            val valid = if (provider == CloudDrive.P115) names.containsAll(listOf("UID", "CID", "SEID")) else "BDUSS" in names
            if (closed || !valid || !CloudHttp.validCookie(cookie)) return false
            // Capture as soon as the login session exists, even if the provider's SPA
            // keeps loading. The caller validates it through the directory API.
            connected(cookie); dismiss()
            return true
        }
        val sessionCheck = object : Runnable {
            override fun run() {
                if (!closed && !finishSignIn()) web.postDelayed(this, 1000)
            }
        }
        buttons.addView(Button(activity).apply {
            text = tr("Back", "后退")
            setOnClickListener { if (web.canGoBack()) web.goBack() }
        })
        buttons.addView(Button(activity).apply {
            text = tr("Reload", "刷新")
            setOnClickListener { web.reload() }
        })
        buttons.addView(Button(activity).apply {
            text = tr("Finish sign-in", "完成登录")
            setOnClickListener {
                if (!finishSignIn()) status.text = tr("Complete sign-in on the page first.", "请先在网页中完成登录。")
            }
        }, LinearLayout.LayoutParams(0, -2, 1f))
        buttons.addView(Button(activity).apply { text = tr("Cancel", "取消"); setOnClickListener { dismiss() } })
        setContentView(body)
        window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        WebView.setWebContentsDebuggingEnabled(false)
        web.settings.apply {
            javaScriptEnabled = true; domStorageEnabled = true
            allowFileAccess = false; allowContentAccess = false
            mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
            cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
            userAgentString = CloudHttp.UA
            useWideViewPort = true; loadWithOverviewMode = true
            setSupportZoom(true); builtInZoomControls = true; displayZoomControls = false
            setSupportMultipleWindows(false)
        }
        cookies.setAcceptCookie(true)
        // Provider login widgets use cross-origin frames. This isolated session is
        // erased on exit; it does not read or alter the system browser's cookies.
        cookies.setAcceptThirdPartyCookies(web, true)
        web.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView, value: Int) {
                progress.progress = value
                progress.visibility = if (value == 100) View.GONE else View.VISIBLE
            }
        }
        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                return !CloudWebNavigation.allowed(request.url.toString(), provider, request.isForMainFrame)
            }
            override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                status.text = ""
            }
            override fun onPageFinished(view: WebView, url: String) {
                if (!closed) finishSignIn()
            }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) {
                    progress.visibility = View.GONE
                    status.text = tr("Page unavailable. Try reloading.", "网页加载失败，请刷新。")
                }
            }
        }
        setOnShowListener {
            window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
            // Do not silently reuse another account's browser session.
            cookies.removeAllCookies { if (!closed) {
                WebStorage.getInstance().deleteAllData(); web.loadUrl(start)
                web.postDelayed(sessionCheck, 1000)
            } }
        }
        setOnDismissListener {
            web.removeCallbacks(sessionCheck)
            closed = true; web.stopLoading(); web.loadUrl("about:blank")
            (web.parent as? ViewGroup)?.removeView(web)
            web.clearCache(true); web.clearHistory(); web.destroy()
            cookies.removeAllCookies { cookies.flush() }; WebStorage.getInstance().deleteAllData()
        }
    }
}
