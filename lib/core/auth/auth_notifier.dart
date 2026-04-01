import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/local/telegram_session_store.dart' as session_store;

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
  bool get hasTelegramSession => (_session ?? '').isNotEmpty;
  bool get hasApiAccessToken => (_apiAccessToken ?? '').isNotEmpty;
  bool get isLoggedIn => hasTelegramSession && hasApiAccessToken;

  Future<void> hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    _session = prefs.getString(kSessionKey);
    // Always force fresh server verification on each app launch.
    await prefs.remove(kApiAccessTokenKey);
    _apiAccessToken = null;
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

  Future<void> clearApiAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kApiAccessTokenKey);
    _apiAccessToken = null;
    notifyListeners();
  }

  Future<void> clearTelegramSession() async {
    await session_store.clearTelegramSession();
    await clearSession();
  }
}
