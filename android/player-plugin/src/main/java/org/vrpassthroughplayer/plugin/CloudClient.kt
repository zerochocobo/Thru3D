package org.vrpassthroughplayer.plugin

internal interface CloudClient {
    fun page(path: String, offset: Int = 0, refresh: Boolean = false): CloudPage
    fun list(path: String): List<CloudFile>
    fun find(path: String): CloudFile
    fun resolve(file: CloudFile): CloudLink
    val canDelete: Boolean get() = false
    fun remove(path: String, file: CloudFile) { throw IllegalStateException("File deletion unavailable for this source") }
}
