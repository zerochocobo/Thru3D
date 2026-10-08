package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class AccountInputTest {
    @Test fun boundsAndSecretsAreIndependentSnapshots() {
        val input = AccountInput(8)
        input.append("abc123456")
        assertEquals(8, input.length)
        val snapshot = input.copy()
        input.clear()
        assertEquals(0, input.length)
        assertEquals("abc12345", String(snapshot))
        snapshot.fill('\u0000')
        input.append("fresh")
        assertEquals("fresh", input.text())
    }
    @Test fun deletingPastedUnicodeRemovesWholeCharacter() {
        val input = AccountInput()
        input.append("名称😀")
        input.backspace()
        assertEquals("名称", input.text())
        input.backspace(); input.backspace(); input.backspace()
        assertEquals(0, input.length)
    }
    @Test fun multilineAndNulCannotBecomeCredentialInput() {
        val input = AccountInput()
        input.append("valid"); input.append("bad\nline"); input.append("nul\u0000")
        assertEquals("valid", input.text())
    }
    @Test fun limitCannotSplitSurrogatePair() {
        val input = AccountInput(2)
        input.append("a😀")
        assertEquals("a", input.text())
    }
}
