package de.aryanmo.oxplayer

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * SubDL search API (https://subdl.com/api-doc) and subtitle ZIP download.
 */
class SubdlApiClient(
    private val okHttpClient: OkHttpClient = defaultClient(),
) {

    data class SubtitleEntry(
        val displayLabel: String,
        /** Relative path, full https URL, or zip file name — passed to [downloadZipToFile]. */
        val rawDownload: String,
    )

    data class SearchOutcome(
        val subtitles: List<SubtitleEntry>,
        val errorMessage: String?,
    )

    suspend fun search(
        apiKey: String,
        filmName: String,
        contentType: String,
        languages: String,
        year: Int?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        imdbId: String?,
        tmdbId: String?,
    ): SearchOutcome = withContext(Dispatchers.IO) {
        val base = API_BASE.toHttpUrlOrNull() ?: return@withContext SearchOutcome(
            emptyList(),
            "Invalid API base URL.",
        )
        val b = base.newBuilder()
            .addQueryParameter("api_key", apiKey)
            .addQueryParameter("subs_per_page", "30")
        val trimmedName = filmName.trim()
        if (trimmedName.isNotEmpty()) {
            b.addQueryParameter("film_name", trimmedName)
        }
        b.addQueryParameter("type", contentType)
        if (languages.isNotBlank()) {
            b.addQueryParameter("languages", languages.trim())
        }
        year?.let { b.addQueryParameter("year", it.toString()) }
        seasonNumber?.let { b.addQueryParameter("season_number", it.toString()) }
        episodeNumber?.let { b.addQueryParameter("episode_number", it.toString()) }
        normalizeImdb(imdbId)?.let { b.addQueryParameter("imdb_id", it) }
        tmdbId?.trim()?.takeIf { it.isNotEmpty() }?.let { b.addQueryParameter("tmdb_id", it) }

        val req = Request.Builder().url(b.build()).get().build()
        try {
            okHttpClient.newCall(req).execute().use { resp ->
                val body = resp.body?.string().orEmpty()
                if (!resp.isSuccessful) {
                    return@withContext SearchOutcome(
                        emptyList(),
                        "HTTP ${resp.code}: ${resp.message}",
                    )
                }
                val root = JSONObject(body)
                val ok = root.optBoolean("status", false)
                if (!ok) {
                    val err = root.optString("error").ifBlank { "Search failed." }
                    return@withContext SearchOutcome(emptyList(), err)
                }
                val arr = root.optJSONArray("subtitles") ?: return@withContext SearchOutcome(
                    emptyList(),
                    null,
                )
                val out = ArrayList<SubtitleEntry>(arr.length())
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    val entry = subtitleEntryFromJson(o) ?: continue
                    out.add(entry)
                }
                SearchOutcome(out, null)
            }
        } catch (e: Exception) {
            SearchOutcome(emptyList(), e.message ?: "Network error.")
        }
    }

    suspend fun downloadZipToFile(
        rawDownload: String,
        destinationZip: java.io.File,
    ): Unit = withContext(Dispatchers.IO) {
        val url = SubdlDownloadUrls.httpUrlFor(rawDownload)
        val req = Request.Builder().url(url).get().build()
        okHttpClient.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) {
                throw java.io.IOException("Download failed: HTTP ${resp.code}")
            }
            val body = resp.body ?: throw java.io.IOException("Empty body.")
            destinationZip.parentFile?.mkdirs()
            body.byteStream().use { input ->
                destinationZip.outputStream().use { output -> input.copyTo(output) }
            }
        }
    }

    companion object {
        private const val API_BASE = "https://api.subdl.com/api/v1/subtitles"

        private fun defaultClient(): OkHttpClient =
            OkHttpClient.Builder()
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(60, TimeUnit.SECONDS)
                .writeTimeout(60, TimeUnit.SECONDS)
                .build()

        private fun normalizeImdb(raw: String?): String? {
            val s = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            return s.removePrefix("tt").removePrefix("TT")
        }

        private fun subtitleEntryFromJson(o: JSONObject): SubtitleEntry? {
            val release = o.optString("release_name").trim()
            val name = o.optString("name").trim()
            val lang = o.optString("lang").trim()
            val label = when {
                release.isNotEmpty() && lang.isNotEmpty() -> "$release · $lang"
                release.isNotEmpty() -> release
                name.isNotEmpty() && lang.isNotEmpty() -> "$name · $lang"
                name.isNotEmpty() -> name
                lang.isNotEmpty() -> lang
                else -> "Subtitle"
            }
            val raw = o.optString("download_link").ifBlank {
                o.optString("url").ifBlank {
                    o.optString("zip").ifBlank { o.optString("link") }
                }
            }.trim()
            if (raw.isEmpty()) return null
            return SubtitleEntry(label, raw)
        }
    }
}

object SubdlDownloadUrls {
    fun httpUrlFor(raw: String): String {
        val s = raw.trim()
        if (s.startsWith("http://", ignoreCase = true) ||
            s.startsWith("https://", ignoreCase = true)
        ) {
            return s
        }
        if (s.startsWith("/")) {
            return "https://dl.subdl.com$s"
        }
        return "https://dl.subdl.com/subtitle/$s"
    }
}

/**
 * Loads SubDL language codes for the search dialog (network with raw-resource fallback).
 */
class SubdlLanguageListLoader(
    private val context: Context,
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build(),
) {
    /** Pairs of (apiCode, displayLabel). */
    suspend fun loadSorted(): List<Pair<String, String>> = withContext(Dispatchers.IO) {
        val cached = FileCache.languageFile(context)
        try {
            val req = Request.Builder()
                .url(LANGUAGE_LIST_URL)
                .get()
                .build()
            client.newCall(req).execute().use { resp ->
                if (resp.isSuccessful) {
                    val bytes = resp.body?.bytes()
                    if (bytes != null && bytes.isNotEmpty()) {
                        cached.parentFile?.mkdirs()
                        cached.writeBytes(bytes)
                        return@withContext parseJsonToPairs(String(bytes, Charsets.UTF_8))
                    }
                }
            }
        } catch (_: Exception) {
        }
        if (cached.isFile) {
            return@withContext parseJsonToPairs(cached.readText())
        }
        return@withContext parseJsonToPairs(readRawFallback())
    }

    private fun readRawFallback(): String =
        context.resources.openRawResource(R.raw.subdl_language_list)
            .bufferedReader(Charsets.UTF_8)
            .use { it.readText() }

    private fun parseJsonToPairs(json: String): List<Pair<String, String>> {
        val root = JSONObject(json)
        val keys = root.keys().asSequence().toList().sorted()
        return keys.map { k -> k to root.optString(k, k) }
    }

    private object FileCache {
        fun languageFile(ctx: Context) = File(ctx.filesDir, "subdl_language_list_cache.json")
    }

    companion object {
        private const val LANGUAGE_LIST_URL = "https://subdl.com/api-files/language_list.json"
    }
}
