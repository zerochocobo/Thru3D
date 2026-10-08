package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import java.net.URLDecoder

class CloudPaginationTest {
    private fun args(url: String) = URI(url).rawQuery.split('&').associate {
        URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('='), "UTF-8")
    }
    private fun response(offset: Int, count: Int, size: Int = CloudDrive.PAGE_SIZE): CloudResponse {
        val data = JSONArray()
        for (i in offset until minOf(offset + size, count)) {
            data.put(if (i % 2 == 0) JSONObject().put("cid", "${9007199254740993L + i}").put("n", "目录 $i")
                else JSONObject().put("fid", "${9007199254740993L + i}").put("n", "片名 $i.mp4").put("s", 999).put("pc", "pick-$i"))
        }
        return CloudResponse(JSONObject().put("state", true).put("offset", offset).put("count", count).put("data", data))
    }
    @Test fun tenThousandEntriesFetchOnlyRequestedPagesAndReuseMetadataForPlaybackAndFolders() {
        val requests = ArrayList<Map<String, String>>()
        val drive = CloudDrive(CloudDrive.P115, "UID=test", CloudTransport { url, _, _ ->
            assertEquals("/files", URI(url).path) // Known folder IDs never need getid.
            val query = args(url); requests.add(query)
            assertEquals("48", query["limit"])
            response(query.getValue("offset").toInt(), if (query["cid"] == "0") 10_001 else 0)
        })
        val first = drive.page("/")
        assertEquals(1, requests.size); assertEquals(48, first.files.size)
        assertEquals(10_001, first.total); assertEquals(48, first.nextOffset)
        val next = drive.page("/", first.nextOffset)
        assertEquals(2, requests.size); assertEquals(96, next.nextOffset)
        assertSame(first, drive.page("/"))
        assertEquals("pick-49", drive.find("/片名 49.mp4").pickCode)
        assertEquals(2, requests.size)
        assertTrue(drive.page("/目录 0").files.isEmpty())
        assertEquals("9007199254740993", requests.last()["cid"])
        val last = drive.page("/", 9984)
        assertEquals(17, last.files.size); assertEquals(-1, last.nextOffset)
    }
    @Test fun laterFailureKeepsEarlierPageAndCanRetryWithoutRereadingIt() {
        var fail = true
        var requests = 0
        val drive = CloudDrive(CloudDrive.P115, "UID=test", CloudTransport { url, _, _ ->
            requests++
            val offset = args(url).getValue("offset").toInt()
            if (offset > 0 && fail) throw CloudFailure()
            response(offset, 3001)
        })
        val first = drive.page("/")
        try { drive.page("/", 48); fail() } catch (_: CloudFailure) {}
        assertSame(first, drive.page("/")); assertEquals(2, requests)
        fail = false
        assertEquals(48, drive.page("/", 48).files.size); assertEquals(3, requests)
    }
    @Test fun allThreeThousandMixedEntriesHaveNoMissingOrDuplicateIds() {
        var requests = 0
        val drive = CloudDrive(CloudDrive.P115, "UID=test", CloudTransport { url, _, _ ->
            requests++; response(args(url).getValue("offset").toInt(), 3001)
        })
        val files = drive.list("/")
        assertEquals(3001, files.size)
        assertEquals(3001, files.map { it.id }.toSet().size)
        assertEquals(63, requests)
    }
    @Test fun uncachedHistoryStopsAtMatchingPageInsteadOfScanningWholeParent() {
        var requests = 0
        val drive = CloudDrive(CloudDrive.P115, "UID=test", CloudTransport { url, _, _ ->
            requests++; response(args(url).getValue("offset").toInt(), 10001)
        })
        assertEquals("pick-49", drive.find("/片名 49.mp4").pickCode)
        assertEquals(2, requests)
    }
    @Test fun refreshAndExpiryInvalidateMetadataAndAccountsStaySeparate() {
        var time = 0L
        val metadata = CloudMetadata { time }
        var requests = 0
        val transport = CloudTransport { _, _, _ -> requests++; response(0, 3) }
        val drive = CloudDrive(CloudDrive.P115, "UID=a", transport, metadata)
        drive.page("/"); drive.page("/"); assertEquals(1, requests)
        CloudDrive(CloudDrive.P115, "UID=b", transport).page("/"); assertEquals(2, requests)
        drive.page("/", refresh = true); assertEquals(3, requests)
        time = 120_001
        assertNull(metadata.file("/片名 1.mp4"))
        drive.page("/"); assertEquals(4, requests)
        repeat(100) { metadata.put("/", it, CloudPage(emptyList(), -1)) }
        assertNull(metadata.page("/", 0))
        repeat(20_001) { metadata.put("/$it", CloudFile("$it", true, 0, "$it")) }
        assertNull(metadata.file("/0"))
    }
    @Test fun malformedPaginationCannotSilentlyTruncateOrLoop() {
        for (mode in 0..3) {
            val drive = CloudDrive(CloudDrive.P115, "UID=test", CloudTransport { url, _, _ ->
                val offset = args(url).getValue("offset").toInt()
                if (offset == 0) response(0, 100) else when (mode) {
                    0 -> response(0, 100) // Server ignored offset.
                    1 -> response(0, 100).also { it.json.put("offset", offset) } // Repeated page.
                    2 -> response(offset, 100, 0) // Empty intermediate page.
                    else -> response(offset, 100).also {
                        it.json.getJSONArray("data").put(1, it.json.getJSONArray("data").getJSONObject(0))
                    }
                }
            })
            drive.page("/")
            try { drive.page("/", 48); fail("Accepted malformed page $mode") } catch (_: CloudFailure) {}
        }
    }
    @Test fun actualReturnedCountDrivesOffsetAndEmptyFolderEndsImmediately() {
        val drive = CloudDrive(CloudDrive.P115, "UID=test", CloudTransport { url, _, _ ->
            val offset = args(url).getValue("offset").toInt()
            response(offset, 5, 3)
        })
        assertEquals(3, drive.page("/").nextOffset)
        assertEquals(-1, drive.page("/", 3).nextOffset)
        val empty = CloudDrive(CloudDrive.P115, "UID=test", CloudTransport { _, _, _ -> response(0, 0) }).page("/")
        assertEquals(-1, empty.nextOffset); assertTrue(empty.files.isEmpty())
    }
}
