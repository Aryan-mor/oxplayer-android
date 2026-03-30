import 'package:flutter/services.dart';

import '../core/debug/app_debug_log.dart';

/// Dart-side wrapper for the `telecima/external_player` MethodChannel.
///
/// The native side (MainActivity.kt) handles:
///   - `launchVideo(path)` — fires ACTION_VIEW with a FileProvider URI and video/* MIME.
///   - `injectMetadata(path, title, year)` — writes MP4 tags (MKV is no-op for v1).
class ExternalPlayer {
  ExternalPlayer._();

  static const _channel = MethodChannel('telecima/external_player');
  static const _metaChannel = MethodChannel('telecima/media_utils');

  /// Launches the system media handler for [path] via implicit intent.
  ///
  /// Returns `true` if the intent was dispatched, `false` if no app handled it.
  static Future<bool> launchVideo({
    required String path,
    required String title,
  }) async {
    try {
      final mimeType = _mimeFromPath(path);
      AppDebugLog.instance.log(
        'ExternalPlayer: launchVideo path=$path title="$title" mime=$mimeType',
      );
      final result = await _channel.invokeMethod<bool>('launchVideo', {
        'path': path,
        'title': title,
        'mimeType': mimeType,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      AppDebugLog.instance.log('ExternalPlayer: launchVideo error: $e');
      return false;
    }
  }

  /// Injects MP4 metadata tags. No-op for MKV/other in v1.
  static Future<void> injectMetadata({
    required String path,
    required String title,
    required String year,
  }) async {
    try {
      AppDebugLog.instance.log(
        'ExternalPlayer: injectMetadata title=$title year=$year path=$path',
      );
      await _metaChannel.invokeMethod<void>('injectMetadata', {
        'path': path,
        'title': title,
        'year': year,
      });
    } on PlatformException catch (e) {
      AppDebugLog.instance.log(
        'ExternalPlayer: injectMetadata error (non-fatal): $e',
      );
    }
  }

  static String _mimeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    if (lower.endsWith('.mp4') || lower.endsWith('.m4v')) return 'video/mp4';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.avi')) return 'video/x-msvideo';
    return 'video/*';
  }
}
