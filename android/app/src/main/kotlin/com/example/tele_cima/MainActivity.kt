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
                        val args = call.arguments as? Map<String, String>
                        val path  = args?.get("path")
                        val title = args?.get("title") ?: ""
                        val year  = args?.get("year")  ?: ""

                        if (path == null) {
                            result.error("INVALID_ARG", "path is null", null)
                            return@setMethodCallHandler
                        }

                        val ext = File(path).extension.lowercase()
                        if (ext == "mp4" || ext == "m4v") {
                            // MediaMetadataRetriever cannot write — use mp4parser or
                            // a native approach for full tag injection.
                            // For v1 we set the title via a best-effort rename that is
                            // already done in Dart; actual tag writing requires mp4parser
                            // (coM.googlecode.mp4parser:isoparser) added to build.gradle.
                            // Log and return "ok" — tags will display in external player
                            // via the file name which is already standardized.
                            android.util.Log.d("TeleCima", "injectMetadata: mp4 title='$title' year='$year' path=$path (v1: tag writing via filename)")
                            result.success("ok")
                        } else {
                            // MKV / WebM / AVI: no-op for v1
                            android.util.Log.d("TeleCima", "injectMetadata: skipping $ext (not mp4) path=$path")
                            result.success("unsupported")
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
