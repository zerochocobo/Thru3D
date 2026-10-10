package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CloudDeletionTest {
    private fun item(name: String, id: String, folder: Boolean = false, modified: Long = 10, writable: Boolean = true) =
        CloudFile(name, folder, 12, "/$name", modified = modified, objectId = id, canDelete = writable)
    private fun request(file: CloudFile) = JSONObject().put("cloud_id", file.objectId).put("folder", file.folder)
        .put("size", file.size).put("modified", file.modified)
    private class Fake : CloudClient {
        override val canDelete = true
        val folders = mutableMapOf<String, MutableList<CloudFile>>("/" to mutableListOf())
        val reads = mutableListOf<Triple<String, Int, Boolean>>()
        var writes = 0
        var mutate = true
        var loseResponse = false
        var failReadBack = false
        override fun page(path: String, offset: Int, refresh: Boolean): CloudPage {
            reads.add(Triple(path, offset, refresh))
            if (writes > 0 && failReadBack) throw CloudFailure()
            val all = folders[path] ?: emptyList()
            val end = minOf(offset + 48, all.size)
            return CloudPage(all.subList(offset, end), if (end < all.size) end else -1, all.size)
        }
        override fun remove(path: String, file: CloudFile) {
            writes++
            if (mutate) folders[path.substringBeforeLast('/').ifEmpty { "/" }]!!.removeAll { it.objectId == file.objectId }
            if (loseResponse) throw CloudFailure()
        }
        override fun list(path: String): List<CloudFile> = error("Deletion must bypass ordinary list snapshots")
        override fun find(path: String): CloudFile = error("Deletion must bypass cached playback lookup")
        override fun resolve(file: CloudFile): CloudLink = error("Deletion must never download media")
    }
    private fun rejected(block: () -> Unit) {
        try { block(); fail("Expected guarded refusal") } catch (_: IllegalArgumentException) {} catch (_: IllegalStateException) {}
    }
    @Test fun stableIdAndFreshReadRequiredBeforeSingleFileWrite() {
        val f = item("中文 #%.mp4", "9007199254740993")
        val client = Fake().apply { folders["/"]!!.add(f) }
        assertTrue(CloudDeletion(client).run("/"+f.name, request(f), false, false).getBoolean("deleted"))
        assertEquals(1, client.writes); assertTrue(client.reads.all { it.third })
    }
    @Test fun replacedPathAndChangedMetadataCannotDeleteAnotherFile() {
        val displayed = item("a.mp4", "9")
        val client = Fake().apply { folders["/"]!!.add(item("a.mp4", "10")) }
        rejected { CloudDeletion(client).run("/a.mp4", request(displayed), false, false) }
        client.folders["/"]!![0] = item("a.mp4", "9", modified = 11)
        rejected { CloudDeletion(client).run("/a.mp4", request(displayed), false, false) }
        assertEquals(0, client.writes)
        client.folders["/"]!![0] = item("a.mp4", "10")
        val checked = CloudDeletion(client).run("/a.mp4", request(displayed), true, false)
        assertTrue(checked.getBoolean("exists")); assertTrue(checked.getBoolean("changed"))
    }
    @Test fun folderPreviewIncludesHiddenAndUnsupportedFilesAcrossPages() {
        val folder = item("旅行", "1", true)
        val client = Fake().apply {
            folders["/"]!!.add(folder)
            folders["/旅行"] = (0 until 55).map { item("note-$it.txt", (100+it).toString()) }.toMutableList()
            folders["/旅行"]!!.add(item(".hidden.srt", "2"))
            folders["/旅行"]!!.add(item("配音", "3", true))
            folders["/旅行/配音"] = mutableListOf(item("travel.m4a", "4"))
        }
        val action = CloudDeletion(client); val req = request(folder)
        val preview = action.run("/旅行", req, false, true)
        assertEquals(57, preview.getInt("files")); assertEquals(1, preview.getInt("folders")); assertEquals(0, client.writes)
        assertTrue(client.reads.any { it.first == "/旅行" && it.second == 48 && !it.third })
        req.put("plan", preview.getString("plan"))
        assertTrue(action.run("/旅行", req, false, false).getBoolean("deleted")); assertEquals(1, client.writes)
    }
    @Test fun replacingAnInvisibleChildInvalidatesFolderConfirmation() {
        val folder = item("folder", "1", true)
        val client = Fake().apply { folders["/"]!!.add(folder); folders["/folder"] = mutableListOf(item(".hidden", "2")) }
        val req = request(folder).put("plan", CloudDeletion(client).run("/folder", request(folder), false, true).getString("plan"))
        client.folders["/folder"]!![0] = item(".hidden", "3")
        rejected { CloudDeletion(client).run("/folder", req, false, false) }; assertEquals(0, client.writes)
    }
    @Test fun lostSuccessResponseIsResolvedByReadBackWithoutRetry() {
        val file = item("a.mp4", "1")
        val client = Fake().apply { folders["/"]!!.add(file); loseResponse = true }
        assertTrue(CloudDeletion(client).run("/a.mp4", request(file), false, false).getBoolean("deleted"))
        assertEquals(1, client.writes)
    }
    @Test fun lostFailureResponseAndOfflineReadBackKeepUncertainState() {
        val file = item("a.mp4", "1")
        val client = Fake().apply { folders["/"]!!.add(file); mutate = false; loseResponse = true }
        val action = CloudDeletion(client)
        assertEquals("uncertain", action.run("/a.mp4", request(file), false, false).getString("state"))
        assertTrue(action.run("/a.mp4", request(file), true, false).getBoolean("exists")); assertEquals(1, client.writes)
        val offline = Fake().apply { folders["/"]!!.add(file); failReadBack = true }
        assertEquals("uncertain", CloudDeletion(offline).run("/a.mp4", request(file), false, false).getString("state"))
        assertEquals(1, offline.writes)
    }
    @Test fun rootForgedIdPermissionAndDisabledGateAreRefused() {
        val file = item("a.mp4", "1", writable = false)
        val client = Fake().apply { folders["/"]!!.add(file) }
        rejected { CloudDeletion(client).run("/", request(file), false, false) }
        rejected { CloudDeletion(client).run("/a.mp4", request(file).put("cloud_id", "1,2"), false, false) }
        rejected { CloudDeletion(client).run("/a.mp4", request(file), false, false) }
        client.folders["/"]!![0] = item("a.mp4", "1")
        rejected { CloudDeletion(client) { error("File management is off") }.run("/a.mp4", request(file), false, false) }
        assertEquals(0, client.writes)
    }
    @Test fun readOnlyProviderCannotUseDeleteAndNew115EntryIsOpenOnly() {
        val client = object : CloudClient {
            override fun page(path: String, offset: Int, refresh: Boolean): CloudPage = error("Must refuse before network")
            override fun list(path: String): List<CloudFile> = error("unused")
            override fun find(path: String): CloudFile = error("unused")
            override fun resolve(file: CloudFile): CloudLink = error("unused")
        }
        rejected { CloudDeletion(client).run("/a.mp4", request(item("a.mp4", "1")), false, false) }
        assertFalse(CloudDrive.PROVIDERS.containsKey(CloudDrive.P115))
        assertEquals(CloudDrive.OPEN115, CloudDrive.PROVIDERS.keys.first())
    }
}
