package de.aryanmo.oxplayer

/**
 * Queued by [InternalPlayerActivity] when the user chooses external playback.
 * [MainActivity] flushes this to Flutter over [CHANNEL_PLAYBACK_HANDOFF].
 */
object ExternalPlaybackHandoff {
    private val lock = Any()

    @Volatile
    private var payload: HashMap<String, Any?>? = null

    fun enqueue(map: HashMap<String, Any?>) {
        synchronized(lock) {
            payload = map
        }
    }

    fun takePending(): HashMap<String, Any?>? =
        synchronized(lock) {
            val p = payload
            payload = null
            p
        }
}
