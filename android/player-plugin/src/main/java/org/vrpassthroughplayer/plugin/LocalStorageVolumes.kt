package org.vrpassthroughplayer.plugin

import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

internal object LocalStorageVolumePolicy {
    fun mounted(state: String) = state == "mounted" || state == "mounted_ro"
    fun removable(removable: Boolean, primary: Boolean, emulated: Boolean) = removable && !primary && !emulated
    fun legacyCandidates(uuid: String?, appDirectories: List<String>): List<String> {
        val candidates = mutableListOf<String>()
        if (uuid != null && Regex("[A-Za-z0-9-]{1,64}").matches(uuid)) candidates.add("/storage/$uuid")
        for (path in appDirectories) {
            val marker = path.indexOf("/Android/data/")
            if (marker > 0) candidates.add(path.substring(0, marker))
        }
        return candidates.distinct()
    }
    // Third-party apps cannot call StorageManager.unmount. These open the system's own UI.
    fun openEjectSettings(launch: (String) -> Unit): Boolean {
        for (action in listOf(Settings.ACTION_MEMORY_CARD_SETTINGS, Settings.ACTION_INTERNAL_STORAGE_SETTINGS)) {
            try { launch(action); return true } catch (_: Exception) { }
        }
        return false
    }
}

internal object LocalStorageVolumes {
    fun roots(context: Context): JSONArray {
        val result = JSONArray()
        val manager = context.getSystemService(StorageManager::class.java) ?: return result
        for (volume in manager.storageVolumes) {
            if (!LocalStorageVolumePolicy.mounted(volume.state)) continue
            val directory = if (Build.VERSION.SDK_INT >= 30) volume.directory else if (volume.isPrimary)
                Environment.getExternalStorageDirectory() else {
                // Android 10 has no public StorageVolume.directory. Verify every fallback through
                // the public manager; a UUID-shaped path alone is never considered a mounted disk.
                fun verified(paths: List<String>) = paths.asSequence().map(::File).firstOrNull {
                    runCatching { manager.getStorageVolume(it) == volume }.getOrDefault(false)
                }
                verified(LocalStorageVolumePolicy.legacyCandidates(volume.uuid, emptyList()))
                    ?: verified(LocalStorageVolumePolicy.legacyCandidates(volume.uuid,
                        context.getExternalFilesDirs(null).filterNotNull().map { it.absolutePath }))
            }
            if (directory == null) continue
            result.put(JSONObject().put("id",directory.absolutePath).put("title",volume.getDescription(context))
                .put("container",true).put("volume",true).put("uuid",volume.uuid ?: "")
                .put("removable",LocalStorageVolumePolicy.removable(volume.isRemovable,volume.isPrimary,volume.isEmulated))
                .put("read_only",volume.state == Environment.MEDIA_MOUNTED_READ_ONLY))
        }
        return result
    }
}
