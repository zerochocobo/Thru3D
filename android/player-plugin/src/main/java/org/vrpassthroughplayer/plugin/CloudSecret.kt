package org.vrpassthroughplayer.plugin

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec

/** The Go database key is wrapped by a non-exportable Android Keystore key. */
internal object CloudSecret {
    private const val ALIAS = "quest_player_cloud_v1"
    fun key(context: Context): String {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val wrapper = (store.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey ?: KeyGenerator
            .getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            }.generateKey()
        val file = AtomicFile(File(context.noBackupFilesDir, "cloud-key.bin"))
        val key = if (file.baseFile.exists() || File(file.baseFile.path + ".bak").exists()) {
            val data = file.readFully()
            require(data.size >= 28)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, wrapper, GCMParameterSpec(128, data, 0, 12))
            }
            cipher.doFinal(data, 12, data.size - 12)
        } else {
            val fresh = ByteArray(32).also { SecureRandom().nextBytes(it) }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, wrapper) }
            val output = file.startWrite()
            try { output.write(cipher.iv + cipher.doFinal(fresh)); file.finishWrite(output) }
            catch (error: Exception) { file.failWrite(output); throw error }
            fresh
        }
        require(key.size == 32)
        return key.joinToString("") { "%02x".format(it.toInt() and 255) }.also { key.fill(0) }
    }
}
