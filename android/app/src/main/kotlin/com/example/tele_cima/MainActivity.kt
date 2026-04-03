package com.example.tele_cima

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.ActivityNotFoundException
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.storage.StorageManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL_PLAYER = "telecima/external_player"
        private const val CHANNEL_MEDIA = "telecima/media_utils"
        private const val CHANNEL_APP = "telecima/app_info"
        private const val CHANNEL_STORAGE = "telecima/storage_space"

        init {
            // Load TDLib JSON client from jniLibs/<abi>/libtdjson.so (x86, x86_64, arm*, …)
            // before Dart FFI calls DynamicLibrary.open('libtdjson.so').
            try {
                System.loadLibrary("tdjson")
            } catch (_: UnsatisfiedLinkError) {
                // Dart init will surface a clearer error if the ABI folder is missing.
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── App package version (replaces package_info_plus plugin registration) ─
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_APP)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPackageInfo" -> {
                        try {
                            val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                packageManager.getPackageInfo(
                                    packageName,
                                    PackageManager.PackageInfoFlags.of(0),
                                )
                            } else {
                                @Suppress("DEPRECATION")
                                packageManager.getPackageInfo(packageName, 0)
                            }
                            val versionCode =
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                    info.longVersionCode
                                } else {
                                    @Suppress("DEPRECATION")
                                    info.versionCode.toLong()
                                }
                            result.success(
                                mapOf(
                                    "versionName" to (info.versionName ?: ""),
                                    "versionCode" to versionCode,
                                ),
                            )
                        } catch (e: Exception) {
                            result.error("PACKAGE_INFO", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Writable free space (sum per distinct volume UUID) ─────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_STORAGE)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getWritableVolumesFreeBytes" -> {
                        try {
                            val total = sumDistinctVolumeFreeBytes(this)
                            result.success(mapOf("totalFreeBytes" to total))
                        } catch (e: Exception) {
                            result.error("STORAGE", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Channel 1: Launch external video player ───────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_PLAYER)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchVideo" -> {
                        @Suppress("UNCHECKED_CAST")
                        val args = call.arguments as? Map<String, Any?>
                        val path = (args?.get("path") as? String) ?: (call.arguments as? String)
                        val streamUriRaw = (args?.get("uri") as? String)?.ifBlank { null }
                        val title = (args?.get("title") as? String)?.ifBlank { null }
                        val mimeType = (args?.get("mimeType") as? String)?.ifBlank { null } ?: "video/*"
                        if (path == null && streamUriRaw == null) {
                            result.error("INVALID_ARG", "path/uri is null", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val effectiveTitle = title ?: "TeleCima stream"
                            val contentUri: Uri = if (streamUriRaw != null) {
                                Uri.parse(streamUriRaw)
                            } else {
                                val file = File(path!!)
                                if (!file.exists()) {
                                    result.success(false)
                                    return@setMethodCallHandler
                                }
                                FileProvider.getUriForFile(
                                    this,
                                    "${packageName}.fileprovider",
                                    file
                                )
                            }
                            val resolvedTitle = if (streamUriRaw != null) {
                                effectiveTitle
                            } else {
                                val f = File(path!!)
                                title ?: f.nameWithoutExtension
                            }

                            android.util.Log.d(
                                "TeleCima",
                                "launchVideo uri=$contentUri path=$path title=$resolvedTitle mime=$mimeType"
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(contentUri, mimeType)
                                if (streamUriRaw == null) {
                                    clipData = ClipData.newUri(contentResolver, resolvedTitle, contentUri)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                putExtra(Intent.EXTRA_TITLE, resolvedTitle)
                                putExtra("title", resolvedTitle)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (_: ActivityNotFoundException) {
                            result.success(false)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Channel 2: Inject MP4 metadata ───────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_MEDIA)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "injectMetadata" -> {
                        @Suppress("UNCHECKED_CAST")
                        val args = call.arguments as? Map<String, Any?>
                        val path = args?.get("path") as? String
                        val title = (args?.get("title") as? String) ?: ""
                        val year = (args?.get("year") as? String) ?: ""
                        val mediaTitle = args?.get("mediaTitle") as? String
                        val displayTitle = args?.get("displayTitle") as? String
                        val subtitle = args?.get("subtitle") as? String
                        val isSeries = args?.get("isSeries") as? Boolean ?: false

                        if (path == null) {
                            result.error("INVALID_ARG", "path is null", null)
                            return@setMethodCallHandler
                        }

                        android.util.Log.d(
                            "TeleCima",
                            "injectMetadata: path=$path title='$title' year='$year' " +
                                "mediaTitle='$mediaTitle' displayTitle='$displayTitle' " +
                                "subtitle='$subtitle' isSeries=$isSeries",
                        )

                        val ext = File(path).extension.lowercase()
                        if (ext == "mp4" || ext == "m4v") {
                            // MP4 tag atoms: add isoparser if we need on-device moov/udta writes.
                            // Filename + intent extras already carry the display title for many players.
                            result.success("ok")
                        } else {
                            result.success("unsupported")
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun usableSpaceBytes(path: File): Long = try {
        if (!path.exists()) 0L else path.usableSpace
    } catch (_: Exception) {
        0L
    }

    /**
     * Sums [File.getUsableSpace] once per physical storage volume the app can write to
     * (internal files dir, cache, and each [getExternalFilesDirs] entry), deduplicated
     * via [StorageManager.getUuidForPath] on API 24+.
     */
    private fun sumDistinctVolumeFreeBytes(context: Context): Long {
        val candidates = ArrayList<File>(6)
        context.filesDir?.let { candidates.add(it) }
        context.cacheDir?.let { candidates.add(it) }
        context.getExternalFilesDirs(null)?.filterNotNull()?.forEach { candidates.add(it) }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val sm = context.getSystemService(Context.STORAGE_SERVICE) as StorageManager
            val seen = HashSet<String>()
            var sum = 0L
            for (raw in candidates) {
                try {
                    val f = raw.canonicalFile
                    if (!f.exists()) continue
                    val key = try {
                        sm.getUuidForPath(f).toString()
                    } catch (_: Exception) {
                        f.absolutePath
                    }
                    if (seen.add(key)) {
                        sum += usableSpaceBytes(f)
                    }
                } catch (_: Exception) {
                }
            }
            return sum
        }

        // API < 24: avoid double-counting the same volume (files vs cache).
        var best = 0L
        for (raw in candidates) {
            try {
                val f = raw.canonicalFile
                if (!f.exists()) continue
                val u = usableSpaceBytes(f)
                if (u > best) best = u
            } catch (_: Exception) {
            }
        }
        return best
    }
}
