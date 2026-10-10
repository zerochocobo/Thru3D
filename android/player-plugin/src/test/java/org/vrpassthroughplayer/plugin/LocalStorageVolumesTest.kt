package org.vrpassthroughplayer.plugin

import android.provider.Settings
import org.junit.Assert.*
import org.junit.Test

class LocalStorageVolumesTest {
    @Test fun onlyMountedAndReadOnlyMountedVolumesAreAccessible() {
        assertTrue(LocalStorageVolumePolicy.mounted("mounted"))
        assertTrue(LocalStorageVolumePolicy.mounted("mounted_ro"))
        for (state in listOf("unmounted","removed","bad_removal","checking","ejecting","unmountable"))
            assertFalse(LocalStorageVolumePolicy.mounted(state))
    }
    @Test fun internalAndEmulatedStorageCannotBeEjected() {
        assertTrue(LocalStorageVolumePolicy.removable(true,false,false))
        assertFalse(LocalStorageVolumePolicy.removable(true,true,false))
        assertFalse(LocalStorageVolumePolicy.removable(true,false,true))
        assertFalse(LocalStorageVolumePolicy.removable(false,false,false))
    }
    @Test fun android10CandidatesIncludePublicUuidAndAppStorageRootsWithoutDuplicates() {
        assertEquals(listOf("/storage/1234-5678","/mnt/external_usb"),
            LocalStorageVolumePolicy.legacyCandidates("1234-5678",listOf(
                "/storage/1234-5678/Android/data/com.wapok.thru3d/files",
                "/mnt/external_usb/Android/data/com.wapok.thru3d/files")))
        assertTrue(LocalStorageVolumePolicy.legacyCandidates("../../emulated/0",emptyList()).isEmpty())
        assertTrue(LocalStorageVolumePolicy.legacyCandidates(null,listOf("/not/an/app/root")).isEmpty())
    }
    @Test fun settingsFallbackCannotPretendToUnmountWhenNoPageExists() {
        val attempts = mutableListOf<String>()
        assertTrue(LocalStorageVolumePolicy.openEjectSettings {
            attempts.add(it)
            if (it == Settings.ACTION_MEMORY_CARD_SETTINGS) throw IllegalStateException("No activity")
        })
        assertEquals(listOf(Settings.ACTION_MEMORY_CARD_SETTINGS,Settings.ACTION_INTERNAL_STORAGE_SETTINGS),attempts)
        attempts.clear()
        assertFalse(LocalStorageVolumePolicy.openEjectSettings { attempts.add(it); throw SecurityException("Not exported") })
        assertEquals(2,attempts.size)
    }
}
