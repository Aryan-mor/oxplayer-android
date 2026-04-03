import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/local/telegram_session_store.dart' as session_store;

const kSessionKey = 'TELEGRAM_SESSION';
const kApiAccessTokenKey = 'TV_APP_API_ACCESS_TOKEN';
const kPreferredSubtitleLanguageKey = 'TV_APP_PREFERRED_SUBTITLE_LANGUAGE';
const kUserTypeKey = 'TV_APP_USER_TYPE';

/// Minimal session gate (parity with `localStorage` in `tv-app-old`).
class AuthNotifier extends ChangeNotifier {
  AuthNotifier() {
    hydrate();
  }

  bool _ready = false;
  String? _session;
  String? _apiAccessToken;
  String? _preferredSubtitleLanguage;
  /// Server [UserType]: DEFAULT, ADMIN, VIP (uppercase).
  String? _userType;
  String? _serverUserId;
  String? _serverTelegramId;
  String? _serverUsername;
  String? _serverFirstName;
  String? _phoneNumber;

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

  /// Full catalog / explore APIs (ADMIN and VIP only).
  bool get canAccessExplore {
    final t = _userType?.trim().toUpperCase();
    return t == 'ADMIN' || t == 'VIP';
  }

  bool get hasServerUserProfile =>
      (_serverUserId != null && _serverUserId!.isNotEmpty);

  /// True when the server account has no [phoneNumber] yet (prompt in TV app).
  bool get needsPhoneNumber {
    if (!hasServerUserProfile) return false;
    final p = _phoneNumber?.trim();
    return p == null || p.isEmpty;
  }

  String? get serverUserId => _serverUserId;
  String? get serverTelegramId => _serverTelegramId;
  String? get serverUsername => _serverUsername;
  String? get serverFirstName => _serverFirstName;
  String? get phoneNumber => _phoneNumber;

  Future<void> hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    _session = prefs.getString(kSessionKey);
    // Always force fresh server verification on each app launch.
    await prefs.remove(kApiAccessTokenKey);
    await prefs.remove(kUserTypeKey);
    _apiAccessToken = null;
    _userType = null;
    _clearServerProfileFields();
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
    await prefs.remove(kUserTypeKey);
    _session = null;
    _apiAccessToken = null;
    _preferredSubtitleLanguage = null;
    _userType = null;
    _clearServerProfileFields();
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
    await prefs.remove(kUserTypeKey);
    _apiAccessToken = null;
    _userType = null;
    _clearServerProfileFields();
    notifyListeners();
  }

  void _clearServerProfileFields() {
    _serverUserId = null;
    _serverTelegramId = null;
    _serverUsername = null;
    _serverFirstName = null;
    _phoneNumber = null;
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

  /// Persists role from POST [/auth/telegram] `user.userType` (DEFAULT | ADMIN | VIP).
  Future<void> syncUserTypeFromServer(String? serverValue) async {
    final raw = serverValue?.trim();
    final normalized =
        (raw == null || raw.isEmpty) ? 'DEFAULT' : raw.toUpperCase();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kUserTypeKey, normalized);
    _userType = normalized;
    notifyListeners();
  }

  /// Applies POST [/auth/telegram] `user` fields (subtitle / role use existing rules).
  Future<void> applyFromTelegramAuthResult({
    required String? userId,
    required String? telegramId,
    required String? username,
    required String? firstName,
    required String? phoneNumber,
    required String? preferredSubtitleLanguage,
    required String? userType,
  }) async {
    await syncPreferredSubtitleLanguageFromServer(preferredSubtitleLanguage);
    await syncUserTypeFromServer(userType);

    final id = userId?.trim();
    _serverUserId = (id != null && id.isNotEmpty) ? id : null;
    final tid = telegramId?.trim();
    _serverTelegramId = (tid != null && tid.isNotEmpty) ? tid : null;
    final u = username?.trim();
    _serverUsername = (u != null && u.isNotEmpty) ? u : null;
    final fn = firstName?.trim();
    _serverFirstName = (fn != null && fn.isNotEmpty) ? fn : null;
    final ph = phoneNumber?.trim();
    _phoneNumber = (ph != null && ph.isNotEmpty) ? ph : null;

    notifyListeners();
  }

  /// Overlays server `user` JSON on the local snapshot (e.g. after PATCH [/me/profile]).
  Future<void> mergeServerUserJson(Object? raw) async {
    if (raw is! Map) return;
    final m = Map<String, dynamic>.from(raw);

    if (m.containsKey('id')) {
      final v = m['id'];
      if (v == null) {
        _serverUserId = null;
      } else {
        final s = v.toString().trim();
        _serverUserId = s.isEmpty ? null : s;
      }
    }
    if (m.containsKey('telegramId')) {
      final v = m['telegramId'];
      if (v == null) {
        _serverTelegramId = null;
      } else {
        final s = v.toString().trim();
        _serverTelegramId = s.isEmpty ? null : s;
      }
    }
    if (m.containsKey('username')) {
      final v = m['username'];
      if (v == null) {
        _serverUsername = null;
      } else {
        final s = v.toString().trim();
        _serverUsername = s.isEmpty ? null : s;
      }
    }
    if (m.containsKey('firstName')) {
      final v = m['firstName'];
      if (v == null) {
        _serverFirstName = null;
      } else {
        final s = v.toString().trim();
        _serverFirstName = s.isEmpty ? null : s;
      }
    }
    if (m.containsKey('phoneNumber')) {
      final v = m['phoneNumber'];
      if (v == null) {
        _phoneNumber = null;
      } else {
        final s = v.toString().trim();
        _phoneNumber = s.isEmpty ? null : s;
      }
    }

    if (m.containsKey('preferredSubtitleLanguage')) {
      final v = m['preferredSubtitleLanguage'];
      if (v == null || v.toString().trim().isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(kPreferredSubtitleLanguageKey);
        _preferredSubtitleLanguage = null;
      } else {
        await syncPreferredSubtitleLanguageFromServer(v.toString());
      }
    }

    if (m.containsKey('userType')) {
      await syncUserTypeFromServer(m['userType']?.toString());
    }

    notifyListeners();
  }
}
