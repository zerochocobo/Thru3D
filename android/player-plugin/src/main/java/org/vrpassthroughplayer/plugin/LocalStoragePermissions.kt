package org.vrpassthroughplayer.plugin

import android.provider.Settings

/** Android 10 uses a runtime read grant; Android 11+ uses the all-files settings. */
internal object LocalStoragePermissions {
    fun allFiles(sdk: Int, manager: Boolean, legacy: Boolean, readGranted: Boolean): Boolean =
        if (sdk >= 30) manager else legacy && readGranted

    fun settingsActions(sdk: Int): List<String> = if (sdk >= 30) listOf(
        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
        Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION,
        Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
        else listOf(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)

    fun openSettings(sdk: Int, launch: (String) -> Unit): Boolean {
        for (action in settingsActions(sdk)) {
            try { launch(action); return true } catch (_: Exception) { /* Try the next supported page. */ }
        }
        return false
    }
}
