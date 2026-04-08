import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tdlib/td_api.dart' as td;

import '../services/storage_service.dart';
import 'config/app_config.dart';
import 'telegram/tdlib_controller.dart'
    if (dart.library.html) 'telegram/tdlib_controller_web.dart';
import 'telegram/tdlib_facade.dart';

class TelegramAuthResult {
  const TelegramAuthResult({
    required this.accessToken,
    this.userId,
    this.telegramId,
    this.username,
    this.firstName,
    this.phoneNumber,
    this.preferredSubtitleLanguage,
    this.userType,
  });

  final String accessToken;
  final String? userId;
  final String? telegramId;
  final String? username;
  final String? firstName;
  final String? phoneNumber;
  final String? preferredSubtitleLanguage;
  final String? userType;
}

class DataRepository {
  DataRepository._({
    required AppConfig config,
    required StorageService storage,
    required TdlibFacade tdlib,
  })  : _config = config,
        _storage = storage,
        _tdlib = tdlib;

  static const String _kApiDeviceIdPrefsKey = 'oxplayer_api_device_id';
  static const String _kDefaultDeviceName = 'OXPlayer Android';

  final AppConfig _config;
  final StorageService _storage;
  final TdlibFacade _tdlib;

  bool _tdlibInitialized = false;

  static Future<DataRepository> create() async {
    final config = await AppConfig.load();
    final storage = await StorageService.getInstance();
    await TelegramTdlibFacade.initTdlibPlugin();
    final tdlib = TelegramTdlibFacade();
    return DataRepository._(config: config, storage: storage, tdlib: tdlib);
  }

  AppConfig get config => _config;

  Stream<String?> get qrLoginPayload => _tdlib.qrLoginPayload;

  Stream<TdlibCloudPasswordChallenge?> get cloudPasswordChallenge => _tdlib.cloudPasswordChallenge;

  Stream<TdlibSmsCodeChallenge?> get smsCodeChallenge => _tdlib.smsCodeChallenge;

  Stream<bool> get authorizationWaitPhoneNumber => _tdlib.authorizationWaitPhoneNumber;

  Stream<int> get authenticatedUserId => _tdlib.authenticatedUserId;

  Stream<String?> get functionErrors => _tdlib.functionErrors;

  Future<void> waitForLoginMethodChoice() {
    return authorizationWaitPhoneNumber.firstWhere((value) => value);
  }

  Future<TelegramAuthResult> loginWithTelegram() async {
    if (kIsWeb) {
      throw UnsupportedError('Telegram sign-in is not available on web builds.');
    }

    final apiId = int.tryParse(_config.telegramApiId) ?? 0;
    if (!_config.hasTelegramKeys || apiId <= 0) {
      throw StateError('Set TELEGRAM_API_ID and TELEGRAM_API_HASH in assets/env/default.env');
    }
    if (!_config.hasApiConfig) {
      throw StateError(
        'Set OXPLAYER_API_BASE_URL and OXPLAYER_TELEGRAM_WEBAPP_SHORT_NAME or OXPLAYER_TELEGRAM_WEBAPP_URL in assets/env/default.env',
      );
    }

    await _ensureTdlibInitialized(apiId: apiId);

    try {
      await _tdlib.ensureAuthorized();
    } on TdlibInteractiveLoginRequired {
      await _tdlib.authenticatedUserId.first;
    }

    final result = await _authenticateWithTelegram();
    await _storage.saveApiAccessToken(result.accessToken);
    return result;
  }

  Future<void> startQrLogin() => _tdlib.startQrLogin();

  Future<void> submitCloudPassword(String password) => _tdlib.submitCloudPassword(password);

  Future<void> submitAuthenticationPhoneNumber(String phoneNumber) =>
      _tdlib.submitAuthenticationPhoneNumber(phoneNumber);

  Future<void> submitAuthenticationCode(String code) => _tdlib.submitAuthenticationCode(code);

  Future<void> resetLocalSessionForQrLogin() async {
    await _tdlib.resetLocalSessionForQrLogin();
    _tdlibInitialized = false;
  }

  Future<void> dispose() => _tdlib.dispose();

  Future<void> _ensureTdlibInitialized({required int apiId}) async {
    if (_tdlibInitialized && _tdlib.isInitialized) {
      return;
    }
    await _tdlib.init(
      apiId: apiId,
      apiHash: _config.telegramApiHash,
      sessionString: '',
    );
    _tdlibInitialized = true;
  }

  Future<TelegramAuthResult> _authenticateWithTelegram() async {
    final initData = await _fetchSignedInitData();
    final identity = await _resolveDeviceIdentity();
    final dio = Dio(BaseOptions(baseUrl: _config.apiBaseUrl));
    final response = await dio.post<Map<String, dynamic>>(
      '/auth/telegram',
      data: <String, dynamic>{
        'initData': initData,
        'deviceId': identity.deviceId,
        if (identity.deviceName != null) 'deviceName': identity.deviceName,
      },
    );

    final accessToken = response.data?['accessToken']?.toString() ?? '';
    if (accessToken.isEmpty) {
      throw StateError('API did not return accessToken');
    }

    String? preferredSubtitleLanguage;
    String? userType;
    String? userId;
    String? telegramId;
    String? username;
    String? firstName;
    String? phoneNumber;
    final userRaw = response.data?['user'];
    if (userRaw is Map) {
      final userMap = Map<String, dynamic>.from(userRaw);
      preferredSubtitleLanguage = _readOptionalTrimmed(userMap['preferredSubtitleLanguage']);
      userType = _readOptionalTrimmed(userMap['userType']);
      userId = _readOptionalTrimmed(userMap['id']);
      telegramId = _readOptionalTrimmed(userMap['telegramId']);
      username = _readOptionalTrimmed(userMap['username']);
      firstName = _readOptionalTrimmed(userMap['firstName']);
      phoneNumber = _readOptionalTrimmed(userMap['phoneNumber']);
    }

    return TelegramAuthResult(
      accessToken: accessToken,
      userId: userId,
      telegramId: telegramId,
      username: username,
      firstName: firstName,
      phoneNumber: phoneNumber,
      preferredSubtitleLanguage: preferredSubtitleLanguage,
      userType: userType,
    );
  }

  Future<String> _fetchSignedInitData() async {
    await _tdlib.ensureAuthorized();
    final resolved = await _tdlib.send(
      td.SearchPublicChat(username: _config.botUsername),
    );
    if (resolved is! td.Chat || resolved.type is! td.ChatTypePrivate) {
      throw StateError('Cannot resolve BOT_USERNAME to a private chat');
    }

    final botUserId = (resolved.type as td.ChatTypePrivate).userId;
    final privateChat = await _tdlib.send(
      td.CreatePrivateChat(userId: botUserId, force: false),
    );
    if (privateChat is! td.Chat) {
      throw StateError('Failed to create private chat with bot');
    }

    String? webAppUrl;
    td.TdError? shortNameError;

    if (_config.telegramWebAppShortName.isNotEmpty) {
      try {
        final result = await _tdlib.send(
          td.GetWebAppLinkUrl(
            chatId: privateChat.id,
            botUserId: botUserId,
            webAppShortName: _config.telegramWebAppShortName,
            startParameter: '',
            theme: null,
            applicationName: 'oxplayer',
            allowWriteAccess: true,
          ),
        );
        if (result is td.HttpUrl) {
          webAppUrl = result.url;
        }
      } catch (error) {
        if (error is td.TdError) {
          shortNameError = error;
        }
      }
    }

    if (webAppUrl == null && _config.telegramWebAppUrl.isNotEmpty) {
      final fallbackResult = await _tdlib.send(
        td.GetWebAppUrl(
          botUserId: botUserId,
          url: _config.telegramWebAppUrl,
          theme: null,
          applicationName: 'oxplayer',
        ),
      );
      if (fallbackResult is td.HttpUrl) {
        webAppUrl = fallbackResult.url;
      }
    }

    if (webAppUrl == null) {
      if (shortNameError != null) {
        throw StateError(
          'WebApp initData failed (${shortNameError.message}). Configure OXPLAYER_TELEGRAM_WEBAPP_SHORT_NAME or OXPLAYER_TELEGRAM_WEBAPP_URL.',
        );
      }
      throw StateError(
        'Cannot get WebApp URL. Configure OXPLAYER_TELEGRAM_WEBAPP_SHORT_NAME or OXPLAYER_TELEGRAM_WEBAPP_URL in assets/env/default.env.',
      );
    }

    final initData = _extractTgWebAppData(webAppUrl);
    if (initData == null || initData.isEmpty) {
      throw StateError('tgWebAppData not found in web app URL');
    }
    return initData;
  }

  String? _extractTgWebAppData(String webAppUrl) {
    final uri = Uri.tryParse(webAppUrl);
    if (uri == null) return null;

    final fromQuery = _extractQueryParamRaw(query: uri.query, key: 'tgWebAppData');
    if (fromQuery != null && fromQuery.isNotEmpty) {
      return fromQuery;
    }

    final fragment = uri.fragment;
    if (fragment.isNotEmpty) {
      final queryFromFragment = fragment.contains('?')
          ? fragment.substring(fragment.indexOf('?') + 1)
          : fragment;
      final fromFragment = _extractQueryParamRaw(query: queryFromFragment, key: 'tgWebAppData');
      if (fromFragment != null && fromFragment.isNotEmpty) {
        return fromFragment;
      }
    }

    return null;
  }

  String? _extractQueryParamRaw({required String query, required String key}) {
    if (query.isEmpty) return null;
    for (final pair in query.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      final rawKey = eq >= 0 ? pair.substring(0, eq) : pair;
      final decodedKey = _decodeComponentSafe(rawKey);
      if (decodedKey != key) continue;
      final rawValue = eq >= 0 ? pair.substring(eq + 1) : '';
      return _decodeComponentSafe(rawValue);
    }
    return null;
  }

  String _decodeComponentSafe(String input) {
    if (input.isEmpty) return input;
    try {
      return Uri.decodeComponent(input);
    } catch (_) {
      return input;
    }
  }

  Future<_ApiDeviceIdentity> _resolveDeviceIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    var storedId = prefs.getString(_kApiDeviceIdPrefsKey)?.trim() ?? '';
    if (storedId.isEmpty) {
      storedId = _generateDeviceId();
      await prefs.setString(_kApiDeviceIdPrefsKey, storedId);
    }
    return _ApiDeviceIdentity(
      deviceId: storedId,
      deviceName: _kDefaultDeviceName,
    );
  }

  String _generateDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return 'oxa-$hex';
  }

  String? _readOptionalTrimmed(Object? raw) {
    final text = raw?.toString().trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    return text;
  }
}

class _ApiDeviceIdentity {
  const _ApiDeviceIdentity({
    required this.deviceId,
    required this.deviceName,
  });

  final String deviceId;
  final String? deviceName;
}