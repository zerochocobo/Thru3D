package org.vrpassthroughplayer.plugin

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.attribute.BasicFileAttributes
import org.json.JSONObject

/** Captures every child, including non-media and hidden files. Plans never follow links. */
internal class DeleteTree(val entries: List<Entry>) {
    data class Entry(val path: String, val folder: Boolean, val size: Long, val modified: Long)
    val fingerprint: String = java.security.MessageDigest.getInstance("SHA-256")
        .digest(entries.sortedBy { it.path }.joinToString("\n") { JSONObject().put("path", it.path).put("dir", it.folder)
            .put("size", it.size).put("modified", it.modified).toString() }.toByteArray()).joinToString("") { "%02x".format(it) }
    fun summary() = JSONObject().put("plan", fingerprint).put("files", entries.count { !it.folder })
        .put("folders", entries.count { it.folder } - 1).put("preview", true)
    fun verify(request: JSONObject) { check(request.optString("plan") == fingerprint) { "Folder changed; check its contents again" } }
    companion object {
        const val LIMIT = 20_000
        fun local(root: File): DeleteTree {
            val entries = ArrayList<Entry>()
            fun visit(file: File, relative: String, depth: Int) {
                check(depth <= 64 && entries.size < LIMIT) { "Folder too large to delete" }
                val attributes = Files.readAttributes(file.toPath(), BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
                check(!attributes.isSymbolicLink && (attributes.isDirectory || attributes.isRegularFile)) { "Folder contains unsupported links" }
                entries.add(Entry(relative, attributes.isDirectory, if (attributes.isDirectory) 0 else attributes.size(), attributes.lastModifiedTime().toMillis()))
                if (attributes.isDirectory) {
                    check(file.canonicalPath == file.absolutePath) { "Folder contains unsupported links" }
                    val children = file.listFiles() ?: error("File deletion permission denied")
                    children.forEach { visit(it, if (relative.isEmpty()) it.name else "$relative/${it.name}", depth + 1) }
                }
            }
            visit(root, "", 0)
            return DeleteTree(entries)
        }
    }
}
