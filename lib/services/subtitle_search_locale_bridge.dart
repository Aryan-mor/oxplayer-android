import 'dart:io';

import 'package:flutter/services.dart';

import 'settings_service.dart';

/// Android native SubDL dialogs call into Flutter to remember the last chosen search language.
class SubtitleSearchLocaleBridge {
  SubtitleSearchLocaleBridge._();

  static const _channel = MethodChannel('de.aryanmo.oxplayer/subtitle_search_locale');
  static bool _registered = false;

  static void register() {
    if (!Platform.isAndroid || _registered) return;
    _registered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'setLanguageCode') {
        final raw = call.arguments;
        final code = raw is String ? raw : raw?.toString();
        if (code != null && code.trim().isNotEmpty) {
          final settings = await SettingsService.getInstance();
          await settings.setSubtitleSearchLanguageCode(code);
        }
      }
    });
  }
}
