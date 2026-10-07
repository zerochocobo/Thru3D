package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class PhotoMediaTest {
    @Test fun mixedSourcesKeepPhotoKinds() {
        for (name in listOf("photo.JPG", "portrait.jpeg", "alpha.png", "photo.webp?token=1#view")) {
            assertTrue(name, MediaKinds.supported(name))
            assertEquals("image", MediaKinds.kind(name))
        }
        assertEquals("video", MediaKinds.kind("movie.mp4?cover=a.jpg"))
        assertFalse(MediaKinds.supported("image.jpg.exe"))
        assertFalse(MediaKinds.supported("document.svg"))
    }
    @Test fun dlnaPhotosUseFullImageAndDoNotStealVideoCovers() {
        val entries = DlnaClient.didl("""<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
          <item id="1"><dc:title>Photo</dc:title><upnp:class>object.item.imageItem.photo</upnp:class>
            <res protocolInfo="http-get:*:image/jpeg:*" resolution="160x80">http://host/thumb</res>
            <res protocolInfo="http-get:*:image/jpeg:*" resolution="8192x4096">http://host/full</res></item>
          <item id="2"><dc:title>Film</dc:title><upnp:class>object.item.videoItem</upnp:class>
            <res protocolInfo="http-get:*:image/jpeg:*">http://host/cover.jpg</res>
            <res protocolInfo="http-get:*:video/mp4:*">http://host/video</res></item>
        </DIDL-Lite>""")
        assertEquals(2, entries.length())
        assertEquals("image", entries.getJSONObject(0).getString("kind"))
        assertEquals("http://host/full", entries.getJSONObject(0).getString("uri"))
        assertEquals("video", entries.getJSONObject(1).getString("kind"))
        assertEquals("http://host/video", entries.getJSONObject(1).getString("uri"))
    }
}
