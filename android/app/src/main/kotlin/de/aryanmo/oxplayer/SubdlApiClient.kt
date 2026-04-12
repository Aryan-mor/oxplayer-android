package de.aryanmo.oxplayer

import android.content.Context
import android.util.Log
import kotlin.math.min
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

class SubdlApiClient(
    private val okHttpClient: OkHttpClient = defaultClient(),
) {

    data class SubtitleEntry(
        val displayLabel: String,
        val rawDownload: String,
        val languageCode: String?,
    )

    data class SearchOutcome(
        val subtitles: List<SubtitleEntry>,
        val errorMessage: String?,
    )

    fun search(
        apiKey: String,
        filmName: String,
        contentType: String,
        languages: String,
        year: Int?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        imdbId: String?,
        tmdbId: String?,
    ): SearchOutcome {
        val base = API_BASE.toHttpUrlOrNull() ?: return SearchOutcome(
            emptyList(),
            "Invalid API base URL.",
        )
        val builder = base.newBuilder()
            .addQueryParameter("api_key", apiKey)
            .addQueryParameter("subs_per_page", "30")

        val trimmedName = filmName.trim()
        if (trimmedName.isNotEmpty()) {
            builder.addQueryParameter("film_name", trimmedName)
        }
        builder.addQueryParameter("type", contentType)
        if (languages.isNotBlank()) {
            builder.addQueryParameter("languages", languages.trim())
        }
        year?.let { builder.addQueryParameter("year", it.toString()) }
        seasonNumber?.let { builder.addQueryParameter("season_number", it.toString()) }
        episodeNumber?.let { builder.addQueryParameter("episode_number", it.toString()) }
        normalizeImdb(imdbId)?.let { builder.addQueryParameter("imdb_id", it) }
        tmdbId?.trim()?.takeIf { it.isNotEmpty() }?.let { builder.addQueryParameter("tmdb_id", it) }

        val builtUrl = builder.build()
        val redactedUrl = builtUrl.toString().replace(Regex("api_key=[^&]+"), "api_key=***")
        Log.i(TAG, "SubDL GET $redactedUrl")
        Log.i(
            TAG,
            "SubDL query: film_name=$trimmedName type=$contentType languages=$languages year=$year " +
                "season_number=$seasonNumber episode_number=$episodeNumber imdb_id=${normalizeImdb(imdbId)} tmdb_id=${tmdbId?.trim()}",
        )

        val request = Request.Builder().url(builtUrl).get().build()
        return try {
            okHttpClient.newCall(request).execute().use { response ->
                val body = response.body?.string().orEmpty()
                if (!response.isSuccessful) {
                    Log.w(TAG, "SubDL HTTP ${response.code} bodyHead=${body.take(200)}")
                    return SearchOutcome(emptyList(), "HTTP ${response.code}: ${response.message}")
                }
                val root = JSONObject(body)
                val ok = root.optBoolean("status", false)
                if (!ok) {
                    val err = root.optString("error").ifBlank { "Search failed." }
                    Log.w(TAG, "SubDL status=false error=$err")
                    return SearchOutcome(emptyList(), err)
                }
                val resultsArr = root.optJSONArray("results")
                if (resultsArr != null && resultsArr.length() > 0) {
                    val parts = ArrayList<String>(min(4, resultsArr.length()))
                    for (i in 0 until min(4, resultsArr.length())) {
                        val o = resultsArr.optJSONObject(i) ?: continue
                        parts.add(
                            "name=${o.optString("name")} year=${o.optString("year")} type=${o.optString("type")} sd_id=${o.optString("sd_id")}",
                        )
                    }
                    Log.i(TAG, "SubDL results(${resultsArr.length()}): ${parts.joinToString(" | ")}")
                } else {
                    Log.i(TAG, "SubDL results: none (subtitles are tied to film_name match only)")
                }
                val subtitles = root.optJSONArray("subtitles") ?: return SearchOutcome(emptyList(), null)
                Log.i(TAG, "SubDL subtitles count=${subtitles.length()}")
                for (i in 0 until min(12, subtitles.length())) {
                    val item = subtitles.optJSONObject(i) ?: continue
                    Log.i(
                        TAG,
                        "  [$i] release=${item.optString("release_name")} ep=${item.opt("episode")} " +
                            "season=${item.opt("season")} lang=${item.optString("lang")}",
                    )
                }
                val out = ArrayList<SubtitleEntry>(subtitles.length())
                for (index in 0 until subtitles.length()) {
                    val item = subtitles.optJSONObject(index) ?: continue
                    val entry = subtitleEntryFromJson(item) ?: continue
                    out.add(entry)
                }
                SearchOutcome(out, null)
            }
        } catch (error: Exception) {
            Log.e(TAG, "SubDL search exception", error)
            SearchOutcome(emptyList(), error.message ?: "Network error.")
        }
    }

    fun downloadZipToFile(
        rawDownload: String,
        destinationZip: File,
    ) {
        val url = SubdlDownloadUrls.httpUrlFor(rawDownload)
        val request = Request.Builder().url(url).get().build()
        okHttpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw java.io.IOException("Download failed: HTTP ${response.code}")
            }
            val body = response.body ?: throw java.io.IOException("Empty body.")
            destinationZip.parentFile?.mkdirs()
            body.byteStream().use { input ->
                destinationZip.outputStream().use { output -> input.copyTo(output) }
            }
        }
    }

    companion object {
        private const val TAG = "SubdlApiClient"
        private const val API_BASE = "https://api.subdl.com/api/v1/subtitles"

        private fun defaultClient(): OkHttpClient =
            OkHttpClient.Builder()
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(60, TimeUnit.SECONDS)
                .writeTimeout(60, TimeUnit.SECONDS)
                .build()

        private fun normalizeImdb(raw: String?): String? {
            val value = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            return value.removePrefix("tt").removePrefix("TT")
        }

        private fun subtitleEntryFromJson(json: JSONObject): SubtitleEntry? {
            val release = json.optString("release_name").trim()
            val name = json.optString("name").trim()
            val language = json.optString("lang").trim()
            val label = when {
                release.isNotEmpty() && language.isNotEmpty() -> "$release · $language"
                release.isNotEmpty() -> release
                name.isNotEmpty() && language.isNotEmpty() -> "$name · $language"
                name.isNotEmpty() -> name
                language.isNotEmpty() -> language
                else -> "Subtitle"
            }
            val rawDownload = json.optString("download_link").ifBlank {
                json.optString("url").ifBlank {
                    json.optString("zip").ifBlank { json.optString("link") }
                }
            }.trim()
            if (rawDownload.isEmpty()) {
                return null
            }
            return SubtitleEntry(
                displayLabel = label,
                rawDownload = rawDownload,
                languageCode = language.ifEmpty { null },
            )
        }
    }
}

object SubdlDownloadUrls {
    fun httpUrlFor(raw: String): String {
        val value = raw.trim()
        if (value.startsWith("http://", ignoreCase = true) ||
            value.startsWith("https://", ignoreCase = true)
        ) {
            return value
        }
        if (value.startsWith('/')) {
            return "https://dl.subdl.com$value"
        }
        return "https://dl.subdl.com/subtitle/$value"
    }
}

class SubdlLanguageListLoader(
    private val context: Context,
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build(),
) {
    suspend fun loadSorted(): List<Pair<String, String>> = withContext(Dispatchers.IO) {
        val cached = FileCache.languageFile(context)
        try {
            val request = Request.Builder()
                .url(LANGUAGE_LIST_URL)
                .get()
                .build()
            client.newCall(request).execute().use { response ->
                if (response.isSuccessful) {
                    val bytes = response.body?.bytes()
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

        return@withContext listOf("EN" to "English")
    }

    private fun parseJsonToPairs(json: String): List<Pair<String, String>> {
        val root = JSONObject(json)
        val keys = root.keys().asSequence().toList().sorted()
        return keys.map { key -> key to root.optString(key, key) }
    }

    private object FileCache {
        fun languageFile(context: Context) = File(context.filesDir, "subdl_language_list_cache.json")
    }

    companion object {
        private const val LANGUAGE_LIST_URL = "https://subdl.com/api-files/language_list.json"
    }
}