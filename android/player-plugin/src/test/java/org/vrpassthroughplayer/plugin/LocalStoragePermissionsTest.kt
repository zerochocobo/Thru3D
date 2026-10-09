package org.vrpassthroughplayer.plugin

import android.provider.Settings
import org.junit.Assert.*
import org.junit.Test

class LocalStoragePermissionsTest {
    @Test fun android10NeedsBothLegacyStorageAndTheReadGrant() {
        assertFalse(LocalStoragePermissions.allFiles(29, false, true, false))
        assertFalse(LocalStoragePermissions.allFiles(29, false, false, true))
        assertTrue(LocalStoragePermissions.allFiles(29, false, true, true))
    }

    @Test fun android11AndNewerRequireTheManagerGrant() {
        for (sdk in listOf(30, 32, 33, 36)) {
            assertFalse(LocalStoragePermissions.allFiles(sdk, false, true, true))
            assertTrue(LocalStoragePermissions.allFiles(sdk, true, false, false))
        }
    }

    @Test fun oldPicoOsDoesNotLaunchNonexistentAllFilesSettings() {
        assertEquals(listOf(Settings.ACTION_APPLICATION_DETAILS_SETTINGS), LocalStoragePermissions.settingsActions(29))
    }

    @Test fun appSpecificSettingsFallBackToGlobalThenApplicationDetails() {
        val attempts = mutableListOf<String>()
        assertTrue(LocalStoragePermissions.openSettings(32) {
            attempts += it
            if (it != Settings.ACTION_APPLICATION_DETAILS_SETTINGS) throw IllegalStateException("Unavailable activity")
        })
        assertEquals(listOf(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
            Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION, Settings.ACTION_APPLICATION_DETAILS_SETTINGS), attempts)
    }

    @Test fun firstSupportedPageStopsTheFallbackAndNoPageReportsFailure() {
        var attempts = 0
        assertTrue(LocalStoragePermissions.openSettings(36) { attempts++ })
        assertEquals(1, attempts)
        attempts = 0
        assertFalse(LocalStoragePermissions.openSettings(29) { attempts++; throw SecurityException("Denied") })
        assertEquals(1, attempts)
    }
}
