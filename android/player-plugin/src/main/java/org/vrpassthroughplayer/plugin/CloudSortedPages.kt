package org.vrpassthroughplayer.plugin

/** Sort the entire directory metadata before slicing. Never label a sorted single page a directory sort.
 * Bounded snapshots contain no stream URLs or credentials, expire after two minutes, and are account-local. */
internal class CloudSortedPages(private val now: () -> Long = { System.nanoTime() / 1_000_000 }) {
    private data class Snapshot(val files: List<CloudFile>, val expires: Long)
    private val snapshots = LinkedHashMap<String, Snapshot>(4, .75f, true)

    @Synchronized fun page(client: CloudClient, path: String, offset: Int, refresh: Boolean, order: String): CloudPage {
        require((order in ORDERS || order == "source") && offset >= 0)
        if (order == "source") return client.page(path, offset, refresh)
        require(offset % CloudDrive.PAGE_SIZE == 0)
        if (refresh) snapshots.remove(path)
        var snapshot = snapshots[path]?.takeIf { it.expires > now() }
        if (snapshot == null) {
            val files = ArrayList<CloudFile>()
            val seen = HashSet<String>()
            var cursor = 0
            while (true) {
                if (Thread.currentThread().isInterrupted) throw CloudFailure()
                val page = client.page(path, cursor, refresh && cursor == 0)
                if (page.total > MAX_FILES || files.size + page.files.size > MAX_FILES) throw CloudFailure("Folder too large to sort; use source order")
                page.files.forEach { if (!seen.add((if (it.folder) "d" else "f") + it.id)) throw CloudFailure() }
                files.addAll(page.files)
                if (page.nextOffset < 0) break
                if (page.nextOffset <= cursor) throw CloudFailure()
                cursor = page.nextOffset
            }
            snapshot = Snapshot(files.filter { it.folder || MediaKinds.supported(it.name) }, now() + 120_000)
            snapshots[path] = snapshot
            while (snapshots.size > 4 || snapshots.values.sumOf { it.files.size } > MAX_FILES * 2) snapshots.remove(snapshots.keys.first())
        }
        val sorted = snapshot.files.sortedWith(comparator(order))
        if (offset > sorted.size) throw CloudFailure()
        val end = minOf(offset + CloudDrive.PAGE_SIZE, sorted.size)
        return CloudPage(sorted.subList(offset, end), if (end < sorted.size) end else -1, sorted.size)
    }

    companion object {
        const val MAX_FILES = 20_000
        val ORDERS = setOf("name_asc", "name_desc", "modified_desc", "modified_asc", "size_desc", "size_asc")
        fun comparator(order: String): Comparator<CloudFile> = Comparator { a, b ->
            if (a.folder != b.folder) return@Comparator if (a.folder) -1 else 1
            val field = order.substringBefore('_')
            if (field == "modified" || (field == "size" && !a.folder)) {
                val av = if (field == "size") a.size else a.modified
                val bv = if (field == "size") b.size else b.modified
                if ((av < 0) != (bv < 0)) return@Comparator if (av < 0) 1 else -1
                if (av != bv) return@Comparator av.compareTo(bv) * if (order.endsWith("desc")) -1 else 1
            }
            val name = natural(a.name, b.name)
            if (name != 0) name * if (field == "name" && order.endsWith("desc")) -1 else 1 else a.id.compareTo(b.id)
        }
        internal fun natural(a: String, b: String): Int {
            val left = a.lowercase(java.util.Locale.ROOT)
            val right = b.lowercase(java.util.Locale.ROOT)
            var i = 0; var j = 0
            while (i < left.length && j < right.length) {
                if (left[i] in '0'..'9' && right[j] in '0'..'9') {
                    val si = i; val sj = j
                    while (i < left.length && left[i] in '0'..'9') i++
                    while (j < right.length && right[j] in '0'..'9') j++
                    val ln = left.substring(si, i).trimStart('0').ifEmpty { "0" }
                    val rn = right.substring(sj, j).trimStart('0').ifEmpty { "0" }
                    val cmp = if (ln.length != rn.length) ln.length.compareTo(rn.length) else ln.compareTo(rn)
                    if (cmp != 0) return cmp
                } else {
                    if (left[i] != right[j]) return left[i].compareTo(right[j])
                    i++; j++
                }
            }
            return (left.length - i).compareTo(right.length - j)
        }
    }
}
