package org.vrpassthroughplayer.plugin

/** Text subtitles beside an SMB video. Keep discovery separate from media filtering:
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

}
