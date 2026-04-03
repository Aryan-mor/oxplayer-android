import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '../core/debug/app_debug_log.dart';

/// Full-screen in-app player (Media3 ExoPlayer on Android).
///
/// See [InternalPlayerActivity] in Kotlin.
class InternalPlayer {
  InternalPlayer._();

  static const _channel = MethodChannel('telecima/internal_player');

  /// Play a URL (e.g. `http://127.0.0.1:port/stream` from [TelegramRangePlayback]).
  static Future<bool> playHttpUrl({
    required String url,
    required String title,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      final r = await _channel.invokeMethod<bool>('playHttpUrl', {
        'url': url,
        'title': title,
      });
      return r ?? false;
    } on PlatformException catch (e) {
      AppDebugLog.instance.log(
        'InternalPlayer: playHttpUrl error: $e',
        category: AppDebugLogCategory.app,
      );
      return false;
    }
  }

  /// Play a completed local file by absolute path.
  static Future<bool> playLocalFile({
    required String path,
    required String title,
  }) async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      final r = await _channel.invokeMethod<bool>('playLocalFile', {
        'path': path,
        'title': title,
      });
      return r ?? false;
    } on PlatformException catch (e) {
      AppDebugLog.instance.log(
        'InternalPlayer: playLocalFile error: $e',
        category: AppDebugLogCategory.app,
      );
      return false;
    }
  }
}
