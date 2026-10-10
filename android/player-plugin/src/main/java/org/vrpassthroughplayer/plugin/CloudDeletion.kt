package org.vrpassthroughplayer.plugin

import org.json.JSONObject

/** Only ordinary 115 delete, never recycle-bin purge. All checks bypass display snapshots. */
internal class CloudDeletion(private val client: CloudClient, private val authorized: () -> Unit = {}) {
    private fun fresh(path: String): CloudFile? {
        val parent = path.substringBeforeLast('/').ifEmpty { "/" }
        val name = path.substringAfterLast('/')
        var offset = 0
        val seen = HashSet<String>()
        var count = 0
        while (true) {
            val page = client.page(parent, offset, offset == 0)
            for (file in page.files) {
                check(seen.add(file.objectId)) { "Cloud file changed. Refresh the folder" }
                if (file.name == name) return file
            }
            count += page.files.size
            check(count <= DeleteTree.LIMIT && (page.nextOffset < 0 || page.nextOffset > offset)) { "Cloud folder too large" }
            if (page.nextOffset < 0) return null
            offset = page.nextOffset
        }
    }
    fun run(path: String, request: JSONObject, inspect: Boolean, prepare: Boolean): JSONObject {
        require(client.canDelete && path != "/" && path.startsWith('/') && !path.endsWith('/') &&
            path.removePrefix("/").split('/').none { it.isEmpty() || it in setOf(".", "..") || '\u0000' in it })
        require(request.optBoolean("folder") || MediaKinds.supported(path.substringAfterLast('/'))) { "File deletion unavailable for this source" }
        val expected = request.getString("cloud_id")
        require(expected.matches(Regex("[1-9][0-9]*")))
        val file = fresh(path)
        if (inspect) return JSONObject().put("exists", file != null).put("changed", file != null && file.objectId != expected)
        check(file != null && file.objectId == expected && file.folder == request.optBoolean("folder")) { "Cloud file changed. Refresh the folder" }
        check(file.canDelete) { "File deletion permission denied" }
        if (!file.folder) MediaDeletePolicy.unchanged(file.size, file.modified, request.getLong("size"), request.optLong("modified", -1))
        if (file.folder) {
            val entries = ArrayList<DeleteTree.Entry>()
            val seen = HashSet<String>()
            fun visit(current: CloudFile, currentPath: String, relative: String, depth: Int) {
                check(depth <= 64 && entries.size < DeleteTree.LIMIT && seen.add(current.objectId)) { "Folder too large to delete" }
                check(current.canDelete) { "File deletion permission denied" }
                entries.add(DeleteTree.Entry(org.json.JSONArray(listOf(relative, current.objectId)).toString(), current.folder, if (current.folder) 0 else current.size, current.modified))
                if (!current.folder) return
                var offset = 0
                while (true) {
                    val page = client.page(currentPath, offset, offset == 0)
                    page.files.forEach { visit(it, CloudPaths.child(currentPath, it.name), CloudPaths.child("/" + relative, it.name).removePrefix("/"), depth + 1) }
                    if (page.nextOffset < 0) break
                    check(page.nextOffset > offset) { "Cloud file changed. Refresh the folder" }; offset = page.nextOffset
                }
            }
            visit(file, path, "", 0)
            val plan = DeleteTree(entries)
            if (prepare) return plan.summary()
            plan.verify(request)
        }
        authorized() // Check account identity again immediately before the write.
        try { client.remove(path, file) }
        catch (_: Exception) { /* An error can follow a successful delete. Read back, never replay. */ }
        return try {
            val remaining = fresh(path)
            if (remaining == null) JSONObject().put("deleted", true)
            else JSONObject().put("state", "uncertain").put("error", "Delete result needs checking")
        } catch (_: Exception) { JSONObject().put("state", "uncertain").put("error", "Delete result needs checking") }
    }
}
