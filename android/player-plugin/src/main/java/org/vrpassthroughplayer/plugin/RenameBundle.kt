package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject

/** Same stem plus a dot boundary includes language/clone-voice suffixes without taking episode10. */
internal class RenameBundle(video: String, newStem: String, names: Collection<String>) {
    data class Move(val from: String, val to: String)
    val moves: List<Move>
    init {
        require(newStem == newStem.trim() && newStem.isNotEmpty() && newStem.length <= 160 &&
            newStem.toByteArray().size <= 200 && !newStem.startsWith('.') && !newStem.endsWith('.') &&
            newStem.none { it < ' ' || it in "/\\:*?\"<>|#%" } && newStem !in setOf(".", "..")) { "Invalid file name" }
        require(!Regex("(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\\..*)?").matches(newStem)) { "Invalid file name" }
        val stem = video.substringBeforeLast('.')
        require(!stem.equals(newStem, true)) { "Name is unchanged" }
        val extensions = setOf("srt", "ass", "ssa", "vtt", "smi", "sami", "sub", "idx", "m4a", "aac", "mp3", "flac", "wav", "ogg", "opus", "ac3", "eac3", "dts")
        val companions = names.filter { it != video && it.startsWith("$stem.", true) && it.substringAfterLast('.').lowercase() in extensions }.sorted()
        require(companions.size <= 64) { "Too many companion files" }
        moves = (listOf(video) + companions).map { Move(it, newStem + it.substring(stem.length)) }
        val existing = names.map { it.lowercase(java.util.Locale.ROOT) }.toSet()
        require(moves.all { it.to.lowercase(java.util.Locale.ROOT) !in existing } &&
            moves.map { it.to.lowercase(java.util.Locale.ROOT) }.distinct().size == moves.size) { "A file with that name already exists" }
    }
    fun preview() = JSONArray().apply { moves.forEach { put(JSONObject().put("from", it.from).put("to", it.to)) } }
    fun fingerprint(stats: (String) -> Pair<Long, Long>): String {
        val records = moves.map { val info = stats(it.from); DeleteTree.Entry(it.from + "→" + it.to, false, info.first, info.second) }
        return DeleteTree(records).fingerprint
    }
    fun execute(inspect: ((Move) -> Int)? = null, rename: (String, String) -> Unit): JSONObject {
        val completed = ArrayList<Move>()
        var attempted: Move? = null
        try {
            for (move in moves) { attempted = move; rename(move.from, move.to); completed.add(move) }
            return JSONObject().put("renamed", true).put("moves", preview())
        } catch (_: Exception) {
            // A lost SMB acknowledgement can follow a successful server rename.
            // Read both locations before trying to revert that ambiguous step.
            if (inspect != null && attempted != null && runCatching { inspect(attempted!!) }.getOrDefault(-1) == 1 && attempted !in completed)
                completed.add(attempted!!)
            val remaining = ArrayList<Move>()
            for (move in completed.reversed()) {
                try { rename(move.to, move.from) } catch (_: Exception) { remaining.add(move) }
            }
            val unknown = ArrayList<Move>()
            if (inspect != null) {
                remaining.clear()
                for (move in moves) when (runCatching { inspect(move) }.getOrDefault(-1)) {
                    1 -> remaining.add(move)
                    -1 -> unknown.add(move)
                }
            }
            return JSONObject().put("state", "error").put("renamed", false).put("partial", remaining.isNotEmpty())
                .put("remaining", JSONArray().apply { remaining.forEach { put(JSONObject().put("from", it.from).put("to", it.to)) } })
                .put("unknown_moves", JSONArray().apply { unknown.forEach { put(JSONObject().put("from", it.from).put("to", it.to)) } })
                .put("error", if (unknown.isNotEmpty()) "Rename result needs checking" else if (remaining.isEmpty()) "Rename failed; check the folder" else "Some names changed; check the folder")
        }
    }
}
