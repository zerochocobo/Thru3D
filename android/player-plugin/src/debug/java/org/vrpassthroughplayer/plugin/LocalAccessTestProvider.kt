package org.vrpassthroughplayer.plugin

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.CancellationSignal
import android.os.OperationCanceledException
import android.os.ParcelFileDescriptor
import android.os.Looper
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Private Debug fixture for actual ContentResolver/cancellation plumbing. */
class LocalAccessTestProvider : ContentProvider() {
    override fun onCreate() = true
    override fun getType(uri: Uri) = "video/mp4"
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? =
        query(uri, projection, selection, selectionArgs, sortOrder, null)
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?, signal: CancellationSignal?): Cursor? {
        check(Looper.myLooper() != Looper.getMainLooper()) { "Provider metadata queried on application main thread" }
        when (uri.lastPathSegment) {
            "name_slow" -> {
                val wake = CountDownLatch(1)
                signal?.setOnCancelListener { wake.countDown() }
                try { wake.await(15, TimeUnit.SECONDS) }
                catch (_: InterruptedException) { throw OperationCanceledException() }
                finally { signal?.setOnCancelListener(null) }
                signal?.throwIfCanceled()
            }
            "name_late" -> Thread.sleep(1200) // Deliberately ignores cancellation until it returns.
            "name_denied" -> throw SecurityException("Optional metadata denied")
        }
        if (uri.lastPathSegment == "name_no_column") return MatrixCursor(arrayOf("other")).apply { addRow(arrayOf("unused")) }
        val title = when (uri.lastPathSegment) {
            "name_unicode" -> "中文字幕 😀\nA\tB\rC"
            "name_long" -> "界".repeat(255) + "😀\n tail"
            "name_blank" -> " \n\t"
            else -> "Local video"
        }
        return MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME)).apply { addRow(arrayOf(title)) }
    }
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor = openFile(uri, mode, null)
    override fun openFile(uri: Uri, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        require(mode == "r")
        when (uri.lastPathSegment) {
            "missing" -> throw FileNotFoundException("Debug missing file")
            "denied" -> throw SecurityException("Debug denied file")
            "slow" -> {
                val wake = CountDownLatch(1)
                signal?.setOnCancelListener { wake.countDown() }
                try { wake.await(15, TimeUnit.SECONDS) }
                catch (_: InterruptedException) { throw OperationCanceledException() }
                finally { signal?.setOnCancelListener(null) }
                signal?.throwIfCanceled()
            }
            "present", "name_slow", "name_late", "name_unicode", "name_long", "name_blank", "name_no_column", "name_denied" -> Unit
            else -> throw FileNotFoundException()
        }
        val fixture = File(context!!.cacheDir, "local-access-fixture.bin")
        if (!fixture.exists()) fixture.writeBytes(byteArrayOf(0, 1, 2, 3))
        return ParcelFileDescriptor.open(fixture, ParcelFileDescriptor.MODE_READ_ONLY)
    }
}
