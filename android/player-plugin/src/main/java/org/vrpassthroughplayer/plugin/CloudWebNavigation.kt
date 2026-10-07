package org.vrpassthroughplayer.plugin

import java.net.URI

internal object CloudWebNavigation {
    fun allowed(value: String, provider: String, mainFrame: Boolean): Boolean {
        // Login bridge frames are initialized with about:blank before navigation.
        if (!mainFrame && value == "about:blank") return true
        val uri = runCatching { URI(value) }.getOrNull() ?: return false
        val domain = if (provider == CloudDrive.P115) "115.com" else "baidu.com"
        return uri.scheme == "https" && uri.rawUserInfo == null && uri.port in setOf(-1, 443) &&
            CloudDrive.within(uri.host, domain)
    }
}
