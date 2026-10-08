package org.vrpassthroughplayer.plugin

/** Bounded transient input. Snapshot APIs expose only the length of secret fields. */
internal class AccountInput(private val limit: Int = 2048) {
    private val chars = CharArray(limit)
    var length = 0
        private set
    @Synchronized fun append(text: String) {
        if (text.any { it == '\u0000' || it == '\n' || it == '\r' }) return
        var at = 0
        while (at < text.length) {
            val c = text[at]
            val count = if (Character.isHighSurrogate(c) && at + 1 < text.length && Character.isLowSurrogate(text[at + 1])) 2 else 1
            if (length + count > limit) break
            repeat(count) { chars[length++] = text[at++] }
        }
    }
    @Synchronized fun backspace() {
        if (length > 0) {
            val last = chars[--length]; chars[length] = '\u0000'
            if (Character.isLowSurrogate(last) && length > 0 && Character.isHighSurrogate(chars[length - 1])) chars[--length] = '\u0000'
        }
    }
    @Synchronized fun clear() { chars.fill('\u0000'); length = 0 }
    @Synchronized fun copy() = chars.copyOf(length)
    @Synchronized fun text() = String(chars, 0, length)
}
