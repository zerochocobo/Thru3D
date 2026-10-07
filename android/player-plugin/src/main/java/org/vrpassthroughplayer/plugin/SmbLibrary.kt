package org.vrpassthroughplayer.plugin

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import jcifs.CIFSContext
import jcifs.config.PropertyConfiguration
import jcifs.context.BaseContext
import jcifs.smb.NtlmPasswordAuthenticator
import jcifs.smb.SmbFile
import jcifs.smb.SmbRandomAccessFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.util.Properties
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** SMB2/3 shares through jcifs-ng. Servers are saved in app-private storage; passwords are
 * AES-GCM encrypted with a non-exportable Android Keystore key. Calls block: use a worker.
 * Playback URIs are smb://<server id>/<share>/<path>; [stream] turns them into a loopback
 * HTTP URL so MPV can seek. */
internal class SmbLibrary(private val context: Context, private val streams: () -> LocalStreamServer) {
    data class Server(val id: String, val name: String, val host: String, val domain: String,
                      val user: String, val password: String)

    private val store = File(context.filesDir, "smb_servers.json")
    private val contexts = HashMap<String, CIFSContext>()

    @Synchronized fun servers(): List<Server> {
        if (!store.isFile) return emptyList()
        val array = JSONArray(store.readText())
        return (0 until array.length()).map { array.getJSONObject(it) }.map {
            Server(it.getString("id"), it.optString("name"), it.getString("host"), it.optString("domain"),
                it.optString("user"), it.optString("password_sealed").takeIf(String::isNotEmpty)?.let(::unseal) ?: "")
        }
    }

    /** Public view: never includes passwords. */
    fun serversJson(): JSONArray = JSONArray().apply {
        for (s in servers()) put(JSONObject().put("id", s.id).put("name", s.name).put("host", s.host)
            .put("user", s.user).put("has_password", s.password.isNotEmpty()))
    }

    /** Adds or replaces (same id) a server. An empty password keeps the saved one. */
    @Synchronized fun save(request: JSONObject): String {
        val host = request.getString("host").trim().removePrefix("smb://").trim('/', '\\')
        require(host.isNotEmpty() && !host.contains('/')) { "SMB host required" }
        val id = request.optString("id").ifEmpty { UUID.randomUUID().toString() }
        val previous = servers().firstOrNull { it.id == id }
        val password = request.optString("password").ifEmpty { previous?.password ?: "" }
        val updated = servers().filter { it.id != id } + Server(id, request.optString("name").ifEmpty { host }, host,
            request.optString("domain"), request.optString("user"), password)
        write(updated)
        synchronized(contexts) { contexts.remove(id) }
        return id
    }

    @Synchronized fun remove(id: String) { write(servers().filter { it.id != id }); synchronized(contexts) { contexts.remove(id) } }

    private fun write(list: List<Server>) {
        val array = JSONArray()
        for (s in list) array.put(JSONObject().put("id", s.id).put("name", s.name).put("host", s.host).put("domain", s.domain)
            .put("user", s.user).put("password_sealed", if (s.password.isEmpty()) "" else seal(s.password)))
        val temporary = File(store.parentFile, store.name + ".tmp")
        temporary.writeText(array.toString())
        check(temporary.renameTo(store)) { "SMB server list write failed" }
    }

    private fun server(id: String) = servers().firstOrNull { it.id == id } ?: error("Unknown SMB server")

    private fun cifs(server: Server): CIFSContext = synchronized(contexts) {
        contexts.getOrPut(server.id) {
            val properties = Properties().apply {
                setProperty("jcifs.smb.client.minVersion", "SMB202")
                setProperty("jcifs.smb.client.maxVersion", "SMB311")
                setProperty("jcifs.smb.client.responseTimeout", "15000")
                setProperty("jcifs.smb.client.connTimeout", "5000")
                setProperty("jcifs.resolveOrder", "DNS,BCAST")
            }
            val base = BaseContext(PropertyConfiguration(properties))
            if (server.user.isEmpty()) base.withGuestCrendentials()
            else base.withCredentials(NtlmPasswordAuthenticator(server.domain, server.user, server.password))
        }
    }

    /** path "" lists shares; otherwise "share/dir/...". Folders first, then video files. */
    fun browse(id: String, path: String): JSONArray {
        val server = server(id)
        val clean = path.trim('/')
        val url = "smb://${server.host}/" + if (clean.isEmpty()) "" else "$clean/"
        val entries = JSONArray()
        SmbFile(url, cifs(server)).use { directory ->
            val children = directory.listFiles().sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))
            for (child in children) {
                val name = child.name.trimEnd('/')
                if (name.endsWith("$")) continue // administrative shares
                val childPath = if (clean.isEmpty()) name else "$clean/$name"
                if (child.isDirectory) entries.put(JSONObject().put("id", childPath).put("title", name).put("container", true))
                else if (MediaKinds.supported(name)) entries.put(JSONObject().put("id", childPath).put("title", name).put("kind", MediaKinds.kind(name))
                    .put("container", false).put("size", child.length()).put("uri", "smb://$id/$childPath"))
                child.close()
            }
        }
        return entries
    }

    /** Sibling "<stem>*.m4a" tracks of an smb:// video, each as a loopback stream (see [SidecarAudio]). */
    fun sidecarAudio(uri: String): List<SidecarAudio.Track> {
        val rest = uri.removePrefix("smb://")
        val server = server(rest.substringBefore('/'))
        val path = rest.substringAfter('/')
        val folder = path.substringBeforeLast('/', "")
        if (folder.isEmpty()) return emptyList()
        val video = path.substringAfterLast('/')
        val names = SmbFile("smb://${server.host}/$folder/", cifs(server)).use { directory ->
            directory.list().map { it.trimEnd('/') }
        }
        return SidecarAudio.select(video, names).map {
            SidecarAudio.Track(stream("smb://${rest.substringBefore('/')}/$folder/$it"), SidecarAudio.title(video, it))
        }
    }

    fun sidecarSubtitles(uri: String): List<SidecarSubtitles.Track> {
        val rest = uri.removePrefix("smb://")
        val id = rest.substringBefore('/')
        val server = server(id)
        val path = rest.substringAfter('/')
        val folder = path.substringBeforeLast('/', "")
        if (folder.isEmpty()) return emptyList()
        val video = path.substringAfterLast('/')
        val names = SmbFile("smb://${server.host}/$folder/", cifs(server)).use { it.list().toList() }
        return SidecarSubtitles.select(video, names).mapNotNull { name ->
            // One inaccessible subtitle must not hide other tracks or fail video playback.
            runCatching {
                SidecarSubtitles.Track(stream("smb://$id/$folder/$name"), name)
            }.getOrNull()
        }
    }

    /** smb://<server id>/<share>/<path> -> loopback HTTP URL with Range support. */
    fun stream(uri: String): String {
        val rest = uri.removePrefix("smb://")
        val server = server(rest.substringBefore('/'))
        val path = rest.substringAfter('/')
        val url = "smb://${server.host}/$path"
        val context = cifs(server)
        val size = SmbFile(url, context).use { it.length() }
        val source = object : StreamSource {
            override val size = size
            override fun open(): StreamSource.Reader {
                val file = SmbFile(url, context)
                val reader = SmbRandomAccessFile(file, "r")
                return object : StreamSource.Reader {
                    override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                        reader.seek(offset)
                        return reader.read(buffer, 0, length)
                    }
                    override fun close() { reader.close(); file.close() }
                }
            }
        }
        return streams().publish(source, path.substringAfterLast('/'))
    }

    /** SMB hosts seen within [timeoutMs]: mDNS _smb._tcp (NAS, macOS, Samba) plus WS-Discovery,
     * which Windows uses instead of mDNS for its file shares. [{name, host}] */
    fun discover(timeoutMs: Long = 2500): JSONArray {
        val windows = Thread { wsdHosts.clear(); wsdHosts.addAll(wsDiscovery(timeoutMs.toInt())) }.apply { start() }
        val found = mdns(timeoutMs)
        windows.join(timeoutMs + 1000)
        val seen = (0 until found.length()).map { found.getJSONObject(it).getString("host") }.toHashSet()
        for ((host, name) in wsdHosts.toList()) if (seen.add(host)) found.put(JSONObject().put("name", name).put("host", host))
        return found
    }
    private val wsdHosts = java.util.concurrent.ConcurrentLinkedQueue<Pair<String, String>>()

    /** WS-Discovery Probe (UDP 3702): Windows computers answer with their address; the share list
     * itself is read over SMB once the user connects. Pairs of (host, display name). */
    private fun wsDiscovery(timeoutMs: Int): List<Pair<String, String>> {
        val result = LinkedHashMap<String, String>()
        val probe = ("""<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" """ +
            """xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery" """ +
            """xmlns:wsdp="http://schemas.xmlsoap.org/ws/2006/02/devprof" xmlns:pub="http://schemas.microsoft.com/windows/pub/2005/07">""" +
            """<soap:Header><wsa:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</wsa:To>""" +
            """<wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</wsa:Action>""" +
            """<wsa:MessageID>urn:uuid:${UUID.randomUUID()}</wsa:MessageID></soap:Header>""" +
            """<soap:Body><wsd:Probe><wsd:Types>wsdp:Device pub:Computer</wsd:Types></wsd:Probe></soap:Body></soap:Envelope>""").toByteArray()
        runCatching {
            java.net.MulticastSocket().use { socket ->
                socket.soTimeout = 300
                val group = java.net.InetAddress.getByName("239.255.255.250")
                for (lan in DlnaClient.lanInterfaces().ifEmpty { listOf(null) }) {
                    if (lan != null) runCatching { socket.networkInterface = lan }
                    repeat(2) { runCatching { socket.send(java.net.DatagramPacket(probe, probe.size, group, 3702)) } }
                }
                val deadline = System.currentTimeMillis() + timeoutMs
                val buffer = ByteArray(16384)
                while (System.currentTimeMillis() < deadline) {
                    val packet = java.net.DatagramPacket(buffer, buffer.size)
                    try { socket.receive(packet) } catch (_: java.net.SocketTimeoutException) { continue }
                    val text = String(packet.data, 0, packet.length)
                    // Only computers (pub:Computer) host Windows file shares; printers etc. also answer.
                    if (!text.contains("Computer")) continue
                    val host = packet.address.hostAddress ?: continue
                    val name = Regex("pub:Computer>([^<]+)<").find(text)?.groupValues?.get(1)?.substringBefore('/')?.trim()
                    result.putIfAbsent(host, name?.takeIf { it.isNotEmpty() } ?: host)
                }
            }
        }
        return result.map { it.key to it.value }
    }

    /** mDNS _smb._tcp hosts seen within [timeoutMs]: [{name, host}]. */
    private fun mdns(timeoutMs: Long): JSONArray {
        val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
        val found = JSONArray()
        val seen = HashSet<String>()
        val pending = mutableListOf<NsdServiceInfo>()
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) { synchronized(pending) { pending.add(info) } }
            override fun onServiceLost(info: NsdServiceInfo) {}
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onStartDiscoveryFailed(type: String, code: Int) {}
            override fun onStopDiscoveryFailed(type: String, code: Int) {}
        }
        nsd.discoverServices("_smb._tcp.", NsdManager.PROTOCOL_DNS_SD, listener)
        Thread.sleep(timeoutMs)
        try { nsd.stopServiceDiscovery(listener) } catch (_: Throwable) {}
        for (info in synchronized(pending) { pending.toList() }) {
            val latch = CountDownLatch(1)
            @Suppress("DEPRECATION")
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(service: NsdServiceInfo, code: Int) { latch.countDown() }
                override fun onServiceResolved(service: NsdServiceInfo) {
                    @Suppress("DEPRECATION") val host = service.host?.hostAddress
                    if (host != null && seen.add(host)) synchronized(found) { found.put(JSONObject().put("name", service.serviceName).put("host", host)) }
                    latch.countDown()
                }
            })
            latch.await(2, TimeUnit.SECONDS)
        }
        return found
    }

    private fun key(): SecretKey {
        val keystore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keystore.getEntry(KEY, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(KEY, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    private fun seal(text: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        return Base64.encodeToString(cipher.iv + cipher.doFinal(text.toByteArray()), Base64.NO_WRAP)
    }
    private fun unseal(sealed: String): String = try {
        val bytes = Base64.decode(sealed, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, 12))
        }
        String(cipher.doFinal(bytes, 12, bytes.size - 12))
    } catch (_: Throwable) { "" } // Key lost (e.g. backup restore): the user re-enters the password.

    companion object { private const val KEY = "quest_player_smb" }
}
