package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI

/** Same public nonce exchange used by OpenList's quarkpan_oa.ts. No custom app
 * credentials or generic endpoint are accepted; raw results stay in native code. */
internal object OpenListQuarkExchange {
    fun exchange(nonce: String): JSONObject {
        require(nonce.matches(Regex("[A-Za-z0-9_-]{16,256}")))
        val connection = URI("https://oauth.fnnas.com/api/v1/oauth/exchangeToken").toURL().openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 20000; connection.readTimeout = 30000
            connection.requestMethod = "POST"; connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Accept", "application/json")
            val body = JSONObject().put("authType", 4).put("nonce", nonce).put("trimAppId", "com.trim.cloudstorage")
                .toString().toByteArray(Charsets.UTF_8)
            try { connection.outputStream.use { it.write(body) } } finally { body.fill(0) }
            require(connection.responseCode == 200)
            val bytes = ByteArrayOutputStream()
            connection.inputStream.use { input ->
                val buffer = ByteArray(4096)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    require(bytes.size() + count <= 65536)
                    bytes.write(buffer, 0, count)
                }
                buffer.fill(0)
            }
            val raw = bytes.toByteArray()
            return try { JSONObject(String(raw, Charsets.UTF_8)) } finally { raw.fill(0) }
        } finally { connection.disconnect() }
    }
}
