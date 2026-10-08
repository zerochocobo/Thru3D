package org.vrpassthroughplayer.plugin

import java.util.Properties

/** CodeLibs uses jcifs.client.*, unlike the old jcifs-ng property prefix. */
internal object SmbClientPolicy {
    /** Accept a server or a direct share (including Windows UNC form). */
    fun address(value: String): String {
        val normalized = value.trim().replace('\\', '/').removePrefix("smb://").trim('/')
        val host = normalized.substringBefore('/')
        require(host.isNotEmpty() && host.matches(Regex("[A-Za-z0-9_.:\\[\\]-]+"))) { "SMB address invalid" }
        require(normalized.split('/').none { it == ".." || it == "." || it.isEmpty() }) { "SMB path invalid" }
        require(!normalized.contains('?') && !normalized.contains('#')) { "SMB path invalid" }
        return normalized
    }

    fun properties(guest: Boolean) = Properties().apply {
        setProperty("jcifs.client.minVersion", "SMB202")
        setProperty("jcifs.client.maxVersion", "SMB311")
        setProperty("jcifs.client.useSMB2Negotiation", "true")
        setProperty("jcifs.client.encryptionEnabled", "true")
        setProperty("jcifs.client.responseTimeout", "15000")
        setProperty("jcifs.client.connTimeout", "5000")
        // Guest sessions have no signing key. Only relax the client's IPC preference
        // for an explicitly selected guest login; server-required signing still wins.
        setProperty("jcifs.client.ipcSigningEnforced", (!guest).toString())
        setProperty("jcifs.resolveOrder", "DNS,BCAST")
    }
}
