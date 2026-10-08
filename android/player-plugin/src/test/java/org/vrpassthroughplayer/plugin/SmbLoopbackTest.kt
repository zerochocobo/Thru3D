package org.vrpassthroughplayer.plugin

import org.codelibs.jcifs.smb.config.PropertyConfiguration
import org.codelibs.jcifs.smb.context.BaseContext
import org.codelibs.jcifs.smb.impl.NtlmPasswordAuthenticator
import org.codelibs.jcifs.smb.impl.SmbFile
import org.codelibs.jcifs.smb.impl.SmbRandomAccessFile
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Optional local fixture server; no real account or media is accessed. */
class SmbLoopbackTest {
    @Test fun enumeratesSharesAndSeeksWithoutChangingStoredUriFormat() {
        val host = System.getenv("VRPP_SMB_FIXTURE_HOST") ?: ""
        assumeTrue(host.isNotEmpty())
        val base = BaseContext(PropertyConfiguration(SmbClientPolicy.properties(false)))
        val context = base.withCredentials(NtlmPasswordAuthenticator("", "vrtest", "fixture-only"))
        try {
            SmbFile("smb://$host/", context).use { root ->
                val files = root.listFiles()
                try { assertTrue(files.any { it.name.trimEnd('/') == "fixture" }) }
                finally { files.forEach { it.close() } }
            }
            SmbFile("smb://$host/fixture/", context).use { root ->
                assertTrue(root.list().contains("sample.mp4"))
                assertTrue(root.list().contains("sample.srt"))
            }
            SmbFile("smb://$host/fixture/sample.mp4", context).use { file ->
                assertEquals(262144L, file.length())
                SmbRandomAccessFile(file, "r").use { reader ->
                    for (offset in listOf(0L, 131071L, 7L, 260000L)) {
                        reader.seek(offset)
                        val actual = ByteArray(1024)
                        reader.readFully(actual)
                        assertArrayEquals(ByteArray(1024) { ((offset + it) * 31).toByte() }, actual)
                    }
                }
            }
        } finally { context.close() }
    }
}
