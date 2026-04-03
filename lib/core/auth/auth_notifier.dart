import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/local/telegram_session_store.dart' as session_store;

const kSessionKey = 'TELEGRAM_SESSION';
const kApiAccessTokenKey = 'TV_APP_API_ACCESS_TOKEN';
const kPreferredSubtitleLanguageKey = 'TV_APP_PREFERRED_SUBTITLE_LANGUAGE';

/// Minimal session gate (parity with `localStorage` in `tv-app-old`).
class AuthNotifier extends ChangeNotifier {
  AuthNotifier() {
    hydrate();
  }

  bool _ready = false;
  String? _session;
  String? _apiAccessToken;
  String? _preferredSubtitleLanguage;

  bool get ready => _ready;
  String? get session => _session;
  String? get apiAccessToken => _apiAccessToken;
  /// SubDL language code (e.g. EN, FA); null if unset.
  ///
  /// **Source of truth (no per-playback network call):**
  /// - Loaded from [SharedPreferences] in [hydrate] when the app starts.
  /// - After Telegram auth completes, updated only if the auth JSON includes a
  ///   non-empty `preferredSubtitleLanguage` ([syncPreferredSubtitleLanguageFromServer]).
  /// - After subtitle search on Android, native code may PATCH then hand off here via [setPreferredSubtitleLanguage].
  /// The internal player receives this only as MethodChannel intent extras; it does not load this field from the API.
  String? get preferredSubtitleLanguage => _preferredSubtitleLanguage;
  bool get hasTelegramSession => (_session ?? '').isNotEmpty;
  bool get hasApiAccessToken => (_apiAccessToken ?? '').isNotEmpty;
  bool get isLoggedIn => hasTelegramSession && hasApiAccessToken;

  Future<void> hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    _session = prefs.getString(kSessionKey);
    // Always force fresh server verification on each app launch.
    await prefs.remove(kApiAccessTokenKey);
    _apiAccessToken = null;
    final subLang = prefs.getString(kPreferredSubtitleLanguageKey)?.trim();
    _preferredSubtitleLanguage =
        (subLang != null && subLang.isNotEmpty) ? subLang : null;
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
    await prefs.remove(kPreferredSubtitleLanguageKey);
    _session = null;
    _apiAccessToken = null;
    _preferredSubtitleLanguage = null;
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

  /// Persists and notifies. Use for native handoff or local-only updates.
  Future<void> setPreferredSubtitleLanguage(String code) async {
    final prefs = await SharedPreferences.getInstance();
    final t = code.trim();
    if (t.isEmpty) {
      await prefs.remove(kPreferredSubtitleLanguageKey);
      _preferredSubtitleLanguage = null;
    } else {
      await prefs.setString(kPreferredSubtitleLanguageKey, t);
      _preferredSubtitleLanguage = t;
    }
    notifyListeners();
  }

  /// Applies a non-empty value from the Telegram auth response.
  ///
  /// If the server omits the field or sends null/empty, **local storage is left unchanged**
  /// so a preference set from the internal player (PATCH + handoff) is not wiped on every re-auth.
  Future<void> syncPreferredSubtitleLanguageFromServer(String? serverValue) async {
    final v = serverValue?.trim();
    if (v == null || v.isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPreferredSubtitleLanguageKey, v);
    _preferredSubtitleLanguage = v;
    notifyListeners();
  }
}
