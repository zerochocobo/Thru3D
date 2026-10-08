package org.vrpassthroughplayer.plugin

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS

/** Only photo transfer caches; never model programs, media originals or credentials. */
internal object PhotoCache {
    val lock = Any()
    private val names = listOf("photos", "photo-preloads")

    fun usage(cache: File): Pair<Long, Long> = synchronized(lock) {
        var count = 0L
        var bytes = 0L
        for (name in names) {
            val root = File(cache, name).toPath()
            if (!Files.isDirectory(root, NOFOLLOW_LINKS)) continue
            Files.walk(root).use { paths -> paths.forEach { path ->
                if (Files.isRegularFile(path, NOFOLLOW_LINKS)) {
                    // A photo may be released while settings is counting its files.
                    runCatching { Files.size(path) }.getOrNull()?.let { size -> count++; bytes += size }
                }
            } }
        }
        count to bytes
    }

    fun clear(cache: File, protected: Set<File>) = synchronized(lock) {
        val active = protected.map { it.absoluteFile.toPath().normalize() }.toSet()
        for (name in names) {
            val root = File(cache, name).absoluteFile.toPath().normalize()
            if (!Files.isDirectory(root, NOFOLLOW_LINKS)) continue
            Files.list(root).use { entries -> entries.forEach { entry ->
                if (entry !in active) {
                    // walk does not follow links, including links to another cache or original.
                    Files.walk(entry).use { paths ->
                        paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
                    }
                }
            } }
        }
    }
}
