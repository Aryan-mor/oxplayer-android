import 'package:flutter/foundation.dart';
import 'package:isar/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/local/entities.dart';
import '../../data/local/isar_provider.dart';

const kSessionKey = 'TELEGRAM_SESSION';
const kApiAccessTokenKey = 'TV_APP_API_ACCESS_TOKEN';

/// Minimal session gate (parity with `localStorage` in `tv-app-old`).
class AuthNotifier extends ChangeNotifier {
  AuthNotifier() {
    hydrate();
  }

  bool _ready = false;
  String? _session;
  String? _apiAccessToken;

  bool get ready => _ready;
  String? get session => _session;
  String? get apiAccessToken => _apiAccessToken;
  bool get isLoggedIn => (_session ?? '').isNotEmpty;

  Future<void> hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    _session = prefs.getString(kSessionKey);
    _apiAccessToken = prefs.getString(kApiAccessTokenKey);
    _ready = true;
    notifyListeners();
  }

  Future<void> setSession(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kSessionKey, value);
    _session = value;
    notifyListeners();
  }

  Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kSessionKey);
    await prefs.remove(kApiAccessTokenKey);
    _session = null;
    _apiAccessToken = null;
    notifyListeners();
  }

  Future<void> setApiAccessToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kApiAccessTokenKey, token);
    _apiAccessToken = token;
    notifyListeners();
  }

  /// If SharedPreferences has no session yet, restore `tdlib:<userId>` from Isar (startup).
  Future<void> mergeIsarSession(Isar isar) async {
    final row = await isar.runWithRetry(
      () => isar.telegramSessions.getBySingletonKey(1),
      debugName: 'mergeIsarSession',
    );
    if (row != null && row.userId > 0) {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getString(kSessionKey);
      if (existing == null || existing.isEmpty) {
        await setSession('tdlib:${row.userId}');
      }
    }
  }

  /// Clears prefs session and removes the singleton TDLib session row (logout).
  Future<void> clearTelegramIsarSession(Isar isar) async {
    await isar.runWithRetry(
        () => isar.writeTxn(() async {
              await isar.telegramSessions.deleteAllBySingletonKey([1]);
            }),
        debugName: 'clearIsarSession');
    await clearSession();
  }
}
