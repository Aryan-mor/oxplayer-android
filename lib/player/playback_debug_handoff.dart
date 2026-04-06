import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '../core/debug/app_debug_log.dart';

/// Android: native playback layer pushes error diagnostics to Flutter debug log.
class PlaybackDebugHandoff {
  PlaybackDebugHandoff._();

  static const _channel = MethodChannel('oxplayer/playback_debug');

  static void register() {
    if (kIsWeb || !Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'appendLog') return;
      final raw = call.arguments;
      if (raw is! Map) return;
      final message = raw['message']?.toString().trim();
      if (message == null || message.isEmpty) return;
      AppDebugLog.instance.log(
        message,
        category: AppDebugLogCategory.playback,
      );
    });
  }
}
