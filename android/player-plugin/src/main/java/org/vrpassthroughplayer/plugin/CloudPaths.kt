package org.vrpassthroughplayer.plugin

import java.net.URI

/** A mount UUID + remote path, never an expiring download URL or a credential. */
internal object CloudPaths {
    fun uri(path: String): String {
        require(path.startsWith('/') && path.substring(1).contains('/'))
        val mount = path.substring(1).substringBefore('/')
        require(mount.matches(Regex("[a-zA-Z0-9-]+")))
        return URI("cloud", mount, path.substring(mount.length + 1), null).toASCIIString()
    }

    fun path(value: String): String {
        val uri = URI(value)
        require(uri.scheme == "cloud" && uri.rawUserInfo == null && uri.port == -1 && uri.rawQuery == null && uri.rawFragment == null)
        require(uri.host?.matches(Regex("[a-zA-Z0-9-]+")) == true)
        val path = uri.path ?: error("Missing cloud path")
        require(path.startsWith('/') && path.split('/').none { it == "." || it == ".." } && !path.contains('\u0000'))
        return "/${uri.host}$path"
    }

    fun child(parent: String, name: String): String {
        require(name.isNotEmpty() && name != "." && name != ".." && !name.contains('/') && !name.contains('\u0000'))
        return parent.trimEnd('/') + "/" + name
    }
}
