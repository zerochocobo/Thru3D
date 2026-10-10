package org.vrpassthroughplayer.plugin

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.os.storage.StorageVolume
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
    @Volatile private var fileManagementEnabled = false
    fun setFileManagement(enabled: Boolean) {
        if (fileManagementEnabled != enabled) mediaAsked = false
        fileManagementEnabled = enabled
    }
    private val permissions get() = if (Build.VERSION.SDK_INT >= 33) arrayOf(permission, Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_AUDIO)
        else if (Build.VERSION.SDK_INT < 30 && fileManagementEnabled) arrayOf(permission, Manifest.permission.WRITE_EXTERNAL_STORAGE) else arrayOf(permission)
    @Volatile private var mediaAsked = false // A partial grant still permits browsing its available media.
    private var grantWaiting = false
    @Volatile private var closed = false
    private var observerContext: Context? = null
    private var observerRegistered = false
    private var volumeObservation: AutoCloseable? = null
    private val observer = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) { refreshStorage(intent.action ?: "") }
    }

    private fun watchStorage(context: Context) {
        if (observerContext != null || closed) return
        val filter = IntentFilter().apply {
            for (action in listOf(Intent.ACTION_MEDIA_MOUNTED, Intent.ACTION_MEDIA_UNMOUNTED,
                Intent.ACTION_MEDIA_REMOVED, Intent.ACTION_MEDIA_BAD_REMOVAL, Intent.ACTION_MEDIA_EJECT)) addAction(action)
            addDataScheme("file")
        }
        observerContext = context
        observerRegistered = runCatching {
            if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(observer,filter,Context.RECEIVER_NOT_EXPORTED)
            else context.registerReceiver(observer,filter)
            true
        }.getOrDefault(false)
        if (Build.VERSION.SDK_INT >= 30) volumeObservation = runCatching {
            VolumeObservation.watch(context) { refreshStorage("volume_state") }
        }.getOrNull()
    }

    /** No filesystem-change observation is required for normal browsing; this is mount lifecycle. */
    fun refreshStorage(action: String = "") {
        if (closed) return
        val context = observerContext ?: host()?.applicationContext ?: return
        watchStorage(context)
        worker.execute {
            if (closed) return@execute
            val event = JSONObject().put("source","local_storage").put("action",action)
            try { event.put("state","changed").put("volumes",LocalStorageVolumes.roots(context)) }
            catch (_: Exception) { event.put("state","error") }
            if (!closed) emit(0,event.toString())
        }
    }

    fun openEjectSettings(id: Int, path: String) {
        val activity = host() ?: return emit(id,ejectState("error",path,"Storage settings unavailable"))
        val roots = runCatching { LocalStorageVolumes.roots(activity) }.getOrNull()
            ?: return emit(id,ejectState("error",path,"Storage device unavailable"))
        val removable = (0 until roots.length()).any { index ->
            val volume = roots.getJSONObject(index)
            volume.optString("id") == path && volume.optBoolean("removable")
        }
        if (!removable) return emit(id,ejectState("error",path,"Storage device unavailable"))
        val opened = LocalStorageVolumePolicy.openEjectSettings { activity.startActivity(Intent(it)) }
        emit(id,ejectState(if (opened) "settings_opened" else "error",path,
            if (opened) "" else "Storage settings unavailable"))
    }

    private fun ejectState(state: String, path: String, error: String) = JSONObject().put("source","local_eject")
        .put("state",state).put("volume_id",path).put("error",error).put("unmounted",false).toString()

    /** Main thread. path "" lists the storage volumes. Asks for the media permission once if needed. */
    fun browse(id: Int, path: String) {
        val activity = host() ?: return emit(id, state("error", "ACTIVITY_UNAVAILABLE"))
        watchStorage(activity.applicationContext)
        if (grantWaiting || waiting.isNotEmpty()) { waiting.add(id to path); return }
        val readable = activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED ||
            (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED)
        if ((allFiles() && (Build.VERSION.SDK_INT >= 30 || !fileManagementEnabled || writable())) || permissions.all { activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED } ||
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
        val readable = permissions.filter { it != Manifest.permission.READ_MEDIA_AUDIO && it != Manifest.permission.WRITE_EXTERNAL_STORAGE }
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
                val volumes = LocalStorageVolumes.roots(context)
                val entries = if (path.isEmpty()) volumes else folder(path)
                    ?: return@execute emit(id, JSONObject(state("denied", "ALL_FILES_ACCESS_NEEDED")).put("path", path).toString())
                emit(id, JSONObject().put("source", "local").put("state", "ready").put("path", path)
                    .put("all_files", allFiles()).put("entries", entries).put("volumes",volumes).toString())
            } catch (error: Throwable) {
                emit(id, state("error", error.message ?: "LOCAL_LIST_FAILED"))
            }
        }
    }

    /** Folders first, then videos, each by name; hidden entries skipped. Null when unreadable. */
    private fun writable(): Boolean = fileManagementEnabled && if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
        else Environment.isExternalStorageLegacy() && host()?.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    fun renameFile(request: JSONObject, prepare: Boolean): JSONObject {
        val activity = host() ?: error("Storage device unavailable")
        val uri = Uri.parse(request.getString("uri"))
        require(uri.scheme == "file" && uri.authority.isNullOrEmpty())
        val roots = LocalStorageVolumes.roots(activity)
        val file = MediaDeletePolicy.local(File(uri.path ?: ""), (0 until roots.length()).map { File(roots.getJSONObject(it).getString("id")) })
        check(writable() && MediaDeletePolicy.regular(file) && file.parentFile?.canWrite() == true) { "File deletion permission denied" }
        MediaDeletePolicy.unchanged(file.length(), file.lastModified(), request.getLong("size"), request.getLong("modified"))
        val parent = file.parentFile!!
        val bundle = RenameBundle(file.name, request.getString("new_name"), parent.list()?.toList() ?: error("File deletion permission denied"))
        val expected = HashMap<String, Pair<Long, Long>>()
        val fingerprint = bundle.fingerprint { name ->
            val child = parent.resolve(name)
            check(MediaDeletePolicy.regular(child) && child.canonicalPath == child.absolutePath) { "Folder contains unsupported links" }
            (child.length() to child.lastModified()).also { expected[name] = it }
        }
        if (prepare) return JSONObject().put("preview", true).put("plan", fingerprint).put("moves", bundle.preview())
        check(fingerprint == request.optString("plan")) { "Folder changed; check its contents again" }
        return bundle.execute(inspect = { move ->
            fun matches(name: String): Boolean {
                val child = parent.resolve(name)
                return MediaDeletePolicy.regular(child) && (child.length() to child.lastModified()) == expected.getValue(move.from)
            }
            val old = matches(move.from); val new = matches(move.to)
            if (old && !parent.resolve(move.to).exists()) 0 else if (new && !parent.resolve(move.from).exists()) 1 else -1
        }) { from, to ->
            val error = NativeMediaDelete.renameAt(parent.absolutePath.toByteArray(Charsets.UTF_8), from.toByteArray(Charsets.UTF_8), to.toByteArray(Charsets.UTF_8))
            check(error == 0)
        }.put("new_uri", Uri.fromFile(parent.resolve(bundle.moves[0].to)).toString()).put("new_title", bundle.moves[0].to)
    }

    fun deleteFile(request: JSONObject, inspect: Boolean, prepare: Boolean = false): JSONObject {
        val activity = host() ?: error("Storage device unavailable")
        val uri = Uri.parse(request.getString("uri"))
        require(uri.scheme == "file" && uri.authority.isNullOrEmpty())
        val roots = LocalStorageVolumes.roots(activity)
        val folder = request.optBoolean("folder")
        val file = MediaDeletePolicy.local(File(uri.path ?: ""), (0 until roots.length()).map { File(roots.getJSONObject(it).getString("id")) }, folder)
        if (inspect) {
            val exists = try {
                java.nio.file.Files.readAttributes(file.toPath(), java.nio.file.attribute.BasicFileAttributes::class.java, java.nio.file.LinkOption.NOFOLLOW_LINKS)
                true
            } catch (_: java.nio.file.NoSuchFileException) { false }
            return JSONObject().put("exists", exists)
        }
        check(writable() && file.parentFile?.canWrite() == true) { "File deletion permission denied" }
        if (folder) {
            check(file.isDirectory) { "Folder changed; check its contents again" }
            val plan = DeleteTree.local(file)
            if (prepare) return plan.summary()
            plan.verify(request)
            var removed = 0
            for (entry in plan.entries.sortedByDescending { it.path.count { c -> c == '/' } * 2 + if (it.path.isEmpty()) -1 else 0 }) {
                val error = NativeMediaDelete.removeAt(file.absolutePath.toByteArray(Charsets.UTF_8), entry.path.toByteArray(Charsets.UTF_8), entry.folder)
                if (error != 0) return JSONObject().put("partial", removed > 0).put("state", "uncertain")
                    .put("error", if (removed > 0) "Some contents were deleted; check the folder" else "Delete result needs checking")
                removed++
            }
            return JSONObject().put("deleted", true)
        }
        check(MediaDeletePolicy.regular(file)) { "File changed; refresh the folder" }
        MediaDeletePolicy.unchanged(file.length(), file.lastModified(), request.getLong("size"), request.getLong("modified"))
        // unlink refuses directories atomically, even when an external writer replaces the path.
        val errno = NativeMediaDelete.unlink(file.absolutePath.toByteArray(Charsets.UTF_8))
        check(errno == 0) { "File deletion permission denied" }
        check(!file.exists()) { "Delete result needs checking" }
        return JSONObject().put("deleted", true)
    }

    private fun folder(path: String): JSONArray? {
        val directory = File(path)
        val children = directory.listFiles() ?: return null
        val result = JSONArray()
        children.filter { !it.name.startsWith(".") && (it.isDirectory || MediaKinds.supported(it.name)) }
            .sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))
            .forEach {
                val entry = JSONObject().put("id", it.absolutePath).put("title", it.name).put("container", it.isDirectory)
                    .put("modified", it.lastModified().takeIf { time -> time > 0 } ?: -1)
                    .put("delete_uri", Uri.fromFile(it).toString()).put("can_delete", writable() && directory.canWrite() && it.canonicalPath == it.absolutePath)
                    .put("delete_reason", "File deletion permission denied")
                if (!it.isDirectory) entry.put("uri", Uri.fromFile(it).toString()).put("size", it.length()).put("kind", MediaKinds.kind(it.name))
                    .put("can_delete", writable() && directory.canWrite() && MediaDeletePolicy.regular(it) && it.canonicalPath == it.absolutePath)
                    .put("delete_reason", "File deletion permission denied")
                result.put(entry)
            }
        return result
    }

    private fun state(state: String, error: String) =
        JSONObject().put("source", "local").put("state", state).put("error", error).toString()

    fun close() {
        closed = true
        volumeObservation?.let { runCatching { it.close() } }; volumeObservation = null
        if (observerRegistered) observerContext?.let { runCatching { it.unregisterReceiver(observer) } }
        observerContext = null; observerRegistered = false
        worker.shutdownNow()
    }

    // Android 10 never loads the API 30 callback class.
    private object VolumeObservation {
        fun watch(context: Context, changed: () -> Unit): AutoCloseable? {
            val manager = context.getSystemService(StorageManager::class.java) ?: return null
            val callback = object : StorageManager.StorageVolumeCallback() {
                override fun onStateChanged(volume: StorageVolume) { changed() }
            }
            manager.registerStorageVolumeCallback(context.mainExecutor, callback)
            return AutoCloseable { manager.unregisterStorageVolumeCallback(callback) }
        }
    }

    companion object { const val REQUEST = 0x5661; const val GRANT_REQUEST = 0x5662 }
}
