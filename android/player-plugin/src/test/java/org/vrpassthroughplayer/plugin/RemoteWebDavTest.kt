package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class RemoteWebDavTest {
    @Test fun addressPreservesRemotePrefixAndRejectsEmbeddedCredentialsAndNonNetworkUrls() {
        assertEquals("http://nas.example:19798/dav", RemoteWebDav.address("  http://nas.example:19798/dav/  "))
        assertEquals("https://nas.example/中文", java.net.URI(RemoteWebDav.address("https://nas.example/中文")).toString().let { java.net.URI(it).toString() }.let { java.net.URLDecoder.decode(it, "UTF-8") })
        for (bad in listOf("file:///tmp", "http://user:secret@nas/dav", "http://nas/dav?password=secret",
            "http://nas/dav#fragment", "http://nas:0/dav", "http://nas/a/../dav", "http://nas/a/%2e%2e/dav")) {
            assertThrows(MediaServerFailure::class.java) { RemoteWebDav.address(bad) }
        }
    }
    @Test fun webDavConfigurationKeepsSecretsOutOfMetadataAndRetainsOnlyTheSameLogin() {
        val previous = RemoteWebDav.connection("https://nas/dav", "fixture", "private-secret")
        val same = RemoteWebDav.connection("https://nas/dav/", "fixture", "", previous)
        assertEquals("private-secret", same.addition().getString("password"))
        assertTrue(same.metadata().getBoolean("has_password"))
        assertFalse(same.metadata().toString().contains("private-secret"))
        assertFalse(same.toString().contains("private-secret"))
        assertTrue(RemoteWebDav.retainsSavedLogin(same.metadata(), "https://nas/dav/", "fixture"))
        assertFalse(RemoteWebDav.retainsSavedLogin(same.metadata(), "https://other/dav", "fixture"))
        assertFalse(RemoteWebDav.retainsSavedLogin(same.metadata(), "https://nas/dav", "another"))
        assertFalse(RemoteWebDav.retainsSavedLogin(same.metadata(), "http://", "fixture"))
        assertEquals("new-secret", RemoteWebDav.connection("https://nas/dav", "fixture", "new-secret", previous).addition().getString("password"))
        assertEquals("", RemoteWebDav.connection("https://other/dav", "fixture", "", previous).addition().getString("password"))
        assertEquals("", RemoteWebDav.connection("https://nas/other", "fixture", "", previous).addition().getString("password"))
        assertEquals("", RemoteWebDav.connection("https://nas/dav", "another", "", previous).addition().getString("password"))
        val fields = same.addition()
        assertEquals("/", fields.getString("root_folder_path"))
        assertEquals("other", fields.getString("vendor"))
        assertFalse(fields.getBoolean("tls_insecure_skip_verify"))
        assertEquals(fields.toString(), RemoteWebDav.fromAddition(fields).addition().toString())
    }
    @Test fun webDavIsACloudMountWithoutOAuthOrRemoteDeletion() {
        assertEquals("WebDAV", CloudDrive.PROVIDERS[CloudDrive.WEBDAV])
        assertTrue(OpenListBackend.supported(CloudDrive.WEBDAV))
        assertFalse(OpenListAuth.supported(CloudDrive.WEBDAV))
        val account = JSONObject().put("provider", CloudDrive.WEBDAV).put("core_id", 1)
            .put("mount", "/00000000-0000-0000-0000-000000000001")
        assertFalse(OpenListBackend.client(account).canDelete)
        assertThrows(CloudFailure::class.java) { OpenListBackend.client(JSONObject().put("provider", CloudDrive.WEBDAV)) }
    }
}
