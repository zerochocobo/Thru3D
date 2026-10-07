package org.vrpassthroughplayer.plugin

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import java.io.File

/** Extra audio tracks stored next to a video: "<video stem>.*m4a". The prepared clone-voice mix
 * of PTMediaServer / VR Video Toolbox ("<stem>.si.mix.m4a": dubbed voice over the ducked original)
 * comes first and is titled [CLONE_TITLE]; MPV adds each as a selectable, unselected track.
 * Only M4A is looked for. Calls block (MediaStore query, SMB listing): worker threads only. */
internal object SidecarAudio {
    const val CLONE_TITLE = "Clone voice"
    private const val CLONE_SUFFIX = ".si.mix.m4a"
    private const val LIMIT = 4

    /** An MPV location for one track; [descriptor] stays open until the source closes. */
    data class Track(val location: String, val title: String, val descriptor: ParcelFileDescriptor? = null)

    /** Sibling names for [video] among [names], clone voice first, then by name. */
    fun select(video: String, names: Collection<String>): List<String> {
        val stem = video.substringBeforeLast('.')
        if (stem.isEmpty()) return emptyList()
        // "<stem>.": part1.mp4 must not take part10.si.mix.m4a.
        return names.filter { it.startsWith("$stem.", ignoreCase = true) && it.endsWith(".m4a", ignoreCase = true) }
            .sortedWith(compareBy({ !it.endsWith(CLONE_SUFFIX, ignoreCase = true) }, { it.lowercase() }))
            .take(LIMIT)
    }

    /** "Clone voice" for the prepared mix; otherwise what the name adds to the video stem. */
    fun title(video: String, name: String): String {
        if (name.endsWith(CLONE_SUFFIX, ignoreCase = true)) return CLONE_TITLE
        val extra = name.substring(video.substringBeforeLast('.').length).removeSuffix(".m4a").removeSuffix(".M4A")
            .trim('.', ' ', '_', '-')
        return extra.ifEmpty { "M4A" }
    }

    fun forFile(path: String): List<Track> {
        val video = File(path)
        val names = video.parentFile?.list()?.toList() ?: return emptyList()
        return select(video.name, names).map { Track(File(video.parentFile, it).absolutePath, title(video.name, it)) }
    }

    /** MediaStore videos (the in-headset library): audio of the same folder, read via MediaStore.Audio. */
    fun forMediaStore(context: Context, uri: Uri): List<Track> {
        if (uri.authority != MediaStore.AUTHORITY || Build.VERSION.SDK_INT < 29) return emptyList()
        val permission = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_AUDIO
            else Manifest.permission.READ_EXTERNAL_STORAGE
        if (context.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) return emptyList()
        val resolver = context.contentResolver
        val (name, folder) = resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.RELATIVE_PATH),
            null, null, null)?.use { if (it.moveToFirst()) (it.getString(0) ?: "") to (it.getString(1) ?: "") else null }
            ?: return emptyList()
        if (name.isEmpty()) return emptyList()
        val audio = MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val found = LinkedHashMap<String, Long>()
        resolver.query(audio, arrayOf(MediaStore.Audio.Media._ID, MediaStore.Audio.Media.DISPLAY_NAME),
            "${MediaStore.Audio.Media.RELATIVE_PATH}=? AND ${MediaStore.Audio.Media.DISPLAY_NAME} LIKE ? ESCAPE '\\'",
            arrayOf(folder, name.substringBeforeLast('.').replace("%", "\\%").replace("_", "\\_") + "%"), null)?.use {
            while (it.moveToNext()) found[it.getString(1) ?: continue] = it.getLong(0)
        }
        return select(name, found.keys).mapNotNull { sibling ->
            val descriptor = runCatching {
                resolver.openFileDescriptor(Uri.withAppendedPath(audio, found.getValue(sibling).toString()), "r")
            }.getOrNull() ?: return@mapNotNull null
            Track("fd://${descriptor.fd}", title(name, sibling), descriptor)
        }
    }
}
