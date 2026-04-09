import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tdlib/td_api.dart' as td;
import 'package:video_thumbnail/video_thumbnail.dart';

export 'telegram/tdlib_facade.dart' show TdlibCloudPasswordChallenge, TdlibInteractiveLoginRequired, TdlibSmsCodeChallenge;

import '../services/storage_service.dart';
import '../services/auth_debug_service.dart';
import 'config/app_config.dart';
import 'telegram/media_file_locator_resolver.dart';
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

class OxBootstrapUnauthorized implements Exception {
  const OxBootstrapUnauthorized();

  @override
  String toString() => 'Saved OXPlayer access token is no longer valid.';
}

class OxBootstrapUser {
  const OxBootstrapUser({
    required this.id,
    required this.telegramId,
    required this.username,
    required this.firstName,
    required this.preferredSubtitleLanguage,
    required this.userType,
  });

  final String id;
  final String telegramId;
  final String? username;
  final String? firstName;
  final String? preferredSubtitleLanguage;
  final String userType;
}

class OxBootstrapSession {
  const OxBootstrapSession({
    required this.deviceId,
    required this.deviceName,
    required this.expiresAt,
  });

  final String deviceId;
  final String? deviceName;
  final DateTime expiresAt;
}

class OxBootstrapCapabilities {
  const OxBootstrapCapabilities({
    required this.hasIndexedChats,
    required this.indexedChatCount,
    required this.hasLibraryMedia,
    required this.libraryItemCount,
  });

  final bool hasIndexedChats;
  final int indexedChatCount;
  final bool hasLibraryMedia;
  final int libraryItemCount;
}

class OxBootstrapResult {
  const OxBootstrapResult({
    required this.telegramReady,
    required this.user,
    required this.session,
    required this.capabilities,
  });

  final bool telegramReady;
  final OxBootstrapUser user;
  final OxBootstrapSession session;
  final OxBootstrapCapabilities capabilities;
}

class OxLibraryMediaItem {
  const OxLibraryMediaItem({
    required this.kind,
    required this.globalId,
    required this.title,
    required this.createdAt,
    this.fileUniqueId,
    required this.posterPath,
    required this.overview,
    required this.voteAverage,
    this.locatorType,
    this.locatorChatId,
    this.locatorMessageId,
    this.locatorBotUsername,
    this.locatorRemoteFileId,
    this.verificationStatus,
    this.thumbnailSourceChatId,
    this.thumbnailSourceMessageId,
  });

  final String kind;
  final String globalId;
  final String title;
  final DateTime createdAt;
  final String? fileUniqueId;
  final String? posterPath;
  final String? overview;
  final double? voteAverage;
  final String? locatorType;
  final int? locatorChatId;
  final int? locatorMessageId;
  final String? locatorBotUsername;
  final String? locatorRemoteFileId;
  final String? verificationStatus;
  /// For general_video: Telegram chat ID of the source message (for thumbnail resolution via TDLib).
  final int? thumbnailSourceChatId;
  /// For general_video: Telegram message ID of the source message (for thumbnail resolution via TDLib).
  final int? thumbnailSourceMessageId;
}

class OxDiscoverSection {
  const OxDiscoverSection({
    required this.id,
    required this.title,
    required this.items,
  });

  final String id;
  final String title;
  final List<OxLibraryMediaItem> items;
}

class _ThumbnailMessageLookupResult {
  const _ThumbnailMessageLookupResult({
    required this.message,
    this.failureReason,
    this.resolvedChatId,
    this.resolvedMessageId,
  });

  final td.Message? message;
  final String? failureReason;
  final int? resolvedChatId;
  final int? resolvedMessageId;
}

class _VerifiedLocatorResult {
  const _VerifiedLocatorResult({
    required this.locatorType,
    required this.locatorMessageId,
    this.locatorChatId,
    this.locatorBotUsername,
  });

  final String locatorType;
  final int locatorMessageId;
  final int? locatorChatId;
  final String? locatorBotUsername;
}

class DataRepository {
  static const MethodChannel _mediaToolsChannel =
      MethodChannel('de.aryanmo.oxplayer/media_tools');

  DataRepository._({
    required AppConfig config,
    required StorageService storage,
    required TdlibFacade tdlib,
  })  : _config = config,
        _storage = storage,
        _tdlib = tdlib;

  static const String _kApiDeviceIdPrefsKey = 'oxplayer_api_device_id';
  static const String _kDefaultDeviceName = 'OXPlayer Android';
  static Future<DataRepository>? _sharedCreateFuture;

  final AppConfig _config;
  final StorageService _storage;
  final TdlibFacade _tdlib;

  bool _tdlibInitialized = false;
  bool _locatorVerifySyncInFlight = false;
  DateTime? _lastLocatorVerifySyncAt;
  final Set<String> _thumbnailRecoveryInFlight = <String>{};
  final Map<String, DateTime> _lastThumbnailRecoveryRequestAt = <String, DateTime>{};

  static Future<DataRepository> create() async {
    final existing = _sharedCreateFuture;
    if (existing != null) {
      return existing;
    }

    final completer = Completer<DataRepository>();
    _sharedCreateFuture = completer.future;

    try {
      final config = await AppConfig.load();
      final storage = await StorageService.getInstance();
      await TelegramTdlibFacade.initTdlibPlugin();
      final tdlib = TelegramTdlibFacade();
      final repository = DataRepository._(config: config, storage: storage, tdlib: tdlib);
      completer.complete(repository);
      return repository;
    } catch (error, stackTrace) {
      _sharedCreateFuture = null;
      completer.completeError(error, stackTrace);
      rethrow;
    }
  }

  AppConfig get config => _config;

  Stream<String?> get qrLoginPayload => _tdlib.qrLoginPayload;

  Stream<TdlibCloudPasswordChallenge?> get cloudPasswordChallenge => _tdlib.cloudPasswordChallenge;

  Stream<TdlibSmsCodeChallenge?> get smsCodeChallenge => _tdlib.smsCodeChallenge;

  Stream<bool> get authorizationWaitPhoneNumber => _tdlib.authorizationWaitPhoneNumber;

  Stream<int> get authenticatedUserId => _tdlib.authenticatedUserId;

  Stream<String?> get functionErrors => _tdlib.functionErrors;

  Future<bool> tryRestoreExistingTelegramSession() async {
    authDebugInfo('Checking for an existing Telegram session...');
    if (kIsWeb) {
      return false;
    }

    final apiId = int.tryParse(_config.telegramApiId) ?? 0;
    if (!_config.hasTelegramKeys || apiId <= 0 || !_config.hasApiConfig) {
      return false;
    }

    await _ensureTdlibInitialized(apiId: apiId);
    authDebugInfo('TDLib initialized. Attempting silent authorization restore...');

    try {
      await _tdlib.ensureAuthorized();
      authDebugSuccess(
        'Existing Telegram session restored from local TDLib storage.',
        completeStatus: AuthDebugStatusKey.telegramSessionDetected,
      );
      authDebugSetStatus(AuthDebugStatusKey.telegramAuthenticated, true);
      return true;
    } on TdlibInteractiveLoginRequired {
      authDebugInfo('No reusable Telegram session was found.');
      return false;
    } catch (error) {
      authDebugError('Silent Telegram session restore failed: $error');
      return false;
    }
  }

  Future<void> beginTelegramAuthorization() async {
    authDebugInfo('Starting Telegram authorization...', completeStatus: AuthDebugStatusKey.telegramAuthorizationStarted);
    if (kIsWeb) {
      authDebugError('Telegram sign-in is not available on web builds.');
      throw UnsupportedError('Telegram sign-in is not available on web builds.');
    }

    final apiId = int.tryParse(_config.telegramApiId) ?? 0;
    if (!_config.hasTelegramKeys || apiId <= 0) {
      authDebugError('Telegram API keys are missing in env configuration.');
      throw StateError('Set TELEGRAM_API_ID and TELEGRAM_API_HASH in assets/env/default.env');
    }
    if (!_config.hasApiConfig) {
      authDebugError('OXPlayer API configuration is missing in env configuration.');
      throw StateError(
        'Set OXPLAYER_API_BASE_URL and OXPLAYER_TELEGRAM_WEBAPP_SHORT_NAME or OXPLAYER_TELEGRAM_WEBAPP_URL in assets/env/default.env',
      );
    }

    await _ensureTdlibInitialized(apiId: apiId);

    try {
      await _tdlib.ensureAuthorized();
    } on TdlibInteractiveLoginRequired {
      authDebugInfo('Telegram requires interactive login. Waiting for user action...');
      await _tdlib.authenticatedUserId.first;
    }

    authDebugSuccess('Telegram authorization finished.', completeStatus: AuthDebugStatusKey.telegramAuthenticated);
  }

  Future<TelegramAuthResult> loginWithTelegram() async {
    await beginTelegramAuthorization();
    final result = await authenticateWithTelegram();
    return result;
  }

  Future<TelegramAuthResult> authenticateWithTelegram() async {
    authDebugInfo('Preparing Telegram initData for backend authentication...');
    final result = await _authenticateWithTelegram();
    await _storage.saveApiAccessToken(result.accessToken);
    authDebugSuccess('Backend access token stored locally.', completeStatus: AuthDebugStatusKey.backendSessionStored);
    return result;
  }

  Future<OxBootstrapResult> bootstrapConnectedSession({required bool requireTelegramSession}) async {
    final accessToken = _storage.getApiAccessToken()?.trim() ?? '';
    if (accessToken.isEmpty) {
      throw const OxBootstrapUnauthorized();
    }

    var telegramReady = true;
    if (requireTelegramSession) {
      authDebugInfo('Validating local Telegram session for app bootstrap...');
      telegramReady = await tryRestoreExistingTelegramSession();
      if (!telegramReady) {
        authDebugError('Saved Telegram session is not available for bootstrap.');
        throw const TdlibInteractiveLoginRequired();
      }
    }

    authDebugInfo('Requesting OXPlayer bootstrap session...');
    final dio = Dio(
      BaseOptions(
        baseUrl: _config.apiBaseUrl,
        headers: <String, String>{'Authorization': 'Bearer $accessToken'},
      ),
    );

    Response<Map<String, dynamic>> response;
    try {
      response = await dio.get<Map<String, dynamic>>('/me/bootstrap');
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        authDebugError('OXPlayer bootstrap rejected the saved access token.');
        throw const OxBootstrapUnauthorized();
      }
      authDebugError('OXPlayer bootstrap request failed: $error');
      rethrow;
    }

    final data = response.data ?? <String, dynamic>{};
    final user = Map<String, dynamic>.from(data['user'] as Map? ?? <String, dynamic>{});
    final session = Map<String, dynamic>.from(data['session'] as Map? ?? <String, dynamic>{});
    final capabilities = Map<String, dynamic>.from(data['capabilities'] as Map? ?? <String, dynamic>{});

    authDebugSuccess('OXPlayer bootstrap session validated.');

    return OxBootstrapResult(
      telegramReady: telegramReady,
      user: OxBootstrapUser(
        id: user['id']?.toString() ?? '',
        telegramId: user['telegramId']?.toString() ?? '',
        username: _readOptionalTrimmed(user['username']),
        firstName: _readOptionalTrimmed(user['firstName']),
        preferredSubtitleLanguage: _readOptionalTrimmed(user['preferredSubtitleLanguage']),
        userType: user['userType']?.toString() ?? 'DEFAULT',
      ),
      session: OxBootstrapSession(
        deviceId: session['deviceId']?.toString() ?? '',
        deviceName: _readOptionalTrimmed(session['deviceName']),
        expiresAt: DateTime.tryParse(session['expiresAt']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      ),
      capabilities: OxBootstrapCapabilities(
        hasIndexedChats: capabilities['hasIndexedChats'] == true,
        indexedChatCount: (capabilities['indexedChatCount'] as num?)?.toInt() ?? 0,
        hasLibraryMedia: capabilities['hasLibraryMedia'] == true,
        libraryItemCount: (capabilities['libraryItemCount'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  Future<void> startQrLogin() async {
    authDebugInfo('Requesting QR login from TDLib...');
    await _tdlib.startQrLogin();
  }

  Future<void> submitCloudPassword(String password) => _tdlib.submitCloudPassword(password);

  Future<void> submitAuthenticationPhoneNumber(String phoneNumber) =>
      _tdlib.submitAuthenticationPhoneNumber(phoneNumber);

  Future<void> submitAuthenticationCode(String code) => _tdlib.submitAuthenticationCode(code);

  Future<void> resetLocalSessionForQrLogin() async {
    await _tdlib.resetLocalSessionForQrLogin();
    _tdlibInitialized = false;
  }

  Future<List<OxDiscoverSection>> fetchOxDiscoverSections({int limitPerKind = 20}) async {
    final movieFuture = _fetchLibraryMedia(kind: 'movie', limit: limitPerKind);
    final seriesFuture = _fetchLibraryMedia(kind: 'series', limit: limitPerKind);
    final videoFuture = _fetchLibraryMedia(kind: 'general_video', limit: limitPerKind);

    final results = await Future.wait([movieFuture, seriesFuture, videoFuture]);
    final sections = <OxDiscoverSection>[];

    if (results[0].isNotEmpty) {
      sections.add(OxDiscoverSection(id: 'movies', title: 'Movies', items: results[0]));
    }
    if (results[1].isNotEmpty) {
      sections.add(OxDiscoverSection(id: 'series', title: 'Series', items: results[1]));
    }
    if (results[2].isNotEmpty) {
      sections.add(OxDiscoverSection(id: 'videos', title: 'Videos', items: results[2]));
    }

    // Fire-and-forget background sync for pending locator verification.
    unawaited(_syncPendingLocatorVerificationCandidates(sections));

    return sections;
  }

  Future<void> dispose() async {}

  Future<void> _syncPendingLocatorVerificationCandidates(List<OxDiscoverSection> sections) async {
    final now = DateTime.now();
    if (_locatorVerifySyncInFlight) {
      debugLogInfo(
        'Locator verify scan skipped: previous scan is still running.',
        type: LogType.locatorVerification,
      );
      return;
    }

    final last = _lastLocatorVerifySyncAt;
    if (last != null && now.difference(last) < const Duration(seconds: 25)) {
      return;
    }

    final candidates = <OxLibraryMediaItem>[];
    final seen = <String>{};
    for (final section in sections) {
      for (final item in section.items) {
        final mediaId = _extractMediaIdForLocatorVerification(item.globalId);
        if (mediaId == null || seen.contains(mediaId)) continue;
        final hasLocatorCandidate = item.locatorMessageId != null && item.locatorMessageId! > 0;
        final hasSourceCandidate =
            item.thumbnailSourceChatId != null &&
            item.thumbnailSourceMessageId != null &&
            item.thumbnailSourceMessageId! > 0;
        if (!hasLocatorCandidate && !hasSourceCandidate) continue;
        seen.add(mediaId);
        candidates.add(item);
      }
    }

    if (candidates.isEmpty) {
      debugLogInfo(
        'Locator verify scan completed: no candidates with locator metadata found.',
        type: LogType.locatorVerification,
      );
      _lastLocatorVerifySyncAt = now;
      return;
    }

    _locatorVerifySyncInFlight = true;
    _lastLocatorVerifySyncAt = now;

    debugLogInfo(
      'Locator verify scan started: candidates=${candidates.length}.',
      type: LogType.locatorVerification,
    );

    var successCount = 0;
    var attemptedCount = 0;
    try {
      for (final item in candidates.take(12)) {
        final mediaId = _extractMediaIdForLocatorVerification(item.globalId);
        if (mediaId == null) continue;
        attemptedCount += 1;
        final ok = await _trySyncResolvedLocatorVerification(
          mediaId: mediaId,
          fileUniqueId: item.fileUniqueId,
          locatorType: item.locatorType,
          locatorChatId: item.locatorChatId,
          locatorMessageId: item.locatorMessageId,
          locatorBotUsername: item.locatorBotUsername,
          sourceChatId: item.thumbnailSourceChatId,
          sourceMessageId: item.thumbnailSourceMessageId,
          reason: 'discover_scan',
        );
        if (ok != null) {
          successCount += 1;
        } else if ((item.verificationStatus ?? '').trim().toLowerCase() == 'verified') {
          debugLogInfo(
            'Locator verify scan failed for verified locator $mediaId. Requesting provider recovery.',
            type: LogType.locatorVerification,
          );
          unawaited(_requestThumbnailRecovery(mediaId, reason: 'locator_verify_scan_failed'));
        }
      }

      debugLogInfo(
        'Locator verify scan finished: attempted=$attemptedCount success=$successCount.',
        type: LogType.locatorVerification,
      );
    } catch (error) {
      debugLogError(
        'Locator verify scan crashed: $error',
        type: LogType.locatorVerification,
      );
    } finally {
      _locatorVerifySyncInFlight = false;
    }
  }

  String? _extractMediaIdForLocatorVerification(String globalId) {
    final value = globalId.trim();
    if (value.isEmpty) return null;
    if (value.startsWith('series:')) return null;
    return value;
  }

  /// Fetches and caches the video thumbnail from Telegram for a [general_video]
  /// media item.
  ///
  /// Uses locator metadata first to resolve the actual Telegram file like the
  /// playback path does, generates a cached JPEG from that file, and falls back
  /// to source-message thumbnail extraction only when locator resolution is not
  /// enough. Returns `null` on failure.
  Future<String?> fetchVideoThumbnail({
    required String mediaId,
    String? fileUniqueId,
    String? verificationStatus,
    String? locatorType,
    int? locatorChatId,
    int? locatorMessageId,
    String? locatorBotUsername,
    String? locatorRemoteFileId,
    int? chatId,
    int? messageId,
  }) async {
    if (!_tdlibInitialized || !_tdlib.isInitialized) {
      debugLogError(
        'Thumbnail skipped for $mediaId because TDLib is not initialized.',
        type: LogType.telegramThumbnail,
      );
      return null;
    }

    debugLogInfo(
      'Resolving thumbnail for $mediaId.',
      type: LogType.telegramThumbnail,
    );

    try {
      final cacheDir = await _videoThumbnailCacheDir();
      final cachedFile = File('${cacheDir.path}/$mediaId.jpg');
      if (cachedFile.existsSync()) {
        debugLogSuccess(
          'Thumbnail cache hit for $mediaId at ${cachedFile.path}.',
          type: LogType.telegramThumbnail,
        );
        return cachedFile.path;
      }

      final directResolvedFile = await resolveTelegramMediaFile(
        tdlib: _tdlib,
        mediaFileId: mediaId,
        locatorType: locatorType,
        locatorChatId: locatorChatId,
        locatorMessageId: locatorMessageId,
        locatorBotUsername: locatorBotUsername,
        locatorRemoteFileId: locatorRemoteFileId,
      );
      if (directResolvedFile != null) {
        final directResolvedThumbPath = await _generateResolvedFileThumbnailToCache(
          sourceFile: directResolvedFile.file,
          cachedFile: cachedFile,
        );
        if (directResolvedThumbPath != null) {
          debugLogSuccess(
            'Generated thumbnail from stable resolved file for $mediaId at $directResolvedThumbPath.',
            type: LogType.telegramThumbnail,
          );
          return directResolvedThumbPath;
        }
      }

      var effectiveVerificationStatus = (verificationStatus ?? '').trim().toLowerCase();
      var effectiveLocatorType = locatorType;
      var effectiveLocatorChatId = locatorChatId;
      var effectiveLocatorMessageId = locatorMessageId;
      var effectiveLocatorBotUsername = locatorBotUsername;
      if (effectiveVerificationStatus != 'verified') {
        final verifiedLocator = await _trySyncResolvedLocatorVerification(
          mediaId: mediaId,
          fileUniqueId: fileUniqueId,
          locatorType: locatorType,
          locatorChatId: locatorChatId,
          locatorMessageId: locatorMessageId,
          locatorBotUsername: locatorBotUsername,
          sourceChatId: chatId,
          sourceMessageId: messageId,
          reason: 'thumbnail_fetch',
        );
        if (verifiedLocator == null) {
          debugLogInfo(
            'Thumbnail skipped for $mediaId because locator is not verified yet. verificationStatus=$verificationStatus',
            type: LogType.telegramThumbnail,
          );
          return null;
        }

        effectiveVerificationStatus = 'verified';
        effectiveLocatorType = verifiedLocator.locatorType;
        effectiveLocatorChatId = verifiedLocator.locatorChatId;
        effectiveLocatorMessageId = verifiedLocator.locatorMessageId;
        effectiveLocatorBotUsername = verifiedLocator.locatorBotUsername;
        debugLogSuccess(
          'Thumbnail verify succeeded inline for $mediaId; continuing with verified locator type=${verifiedLocator.locatorType} messageId=${verifiedLocator.locatorMessageId}.',
          type: LogType.telegramThumbnail,
        );
      }

      if (effectiveVerificationStatus == 'verified') {
        final resolvedFile = await resolveTelegramMediaFile(
          tdlib: _tdlib,
          mediaFileId: mediaId,
          locatorType: effectiveLocatorType,
          locatorChatId: effectiveLocatorChatId,
          locatorMessageId: effectiveLocatorMessageId,
          locatorBotUsername: effectiveLocatorBotUsername,
          locatorRemoteFileId: locatorRemoteFileId,
        );
        if (resolvedFile != null) {
          final resolvedThumbPath = await _generateResolvedFileThumbnailToCache(
            sourceFile: resolvedFile.file,
            cachedFile: cachedFile,
          );
          if (resolvedThumbPath != null) {
            debugLogSuccess(
              'Generated thumbnail from verified resolved locator file for $mediaId at $resolvedThumbPath.',
              type: LogType.telegramThumbnail,
            );
            return resolvedThumbPath;
          }
        }
      }

      final lookup = await _resolveVerifiedThumbnailMessage(
        mediaId: mediaId,
        fileUniqueId: fileUniqueId,
        locatorType: effectiveLocatorType,
        locatorChatId: effectiveLocatorChatId,
        locatorMessageId: effectiveLocatorMessageId,
        locatorBotUsername: effectiveLocatorBotUsername,
      );
      var effectiveLookup = lookup;
      var message = effectiveLookup.message;
      if (message == null) {
        final repairedLocator = await _trySyncResolvedLocatorVerification(
          mediaId: mediaId,
          fileUniqueId: fileUniqueId,
          locatorType: effectiveLocatorType,
          locatorChatId: effectiveLocatorChatId,
          locatorMessageId: effectiveLocatorMessageId,
          locatorBotUsername: effectiveLocatorBotUsername,
          sourceChatId: chatId,
          sourceMessageId: messageId,
          reason: 'verified_locator_recheck',
        );
        if (repairedLocator != null) {
          effectiveLocatorType = repairedLocator.locatorType;
          effectiveLocatorChatId = repairedLocator.locatorChatId;
          effectiveLocatorMessageId = repairedLocator.locatorMessageId;
          effectiveLocatorBotUsername = repairedLocator.locatorBotUsername;
          effectiveLookup = await _resolveVerifiedThumbnailMessage(
            mediaId: mediaId,
            fileUniqueId: fileUniqueId,
            locatorType: effectiveLocatorType,
            locatorChatId: effectiveLocatorChatId,
            locatorMessageId: effectiveLocatorMessageId,
            locatorBotUsername: effectiveLocatorBotUsername,
          );
          message = effectiveLookup.message;
        }
      }
      if (message == null) {
        debugLogError(
          effectiveLookup.failureReason ?? 'Could not resolve verified locator message for $mediaId.',
          type: LogType.telegramThumbnail,
        );
        unawaited(_requestThumbnailRecovery(mediaId, reason: 'verified_locator_message_missing'));
        return null;
      }

      final directThumbPath = await _downloadMessageThumbnailToCache(
        message: message,
        cachedFile: cachedFile,
      );
      if (directThumbPath != null) {
        debugLogSuccess(
          'Embedded Telegram thumbnail cached for $mediaId at $directThumbPath.',
          type: LogType.telegramThumbnail,
        );
        return directThumbPath;
      }

      final generatedThumbPath = await _generateMessageThumbnailToCache(
        message: message,
        cachedFile: cachedFile,
      );
      if (generatedThumbPath != null) {
        debugLogSuccess(
          'Generated thumbnail from verified locator for $mediaId at $generatedThumbPath.',
          type: LogType.telegramThumbnail,
        );
      } else {
        debugLogError(
          'Verified locator thumbnail generation failed for $mediaId. Requesting provider recovery.',
          type: LogType.telegramThumbnail,
        );
        unawaited(_requestThumbnailRecovery(mediaId, reason: 'verified_locator_thumbnail_generation_failed'));
      }
      return generatedThumbPath;
    } catch (error) {
      debugLogError(
        'Thumbnail resolution crashed for $mediaId: $error',
        type: LogType.telegramThumbnail,
      );
      unawaited(_requestThumbnailRecovery(mediaId, reason: 'thumbnail_resolution_crashed'));
      return null;
    }
  }

  Future<_VerifiedLocatorResult?> _trySyncResolvedLocatorVerification({
    required String mediaId,
    required String? fileUniqueId,
    required String? locatorType,
    required int? locatorChatId,
    required int? locatorMessageId,
    required String? locatorBotUsername,
    required int? sourceChatId,
    required int? sourceMessageId,
    required String reason,
  }) async {
    final messageId = locatorMessageId;
    final fallbackMessageId = sourceMessageId;
    if ((messageId == null || messageId <= 0) && (fallbackMessageId == null || fallbackMessageId <= 0)) {
      debugLogInfo(
        'Locator verify skipped for $mediaId: missing locatorMessageId and sourceMessageId. reason=$reason',
        type: LogType.locatorVerification,
      );
      return null;
    }

    final type = (locatorType ?? '').trim();
    final hasSupportedLocatorType =
        type == 'CHAT_MESSAGE' || type == 'PRIVATE_USER_CHAT' || type == 'BOT_PRIVATE_RUNTIME';
    if (!hasSupportedLocatorType && (sourceChatId == null || sourceMessageId == null)) {
      debugLogInfo(
        'Locator verify skipped for $mediaId: unsupported locatorType="$type" and no source fallback. reason=$reason',
        type: LogType.locatorVerification,
      );
      return null;
    }

    var lookup = const _ThumbnailMessageLookupResult(message: null);
    if (hasSupportedLocatorType && messageId != null && messageId > 0) {
      lookup = await _resolveLocatorVerificationCandidate(
        mediaId: mediaId,
        fileUniqueId: fileUniqueId,
        locatorType: type,
        locatorChatId: locatorChatId,
        locatorMessageId: messageId,
        locatorBotUsername: locatorBotUsername,
      );
    }

    if (lookup.message == null && sourceChatId != null && sourceMessageId != null) {
      final sourceLookup = await _resolveThumbnailMessage(
        chatId: sourceChatId,
        messageId: sourceMessageId,
        fileUniqueId: fileUniqueId,
      );
      if (sourceLookup.message != null) {
        lookup = sourceLookup;
        debugLogInfo(
          'Locator verify fell back to source chat/message for $mediaId. chatId=${sourceLookup.resolvedChatId ?? sourceChatId} messageId=${sourceLookup.resolvedMessageId ?? sourceMessageId}.',
          type: LogType.locatorVerification,
        );
      }
    }

    if (lookup.message == null) {
      debugLogError(
        lookup.failureReason ?? 'Locator verify failed for $mediaId before sync. reason=$reason',
        type: LogType.locatorVerification,
      );
      return null;
    }

    final outboundType = 'CHAT_MESSAGE';
    final outboundChatId = lookup.resolvedChatId;
    final outboundMessageId = lookup.resolvedMessageId ?? lookup.message!.id;

    final payload = <String, dynamic>{
      'mediaFileId': mediaId,
      'locatorType': outboundType,
      'locatorMessageId': outboundMessageId,
    };

    if (outboundChatId == null) {
      debugLogError(
        'Locator verify skipped for $mediaId: resolved lookup has no chat id. reason=$reason',
        type: LogType.locatorVerification,
      );
      return null;
    }
    payload['locatorChatId'] = outboundChatId;

    try {
      debugLogInfo(
        'Locator verify start for $mediaId. type=$outboundType chatId=$outboundChatId messageId=$outboundMessageId reason=$reason',
        type: LogType.locatorVerification,
      );

      final dio = _authorizedApiClient();
      final response = await dio.post<Map<String, dynamic>>(
        '/me/media-locator-sync',
        data: payload,
      );

      final ok = response.data?['ok'] == true;
      if (ok) {
        debugLogSuccess(
          'Locator verify success for $mediaId. type=$outboundType chatId=$outboundChatId messageId=$outboundMessageId',
          type: LogType.locatorVerification,
        );
        return _VerifiedLocatorResult(
          locatorType: outboundType,
          locatorChatId: outboundChatId,
          locatorMessageId: outboundMessageId,
        );
      }

      debugLogError(
        'Locator verify failed for $mediaId: API response missing ok=true.',
        type: LogType.locatorVerification,
      );
      return null;
    } on DioException catch (error) {
      final code = error.response?.statusCode;
      final body = error.response?.data;
      debugLogError(
        'Locator verify Dio error for $mediaId: status=$code body=$body error=${error.message}',
        type: LogType.locatorVerification,
      );
      return null;
    } catch (error) {
      debugLogError(
        'Locator verify unexpected error for $mediaId: $error',
        type: LogType.locatorVerification,
      );
      return null;
    }
  }

  Future<_ThumbnailMessageLookupResult> _resolveLocatorVerificationCandidate({
    required String mediaId,
    required String? fileUniqueId,
    required String locatorType,
    required int? locatorChatId,
    required int locatorMessageId,
    required String? locatorBotUsername,
  }) async {
    if (locatorType == 'CHAT_MESSAGE' && locatorChatId != null) {
      final directLookup = await _resolveThumbnailMessage(
        chatId: locatorChatId,
        messageId: locatorMessageId,
        exactChatIdOnly: false,
        fileUniqueId: fileUniqueId,
      );
      if (directLookup.message != null) {
        return directLookup;
      }
      if ((locatorBotUsername ?? '').trim().isNotEmpty) {
        debugLogInfo(
          'Locator verify direct chat lookup failed for $mediaId. Trying runtime private fallback with bot=$locatorBotUsername.',
          type: LogType.locatorVerification,
        );
        final runtimeChatId = await _resolveBotPrivateChatId(locatorBotUsername);
        if (runtimeChatId != null) {
          final runtimeLookup = await _resolveThumbnailMessage(
            chatId: runtimeChatId,
            messageId: locatorMessageId,
            exactChatIdOnly: true,
            fileUniqueId: fileUniqueId,
          );
          if (runtimeLookup.message != null) {
            return runtimeLookup;
          }
          return _ThumbnailMessageLookupResult(
            message: null,
            failureReason: runtimeLookup.failureReason ?? directLookup.failureReason,
          );
        }
      }
      return directLookup;
    }

    if (locatorType == 'PRIVATE_USER_CHAT') {
      if (locatorChatId == null) {
        return _ThumbnailMessageLookupResult(
          message: null,
          failureReason: 'Locator verify skipped for $mediaId: PRIVATE_USER_CHAT without locatorChatId.',
        );
      }

      final resolvedPrivateChatId = await _resolvePrivateUserChatId(locatorChatId);
      if (resolvedPrivateChatId == null) {
        return _ThumbnailMessageLookupResult(
          message: null,
          failureReason: 'Locator verify skipped for $mediaId: could not resolve private chat id from userId=$locatorChatId.',
        );
      }

      debugLogInfo(
        'Locator verify normalized PRIVATE_USER_CHAT for $mediaId to CHAT_MESSAGE chatId=$resolvedPrivateChatId.',
        type: LogType.locatorVerification,
      );
      return _resolveThumbnailMessage(
        chatId: resolvedPrivateChatId,
        messageId: locatorMessageId,
        exactChatIdOnly: true,
        fileUniqueId: fileUniqueId,
      );
    }

    if (locatorType == 'BOT_PRIVATE_RUNTIME') {
      final runtimeChatId = await _resolveBotPrivateChatId(locatorBotUsername);
      if (runtimeChatId == null) {
        return _ThumbnailMessageLookupResult(
          message: null,
          failureReason: 'Locator verify skipped for $mediaId: BOT_PRIVATE_RUNTIME could not resolve private chat.',
        );
      }

      debugLogInfo(
        'Locator verify normalized BOT_PRIVATE_RUNTIME for $mediaId to CHAT_MESSAGE chatId=$runtimeChatId.',
        type: LogType.locatorVerification,
      );
      return _resolveThumbnailMessage(
        chatId: runtimeChatId,
        messageId: locatorMessageId,
        exactChatIdOnly: true,
        fileUniqueId: fileUniqueId,
      );
    }

    return _ThumbnailMessageLookupResult(
      message: null,
      failureReason: 'Locator verify skipped for $mediaId: unsupported locatorType="$locatorType".',
    );
  }

  Future<_ThumbnailMessageLookupResult> _resolveVerifiedThumbnailMessage({
    required String mediaId,
    required String? fileUniqueId,
    required String? locatorType,
    required int? locatorChatId,
    required int? locatorMessageId,
    required String? locatorBotUsername,
  }) async {
    if (locatorMessageId == null || locatorMessageId <= 0) {
      return _ThumbnailMessageLookupResult(
        message: null,
        failureReason: 'Verified locator for $mediaId has no locatorMessageId.',
      );
    }

    if (locatorType == 'CHAT_MESSAGE' && locatorChatId != null) {
      debugLogInfo(
        'Reading thumbnail from verified locator chat/message for $mediaId.',
        type: LogType.telegramThumbnail,
      );
      return _resolveThumbnailMessage(
        chatId: locatorChatId,
        messageId: locatorMessageId,
        exactChatIdOnly: false,
        fileUniqueId: fileUniqueId,
      );
    }

    if (locatorType == 'PRIVATE_USER_CHAT' && locatorChatId != null) {
      final privateChatId = await _resolvePrivateUserChatId(locatorChatId);
      if (privateChatId == null) {
        return _ThumbnailMessageLookupResult(
          message: null,
          failureReason: 'Verified private-user locator for $mediaId could not create private chat.',
        );
      }

      debugLogInfo(
        'Reading thumbnail from verified private-user locator for $mediaId.',
        type: LogType.telegramThumbnail,
      );
      return _resolveThumbnailMessage(
        chatId: privateChatId,
        messageId: locatorMessageId,
        exactChatIdOnly: true,
        fileUniqueId: fileUniqueId,
      );
    }

    if (locatorType == 'BOT_PRIVATE_RUNTIME') {
      final runtimeChatId = await _resolveBotPrivateChatId(locatorBotUsername);
      if (runtimeChatId == null) {
        return _ThumbnailMessageLookupResult(
          message: null,
          failureReason: 'Verified bot runtime locator for $mediaId could not resolve private chat.',
        );
      }

      debugLogInfo(
        'Reading thumbnail from verified bot runtime locator for $mediaId.',
        type: LogType.telegramThumbnail,
      );
      return _resolveThumbnailMessage(
        chatId: runtimeChatId,
        messageId: locatorMessageId,
        exactChatIdOnly: true,
        fileUniqueId: fileUniqueId,
      );
    }

    return _ThumbnailMessageLookupResult(
      message: null,
      failureReason: 'Verified locator for $mediaId has unsupported locatorType=$locatorType.',
    );
  }

  Future<void> _requestThumbnailRecovery(String mediaId, {required String reason}) async {
    final now = DateTime.now();
    final lastAttempt = _lastThumbnailRecoveryRequestAt[mediaId];
    if (_thumbnailRecoveryInFlight.contains(mediaId)) {
      debugLogInfo(
        'Thumbnail recovery already in flight for $mediaId. reason=$reason',
        type: LogType.telegramThumbnail,
      );
      return;
    }
    if (lastAttempt != null && now.difference(lastAttempt) < const Duration(seconds: 30)) {
      debugLogInfo(
        'Thumbnail recovery throttled for $mediaId. reason=$reason',
        type: LogType.telegramThumbnail,
      );
      return;
    }

    _thumbnailRecoveryInFlight.add(mediaId);
    _lastThumbnailRecoveryRequestAt[mediaId] = now;
    try {
      debugLogInfo(
        'Requesting provider recovery for thumbnail mediaId=$mediaId. reason=$reason',
        type: LogType.telegramThumbnail,
      );
      final dio = _authorizedApiClient();
      final response = await dio.post<Map<String, dynamic>>(
        '/me/recover-from-backup',
        data: <String, dynamic>{'mediaFileId': mediaId},
      );
      final ok = response.data?['ok'] == true;
      final status = response.data?['status']?.toString();
      final attempts = response.data?['attempts'];
      if (ok) {
        debugLogSuccess(
          'Provider recovery succeeded for thumbnail mediaId=$mediaId. status=$status attempts=$attempts',
          type: LogType.telegramThumbnail,
        );
      } else {
        debugLogError(
          'Provider recovery did not succeed for thumbnail mediaId=$mediaId. status=$status attempts=$attempts',
          type: LogType.telegramThumbnail,
        );
      }
    } on DioException catch (error) {
      debugLogError(
        'Provider recovery request failed for thumbnail mediaId=$mediaId: status=${error.response?.statusCode} body=${error.response?.data} error=${error.message}',
        type: LogType.telegramThumbnail,
      );
    } catch (error) {
      debugLogError(
        'Provider recovery crashed for thumbnail mediaId=$mediaId: $error',
        type: LogType.telegramThumbnail,
      );
    } finally {
      _thumbnailRecoveryInFlight.remove(mediaId);
    }
  }


  Future<int?> _resolveBotPrivateChatId(String? botUsername) async {
    final cleaned = botUsername?.trim().replaceFirst(RegExp(r'^@'), '');
    if (cleaned == null || cleaned.isEmpty) return null;

    try {
      final resolved = await _tdlib.send(td.SearchPublicChat(username: cleaned));
      if (resolved is! td.Chat || resolved.type is! td.ChatTypePrivate) return null;

      final botUserId = (resolved.type as td.ChatTypePrivate).userId;
      final privateChat = await _tdlib.send(td.CreatePrivateChat(userId: botUserId, force: false));
      if (privateChat is td.Chat) {
        try {
          await _tdlib.send(td.OpenChat(chatId: privateChat.id));
        } catch (_) {}
        return privateChat.id;
      }
    } catch (_) {
      return null;
    }

    return null;
  }

  Future<int?> _resolvePrivateUserChatId(int userId) async {
    if (userId <= 0) return null;
    try {
      final privateChat = await _tdlib.send(
        td.CreatePrivateChat(userId: userId, force: false),
      );
      if (privateChat is td.Chat) {
        try {
          await _tdlib.send(td.OpenChat(chatId: privateChat.id));
        } catch (_) {}
        return privateChat.id;
      }
    } catch (_) {
      return null;
    }

    return null;
  }

  Future<_ThumbnailMessageLookupResult> _resolveThumbnailMessage({
    required int chatId,
    required int messageId,
    bool exactChatIdOnly = false,
    String? fileUniqueId,
  }) async {
    String? lastFailureReason;
    final chatCandidates = _candidateTelegramChatIds(chatId, exactOnly: exactChatIdOnly)
        .toList(growable: false);
    for (final chatCandidate in chatCandidates) {
      for (final messageCandidate in _candidateTelegramMessageIds(messageId)) {
        try {
          final result = await _tdlib.send(
            td.GetMessage(chatId: chatCandidate, messageId: messageCandidate),
          );
          if (result is td.Message) {
            return _ThumbnailMessageLookupResult(
              message: result,
              resolvedChatId: chatCandidate,
              resolvedMessageId: result.id,
            );
          }
        } on td.TdError catch (error) {
          lastFailureReason = 'Message lookup failed for chatCandidate=$chatCandidate messageCandidate=$messageCandidate: code=${error.code} message=${error.message}';
        } catch (error) {
          lastFailureReason = 'Message lookup failed for chatCandidate=$chatCandidate messageCandidate=$messageCandidate: $error';
        }
      }
    }

    final trimmedFileUniqueId = fileUniqueId?.trim() ?? '';
    if (trimmedFileUniqueId.isNotEmpty) {
      for (final chatCandidate in chatCandidates) {
        final historyMatch = await _findMessageInRecentHistoryByFileUniqueId(
          chatId: chatCandidate,
          fileUniqueId: trimmedFileUniqueId,
        );
        if (historyMatch != null) {
          return historyMatch;
        }
      }
    }

    return _ThumbnailMessageLookupResult(
      message: null,
      failureReason: lastFailureReason ?? 'Message lookup failed for chat=$chatId message=$messageId.',
    );
  }

  Future<_ThumbnailMessageLookupResult?> _findMessageInRecentHistoryByFileUniqueId({
    required int chatId,
    required String fileUniqueId,
  }) async {
    try {
      final result = await _tdlib.send(
        td.GetChatHistory(
          chatId: chatId,
          fromMessageId: 0,
          offset: 0,
          limit: 60,
          onlyLocal: false,
        ),
      );
      if (result is! td.Messages) return null;

      for (final message in result.messages) {
        if (_messageFileUniqueId(message) != fileUniqueId) continue;
        return _ThumbnailMessageLookupResult(
          message: message,
          resolvedChatId: chatId,
          resolvedMessageId: message.id,
        );
      }
    } catch (_) {}

    return null;
  }

  Iterable<int> _candidateTelegramChatIds(int chatId, {bool exactOnly = false}) sync* {
    final emitted = <int>{};

    bool emit(int value) {
      if (value == 0 || emitted.contains(value)) return false;
      emitted.add(value);
      return true;
    }

    if (emit(chatId)) yield chatId;

  if (exactOnly) return;

    // Basic-group style chats are often addressed as negative ids in TDLib.
    if (chatId > 0 && emit(-chatId)) yield -chatId;

    // Supergroups/channels commonly need the TDLib chat id form: -100<peerId>.
    const supergroupPrefix = 1000000000000;
    if (chatId > 0) {
      final supergroupChatId = -(supergroupPrefix + chatId);
      if (emit(supergroupChatId)) yield supergroupChatId;
    }
  }

  Iterable<int> _candidateTelegramMessageIds(int messageId) sync* {
    yield messageId;

    final tdlibScaled = messageId * 1048576;
    if (tdlibScaled != messageId) {
      yield tdlibScaled;
    }
  }

  Future<String?> _downloadMessageThumbnailToCache({
    required td.Message message,
    required File cachedFile,
  }) async {
    int? thumbFileId;
    final content = message.content;
    if (content is td.MessageVideo) {
      thumbFileId = content.video.thumbnail?.file.id;
    } else if (content is td.MessageDocument) {
      thumbFileId = content.document.thumbnail?.file.id;
    }
    if (thumbFileId == null) return null;

    final srcPath = await _downloadTelegramFileFully(thumbFileId);
    if (srcPath == null || srcPath.isEmpty) return null;

    await File(srcPath).copy(cachedFile.path);
    return cachedFile.path;
  }

  Future<String?> _generateMessageThumbnailToCache({
    required td.Message message,
    required File cachedFile,
  }) async {
    final sourceFileId = _messagePlayableFileId(message);
    if (sourceFileId == null) {
      debugLogError(
        'Telegram message has no playable file to generate a thumbnail from.',
        type: LogType.telegramThumbnail,
      );
      return null;
    }

    final localVideoPath = await _waitForReadableVideoPrefix(sourceFileId);
    if (localVideoPath == null || localVideoPath.isEmpty) {
      debugLogError(
        'Playable file $sourceFileId did not reach a readable local prefix.',
        type: LogType.telegramThumbnail,
      );
      return null;
    }

    return _generateVideoThumbnailFile(
      sourceVideoPath: localVideoPath,
      cachedFile: cachedFile,
      logContext: 'fileId=$sourceFileId',
    );
  }

  Future<String?> _generateVideoThumbnailFile({
    required String sourceVideoPath,
    required File cachedFile,
    required String logContext,
  }) async {
    if (Platform.isAndroid) {
      try {
        final result = await _mediaToolsChannel.invokeMethod<String>(
          'generateVideoThumbnail',
          <String, Object?>{
            'sourcePath': sourceVideoPath,
            'targetPath': cachedFile.path,
            'maxWidth': 480,
            'quality': 78,
            'timeMs': 1200,
          },
        );
        if (result != null && result.isNotEmpty) {
          return result;
        }
      } catch (error) {
        debugLogError(
          'Native thumbnail generation failed for $logContext: $error',
          type: LogType.telegramThumbnail,
        );
        return null;
      }

      debugLogError(
        'Native thumbnail generation returned no path for $logContext.',
        type: LogType.telegramThumbnail,
      );
      return null;
    }

    Uint8List? bytes;
    try {
      bytes = await VideoThumbnail.thumbnailData(
        video: sourceVideoPath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 480,
        quality: 78,
        timeMs: 1200,
      );
    } catch (error) {
      debugLogError(
        'video_thumbnail failed for $logContext: $error',
        type: LogType.telegramThumbnail,
      );
      return null;
    }

    if (bytes == null || bytes.isEmpty) {
      debugLogError(
        'video_thumbnail returned no bytes for $logContext.',
        type: LogType.telegramThumbnail,
      );
      return null;
    }

    await cachedFile.writeAsBytes(bytes, flush: true);
    return cachedFile.path;
  }

  Future<String?> _generateResolvedFileThumbnailToCache({
    required td.File sourceFile,
    required File cachedFile,
  }) async {
    final localVideoPath = await _waitForReadableVideoPrefix(sourceFile.id);
    if (localVideoPath == null || localVideoPath.isEmpty) {
      return null;
    }

    return _generateVideoThumbnailFile(
      sourceVideoPath: localVideoPath,
      cachedFile: cachedFile,
      logContext: 'locator fileId=${sourceFile.id}',
    );
  }

  int? _messagePlayableFileId(td.Message message) {
    final content = message.content;
    if (content is td.MessageVideo) {
      return content.video.video.id;
    }
    if (content is td.MessageDocument) {
      return content.document.document.id;
    }
    return null;
  }

  String? _messageFileUniqueId(td.Message message) {
    final content = message.content;
    if (content is td.MessageVideo) {
      final value = content.video.video.remote.uniqueId.trim();
      return value.isEmpty ? null : value;
    }
    if (content is td.MessageDocument) {
      final value = content.document.document.remote.uniqueId.trim();
      return value.isEmpty ? null : value;
    }
    return null;
  }

  Future<String?> _downloadTelegramFileFully(int fileId) async {
    final fileResult = await _tdlib.send(
      td.DownloadFile(
        fileId: fileId,
        priority: 5,
        offset: 0,
        limit: 0,
        synchronous: true,
      ),
    );
    if (fileResult is! td.File) return null;
    final srcPath = fileResult.local.path.trim();
    if (srcPath.isEmpty) return null;
    return srcPath;
  }

  Future<String?> _waitForReadableVideoPrefix(int fileId) async {
    const minVideoPrefixBytes = 768 * 1024;
    const maxTdlibDownloadLimit = 4 * 1024 * 1024;
    const prefixWait = Duration(seconds: 26);
    const pollInterval = Duration(milliseconds: 380);

    final deadline = DateTime.now().add(prefixWait);
    while (DateTime.now().isBefore(deadline)) {
      td.File? file;
      try {
        final obj = await _tdlib.send(td.GetFile(fileId: fileId));
        if (obj is td.File) file = obj;
      } catch (_) {}

      if (file != null) {
        final path = file.local.path.trim();
        final downloaded = file.local.downloadedSize;
        if (path.isNotEmpty && downloaded >= minVideoPrefixBytes) return path;
      }

      try {
        await _tdlib.send(
          td.DownloadFile(
            fileId: fileId,
            priority: 8,
            offset: 0,
            limit: maxTdlibDownloadLimit,
            synchronous: false,
          ),
        );
      } catch (_) {}

      await Future<void>.delayed(pollInterval);
    }

    debugLogError(
      'Timed out waiting for readable video prefix for fileId=$fileId.',
      type: LogType.telegramThumbnail,
    );
    return null;
  }

  static Directory? _thumbnailCacheDirCache;

  Future<Directory> _videoThumbnailCacheDir() async {
    if (_thumbnailCacheDirCache != null) return _thumbnailCacheDirCache!;
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/ox_thumbnails');
    if (!dir.existsSync()) await dir.create(recursive: true);
    _thumbnailCacheDirCache = dir;
    return dir;
  }

  Future<List<OxLibraryMediaItem>> _fetchLibraryMedia({required String kind, required int limit}) async {
    final dio = _authorizedApiClient();
    final response = await dio.get<Map<String, dynamic>>(
      '/me/library/media',
      queryParameters: <String, dynamic>{
        'kind': kind,
        'limit': limit,
        'sort': 'created_desc',
      },
    );

    final items = response.data?['items'];
    if (items is! List) {
      return const <OxLibraryMediaItem>[];
    }

    return items.whereType<Map>().map((rawItem) {
      final item = Map<String, dynamic>.from(rawItem);
      final mediaId = _readOptionalTrimmed(item['mediaId']);
      final seriesId = _readOptionalTrimmed(item['seriesId']);
      final globalId = kind == 'series' && seriesId != null ? 'series:$seriesId' : (mediaId ?? '');

      return OxLibraryMediaItem(
        kind: _readOptionalTrimmed(item['kind']) ?? kind,
        globalId: globalId,
        title: _readOptionalTrimmed(item['title']) ?? 'Untitled',
        createdAt: DateTime.tryParse(item['createdAt']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        fileUniqueId: _readOptionalTrimmed(item['fileUniqueId']),
        posterPath: _readOptionalTrimmed(item['posterPath']),
        overview: _readOptionalTrimmed(item['overview']),
        voteAverage: (item['voteAverage'] as num?)?.toDouble(),
        locatorType: _readOptionalTrimmed(item['locatorType']),
        locatorChatId: (item['locatorChatId'] as num?)?.toInt(),
        locatorMessageId: (item['locatorMessageId'] as num?)?.toInt(),
        locatorBotUsername: _readOptionalTrimmed(item['locatorBotUsername']),
        locatorRemoteFileId: _readOptionalTrimmed(item['locatorRemoteFileId']),
        verificationStatus: _readOptionalTrimmed(item['verificationStatus']),
        thumbnailSourceChatId: (item['thumbnailSourceChatId'] as num?)?.toInt(),
        thumbnailSourceMessageId: (item['thumbnailSourceMessageId'] as num?)?.toInt(),
      );
    }).where((item) => item.globalId.isNotEmpty).toList(growable: false);
  }

  Dio _authorizedApiClient() {
    final accessToken = _storage.getApiAccessToken()?.trim() ?? '';
    if (accessToken.isEmpty) {
      throw const OxBootstrapUnauthorized();
    }

    return Dio(
      BaseOptions(
        baseUrl: _config.apiBaseUrl,
        headers: <String, String>{'Authorization': 'Bearer $accessToken'},
      ),
    );
  }

  Future<void> _ensureTdlibInitialized({required int apiId}) async {
    if (_tdlibInitialized && _tdlib.isInitialized) {
      authDebugDedup('tdlib_init', AuthDebugLevel.info, 'TDLib already initialized, reusing existing client.');
      return;
    }
    authDebugInfo('Initializing TDLib client...');
    await _tdlib.init(
      apiId: apiId,
      apiHash: _config.telegramApiHash,
      sessionString: '',
    );
    _tdlibInitialized = true;
    authDebugSuccess('TDLib client initialized.');
  }

  Future<TelegramAuthResult> _authenticateWithTelegram() async {
    final initData = await _fetchSignedInitData();
    authDebugSuccess('Signed Telegram initData fetched.', completeStatus: AuthDebugStatusKey.initDataFetched);
    final identity = await _resolveDeviceIdentity();
    final dio = Dio(BaseOptions(baseUrl: _config.apiBaseUrl));
    authDebugInfo('Sending Telegram initData to OXPlayer API...', completeStatus: AuthDebugStatusKey.backendRequestSent);
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
      authDebugError('Backend response did not include accessToken.');
      throw StateError('API did not return accessToken');
    }
    authDebugSuccess('OXPlayer API returned backend access token.', completeStatus: AuthDebugStatusKey.backendAuthenticated);

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
    authDebugInfo('Resolving Telegram bot public chat...');
    final resolved = await _tdlib.send(
      td.SearchPublicChat(username: _config.botUsername),
    );
    if (resolved is! td.Chat || resolved.type is! td.ChatTypePrivate) {
      throw StateError('Cannot resolve BOT_USERNAME to a private chat');
    }

    final botUserId = (resolved.type as td.ChatTypePrivate).userId;
    authDebugSuccess('Telegram bot public chat resolved.');
    authDebugInfo('Opening private chat with Telegram bot...');
    final privateChat = await _tdlib.send(
      td.CreatePrivateChat(userId: botUserId, force: false),
    );
    if (privateChat is! td.Chat) {
      throw StateError('Failed to create private chat with bot');
    }
    authDebugSuccess('Private chat with Telegram bot is ready.');

    String? webAppUrl;
    td.TdError? shortNameError;

    if (_config.telegramWebAppShortName.isNotEmpty) {
      try {
        authDebugInfo('Requesting Telegram WebApp link by short name...');
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
          authDebugSuccess('Telegram WebApp link resolved by short name.');
        }
      } catch (error) {
        if (error is td.TdError) {
          shortNameError = error;
        }
        authDebugError('Telegram WebApp short-name lookup failed: $error');
      }
    }

    if (webAppUrl == null && _config.telegramWebAppUrl.isNotEmpty) {
      authDebugInfo('Requesting Telegram WebApp fallback URL...');
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
        authDebugSuccess('Telegram WebApp fallback URL resolved.');
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
    authDebugSuccess('Telegram signed initData extracted from WebApp URL.');
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