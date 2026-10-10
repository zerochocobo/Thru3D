package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import java.util.Base64

class OpenListAuthTest {
    private fun result(variant: String, online: Boolean = true): String {
        val json = JSONObject().put("driver_txt", variant).put("access_token", "access-fixture")
            .put("refresh_token", "refresh-fixture").put("server_use", online.toString())
        if (!online) json.put("client_uid", "own-id").put("client_key", "own-secret")
        return OpenListAuth.ORIGIN + "/#" + Base64.getEncoder().encodeToString(json.toString().toByteArray())
    }
    @Test fun callbacksMapToMatchingDriversAndKeepParametersNative() {
        val a = OpenListAuth.parse(result("115cloud_go"), CloudDrive.OPEN115)!!.addition()
        assertEquals("0", a.getString("root_folder_id"))
        assertEquals("access-fixture", a.getString("access_token"))
        val o = OpenListAuth.parse(result("onedrive_pr"), CloudDrive.ONEDRIVE)!!.addition()
        assertTrue(o.getBoolean("use_online_api"))
        assertEquals("https://api.oplist.org/onedrive/renewapi", o.getString("api_url_address"))
        val own = OpenListAuth.parse(result("onedrive_pr", false), CloudDrive.ONEDRIVE)!!.addition()
        assertFalse(own.getBoolean("use_online_api"))
        assertEquals("own-secret", own.getString("client_secret"))
    }
    @Test fun rejectsOtherProvidersQrPhishingInvalidAndOversizedResponses() {
        assertNull(OpenListAuth.parse(result("115cloud_qr"), CloudDrive.OPEN115))
        assertNull(OpenListAuth.parse(result("onedrive_pr"), CloudDrive.OPEN115))
        assertNull(OpenListAuth.parse(result("onedrive_cn"), CloudDrive.ONEDRIVE))
        assertNull(OpenListAuth.parse(result("115cloud_go").replace("api.oplist.org", "api.oplist.org.evil.test"), CloudDrive.OPEN115))
        assertNull(OpenListAuth.parse(result("115cloud_go").replace("https:", "http:"), CloudDrive.OPEN115))
        assertNull(OpenListAuth.parse(OpenListAuth.ORIGIN + "/#invalid", CloudDrive.OPEN115))
        assertNull(OpenListAuth.parse(OpenListAuth.ORIGIN + "/#" + "A".repeat(90000), CloudDrive.OPEN115))
        assertNull(OpenListAuth.parse(result("115cloud_go").replace("/#", "/other#"), CloudDrive.OPEN115))
    }
    @Test fun navigationStaysInTheSelectedProviderWithoutAppSchemes() {
        assertTrue(OpenListAuth.allowed("https://passportapi.115.com/open/authorize", CloudDrive.OPEN115, true))
        assertFalse(OpenListAuth.allowed("https://login.microsoftonline.com/", CloudDrive.OPEN115, true))
        assertFalse(OpenListAuth.allowed("intent://login", CloudDrive.OPEN115, true))
        assertFalse(OpenListAuth.allowed("https://api.oplist.org@evil.test/", CloudDrive.OPEN115, true))
        assertFalse(OpenListAuth.allowed("https://115.com.evil.test/", CloudDrive.OPEN115, true))
        assertTrue(OpenListAuth.allowed("https://login.live.com/", CloudDrive.ONEDRIVE, true))
        assertFalse(OpenListAuth.allowed("https://www.dropbox.com/oauth2/authorize", CloudDrive.ONEDRIVE, true))
    }
    @Test fun tokenImportNeedsAnInitiatedMatchingCallbackAndCorrectState() {
        val s = OpenListOAuthSession(CloudDrive.OPEN115)
        assertNull(s.credential(result("115cloud_go")))
        assertFalse(s.allowCallback("https://api.oplist.org/115cloud/callback?state=fixture&code=code"))
        s.providerNavigation("https://passport.115.com/login", "random_key=fixture")
        assertFalse(s.allowCallback("https://api.oplist.org/onedrive/callback?state=fixture&code=code"))
        assertFalse(s.allowCallback("https://api.oplist.org/115cloud/callback?state=wrong&code=code"))
        assertFalse(s.allowCallback("https://api.oplist.org/115cloud/callback?state=fixture&state=wrong&code=code"))
        assertTrue(s.allowCallback("https://api.oplist.org/115cloud/callback?state=fixture&code=code"))
        assertNotNull(s.credential(result("115cloud_go")))
        assertNull(s.credential(result("115cloud_qr")))
        assertFalse(s.allowCallback("https://api.oplist.org/115cloud/callback?state=fixture&code=code"))
    }
    @Test fun insertsStateForApiPagesWithoutItAndChecksReturn() {
        val s = OpenListOAuthSession(CloudDrive.ONEDRIVE)
        val url = s.providerNavigation("https://login.microsoftonline.com/common/oauth2/v2.0/authorize?redirect_uri=https%3A%2F%2Fapi.oplist.org%2Fonedrive%2Fcallback", "")
        val state = URI(url).query.substringAfter("state=")
        assertTrue(state.isNotBlank())
        assertTrue(s.allowCallback("https://api.oplist.org/onedrive/callback?code=code&state=$state"))
        assertNotNull(s.credential(result("onedrive_pr")))
    }
    @Test fun directRequestsUseOnlyTheSelectedPublicNonQrFlow() {
        assertTrue(OpenListAuth.requestUrl(CloudDrive.OPEN115).contains("/115cloud/requests?"))
        assertTrue(OpenListAuth.requestUrl(CloudDrive.ONEDRIVE).contains("driver_txt=onedrive_pr&server_use=true"))
        assertFalse(OpenListAuth.requestUrl(CloudDrive.OPEN115).contains("_qr"))
        assertFalse(OpenListAuth.requestPage("https://api.oplist.org/onedrive/requests", CloudDrive.OPEN115))
        val s = OpenListOAuthSession(CloudDrive.OPEN115)
        val data = JSONObject().put("driver_txt","115cloud_go").put("access_token","access").put("refresh_token","refresh").put("server_use",true)
        assertNull(s.recovered(data))
        s.providerNavigation("https://passport.115.com/", "random_key=fixture")
        assertTrue(s.allowCallback("https://api.oplist.org/115cloud/callback?state=fixture&code=code"))
        assertNotNull(s.recovered(data))
    }    @Test fun localProxyConnectorRejectsAnyUrlOutsideTheExactCapability() {
        val link = CloudLink("http://127.0.0.1:5244/capability/file") { emptyMap() }
        val connection = OpenListBackend.connection(URI(link.url), link)
        connection.disconnect()
        for (uri in listOf("http://127.0.0.1:5244/other", "http://localhost:5244/capability/file",
            "https://evil.test/file", "http://127.0.0.1:80/capability/file")) {
            assertThrows(CloudFailure::class.java) { OpenListBackend.connection(URI(uri), link) }
        }
    }
}
