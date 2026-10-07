package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.io.Closeable
import java.io.IOException
import java.net.CookieManager
import java.net.CookiePolicy
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import javax.crypto.Cipher

/** Independent 115 login. Protocol references: p115client and 115's own login-api.js.
 * Passwords, challenges and the HTTP cookie jar live only for the current dialog.
 */
internal class Cloud115Auth(private val transport: Transport = HttpTransport()) : Closeable {
    interface Transport : Closeable {
        fun request(url: String, form: Map<String, String>? = null): ByteArray
        fun sessionCookies(): JSONObject = JSONObject()
    }

    sealed class Result {
        class Connected(val cookie: String) : Result()
        class Sms(val userId: String, val twoStep: Boolean) : Result()
        object Captcha : Result()
        object Sent : Result()
        class Rejected(val code: Int) : Result()
    }
    class Challenge(val sign: String, val prompt: ByteArray, val choices: ByteArray)
    class Answer(val sign: String, val code: String)

    private fun json(path: String, form: Map<String, String>? = null) =
        JSONObject(String(transport.request(PASSPORT + path, form), Charsets.UTF_8))

    private fun result(response: JSONObject): Result {
        val parsed = parse(response)
        // The password endpoint returns cookies in JSON; SMS login can set HTTP cookies instead.
        // Never accept cookies on an unsuccessful or challenge response.
        if (ok(response) && parsed is Result.Rejected && parsed.code == 0) {
            cookieHeader(transport.sessionCookies())?.let { return Result.Connected(it) }
        }
        return parsed
    }

    fun password(account: String, password: CharArray, answer: Answer? = null, sms: String? = null): Result {
        require(account.isNotBlank() && password.isNotEmpty())
        val key = json("login/getKey").getJSONObject("data").getString("key")
        val form = linkedMapOf("account" to account.trim(), "passwd" to encryptPassword(password, key), "cipher_ver" to "2")
        answer?.let { form["code"] = it.code; form["code_id"] = it.sign }
        sms?.let { form["code"] = it; form["login[scode]"] = it }
        return result(json("login/login", form))
    }

    fun sendSms(sms: Result.Sms, answer: Answer? = null): Result {
        val form = linkedMapOf("user_id" to sms.userId, "tpl" to if (sms.twoStep) "login_from_two_step" else "verify_code", "cv21" to "2")
        answer?.let { form["code"] = it.code; form["code_id"] = it.sign }
        val response = json("code/sms/login", form)
        return if (ok(response)) Result.Sent else parse(response)
    }

    fun verifySms(sms: Result.Sms, code: String): Result {
        require(sms.twoStep && code.matches(Regex("[0-9]{4,8}")))
        return result(json("login/vip", mapOf("account" to sms.userId, "code" to code)))
    }

    fun challenge(): Challenge {
        // Fetch the sign first; all following images must share the same PHP session.
        val response = JSONObject(String(transport.request("$CAPTCHA/?ac=code&t=sign"), Charsets.UTF_8))
        check(ok(response))
        val sign = response.getString("sign").also { check(it.isNotBlank()) }
        val prompt = transport.request("$CAPTCHA/?ct=index&ac=code")
        val choices = transport.request("$CAPTCHA/?ct=index&ac=code&t=all")
        return Challenge(sign, prompt, choices)
    }

    override fun close() = transport.close()

    companion object {
        private const val PASSPORT = "https://passportapi.115.com/app/1.0/web/1.0/"
        private const val CAPTCHA = "https://captchaapi.115.com"
        const val USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

        private fun ok(value: JSONObject) = value.opt("state") == true || value.opt("state")?.toString() == "1"

        fun parse(value: JSONObject): Result {
            val code = sequenceOf("errno", "err_code", "code").map { value.optInt(it) }.firstOrNull { it != 0 } ?: 0
            val data = value.optJSONObject("data") ?: value
            if (code in setOf(40101010, 70128, 90059)) {
                val userId = data.optString("user_id")
                return if (userId.matches(Regex("[0-9]+"))) Result.Sms(userId, code != 90059) else Result.Rejected(code)
            }
            if (code in setOf(10098, 40101004, 40103000) || value.optString("err_name") == "code") return Result.Captcha
            if (ok(value)) {
                val cookie = data.optJSONObject("cookie")
                if (cookie != null) cookieHeader(cookie)?.let { return Result.Connected(it) }
            }
            return Result.Rejected(code)
        }

        fun cookieHeader(value: JSONObject): String? {
            val names = listOf("UID", "CID", "SEID", "KID")
            val parts = names.associateWith { value.optString(it) }
            if (names.take(3).any { parts[it].isNullOrBlank() }) return null
            if (parts.values.any { v -> v.any { it <= ' ' || it == ';' || it == ',' || it == '\u007f' } }) return null
            return parts.filterValues { it.isNotEmpty() }.entries.joinToString("; ") { "${it.key}=${it.value}" }
        }

        fun encryptPassword(password: CharArray, encodedKey: String, seconds: Long = System.currentTimeMillis() / 1000): String {
            val pem = String(Base64.getDecoder().decode(encodedKey), Charsets.US_ASCII)
            val der = Base64.getMimeDecoder().decode(pem.replace("-----BEGIN PUBLIC KEY-----", "").replace("-----END PUBLIC KEY-----", ""))
            val key = KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(der))
            val bytes = String(password).toByteArray(Charsets.UTF_8)
            val digest = try { MessageDigest.getInstance("SHA-1").digest(bytes) } finally { bytes.fill(0) }
            val text = (digest.joinToString("") { "%02x".format(it.toInt() and 255) } + "_" + seconds).toByteArray(Charsets.US_ASCII)
            digest.fill(0)
            return try {
                val cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding")
                cipher.init(Cipher.ENCRYPT_MODE, key)
                Base64.getEncoder().encodeToString(cipher.doFinal(text))
            } finally { text.fill(0) }
        }
    }

    /** Fixed official HTTPS origins only. No global CookieHandler, redirects, disk cache or logging. */
    class HttpTransport : Transport {
        private val cookies = CookieManager(null, CookiePolicy.ACCEPT_ORIGINAL_SERVER)
        @Volatile private var closed = false
        private var active: HttpURLConnection? = null

        override fun request(url: String, form: Map<String, String>?): ByteArray {
            val uri = URI(url)
            require(uri.scheme == "https" && uri.host in setOf("passportapi.115.com", "captchaapi.115.com") && uri.port == -1 && uri.rawUserInfo == null)
            val connection = URL(url).openConnection() as HttpURLConnection
            synchronized(this) { check(!closed); active = connection }
            try {
                connection.connectTimeout = 15000
                connection.readTimeout = 20000
                connection.instanceFollowRedirects = false
                connection.useCaches = false
                connection.setRequestProperty("User-Agent", USER_AGENT)
                connection.setRequestProperty("Referer", "https://115.com/")
                synchronized(cookies) { cookies.get(uri, emptyMap()).forEach { (key, values) -> connection.setRequestProperty(key, values.joinToString("; ")) } }
                if (form != null) {
                    connection.requestMethod = "POST"
                    connection.doOutput = true
                    connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
                    val bytes = form.entries.joinToString("&") { URLEncoder.encode(it.key, "UTF-8") + "=" + URLEncoder.encode(it.value, "UTF-8") }.toByteArray(Charsets.UTF_8)
                    try { connection.outputStream.use { it.write(bytes) } } finally { bytes.fill(0) }
                }
                if (connection.responseCode != 200) throw IOException("115 HTTP ${connection.responseCode}")
                synchronized(cookies) { if (!closed) cookies.put(uri, connection.headerFields.filterKeys { it != null }) }
                val result = connection.inputStream.use { input ->
                    val output = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (closed || output.size() + count > 1024 * 1024) throw IOException("115 response unavailable")
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                }
                check(!closed)
                return result
            } finally {
                connection.disconnect()
                synchronized(this) { if (active === connection) active = null }
            }
        }

        override fun close() {
            synchronized(this) { closed = true; active?.disconnect(); active = null }
            synchronized(cookies) { cookies.cookieStore.removeAll() }
        }

        override fun sessionCookies(): JSONObject = synchronized(cookies) {
            JSONObject().also { result ->
                if (!closed) cookies.cookieStore.get(URI("https://passportapi.115.com/")).forEach {
                    if (!it.hasExpired()) result.put(it.name, it.value)
                }
            }
        }
    }
}
