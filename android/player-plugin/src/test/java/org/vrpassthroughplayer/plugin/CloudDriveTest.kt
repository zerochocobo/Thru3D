package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import java.net.URLDecoder
import java.util.Base64

class CloudDriveTest {
    private fun query(url: String) = URI(url).rawQuery.split('&').associate {
        URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('='), "UTF-8")
    }
    @Test fun paginated115ListingUsesOnlyMetadataAndPreservesLargeIds() {
        var requests = 0
        val drive = CloudDrive(CloudDrive.P115, "UID=test; CID=test; SEID=test", CloudTransport { url, _, form ->
            assertNull(form)
            val args = query(url)
            assertEquals("/files", URI(url).path)
            assertEquals("0", args["cid"])
            val response = if (requests++ == 0) {
                assertEquals("0", args["offset"])
                """{"state":true,"count":3,"data":[{"cid":"2","n":"电影 & 音乐"},{"fid":"9007199254740993","n":"a #?%.mp4","s":"4294967297","pc":"pick"}]}"""
            } else {
                assertEquals("2", args["offset"])
                """{"state":true,"count":3,"data":[{"fid":"4","n":"readme.txt","s":"5","pc":"text"}]}"""
            }
            CloudResponse(JSONObject(response))
        })
        val files = drive.list("/")
        assertEquals(2, requests); assertEquals(3, files.size)
        assertTrue(files[0].folder)
        assertEquals("9007199254740993", files[1].id)
        assertEquals(4294967297L, files[1].size)
        assertEquals("a #?%.mp4", files[1].name)
    }
    @Test fun nested115PathUsesDirectoryLookup() {
        var request = 0
        val drive = CloudDrive(CloudDrive.P115, "UID=x", CloudTransport { url, _, _ ->
            val args = query(url)
            if (request++ == 0) {
                assertEquals("/files/getid", URI(url).path); assertEquals("/中文 #?%", args["path"])
                CloudResponse(JSONObject("""{"state":true,"id":42}"""))
            } else {
                assertEquals("42", args["cid"])
                CloudResponse(JSONObject("""{"state":true,"count":0,"data":[]}"""))
            }
        })
        assertTrue(drive.list("/中文 #?%").isEmpty())
    }
    @Test fun rejectedSessionsAndRedirectDestinationsDoNotExposeUpstreamText() {
        val drive = CloudDrive(CloudDrive.P115, "UID=x", CloudTransport { _, _, _ ->
            CloudResponse(JSONObject("""{"state":false,"errno":99,"errmsg":"secret cookie"}"""))
        })
        try { drive.list("/"); fail() } catch (error: CloudFailure) {
            assertEquals("cloud_login_required", error.reason)
            assertFalse(error.message!!.contains("secret"))
        }
        for (url in listOf("https://115.com.evil.test/file", "https://u:p@115.com/file", "file:///secret", "https://115.com:8080/file")) {
            try { CloudDrive.secureMediaUrl(url, CloudDrive.P115); fail(url) } catch (_: CloudFailure) {}
        }
        assertFalse(CloudHttp.validCookie("UID=a\r\nInjected: true"))
    }
    @Test fun cryptoMatchesIndependentMitReference() {
        assertEquals("DWYhXqHtXhKTpBUrv8Mx+OFq6yzU/vryewZ06yORLcnXUh4ObODn2pDCDaqhQs/XYdk/p/zzvk8f6LHQZlx3Enc47niW2tkmSOi+xBc3UCxZ5iD1jNxK5N8lAZAuhWxK6pNtALwSsFswSRb2H9WpZ8WiSHeW6elSp1RcKrNdX6M=",
            Cloud115Cipher.encrypt("""{"pickcode":"fixture-pickcode"}"""))
        assertEquals("hSP1CNRNVuoww1gwiSJF1W4bXE+PEHyx3OB6o+h6DwpiAFSObfJ4r6bahiCsqiNsg8fT7P2euSjxRjDmeBovPWlhIkolk6fy2jixhPOx/BaQvuNgOrBprqhHKFZxMRjxqIHeqR98DyQ/R74EzULz2oudHRVOCeGiosErPPGFZ2aF7BP5aeZaCJEaFySKykkfVY3qH28Zo7vRxLxRdq6Y/poh78VsvbEJN64tA0+iJeHueEUCR6OGxwHJpcVTkOMgL39MOv0GgCnWRngpxcniVsTukb8WFVXqLtXoW+PBYK2kQYvsdIA2YiitdYQqDRZQD/v5lSBgoF+hQZ5pkz1yWQ==",
            Cloud115Cipher.encrypt("a".repeat(200)))
        for (value in listOf("", "AAAA", Base64.getEncoder().encodeToString(ByteArray(128)))) {
            try { Cloud115Cipher.decrypt(value); fail() } catch (_: IllegalArgumentException) {} catch (_: IllegalStateException) {}
        }
    }

    @Test fun current115CdnIsAcceptedByLinkAndStreamingPoliciesWithoutBroadeningCookieScope() {
        val signed = "https://cdnfhnfile.115cdn.net/video.mp4?sign=a%2Fb%2Bc&n=%E4%B8%AD"
        assertEquals(signed, CloudDrive.secureMediaUrl(signed, CloudDrive.P115))
        assertEquals(signed, CloudDrive.secureMediaUrl(signed.replace("https:", "http:"), CloudDrive.P115))
        assertTrue(CloudDrive.allowedMediaUri(URI(signed)))
        assertFalse(CloudDrive.allowedMediaUri(URI(signed), CloudDrive.BAIDU))
        assertFalse(CloudDrive.within(URI(signed).host, "115.com"))
        for (value in listOf("https://115cdn.net.evil.test/file", "https://evil115cdn.net/file",
                "https://user:secret@cdnfhnfile.115cdn.net/file", "https://cdnfhnfile.115cdn.net:8443/file",
                "http://cdnfhnfile.115cdn.net/file", "file:///115cdn.net/file")) {
            assertFalse(value, CloudDrive.allowedMediaUri(URI(value)))
        }
    }
}
