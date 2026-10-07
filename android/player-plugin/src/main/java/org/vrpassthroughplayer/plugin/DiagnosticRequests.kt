package org.vrpassthroughplayer.plugin

import java.lang.ref.WeakReference

/** Debug receiver lives in src/debug only. It uses the actual running Godot plugin. */
internal object DiagnosticRequests {
    val processId: String = java.util.UUID.randomUUID().toString()
    @Volatile private var plugin = WeakReference<QuestPlayerPlugin>(null)
    fun attach(value: QuestPlayerPlugin) { plugin = WeakReference(value) }
    fun current(): QuestPlayerPlugin? = plugin.get()
}
