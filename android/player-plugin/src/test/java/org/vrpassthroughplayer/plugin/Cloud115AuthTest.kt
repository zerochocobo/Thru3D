package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.security.KeyPairGenerator
import java.util.Base64
import javax.crypto.Cipher

class Cloud115AuthTest {
    private val pair = KeyPairGenerator.getInstance("RSA").apply { initialize(1024) }.generateKeyPair()
    private val publicKey = Base64.getEncoder().encodeToString(
        ("-----BEGIN PUBLIC KEY-----\n" + Base64.getEncoder().encodeToString(pair.public.encoded) + "\n-----END PUBLIC KEY-----").toByteArray())

    private fun decrypt(encoded: String): String = Cipher.getInstance("RSA/ECB/PKCS1Padding").run {
        init(Cipher.DECRYPT_MODE, pair.private)
        String(doFinal(Base64.getDecoder().decode(encoded)))
    }

    private class Step(val suffix: String, val response: String, val inspect: (Map<String, String>?) -> Unit = {})
    private class Fixture(vararg steps: Step) : Cloud115Auth.Transport {
        val queue = ArrayDeque(steps.toList())
        var closed = false
        override fun request(url: String, form: Map<String, String>?): ByteArray {
            check(!closed)
            val step = queue.removeFirst()
            assertTrue("Unexpected endpoint", url.endsWith(step.suffix))
            step.inspect(form)
            return step.response.toByteArray()
        }
        override fun close() { closed = true }
    }

    @Test fun passwordIsEncryptedWithFreshServerKeyAndTimestamp() {
        val secret = "password".toCharArray()
        val encrypted = Cloud115Auth.encryptPassword(secret, publicKey, 1700000000)
        assertEquals("5baa61e4c9b93f3f0682250b6cf8331b7ee68fd8_1700000000", decrypt(encrypted))
        assertArrayEquals("password".toCharArray(), secret)
        assertNotEquals(encrypted, Cloud115Auth.encryptPassword(secret, publicKey, 1700000000))
    }

    @Test fun captchaRetryPreservesAccountAndSubmitsUserSelectionWithSessionSign() {
        val key = JSONObject().put("data", JSONObject().put("key", publicKey)).toString()
        val transport = Fixture(
            Step("login/getKey", key),
            Step("login/login", """{"state":false,"errno":40101004}""") { form ->
                assertEquals("fixture-account", form!!["account"])
                assertFalse(form.values.contains("password"))
                assertTrue(decrypt(form.getValue("passwd")).startsWith("5baa61e4c9b93f3f0682250b6cf8331b7ee68fd8_"))
            },
            Step("?ac=code&t=sign", """{"state":true,"sign":"fixture-sign"}"""),
            Step("?ct=index&ac=code", "prompt"),
            Step("?ct=index&ac=code&t=all", "choices"),
            Step("login/getKey", key),
            Step("login/login", """{"state":1,"data":{"cookie":{"UID":"fixture","CID":"cid","SEID":"seid","KID":"kid"}}}""") { form ->
                assertEquals("9250", form!!["code"])
                assertEquals("fixture-sign", form["code_id"])
                assertEquals("2", form["cipher_ver"])
            })
        Cloud115Auth(transport).use { auth ->
            assertSame(Cloud115Auth.Result.Captcha, auth.password("fixture-account", "password".toCharArray()))
            val challenge = auth.challenge()
            assertEquals("choices", String(challenge.choices))
            val result = auth.password("fixture-account", "password".toCharArray(), Cloud115Auth.Answer(challenge.sign, "9250")) as Cloud115Auth.Result.Connected
            assertEquals("UID=fixture; CID=cid; SEID=seid; KID=kid", result.cookie)
        }
        assertTrue(transport.closed)
        assertTrue(transport.queue.isEmpty())
    }

    @Test fun twoStepRequiresExplicitSmsSendAndVerifiesServerUserId() {
        val sms = Cloud115Auth.parse(JSONObject("""{"state":false,"errno":40101010,"data":{"user_id":1234}}""")) as Cloud115Auth.Result.Sms
        assertTrue(sms.twoStep)
        val fixture = Fixture(
            Step("code/sms/login", """{"state":true}""") { form ->
                assertEquals("1234", form!!["user_id"])
                assertEquals("login_from_two_step", form["tpl"])
            },
            Step("login/vip", """{"state":true,"data":{"cookie":{"UID":"u","CID":"c","SEID":"s"}}}""") { form ->
                assertEquals("1234", form!!["account"])
                assertEquals("123456", form["code"])
                assertFalse(form.containsKey("passwd"))
            })
        Cloud115Auth(fixture).use { auth ->
            assertEquals(2, fixture.queue.size)
            assertSame(Cloud115Auth.Result.Sent, auth.sendSms(sms))
            assertTrue(auth.verifySms(sms, "123456") is Cloud115Auth.Result.Connected)
        }
        assertTrue(fixture.queue.isEmpty())
    }

    @Test fun distinguishesSmsCaptchaAndFailedAuthentication() {
        assertFalse((Cloud115Auth.parse(JSONObject("""{"errno":90059,"data":{"user_id":"42"}}""")) as Cloud115Auth.Result.Sms).twoStep)
        for (code in listOf(10098, 40101004, 40103000)) {
            assertSame(Cloud115Auth.Result.Captcha, Cloud115Auth.parse(JSONObject().put("errno", code)))
        }
        for (body in listOf("""{"state":1}""", """{"state":true,"data":{"cookie":{"UID":"u"}}}""",
            """{"errno":40101010,"data":{}}""", """{"state":false,"errno":40101007,"error":"sensitive upstream content"}""")) {
            assertTrue(Cloud115Auth.parse(JSONObject(body)) is Cloud115Auth.Result.Rejected)
        }
    }

    @Test fun smsAcceptsHttpCookiesOnlyAfterServerConfirmsLogin() {
        var allowed = false
        val transport = object : Cloud115Auth.Transport {
            override fun request(url: String, form: Map<String, String>?) =
                JSONObject().put("state", allowed).toString().toByteArray()
            override fun sessionCookies() = JSONObject().put("UID", "u").put("CID", "c").put("SEID", "s")
            override fun close() {}
        }
        Cloud115Auth(transport).use { auth ->
            val sms = Cloud115Auth.Result.Sms("123", true)
            assertTrue(auth.verifySms(sms, "123456") is Cloud115Auth.Result.Rejected)
            allowed = true
            assertEquals("UID=u; CID=c; SEID=s", (auth.verifySms(sms, "123456") as Cloud115Auth.Result.Connected).cookie)
        }
    }

    @Test fun cookiesOnlyContainExpectedValidSessionFields() {
        val good = JSONObject().put("UID", "u").put("CID", "c").put("SEID", "s").put("unrelated", "private")
        assertEquals("UID=u; CID=c; SEID=s", Cloud115Auth.cookieHeader(good))
        for (bad in listOf("", "\r\nHeader:x", "a;b=c", "white space", "a,b")) {
            assertNull(Cloud115Auth.cookieHeader(JSONObject(good.toString()).put("CID", bad)))
        }
    }

    @Test fun transportRejectsRedirectTargetsAndClosedSessionsBeforeConnecting() {
        val transport = Cloud115Auth.HttpTransport()
        for (url in listOf("http://passportapi.115.com/", "https://passportapi.115.com.evil.invalid/", "https://evil.invalid/",
            "https://user@passportapi.115.com/", "https://passportapi.115.com:443/")) {
            assertThrows(IllegalArgumentException::class.java) { transport.request(url, emptyMap()) }
        }
        transport.close()
        assertThrows(IllegalStateException::class.java) { transport.request("https://passportapi.115.com/", null) }
    }
}
