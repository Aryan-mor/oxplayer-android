package de.aryanmo.oxplayer

import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.app.AppOpsManager
import android.app.PictureInPictureParams
import android.content.Context
import android.content.res.Configuration
import android.util.Log
import android.util.Rational
import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ProgressBar
import android.widget.Spinner
import android.widget.Toast
import androidx.core.content.FileProvider
import androidx.lifecycle.lifecycleScope
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import de.aryanmo.oxplayer.exoplayer.ExoPlayerPlugin
import de.aryanmo.oxplayer.mpv.MpvPlayerPlugin
import de.aryanmo.oxplayer.shared.ThemeHelper
import de.aryanmo.oxplayer.watchnext.WatchNextPlugin
import java.io.File
import java.io.FileOutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Flutter may send Dart [int] as [Long] on the platform channel; [MethodCall.argument]<Int> returns null. */
private fun MethodCall.optionalInt(key: String): Int? {
    val raw = argument<Any>(key) ?: return null
    return when (raw) {
        is Int -> raw
        is Long -> raw.toInt()
        is Short -> raw.toInt()
        is Byte -> raw.toInt()
        is Double -> raw.toInt()
        is Float -> raw.toInt()
        is Number -> raw.toInt()
        else -> null
    }
}

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "MainActivity"
        var usingSkia = false

        init {
            try {
                System.loadLibrary("tdjson")
            } catch (_: UnsatisfiedLinkError) {
                // Dart TDLib init will surface a clearer runtime error if jniLibs are missing.
            }
        }
    }

    private val PIP_CHANNEL = "com.plezy/pip"
    private val EXTERNAL_PLAYER_CHANNEL = "com.plezy/external_player"
    private val THEME_CHANNEL = "com.plezy/theme"
    private val MEDIA_TOOLS_CHANNEL = "de.aryanmo.oxplayer/media_tools"
    private val UPDATE_CHANNEL = "de.aryanmo.oxplayer/update"
    private val subdlClient = SubdlApiClient()
    private var watchNextPlugin: WatchNextPlugin? = null
    private lateinit var mainFlutterMessenger: BinaryMessenger

    // Auto PiP state
    private var autoPipReady = false
    private var autoPipWidth: Int = 16
    private var autoPipHeight: Int = 9

    override fun onCreate(savedInstanceState: Bundle?) {
        // Apply persisted theme color to the window background before anything
        // else renders.  This prevents a white flash between the native splash
        // screen and Flutter's first frame for non-default themes (e.g. OLED).
        val prefs = getSharedPreferences("plezy_prefs", Context.MODE_PRIVATE)
        val savedTheme = prefs.getString("splash_theme", null)
        ThemeHelper.themeColor(savedTheme)?.let { window.decorView.setBackgroundColor(it) }

        super.onCreate(savedInstanceState)

        // Disable the Android splash screen fade-out animation to avoid
        // a flicker before Flutter draws its first frame.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            splashScreen.setOnExitAnimationListener { splashScreenView -> splashScreenView.remove() }
        }

        // Disable Android's default focus highlight ring that appears when using
        // D-pad navigation so the Flutter UI can render its own focus state.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            window.decorView.defaultFocusHighlightEnabled = false
        }

        // Wrap the content view in a layout that intercepts DPAD key events
        // before the IME input stage, which can consume DPAD direction events
        // from virtual remotes before they reach Flutter's key handler.
        val content = findViewById<ViewGroup>(android.R.id.content)
        val wrapper = object : FrameLayout(this) {
            override fun dispatchKeyEventPreIme(event: KeyEvent): Boolean {
                when (event.keyCode) {
                    KeyEvent.KEYCODE_DPAD_UP,
                    KeyEvent.KEYCODE_DPAD_DOWN,
                    KeyEvent.KEYCODE_DPAD_LEFT,
                    KeyEvent.KEYCODE_DPAD_RIGHT,
                    KeyEvent.KEYCODE_DPAD_CENTER -> {
                        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                        if (!imm.isAcceptingText) {
                            super.dispatchKeyEvent(event)
                            return true
                        }
                    }
                }
                return super.dispatchKeyEventPreIme(event)
            }
        }
        while (content.childCount > 0) {
            val child = content.getChildAt(0)
            content.removeViewAt(0)
            wrapper.addView(child)
        }
        content.addView(wrapper, ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT))

        // Handle Watch Next deep link from initial launch
        handleWatchNextIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Handle Watch Next deep link when app is already running
        handleWatchNextIntent(intent)
    }

    private fun handleWatchNextIntent(intent: Intent?) {
        val contentId = WatchNextPlugin.handleIntent(intent)
        if (contentId != null) {
            // Notify the plugin to send event to Flutter
            watchNextPlugin?.notifyDeepLink(contentId)
        }
    }

    override fun getFlutterShellArgs(): FlutterShellArgs {
        val args = super.getFlutterShellArgs()
        usingSkia = shouldDisableImpeller()
        if (usingSkia) args.add("--enable-impeller=false")
        return args
    }

    private fun shouldDisableImpeller(): Boolean {
        // Android TV devices — weaker GPUs, less Impeller testing
        if (packageManager.hasSystemFeature("android.software.leanback")) return true
        // Google Tensor SoC (Mali GPU) — Pixel 6+
        // SOC_MODEL may return marketing name ("Tensor G2") or internal ID ("GS201")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val soc = Build.SOC_MODEL
            if (soc.startsWith("Tensor", ignoreCase = true) ||
                soc.startsWith("GS", ignoreCase = true)) return true
        }
        // NVIDIA Tegra (Shield TV)
        if (Build.MANUFACTURER.equals("NVIDIA", ignoreCase = true)) return true
        // Huawei/HONOR Kirin SoCs use Mali GPUs
        if (Build.MANUFACTURER.equals("Huawei", ignoreCase = true) ||
            Build.MANUFACTURER.equals("HONOR", ignoreCase = true)) return true
        return false
    }

    override fun getRenderMode(): RenderMode {
        // Use TextureView so Flutter doesn't occupy a SurfaceView layer.
        // This allows the libass subtitle SurfaceView to sit between video and Flutter UI.
        return RenderMode.texture
    }

    override fun getTransparencyMode(): TransparencyMode {
        // Keep Flutter transparent so video/subtitles are visible below.
        return TransparencyMode.transparent
    }

    override fun onFlutterTextureViewCreated(flutterTextureView: FlutterTextureView) {
        val original = flutterTextureView.surfaceTextureListener ?: return
        val handler = Handler(Looper.getMainLooper())
        var pendingResize: Runnable? = null
        var lastWidth = 0
        var lastHeight = 0

        flutterTextureView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(surface: SurfaceTexture, w: Int, h: Int) {
                original.onSurfaceTextureAvailable(surface, w, h)
            }
            override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, w: Int, h: Int) {
                if (w == lastWidth && h == lastHeight) return
                lastWidth = w; lastHeight = h
                pendingResize?.let { handler.removeCallbacks(it) }
                pendingResize = Runnable {
                    if (flutterTextureView.isAvailable) {
                        original.onSurfaceTextureSizeChanged(surface, w, h)
                    }
                }
                handler.postDelayed(pendingResize!!, 100)
            }
            override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {
                original.onSurfaceTextureUpdated(surface)
            }
            override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
                pendingResize?.let { handler.removeCallbacks(it) }
                pendingResize = null
                lastWidth = 0; lastHeight = 0
                return original.onSurfaceTextureDestroyed(surface)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        mainFlutterMessenger = flutterEngine.dartExecutor.binaryMessenger
        flutterEngine.plugins.add(MpvPlayerPlugin())
        flutterEngine.plugins.add(ExoPlayerPlugin())

        // External player: open local video files with proper content:// URIs
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EXTERNAL_PLAYER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openVideo" -> {
                    val filePath = call.argument<String>("filePath")
                    val packageName = call.argument<String>("package")

                    if (filePath == null) {
                        result.error("INVALID_ARGUMENT", "filePath is required", null)
                        return@setMethodCallHandler
                    }

                    try {
                        val uri: Uri
                        val grantRead: Boolean

                        if (filePath.startsWith("http://") || filePath.startsWith("https://")) {
                            uri = Uri.parse(filePath)
                            grantRead = false
                        } else if (filePath.startsWith("content://")) {
                            uri = Uri.parse(filePath)
                            grantRead = true
                        } else {
                            val path = if (filePath.startsWith("file://")) filePath.removePrefix("file://") else filePath
                            uri = FileProvider.getUriForFile(this, "${applicationContext.packageName}.fileprovider", File(path))
                            grantRead = true
                        }

                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "video/*")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            if (grantRead) {
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            if (packageName != null) {
                                setPackage(packageName)
                            }
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: android.content.ActivityNotFoundException) {
                        result.error("APP_NOT_FOUND", "No app found for package: $packageName", null)
                    } catch (e: Exception) {
                        result.error("LAUNCH_FAILED", e.message ?: e.javaClass.simpleName, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Splash screen theme: persist user's chosen theme for next launch (API 31+)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, THEME_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getRenderer" -> result.success(if (usingSkia) "Skia" else "Impeller")
                "setSplashTheme" -> {
                    val mode = call.argument<String>("mode")

                    // Persist for next cold start & update window background now
                    getSharedPreferences("plezy_prefs", Context.MODE_PRIVATE)
                        .edit().putString("splash_theme", mode).apply()
                    ThemeHelper.themeColor(mode)?.let { window.decorView.setBackgroundColor(it) }

                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        val themeId = when (mode) {
                            "dark" -> R.style.SplashTheme_Dark
                            "oled" -> R.style.SplashTheme_Oled
                            "light" -> R.style.SplashTheme_Light
                            "system" -> android.content.res.Resources.ID_NULL
                            else -> android.content.res.Resources.ID_NULL
                        }
                        splashScreen.setSplashScreenTheme(themeId)
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_TOOLS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "generateVideoThumbnail" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val targetPath = call.argument<String>("targetPath")
                    val maxWidth = call.argument<Int>("maxWidth") ?: 480
                    val quality = call.argument<Int>("quality") ?: 78
                    val timeMs = call.argument<Int>("timeMs")?.toLong() ?: 1200L

                    if (sourcePath.isNullOrBlank() || targetPath.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "sourcePath and targetPath are required", null)
                        return@setMethodCallHandler
                    }

                    Thread {
                        try {
                            val outputPath = generateVideoThumbnail(
                                sourcePath = sourcePath,
                                targetPath = targetPath,
                                maxWidth = maxWidth,
                                quality = quality,
                                timeMs = timeMs,
                            )
                            runOnUiThread { result.success(outputPath) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error(
                                    "THUMBNAIL_FAILED",
                                    e.message ?: e.javaClass.simpleName,
                                    null,
                                )
                            }
                        }
                    }.start()
                }
                "searchSubdl" -> {
                    val apiKey = call.argument<String>("apiKey")?.trim().orEmpty()
                    val filmName = call.argument<String>("filmName")?.trim().orEmpty()
                    val contentType = call.argument<String>("contentType")?.trim().orEmpty()
                    val languages = call.argument<String>("languages")?.trim().orEmpty()
                    val year = call.optionalInt("year")
                    val seasonNumber = call.optionalInt("seasonNumber")
                    val episodeNumber = call.optionalInt("episodeNumber")
                    val imdbId = call.argument<String>("imdbId")?.trim()
                    val tmdbId = call.argument<String>("tmdbId")?.trim()

                    if (apiKey.isBlank() || filmName.isBlank() || contentType.isBlank()) {
                        result.error("INVALID_ARGUMENT", "apiKey, filmName, and contentType are required", null)
                        return@setMethodCallHandler
                    }

                    Thread {
                        try {
                            Log.i(
                                TAG,
                                "searchSubdl (channel): film=$filmName type=$contentType lang=$languages year=$year S=$seasonNumber E=$episodeNumber imdb=$imdbId tmdb=$tmdbId",
                            )
                            val outcome = subdlClient.search(
                                apiKey = apiKey,
                                filmName = filmName,
                                contentType = contentType,
                                languages = languages,
                                year = year,
                                seasonNumber = seasonNumber,
                                episodeNumber = episodeNumber,
                                imdbId = imdbId,
                                tmdbId = tmdbId,
                            )
                            runOnUiThread {
                                if (outcome.errorMessage != null) {
                                    result.error("SUBDL_SEARCH_FAILED", outcome.errorMessage, null)
                                } else {
                                    result.success(
                                        outcome.subtitles.map { subtitle ->
                                            mapOf(
                                                "displayLabel" to subtitle.displayLabel,
                                                "rawDownload" to subtitle.rawDownload,
                                                "languageCode" to subtitle.languageCode,
                                            )
                                        },
                                    )
                                }
                            }
                        } catch (error: Exception) {
                            runOnUiThread {
                                result.error(
                                    "SUBDL_SEARCH_FAILED",
                                    error.message ?: error.javaClass.simpleName,
                                    null,
                                )
                            }
                        }
                    }.start()
                }
                "pickSubdlSubtitle" -> {
                    val apiKey = call.argument<String>("apiKey")?.trim().orEmpty()
                    val filmName = call.argument<String>("filmName")?.trim().orEmpty()
                    val contentType = call.argument<String>("contentType")?.trim().orEmpty()
                    val preferredLanguageCode = call.argument<String>("preferredLanguageCode")?.trim()
                    val year = call.optionalInt("year")
                    val seasonNumber = call.optionalInt("seasonNumber")
                    val episodeNumber = call.optionalInt("episodeNumber")
                    val imdbId = call.argument<String>("imdbId")?.trim()
                    val tmdbId = call.argument<String>("tmdbId")?.trim()

                    if (apiKey.isBlank() || filmName.isBlank() || contentType.isBlank()) {
                        result.error("INVALID_ARGUMENT", "apiKey, filmName, and contentType are required", null)
                        return@setMethodCallHandler
                    }

                    showLegacySubdlPicker(
                        apiKey = apiKey,
                        initialFilmName = filmName,
                        contentType = contentType,
                        preferredLanguageCode = preferredLanguageCode,
                        year = year,
                        seasonNumber = seasonNumber,
                        episodeNumber = episodeNumber,
                        imdbId = imdbId,
                        tmdbId = tmdbId,
                        result = result,
                    )
                }
                "searchSubdlWithDialog" -> {
                    val apiKey = call.argument<String>("apiKey")?.trim().orEmpty()
                    val filmName = call.argument<String>("filmName")?.trim().orEmpty()
                    val contentType = call.argument<String>("contentType")?.trim().orEmpty()
                    val preferredLanguageCode = call.argument<String>("preferredLanguageCode")?.trim()
                    val year = call.optionalInt("year")
                    val seasonNumber = call.optionalInt("seasonNumber")
                    val episodeNumber = call.optionalInt("episodeNumber")
                    val imdbId = call.argument<String>("imdbId")?.trim()
                    val tmdbId = call.argument<String>("tmdbId")?.trim()

                    if (apiKey.isBlank() || filmName.isBlank() || contentType.isBlank()) {
                        result.error("INVALID_ARGUMENT", "apiKey, filmName, and contentType are required", null)
                        return@setMethodCallHandler
                    }

                    showLegacySubdlSearchDialog(
                        apiKey = apiKey,
                        initialFilmName = filmName,
                        contentType = contentType,
                        preferredLanguageCode = preferredLanguageCode,
                        year = year,
                        seasonNumber = seasonNumber,
                        episodeNumber = episodeNumber,
                        imdbId = imdbId,
                        tmdbId = tmdbId,
                        result = result,
                    )
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val apkPath = call.argument<String>("path")
                    if (apkPath.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "path is required", null)
                        return@setMethodCallHandler
                    }

                    try {
                        val apkFile = File(apkPath)
                        if (!apkFile.exists()) {
                            result.error("NOT_FOUND", "APK file does not exist", null)
                            return@setMethodCallHandler
                        }

                        val apkUri = FileProvider.getUriForFile(
                            this,
                            "${applicationContext.packageName}.fileprovider",
                            apkFile,
                        )

                        val installIntent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(apkUri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }

                        val resolveInfo = packageManager.queryIntentActivities(
                            installIntent,
                            PackageManager.MATCH_DEFAULT_ONLY,
                        )
                        if (resolveInfo.isEmpty()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }

                        resolveInfo.forEach { info ->
                            grantUriPermission(
                                info.activityInfo.packageName,
                                apkUri,
                                Intent.FLAG_GRANT_READ_URI_PERMISSION,
                            )
                        }

                        startActivity(installIntent)
                        result.success(true)
                    } catch (error: ActivityNotFoundException) {
                        result.success(false)
                    } catch (error: Exception) {
                        result.error("INSTALL_FAILED", error.message ?: error.javaClass.simpleName, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Register Watch Next plugin and keep reference for deep link handling
        watchNextPlugin = WatchNextPlugin()
        flutterEngine.plugins.add(watchNextPlugin!!)

        MethodChannel( flutterEngine.dartExecutor.binaryMessenger, PIP_CHANNEL ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> {
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                }
                "enter" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                        result.success(mapOf("success" to false, "errorCode" to "android_version"))
                        return@setMethodCallHandler
                    }

                    if (!isPipPermissionGranted()) {
                        result.success(mapOf("success" to false, "errorCode" to "permission_disabled"))
                        return@setMethodCallHandler
                    }

                    try {
                        val width = call.argument<Int>("width") ?: 16
                        val height = call.argument<Int>("height") ?: 9
                        val params = buildPipParams(width, height)
                        val success = enterPictureInPictureMode(params)
                        if (success) {
                            result.success(mapOf("success" to true))
                        } else {
                            result.success(mapOf("success" to false, "errorCode" to "failed"))
                        }
                    } catch (e: IllegalStateException) {
                        result.success(mapOf("success" to false, "errorCode" to "not_supported"))
                    } catch (e: Exception) {
                        result.success(mapOf("success" to false, "errorCode" to "unknown", "errorMessage" to (e.message ?: "Unknown error")))
                    }
                }
                "setAutoPipReady" -> {
                    autoPipReady = call.argument<Boolean>("ready") ?: false
                    autoPipWidth = call.argument<Int>("width") ?: 16
                    autoPipHeight = call.argument<Int>("height") ?: 9

                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        try {
                            val params = buildPipParams(autoPipWidth, autoPipHeight, autoEnterEnabled = autoPipReady)
                            setPictureInPictureParams(params)
                        } catch (e: Exception) {
                            Log.w(TAG, "Failed to set auto-PiP params", e)
                        }
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean,newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        flutterEngine?.let { engine ->
            MethodChannel(engine.dartExecutor.binaryMessenger, PIP_CHANNEL).invokeMethod("onPipChanged", isInPictureInPictureMode)
            engine.plugins.get(ExoPlayerPlugin::class.java)?.let { plugin ->
                (plugin as? ExoPlayerPlugin)?.onPipModeChanged(isInPictureInPictureMode)
            }
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Auto PiP for API 26-30 (API 31+ uses setAutoEnterEnabled)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S &&
            autoPipReady && isPipPermissionGranted()) {
            try {
                // Notify Flutter to prepare video filter before PiP
                flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
                    MethodChannel(messenger, PIP_CHANNEL).invokeMethod("onAutoPipEntering", null)
                }
                val params = buildPipParams(autoPipWidth, autoPipHeight)
                enterPictureInPictureMode(params)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to enter auto-PiP", e)
            }
        }
    }

    private fun isPipPermissionGranted(): Boolean {
        val appOpsManager = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        return appOpsManager.checkOpNoThrow(
            AppOpsManager.OPSTR_PICTURE_IN_PICTURE,
            applicationInfo.uid,
            packageName
        ) == AppOpsManager.MODE_ALLOWED
    }

    private fun buildPipParams(width: Int, height: Int, autoEnterEnabled: Boolean? = null): PictureInPictureParams {
        val (w, h) = if (width <= 0 || height <= 0) {
            Pair(16, 9)
        } else {
            val ratio = width.toFloat() / height.toFloat()
            when {
                ratio < 1f / 2.39f -> Pair(100, 239)
                ratio > 2.39f -> Pair(239, 100)
                else -> Pair(width, height)
            }
        }
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(w, h))
        if (autoEnterEnabled != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(autoEnterEnabled)
        }
        return builder.build()
    }

    private fun generateVideoThumbnail(
        sourcePath: String,
        targetPath: String,
        maxWidth: Int,
        quality: Int,
        timeMs: Long,
    ): String {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(sourcePath)
            val frame = retriever.getFrameAtTime(
                timeMs * 1000L,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            ) ?: throw IllegalStateException("Could not decode video frame")

            val scaled = if (maxWidth > 0 && frame.width > maxWidth) {
                val targetHeight = (frame.height * (maxWidth.toDouble() / frame.width))
                    .toInt()
                    .coerceAtLeast(1)
                Bitmap.createScaledBitmap(frame, maxWidth, targetHeight, true).also {
                    if (it !== frame) {
                        frame.recycle()
                    }
                }
            } else {
                frame
            }

            val outputFile = File(targetPath)
            outputFile.parentFile?.mkdirs()
            FileOutputStream(outputFile).use { stream ->
                if (!scaled.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(1, 100), stream)) {
                    throw IllegalStateException("Could not compress thumbnail bitmap")
                }
                stream.flush()
            }
            scaled.recycle()
            return outputFile.absolutePath
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun showLegacySubdlPicker(
        apiKey: String,
        initialFilmName: String,
        contentType: String,
        preferredLanguageCode: String?,
        year: Int?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        imdbId: String?,
        tmdbId: String?,
        result: MethodChannel.Result,
    ) {
        val view = LayoutInflater.from(this).inflate(R.layout.dialog_subdl_search, null, false)
        val nameEditText = view.findViewById<EditText>(R.id.subdl_search_name)
        val languageSpinner = view.findViewById<Spinner>(R.id.subdl_search_language)
        val languageLoadingRow = view.findViewById<View>(R.id.subdl_language_loading_row)
        val seasonEditText = view.findViewById<EditText>(R.id.subdl_search_season)
        val episodeEditText = view.findViewById<EditText>(R.id.subdl_search_episode)

        nameEditText.setText(initialFilmName)
        seasonNumber?.let { seasonEditText.setText(it.toString()) }
        episodeNumber?.let { episodeEditText.setText(it.toString()) }

        var languagePairs: List<Pair<String, String>> = emptyList()
        var completed = false

        fun finishOnce(value: Map<String, Any?>?) {
            if (completed) return
            completed = true
            result.success(value)
        }

        fun failOnce(message: String) {
            if (completed) return
            completed = true
            result.error("SUBDL_PICK_FAILED", message, null)
        }

        fun busyDialog(): AlertDialog {
            val progress = ProgressBar(this).apply { isIndeterminate = true }
            return AlertDialog.Builder(this)
                .setTitle(R.string.internal_player_loading)
                .setView(progress)
                .setCancelable(false)
                .create()
        }

        fun showResultsDialog(entries: List<SubdlApiClient.SubtitleEntry>) {
            val labels = entries.map { it.displayLabel }.toTypedArray()
            AlertDialog.Builder(this)
                .setTitle(R.string.internal_player_search_title)
                .setItems(labels) { dialogInterface, which ->
                    dialogInterface.dismiss()
                    val selected = entries.getOrNull(which)
                    if (selected == null) {
                        finishOnce(null)
                        return@setItems
                    }
                    val loading = busyDialog()
                    loading.show()
                    lifecycleScope.launch {
                        val extracted = withContext(Dispatchers.IO) {
                            try {
                                val workDir = File(cacheDir, "subtitles/manual_${System.currentTimeMillis()}")
                                workDir.mkdirs()
                                val zipFile = File(workDir, "sub.zip")
                                subdlClient.downloadZipToFile(selected.rawDownload, zipFile)
                                SubtitleZipExtractor.extractBest(zipFile, workDir)
                            } catch (_: Exception) {
                                null
                            }
                        }
                        loading.dismiss()
                        if (extracted == null) {
                            Toast.makeText(this@MainActivity, R.string.internal_player_subtitle_apply_failed, Toast.LENGTH_LONG).show()
                            failOnce(getString(R.string.internal_player_subtitle_apply_failed))
                            return@launch
                        }
                        finishOnce(
                            mapOf(
                                "filePath" to extracted.file.absolutePath,
                                "displayLabel" to selected.displayLabel,
                                "languageCode" to selected.languageCode,
                            ),
                        )
                    }
                }
                .setOnCancelListener { finishOnce(null) }
                .create().also {
                    it.setOnShowListener { _ -> applyLegacyDialogWidth(it) }
                    it.show()
                }
        }

        val dialog = AlertDialog.Builder(this)
            .setTitle(R.string.internal_player_search_title)
            .setView(view)
            .setPositiveButton(R.string.internal_player_check, null)
            .setNegativeButton(R.string.internal_player_cancel) { dialogInterface, _ ->
                finishOnce(null)
                dialogInterface.dismiss()
            }
            .create()

        fun positiveButton(): Button? = dialog.getButton(AlertDialog.BUTTON_POSITIVE)

        fun runSearch() {
            val filmName = nameEditText.text?.toString().orEmpty().trim()
            if (filmName.isEmpty()) {
                Toast.makeText(this, R.string.internal_player_label_name, Toast.LENGTH_SHORT).show()
                return
            }
            val selectedLanguage = languagePairs.getOrNull(languageSpinner.selectedItemPosition)?.first ?: "EN"
            notifyFlutterSubtitleSearchLanguage(selectedLanguage)
            val parsedSeason = seasonEditText.text?.toString()?.trim()?.toIntOrNull()
            val parsedEpisode = episodeEditText.text?.toString()?.trim()?.toIntOrNull()
            Log.i(
                TAG,
                "SubDL picker runSearch: film=$filmName rawSeason=${seasonEditText.text} rawEpisode=${episodeEditText.text} -> S=$parsedSeason E=$parsedEpisode lang=$selectedLanguage type=$contentType year=$year",
            )
            positiveButton()?.isEnabled = false

            lifecycleScope.launch {
                val outcome = withContext(Dispatchers.IO) {
                    subdlClient.search(
                        apiKey = apiKey,
                        filmName = filmName,
                        contentType = contentType,
                        languages = selectedLanguage,
                        year = year,
                        seasonNumber = parsedSeason,
                        episodeNumber = parsedEpisode,
                        imdbId = imdbId,
                        tmdbId = tmdbId,
                    )
                }
                positiveButton()?.isEnabled = true
                Log.i(TAG, "SubDL picker outcome: err=${outcome.errorMessage} count=${outcome.subtitles.size}")
                if (outcome.errorMessage != null) {
                    Toast.makeText(
                        this@MainActivity,
                        getString(R.string.internal_player_search_failed, outcome.errorMessage),
                        Toast.LENGTH_LONG,
                    ).show()
                    return@launch
                }
                if (outcome.subtitles.isEmpty()) {
                    Toast.makeText(this@MainActivity, R.string.internal_player_found_zero_subtitles, Toast.LENGTH_LONG).show()
                    return@launch
                }
                dialog.dismiss()
                showResultsDialog(outcome.subtitles)
            }
        }

        dialog.setOnShowListener {
            positiveButton()?.apply {
                isEnabled = false
                setOnClickListener { runSearch() }
            }
        }

        dialog.setOnDismissListener {
            if (!completed) {
                finishOnce(null)
            }
        }

        dialog.show()
        applyLegacyDialogWidth(dialog)

        lifecycleScope.launch {
            val languages = try {
                SubdlLanguageListLoader(this@MainActivity).loadSorted()
            } catch (_: Exception) {
                listOf("EN" to "English")
            }
            languagePairs = languages
            val labels = languages.map { "${it.second} (${it.first})" }
            val adapter = ArrayAdapter(
                this@MainActivity,
                android.R.layout.simple_spinner_item,
                labels,
            )
            adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
            languageSpinner.adapter = adapter
            val preferredIndex = preferredLanguageCode
                ?.uppercase()
                ?.let { code -> languages.indexOfFirst { it.first.equals(code, ignoreCase = true) } }
                ?.takeIf { it >= 0 }
                ?: languages.indexOfFirst { it.first == "EN" }.takeIf { it >= 0 }
                ?: 0
            languageSpinner.setSelection(preferredIndex)
            languageLoadingRow.visibility = View.GONE
            languageSpinner.visibility = View.VISIBLE
            positiveButton()?.isEnabled = true
        }
    }

    private fun showLegacySubdlSearchDialog(
        apiKey: String,
        initialFilmName: String,
        contentType: String,
        preferredLanguageCode: String?,
        year: Int?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        imdbId: String?,
        tmdbId: String?,
        result: MethodChannel.Result,
    ) {
        val view = LayoutInflater.from(this).inflate(R.layout.dialog_subdl_search, null, false)
        val nameEditText = view.findViewById<EditText>(R.id.subdl_search_name)
        val languageSpinner = view.findViewById<Spinner>(R.id.subdl_search_language)
        val languageLoadingRow = view.findViewById<View>(R.id.subdl_language_loading_row)
        val seasonEditText = view.findViewById<EditText>(R.id.subdl_search_season)
        val episodeEditText = view.findViewById<EditText>(R.id.subdl_search_episode)

        nameEditText.setText(initialFilmName)
        seasonNumber?.let { seasonEditText.setText(it.toString()) }
        episodeNumber?.let { episodeEditText.setText(it.toString()) }

        var languagePairs: List<Pair<String, String>> = emptyList()
        var completed = false

        fun finishOnce(value: List<Map<String, Any?>>?) {
            if (completed) return
            completed = true
            result.success(value)
        }

        val dialog = AlertDialog.Builder(this)
            .setTitle(R.string.internal_player_search_title)
            .setView(view)
            .setPositiveButton(R.string.internal_player_check, null)
            .setNegativeButton(R.string.internal_player_cancel) { dialogInterface, _ ->
                finishOnce(null)
                dialogInterface.dismiss()
            }
            .create()

        fun positiveButton(): Button? = dialog.getButton(AlertDialog.BUTTON_POSITIVE)

        fun runSearch() {
            val filmName = nameEditText.text?.toString().orEmpty().trim()
            if (filmName.isEmpty()) {
                Toast.makeText(this, R.string.internal_player_label_name, Toast.LENGTH_SHORT).show()
                return
            }
            val selectedLanguage = languagePairs.getOrNull(languageSpinner.selectedItemPosition)?.first ?: "EN"
            notifyFlutterSubtitleSearchLanguage(selectedLanguage)
            val parsedSeason = seasonEditText.text?.toString()?.trim()?.toIntOrNull()
            val parsedEpisode = episodeEditText.text?.toString()?.trim()?.toIntOrNull()
            Log.i(
                TAG,
                "SubDL dialog runSearch: film=$filmName rawSeason=${seasonEditText.text} rawEpisode=${episodeEditText.text} -> S=$parsedSeason E=$parsedEpisode lang=$selectedLanguage type=$contentType year=$year imdb=$imdbId tmdb=$tmdbId",
            )
            positiveButton()?.isEnabled = false

            lifecycleScope.launch {
                val outcome = withContext(Dispatchers.IO) {
                    subdlClient.search(
                        apiKey = apiKey,
                        filmName = filmName,
                        contentType = contentType,
                        languages = selectedLanguage,
                        year = year,
                        seasonNumber = parsedSeason,
                        episodeNumber = parsedEpisode,
                        imdbId = imdbId,
                        tmdbId = tmdbId,
                    )
                }
                positiveButton()?.isEnabled = true
                Log.i(TAG, "SubDL dialog outcome: err=${outcome.errorMessage} count=${outcome.subtitles.size}")
                if (outcome.errorMessage != null) {
                    Toast.makeText(
                        this@MainActivity,
                        getString(R.string.internal_player_search_failed, outcome.errorMessage),
                        Toast.LENGTH_LONG,
                    ).show()
                    return@launch
                }
                if (outcome.subtitles.isEmpty()) {
                    Toast.makeText(
                        this@MainActivity,
                        R.string.internal_player_found_zero_subtitles,
                        Toast.LENGTH_LONG,
                    ).show()
                    return@launch
                }
                finishOnce(
                    outcome.subtitles.map { subtitle ->
                        mapOf(
                            "displayLabel" to subtitle.displayLabel,
                            "rawDownload" to subtitle.rawDownload,
                            "languageCode" to subtitle.languageCode,
                        )
                    },
                )
                dialog.dismiss()
            }
        }

        dialog.setOnShowListener {
            applyLegacyDialogWidth(dialog)
            positiveButton()?.apply {
                isEnabled = false
                setOnClickListener { runSearch() }
            }
        }

        dialog.setOnDismissListener {
            if (!completed) {
                finishOnce(null)
            }
        }

        dialog.show()

        lifecycleScope.launch {
            val languages = try {
                SubdlLanguageListLoader(this@MainActivity).loadSorted()
            } catch (_: Exception) {
                listOf("EN" to "English")
            }
            languagePairs = languages
            val labels = languages.map { "${it.second} (${it.first})" }
            val adapter = ArrayAdapter(
                this@MainActivity,
                android.R.layout.simple_spinner_item,
                labels,
            )
            adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
            languageSpinner.adapter = adapter
            val preferredIndex = preferredLanguageCode
                ?.uppercase()
                ?.let { code -> languages.indexOfFirst { it.first.equals(code, ignoreCase = true) } }
                ?.takeIf { it >= 0 }
                ?: languages.indexOfFirst { it.first == "EN" }.takeIf { it >= 0 }
                ?: 0
            languageSpinner.setSelection(preferredIndex)
            languageLoadingRow.visibility = View.GONE
            languageSpinner.visibility = View.VISIBLE
            positiveButton()?.isEnabled = true
        }
    }

    /// Persists SubDL search language from native dialogs into Flutter [SettingsService] (ISO 639-1 lowercase).
    private fun notifyFlutterSubtitleSearchLanguage(languageCode: String) {
        val normalized = languageCode.trim().lowercase(Locale.US)
        if (normalized.isEmpty()) return
        if (!::mainFlutterMessenger.isInitialized) return
        runOnUiThread {
            try {
                MethodChannel(mainFlutterMessenger, "de.aryanmo.oxplayer/subtitle_search_locale").invokeMethod(
                    "setLanguageCode",
                    normalized,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {}
                        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
                        override fun notImplemented() {}
                    },
                )
            } catch (e: Exception) {
                Log.w(TAG, "notifyFlutterSubtitleSearchLanguage failed: ${e.message}")
            }
        }
    }

    private fun applyLegacyDialogWidth(dialog: AlertDialog) {
        val width = (resources.displayMetrics.widthPixels * 0.92f).toInt()
        dialog.window?.setLayout(width, ViewGroup.LayoutParams.WRAP_CONTENT)
    }
}
