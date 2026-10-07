package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.app.AlertDialog
import android.app.Dialog
import android.graphics.Color
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.view.WindowManager
import android.widget.*
import org.json.JSONObject
import java.util.concurrent.Executors

/** Two direct providers, plus an optional read-only LAN WebDAV endpoint. */
class CloudAccountsActivity : Activity() {
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var body: LinearLayout
    private lateinit var status: TextView
    private var loginDialog: Dialog? = null
    private var screen = 0
    private var busy = false
    private fun tr(en: String, zh: String) = UiLanguage.tr(this, en, zh)

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        accounts()
    }
    private fun page(title: String) {
        screen++
        val scroll = ScrollView(this)
        body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(32, 24, 32, 32) }
        scroll.addView(body); setContentView(scroll)
        body.addView(TextView(this).apply { text = title; textSize = 25f; setPadding(0, 0, 0, 14) })
        status = TextView(this).apply { textSize = 16f; setTextColor(Color.rgb(170, 70, 55)) }
        body.addView(status)
    }
    private fun button(label: String, gated: Boolean = true, action: () -> Unit) = Button(this).also {
        it.text = label; it.minHeight = 56
        it.setOnClickListener { if (!gated || !busy) action() }; body.addView(it)
    }
    private fun <T> task(work: () -> T, done: (T) -> Unit) {
        if (busy) return
        busy = true
        val revision = screen
        status.text = tr("Connecting…", "正在连接…")
        worker.execute {
            val result = runCatching { CloudLibrary.start(applicationContext); work() }
            runOnUiThread {
                busy = false
                if (isFinishing || isDestroyed || revision != screen) return@runOnUiThread
                status.text = ""
                result.onSuccess(done).onFailure {
                    status.text = if (it is CloudFailure && it.reason == "cloud_login_required") tr("Sign in again.", "请重新登录。")
                        else tr("Unable to connect. Please retry.", "连接失败，请重试。")
                }
            }
        }
    }
    private fun accounts() {
        page(tr("Cloud accounts", "网盘账号"))
        task({ CloudLibrary.accounts() }) { list ->
            for (i in 0 until list.length()) {
                val account = list.getJSONObject(i)
                button(account.getString("name") + "  ›") { edit(account.getString("provider"), account) }
            }
            button("+ 115") { edit(CloudDrive.P115, null) }
            button(tr("+ Baidu Netdisk", "+ 百度网盘")) { edit(CloudDrive.BAIDU, null) }
            button("WebDAV  ›") { webdav() }
            button(tr("Open source licenses", "开源许可")) {
                val text = assets.open("p115rsacipher/NOTICE.md").bufferedReader().use { it.readText() } + "\n\n" +
                    assets.open("p115rsacipher/LICENSE").bufferedReader().use { it.readText() }
                AlertDialog.Builder(this).setMessage(text).setPositiveButton(tr("Close", "关闭"), null).show()
            }
        }
        button(tr("Return to player", "返回播放器"), false) { finish() }
    }
    private fun edit(provider: String, existing: JSONObject?) {
        page(CloudLibrary.providers.getValue(provider))
        val name = EditText(this).apply {
            hint = tr("Name", "名称"); setText(existing?.getString("name") ?: CloudLibrary.providers.getValue(provider))
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            isSaveEnabled = false; importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        }
        body.addView(name)
        fun connect(cookie: String) {
            val title = name.text.toString().trim().ifBlank { CloudLibrary.providers.getValue(provider) }
            task({ CloudLibrary.connect(provider, title, cookie, existing?.getString("id")) }) { accounts() }
        }
        button(tr("Sign in on website", "网页登录")) {
            runCatching { CloudWebLoginDialog(this, provider, ::connect).also { it.show() } }
                .onSuccess { loginDialog = it }
                .onFailure { status.text = tr("Web sign-in is unavailable on this device.", "此设备暂时无法打开网页登录。") }
        }
        if (provider == CloudDrive.P115) button(tr("Account and password", "账号密码登录")) {
            loginDialog = Cloud115LoginDialog(this, ::connect).also { it.show() }
        }
        if (existing != null) button(tr("Remove account", "移除账号")) {
            AlertDialog.Builder(this).setMessage(tr("Remove this account?", "移除此账号？"))
                .setNegativeButton(tr("Cancel", "取消"), null)
                .setPositiveButton(tr("Remove", "移除")) { _, _ -> task({ CloudLibrary.remove(existing.getString("id")) }) { accounts() } }.show()
        }
        button(tr("Back", "返回")) { accounts() }
    }
    private fun webdav() {
        page("WebDAV")
        task({ CloudWebDav.status(applicationContext) }) { state ->
            body.addView(TextView(this).apply {
                textSize = 18f; setTextIsSelectable(true)
                text = if (state.enabled) state.addresses.joinToString("\n").ifEmpty { tr("Wi-Fi unavailable", "未连接局域网") } else tr("Off", "未开启")
            })
            if (state.enabled) {
                body.addView(TextView(this).apply { text = tr("Username: quest", "用户名：quest"); textSize = 18f })
                val password = TextView(this).apply { text = "••••••••••••"; textSize = 18f; setTextIsSelectable(true) }
                body.addView(password)
                button(tr("Show password", "显示密码")) { password.text = state.password }
                body.addView(TextView(this).apply { text = tr("Local network · Read only · Keep the player running", "局域网 · 只读 · 保持播放器运行") })
                button(tr("Turn off", "关闭服务")) { task({ CloudWebDav.setEnabled(applicationContext, false) }) { webdav() } }
                button(tr("Reset password", "重置密码")) { task({ CloudWebDav.resetPassword(applicationContext) }) { webdav() } }
            } else button(tr("Turn on", "开启服务")) { task({ CloudWebDav.setEnabled(applicationContext, true) }) { webdav() } }
            button(tr("Back", "返回")) { accounts() }
        }
    }
    override fun onDestroy() {
        loginDialog?.dismiss(); loginDialog = null
        worker.shutdownNow()
        super.onDestroy()
    }
}
