package org.vrpassthroughplayer.plugin

import org.junit.Assert.assertEquals
import org.junit.Test

class UiLanguageTest {
    @Test fun systemLocalesRespectScriptBeforeRegion() {
        mapOf("en-US" to "en", "ja-JP" to "ja", "zh-CN" to "zh", "zh-SG" to "zh",
            "zh-TW" to "zh_Hant", "zh-HK" to "zh_Hant", "zh-MO" to "zh_Hant",
            "zh-Hant-CN" to "zh_Hant", "zh-Hans-TW" to "zh", "fr-FR" to "en", "" to "en")
            .forEach { (locale, expected) -> assertEquals(locale, expected, UiLanguage.resolve("auto", locale)) }
    }
    @Test fun explicitChoiceOverridesSystemAndKeepsLegacyChinese() {
        for (choice in listOf("en", "ja", "zh", "zh_Hant")) {
            assertEquals(choice, UiLanguage.resolve(choice, "zh-TW"))
        }
        assertEquals("ja", UiLanguage.resolve("invalid", "ja-JP"))
    }
}
