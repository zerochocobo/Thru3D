package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.net.URI
import java.util.Base64

/** Only the selected non-QR OAuth flow returns credentials to the native account layer. */
internal object OpenListAuth {
    const val ORIGIN = "https://api.oplist.org"
    val drivers = mapOf(CloudDrive.OPEN115 to "115 Open", CloudDrive.BAIDU to "BaiduNetdisk", CloudDrive.ONEDRIVE to "Onedrive",
        CloudDrive.ALIYUN to "AliyundriveOpen", CloudDrive.QUARK to "QuarkOpen")
    private val variants = mapOf(CloudDrive.OPEN115 to setOf("115cloud_go"), CloudDrive.BAIDU to setOf("baiduyun_go"), CloudDrive.ONEDRIVE to setOf("onedrive_pr", "onedrive_go"),
        CloudDrive.ALIYUN to setOf("alicloud_go"), CloudDrive.QUARK to setOf("quarkyun_fn"))
    private val callbacks = mapOf(CloudDrive.OPEN115 to "/115cloud/callback", CloudDrive.BAIDU to "/baiduyun/callback", CloudDrive.ONEDRIVE to "/onedrive/callback",
        CloudDrive.ALIYUN to "/alicloud/callback", CloudDrive.QUARK to "/quarkyun/callback")
    fun supported(provider: String) = provider in drivers && (provider !in CloudDrive.TRIAL_PROVIDERS || BuildConfig.DEBUG)
    fun requestUrl(provider: String): String {
        val variant = variants.getValue(provider).first()
        return ORIGIN + "/" + variant.substringBefore('_') + "/requests?client_uid=&client_key=&driver_txt=" + variant + "&server_use=true"
    }
    fun requestPage(value: String, provider: String): Boolean = runCatching {
        atTool(value) && URI(value).path == "/" + variants.getValue(provider).first().substringBefore('_') + "/requests"
    }.getOrDefault(false)
    fun atTool(value: String): Boolean = runCatching {
        val uri = URI(value)
        uri.scheme == "https" && uri.host == "api.oplist.org" && uri.port in setOf(-1, 443) && uri.rawUserInfo == null
    }.getOrDefault(false)
    fun quarkBrokerCallback(value: String) = runCatching {
        val uri = URI(value)
        uri.scheme == "https" && uri.host == "oauth.fnnas.com" && uri.port in setOf(-1, 443) &&
            uri.rawUserInfo == null && uri.path == "/api/v1/redirect/fromQuark"
    }.getOrDefault(false)
    fun callback(value: String, provider: String) = atTool(value) && runCatching { URI(value).path == callbacks[provider] }.getOrDefault(false)
    fun allowed(value: String, provider: String, mainFrame: Boolean): Boolean {
        if (!mainFrame && value == "about:blank") return true
        if (!supported(provider)) return false
        val uri = runCatching { URI(value) }.getOrNull() ?: return false
        if (uri.scheme != "https" || uri.rawUserInfo != null || uri.port !in setOf(-1, 443)) return false
        if (atTool(value)) return true
        val domains = when (provider) {
            CloudDrive.OPEN115 -> listOf("115.com")
            CloudDrive.BAIDU -> listOf("baidu.com")
            CloudDrive.ALIYUN -> listOf("aliyundrive.com", "alipan.com", "aliyun.com", "taobao.com")
            CloudDrive.QUARK -> listOf("quark.cn", "uc.cn")
            else -> listOf("microsoftonline.com", "live.com", "microsoft.com", "msauth.net", "msftauth.net")
        }
        return domains.any { CloudDrive.within(uri.host, it) } || (provider == CloudDrive.QUARK && uri.host == "oauth.fnnas.com")
    }

    class Credential(val provider: String, private val access: String, private val refresh: String,
        private val clientId: String, private val clientSecret: String, private val online: Boolean) {
        fun addition(): JSONObject = if (provider == CloudDrive.OPEN115)
            JSONObject().put("root_folder_id", "0").put("access_token", access).put("refresh_token", refresh)
                .put("order_by", "file_name").put("order_direction", "asc").put("limit_rate", 1).put("page_size", 200)
        else if (provider == CloudDrive.BAIDU) JSONObject().put("root_folder_path", "/").put("refresh_token", refresh)
            .put("AccessToken", access).put("use_online_api", true).put("api_url_address", "$ORIGIN/baiduyun/renewapi")
            .put("download_api", "official").put("order_by", "name").put("order_direction", "asc")
            .put("only_list_video_file", false).put("client_id", "").put("client_secret", "")
        else if (provider == CloudDrive.ALIYUN) JSONObject().put("root_folder_id", "root").put("refresh_token", refresh)
            .put("AccessToken", access).put("use_online_api", true).put("api_url_address", "$ORIGIN/alicloud/renewapi")
            .put("client_id", "").put("client_secret", "").put("alipan_type", "default").put("drive_type", "default")
            .put("order_by", "name").put("order_direction", "ASC").put("remove_way", "trash")
            .put("rapid_upload", false).put("internal_upload", false).put("livp_download_format", "jpeg")
        else if (provider == CloudDrive.QUARK) JSONObject().put("root_folder_id", "0").put("refresh_token", refresh)
            .put("access_token", access).put("use_online_api", true).put("api_url_address", "$ORIGIN/quarkyun/renewapi")
            .put("app_id", clientId).put("sign_key", clientSecret).put("order_by", "file_name").put("order_direction", "asc")
        else JSONObject().put("root_folder_path", "/").put("region", "global").put("refresh_token", refresh)
            .put("use_online_api", online).put("client_id", clientId).put("client_secret", clientSecret)
            .put("redirect_uri", "$ORIGIN/onedrive/callback").put("api_url_address", "$ORIGIN/onedrive/renewapi")
            .put("disable_disk_usage", true)
    }
    /** APIpage sends Base64 JSON in the fragment. No tokens enter Godot, clipboard or logs. */
    fun parse(value: String, provider: String): Credential? {
        if (!atTool(value) || value.length > 90000) return null
        val uri = runCatching { URI(value) }.getOrNull() ?: return null
        if (uri.path !in setOf("", "/") || !uri.rawQuery.isNullOrEmpty()) return null
        val fragment = uri.fragment ?: return null
        if (fragment.length !in 8..88000) return null
        return runCatching {
            val bytes = Base64.getDecoder().decode(fragment)
            require(bytes.size <= 65536)
            val data = try { JSONObject(String(bytes, Charsets.UTF_8)) } finally { bytes.fill(0) }
            fromData(data, provider)
        }.getOrNull()
    }
    fun fromData(data: JSONObject, provider: String): Credential? = runCatching {
        require(data.optString("driver_txt") in variants[provider].orEmpty())
        require(data.optString("message_err").isEmpty())
        val access = data.optString("access_token")
        val refresh = data.optString("refresh_token")
        require(validToken(refresh))
        if (provider in setOf(CloudDrive.OPEN115, CloudDrive.BAIDU, CloudDrive.ALIYUN, CloudDrive.QUARK)) require(validToken(access))
        // APIpage's Baidu public callback omits server_use, and uses client_key /
        // secret_key for custom applications. This selected flow is public only.
        val online = if (provider in setOf(CloudDrive.BAIDU, CloudDrive.ALIYUN)) {
            require(data.optString("client_uid").isEmpty() && data.optString("client_key").isEmpty() && data.optString("secret_key").isEmpty())
            require(!data.has("server_use") || data.opt("server_use") == true || data.optString("server_use") == "true")
            true
        } else data.opt("server_use") == true || data.optString("server_use") == "true"
        // APIpage currently discards Quark signing fields. Never invent defaults.
        if (provider == CloudDrive.QUARK) return null
        val clientId = if (online) "" else data.optString("client_uid")
        val clientSecret = if (online) "" else data.optString("client_key")
        if (!online && provider != CloudDrive.OPEN115) require(validToken(clientId) && validToken(clientSecret))
        Credential(provider, access, refresh, clientId, clientSecret, online)
    }.getOrNull()
    /** Only the initiated session's FnNAS nonce can import a public exchange result. */
    fun quarkExchange(data: JSONObject, expectedAppId: String): Credential? = runCatching {
        require(data.optInt("code", -1) == 0 && validToken(expectedAppId))
        val result = data.getJSONObject("data")
        val access = result.getString("accessToken")
        val refresh = result.getString("refreshToken")
        val appId = result.getString("appId")
        val signKey = result.getString("signKey")
        require(appId == expectedAppId && validToken(access) && validToken(refresh) && validToken(signKey))
        Credential(CloudDrive.QUARK, access, refresh, appId, signKey, true)
    }.getOrNull()
    /** Debug metadata only: never returns any code, state, token or unknown field. */
    fun resultDiagnostics(value: String, provider: String): JSONObject {
        val info = JSONObject().put("origin_matches", atTool(value))
        if (!atTool(value) || value.length > 90000) return info
        val uri = runCatching { URI(value) }.getOrNull() ?: return info
        info.put("root_path", uri.path in setOf("", "/")).put("query_empty", uri.rawQuery.isNullOrEmpty())
            .put("fragment_present", !uri.rawFragment.isNullOrEmpty())
        val data = runCatching {
            val bytes = Base64.getDecoder().decode(uri.fragment.orEmpty())
            require(bytes.size <= 65536)
            try { JSONObject(String(bytes, Charsets.UTF_8)) } finally { bytes.fill(0) }
        }.getOrNull()
        info.put("json_valid", data != null)
        return if (data == null) info else info.put("fields", dataDiagnostics(data, provider))
    }
    fun dataDiagnostics(data: JSONObject, provider: String): JSONObject = JSONObject()
        .put("driver_matches", data.optString("driver_txt") in variants[provider].orEmpty())
        .put("access_valid", validToken(data.optString("access_token")))
        .put("refresh_valid", validToken(data.optString("refresh_token")))
        .put("error_present", data.optString("message_err").isNotEmpty())
        .put("server_use_present", data.has("server_use"))
        .put("server_use_true", data.opt("server_use") == true || data.optString("server_use") == "true")
        .put("public_fields_empty", listOf("client_uid", "client_key", "secret_key").all { data.optString(it).isEmpty() })
    private fun validToken(value: String) = value.length in 1..32768 && value.none { it.isWhitespace() || it.code < 32 || it.code == 127 }

    fun readResultScript(provider: String): String {
        val variant = JSONObject.quote(variants.getValue(provider).first())
        return """(function(){
          if(location.origin!=='https://api.oplist.org'||location.pathname!=='/')return '';
          function value(id){var e=document.getElementById(id);return e&&e.value?e.value.slice(0,32769):'';}
          var access=value('access-token'),refresh=value('refresh-token');
          if(!refresh){
            var fields=document.querySelectorAll('.token-card textarea[readonly]');
            if(fields.length>=2){access=fields[0].value.slice(0,32769);refresh=fields[1].value.slice(0,32769);}
          }
          if(!refresh)return '';
          return JSON.stringify({driver_txt:$variant,access_token:access,refresh_token:refresh,server_use:true});
        })()"""
    }
}