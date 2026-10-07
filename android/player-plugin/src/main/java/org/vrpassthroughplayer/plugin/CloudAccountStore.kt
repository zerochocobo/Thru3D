package org.vrpassthroughplayer.plugin

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import org.json.JSONArray
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec

/** Separate from the retired Go database. Cookies never enter backups or Godot. */
internal class CloudAccountStore(context: Context, filename: String = "cloud-accounts-v2.bin", keyAlias: String = "quest_player_cloud_accounts_v2") {
    private val file = AtomicFile(File(context.noBackupFilesDir, filename))
    private val key by lazy { synchronized(KEY_LOCK) {
        val alias = keyAlias
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.secretKey ?: KeyGenerator
            .getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
            }.generateKey()
    } }

    companion object { private val KEY_LOCK = Any() }

    @Synchronized fun load(): JSONArray {
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return JSONArray()
        val encrypted = file.readFully()
        require(encrypted.size in 28..1024 * 1024)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, encrypted, 0, 12))
        }
        val plain = cipher.doFinal(encrypted, 12, encrypted.size - 12)
        return try { JSONArray(String(plain, Charsets.UTF_8)) } finally { plain.fill(0) }
    }

    @Synchronized fun save(accounts: JSONArray) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key) }
        val plain = accounts.toString().toByteArray(Charsets.UTF_8)
        val encrypted = try { cipher.iv + cipher.doFinal(plain) } finally { plain.fill(0) }
        val output = file.startWrite()
        try { output.write(encrypted); file.finishWrite(output) }
        catch (error: Exception) { file.failWrite(output); throw error }
    }
}
