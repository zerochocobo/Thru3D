package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.net.Inet4Address
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** In-process account workflows, independent of Android windows and the Godot render loop.
 * A snapshot survives focus loss; cancelled sessions cannot commit late authentication results. */
internal class AccountManager(private val host: () -> Activity?) {
    private val ids = AtomicInteger()
    private val worker = Executors.newFixedThreadPool(2) { Thread(it, "PlayerAccount") }
    @Volatile private var session: Session? = null
    @Volatile private var closed = false
    private fun context(): Context = host()?.applicationContext ?: error("Activity unavailable")

    private class Session(val id: Int, val kind: String, val provider: String, val accountId: String) : AccountSessionGuard() {
        val inputs = listOf("name", "base", "username", "password", "sms").associateWith { AccountInput() }
        var state = "form"
        var error = ""
        var busy = false
        var revision = 0
        var old: MediaServerAccount? = null
        var sms: Cloud115Auth.Result.Sms? = null
        var smsSent = false
        var nextSmsAt = 0L
        var challenge: Cloud115Auth.Challenge? = null
        var challengeVersion = 0
        var answer: Cloud115Auth.Answer? = null
        var retry = "password"
        var result = JSONObject()
        var auth: Cloud115Auth? = null
        @Volatile var http: MediaServerHttp? = null
        @Volatile var discovery: MediaServerDiscovery? = null
        var web: InAppWebLogin? = null
        fun value(key: String) = inputs.getValue(key).text()
        fun set(key: String, text: String) { inputs.getValue(key).clear(); inputs.getValue(key).append(text) }
    }

    @Synchronized fun open(kind: String, provider: String, accountId: String, raw: String): Int {
        if (closed || kind !in setOf("cloud", "server", "dav", "discover") || raw.length > 4096) return -1
        if (kind == "cloud" && provider !in CloudDrive.PROVIDERS) return -1
        if (kind == "server" && provider !in setOf("emby", "jellyfin", "stash", "xbvr")) return -1
        cancel(session?.id ?: 0)
        val s = Session(ids.incrementAndGet(), kind, provider, accountId)
        session = s
        try {
            val app = context()
            val data = if (raw.isEmpty()) JSONObject() else JSONObject(raw)
            if (kind == "server") {
                s.old = if (accountId.isEmpty()) null else MediaServerStore.get(app, accountId)
                require(s.old == null || s.old!!.provider == provider)
                s.set("name", s.old?.name ?: data.optString("name", providerName(provider)))
                s.set("base", s.old?.base ?: data.optString("base", "http://"))
                s.set("username", s.old?.username ?: "")
            } else if (kind == "cloud") {
                CloudLibrary.start(app)
                val all = CloudLibrary.accounts()
                val old = (0 until all.length()).map(all::getJSONObject).find { it.getString("id") == accountId }
                require(accountId.isEmpty() || old?.optString("provider") == provider)
                s.set("name", old?.getString("name") ?: CloudDrive.PROVIDERS.getValue(provider))
                s.auth = if (provider == CloudDrive.P115) Cloud115Auth() else null
            }
            if (kind == "dav") task(s) { dav(s, app) }
            if (kind == "discover") task(s) { discover(s, app) }
        } catch (_: Exception) { s.error = "Account settings unavailable"; s.revision++ }
        return s.id
    }

    fun accounts(kind: String): String = try {
        val app = context()
        if (kind == "cloud") { CloudLibrary.start(app); CloudLibrary.accounts().toString() }
        else JSONArray().apply { MediaServerStore.accounts(app).forEach { put(it.json().put("username", it.username).put("has_password", it.key.isNotEmpty())) } }.toString()
    } catch (_: Exception) { "null" }

    fun snapshot(id: Int): String {
        val s = session?.takeIf { it.id == id && !it.cancelled } ?: return "{}"
        synchronized(s) {
            val fields = JSONObject()
            for ((name, input) in s.inputs) fields.put(name, if (name in setOf("password", "sms")) "" else input.text())
            val value = JSONObject().put("id", id).put("state", s.state).put("busy", s.busy).put("error", s.error)
                .put("revision", s.revision).put("fields", fields).put("password_length", s.inputs.getValue("password").length)
                .put("sms_length", s.inputs.getValue("sms").length).put("sms_sent", s.smsSent)
                .put("challenge_revision", s.challengeVersion)
                .put("sms_wait", ((s.nextSmsAt - SystemClock.elapsedRealtime() + 999) / 1000).coerceAtLeast(0))
                .put("has_password", s.old?.key?.isNotEmpty() == true).put("result", s.result)
                .put("editing_account", s.accountId.isNotEmpty())
            s.challenge?.let { c ->
                value.put("prompt", android.util.Base64.encodeToString(c.prompt, android.util.Base64.NO_WRAP))
                    .put("choices", android.util.Base64.encodeToString(c.choices, android.util.Base64.NO_WRAP))
            }
            s.web?.let { value.put("web", it.snapshot()) }
            return value.toString()
        }
    }

    fun input(id: Int, field: String, action: String, text: String) {
        val s = session?.takeIf { it.id == id } ?: return
        if (action == "paste") {
            val activity = host() ?: return
            synchronized(s) {
                if (s.cancelled || s.busy || field !in s.inputs) return
                s.busy = true; s.revision++
            }
            activity.runOnUiThread {
                try {
                    val clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as? android.content.ClipboardManager
                    val value = clipboard?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()?.trimEnd('\r', '\n').orEmpty()
                    commit(s) {
                        if (value.length > 2048) s.error = "Input too long"
                        else if (value.isNotEmpty() && value.none { it == '\u0000' || it == '\n' || it == '\r' }) {
                            s.inputs.getValue(field).clear(); s.inputs.getValue(field).append(value)
                        }
                    }
                } catch (_: Exception) { synchronized(s) { if (!s.cancelled) s.error = "Account settings unavailable" } }
                finally { synchronized(s) { s.busy = false; s.revision++ } }
            }
            return
        }
        synchronized(s) {
            if (s.cancelled || s.busy || text.length > 4096) return
            val input = s.inputs[field] ?: return
            when (action) {
                "append" -> input.append(text)
                "backspace" -> input.backspace()
                "clear" -> input.clear()
                "replace" -> if (text.none { it == '\u0000' || it == '\n' || it == '\r' }) { input.clear(); input.append(text) }
            }
            s.revision++
        }
    }

    fun action(id: Int, action: String, raw: String) {
        val s = session?.takeIf { it.id == id && !it.cancelled } ?: return
        if (raw.length > 4096) return
        val data = runCatching { if (raw.isEmpty()) JSONObject() else JSONObject(raw) }.getOrNull() ?: return
        if (action == "web") {
            synchronized(s) {
                if (s.busy || s.kind != "cloud") return
                s.error = ""; s.state = "web"; s.revision++
                if (s.web == null) s.web = InAppWebLogin(host, s.provider) { cookie ->
                    task(s) { connect(s, cookie) }
                }
                s.web!!.open()
            }
            return
        }
        task(s) {
            val app = context()
            when (action) {
                "save_server" -> { require(s.kind == "server"); saveServer(s, app) }
                "rename" -> { require(s.kind == "cloud" && s.accountId.isNotEmpty()); commit(s) { CloudLibrary.rename(s.accountId, s.value("name")); s.state = "done" } }
                "password", "send_sms", "verify_sms", "captcha", "answer" -> {
                    require(s.kind == "cloud" && s.provider == CloudDrive.P115)
                    login(s, action, data)
                }
                "dav_enable" -> { require(s.kind == "dav"); commit(s) { CloudWebDav.setEnabled(app, data.optBoolean("enabled")) }; dav(s, app) }
                "dav_reset" -> { require(s.kind == "dav"); commit(s) { CloudWebDav.resetPassword(app) }; dav(s, app) }
                "dav_show" -> { require(s.kind == "dav"); val state = CloudWebDav.status(app); commit(s) { s.result.put("password", state.password); s.revision++ } }
                else -> error("Invalid action")
            }
        }
    }

    private fun task(s: Session, work: () -> Unit): Boolean {
        synchronized(s) {
            if (closed || s.cancelled || s.busy) return false
            s.busy = true; s.error = ""; s.revision++
        }
        try { worker.execute {
            if (s.cancelled || closed) return@execute
            try { work() } catch (e: Exception) {
                synchronized(s) { if (!s.cancelled) {
                    s.error = when (e) {
                        is MediaServerFailure -> e.code
                        is CloudFailure -> if (e.reason == "cloud_login_required") "Sign in again." else "Cloud connection failed"
                        else -> "Unable to connect. Please retry."
                    }
                } }
            } finally { synchronized(s) { s.busy = false; s.revision++ } }
        } } catch (_: java.util.concurrent.RejectedExecutionException) {
            synchronized(s) { s.busy = false; s.revision++ }
            return false
        }
        return true
    }

    private fun commit(s: Session, block: () -> Unit) = s.commitSession {
        check(!s.cancelled && session === s && !closed)
        block()
    }

    private fun connect(s: Session, cookie: String) {
        CloudLibrary.connect(s.provider, s.value("name").ifBlank { CloudDrive.PROVIDERS.getValue(s.provider) }, cookie,
            s.accountId.ifEmpty { null }, { block -> commit(s, block) })
        commit(s) { s.state = "done"; s.inputs.values.forEach { it.clear() }; s.challenge = null }
        s.web?.close()
    }

    private fun login(s: Session, action: String, data: JSONObject) {
        val auth = s.auth ?: error("No authentication session")
        if (action == "captcha") { challenge(s, auth); return }
        val operation = if (action == "answer") s.retry else action
        if (action == "answer") {
            val code = data.getString("code")
            require(code.matches(Regex("[0-9]{4}")))
            s.answer = Cloud115Auth.Answer(s.challenge?.sign ?: error("No challenge"), code)
        }
        val result = when (operation) {
            "password" -> {
                val password = s.inputs.getValue("password").copy()
                try { auth.password(s.value("username"), password, s.answer) } finally { password.fill('\u0000') }
            }
            "send_sms" -> {
                check(SystemClock.elapsedRealtime() >= s.nextSmsAt)
                auth.sendSms(s.sms ?: error("No SMS session"), s.answer)
            }
            "verify_sms" -> {
                val sms = s.sms ?: error("No SMS session")
                check(s.smsSent)
                val code = s.value("sms"); require(code.matches(Regex("[0-9]{4,8}")))
                if (sms.twoStep) auth.verifySms(sms, code) else {
                    val password = s.inputs.getValue("password").copy()
                    try { auth.password(s.value("username"), password, s.answer, code) } finally { password.fill('\u0000') }
                }
            }
            else -> error("Invalid login operation")
        }
        when (result) {
            is Cloud115Auth.Result.Connected -> connect(s, result.cookie)
            is Cloud115Auth.Result.Captcha -> { s.retry = operation; challenge(s, auth) }
            is Cloud115Auth.Result.Sms -> commit(s) {
                s.sms = result; s.smsSent = false; s.answer = null; s.challenge = null; s.state = "sms"
                if (result.twoStep) s.inputs.getValue("password").clear()
            }
            is Cloud115Auth.Result.Sent -> commit(s) {
                s.smsSent = true; s.nextSmsAt = SystemClock.elapsedRealtime() + 60000
                s.answer = null; s.challenge = null; s.state = "sms"
            }
            is Cloud115Auth.Result.Rejected -> commit(s) { s.error = "Sign-in declined (%s).".replace("%s", result.code.toString()) }
        }
    }

    private fun challenge(s: Session, auth: Cloud115Auth) {
        val value = auth.challenge()
        // Size checks are repeated by the Godot image decoder before making GPU textures.
        require(value.prompt.size <= 1024 * 1024 && value.choices.size <= 1024 * 1024)
        for (bytes in listOf(value.prompt, value.choices)) {
            val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
            android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            require(bounds.outWidth in 1..2048 && bounds.outHeight in 1..2048)
        }
        commit(s) { s.answer = null; s.challenge = value; s.challengeVersion++; s.state = "captcha" }
    }

    private fun saveServer(s: Session, app: Context) {
        val old = s.old
        val candidate = MediaServerAccount(old?.id ?: UUID.randomUUID().toString(), s.value("name").trim().take(80).ifBlank { providerName(s.provider) },
            MediaServerAccount.address(s.value("base")), "", s.provider, old?.userId ?: "", s.value("username").trim())
        val secret = s.value("password")
        val sameLogin = old != null && old.base == candidate.base && old.username == candidate.username && secret.isEmpty()
        val authenticated = if (s.provider in setOf("emby", "jellyfin")) {
            if (sameLogin) candidate.copy(key = old!!.key) else MediaServerHttp(candidate).use { http ->
                s.http = http; check(!s.cancelled); EmbyClient(candidate, http).login(candidate.username, secret)
            }
        } else candidate.copy(key = if (sameLogin) old!!.key else secret)
        MediaServerHttp(authenticated).use { http -> s.http = http; check(!s.cancelled); mediaClient(authenticated, http).probe() }
        s.http = null
        commit(s) { synchronized(MediaServerStore) {
            check(old == null || MediaServerStore.get(app, old.id) == old)
            MediaServerStore.save(app, authenticated); s.state = "done"; s.inputs.values.forEach { it.clear() }
        } }
    }

    private fun dav(s: Session, app: Context) {
        val value = CloudWebDav.status(app)
        commit(s) { s.state = "dav"; s.result = JSONObject().put("enabled", value.enabled).put("addresses", JSONArray(value.addresses)).put("username", "quest") }
    }

    private fun discover(s: Session, app: Context) {
        val manager = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = manager.activeNetwork ?: throw MediaServerFailure("Connect to Wi-Fi")
        val caps = manager.getNetworkCapabilities(network)
        val address = manager.getLinkProperties(network)?.linkAddresses?.firstOrNull { it.address is Inet4Address && it.address.isSiteLocalAddress }
        mediaRequire(caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true && address != null, "Connect to Wi-Fi")
        val scanner = MediaServerDiscovery { network.openConnection(it) as java.net.HttpURLConnection }
        s.discovery = scanner
        val lock = (app.getSystemService(Context.WIFI_SERVICE) as WifiManager).createMulticastLock("PlayerAccountDiscovery")
        commit(s) { s.state = "discover"; s.result = JSONObject().put("servers", JSONArray()) }
        try {
            lock.acquire()
            scanner.scan(MediaServerDiscovery.Subnet(address!!.address.hostAddress!!, address.prefixLength)) { found ->
                commit(s) {
                    mediaRequire(manager.activeNetwork == network, "Network changed. Search again.")
                    s.result.getJSONArray("servers").put(JSONObject().put("name", found.name).put("base", found.address).put("provider", found.provider))
                    s.revision++
                }
            }
            mediaRequire(manager.activeNetwork == network, "Network changed. Search again.")
        } finally { scanner.close(); if (lock.isHeld) lock.release(); s.discovery = null }
    }

    fun webFrame(id: Int): ByteArray = session?.takeIf { it.id == id && !it.cancelled }?.web?.frame() ?: ByteArray(0)
    fun webAction(id: Int, action: String, x: Float, y: Float, text: String) {
        session?.takeIf { it.id == id && !it.cancelled }?.web?.action(action, x, y, text)
    }
    fun pause(paused: Boolean) { session?.web?.pause(paused) }
    @Synchronized fun cancel(id: Int) {
        val s = session?.takeIf { it.id == id } ?: return
        s.cancelSession { s.inputs.values.forEach { it.clear() }; s.challenge = null; s.result = JSONObject() }
        s.auth?.close(); s.http?.close(); s.discovery?.close(); s.web?.close()
        session = null
    }
    @Synchronized fun close() { closed = true; cancel(session?.id ?: 0); worker.shutdownNow() }
    private fun providerName(provider: String) = mapOf("stash" to "Stash", "emby" to "Emby", "jellyfin" to "Jellyfin", "xbvr" to "XBVR")[provider] ?: provider
}
