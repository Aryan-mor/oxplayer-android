package de.aryanmo.oxplayer

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * PATCH [/me/preferences] (preferred subtitle language).
 */
object OxplayerMePreferencesClient {

    private val jsonMedia = "application/json; charset=utf-8".toMediaType()

    private val client: OkHttpClient =
        OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(20, TimeUnit.SECONDS)
            .build()

    suspend fun patchPreferredSubtitleLanguage(
        baseUrl: String,
        bearerToken: String,
        languageCode: String,
    ): Boolean = withContext(Dispatchers.IO) {
        val root = baseUrl.trimEnd('/')
        val body = JSONObject()
            .put("preferredSubtitleLanguage", languageCode.trim())
            .toString()
            .toRequestBody(jsonMedia)
        val req = Request.Builder()
            .url("$root/me/preferences")
            .patch(body)
            .header("Authorization", "Bearer ${bearerToken.trim()}")
            .build()
        try {
            client.newCall(req).execute().use { it.isSuccessful }
        } catch (_: Exception) {
            false
        }
    }
}
