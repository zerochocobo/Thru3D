package org.vrpassthroughplayer.plugin

import android.content.Context
import android.content.Intent
import android.net.Uri

/** Same grant policy for the real picker and actual cross-UID diagnostics. */
internal object LocalDocumentGrant {
    fun take(context: Context, uri: Uri, flags: Int): Boolean {
        if (uri.scheme != "content" || flags and Intent.FLAG_GRANT_READ_URI_PERMISSION == 0 ||
            flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION == 0) return false
        return try {
            context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            context.contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }
        } catch (_: SecurityException) { false }
    }
}
