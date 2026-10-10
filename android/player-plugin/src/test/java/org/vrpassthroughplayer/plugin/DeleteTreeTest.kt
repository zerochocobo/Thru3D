package org.vrpassthroughplayer.plugin
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
class DeleteTreeTest {
    @Test fun includesHiddenNonMediaAndDetectsChangedContents() {
        val root = Files.createTempDirectory("tree-delete-plan").toFile()
        try {
            root.resolve("a.mp4").writeText("video")
            root.resolve("a.srt").writeText("subtitle")
            root.resolve(".hidden").writeText("private")
            root.resolve("sub").mkdir()
            root.resolve("sub/notes.txt").writeText("notes")
            val first = DeleteTree.local(root)
            assertEquals(4, first.summary().getInt("files"))
            assertEquals(1, first.summary().getInt("folders"))
            first.verify(first.summary())
            root.resolve("sub/notes.txt").appendText("changed")
            val next = DeleteTree.local(root)
            assertThrows(IllegalStateException::class.java) { next.verify(first.summary()) }
        } finally { root.resolve("sub").listFiles()?.forEach { it.delete() }; root.listFiles()?.forEach { it.delete() }; root.delete() }
    }
}
