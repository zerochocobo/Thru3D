package org.vrpassthroughplayer.plugin

/** File type is independent from projection and stereo packing. */
internal object MediaKinds {
    val images = setOf("jpg", "jpeg", "png", "webp")
    fun image(name: String) = name.substringBefore('?').substringBefore('#').substringAfterLast('.', "").lowercase() in images
    fun supported(name: String) = image(name) || DlnaClient.isVideoName(name)
    fun kind(name: String) = if (image(name)) "image" else "video"
}
