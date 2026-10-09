package org.vrpassthroughplayer.plugin

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/** The headset's own storage as folders, like a file manager: storage volumes (internal, USB) at
 * the top, then folders and media read straight from the disk. The media index (MediaStore) is
 * not used: files it has not scanned yet would be missing. Results are file:// URIs.
 * Reading needs the matching image/video permission; folders other than media ones and non-media files beside
 * the videos need "All files access", which [grantAllFiles] opens in system settings. */
internal class LocalVideoLibrary(
    private val host: () -> Activity?,
    private val emit: (Int, String) -> Unit,
) {
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "QuestLocalLibrary") }
    private val waiting = mutableListOf<Pair<Int, String>>() // main thread only
    private val permission = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_VIDEO
        else Manifest.permission.READ_EXTERNAL_STORAGE
    // Asked together with video: clone-voice M4A tracks beside the videos are MediaStore audio.
    private val permissions = if (Build.VERSION.SDK_INT >= 33) arrayOf(permission, Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_AUDIO)
        else arrayOf(permission)
    private var mediaAsked = false // A partial grant still permits browsing its available media.
    private var grantWaiting = false

    /** Main thread. path "" lists the storage volumes. Asks for the media permission once if needed. */
    fun browse(id: Int, path: String) {
        val activity = host() ?: return emit(id, state("error", "ACTIVITY_UNAVAILABLE"))
        if (grantWaiting || waiting.isNotEmpty()) { waiting.add(id to path); return }
        val readable = activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED ||
            (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED)
        if (allFiles() || permissions.all { activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED } ||
            (mediaAsked && readable)) return list(id, path)
        waiting.add(id to path)
        mediaAsked = true
        if (waiting.size == 1) {
            try { activity.requestPermissions(permissions, REQUEST) }
            catch (_: Exception) { finishBrowsePermission(false) }
        }
    }

    fun onPermissionResult(requestCode: Int, granted: Boolean) {
        if (requestCode != REQUEST && requestCode != GRANT_REQUEST) return
        val explicitGrant = grantWaiting || requestCode == GRANT_REQUEST
        grantWaiting = false
        finishBrowsePermission(granted)
        if (explicitGrant) {
            val activity = host()
            if (allFiles()) accessEvent("granted")
            else if (activity != null && !activity.shouldShowRequestPermissionRationale(permission)) openAccessSettings(activity)
            else accessEvent("denied", "Media access needed")
        }
    }

    private fun finishBrowsePermission(granted: Boolean) {
        val requests = waiting.toList(); waiting.clear()
        val readable = permissions.filter { it != Manifest.permission.READ_MEDIA_AUDIO }
            .any { host()?.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED } || granted
        for ((id, path) in requests) if (readable) list(id, path) else emit(id, state("denied", "MEDIA_PERMISSION_DENIED"))
    }

    private fun allFiles(): Boolean = LocalStoragePermissions.allFiles(Build.VERSION.SDK_INT,
        Build.VERSION.SDK_INT >= 30 && Environment.isExternalStorageManager(),
        Build.VERSION.SDK_INT < 30 && Environment.isExternalStorageLegacy(),
        host()?.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED)

    /** Main thread: explicit Grant button, with observable results even on older PICO OS. */
    fun grantAllFiles() {
        val activity = host() ?: return accessEvent("error", "Permission settings unavailable")
        if (grantWaiting) return
        if (allFiles()) return accessEvent("granted")
        if (Build.VERSION.SDK_INT < 30 && activity.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
            grantWaiting = true
            accessEvent("requested")
            // Reuse a browse-triggered prompt already in flight; do not open a second one.
            if (waiting.isNotEmpty()) return
            try { activity.requestPermissions(permissions, GRANT_REQUEST) }
            catch (_: Exception) {
                grantWaiting = false
                finishBrowsePermission(false)
                openAccessSettings(activity)
            }
        } else openAccessSettings(activity)
    }

    private fun openAccessSettings(activity: Activity) {
        val opened = LocalStoragePermissions.openSettings(Build.VERSION.SDK_INT) { action ->
            val intent = Intent(action)
            if (action != Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION) intent.data = Uri.parse("package:${activity.packageName}")
            activity.startActivity(intent)
        }
        accessEvent(if (opened) "settings_opened" else "error", if (opened) "" else "Permission settings unavailable")
    }

    private fun accessEvent(state: String, error: String = "") = emit(0,
        JSONObject().put("source", "local_access").put("state", state).put("error", error).toString())

    private fun list(id: Int, path: String) {
        val context = host()?.applicationContext ?: return emit(id, state("error", "ACTIVITY_UNAVAILABLE"))
        worker.execute {
            try {
                val entries = if (path.isEmpty()) roots(context) else folder(path)
                    ?: return@execute emit(id, JSONObject(state("denied", "ALL_FILES_ACCESS_NEEDED")).put("path", path).toString())
                emit(id, JSONObject().put("source", "local").put("state", "ready").put("path", path)
                    .put("all_files", allFiles()).put("entries", entries).toString())
            } catch (error: Throwable) {
                emit(id, state("error", error.message ?: "LOCAL_LIST_FAILED"))
            }
        }
    }

    private fun roots(context: Context): JSONArray {
        val result = JSONArray()
        val volumes = context.getSystemService(StorageManager::class.java)?.storageVolumes.orEmpty()
        for (volume in volumes) {
            val directory = (if (Build.VERSION.SDK_INT >= 30) volume.directory else null)
                ?: if (volume.isPrimary) Environment.getExternalStorageDirectory() else null
            if (directory == null || !directory.isDirectory) continue
            result.put(JSONObject().put("id", directory.absolutePath).put("title", volume.getDescription(context))
                .put("container", true).put("volume", true).put("removable", volume.isRemovable))
        }
        return result
    }

    /** Folders first, then videos, each by name; hidden entries skipped. Null when unreadable. */
    private fun folder(path: String): JSONArray? {
        val directory = File(path)
        val children = directory.listFiles() ?: return null
        val result = JSONArray()
        children.filter { !it.name.startsWith(".") && (it.isDirectory || MediaKinds.supported(it.name)) }
            .sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))
            .forEach {
                val entry = JSONObject().put("id", it.absolutePath).put("title", it.name).put("container", it.isDirectory)
                if (!it.isDirectory) entry.put("uri", Uri.fromFile(it).toString()).put("size", it.length()).put("kind", MediaKinds.kind(it.name))
                result.put(entry)
            }
        return result
    }

    private fun state(state: String, error: String) =
        JSONObject().put("source", "local").put("state", state).put("error", error).toString()

    fun close() { worker.shutdownNow() }

    companion object { const val REQUEST = 0x5661; const val GRANT_REQUEST = 0x5662 }
}
