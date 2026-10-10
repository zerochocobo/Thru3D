package org.vrpassthroughplayer.plugin

import java.net.HttpURLConnection
import java.net.URI

/** Text subtitles beside a network video. Keep discovery separate from media filtering:
 * SRT/ASS files should become CC tracks, not playable library entries. */
internal object SidecarSubtitles {
    data class Track(val location: String, val title: String)
    // .sub is ambiguous: MPV's detected codec decides whether it is text or bitmap.
    private val extensions = setOf("srt", "ass", "ssa", "vtt", "smi", "sami", "sub")

    fun select(video: String, names: Collection<String>): List<String> {
        val stem = video.substringBeforeLast('.')
        if (stem.isEmpty()) return emptyList()
        return names.filter {
            '/' !in it && '\\' !in it && it.startsWith("$stem.", ignoreCase = true) &&
                it.substringAfterLast('.', "").lowercase() in extensions
        }.sortedWith(compareBy({ !it.substringBeforeLast('.').equals(stem, ignoreCase = true) },
            { it.lowercase() })).take(8)
    }

    fun forCloud(path: String, client: CloudClient, publish: (CloudFile) -> String): List<Track> {
        // Library pages hide subtitle files. Read the unfiltered directory, including later pages.
        val files = client.list(path.substringBeforeLast('/').ifEmpty { "/" })
            .filter { !it.folder && it.size > 0 }.associateBy { it.name }
        return select(path.substringAfterLast('/'), files.keys).mapNotNull { name ->
            // One inaccessible subtitle must not hide other tracks or fail video playback.
            runCatching { Track(publish(files.getValue(name)), name) }.getOrNull()
        }
    }

    fun forServer(http: MediaServerHttp, captions: List<MediaSubtitleLink>,
        publish: (StreamSource, String) -> String): List<Track> = captions.take(8).mapIndexedNotNull { index, caption ->
        runCatching {
            require(caption.extension in extensions)
            val bytes = http.bytes(caption.url, 4 * 1024 * 1024, textSubtitle = true)
            require(bytes.isNotEmpty())
            validate(bytes)
            val source = Bytes(bytes)
            try { Track(publish(source, "subtitle-$index.${caption.extension}"), caption.title) }
            catch (error: Exception) { source.close(); throw error }
        }.getOrNull()
    }

    fun forDlna(captions: List<MediaSubtitleLink>, publish: (StreamSource, String) -> String): List<Track> =
        captions.take(8).mapIndexedNotNull { index, caption ->
            runCatching {
                require(caption.extension in extensions)
                val bytes = download(caption.url)
                validate(bytes)
                val source = Bytes(bytes)
                try { Track(publish(source, "subtitle-$index.${caption.extension}"), caption.title) }
                catch (error: Exception) { source.close(); throw error }
            }.getOrNull()
        }

    private fun validate(bytes: ByteArray) {
        require(bytes.isNotEmpty())
        val prefix = bytes.copyOf(minOf(256, bytes.size)).toString(Charsets.UTF_8).trimStart('\uFEFF', ' ', '\r', '\n', '\t').lowercase()
        require(!prefix.startsWith("<html") && !prefix.startsWith("<!doctype html") && !prefix.startsWith("{") && !prefix.startsWith("[{"))
    }

    private fun download(url: URI): ByteArray {
        var current = url
        repeat(4) {
            val connection = current.toURL().openConnection() as HttpURLConnection
            connection.connectTimeout = 3000; connection.readTimeout = 5000
            connection.instanceFollowRedirects = false
            try {
                val status = connection.responseCode
                if (status in listOf(301, 302, 303, 307, 308)) {
                    current = DlnaClient.httpUri(connection.getHeaderField("Location").orEmpty(), current.toString()) ?: error("Invalid subtitle redirect")
                } else {
                    require(status == 200 && connection.contentLengthLong <= 4 * 1024 * 1024)
                    return connection.inputStream.use { input ->
                        val output = java.io.ByteArrayOutputStream()
                        val buffer = ByteArray(8192)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            require(output.size() + count <= 4 * 1024 * 1024)
                            output.write(buffer, 0, count)
                        }
                        output.toByteArray()
                    }
                }
            } finally { connection.disconnect() }
        }
        error("Too many subtitle redirects")
    }

    private class Bytes(data: ByteArray) : StreamSource {
        override val size = data.size.toLong()
        @Volatile private var bytes: ByteArray? = data
        override fun close() { bytes = null }
        override fun open(): StreamSource.Reader {
            check(bytes != null)
            return object : StreamSource.Reader {
                private var closed = false
                override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                    check(!closed)
                    val data = bytes ?: error("Subtitle stream closed")
                    require(offset >= 0 && length in 1..buffer.size)
                    if (offset >= data.size) return -1
                    val count = minOf(length, data.size - offset.toInt())
                    data.copyInto(buffer, 0, offset.toInt(), offset.toInt() + count)
                    return count
                }
                override fun close() { closed = true }
            }
        }
    }
}