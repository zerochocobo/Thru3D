package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class CloudWebNavigationTest {
    @Test fun loginFramesCanInitializeWithoutOpeningExternalNavigation() {
        assertTrue(CloudWebNavigation.allowed("about:blank", "115", false))
        assertFalse(CloudWebNavigation.allowed("about:blank", "115", true))
        assertTrue(CloudWebNavigation.allowed("https://passport.115.com/", "115", true))
        assertTrue(CloudWebNavigation.allowed("https://passport.baidu.com/", "baidu", false))
        for (url in listOf("https://115.com.evil.test/", "https://user@115.com/", "http://115.com/", "file:///x", "intent://115.com/", "https://115.com:8443/")) {
            assertFalse(url, CloudWebNavigation.allowed(url, "115", true))
            assertFalse(url, CloudWebNavigation.allowed(url, "115", false))
        }
    }
}
