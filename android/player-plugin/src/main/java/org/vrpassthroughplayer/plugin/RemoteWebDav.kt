package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.net.URI

/** Remote server credentials stay in the encrypted OpenList addition; UI only sees metadata. */
internal object RemoteWebDav {
    class Connection(val base: String, val username: String, private val password: String) {
        val hasPassword get() = password.isNotEmpty()
        fun addition() = JSONObject().put("address", base).put("username", username).put("password", password)
            .put("vendor", "other").put("root_folder_path", "/").put("tls_insecure_skip_verify", false)
        fun metadata() = JSONObject().put("base", base).put("username", username).put("has_password", hasPassword)
        internal fun retainedPassword(nextBase: String, nextUser: String) =
            if (base == nextBase && username == nextUser) password else ""
    }
    fun address(raw: String): String {
        val value = MediaServerAccount.address(raw)
        val uri = URI(value)
        mediaRequire(uri.port != 0 && uri.path.orEmpty().split('/').none { it == "." || it == ".." } &&
            uri.path.orEmpty().none { it == '\\' || it.isISOControl() }, "Invalid server address")
        return value
    }
    fun connection(base: String, username: String, password: String, previous: Connection? = null): Connection {
        val address = address(base)
        val user = username.trim()
        mediaRequire(user.length <= 2048 && user.none(Char::isISOControl) && password.length <= 2048 &&
            password.none(Char::isISOControl), "Invalid server response")
        val secret = password.ifEmpty { previous?.retainedPassword(address, user).orEmpty() }
        return Connection(address, user, secret)
    }
    fun retainsSavedLogin(metadata: JSONObject?, base: String, username: String): Boolean = runCatching {
        metadata != null && metadata.optBoolean("has_password") && address(base) == metadata.getString("base") &&
            username.trim() == metadata.optString("username")
    }.getOrDefault(false)
    fun fromAddition(addition: JSONObject) = connection(addition.getString("address"),
        addition.optString("username"), addition.optString("password"))
}
