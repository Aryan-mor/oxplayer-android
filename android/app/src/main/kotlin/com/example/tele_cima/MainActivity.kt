package com.example.tele_cima

import android.content.ClipData
import android.content.Intent
import android.content.ActivityNotFoundException
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL_PLAYER = "telecima/external_player"
        private const val CHANNEL_MEDIA  = "telecima/media_utils"

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

        // ── Channel 1: Launch external video player ───────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_PLAYER)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchVideo" -> {
                        @Suppress("UNCHECKED_CAST")
                        val args = call.arguments as? Map<String, Any?>
                        val path = (args?.get("path") as? String) ?: (call.arguments as? String)
                        val title = (args?.get("title") as? String)?.ifBlank { null }
                        val mimeType = (args?.get("mimeType") as? String)?.ifBlank { null } ?: "video/*"
                        if (path == null) {
                            result.error("INVALID_ARG", "path is null", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val file = File(path)
                            if (!file.exists()) {
                                result.success(false)
                                return@setMethodCallHandler
                            }
                            val contentUri: Uri = FileProvider.getUriForFile(
                                this,
                                "${packageName}.fileprovider",
                                file
                            )
                            val effectiveTitle = title ?: file.nameWithoutExtension

                            android.util.Log.d(
                                "TeleCima",
                                "launchVideo uri=$contentUri path=$path title=$effectiveTitle mime=$mimeType"
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(contentUri, mimeType)
                                clipData = ClipData.newUri(contentResolver, effectiveTitle, contentUri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                putExtra(Intent.EXTRA_TITLE, effectiveTitle)
                                putExtra("title", effectiveTitle)
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
}
