package org.vrpassthroughplayer.plugin

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class BaiduOpenListTest {
    private fun publicResult() = JSONObject().put("driver_txt", "baiduyun_go")
        .put("access_token", "access-fixture").put("refresh_token", "refresh-fixture")
        .put("client_key", "").put("secret_key", "")
    private fun params(value: String) = URI(value).rawQuery.split('&').associate {
        URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8")
    }
    @Test fun callbackWithoutServerUseMapsToPublicOfficialBaiduDriver() {
        val addition = OpenListAuth.fromData(publicResult(), CloudDrive.BAIDU)!!.addition()
        assertEquals("BaiduNetdisk", OpenListAuth.drivers[CloudDrive.BAIDU])
        assertEquals("/", addition.getString("root_folder_path"))
        assertEquals("access-fixture", addition.getString("AccessToken"))
        assertTrue(addition.getBoolean("use_online_api"))
        assertEquals("https://api.oplist.org/baiduyun/renewapi", addition.getString("api_url_address"))
        assertEquals("official", addition.getString("download_api"))
        assertFalse(addition.getBoolean("only_list_video_file"))
        assertTrue(addition.getString("client_id").isEmpty()); assertTrue(addition.getString("client_secret").isEmpty())
    }
    @Test fun rejectsOobWrongProviderCustomKeysErrorAndMissingToken() {
        for (data in listOf(publicResult().put("driver_txt","baiduyun_ob"), publicResult().put("driver_txt","dropboxs_go"),
            publicResult().put("server_use",false), publicResult().put("secret_key","own-secret"),
            publicResult().put("client_key","own-key"), publicResult().put("client_uid","own-id"),
            publicResult().put("message_err","provider-error"), publicResult().put("refresh_token",""),
            publicResult().put("access_token",""))) {
            assertNull(OpenListAuth.fromData(data, CloudDrive.BAIDU))
        }
    }
    @Test fun directBaiduRequestPinsStateBeforeAcceptingCallback() {
        assertTrue(OpenListAuth.requestUrl(CloudDrive.BAIDU).contains("/baiduyun/requests?"))
        assertTrue(OpenListAuth.requestUrl(CloudDrive.BAIDU).contains("driver_txt=baiduyun_go&server_use=true"))
        val s = OpenListOAuthSession(CloudDrive.BAIDU)
        val url = s.providerNavigation("https://openapi.baidu.com/oauth/2.0/authorize?client_id=fixture&redirect_uri=https%3A%2F%2Fapi.oplist.org%2Fbaiduyun%2Fcallback", "")
        val state = params(url).getValue("state")
        assertFalse(s.allowCallback("https://api.oplist.org/baiduyun/callback?code=fixture&state=wrong"))
        assertTrue(s.allowCallback("https://api.oplist.org/baiduyun/callback?code=fixture&state=$state"))
        assertNotNull(s.recovered(publicResult()))
        assertFalse(s.allowCallback("https://api.oplist.org/baiduyun/callback?code=fixture&state=$state"))
    }
    @Test fun passportWrappedReturnPreservesStateAndOtherParameters() {
        val s = OpenListOAuthSession(CloudDrive.BAIDU)
        val auth = "https://openapi.baidu.com/oauth/2.0/authorize?redirect_uri=https%3A%2F%2Fapi.oplist.org%2Fbaiduyun%2Fcallback&scope=basic%2Cnetdisk"
        val url = s.providerNavigation("https://passport.baidu.com/v2/?login&tpl=netdisk&u="+URLEncoder.encode(auth,"UTF-8"), "")
        assertEquals("netdisk", params(url)["tpl"])
        val nested = params(params(url).getValue("u"))
        assertEquals("basic,netdisk",nested["scope"])
        assertTrue(s.allowCallback("https://api.oplist.org/baiduyun/callback?code=fixture&state="+nested.getValue("state")))
    }
    @Test fun maliciousNavigationCannotReplaceInitiatedStateOrSwitchProviders() {
        val s = OpenListOAuthSession(CloudDrive.BAIDU)
        val original = s.providerNavigation("https://openapi.baidu.com/oauth/2.0/authorize?redirect_uri=https%3A%2F%2Fapi.oplist.org%2Fbaiduyun%2Fcallback", "")
        val next = s.providerNavigation(original.replace(params(original).getValue("state"),"injected"), "")
        assertEquals(params(original)["state"],params(next)["state"])
        assertFalse(OpenListAuth.allowed("https://baidu.com.evil.test/",CloudDrive.BAIDU,true))
        assertFalse(OpenListAuth.allowed("https://api.oplist.org@evil.test/",CloudDrive.BAIDU,true))
        assertFalse(OpenListAuth.allowed("https://accounts.google.com/",CloudDrive.BAIDU,true))
        assertFalse(OpenListAuth.allowed("intent://login",CloudDrive.BAIDU,true))
        assertTrue(OpenListAuth.allowed("https://passport.baidu.com/",CloudDrive.BAIDU,true))
    }
    @Test fun legacyCookieAccountRequiresReauthorizationWithoutStartingOldAdapter() {
        val legacy = JSONObject().put("provider","baidu").put("id","keep-this-id").put("cookie","BDUSS=fixture")
        val error = assertThrows(CloudFailure::class.java) { OpenListBackend.client(legacy) }
        assertEquals("cloud_login_required",error.reason)
        assertEquals("keep-this-id",legacy.getString("id"))
        assertThrows(IllegalArgumentException::class.java) { CloudDrive(CloudDrive.BAIDU,"BDUSS=fixture") }
        val oauth = JSONObject().put("provider","baidu").put("id","keep-this-id").put("core_id",1)
            .put("mount","/12345678-1234-1234-1234-123456789abc")
        assertFalse(OpenListBackend.client(oauth).canDelete)
    }
}
