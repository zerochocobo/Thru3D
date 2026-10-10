package org.vrpassthroughplayer.plugin

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import org.json.JSONObject
import java.util.UUID

/** OAuth state is checked before APIpage exchanges the code. One session imports one provider only. */
internal class OpenListOAuthSession(private val provider: String, private val now: () -> Long = System::nanoTime) {
    private val nonce = UUID.randomUUID().toString()
    private var expectedState = ""
    private var expectedNonce = ""
    private var expectedAppId = ""
    private var quarkBrokerSeen = false
    private var quarkBrokerStateMatches = false
    private var quarkBrokerCode = ""
    private var quarkBrokerAt = 0L
    private var leftTool = false
    private var returned = false
    private var acceptedCallback = ""
    private val started = now()

    fun providerNavigation(value: String, toolCookies: String): String {
        if (OpenListAuth.atTool(value)) return value
        val uri = URI(value)
        require(OpenListAuth.allowed(value, provider, true))
        leftTool = true
        if (provider == CloudDrive.QUARK) {
            if (OpenListAuth.quarkBrokerCallback(value)) {
                val params = query(uri)
                quarkBrokerSeen = true
                quarkBrokerStateMatches = expectedNonce.isNotEmpty() &&
                    params["state"] == "com.trim.cloudstorage--trimNonce__" + expectedNonce
                val code = params["code"].orEmpty()
                require(quarkBrokerStateMatches && code.length in 1..4096)
                require(quarkBrokerCode.isEmpty() || quarkBrokerCode == code)
                if (quarkBrokerCode.isEmpty()) { quarkBrokerCode = code; quarkBrokerAt = now() }
            }
            if (uri.host == "pan.quark.cn" && uri.path == "/open/v1/oauth/authorize") {
                val params = query(uri)
                require(params["redirect_uri"] == "https://oauth.fnnas.com/api/v1/redirect/fromQuark")
                val state = params["state"].orEmpty()
                val nonce = state.removePrefix("com.trim.cloudstorage--trimNonce__")
                require(nonce != state && nonce.matches(Regex("[A-Za-z0-9_-]{16,256}")))
                require(expectedNonce.isEmpty() || expectedNonce == nonce)
                val appId = params["client_id"].orEmpty()
                require(appId.matches(Regex("[A-Za-z0-9_-]{8,128}")))
                expectedNonce = nonce; expectedAppId = appId
            }
            return value
        }
        if (provider == CloudDrive.OPEN115 && expectedState.isEmpty()) {
            expectedState = toolCookies.split(';').map { it.trim().split('=', limit = 2) }
                .firstOrNull { it.size == 2 && it[0] == "random_key" }?.get(1).orEmpty()
        }
        return prepareAuthorization(value, 0)
    }

    private fun prepareAuthorization(value: String, depth: Int): String {
        if (depth > 4 || !OpenListAuth.allowed(value, provider, true) || OpenListAuth.atTool(value)) return value
        val uri = URI(value)
        val params = query(uri)
        if (params["redirect_uri"]?.let { OpenListAuth.callback(it, provider) } == true) {
            val state = params["state"].orEmpty()
            if (expectedState.isEmpty()) expectedState = state.ifEmpty { nonce }
            if (state == expectedState) return value
            // Preserve the first initiated state through provider login redirects.
            return replaceQuery(uri, "state", expectedState)
        }
        if (provider == CloudDrive.BAIDU) {
            // APIpage follows Baidu's first redirect on its server; Passport may
            // wrap the OAuth authorization URL in a login return parameter.
            for (key in listOf("u", "url", "redirect", "redirect_url")) {
                val inner = params[key] ?: continue
                val next = runCatching { prepareAuthorization(inner, depth + 1) }.getOrDefault(inner)
                if (next != inner) return replaceQuery(uri, key, next)
            }
        }
        return value
    }

    private fun replaceQuery(uri: URI, key: String, value: String): String {
        val encoded = URLEncoder.encode(value, "UTF-8")
        var found = false
        val parts = uri.rawQuery.orEmpty().split('&').filter { it.isNotEmpty() }.map {
            if (URLDecoder.decode(it.substringBefore('='), "UTF-8") == key) {
                found = true; it.substringBefore('=') + "=" + encoded
            } else it
        }.toMutableList()
        if (!found) parts.add(key + "=" + encoded)
        return uri.scheme + "://" + uri.rawAuthority + uri.rawPath + "?" + parts.joinToString("&") +
            (uri.rawFragment?.let { "#" + it } ?: "")
    }

    fun allowCallback(value: String): Boolean {
        if (!leftTool || returned || !OpenListAuth.callback(value, provider) ||
            now() - started > 1_200_000_000_000L) return false
        val query = query(URI(value))
        if (provider == CloudDrive.QUARK) {
            // FnNAS rotates its own exchange nonce after validating Quark's code.
            // Bind this return to the initiated state-checked broker grant, not to
            // the earlier authorization nonce. Only the exact tool callback is accepted.
            if (!quarkBrokerStateMatches || quarkBrokerCode.isEmpty() || now() - quarkBrokerAt > 60_000_000_000L ||
                !query["nonce"].orEmpty().matches(Regex("[A-Za-z0-9_-]{16,256}"))) return false
        } else if (expectedState.isEmpty() || query["state"] != expectedState || query["code"].isNullOrEmpty()) return false
        returned = true; acceptedCallback = value
        return true
    }
    fun credential(value: String): OpenListAuth.Credential? =
        if (returned) OpenListAuth.parse(value, provider) else null

    fun matchesCallback(value: String): Boolean = returned && OpenListAuth.callback(value, provider) && runCatching {
        // Android's navigation and page-start callbacks can normalize encoding,
        // query ordering and the default port. Compare every decoded parameter.
        query(URI(value)) == query(URI(acceptedCallback))
    }.getOrDefault(false)
    fun summary() = JSONObject().put("initiated", leftTool).put("state_expected", expectedState.isNotEmpty())
        .put("nonce_expected", expectedNonce.isNotEmpty()).put("returned", returned)
        .put("elapsed_seconds", (now() - started) / 1_000_000_000L)
    fun callbackDiagnostics(value: String): JSONObject {
        val params = runCatching { query(URI(value)) }.getOrDefault(emptyMap())
        val accepted = runCatching { query(URI(acceptedCallback)) }.getOrDefault(emptyMap())
        return summary().put("code_present", !params["code"].isNullOrEmpty())
            .put("code_matches", !accepted["code"].isNullOrEmpty() && params["code"] == accepted["code"])
            .put("query_matches", returned && params == accepted)
            .put("state_present", !params["state"].isNullOrEmpty())
            .put("state_matches", expectedState.isNotEmpty() && params["state"] == expectedState)
            .put("nonce_present", !params["nonce"].isNullOrEmpty())
            .put("nonce_matches", expectedNonce.isNotEmpty() && params["nonce"] == expectedNonce)
            .put("nonce_received_length", params["nonce"].orEmpty().length)
            .put("nonce_expected_length", expectedNonce.length)
            .put("nonce_matches_with_prefix", expectedNonce.isNotEmpty() &&
                params["nonce"] == "com.trim.cloudstorage--trimNonce__" + expectedNonce)
            .put("broker_seen", quarkBrokerSeen).put("broker_state_matches", quarkBrokerStateMatches)
    }
    val quarkNonce: String? get() = if (provider == CloudDrive.QUARK && returned)
        query(URI(acceptedCallback))["nonce"] else null
    fun quarkCredential(data: JSONObject): OpenListAuth.Credential? =
        if (quarkNonce != null) OpenListAuth.quarkExchange(data, expectedAppId) else null
    val awaitingTokens get() = returned
    fun recovered(data: JSONObject): OpenListAuth.Credential? = if (returned) OpenListAuth.fromData(data, provider) else null

    private fun query(uri: URI): Map<String, String> = runCatching {
        val pairs = uri.rawQuery.orEmpty().split('&').filter { it.isNotEmpty() }.map {
            val pair = it.split('=', limit = 2)
            URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair.getOrElse(1) { "" }, "UTF-8")
        }
        require(pairs.map { it.first }.toSet().size == pairs.size)
        pairs.toMap()
    }.getOrDefault(emptyMap())
}
