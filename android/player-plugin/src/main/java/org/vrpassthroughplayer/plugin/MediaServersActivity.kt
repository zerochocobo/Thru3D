package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.app.AlertDialog
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.view.WindowManager
import android.widget.*
import java.util.UUID
import java.util.concurrent.Executors

/** Native text entry keeps server secrets out of Godot and permits the system paste menu. */
class MediaServersActivity : NativePanelActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var body: LinearLayout
    private lateinit var status: TextView
    @Volatile private var active: MediaServerHttp? = null
    private var discovery: MediaServerDiscovery? = null
    private var busy = false
    private var revision = 0
    private fun tr(en: String, zh: String) = UiLanguage.tr(this, en, zh)
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        if (isFinishing) return
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE); accounts()
    }
    private fun page(title: String) {
        discovery?.close(); discovery = null
        revision++
        body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(32, 24, 32, 32) }
        setContentView(ScrollView(this).apply { addView(body) })
        body.addView(TextView(this).apply { text = title; textSize = 25f })
        status = TextView(this).apply { textSize = 17f }; body.addView(status)
    }
    private fun button(text: String, action: () -> Unit) {
        body.addView(Button(this).apply { this.text = text; setOnClickListener { if (!busy) action() } })
    }
    private fun task(work: () -> Unit, done: () -> Unit) {
        if (busy) return
        busy = true; status.text = tr("Connecting…", "正在连接…"); val rev = revision
        worker.execute {
            val result = runCatching(work)
            runOnUiThread {
                busy = false
                if (isDestroyed || isFinishing || rev != revision) return@runOnUiThread
                result.onSuccess { status.text = ""; done() }.onFailure {
                    status.text = if (it is MediaServerFailure && it.code == "Server authentication required")
                        tr("Check credentials", "请检查登录凭据") else if (it is MediaServerFailure && it.code == "Wrong server type")
                        tr("Check server type", "请检查服务器类型") else tr("Check the address and connection", "请检查地址和连接")
                }
            }
        }
    }
    private fun accounts() {
        page(tr("Media servers", "媒体服务器"))
        runCatching { MediaServerStore.accounts(this) }.onSuccess { list ->
            list.forEach { account -> button(account.name + "  ›") { edit(account) } }
            button(tr("Search local network", "搜索局域网")) { search() }
            button(tr("Add manually", "手动添加")) { chooseType() }
        }.onFailure { status.text = tr("Unable to read saved servers", "无法读取已保存的服务器") }
        button(tr("Return to player", "返回播放器")) { finish() }
    }
    private fun providerName(provider: String) = mapOf("stash" to "Stash", "emby" to "Emby", "jellyfin" to "Jellyfin", "xbvr" to "XBVR")[provider] ?: provider
    private fun chooseType(address: String = "", name: String = "") {
        val types = listOf("emby", "jellyfin", "stash", "xbvr")
        AlertDialog.Builder(this).setTitle(tr("Server type", "服务器类型"))
            .setItems(types.map(::providerName).toTypedArray()) { _, index -> edit(null, types[index], address, name) }.show()
    }
    private fun search() {
        page(tr("Search local network", "搜索局域网"))
        val manager = getSystemService(android.content.Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        val network = manager.activeNetwork
        val caps = network?.let(manager::getNetworkCapabilities)
        val address = network?.let(manager::getLinkProperties)?.linkAddresses?.firstOrNull {
            it.address is java.net.Inet4Address && it.address.isSiteLocalAddress
        }
        if (network == null || caps?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) != true || address == null) {
            status.text = tr("Connect to Wi-Fi", "请连接 Wi-Fi")
            button(tr("Add manually", "手动添加")) { chooseType() }
            button(tr("Back", "返回")) { accounts() }
            return
        }
        val subnet = MediaServerDiscovery.Subnet(address.address.hostAddress!!, address.prefixLength)
        val scanner = MediaServerDiscovery { network.openConnection(it) as java.net.HttpURLConnection }
        discovery = scanner
        val rev = revision
        status.text = tr("Searching…", "正在搜索…")
        button(tr("Add manually", "手动添加")) { scanner.close(); chooseType() }
        button(tr("Back", "返回")) { accounts() }
        val results = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }; body.addView(results)
        val lock = (applicationContext.getSystemService(android.content.Context.WIFI_SERVICE) as android.net.wifi.WifiManager).createMulticastLock("QuestServerDiscovery")
        worker.execute {
            val count = runCatching {
                lock.acquire()
                scanner.scan(subnet) { found -> runOnUiThread {
                    if (revision != rev || isDestroyed || isFinishing || manager.activeNetwork != network) return@runOnUiThread
                    results.addView(Button(this).apply {
                        val label = found.name.ifBlank { tr("Server", "服务器") }
                        val type = providerName(found.provider)
                        text = listOf(if (type.isBlank() || label == type) label else "$label · $type", found.address).joinToString("\n")
                        setOnClickListener {
                            if (manager.activeNetwork != network) { search(); return@setOnClickListener }
                            scanner.close()
                            if (found.provider.isEmpty()) chooseType(found.address, found.name)
                            else edit(null, found.provider, found.address, found.name)
                        }
                    })
                } }
            }.getOrNull()
            scanner.close()
            if (lock.isHeld) lock.release()
            runOnUiThread {
                if (revision != rev || isDestroyed || isFinishing) return@runOnUiThread
                status.text = when {
                    manager.activeNetwork != network -> tr("Network changed. Search again.", "网络已切换，请重新搜索")
                    count == null -> tr("Search unavailable", "搜索暂不可用")
                    count == 0 -> tr("No servers found", "未发现服务器")
                    else -> tr("Select a server", "选择服务器")
                } + if (subnet.limited) tr(" · Nearby addresses only", " · 已搜索附近地址") else ""
                button(tr("Search again", "重新搜索")) { search() }
            }
        }
    }
    private fun edit(old: MediaServerAccount?, provider: String = old?.provider ?: "stash", suggestedAddress: String = "", suggestedName: String = "") {
        page(providerName(provider))
        fun field(hint: String, value: String, secret: Boolean = false) = EditText(this).apply {
            this.hint = hint; setText(value); setSingleLine(true)
            inputType = InputType.TYPE_CLASS_TEXT or if (secret) InputType.TYPE_TEXT_VARIATION_PASSWORD else InputType.TYPE_TEXT_VARIATION_URI
            isSaveEnabled = false; importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
            body.addView(this)
        }
        val name = field(tr("Name", "名称"), old?.name ?: suggestedName.ifBlank { providerName(provider) })
        val address = field(tr("Server address", "服务器地址"), old?.base ?: suggestedAddress.ifBlank { "http://" })
        val username = if (provider != "stash") field(tr("Username", "用户名"), old?.username ?: "") else null
        val secretName = if (provider == "stash") "API Key" else tr("Password", "密码")
        val key = field(secretName + if (old?.key?.isNotEmpty() == true) tr(" (blank keeps saved login)", "（留空保留登录）") else "", "", true)
        body.addView(CheckBox(this).apply { text = tr("Show", "显示"); setOnCheckedChangeListener { _, checked ->
            key.transformationMethod = if (checked) null else android.text.method.PasswordTransformationMethod.getInstance()
        } })
        var tested: MediaServerAccount? = null
        fun value(): MediaServerAccount = MediaServerAccount(old?.id ?: UUID.randomUUID().toString(), name.text.toString().trim().take(80).ifBlank { providerName(provider) },
            MediaServerAccount.address(address.text.toString()), "", provider, old?.userId ?: "", username?.text?.toString()?.trim() ?: "")
        button(tr("Test and save", "测试并保存")) {
            val candidate = runCatching { value() }.getOrElse { status.text = tr("Invalid address", "地址无效"); return@button }
            val enteredSecret = key.text.toString()
            task({
                val sameLogin = old != null && old.base == candidate.base && old.username == candidate.username && enteredSecret.isEmpty()
                val authenticated = if (provider in setOf("emby", "jellyfin")) {
                    if (sameLogin) candidate.copy(key = old!!.key) else MediaServerHttp(candidate).use { http ->
                        active = http; EmbyClient(candidate, http).login(candidate.username, enteredSecret)
                    }
                } else candidate.copy(key = if (sameLogin) old!!.key else enteredSecret)
                MediaServerHttp(authenticated).use { http -> active = http; mediaClient(authenticated, http).probe() }
                active = null
                if (!isFinishing && !isDestroyed) { MediaServerStore.save(applicationContext, authenticated); tested = authenticated }
            }) { if (tested != null) accounts() }
        }
        if (old != null) button(tr("Remove server", "移除服务器")) {
            AlertDialog.Builder(this).setMessage(tr("Remove this server?", "移除此服务器？"))
                .setNegativeButton(tr("Cancel", "取消"), null).setPositiveButton(tr("Remove", "移除")) { _, _ ->
                    task({ MediaServerStore.remove(applicationContext, old.id) }) { accounts() }
                }.show()
        }
        button(tr("Back", "返回")) { accounts() }
    }
    override fun onStop() { discovery?.close(); super.onStop() }
    override fun onDestroy() { discovery?.close(); active?.close(); worker.shutdownNow(); super.onDestroy() }
}
