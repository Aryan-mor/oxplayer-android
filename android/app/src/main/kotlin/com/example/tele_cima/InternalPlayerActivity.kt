package com.example.tele_cima

import android.net.Uri
import android.os.Bundle
import android.view.WindowManager
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.FileProvider
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import java.io.File

/**
 * In-app fullscreen playback (Media3 ExoPlayer). Fed by localhost stream URL or FileProvider URI.
 */
class InternalPlayerActivity : AppCompatActivity() {

    private var player: ExoPlayer? = null
    private var playerView: PlayerView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val titleExtra = intent.getStringExtra(EXTRA_TITLE)?.ifBlank { null } ?: "Video"
        title = titleExtra

        val streamUrl = intent.getStringExtra(EXTRA_STREAM_URL)?.trim().orEmpty()
        val localPath = intent.getStringExtra(EXTRA_LOCAL_PATH)?.trim().orEmpty()

        val uri: Uri = when {
            streamUrl.isNotEmpty() -> Uri.parse(streamUrl)
            localPath.isNotEmpty() -> {
                val f = File(localPath)
                if (!f.isFile) {
                    android.util.Log.e("TeleCima", "InternalPlayer: missing file $localPath")
                    finish()
                    return
                }
                FileProvider.getUriForFile(
                    this,
                    "${packageName}.fileprovider",
                    f,
                )
            }
            else -> {
                android.util.Log.e("TeleCima", "InternalPlayer: no url or path")
                finish()
                return
            }
        }

        val view = PlayerView(this)
        playerView = view
        setContentView(view)

        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                50_000,
                120_000,
                2_500,
                5_000,
            )
            .build()

        val exo = ExoPlayer.Builder(this)
            .setLoadControl(loadControl)
            .build()
        player = exo
        view.player = exo
        exo.setMediaItem(MediaItem.fromUri(uri))
        exo.prepare()
        exo.playWhenReady = true
        exo.addListener(
            object : Player.Listener {
                override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                    android.util.Log.e("TeleCima", "InternalPlayer playback error", error)
                    finish()
                }
            },
        )
    }

    override fun onStop() {
        super.onStop()
        player?.pause()
    }

    override fun onDestroy() {
        playerView?.player = null
        player?.release()
        player = null
        playerView = null
        super.onDestroy()
    }

    companion object {
        const val EXTRA_STREAM_URL = "stream_url"
        const val EXTRA_LOCAL_PATH = "local_path"
        const val EXTRA_TITLE = "title"
    }
}
