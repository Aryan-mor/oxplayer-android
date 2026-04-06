import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/local/telegram_session_store.dart' as telegram_session;

const kApiAccessTokenKey = 'OXPLAYER_API_ACCESS_TOKEN';
const kPreferredSubtitleLanguageKey = 'OXPLAYER_PREFERRED_SUBTITLE_LANGUAGE';
const kUserTypeKey = 'OXPLAYER_USER_TYPE';

const _kServerUserJsonKey = 'OXPLAYER_SERVER_USER_JSON';
const _kTelegramMarkerKey = 'OXPLAYER_TELEGRAM_SESSION_MARKER';

/// Disk-backed session and server user profile (SharedPreferences).
class AuthNotifier extends ChangeNotifier {
  AuthNotifier() {
    unawaited(_hydrate());
  }

  bool _ready = false;
  bool _hasTelegramSession = false;
  String? _apiAccessToken;
  String? _preferredSubtitleLanguage;
  String? _userType;
  String? _userId;
  String? _telegramId;
  String? _username;
  String? _firstName;
  String? _phoneNumber;

  bool get ready => _ready;
  bool get hasTelegramSession => _hasTelegramSession;
  bool get isLoggedIn => _hasTelegramSession;

  String? get apiAccessToken => _apiAccessToken;
  String? get preferredSubtitleLanguage => _preferredSubtitleLanguage;

  bool get canAccessExplore {
    final t = (_userType ?? '').toUpperCase();
    return t == 'ADMIN' || t == 'VIP';
  }

  bool get hasServerUserProfile =>
      _userId != null && _userId!.trim().isNotEmpty;

  Future<void> _hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    await _migrateLegacyTvAppKeys(prefs);
    _apiAccessToken = prefs.getString(kApiAccessTokenKey);
    _preferredSubtitleLanguage =
        prefs.getString(kPreferredSubtitleLanguageKey);
    _userType = prefs.getString(kUserTypeKey);

    final marker = prefs.getString(_kTelegramMarkerKey);
    final tgRaw = prefs.getString('telegram_session');
    _hasTelegramSession = (marker != null && marker.isNotEmpty) ||
        (tgRaw != null && tgRaw.isNotEmpty);

    final userRaw = prefs.getString(_kServerUserJsonKey);
    if (userRaw != null && userRaw.isNotEmpty) {
      try {
        final m = jsonDecode(userRaw) as Map<String, dynamic>;
        _applyUserMap(m, persist: false);
      } catch (_) {}
    }

    _ready = true;
    notifyListeners();
  }

  /// One-time rename from pre-Oxplayer env/prefs naming (`TV_APP_*`).
  Future<void> _migrateLegacyTvAppKeys(SharedPreferences prefs) async {
    Future<void> moveKey(String oldKey, String newKey) async {
      final v = prefs.getString(oldKey);
      if (v == null || v.isEmpty) return;
      if (prefs.getString(newKey) != null && prefs.getString(newKey)!.isNotEmpty) {
        await prefs.remove(oldKey);
        return;
      }
      await prefs.setString(newKey, v);
      await prefs.remove(oldKey);
    }

    await moveKey('TV_APP_API_ACCESS_TOKEN', kApiAccessTokenKey);
    await moveKey(
      'TV_APP_PREFERRED_SUBTITLE_LANGUAGE',
      kPreferredSubtitleLanguageKey,
    );
    await moveKey('TV_APP_USER_TYPE', kUserTypeKey);
  }

  void _applyUserMap(Map<String, dynamic> m, {required bool persist}) {
    final id = m['id']?.toString();
    if (id != null) _userId = id;
    final tid = m['telegramId']?.toString();
    if (tid != null) _telegramId = tid;
    final u = m['username']?.toString();
    if (u != null) _username = u;
    final fn = m['firstName']?.toString();
    if (fn != null) _firstName = fn;
    final ph = m['phoneNumber']?.toString();
    if (ph != null) _phoneNumber = ph;
    final ut = m['userType']?.toString();
    if (ut != null && ut.isNotEmpty) _userType = ut;
    final pl = m['preferredSubtitleLanguage']?.toString();
    if (pl != null && pl.isNotEmpty) _preferredSubtitleLanguage = pl;
    if (persist) unawaited(_persistUserJson());
  }

  Future<void> _persistUserJson() async {
    final prefs = await SharedPreferences.getInstance();
    final m = <String, dynamic>{
      if (_userId != null) 'id': _userId,
      if (_telegramId != null) 'telegramId': _telegramId,
      if (_username != null) 'username': _username,
      if (_firstName != null) 'firstName': _firstName,
      if (_phoneNumber != null) 'phoneNumber': _phoneNumber,
      if (_userType != null) 'userType': _userType,
      if (_preferredSubtitleLanguage != null)
        'preferredSubtitleLanguage': _preferredSubtitleLanguage,
    };
    await prefs.setString(_kServerUserJsonKey, jsonEncode(m));
  }

  Future<void> setSession(String marker) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTelegramMarkerKey, marker);
    _hasTelegramSession = true;
    notifyListeners();
  }

  Future<void> clearTelegramSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kTelegramMarkerKey);
    await telegram_session.clearTelegramSession();
    _hasTelegramSession = false;
    notifyListeners();
  }

  Future<void> setApiAccessToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    _apiAccessToken = token;
    await prefs.setString(kApiAccessTokenKey, token);
    notifyListeners();
  }

  Future<void> clearApiAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    _apiAccessToken = null;
    await prefs.remove(kApiAccessTokenKey);
    notifyListeners();
  }

  Future<void> clearSession() async {
    await clearApiAccessToken();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kServerUserJsonKey);
    await prefs.remove(kUserTypeKey);
    await prefs.remove(kPreferredSubtitleLanguageKey);
    _userId = null;
    _telegramId = null;
    _username = null;
    _firstName = null;
    _phoneNumber = null;
    _userType = null;
    _preferredSubtitleLanguage = null;
    await clearTelegramSession();
    notifyListeners();
  }

  Future<void> applyFromTelegramAuthResult({
    String? userId,
    String? telegramId,
    String? username,
    String? firstName,
    String? phoneNumber,
    String? preferredSubtitleLanguage,
    String? userType,
  }) async {
    if (userId != null) _userId = userId;
    if (telegramId != null) _telegramId = telegramId;
    if (username != null) _username = username;
    if (firstName != null) _firstName = firstName;
    if (phoneNumber != null) _phoneNumber = phoneNumber;
    if (preferredSubtitleLanguage != null) {
      _preferredSubtitleLanguage = preferredSubtitleLanguage;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kPreferredSubtitleLanguageKey,
        preferredSubtitleLanguage,
      );
    }
    if (userType != null && userType.isNotEmpty) {
      _userType = userType;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kUserTypeKey, userType);
    }
    await _persistUserJson();
    notifyListeners();
  }

  Future<void> mergeServerUserJson(Map<String, dynamic> userMap) async {
    _applyUserMap(userMap, persist: true);
    final prefs = await SharedPreferences.getInstance();
    final ut = userMap['userType']?.toString();
    if (ut != null && ut.isNotEmpty) {
      _userType = ut;
      await prefs.setString(kUserTypeKey, ut);
    }
    final pl = userMap['preferredSubtitleLanguage']?.toString();
    if (pl != null && pl.isNotEmpty) {
      _preferredSubtitleLanguage = pl;
      await prefs.setString(kPreferredSubtitleLanguageKey, pl);
    }
    notifyListeners();
  }

  Future<void> setPreferredSubtitleLanguage(String code) async {
    _preferredSubtitleLanguage = code;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPreferredSubtitleLanguageKey, code);
    notifyListeners();
  }
}
