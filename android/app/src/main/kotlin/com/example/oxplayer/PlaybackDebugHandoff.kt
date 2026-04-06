package com.example.oxplayer

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Queues native playback diagnostics from [InternalPlayerActivity] and forwards
 * them to Flutter debug log through [CHANNEL_PLAYBACK_DEBUG].
 */
object PlaybackDebugHandoff {
    private const val CHANNEL_PLAYBACK_DEBUG = "oxplayer/playback_debug"
    private val lock = Any()

    @Volatile
    private var pending: ArrayList<HashMap<String, String>> = ArrayList()

    fun enqueue(message: String) {
        val msg = message.trim()
        if (msg.isEmpty()) return
        synchronized(lock) {
            pending.add(hashMapOf("message" to msg))
        }
    }

    private fun takeAllPending(): List<HashMap<String, String>> =
        synchronized(lock) {
            val out = pending.toList()
            pending = ArrayList()
            out
        }

    fun flushPendingToFlutter(engine: FlutterEngine?) {
        val e = engine ?: return
        val entries = takeAllPending()
        if (entries.isEmpty()) return
        val channel = MethodChannel(e.dartExecutor.binaryMessenger, CHANNEL_PLAYBACK_DEBUG)
        for (entry in entries) {
            channel.invokeMethod(
                "appendLog",
                entry,
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
}
