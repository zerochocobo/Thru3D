package org.vrpassthroughplayer.plugin

import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.util.Base64

/** Kotlin adaptation of p115rsacipher 0.0.1 (MIT, ChenyangGao).
 * Protocol obfuscation only; transport and credential storage use TLS and AES-GCM.
 * Provenance and full license: third_party/p115rsacipher/.
 */
internal object Cloud115Cipher {
    private val modulus = BigInteger("8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b8602136477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad6338c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f10a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683", 16)
    private val exponent = BigInteger.valueOf(65537)
    private val shortKey = hex("8da5a58d")
    private val longKey = hex("7806ad4c33865d184c013f46")
    private val table = hex("f0e569aebfdcbf8a1a45e8be7da673b8de8fe7c445da86c49b648b146ab4f1aa3801359e26692c86006b4fa5363462a62a966818f24afdbd6b978f4d8f8913b76c8e93ed0e0d483ed72f88d8fefe7e8650954fd1eb832634db667b9c7e9d7a8132eab633de3aa95934663baaba816048b9d5819cf86c8477ff5478265fbee81e369f34805c452c9b76d51b8fccc3b8f5")
    private fun hex(value: String) = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private fun xor(data: ByteArray, key: ByteArray): ByteArray {
        val prefix = data.size % 4
        return ByteArray(data.size) { i -> (data[i].toInt() xor key[if (i < prefix) i else (i - prefix) % key.size].toInt()).toByte() }
    }
    fun encrypt(text: String): String {
        val payload = ByteArray(16) + xor(xor(text.toByteArray(Charsets.UTF_8), shortKey).reversedArray(), longKey)
        val out = ByteArrayOutputStream()
        for (offset in payload.indices step 117) {
            val count = minOf(117, payload.size - offset)
            val padded = ByteArray(128) { 2 }.apply {
                this[0] = 0; this[127 - count] = 0
                payload.copyInto(this, 128 - count, offset, offset + count)
            }
            val block = BigInteger(1, padded).modPow(exponent, modulus).toByteArray()
            val fixed = ByteArray(128)
            val length = minOf(block.size, 128)
            block.copyInto(fixed, 128 - length, block.size - length)
            out.write(fixed)
        }
        return Base64.getEncoder().encodeToString(out.toByteArray())
    }
    fun decrypt(value: String): String {
        val encrypted = Base64.getDecoder().decode(value)
        require(encrypted.isNotEmpty() && encrypted.size % 128 == 0 && encrypted.size <= 1024 * 1024)
        val out = ByteArrayOutputStream()
        for (offset in encrypted.indices step 128) {
            val block = BigInteger(1, encrypted.copyOfRange(offset, offset + 128)).modPow(exponent, modulus).toByteArray()
            val from = if (block[0] == 0.toByte()) 1 else 0
            val separator = (from until block.size).firstOrNull { block[it] == 0.toByte() } ?: error("Invalid 115 block")
            require(separator - from >= 8)
            out.write(block, separator + 1, block.size - separator - 1)
        }
        val payload = out.toByteArray()
        require(payload.size >= 16)
        val key = ByteArray(12) { i ->
            (table[132 - 12 * i].toInt() xor ((payload[i].toInt() + table[12 * i].toInt()) and 255)).toByte()
        }
        return String(xor(xor(payload.copyOfRange(16, payload.size), key).reversedArray(), shortKey), Charsets.UTF_8)
    }
}
