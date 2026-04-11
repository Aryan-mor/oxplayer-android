import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../infrastructure/data_repository.dart';
import '../services/auth_debug_service.dart';
import '../services/storage_service.dart';

const String kApiAccessTokenKey = 'OXPLAYER_API_ACCESS_TOKEN';
const String kPreferredSubtitleLanguageKey = 'OXPLAYER_PREFERRED_SUBTITLE_LANGUAGE';
const String kUserTypeKey = 'OXPLAYER_USER_TYPE';

const String _kServerUserJsonKey = 'OXPLAYER_SERVER_USER_JSON';
const String _kTelegramMarkerKey = 'OXPLAYER_TELEGRAM_SESSION_MARKER';

class AuthNotifier extends ChangeNotifier {
  AuthNotifier() {
    unawaited(_hydrate());
  }

  bool _ready = false;
  bool _hasTelegramSession = false;
  bool _telegramSessionValidatedInProcess = false;
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
  bool get telegramSessionValidatedInProcess => _telegramSessionValidatedInProcess;
  bool get isLoggedIn => (_apiAccessToken?.isNotEmpty ?? false);
  bool get hasPersistedSession => _hasTelegramSession || (_apiAccessToken?.isNotEmpty ?? false);
  String? get apiAccessToken => _apiAccessToken;
  String? get preferredSubtitleLanguage => _preferredSubtitleLanguage;

  Future<void> _hydrate() async {
    authDebugInfo('Hydrating auth state from local storage...');
    final storage = await StorageService.getInstance();
    final prefs = await SharedPreferences.getInstance();

    _apiAccessToken = storage.getApiAccessToken() ?? prefs.getString(kApiAccessTokenKey);
    _preferredSubtitleLanguage = prefs.getString(kPreferredSubtitleLanguageKey);
    _userType = prefs.getString(kUserTypeKey);

    final marker = prefs.getString(_kTelegramMarkerKey);
    _hasTelegramSession = marker != null && marker.isNotEmpty;
    _telegramSessionValidatedInProcess = false;
    authDebugDedup(
      'auth_notifier_hydrate_values',
      AuthDebugLevel.info,
      'Hydrated auth state: apiAccessToken=${_apiAccessToken != null && _apiAccessToken!.isNotEmpty}, telegramMarker=$_hasTelegramSession, userType=${_userType ?? 'none'}.',
    );

    final userRaw = prefs.getString(_kServerUserJsonKey);
    if (userRaw != null && userRaw.isNotEmpty) {
      try {
        _applyUserMap(jsonDecode(userRaw) as Map<String, dynamic>);
      } catch (_) {}
    }

    _ready = true;
    authDebugSuccess('Auth state hydration completed.');
    notifyListeners();
  }

  void _applyUserMap(Map<String, dynamic> userMap) {
    _userId = userMap['id']?.toString() ?? _userId;
    _telegramId = userMap['telegramId']?.toString() ?? _telegramId;
    _username = userMap['username']?.toString() ?? _username;
    _firstName = userMap['firstName']?.toString() ?? _firstName;
    _phoneNumber = userMap['phoneNumber']?.toString() ?? _phoneNumber;
    _userType = userMap['userType']?.toString() ?? _userType;
    _preferredSubtitleLanguage = userMap['preferredSubtitleLanguage']?.toString() ?? _preferredSubtitleLanguage;
  }

  Future<void> _persistUserJson() async {
    final prefs = await SharedPreferences.getInstance();
    final userMap = <String, dynamic>{
      if (_userId != null) 'id': _userId,
      if (_telegramId != null) 'telegramId': _telegramId,
      if (_username != null) 'username': _username,
      if (_firstName != null) 'firstName': _firstName,
      if (_phoneNumber != null) 'phoneNumber': _phoneNumber,
      if (_userType != null) 'userType': _userType,
      if (_preferredSubtitleLanguage != null) 'preferredSubtitleLanguage': _preferredSubtitleLanguage,
    };
    await prefs.setString(_kServerUserJsonKey, jsonEncode(userMap));
  }

  Future<void> setSession(String marker) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTelegramMarkerKey, marker);
    _hasTelegramSession = true;
    _telegramSessionValidatedInProcess = true;
    authDebugSuccess('Telegram session marker saved locally.');
    notifyListeners();
  }

  Future<void> setApiAccessToken(String token) async {
    final storage = await StorageService.getInstance();
    final prefs = await SharedPreferences.getInstance();
    _apiAccessToken = token;
    await storage.saveApiAccessToken(token);
    await prefs.setString(kApiAccessTokenKey, token);
    authDebugSuccess('Backend access token saved to local storage.');
    notifyListeners();
  }

  Future<void> persistTelegramBackendSession(TelegramAuthResult result) async {
    authDebugInfo('Persisting backend session to local storage...');
    final storage = await StorageService.getInstance();
    final prefs = await SharedPreferences.getInstance();

    final marker = 'tdlib:${result.telegramId ?? result.userId ?? 'authenticated'}';
    _hasTelegramSession = true;
    _telegramSessionValidatedInProcess = true;
    _apiAccessToken = result.accessToken;
    await prefs.setString(_kTelegramMarkerKey, marker);
    await storage.saveApiAccessToken(result.accessToken);
    await prefs.setString(kApiAccessTokenKey, result.accessToken);

    if (result.userId != null) _userId = result.userId;
    if (result.telegramId != null) _telegramId = result.telegramId;
    if (result.username != null) _username = result.username;
    if (result.firstName != null) _firstName = result.firstName;
    if (result.phoneNumber != null) _phoneNumber = result.phoneNumber;
    if (result.preferredSubtitleLanguage != null && result.preferredSubtitleLanguage!.isNotEmpty) {
      _preferredSubtitleLanguage = result.preferredSubtitleLanguage;
      await prefs.setString(kPreferredSubtitleLanguageKey, _preferredSubtitleLanguage!);
    }
    if (result.userType != null && result.userType!.isNotEmpty) {
      _userType = result.userType;
      await prefs.setString(kUserTypeKey, _userType!);
    }

    await _persistUserJson();
    authDebugSuccess('Backend session persisted to local storage.', completeStatus: AuthDebugStatusKey.backendSessionStored);
    notifyListeners();
  }

  void markTelegramSessionValidatedInProcess() {
    if (_telegramSessionValidatedInProcess) return;
    _telegramSessionValidatedInProcess = true;
    notifyListeners();
  }

  Future<void> applyFromTelegramAuthResult(TelegramAuthResult result) async {
    if (result.userId != null) _userId = result.userId;
    if (result.telegramId != null) _telegramId = result.telegramId;
    if (result.username != null) _username = result.username;
    if (result.firstName != null) _firstName = result.firstName;
    if (result.phoneNumber != null) _phoneNumber = result.phoneNumber;
    if (result.preferredSubtitleLanguage != null && result.preferredSubtitleLanguage!.isNotEmpty) {
      _preferredSubtitleLanguage = result.preferredSubtitleLanguage;
    }
    if (result.userType != null && result.userType!.isNotEmpty) {
      _userType = result.userType;
    }

    final prefs = await SharedPreferences.getInstance();
    if (_preferredSubtitleLanguage != null) {
      await prefs.setString(kPreferredSubtitleLanguageKey, _preferredSubtitleLanguage!);
    }
    if (_userType != null) {
      await prefs.setString(kUserTypeKey, _userType!);
    }
    await _persistUserJson();
    notifyListeners();
  }

  Future<void> clearSession() async {
    final storage = await StorageService.getInstance();
    final prefs = await SharedPreferences.getInstance();

    await storage.clearApiAccessToken();
    await prefs.remove(kApiAccessTokenKey);
    await prefs.remove(_kTelegramMarkerKey);
    await prefs.remove(_kServerUserJsonKey);
    await prefs.remove(kPreferredSubtitleLanguageKey);
    await prefs.remove(kUserTypeKey);

    _apiAccessToken = null;
    _hasTelegramSession = false;
    _telegramSessionValidatedInProcess = false;
    _preferredSubtitleLanguage = null;
    _userType = null;
    _userId = null;
    _telegramId = null;
    _username = null;
    _firstName = null;
    _phoneNumber = null;
    notifyListeners();
  }
}
