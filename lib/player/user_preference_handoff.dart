import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '../core/auth/auth_notifier.dart';

/// Android: native PATCH /me/preferences then delivers the new language here.
class UserPreferenceHandoff {
  UserPreferenceHandoff._();

  static const _channel = MethodChannel('oxplayer/user_prefs');

  static void register(AuthNotifier auth) {
    if (kIsWeb || !Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'setPreferredSubtitleLanguage') return;
      final raw = call.arguments;
      if (raw is! Map) return;
      final code = raw['preferredSubtitleLanguage']?.toString().trim();
      if (code == null || code.isEmpty) return;
      await auth.setPreferredSubtitleLanguage(code);
    });
  }
}
