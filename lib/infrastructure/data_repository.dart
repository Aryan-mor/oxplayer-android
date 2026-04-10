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
import 'telegram/telegram_range_playback.dart';
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

class OxRequiredDialogMapping {
  const OxRequiredDialogMapping({
    required this.key,
    required this.botUsername,
    required this.isReady,
    this.mappingId,
    this.tdlibChatId,
    this.botApiChatId,
    this.botUserId,
    this.mappingSource,
  });

  final String key;
  final String botUsername;
  final bool isReady;
  final String? mappingId;
  final String? tdlibChatId;
  final String? botApiChatId;
  final String? botUserId;
  final String? mappingSource;
}

class OxBootstrapResult {
  const OxBootstrapResult({
    required this.telegramReady,
    required this.user,
    required this.session,
    required this.capabilities,
    required this.requiredDialogMappings,
  });

  final bool telegramReady;
  final OxBootstrapUser user;
  final OxBootstrapSession session;
  final OxBootstrapCapabilities capabilities;
  final List<OxRequiredDialogMapping> requiredDialogMappings;
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
    this.locatorRemoteFileId,
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
  final String? locatorRemoteFileId;
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

class OxLibraryGenre {
  const OxLibraryGenre({required this.id, required this.title});

  final String id;
  final String title;
}

class OxLibraryMediaDetailMedia {
  const OxLibraryMediaDetailMedia({
    required this.id,
    required this.title,
    required this.type,
    required this.genres,
    required this.createdAt,
    required this.updatedAt,
    this.imdbId,
    this.tmdbId,
    this.releaseYear,
    this.originalLanguage,
    this.posterPath,
    this.summary,
    this.voteAverage,
    this.rawDetails,
  });

  final String id;
  final String? imdbId;
  final String? tmdbId;
  final String title;
  final String type;
  final int? releaseYear;
  final String? originalLanguage;
  final String? posterPath;
  final String? summary;
  final double? voteAverage;
  final String? rawDetails;
  final List<OxLibraryGenre> genres;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class OxLibraryMediaDetailFile {
  const OxLibraryMediaDetailFile({
    required this.id,
    required this.mediaId,
    required this.fileUniqueId,
    required this.createdAt,
    required this.updatedAt,
    this.sourceId,
    this.sourceChatId,
    this.sourceName,
    this.videoLanguage,
    this.quality,
    this.size,
    this.versionTag,
    this.language,
    this.subtitleMentioned,
    this.subtitlePresentation,
    this.subtitleLanguage,
    this.captionText,
    this.canStream,
    this.season,
    this.episode,
    this.telegramFileId,
    this.locatorType,
    this.locatorChatId,
    this.locatorMessageId,
    this.locatorRemoteFileId,
  });

  final String id;
  final String mediaId;
  final String? sourceId;
  final int? sourceChatId;
  final String? sourceName;
  final String fileUniqueId;
  final String? videoLanguage;
  final String? quality;
  final int? size;
  final String? versionTag;
  final String? language;
  final bool? subtitleMentioned;
  final String? subtitlePresentation;
  final String? subtitleLanguage;
  final String? captionText;
  final bool? canStream;
  final int? season;
  final int? episode;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? telegramFileId;
  final String? locatorType;
  final int? locatorChatId;
  final int? locatorMessageId;
  final String? locatorRemoteFileId;
}

class OxLibraryMediaDetail {
  const OxLibraryMediaDetail({
    required this.media,
    required this.files,
    required this.currentUserHasAccess,
  });

  final OxLibraryMediaDetailMedia media;
  final List<OxLibraryMediaDetailFile> files;
  final bool currentUserHasAccess;
}

class _ThumbnailMessageLookupResult {
  const _ThumbnailMessageLookupResult({
    required this.message,
    this.failureReason,
    this.resolvedChatId,
    this.resolvedMessageId,
    this.resolutionReason,
  });

  final td.Message? message;
  final String? failureReason;
  final int? resolvedChatId;
  final int? resolvedMessageId;
  final String? resolutionReason;
}

class _ResolvedPlayableTelegramFile {
  const _ResolvedPlayableTelegramFile({
    required this.file,
    this.locatorChatId,
    this.locatorMessageId,
    this.locatorType,
    this.resolutionReason,
  });

  final td.File file;
  final int? locatorChatId;
  final int? locatorMessageId;
  final String? locatorType;
  final String? resolutionReason;
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
    final requiredDialogMappings = _parseRequiredDialogMappings(data['requiredDialogMappings']);

    if (requireTelegramSession && requiredDialogMappings.isNotEmpty) {
      final ensuredMappings = await _ensureRequiredDialogMappings(requiredDialogMappings);
      for (var index = 0; index < requiredDialogMappings.length; index += 1) {
        requiredDialogMappings[index] = ensuredMappings[index];
      }
    }

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
      requiredDialogMappings: requiredDialogMappings,
    );
  }

  Future<void> startQrLogin() async {
    authDebugInfo('Requesting QR login from TDLib...');
    await _tdlib.startQrLogin();
  }

  List<OxRequiredDialogMapping> _parseRequiredDialogMappings(Object? raw) {
    if (raw is! List) {
      return <OxRequiredDialogMapping>[];
    }

    return raw.whereType<Map>().map((entry) {
      final item = Map<String, dynamic>.from(entry);
      return OxRequiredDialogMapping(
        key: _readOptionalTrimmed(item['key']) ?? '',
        botUsername: _readOptionalTrimmed(item['botUsername']) ?? '',
        isReady: item['isReady'] == true,
        mappingId: _readOptionalTrimmed(item['mappingId']),
        tdlibChatId: _readOptionalTrimmed(item['tdlibChatId']),
        botApiChatId: _readOptionalTrimmed(item['botApiChatId']),
        botUserId: _readOptionalTrimmed(item['botUserId']),
        mappingSource: _readOptionalTrimmed(item['mappingSource']),
      );
    }).where((item) => item.botUsername.isNotEmpty).toList(growable: true);
  }

  Future<List<OxRequiredDialogMapping>> _ensureRequiredDialogMappings(
    List<OxRequiredDialogMapping> mappings,
  ) async {
    if (mappings.isEmpty) {
      return mappings;
    }

    final dio = _authorizedApiClient();
    final resolved = <OxRequiredDialogMapping>[];

    for (final mapping in mappings) {
      if (mapping.isReady && (mapping.tdlibChatId ?? '').isNotEmpty) {
        resolved.add(mapping);
        continue;
      }

      final privateChat = await _openBotPrivateChat(mapping.botUsername);
      if (privateChat == null) {
        resolved.add(mapping);
        continue;
      }

      final botUserId = privateChat.$2;
      final chat = privateChat.$1;
      try {
        final response = await dio.post<Map<String, dynamic>>(
          '/me/dialog-mappings/upsert',
          data: <String, dynamic>{
            'tdlibChatId': chat.id.toString(),
            'botUserId': botUserId.toString(),
            'botUsername': mapping.botUsername,
            'title': chat.title,
            'chatType': 'private',
            'peerIsBot': true,
            'mappingSource': 'merged',
          },
        );
        final raw = Map<String, dynamic>.from(response.data ?? const <String, dynamic>{});
        resolved.add(
          OxRequiredDialogMapping(
            key: mapping.key,
            botUsername: mapping.botUsername,
            isReady: true,
            mappingId: _readOptionalTrimmed(raw['id']) ?? mapping.mappingId,
            tdlibChatId: _readOptionalTrimmed(raw['tdlibChatId']) ?? chat.id.toString(),
            botApiChatId: _readOptionalTrimmed(raw['botApiChatId']) ?? mapping.botApiChatId,
            botUserId: _readOptionalTrimmed(raw['botUserId']) ?? botUserId.toString(),
            mappingSource: _readOptionalTrimmed(raw['mappingSource']) ?? 'merged',
          ),
        );
      } catch (_) {
        resolved.add(
          OxRequiredDialogMapping(
            key: mapping.key,
            botUsername: mapping.botUsername,
            isReady: true,
            mappingId: mapping.mappingId,
            tdlibChatId: chat.id.toString(),
            botApiChatId: mapping.botApiChatId,
            botUserId: botUserId.toString(),
            mappingSource: mapping.mappingSource ?? 'tdlib_only',
          ),
        );
      }
    }

    return resolved;
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

    return sections;
  }

  Future<OxLibraryMediaDetail> fetchOxLibraryMediaDetail(String globalId) async {
    final trimmedId = globalId.trim();
    if (trimmedId.isEmpty) {
      throw ArgumentError.value(globalId, 'globalId', 'globalId cannot be empty');
    }

    final dio = _authorizedApiClient();
    final response = await dio.get<Map<String, dynamic>>(
      '/me/library/media/${Uri.encodeComponent(trimmedId)}',
    );

    final root = response.data;
    if (root == null) {
      throw StateError('Library detail response is empty for $trimmedId');
    }

    final mediaRaw = root['media'];
    final filesRaw = root['files'];

    if (mediaRaw is! Map || filesRaw is! List) {
      throw StateError('Library detail response has unexpected shape for $trimmedId');
    }

    final media = _parseOxLibraryMediaDetailMedia(Map<String, dynamic>.from(mediaRaw));
    final files = filesRaw
        .whereType<Map>()
        .map((raw) => _parseOxLibraryMediaDetailFile(Map<String, dynamic>.from(raw)))
        .toList(growable: false);

    return OxLibraryMediaDetail(
      media: media,
      files: files,
      currentUserHasAccess: _readOptionalBool(root['currentUserHasAccess']) ?? false,
    );
  }

  Future<bool> requestOxMediaRecovery(String mediaId) async {
    final id = mediaId.trim();
    if (id.isEmpty) return false;

    try {
      final dio = _authorizedApiClient();
      final response = await dio.post<Map<String, dynamic>>(
        '/me/recover-from-backup',
        data: <String, dynamic>{'mediaFileId': id},
      );
      final body = response.data ?? const <String, dynamic>{};
      final ok = _readOptionalBool(body['ok']) ?? false;
      if (ok) return true;

      final status = _readOptionalTrimmed(body['status']);
      return status == 'succeeded';
    } catch (_) {
      return false;
    }
  }

  /// Resolves a playable local path for an OX media file via TDLib locator metadata.
  ///
  /// This prioritizes stable locator resolution, then waits for a readable file
  /// prefix (stream-like start), and finally falls back to a full file download.
  Future<String?> resolveOxMediaFilePathForPlayback({
    required String mediaId,
    required String? fileUniqueId,
    required String? locatorType,
    required int? locatorChatId,
    required int? locatorMessageId,
    required String? locatorRemoteFileId,
    bool allowQuickStart = true,
  }) async {
    playMediaDebugInfo(
      'Resolving OX playback path for mediaId=$mediaId locatorType=$locatorType locatorChatId=$locatorChatId locatorMessageId=$locatorMessageId',
    );
    final ready = await _ensureTdlibReadyForMediaPlayback();
    if (!ready) {
      playMediaDebugError('TDLib is not ready for media playback for mediaId=$mediaId');
      return null;
    }

    final resolved = await _resolvePlayableTelegramFileFromLocator(
      mediaId: mediaId,
      fileUniqueId: fileUniqueId,
      locatorType: locatorType,
      locatorChatId: locatorChatId,
      locatorMessageId: locatorMessageId,
      locatorRemoteFileId: locatorRemoteFileId,
    );
    if (resolved == null) {
      locatorDebugError(
        'Telegram media locator failed for mediaId=$mediaId fileUniqueId=$fileUniqueId locatorType=$locatorType locatorChatId=$locatorChatId locatorMessageId=$locatorMessageId locatorRemoteFileId=$locatorRemoteFileId',
      );
      return null;
    }

    locatorDebugSuccess(
      'Telegram media locator resolved for mediaId=$mediaId fileId=${resolved.file.id} reason=${resolved.resolutionReason}',
    );

    if (allowQuickStart) {
      final quickStartPath = await _waitForReadableVideoPrefix(resolved.file.id);
      if (quickStartPath != null && quickStartPath.isNotEmpty) {
        playMediaDebugSuccess(
          'Quick-start playback path resolved for mediaId=$mediaId at $quickStartPath',
        );
        return quickStartPath;
      }

      playMediaDebugInfo(
        'Quick-start path unavailable for mediaId=$mediaId. Falling back to full Telegram download for fileId=${resolved.file.id}',
      );
    } else {
      playMediaDebugInfo(
        'Quick-start playback disabled for mediaId=$mediaId. Waiting for full Telegram download for fileId=${resolved.file.id}',
      );
    }
    final downloadedPath = await _downloadTelegramFileFully(resolved.file.id);
    if (downloadedPath == null || downloadedPath.isEmpty) {
      playMediaDebugError(
        'Full Telegram download failed for mediaId=$mediaId fileId=${resolved.file.id}',
      );
      return null;
    }
    playMediaDebugSuccess(
      'Full Telegram download resolved playback path for mediaId=$mediaId at $downloadedPath',
    );
    return downloadedPath;
  }

  Future<Uri?> resolveOxMediaStreamUrlForPlayback({
    required String mediaId,
    required String? fileUniqueId,
    required String? locatorType,
    required int? locatorChatId,
    required int? locatorMessageId,
    required String? locatorRemoteFileId,
  }) async {
    playMediaDebugInfo(
      'Resolving OX stream URL for mediaId=$mediaId locatorType=$locatorType locatorChatId=$locatorChatId locatorMessageId=$locatorMessageId',
    );
    final ready = await _ensureTdlibReadyForMediaPlayback();
    if (!ready) {
      playMediaDebugError('TDLib is not ready for range playback for mediaId=$mediaId');
      return null;
    }

    final resolved = await _resolvePlayableTelegramFileFromLocator(
      mediaId: mediaId,
      fileUniqueId: fileUniqueId,
      locatorType: locatorType,
      locatorChatId: locatorChatId,
      locatorMessageId: locatorMessageId,
      locatorRemoteFileId: locatorRemoteFileId,
    );
    if (resolved == null) {
      locatorDebugError(
        'Telegram media locator failed for streaming mediaId=$mediaId fileUniqueId=$fileUniqueId locatorType=$locatorType locatorChatId=$locatorChatId locatorMessageId=$locatorMessageId locatorRemoteFileId=$locatorRemoteFileId',
      );
      return null;
    }

    locatorDebugSuccess(
      'Telegram media locator resolved for streaming mediaId=$mediaId fileId=${resolved.file.id} reason=${resolved.resolutionReason}',
    );

    final streamUrl = await TelegramRangePlayback.instance.openResolvedFile(
      tdlib: _tdlib,
      file: resolved.file,
      onDiagnostic: locatorDebugInfo,
    );
    if (streamUrl == null) {
      playMediaDebugError(
        'Telegram range playback failed for mediaId=$mediaId fileId=${resolved.file.id} reason=${TelegramRangePlayback.instance.lastOpenFailureReason}',
      );
      return null;
    }

    playMediaDebugSuccess(
      'Telegram range playback stream URL resolved for mediaId=$mediaId at $streamUrl',
    );
    return streamUrl;
  }

  Future<int> releaseOxMediaPlaybackSession({String? reason}) {
    return TelegramRangePlayback.instance.releaseActiveCacheIfAny(reason: reason);
  }

  Future<void> dispose() async {}

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
    String? locatorType,
    int? locatorChatId,
    int? locatorMessageId,
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
        fileUniqueId: fileUniqueId,
        locatorType: locatorType,
        locatorChatId: locatorChatId,
        locatorMessageId: locatorMessageId,
        locatorRemoteFileId: locatorRemoteFileId,
        onDiagnostic: (message) => debugLogInfo(message, type: LogType.telegramThumbnail),
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

      var message = await _resolveDirectThumbnailMessage(
        mediaId: mediaId,
        fileUniqueId: fileUniqueId,
        locatorType: locatorType,
        locatorChatId: locatorChatId,
        locatorMessageId: locatorMessageId,
      );

      if (message.message == null && chatId != null && messageId != null) {
        message = await _resolveThumbnailMessage(
          chatId: chatId,
          messageId: messageId,
          fileUniqueId: fileUniqueId,
        );
      }

      if (message.message == null) {
        debugLogError(
          message.failureReason ?? 'Could not resolve direct locator message for $mediaId.',
          type: LogType.telegramThumbnail,
        );
        unawaited(_requestThumbnailRecovery(mediaId, reason: 'direct_locator_message_missing'));
        return null;
      }

      final directThumbPath = await _downloadMessageThumbnailToCache(
        message: message.message!,
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
        message: message.message!,
        cachedFile: cachedFile,
      );
      if (generatedThumbPath != null) {
        debugLogSuccess(
          'Generated thumbnail from direct Telegram message for $mediaId at $generatedThumbPath.',
          type: LogType.telegramThumbnail,
        );
      } else {
        debugLogError(
          'Direct Telegram thumbnail generation failed for $mediaId. Requesting provider recovery.',
          type: LogType.telegramThumbnail,
        );
        unawaited(_requestThumbnailRecovery(mediaId, reason: 'direct_thumbnail_generation_failed'));
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

  Future<_ThumbnailMessageLookupResult> _resolveDirectThumbnailMessage({
    required String mediaId,
    required String? fileUniqueId,
    required String? locatorType,
    required int? locatorChatId,
    required int? locatorMessageId,
  }) async {
    if (locatorMessageId == null || locatorMessageId <= 0) {
      return _ThumbnailMessageLookupResult(
        message: null,
        failureReason: 'Direct locator for $mediaId has no locatorMessageId.',
      );
    }

    if (locatorType == 'CHAT_MESSAGE' && locatorChatId != null) {
      debugLogInfo(
        'Reading thumbnail from direct locator chat/message for $mediaId.',
        type: LogType.telegramThumbnail,
      );
      return _resolveThumbnailMessage(
        chatId: locatorChatId,
        messageId: locatorMessageId,
        exactChatIdOnly: false,
        fileUniqueId: fileUniqueId,
        onDiagnostic: (message) => debugLogInfo(message, type: LogType.locator),
      );
    }

    return _ThumbnailMessageLookupResult(
      message: null,
      failureReason: 'Direct locator for $mediaId has unsupported locatorType=$locatorType.',
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
  Future<(td.Chat, int)?> _openBotPrivateChat(String? botUsername) async {
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
        return (privateChat, botUserId);
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
    void Function(String message)? onDiagnostic,
  }) async {
    String? lastFailureReason;
    final chatCandidates = _candidateTelegramChatIds(chatId, exactOnly: exactChatIdOnly)
        .toList(growable: false);
    final messageCandidates = _candidateTelegramMessageIds(messageId).toList(growable: false);

    onDiagnostic?.call(
      'Stored locator direct lookup prepared for mediaFileId=n/a chatCandidates=$chatCandidates messageCandidates=$messageCandidates locatorRemoteFileId=n/a',
    );

    for (final chatCandidate in chatCandidates) {
      for (final messageCandidate in messageCandidates) {
        try {
          onDiagnostic?.call(
            'Trying Telegram message lookup chatCandidate=$chatCandidate messageCandidate=$messageCandidate',
          );
          final result = await _tdlib.send(
            td.GetMessage(chatId: chatCandidate, messageId: messageCandidate),
          );
          if (result is td.Message) {
            final resolutionReason =
                chatCandidate == chatId && messageCandidate == messageId
                ? 'direct_chat_message_exact'
                : 'direct_chat_message_candidate';
            onDiagnostic?.call(
              'Telegram message lookup succeeded for chatCandidate=$chatCandidate resolvedMessageId=${result.id} fileId=${_messagePlayableFileId(result)}',
            );
            return _ThumbnailMessageLookupResult(
              message: result,
              resolvedChatId: chatCandidate,
              resolvedMessageId: result.id,
              resolutionReason: resolutionReason,
            );
          }
        } on td.TdError catch (error) {
          onDiagnostic?.call(
            'Telegram message lookup failed for chatCandidate=$chatCandidate messageCandidate=$messageCandidate: code=${error.code} message=${error.message}',
          );
          lastFailureReason = 'Message lookup failed for chatCandidate=$chatCandidate messageCandidate=$messageCandidate: code=${error.code} message=${error.message}';
        } catch (error) {
          onDiagnostic?.call(
            'Telegram message lookup crashed for chatCandidate=$chatCandidate messageCandidate=$messageCandidate: $error',
          );
          lastFailureReason = 'Message lookup failed for chatCandidate=$chatCandidate messageCandidate=$messageCandidate: $error';
        }
      }
    }

    final trimmedFileUniqueId = fileUniqueId?.trim() ?? '';
    if (trimmedFileUniqueId.isNotEmpty) {
      for (final chatCandidate in chatCandidates) {
        onDiagnostic?.call(
          'Trying Telegram recent history fallback for chatCandidate=$chatCandidate fileUniqueId=$trimmedFileUniqueId',
        );
        final historyMatch = await _findMessageInRecentHistoryByFileUniqueId(
          chatId: chatCandidate,
          fileUniqueId: trimmedFileUniqueId,
          onDiagnostic: onDiagnostic,
        );
        if (historyMatch != null) {
          return historyMatch;
        }
      }
    }

    onDiagnostic?.call(
      'Stored locator direct lookup exhausted for mediaFileId=n/a requestedChatId=$chatId requestedMessageId=$messageId fileUniqueId=$fileUniqueId',
    );

    return _ThumbnailMessageLookupResult(
      message: null,
      failureReason: lastFailureReason ?? 'Message lookup failed for chat=$chatId message=$messageId.',
    );
  }

  Future<_ThumbnailMessageLookupResult?> _findMessageInRecentHistoryByFileUniqueId({
    required int chatId,
    required String fileUniqueId,
    void Function(String message)? onDiagnostic,
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
        onDiagnostic?.call(
          'Telegram recent history fallback matched chatCandidate=$chatId resolvedMessageId=${message.id} fileId=${_messagePlayableFileId(message)}',
        );
        return _ThumbnailMessageLookupResult(
          message: message,
          resolvedChatId: chatId,
          resolvedMessageId: message.id,
          resolutionReason: 'recent_history_file_unique_id',
        );
      }
      onDiagnostic?.call(
        'Telegram recent history fallback found no matching fileUniqueId for chatCandidate=$chatId',
      );
    } on td.TdError catch (error) {
      onDiagnostic?.call(
        'Telegram recent history fallback failed for chatCandidate=$chatId: code=${error.code} message=${error.message}',
      );
    } catch (error) {
      onDiagnostic?.call(
        'Telegram recent history fallback crashed for chatCandidate=$chatId: $error',
      );
    }

    return null;
  }

  Future<_ResolvedPlayableTelegramFile?> _resolvePlayableTelegramFileFromLocator({
    required String mediaId,
    required String? fileUniqueId,
    required String? locatorType,
    required int? locatorChatId,
    required int? locatorMessageId,
    required String? locatorRemoteFileId,
  }) async {
    if (locatorType == 'CHAT_MESSAGE' &&
        locatorChatId != null &&
        locatorMessageId != null) {
      final lookup = await _resolveThumbnailMessage(
        chatId: locatorChatId,
        messageId: locatorMessageId,
        exactChatIdOnly: false,
        fileUniqueId: fileUniqueId,
        onDiagnostic: (message) {
          locatorDebugInfo(
            message
                .replaceFirst('mediaFileId=n/a', 'mediaFileId=$mediaId')
                .replaceFirst('locatorRemoteFileId=n/a', 'locatorRemoteFileId=$locatorRemoteFileId'),
          );
        },
      );
      final message = lookup.message;
      if (message != null) {
        final file = _messagePlayableFile(message);
        if (file != null) {
          if (lookup.resolutionReason == 'recent_history_file_unique_id') {
            locatorDebugInfo(
              'Stored locator direct lookup did not resolve exact message for mediaFileId=$mediaId. History fallback recovered resolvedChatId=${lookup.resolvedChatId} resolvedMessageId=${lookup.resolvedMessageId} requestedChatId=$locatorChatId requestedMessageId=$locatorMessageId fileId=${file.id}',
            );
          } else if (lookup.resolvedMessageId != locatorMessageId ||
              lookup.resolvedChatId != locatorChatId) {
            locatorDebugInfo(
              'Stored locator direct lookup resolved with alternate candidate for mediaFileId=$mediaId requestedChatId=$locatorChatId requestedMessageId=$locatorMessageId resolvedChatId=${lookup.resolvedChatId} resolvedMessageId=${lookup.resolvedMessageId} reason=${lookup.resolutionReason} fileId=${file.id}',
            );
          } else {
            locatorDebugInfo(
              'Stored locator direct lookup resolved exact message for mediaFileId=$mediaId chatId=$locatorChatId messageId=$locatorMessageId fileId=${file.id}',
            );
          }
          return _ResolvedPlayableTelegramFile(
            file: file,
            locatorChatId: lookup.resolvedChatId ?? locatorChatId,
            locatorMessageId: lookup.resolvedMessageId ?? locatorMessageId,
            locatorType: 'CHAT_MESSAGE',
            resolutionReason: lookup.resolutionReason,
          );
        }
        locatorDebugError(
          'Telegram message lookup resolved for mediaFileId=$mediaId but message ${message.id} had no playable file',
        );
      }
    }

    final trimmedLocatorRemote = locatorRemoteFileId?.trim() ?? '';
    if (trimmedLocatorRemote.isNotEmpty) {
      try {
        locatorDebugInfo(
          'Trying Telegram remote file fallback for mediaFileId=$mediaId remoteFileId=$trimmedLocatorRemote',
        );
        final remoteFile = await _tdlib.send(
          td.GetRemoteFile(
            remoteFileId: trimmedLocatorRemote,
            fileType: null,
          ),
        );
        if (remoteFile is td.File) {
          locatorDebugInfo(
            'Telegram remote file fallback succeeded for mediaFileId=$mediaId fileId=${remoteFile.id}',
          );
          return _ResolvedPlayableTelegramFile(
            file: remoteFile,
            locatorType: 'REMOTE_FILE_ID',
            resolutionReason: 'get_remote_file_locator_remote',
          );
        }
        locatorDebugInfo(
          'Telegram remote file fallback returned ${remoteFile.runtimeType} for mediaFileId=$mediaId',
        );
      } on td.TdError catch (error) {
        locatorDebugInfo(
          'Telegram remote file fallback failed for mediaFileId=$mediaId: code=${error.code} message=${error.message}',
        );
      } catch (error) {
        locatorDebugInfo(
          'Telegram remote file fallback crashed for mediaFileId=$mediaId: $error',
        );
      }
    }

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

  Iterable<int> _candidateTelegramMessageIds(
    int messageId,
  ) sync* {
    final tdlibScaled = messageId * 1048576;
    yield messageId;
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

  td.File? _messagePlayableFile(td.Message message) {
    final content = message.content;
    if (content is td.MessageVideo) {
      return content.video.video;
    }
    if (content is td.MessageDocument) {
      return content.document.document;
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
        locatorRemoteFileId: _readOptionalTrimmed(item['locatorRemoteFileId']),
        thumbnailSourceChatId: (item['thumbnailSourceChatId'] as num?)?.toInt(),
        thumbnailSourceMessageId: (item['thumbnailSourceMessageId'] as num?)?.toInt(),
      );
    }).where((item) => item.globalId.isNotEmpty).toList(growable: false);
  }

  OxLibraryMediaDetailMedia _parseOxLibraryMediaDetailMedia(Map<String, dynamic> raw) {
    return OxLibraryMediaDetailMedia(
      id: _readOptionalTrimmed(raw['id']) ?? '',
      imdbId: _readOptionalTrimmed(raw['imdbId']),
      tmdbId: _readOptionalTrimmed(raw['tmdbId']),
      title: _readOptionalTrimmed(raw['title']) ?? 'Untitled',
      type: _readOptionalTrimmed(raw['type']) ?? 'UNKNOWN',
      releaseYear: _readOptionalInt(raw['releaseYear']),
      originalLanguage: _readOptionalTrimmed(raw['originalLanguage']),
      posterPath: _readOptionalTrimmed(raw['posterPath']),
      summary: _readOptionalTrimmed(raw['summary']),
      voteAverage: _readOptionalDouble(raw['voteAverage']),
      rawDetails: _readOptionalTrimmed(raw['rawDetails']),
      genres: _parseOxGenres(raw['genres']),
      createdAt: _readDateTimeOrEpoch(raw['createdAt']),
      updatedAt: _readDateTimeOrEpoch(raw['updatedAt']),
    );
  }

  OxLibraryMediaDetailFile _parseOxLibraryMediaDetailFile(Map<String, dynamic> raw) {
    return OxLibraryMediaDetailFile(
      id: _readOptionalTrimmed(raw['id']) ?? '',
      mediaId: _readOptionalTrimmed(raw['mediaId']) ?? '',
      sourceId: _readOptionalTrimmed(raw['sourceId']),
      sourceChatId: _readOptionalInt(raw['sourceChatId']),
      sourceName: _readOptionalTrimmed(raw['sourceName']),
      fileUniqueId: _readOptionalTrimmed(raw['fileUniqueId']) ?? '',
      videoLanguage: _readOptionalTrimmed(raw['videoLanguage']),
      quality: _readOptionalTrimmed(raw['quality']),
      size: _readOptionalInt(raw['size']),
      versionTag: _readOptionalTrimmed(raw['versionTag']),
      language: _readOptionalTrimmed(raw['language']),
      subtitleMentioned: _readOptionalBool(raw['subtitleMentioned']),
      subtitlePresentation: _readOptionalTrimmed(raw['subtitlePresentation']),
      subtitleLanguage: _readOptionalTrimmed(raw['subtitleLanguage']),
      captionText: _readOptionalTrimmed(raw['captionText']),
      canStream: _readOptionalBool(raw['canStream']),
      season: _readOptionalInt(raw['season']),
      episode: _readOptionalInt(raw['episode']),
      createdAt: _readDateTimeOrEpoch(raw['createdAt']),
      updatedAt: _readDateTimeOrEpoch(raw['updatedAt']),
      telegramFileId: _readOptionalTrimmed(raw['telegramFileId']),
      locatorType: _readOptionalTrimmed(raw['locatorType']),
      locatorChatId: _readOptionalInt(raw['locatorChatId']),
      locatorMessageId: _readOptionalInt(raw['locatorMessageId']),
      locatorRemoteFileId: _readOptionalTrimmed(raw['locatorRemoteFileId']),
    );
  }

  List<OxLibraryGenre> _parseOxGenres(Object? rawGenres) {
    if (rawGenres is! List) {
      return const <OxLibraryGenre>[];
    }

    return rawGenres.whereType<Map>().map((raw) {
      final genre = Map<String, dynamic>.from(raw);
      return OxLibraryGenre(
        id: _readOptionalTrimmed(genre['id']) ?? '',
        title: _readOptionalTrimmed(genre['title']) ?? '',
      );
    }).where((genre) => genre.id.isNotEmpty || genre.title.isNotEmpty).toList(growable: false);
  }

  DateTime _readDateTimeOrEpoch(Object? raw) {
    final parsed = DateTime.tryParse(raw?.toString() ?? '');
    return parsed ?? DateTime.fromMillisecondsSinceEpoch(0);
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

  Future<bool> _ensureTdlibReadyForMediaPlayback() async {
    if (!_tdlibInitialized || !_tdlib.isInitialized) {
      final apiId = int.tryParse(_config.telegramApiId) ?? 0;
      if (!_config.hasTelegramKeys || apiId <= 0) {
        return false;
      }
      try {
        await _ensureTdlibInitialized(apiId: apiId);
      } catch (_) {
        return false;
      }
    }

    try {
      await _tdlib.ensureAuthorized();
      return true;
    } catch (_) {
      return false;
    }
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

  int? _readOptionalInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '');
  }

  double? _readOptionalDouble(Object? raw) {
    if (raw is double) return raw;
    if (raw is num) return raw.toDouble();
    return double.tryParse(raw?.toString() ?? '');
  }

  bool? _readOptionalBool(Object? raw) {
    if (raw is bool) return raw;
    if (raw is num) {
      if (raw == 1) return true;
      if (raw == 0) return false;
    }
    final text = raw?.toString().trim().toLowerCase();
    if (text == 'true' || text == '1') return true;
    if (text == 'false' || text == '0') return false;
    return null;
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