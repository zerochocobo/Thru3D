package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class CloudSortedPagesTest {
    private class Client(var files: List<CloudFile>) : CloudClient {
        var calls = 0
        var failOffset = -1
        override fun page(path: String, offset: Int, refresh: Boolean): CloudPage {
            calls++
            if (offset == failOffset) throw CloudFailure()
            val end = minOf(files.size, offset + 48)
            return CloudPage(files.subList(offset, end), if (end < files.size) end else -1, files.size)
        }
        override fun list(path: String) = files
        override fun find(path: String) = files.first { it.id == path }
        override fun resolve(file: CloudFile): CloudLink = error("Sort must never resolve media")
    }
    @Test fun sortsWholeDirectoryBeforePagingAndReusesSnapshotAcrossOrders() {
        val files = (1..100).reversed().map { CloudFile("video$it.mp4", false, it.toLong(), "$it", modified = it * 100L) }
        val client = Client(files + CloudFile("Folder", true, 0, "dir"))
        val cache = CloudSortedPages()
        val first = cache.page(client, "/", 0, false, "name_asc")
        assertTrue(first.files.first().folder)
        assertEquals("video1.mp4", first.files[1].name)
        assertEquals("video47.mp4", first.files.last().name)
        assertEquals("video48.mp4", cache.page(client, "/", 48, false, "name_asc").files.first().name)
        assertEquals("video100.mp4", cache.page(client, "/", 0, false, "size_desc").files[1].name)
        assertEquals(3, client.calls)
        cache.page(client, "/", 0, true, "modified_desc")
        assertEquals(6, client.calls)
    }
    @Test fun failedOrOversizedListingNeverCommitsPartialOrder() {
        val client = Client((1..60).map { CloudFile("$it.mp4", false, 1, "$it") })
        val cache = CloudSortedPages()
        client.failOffset = 48
        assertThrows(CloudFailure::class.java) { cache.page(client, "/", 0, false, "name_asc") }
        client.failOffset = -1
        assertEquals(60, cache.page(client, "/", 0, false, "name_asc").total)
        client.files = (1..20_001).map { CloudFile("$it.mp4", false, 1, "$it") }
        assertThrows(CloudFailure::class.java) { cache.page(client, "/", 0, true, "name_asc") }
    }
    @Test fun unknownTimesStayLastBothWaysAndNamesHandleHugeNumbers() {
        val files = listOf(CloudFile("Unknown.mp4", false, 1, "a"), CloudFile("Known.mp4", false, 1, "b", modified = 5))
        for (order in listOf("modified_asc", "modified_desc")) assertEquals("b", files.sortedWith(CloudSortedPages.comparator(order))[0].id)
        assertTrue(CloudSortedPages.natural("2.mp4", "10.mp4") < 0)
        assertTrue(CloudSortedPages.natural("100000000000000000000.mp4", "99999999999999999999.mp4") > 0)
        assertEquals(0, CloudSortedPages.natural("VIDEO02.mp4", "video2.mp4"))
    }
    @Test fun expirationRefreshesMetadata() {
        var now = 0L
        val cache = CloudSortedPages { now }
        val client = Client(listOf(CloudFile("1.mp4", false, 1, "1")))
        cache.page(client, "/", 0, false, "name_asc")
        now = 120_001
        client.files = listOf(CloudFile("2.mp4", false, 1, "2"))
        assertEquals("2", cache.page(client, "/", 0, false, "name_asc").files.single().id)
        assertEquals(2, client.calls)
    }
    @Test fun folderTimesSortBothWaysWithUnknownsLastAndNaturalNameTies() {
        val files = listOf(
            CloudFile("A10", true, 900, "10", modified = 100),
            CloudFile("Unknown", true, 800, "unknown"),
            CloudFile("B", true, 100, "b", modified = 300),
            CloudFile("A2", true, 700, "2", modified = 100),
            CloudFile("New.mp4", false, 1, "new", modified = 999),
            CloudFile("Old.mp4", false, 1, "old", modified = 1),
            CloudFile("Unknown.mp4", false, 1, "file-unknown"))
        fun ids(order: String) = files.sortedWith(CloudSortedPages.comparator(order)).map { it.id }
        assertEquals(listOf("2", "10", "b", "unknown", "old", "new", "file-unknown"), ids("modified_asc"))
        assertEquals(listOf("b", "2", "10", "unknown", "new", "old", "file-unknown"), ids("modified_desc"))
        for (order in listOf("size_asc", "size_desc"))
            assertEquals(listOf("2", "10", "b", "unknown"), ids(order).take(4))
        assertEquals(listOf("unknown", "b", "10", "2"), ids("name_desc").take(4))
    }
    @Test fun folderTimeOrderIsGlobalAcrossPageBoundaries() {
        val client = Client((1..100).map { CloudFile("Folder$it", true, 0, "$it", modified = it.toLong()) }
            + CloudFile("Newest.mp4", false, 1, "file", modified = 9999))
        val pages = CloudSortedPages()
        assertEquals("100", pages.page(client, "/", 0, false, "modified_desc").files.first().id)
        assertEquals("52", pages.page(client, "/", 48, false, "modified_desc").files.first().id)
        assertEquals(listOf("4", "3", "2", "1", "file"), pages.page(client, "/", 96, false, "modified_desc").files.map { it.id })
        assertEquals("1", pages.page(client, "/", 0, false, "modified_asc").files.first().id)
        assertEquals(3, client.calls)
    }
    @Test fun sourceOrderReadsOnlyOnePageEvenInVeryLargeDirectories() {
        val client = Client((1..20_001).reversed().map { CloudFile("$it.mp4", false, 1, "$it") })
        val page = CloudSortedPages().page(client, "/", 0, false, "source")
        assertEquals("20001.mp4", page.files.first().name)
        assertEquals(48, page.files.size)
        assertEquals(20_001, page.total)
        assertEquals(1, client.calls)
    }
    @Test fun nonMediaChildrenDoNotCreateEmptySortedPages() {
        val client = Client((1..80).map { CloudFile("$it.pdf", false, 1000, "$it") } + CloudFile("movie.mp4", false, 1, "video"))
        val page = CloudSortedPages().page(client, "/", 0, false, "size_desc")
        assertEquals(1, page.total)
        assertEquals("movie.mp4", page.files.single().name)
        assertEquals(-1, page.nextOffset)
    }
}
