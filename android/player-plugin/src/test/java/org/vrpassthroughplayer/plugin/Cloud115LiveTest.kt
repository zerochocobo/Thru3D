package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.util.Base64

/** Opt-in anonymous endpoint smoke test. Never submits an account, password or solved captcha. */
class Cloud115LiveTest {
    @Test fun officialKeyAndCaptchaSession() {
        assumeTrue(System.getenv("VRPP_TEST_115_PUBLIC_ENDPOINTS") == "1")
        Cloud115Auth.HttpTransport().use { transport ->
            val key = JSONObject(String(transport.request("https://passportapi.115.com/app/1.0/web/1.0/login/getKey", null)))
                .getJSONObject("data").getString("key")
            val encrypted = Cloud115Auth.encryptPassword("unused-local-fixture".toCharArray(), key)
            assertTrue(Base64.getDecoder().decode(encrypted).size >= 128)
            val challenge = Cloud115Auth(transport).challenge()
            assertTrue(challenge.sign.isNotBlank())
            for (bytes in listOf(challenge.prompt, challenge.choices)) {
                assertTrue(bytes.size in 100..1024 * 1024)
                val image = (bytes[0] == 0xff.toByte() && bytes[1] == 0xd8.toByte()) ||
                    String(bytes.copyOfRange(1, 4)) == "PNG" || String(bytes.copyOfRange(0, 3)) == "GIF"
                assertTrue("Expected a captcha image, not an HTML/JSON error", image)
            }
        }
    }
}
