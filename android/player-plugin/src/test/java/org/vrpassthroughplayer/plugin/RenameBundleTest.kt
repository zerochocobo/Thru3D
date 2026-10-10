package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class RenameBundleTest {
    @Test fun includesAllMatchingCompanionsAndPreservesSuffixes() {
        val bundle = RenameBundle("Episode1.mp4", "旅行", listOf("Episode1.mp4", "Episode1.zh.srt", "Episode1.si.mix.m4a", "Episode1.idx", "Episode10.srt", "Episode1.jpg"))
        assertEquals(setOf("旅行.mp4", "旅行.zh.srt", "旅行.si.mix.m4a", "旅行.idx"), bundle.moves.map { it.to }.toSet())
        assertFalse(bundle.moves.any { it.from == "Episode10.srt" || it.from.endsWith(".jpg") })
    }
    @Test fun blocksCollisionsAndUnsafeNamesBeforeMutation() {
        assertThrows(IllegalArgumentException::class.java) { RenameBundle("old.mp4", "new", listOf("old.mp4", "NEW.mp4")) }
        for (name in listOf("../new", "CON", "new/part", ".", "new.", " name", "na?me"))
            assertThrows(IllegalArgumentException::class.java) { RenameBundle("old.mp4", name, listOf("old.mp4")) }
    }
    @Test fun rollsBackPriorMovesOnFailureAndReportsFailedRollback() {
        val bundle = RenameBundle("old.mp4", "new", listOf("old.mp4", "old.srt"))
        val moves = ArrayList<Pair<String, String>>()
        val result = bundle.execute { from, to -> if (from == "old.srt") error("readonly") else moves.add(from to to) }
        assertFalse(result.getBoolean("renamed"))
        assertEquals(listOf("old.mp4" to "new.mp4", "new.mp4" to "old.mp4"), moves)
        val partial = bundle.execute { from, _ -> if (from != "old.mp4") error("offline") }
        assertTrue(partial.getBoolean("partial"))
        assertEquals("new.mp4", partial.getJSONArray("remaining").getJSONObject(0).getString("to"))
    }
}
