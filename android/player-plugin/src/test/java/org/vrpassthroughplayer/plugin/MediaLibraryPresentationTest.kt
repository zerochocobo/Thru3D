package org.vrpassthroughplayer.plugin

import java.net.URI
import java.net.URLDecoder
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class MediaLibraryPresentationTest {
    @Test fun scopedHomeHierarchyFacetsAndCompletePaging() {
        val mutations = mutableListOf<String>()
        val movies = (1..250).map { id -> JSONObject().put("Id", "$id").put("Name", "Film $id").put("Type", "Movie")
            .put("MediaSources", JSONArray().put(JSONObject().put("Path", "/private/Film_${id}_180_SBS.mkv")))
            .put("RunTimeTicks", 600000000L)
            .put("Genres", JSONArray(if (id <= 54) listOf("Drama") else emptyList<String>()))
            .put("TagItems", JSONArray(if (id <= 53) listOf(JSONObject().put("Id", "tag1").put("Name", "Tag & A")) else emptyList<JSONObject>()))
            .put("UserData", JSONObject().put("PlaybackPositionTicks", if (id == 1) 300000000L else 0L)) }
        val fixture = MediaServerClientTest.Fixture { request, _, _ ->
            val uri = URI("http://fixture" + request.split(' ')[1])
            val q = uri.rawQuery.orEmpty().split('&').filter { it.contains('=') }.associate {
                val parts = it.split('=', limit = 2)
                URLDecoder.decode(parts[0], "UTF-8") to URLDecoder.decode(parts[1], "UTF-8")
            }
            val path = uri.path
            val data = when {
                path.endsWith("/Views") -> JSONObject().put("Items", JSONArray().put(JSONObject().put("Id", "lib1").put("Name", "Movies").put("IsFolder", true).put("Type", "CollectionFolder").put("CollectionType", "movies")))
                path.contains("/FavoriteItems/") -> { mutations.add(request.substringBefore(' ')); JSONObject().put("IsFavorite", request.substringBefore(' ') == "POST") }
                path == "/Genres" || path == "/Tags" -> JSONObject().put("Items", JSONArray().put(JSONObject().put("Id", "facet1").put("Name", if (path == "/Tags") "Tag & A" else "Drama"))).put("TotalRecordCount", 1)
                path.endsWith("/Items/1") -> movies[0]
                else -> {
                    var selected = if (q["Recursive"] == "false") listOf(JSONObject().put("Id", "folder1").put("Name", "Folder").put("Type", "Folder").put("IsFolder", true), movies[0]) else movies
                    if (q["Filters"] == "IsResumable") selected = listOf(movies[0])
                    if (q["Filters"] == "IsFavorite") selected = emptyList()
                    if (q.containsKey("Genres")) selected = selected.filter { it.getJSONArray("Genres").length() > 0 }
                    if (q.containsKey("Tags")) selected = selected.filter { it.getJSONArray("TagItems").length() > 0 }
                    val start = q["StartIndex"]?.toInt() ?: 0
                    val limit = q["Limit"]?.toInt() ?: 48
                    JSONObject().put("Items", JSONArray(selected.drop(start).take(limit))).put("TotalRecordCount", selected.size)
                }
            }
            val bytes = data.toString().toByteArray()
            MediaServerClientTest.Reply(body = bytes)
        }
        try {
            for (provider in listOf("emby", "jellyfin")) {
                val account = MediaServerAccount("profile", "Test", fixture.url, "fake-token", provider, "user1")
                MediaServerHttp(account).use { http ->
                    val client = EmbyClient(account, http)
                    val home = client.home(JSONObject())
                    assertEquals("lib1", home.getString("library_id"))
                    assertEquals(250, home.getInt("total"))
                    assertEquals(4, home.getJSONArray("recent").length())
                    assertEquals(30000L, home.getJSONArray("resume").getJSONObject(0).getLong("position_ms"))
                    assertTrue(home.getJSONObject("capabilities").getBoolean("folders"))
                    val ids = mutableSetOf<String>()
                    for (page in 1..6) {
                        val result = client.browse(JSONObject().put("page", page).put("library_id", "lib1"))
                        val entries = result.getJSONArray("entries").objects()
                        assertEquals(if (page == 6) 10 else 48, entries.size)
                        assertTrue(entries.all { ids.add(it.getString("id")) })
                        assertFalse(result.toString().contains("/private/"))
                    }
                    assertEquals(250, ids.size)
                    val folders = client.browse(JSONObject().put("mode", "folders").put("library_id", "lib1")).getJSONArray("entries")
                    assertTrue(folders.getJSONObject(0).getBoolean("container"))
                    assertFalse(folders.getJSONObject(0).has("uri"))
                    assertFalse(folders.getJSONObject(1).getBoolean("container"))
                    val tags = client.candidates(JSONObject().put("kind", "tags").put("library_id", "lib1"))
                    assertEquals("Tag & A", tags.getJSONArray("entries").getJSONObject(0).getString("id"))
                    assertEquals(53, client.browse(JSONObject().put("tags", JSONArray().put("Tag & A"))).getInt("total"))
                    val absent = client.browse(JSONObject().put("unclassified", "genres").put("page", 2))
                    assertEquals(196, absent.getInt("total")); assertEquals(48, absent.getJSONArray("entries").length())
                    assertFalse(absent.toString().contains("/private/"))
                    assertEquals("103", absent.getJSONArray("entries").getJSONObject(0).getString("id"))
                    val detail = client.detail("1")
                    assertEquals("Tag & A", detail.getJSONArray("tags").getJSONObject(0).getString("name"))
                    assertTrue(client.favorite(JSONObject().put("scene_id", "1").put("favorite", true)).getBoolean("favorite"))
                    assertFalse(client.favorite(JSONObject().put("scene_id", "1").put("favorite", false)).getBoolean("favorite"))
                    assertThrows(MediaServerFailure::class.java) { client.browse(JSONObject().put("parent_id", "../other-user")) }
                    assertThrows(MediaServerFailure::class.java) { client.browse(JSONObject().put("tags", JSONArray().put("ambiguous|tag"))) }
                }
            }
            assertEquals(listOf("POST", "DELETE", "POST", "DELETE"), mutations)
        } finally { fixture.close() }
    }

    @Test fun providersAdvertiseOnlyImplementedCapabilities() {
        val account = MediaServerAccount("profile", "Test", "http://127.0.0.1:1", "")
        MediaServerHttp(account).use { http ->
            val stash = StashClient(account, http).capabilities()
            val xbvr = XbvrClient(account, http).capabilities()
            assertFalse(stash.getBoolean("folders")); assertEquals("local", stash.getString("favorite_scope"))
            assertTrue(stash.getBoolean("tag_match_all")); assertTrue(stash.getBoolean("descendants"))
            assertFalse(xbvr.getBoolean("search")); assertFalse(xbvr.getBoolean("descendants"))
            assertFalse(xbvr.getJSONArray("sorts").objectsOrStrings().contains("duration"))
        }
    }

    @Test fun optionalLiveEmbyReadOnlyPresentation() {
        val base = System.getenv("VRPP_MEDIA_UI_EMBY_URL").orEmpty()
        val username = System.getenv("VRPP_MEDIA_UI_EMBY_USER").orEmpty()
        val password = System.getenv("VRPP_MEDIA_UI_EMBY_PASSWORD").orEmpty()
        assumeTrue(base.isNotBlank() && username.isNotBlank() && password.isNotBlank())
        val anonymous = MediaServerAccount("ui-integration", "Test", base, "", "emby")
        val account = MediaServerHttp(anonymous).use { EmbyClient(anonymous, it).login(username, password) }
        MediaServerHttp(account).use { http ->
            val client = EmbyClient(account, http)
            val home = client.home(JSONObject())
            val library = home.getString("library_id")
            val count = home.getInt("total")
            val ids = mutableSetOf<String>()
            for (page in 1..maxOf(1, (count + 47) / 48)) {
                val result = client.browse(JSONObject().put("page", page).put("library_id", library))
                assertTrue(result.getJSONArray("entries").objects().all { ids.add(it.getString("id")) })
            }
            assertEquals(count, ids.size)
            assertTrue(client.browse(JSONObject().put("mode", "folders").put("library_id", library)).getJSONArray("entries").objects().any { it.getBoolean("container") })
            for (kind in listOf("genres", "tags")) {
                val facets = client.candidates(JSONObject().put("kind", kind).put("library_id", library))
                assertTrue(facets.getInt("total") > 0)
                val name = facets.getJSONArray("entries").getJSONObject(0).getString("id")
                assertTrue(client.browse(JSONObject().put(kind, JSONArray().put(name)).put("library_id", library)).getInt("total") > 0)
                val empty = client.browse(JSONObject().put("unclassified", kind).put("library_id", library))
                assertTrue(empty.getInt("total") in 1 until count)
            }
            println("Live Emby presentation: total=$count; unique=${ids.size}; folders/facets/unclassified verified; no metadata mutations")
        }
    }

    private fun JSONArray.objectsOrStrings(): List<String> = (0 until length()).map { getString(it) }
}
