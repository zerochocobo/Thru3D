package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class OpenListCandidateAuthTest {
    private fun aliyun() = JSONObject().put("driver_txt", "alicloud_go").put("server_use", true)
        .put("access_token", "access-fixture").put("refresh_token", "refresh-fixture")
    private fun quark(includeSign: Boolean = true) = JSONObject().put("code", 0).put("data", JSONObject()
        .put("accessToken", "access-fixture").put("refreshToken", "refresh-fixture").put("appId", "public-client")
        .apply { if (includeSign) put("signKey", "public-sign-fixture") })
    private val authorization = "https://pan.quark.cn/open/v1/oauth/authorize?client_id=public-client&" +
        "redirect_uri=https%3A%2F%2Foauth.fnnas.com%2Fapi%2Fv1%2Fredirect%2FfromQuark&" +
        "state=com.trim.cloudstorage--trimNonce__abcdefghijklmnop"
    @Test fun bothVerifiedProvidersHavePublicEntries() {
        assertTrue(CloudDrive.PROVIDERS.containsKey(CloudDrive.ALIYUN))
        assertTrue(CloudDrive.PROVIDERS.containsKey(CloudDrive.QUARK))
        assertTrue(CloudDrive.TRIAL_PROVIDERS.isEmpty())
        assertTrue(OpenListAuth.requestUrl(CloudDrive.ALIYUN).contains("driver_txt=alicloud_go&server_use=true"))
        assertTrue(OpenListAuth.requestUrl(CloudDrive.QUARK).contains("driver_txt=quarkyun_fn&server_use=true"))
    }
    @Test fun aliyunImportsOnlyThePublicNonQrFlowAndFixedDriverFields() {
        val addition = OpenListAuth.fromData(aliyun(), CloudDrive.ALIYUN)!!.addition()
        assertEquals("root", addition.getString("root_folder_id"))
        assertEquals("access-fixture", addition.getString("AccessToken"))
        assertEquals("https://api.oplist.org/alicloud/renewapi", addition.getString("api_url_address"))
        assertEquals("", addition.getString("client_secret"))
        for (variant in listOf("alicloud_qr", "alicloud_tv", "alicloud_cs", "quarkyun_fn"))
            assertNull(OpenListAuth.fromData(aliyun().put("driver_txt", variant), CloudDrive.ALIYUN))
        assertNull(OpenListAuth.fromData(aliyun().put("server_use", false), CloudDrive.ALIYUN))
        assertNull(OpenListAuth.fromData(aliyun().put("client_uid", "custom-id"), CloudDrive.ALIYUN))
        assertNull(OpenListAuth.fromData(aliyun().put("access_token", ""), CloudDrive.ALIYUN))
    }
    @Test fun aliyunCallbackUsesStateBoundToTheInitiatedAuthorization() {
        val session = OpenListOAuthSession(CloudDrive.ALIYUN)
        val auth = session.providerNavigation("https://openapi.aliyundrive.com/oauth/authorize?redirect_uri=https%3A%2F%2Fapi.oplist.org%2Falicloud%2Fcallback", "")
        val state = java.net.URI(auth).query.substringAfter("state=")
        assertFalse(session.allowCallback("https://api.oplist.org/alicloud/callback?code=fixture&state=wrong"))
        assertTrue(session.allowCallback("https://api.oplist.org/alicloud/callback?code=fixture&state=$state"))
        assertNotNull(session.recovered(aliyun()))
    }
    @Test fun quarkCannotImportWithoutMatchingNonceAndApplicationSignature() {
        val session = OpenListOAuthSession(CloudDrive.QUARK)
        assertNull(session.quarkCredential(quark()))
        assertFalse(session.allowCallback("https://api.oplist.org/quarkyun/callback?nonce=abcdefghijklmnop"))
        assertEquals(authorization, session.providerNavigation(authorization, ""))
        assertFalse(session.allowCallback("https://api.oplist.org/quarkyun/callback?nonce=abcdefghijklmnop"))
        session.providerNavigation("https://oauth.fnnas.com/api/v1/redirect/fromQuark?code=fixture&state=com.trim.cloudstorage--trimNonce__abcdefghijklmnop", "")
        assertFalse(session.allowCallback("https://api.oplist.org/quarkyun/callback?nonce=wrong"))
        assertFalse(session.allowCallback("https://api.oplist.org/quarkyun/callback?nonce=abcdefghijklmnop&nonce=wrong"))
        assertTrue(session.allowCallback("https://api.oplist.org/quarkyun/callback?nonce=abcdefghijklmnop"))
        assertNull(session.quarkCredential(quark(false)))
        assertNull(session.quarkCredential(quark().apply { getJSONObject("data").put("appId", "other-client") }))
        val addition = session.quarkCredential(quark())!!.addition()
        assertEquals("public-client", addition.getString("app_id"))
        assertEquals("public-sign-fixture", addition.getString("sign_key"))
        assertTrue(addition.getBoolean("use_online_api"))
        assertFalse(session.allowCallback("https://api.oplist.org/quarkyun/callback?nonce=abcdefghijklmnop"))
    }
    @Test fun quarkRotatedNonceRequiresTheInitiatedBrokerGrantAndExpires() {
        var clock = 1L
        val session = OpenListOAuthSession(CloudDrive.QUARK) { clock }
        session.providerNavigation(authorization, "")
        val callback = "https://api.oplist.org/quarkyun/callback?nonce=qrstuvwxyzABCDEF"
        assertFalse(session.allowCallback(callback))
        val broker = "https://oauth.fnnas.com/api/v1/redirect/fromQuark?code=SECRET-code&state=com.trim.cloudstorage--trimNonce__abcdefghijklmnop"
        assertTrue(runCatching { session.providerNavigation(broker.replace("abcdefghijklmnop", "wrong"), "") }.isFailure)
        assertFalse(session.allowCallback(callback))
        assertTrue(runCatching { session.providerNavigation(broker + "&state=wrong", "") }.isFailure)
        session.providerNavigation(broker, "")
        assertTrue(session.allowCallback(callback))
        assertEquals("qrstuvwxyzABCDEF", session.quarkNonce)
        assertTrue(session.matchesCallback(callback)); assertFalse(session.allowCallback(callback))
        assertFalse(session.matchesCallback(callback.replace("qrstuvwxyzABCDEF", "aDifferentNonce16")))
        assertTrue(runCatching { session.providerNavigation(broker.replace("SECRET-code", "other-code"), "") }.isFailure)
        val expired = OpenListOAuthSession(CloudDrive.QUARK) { clock }
        expired.providerNavigation(authorization, ""); expired.providerNavigation(broker, "")
        clock += 61_000_000_000L
        assertFalse(expired.allowCallback(callback))
    }
    @Test fun quarkDiagnosticsDescribeTheBrokerAndNonceWithoutAcceptingAnotherFormat() {
        val session = OpenListOAuthSession(CloudDrive.QUARK)
        session.providerNavigation(authorization, "")
        session.providerNavigation("https://oauth.fnnas.com/api/v1/redirect/fromQuark?code=SECRET-code&state=com.trim.cloudstorage--trimNonce__abcdefghijklmnop", "")
        val callback = "https://api.oplist.org/quarkyun/callback?nonce=com.trim.cloudstorage--trimNonce__abcdefghijklmnop"
        assertFalse(session.allowCallback(callback))
        val info = session.callbackDiagnostics(callback)
        assertTrue(info.getBoolean("broker_seen")); assertTrue(info.getBoolean("broker_state_matches"))
        assertTrue(info.getBoolean("nonce_matches_with_prefix"))
        assertEquals(16, info.getInt("nonce_expected_length"))
        assertTrue(info.getInt("nonce_received_length") > 16)
        assertFalse(info.getBoolean("returned"))
        assertFalse(info.toString().contains("abcdefghijklmnop")); assertFalse(info.toString().contains("SECRET-code"))
    }
    @Test fun diagnosticsContainOnlyPresenceFlagsAndNeverSecrets() {
        val state = "SECRET-state-fixture"
        val code = "SECRET-code-fixture"
        val session = OpenListOAuthSession(CloudDrive.ALIYUN)
        session.providerNavigation("https://openapi.aliyundrive.com/oauth/authorize?redirect_uri=https%3A%2F%2Fapi.oplist.org%2Falicloud%2Fcallback&state=$state", "")
        val callback = "https://api.oplist.org/alicloud/callback?code=$code&state=$state"
        val before = session.callbackDiagnostics(callback)
        assertTrue(before.getBoolean("state_matches"))
        assertFalse(before.getBoolean("returned"))
        assertFalse(before.toString().contains(state)); assertFalse(before.toString().contains(code))
        assertTrue(session.allowCallback(callback)); assertTrue(session.matchesCallback(callback))
        assertFalse(session.matchesCallback(callback + "-changed"))
        assertTrue(session.matchesCallback("https://api.oplist.org:443/alicloud/callback?state=$state&code=SECRET%2Dcode%2Dfixture"))
        assertFalse(session.matchesCallback(callback + "&grant_type=refresh_token"))
        assertFalse(session.matchesCallback(callback + "&code=$code"))
        assertTrue(session.callbackDiagnostics(callback).getBoolean("code_matches"))
        val data = aliyun().put("access_token", "SECRET-access-fixture").put("refresh_token", "SECRET-refresh-fixture")
        val url = OpenListAuth.ORIGIN + "/#" + java.util.Base64.getEncoder().encodeToString(data.toString().toByteArray())
        val result = OpenListAuth.resultDiagnostics(url, CloudDrive.ALIYUN)
        assertTrue(result.getJSONObject("fields").getBoolean("driver_matches"))
        assertFalse(result.toString().contains("SECRET-"))
    }
    @Test fun navigationDoesNotAcceptOtherCloudsOrFakeOrigins() {
        assertTrue(OpenListAuth.allowed("https://oauth.fnnas.com/api/v1/redirect/fromQuark", CloudDrive.QUARK, true))
        assertFalse(OpenListAuth.allowed("https://oauth.fnnas.com.evil.test/", CloudDrive.QUARK, true))
        assertFalse(OpenListAuth.allowed("https://pan.quark.cn/", CloudDrive.ALIYUN, true))
        assertFalse(OpenListAuth.allowed("alipansdk://callback", CloudDrive.ALIYUN, true))
        assertThrows(IllegalArgumentException::class.java) {
            OpenListOAuthSession(CloudDrive.QUARK).providerNavigation(authorization.replace("oauth.fnnas.com", "evil.test"), "")
        }
    }
}
