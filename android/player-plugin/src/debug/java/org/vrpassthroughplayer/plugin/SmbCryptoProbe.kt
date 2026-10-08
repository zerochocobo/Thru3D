package org.vrpassthroughplayer.plugin

import org.codelibs.jcifs.smb.DialectVersion
import org.codelibs.jcifs.smb.config.PropertyConfiguration
import org.codelibs.jcifs.smb.context.BaseContext
import org.codelibs.jcifs.smb.internal.smb2.Smb2EncryptionContext
import org.json.JSONObject

/** Exercises the packaged Android crypto implementation without account credentials. */
internal object SmbCryptoProbe {
    fun run(): JSONObject {
        val config = PropertyConfiguration(SmbClientPolicy.properties(false))
        check(config.maximumVersion == DialectVersion.SMB311 && config.isEncryptionEnabled)
        BaseContext(config).close()
        val key = ByteArray(16) { it.toByte() }
        val data = ByteArray(4097) { (it * 17).toByte() }
        for (cipher in listOf(1, 2)) {
            val crypto = Smb2EncryptionContext(cipher, if (cipher == 1) DialectVersion.SMB300 else DialectVersion.SMB311, key, key)
            val encrypted = crypto.encryptMessage(data, 7)
            check(crypto.decryptMessage(encrypted).contentEquals(data))
            encrypted[encrypted.lastIndex] = (encrypted.last().toInt() xor 1).toByte()
            check(runCatching { crypto.decryptMessage(encrypted) }.isFailure)
        }
        return JSONObject().put("library", "CodeLibs JCIFS 3.0.4").put("aes_ccm", true).put("aes_gcm", true)
            .put("scope", "Android configuration and crypto; not remote SMB interoperability")
    }
}
