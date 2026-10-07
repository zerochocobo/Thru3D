# p115rsacipher

Cloud115Cipher.kt adapts the RSA download codec from p115rsacipher 0.0.1 by
ChenyangGao, under the MIT License. The full license is adjacent in LICENSE.

Source: https://pypi.org/project/p115rsacipher/0.0.1/
Repository: https://github.com/ChenyangGao/p115client/tree/main/modules/p115rsacipher
Verified wheel: p115rsacipher-0.0.1-py3-none-any.whl
SHA-256: d537de3082f6141b1128506f7a499c6af07c30d7543d59ac6d1d866c4bf33d99

Changes: Kotlin/JVM translation, Java BigInteger/Base64, bounded block decoding
and malformed-input checks. The Python package and its runtime are not shipped.
Only this separately MIT-licensed module was adapted, not the surrounding
p115client implementation or OpenList drivers. The provider adapters and WebDAV
server are project code.
