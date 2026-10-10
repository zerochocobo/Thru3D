package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject

/** The VR browser consumes capabilities and nodes, never provider names or native API fields. */
internal object MediaLibraryPresentation {
    fun capabilities(facets: List<String> = emptyList(), navigation: List<String> = facets,
        filters: List<String> = listOf("watched"), sorts: List<String> = listOf("created_at", "title", "date", "duration", "rating100"),
        search: Boolean = true, favoriteScope: String = "local", excludes: List<String> = emptyList(),
        tagMatchAll: Boolean = false, descendants: Boolean = false, tree: Boolean = false,
        unclassified: List<String> = emptyList()): JSONObject = JSONObject()
        .put("facets", JSONArray(facets)).put("navigation", JSONArray(navigation))
        .put("filters", JSONArray(filters)).put("sorts", JSONArray(sorts)).put("search", search)
        .put("favorite_scope", favoriteScope).put("exclude_facets", JSONArray(excludes))
        .put("tag_match_all", tagMatchAll).put("descendants", descendants)
        .put("folders", tree).put("libraries", tree).put("unclassified", JSONArray(unclassified))

    fun home(client: MediaLibraryClient, request: JSONObject): JSONObject {
        val q = JSONObject().put("page", 1).put("sort", "created_at")
        val result = client.browse(q)
        return JSONObject().put("capabilities", client.capabilities()).put("total", result.optInt("total"))
            .put("recent", JSONArray(result.getJSONArray("entries").objects().take(4)))
            .put("resume", JSONArray()).put("libraries", JSONArray()).put("library_id", "")
    }
}
