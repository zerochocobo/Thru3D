package org.vrpassthroughplayer.plugin

/** libc unlink has a file-only contract; Java/Os.remove also allow empty directories. */
internal object NativeMediaDelete {
    init { System.loadLibrary("quest_rvm") }
    external fun unlink(pathUtf8: ByteArray): Int
    external fun removeAt(rootUtf8: ByteArray, relativeUtf8: ByteArray, directory: Boolean): Int
    external fun renameAt(parentUtf8: ByteArray, oldUtf8: ByteArray, newUtf8: ByteArray): Int
}
