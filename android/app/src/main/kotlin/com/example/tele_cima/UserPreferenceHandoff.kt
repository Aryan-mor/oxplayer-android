package com.example.tele_cima

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * After PATCH /me/preferences from [InternalPlayerActivity], Flutter updates [AuthNotifier].
 */
object UserPreferenceHandoff {
    private const val CHANNEL_USER_PREFS = "telecima/user_prefs"
    private val lock = Any()

    @Volatile
    private var pendingLanguageCode: String? = null

    fun enqueuePreferredSubtitleLanguage(code: String) {
        val trimmed = code.trim()
        if (trimmed.isEmpty()) return
        synchronized(lock) {
            pendingLanguageCode = trimmed
        }
    }

    fun takePendingPreferredSubtitleLanguage(): String? =
        synchronized(lock) {
            val c = pendingLanguageCode
            pendingLanguageCode = null
            c
        }

    fun flushPendingToFlutter(engine: FlutterEngine?) {
        val code = takePendingPreferredSubtitleLanguage() ?: return
        val e = engine ?: return
        MethodChannel(e.dartExecutor.binaryMessenger, CHANNEL_USER_PREFS).invokeMethod(
            "setPreferredSubtitleLanguage",
            mapOf("preferredSubtitleLanguage" to code),
            object : MethodChannel.Result {
                override fun success(result: Any?) {}

                override fun error(
                    errorCode: String,
                    errorMessage: String?,
                    errorDetails: Any?,
                ) {
                }

                override fun notImplemented() {}
            },
        )
    }
}
