package com.example.oxplayer

import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.ProgressBar
import android.widget.Spinner
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.FileProvider
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.ui.PlayerView
import androidx.media3.ui.R as MediaUiR
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * In-app fullscreen playback (Media3 ExoPlayer). SubDL search, embedded/sidecar subtitles, trial mode.
 */
class InternalPlayerActivity : AppCompatActivity() {

    private var player: ExoPlayer? = null
    private lateinit var playerView: PlayerView
    private lateinit var root: View
    private lateinit var trialBar: View
    private lateinit var trialBtnPrevious: Button
    private lateinit var trialBtnConfirm: Button
    private lateinit var trialBtnNext: Button
    private lateinit var trialLoading: ProgressBar

    private lateinit var args: InternalPlaybackArgs
    private lateinit var mainUri: Uri
    private lateinit var trackSelector: DefaultTrackSelector
    private val subdlClient = SubdlApiClient()
    private val languageLoader by lazy { SubdlLanguageListLoader(this) }

    private var trialActive: Boolean = false
    private var trialList: List<SubdlApiClient.SubtitleEntry> = emptyList()
    private var trialIndex: Int = 0
    private var trialStartPositionMs: Long = 0L
    private var baselineTrackParameters: DefaultTrackSelector.Parameters? = null

    /** Session default for the language spinner; intent extras stay stale until the next Flutter launch. */
    private var preferredSubtitleLanguageOverride: String? = null

    /** After a successful PATCH for an initially empty server pref, skip further PATCHes this session. */
    private var preferredSubtitlePersistedThisSession: Boolean = false

    private val trialBarBaseBottomMarginPx: Int by lazy {
        resources.getDimensionPixelSize(R.dimen.internal_player_trial_bar_margin_bottom)
    }

    private val trialBarLiftWhenScrubberVisiblePx: Int by lazy {
        resources.getDimensionPixelSize(R.dimen.internal_player_trial_bar_lift_when_scrubber)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        args = readPlaybackArgsFromIntent()
        title = args.displayTitle

        val streamUrl = intent.getStringExtra(EXTRA_STREAM_URL)?.trim().orEmpty()
        val localPath = intent.getStringExtra(EXTRA_LOCAL_PATH)?.trim().orEmpty()

        mainUri = when {
            streamUrl.isNotEmpty() -> Uri.parse(streamUrl)
            localPath.isNotEmpty() -> {
                val f = File(localPath)
                if (!f.isFile) {
                    android.util.Log.e("OXPlayer", "InternalPlayer: missing file $localPath")
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
                android.util.Log.e("OXPlayer", "InternalPlayer: no url or path")
                finish()
                return
            }
        }

        setContentView(R.layout.activity_internal_player)
        root = findViewById(R.id.internal_player_root)
        playerView = findViewById(R.id.player_view)
        trialBar = findViewById(R.id.trial_subtitle_bar)
        trialBtnPrevious = findViewById(R.id.trial_btn_previous)
        trialBtnConfirm = findViewById(R.id.trial_btn_confirm)
        trialBtnNext = findViewById(R.id.trial_btn_next)
        trialLoading = findViewById(R.id.trial_loading)

        applyRtlFriendlySubtitles()

        trackSelector = DefaultTrackSelector(this)
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                50_000,
                120_000,
                2_500,
                5_000,
            )
            .build()

        val exo = ExoPlayer.Builder(this)
            .setTrackSelector(trackSelector)
            .setLoadControl(loadControl)
            .build()
        player = exo
        playerView.player = exo
        exo.setMediaItem(MediaItem.fromUri(mainUri))
        exo.prepare()
        exo.playWhenReady = true
        exo.addListener(
            object : Player.Listener {
                override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                    android.util.Log.e("OXPlayer", "InternalPlayer playback error", error)
                    finish()
                }
            },
        )

        playerView.findViewById<View>(R.id.oxplayer_subtitle_menu)?.setOnClickListener {
            showMainSubtitleMenu()
        }

        playerView.findViewById<View>(R.id.oxplayer_overflow_menu)?.setOnClickListener {
            showMoreOptionsMenu()
        }

        trialBtnPrevious.setOnClickListener {
            if (trialIndex <= 0) return@setOnClickListener
            trialIndex--
            updateTrialNavEnabled()
            loadTrialSubtitleAtCurrentIndex()
        }
        trialBtnNext.setOnClickListener {
            if (trialIndex >= trialList.size - 1) return@setOnClickListener
            trialIndex++
            updateTrialNavEnabled()
            loadTrialSubtitleAtCurrentIndex()
        }
        trialBtnConfirm.setOnClickListener {
            confirmTrialSubtitle()
        }

        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    if (trialActive) {
                        exitTrialRestoreBaseline()
                    } else {
                        isEnabled = false
                        onBackPressedDispatcher.onBackPressed()
                        isEnabled = true
                    }
                }
            },
        )
    }

    override fun onResume() {
        super.onResume()
        MainActivity.flushUserPreferenceHandoffsIfPossible()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_BACK && trialActive) {
            exitTrialRestoreBaseline()
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    private fun applyRtlFriendlySubtitles() {
        playerView.subtitleView?.apply {
            textAlignment = View.TEXT_ALIGNMENT_VIEW_START
            layoutDirection = View.LAYOUT_DIRECTION_LOCALE
        }
    }

    private fun readPlaybackArgsFromIntent(): InternalPlaybackArgs {
        val displayTitle = intent.getStringExtra(EXTRA_TITLE)?.ifBlank { null } ?: "Video"
        val mediaTitle = intent.getStringExtra(EXTRA_MEDIA_TITLE)?.ifBlank { null } ?: displayTitle
        val year = intent.optionalIntExtra(EXTRA_RELEASE_YEAR)
        val season = intent.optionalIntExtra(EXTRA_SEASON)
        val episode = intent.optionalIntExtra(EXTRA_EPISODE)
        val isSeries = intent.getBooleanExtra(EXTRA_IS_SERIES, false)
        val imdb = intent.getStringExtra(EXTRA_IMDB_ID)?.trim()?.takeIf { it.isNotEmpty() }
        val tmdb = intent.getStringExtra(EXTRA_TMDB_ID)?.trim()?.takeIf { it.isNotEmpty() }
        val key = intent.getStringExtra(EXTRA_SUBDL_API_KEY)?.trim()?.takeIf { it.isNotEmpty() }
        val metaSub = intent.getStringExtra(EXTRA_METADATA_SUBTITLE)?.trim()?.takeIf { it.isNotEmpty() }
        val prefLang =
            intent.getStringExtra(EXTRA_PREFERRED_SUBTITLE_LANGUAGE)?.trim()?.takeIf { it.isNotEmpty() }
        val apiToken = intent.getStringExtra(EXTRA_API_ACCESS_TOKEN)?.trim()?.takeIf { it.isNotEmpty() }
        val apiBase = intent.getStringExtra(EXTRA_API_BASE_URL)?.trim()?.takeIf { it.isNotEmpty() }
        return InternalPlaybackArgs(
            displayTitle = displayTitle,
            mediaTitle = mediaTitle,
            releaseYear = year,
            season = season,
            episode = episode,
            isSeries = isSeries,
            imdbId = imdb,
            tmdbId = tmdb,
            subdlApiKey = key,
            metadataSubtitle = metaSub,
            preferredSubtitleLanguage = prefLang,
            apiAccessToken = apiToken,
            apiBaseUrl = apiBase,
        )
    }

    private fun showMoreOptionsMenu() {
        val options = arrayOf(getString(R.string.internal_player_open_external))
        AlertDialog.Builder(this)
            .setTitle(R.string.internal_player_overflow_menu)
            .setItems(options) { d, which ->
                if (which == 0) {
                    handOffToExternalAndFinish()
                }
                d.dismiss()
            }
            .setNegativeButton(R.string.internal_player_cancel, null)
            .show()
    }

    private fun handOffToExternalAndFinish() {
        val streamUrl = intent.getStringExtra(EXTRA_STREAM_URL)?.trim().orEmpty()
        val localPath = intent.getStringExtra(EXTRA_LOCAL_PATH)?.trim().orEmpty()
        val map = HashMap<String, Any?>()
        if (streamUrl.isNotEmpty()) {
            map["kind"] = "stream"
            map["streamUrl"] = streamUrl
        } else {
            map["kind"] = "local"
            map["localPath"] = localPath
        }
        map["title"] = args.displayTitle
        map["injectTitle"] = args.displayTitle
        map["year"] = args.releaseYear?.toString() ?: ""
        map["mediaTitle"] = args.mediaTitle
        map["displayTitle"] = args.displayTitle
        args.metadataSubtitle?.let { map["subtitle"] = it }
        map["isSeries"] = args.isSeries
        map["mimeType"] = "video/*"
        ExternalPlaybackHandoff.enqueue(map)
        finish()
        startActivity(
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            },
        )
    }

    private fun Intent.optionalIntExtra(key: String): Int? {
        if (!hasExtra(key)) return null
        val v = getIntExtra(key, Int.MIN_VALUE)
        return if (v == Int.MIN_VALUE) null else v
    }

    private fun showMainSubtitleMenu() {
        val p = player ?: return
        val embedded = collectEmbeddedTextTracks(p.currentTracks)
        val items = mutableListOf<String>()
        val actions = mutableListOf<() -> Unit>()

        items.add(getString(R.string.internal_player_turn_off_subtitles))
        actions.add { turnOffAllSubtitles() }

        for (e in embedded) {
            items.add(getString(R.string.internal_player_embedded_track, e.label))
            actions.add { selectEmbeddedTextTrack(e.group, e.trackIndex) }
        }

        if (args.subdlApiKey != null) {
            items.add(getString(R.string.internal_player_search_subtitles))
            actions.add { showSubdlSearchDialog() }
        } else {
            items.add(getString(R.string.internal_player_search_subtitles))
            actions.add {
                Toast.makeText(
                    this,
                    R.string.internal_player_subtitle_search_requires_key,
                    Toast.LENGTH_LONG,
                ).show()
            }
        }

        AlertDialog.Builder(this)
            .setTitle(R.string.internal_player_subtitles)
            .setItems(items.toTypedArray()) { d, which ->
                actions.getOrNull(which)?.invoke()
                d.dismiss()
            }
            .setNegativeButton(R.string.internal_player_cancel, null)
            .show()
    }

    private data class EmbeddedTextTrack(
        val label: String,
        val group: Tracks.Group,
        val trackIndex: Int,
    )

    private fun collectEmbeddedTextTracks(tracks: Tracks): List<EmbeddedTextTrack> {
        val out = ArrayList<EmbeddedTextTrack>()
        for (group in tracks.groups) {
            if (group.type != C.TRACK_TYPE_TEXT) continue
            for (i in 0 until group.length) {
                if (!group.isTrackSupported(i)) continue
                val fmt = group.getTrackFormat(i)
                val lang = fmt.language?.let { " ($it)" }.orEmpty()
                val label = (fmt.label?.ifBlank { null } ?: "text") + lang
                out.add(EmbeddedTextTrack(label, group, i))
            }
        }
        return out
    }

    private fun turnOffAllSubtitles() {
        val p = player ?: return
        val pos = p.currentPosition
        trackSelector.setParameters(
            trackSelector.buildUponParameters()
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
                .clearOverridesOfType(C.TRACK_TYPE_TEXT)
                .build(),
        )
        p.setMediaItem(MediaItem.Builder().setUri(mainUri).build(), false)
        p.seekTo(pos)
        p.prepare()
        p.playWhenReady = true
    }

    private fun selectEmbeddedTextTrack(group: Tracks.Group, trackIndex: Int) {
        val p = player ?: return
        val pos = p.currentPosition
        trackSelector.setParameters(
            trackSelector.buildUponParameters()
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                .clearOverridesOfType(C.TRACK_TYPE_TEXT)
                .addOverride(
                    TrackSelectionOverride(
                        group.mediaTrackGroup,
                        listOf(trackIndex),
                    ),
                )
                .build(),
        )
        p.setMediaItem(MediaItem.Builder().setUri(mainUri).build(), false)
        p.seekTo(pos)
        p.prepare()
        p.playWhenReady = true
    }

    private fun maybePersistPreferredSubtitleLanguageAfterSuccessfulCheck(languageCode: String) {
        if (preferredSubtitlePersistedThisSession) return
        if (!args.preferredSubtitleLanguage.isNullOrBlank()) return
        val token = args.apiAccessToken ?: return
        val base = args.apiBaseUrl ?: return
        lifecycleScope.launch {
            val ok = OxplayerMePreferencesClient.patchPreferredSubtitleLanguage(
                baseUrl = base,
                bearerToken = token,
                languageCode = languageCode,
            )
            if (ok) {
                preferredSubtitlePersistedThisSession = true
                UserPreferenceHandoff.enqueuePreferredSubtitleLanguage(languageCode)
                MainActivity.flushUserPreferenceHandoffsIfPossible()
            }
        }
    }

    private fun showSubdlSearchDialog() {
        val p = player ?: return
        p.pause()
        val view = LayoutInflater.from(this).inflate(R.layout.dialog_subdl_search, null, false)
        val nameEt = view.findViewById<EditText>(R.id.subdl_search_name)
        val langSpinner = view.findViewById<Spinner>(R.id.subdl_search_language)
        val languageLoadingRow = view.findViewById<View>(R.id.subdl_language_loading_row)
        val seasonEt = view.findViewById<EditText>(R.id.subdl_search_season)
        val episodeEt = view.findViewById<EditText>(R.id.subdl_search_episode)
        var langPairs: List<Pair<String, String>> = emptyList()
        var languageCodeUsedForLastSearch = "EN"

        nameEt.setText(args.defaultSearchName())
        args.season?.let { seasonEt.setText(it.toString()) }
        args.episode?.let { episodeEt.setText(it.toString()) }

        var suppressResumeOnSearchDismiss = false
        val dialog = AlertDialog.Builder(this)
            .setTitle(R.string.internal_player_search_title)
            .setView(view)
            .setPositiveButton(R.string.internal_player_check, null)
            .setNegativeButton(R.string.internal_player_cancel) { d, _ ->
                d.dismiss()
                p.playWhenReady = true
            }
            .create()

        fun positiveCheckButton(): Button? =
            dialog.getButton(AlertDialog.BUTTON_POSITIVE)

        fun runSubdlCheck() {
            val key = args.subdlApiKey ?: return
            val filmName = nameEt.text?.toString().orEmpty().trim()
            if (filmName.isEmpty()) {
                Toast.makeText(this, R.string.internal_player_label_name, Toast.LENGTH_SHORT).show()
                return
            }
            val langPos = langSpinner.selectedItemPosition
            val langCode = langPairs.getOrNull(langPos)?.first ?: "EN"
            languageCodeUsedForLastSearch = langCode
            val season = seasonEt.text?.toString()?.trim()?.toIntOrNull()
            val episode = episodeEt.text?.toString()?.trim()?.toIntOrNull()

            positiveCheckButton()?.isEnabled = false
            lifecycleScope.launch {
                val outcome = subdlClient.search(
                    apiKey = key,
                    filmName = filmName,
                    contentType = args.subdlContentType(),
                    languages = langCode,
                    year = args.releaseYear,
                    seasonNumber = season,
                    episodeNumber = episode,
                    imdbId = args.imdbId,
                    tmdbId = args.tmdbId,
                )
                withContext(Dispatchers.Main) {
                    if (dialog.isShowing) {
                        positiveCheckButton()?.isEnabled = true
                    }
                    if (outcome.errorMessage != null) {
                        Toast.makeText(
                            this@InternalPlayerActivity,
                            getString(R.string.internal_player_search_failed, outcome.errorMessage),
                            Toast.LENGTH_LONG,
                        ).show()
                        return@withContext
                    }
                    if (args.preferredSubtitleLanguage.isNullOrBlank()) {
                        preferredSubtitleLanguageOverride = languageCodeUsedForLastSearch
                    }
                    maybePersistPreferredSubtitleLanguageAfterSuccessfulCheck(
                        languageCodeUsedForLastSearch,
                    )
                    suppressResumeOnSearchDismiss = true
                    dialog.dismiss()
                    val n = outcome.subtitles.size
                    val msg = if (n == 0) {
                        getString(R.string.internal_player_found_zero_subtitles)
                    } else {
                        getString(R.string.internal_player_found_n_subtitles, n)
                    }
                    AlertDialog.Builder(this@InternalPlayerActivity)
                        .setMessage(msg)
                        .setPositiveButton(R.string.internal_player_continue) { _, _ ->
                            if (n > 0) {
                                startTrialMode(outcome.subtitles)
                            } else {
                                p.playWhenReady = true
                            }
                        }
                        .setNegativeButton(R.string.internal_player_cancel) { _, _ ->
                            p.playWhenReady = true
                        }
                        .show()
                }
            }
        }

        dialog.setOnShowListener {
            positiveCheckButton()?.apply {
                isEnabled = false
                setOnClickListener { runSubdlCheck() }
            }
        }

        dialog.setOnDismissListener {
            if (!trialActive && !suppressResumeOnSearchDismiss) {
                p.playWhenReady = true
            }
        }

        dialog.show()

        lifecycleScope.launch {
            val langs = try {
                languageLoader.loadSorted()
            } catch (_: Exception) {
                listOf("EN" to "English")
            }
            langPairs = langs
            withContext(Dispatchers.Main) {
                if (!dialog.isShowing) return@withContext
                val labels = langs.map { "${it.second} (${it.first})" }
                val adapter = ArrayAdapter(
                    this@InternalPlayerActivity,
                    android.R.layout.simple_spinner_item,
                    labels,
                )
                adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
                langSpinner.adapter = adapter
                val preferred =
                    (preferredSubtitleLanguageOverride ?: args.preferredSubtitleLanguage)?.uppercase()
                val preferredIdx = if (!preferred.isNullOrEmpty()) {
                    langs.indexOfFirst { it.first.equals(preferred, ignoreCase = true) }
                } else {
                    -1
                }
                val defaultIdx = when {
                    preferredIdx >= 0 -> preferredIdx
                    else -> langs.indexOfFirst { it.first == "EN" }.takeIf { it >= 0 } ?: 0
                }
                langSpinner.setSelection(defaultIdx)
                languageLoadingRow.visibility = View.GONE
                langSpinner.visibility = View.VISIBLE
                positiveCheckButton()?.isEnabled = true
            }
        }
    }

    private fun startTrialMode(entries: List<SubdlApiClient.SubtitleEntry>) {
        val p = player ?: return
        baselineTrackParameters = trackSelector.parameters
        trialStartPositionMs = p.currentPosition
        trialActive = true
        trialList = entries
        trialIndex = 0
        applyTrialModeScrubberOnlyControllerUi()
        trialBar.visibility = View.VISIBLE
        updateTrialNavEnabled()
        p.playWhenReady = true
        loadTrialSubtitleAtCurrentIndex()
    }

    /**
     * Keep the default tap-to-show time bar, but hide all other controller chrome (play, menus, etc.).
     */
    private fun applyTrialModeScrubberOnlyControllerUi() {
        playerView.useController = true
        hideTrialNonScrubberControllerViews()
        playerView.setControllerVisibilityListener(
            object : PlayerView.ControllerVisibilityListener {
                override fun onVisibilityChanged(visibility: Int) {
                    updateTrialBarBottomMarginForScrubber(visibility == View.VISIBLE)
                }
            },
        )
        updateTrialBarBottomMarginForScrubber(false)
        playerView.hideController()
    }

    private fun updateTrialBarBottomMarginForScrubber(scrubberChromeVisible: Boolean) {
        val lp = trialBar.layoutParams as FrameLayout.LayoutParams
        lp.bottomMargin =
            trialBarBaseBottomMarginPx +
            if (scrubberChromeVisible) trialBarLiftWhenScrubberVisiblePx else 0
        trialBar.layoutParams = lp
    }

    private fun hideTrialNonScrubberControllerViews() {
        val ids = intArrayOf(
            MediaUiR.id.exo_bottom_bar,
            MediaUiR.id.exo_center_controls,
            MediaUiR.id.exo_minimal_controls,
            R.id.oxplayer_subtitle_menu,
            R.id.oxplayer_overflow_menu,
        )
        for (id in ids) {
            playerView.findViewById<View>(id)?.visibility = View.GONE
        }
    }

    private fun restoreFullControllerChrome() {
        val ids = intArrayOf(
            MediaUiR.id.exo_bottom_bar,
            MediaUiR.id.exo_center_controls,
            MediaUiR.id.exo_minimal_controls,
            R.id.oxplayer_subtitle_menu,
            R.id.oxplayer_overflow_menu,
        )
        for (id in ids) {
            playerView.findViewById<View>(id)?.visibility = View.VISIBLE
        }
    }

    private fun restoreNormalPlaybackControllerUi() {
        playerView.setControllerVisibilityListener(null as PlayerView.ControllerVisibilityListener?)
        updateTrialBarBottomMarginForScrubber(false)
        restoreFullControllerChrome()
        playerView.useController = true
    }

    private fun updateTrialNavEnabled() {
        trialBtnPrevious.isEnabled = trialIndex > 0
        trialBtnNext.isEnabled = trialIndex < trialList.size - 1
    }

    private fun loadTrialSubtitleAtCurrentIndex() {
        val p = player ?: return
        val entry = trialList.getOrNull(trialIndex) ?: return
        trialLoading.visibility = View.VISIBLE
        trialBtnPrevious.isEnabled = false
        trialBtnNext.isEnabled = false
        trialBtnConfirm.isEnabled = false

        lifecycleScope.launch {
            val extracted = withContext(Dispatchers.IO) {
                try {
                    val workDir = File(cacheDir, "subtitles/trial_${System.currentTimeMillis()}")
                    workDir.mkdirs()
                    val zipFile = File(workDir, "sub.zip")
                    subdlClient.downloadZipToFile(entry.rawDownload, zipFile)
                    SubtitleZipExtractor.extractBest(zipFile, workDir)
                } catch (_: Exception) {
                    null
                }
            }
            trialLoading.visibility = View.GONE
            trialBtnConfirm.isEnabled = true
            updateTrialNavEnabled()
            if (extracted != null) {
                applyExternalSubtitleFile(extracted.file, extracted.mimeType)
            } else {
                Toast.makeText(
                    this@InternalPlayerActivity,
                    R.string.internal_player_subtitle_apply_failed,
                    Toast.LENGTH_LONG,
                ).show()
            }
        }
    }

    private fun applyExternalSubtitleFile(subFile: File, mimeType: String) {
        val p = player ?: return
        val pos = p.currentPosition
        val subUri = FileProvider.getUriForFile(
            this,
            "${packageName}.fileprovider",
            subFile,
        )
        val subConfig = MediaItem.SubtitleConfiguration.Builder(subUri)
            .setMimeType(mimeType)
            .setLanguage("und")
            .setSelectionFlags(C.SELECTION_FLAG_DEFAULT)
            .build()
        trackSelector.setParameters(
            trackSelector.buildUponParameters()
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                .clearOverridesOfType(C.TRACK_TYPE_TEXT)
                .build(),
        )
        val item = MediaItem.Builder()
            .setUri(mainUri)
            .setSubtitleConfigurations(listOf(subConfig))
            .build()
        p.setMediaItem(item, false)
        p.seekTo(pos)
        p.prepare()
        p.playWhenReady = true
        applyRtlFriendlySubtitles()
    }

    private fun confirmTrialSubtitle() {
        trialActive = false
        trialList = emptyList()
        trialBar.visibility = View.GONE
        trialLoading.visibility = View.GONE
        restoreNormalPlaybackControllerUi()
        playerView.hideController()
        baselineTrackParameters = trackSelector.parameters
    }

    private fun exitTrialRestoreBaseline() {
        val p = player ?: return
        trialActive = false
        trialList = emptyList()
        trialBar.visibility = View.GONE
        trialLoading.visibility = View.GONE
        restoreNormalPlaybackControllerUi()
        playerView.hideController()
        val base = baselineTrackParameters
        val pos = trialStartPositionMs
        if (base != null) {
            trackSelector.setParameters(base)
        }
        p.setMediaItem(MediaItem.Builder().setUri(mainUri).build(), false)
        p.seekTo(pos)
        p.prepare()
        p.playWhenReady = true
    }

    override fun onStop() {
        super.onStop()
        player?.pause()
    }

    override fun onDestroy() {
        playerView.player = null
        player?.release()
        player = null
        super.onDestroy()
    }

    data class InternalPlaybackArgs(
        val displayTitle: String,
        val mediaTitle: String,
        val releaseYear: Int?,
        val season: Int?,
        val episode: Int?,
        val isSeries: Boolean,
        val imdbId: String?,
        val tmdbId: String?,
        val subdlApiKey: String?,
        /** Season/episode line for [ExternalPlayer.injectMetadata] when opening externally. */
        val metadataSubtitle: String?,
        /** SubDL language code; default selection in search dialog. */
        val preferredSubtitleLanguage: String?,
        val apiAccessToken: String?,
        val apiBaseUrl: String?,
    ) {
        fun defaultSearchName(): String = mediaTitle.ifBlank { displayTitle }

        fun subdlContentType(): String = if (isSeries) "tv" else "movie"
    }

    companion object {
        const val EXTRA_STREAM_URL = "stream_url"
        const val EXTRA_LOCAL_PATH = "local_path"
        const val EXTRA_TITLE = "title"
        const val EXTRA_MEDIA_TITLE = "media_title"
        const val EXTRA_RELEASE_YEAR = "release_year"
        const val EXTRA_SEASON = "season"
        const val EXTRA_EPISODE = "episode"
        const val EXTRA_IS_SERIES = "is_series"
        const val EXTRA_IMDB_ID = "imdb_id"
        const val EXTRA_TMDB_ID = "tmdb_id"
        const val EXTRA_SUBDL_API_KEY = "subdl_api_key"
        const val EXTRA_METADATA_SUBTITLE = "metadata_subtitle"
        const val EXTRA_PREFERRED_SUBTITLE_LANGUAGE = "preferred_subtitle_language"
        const val EXTRA_API_ACCESS_TOKEN = "api_access_token"
        const val EXTRA_API_BASE_URL = "api_base_url"
    }
}
