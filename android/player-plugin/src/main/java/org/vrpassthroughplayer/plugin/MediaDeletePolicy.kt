package org.vrpassthroughplayer.plugin

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption

internal object MediaDeletePolicy {
    fun local(file: File, roots: List<File>, folder: Boolean = false): File {
        require(file.isAbsolute && (folder || MediaKinds.supported(file.name))) { "File deletion unavailable for this source" }
        val path = file.toPath().normalize()
        require(file.absolutePath == path.toString() && file.canonicalPath == file.absolutePath) { "File changed; refresh the folder" }
        require(roots.any { path.startsWith(it.canonicalFile.toPath()) && path != it.canonicalFile.toPath() }) { "File deletion unavailable for this source" }
        require(!(path.toString().replace('\\', '/') + "/").contains("/Android/")) { "File deletion unavailable for this source" }
        return file
    }
    fun unchanged(size: Long, modified: Long, expectedSize: Long, expectedModified: Long) {
        check(size == expectedSize && (expectedModified < 0 || modified == expectedModified)) { "File changed; refresh the folder" }
    }
    fun regular(file: File) = Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS)
    fun smbPath(path: String, folder: Boolean = false): String {
        val parts = path.split('/')
        require(parts.size >= 2 && parts.none { it.isEmpty() || it in setOf(".", "..") || it.any { c -> c in "\\\u0000:?*#%" } }
            && (folder || MediaKinds.supported(parts.last()))) { "File deletion unavailable for this source" }
        return path
    }
}
