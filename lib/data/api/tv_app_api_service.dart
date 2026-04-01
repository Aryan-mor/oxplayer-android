import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:tdlib/td_api.dart' as td;

import '../../core/config/app_config.dart';
import '../../core/debug/app_debug_log.dart';
import '../../telegram/tdlib_facade.dart';
import '../models/app_media.dart';

void _apilog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.api);

class SyncLibraryResult {
  const SyncLibraryResult({
    required this.items,
    this.lastIndexedAt,
  });

  final List<AppMediaAggregate> items;
  final DateTime? lastIndexedAt;
}

class LibraryFetchResult {
  const LibraryFetchResult({
    required this.items,
    this.lastIndexedAt,
  });

  final List<AppMediaAggregate> items;
  final DateTime? lastIndexedAt;
}

class DiscoveredMediaRef {
  DiscoveredMediaRef({
    required this.mediaFileId,
    required this.sourceChatId,
    required this.sourceMessageId,
    required this.captionText,
    required this.telegramFileId,
    required this.telegramDate,
    this.fileSizeBytes,
  });

  final String mediaFileId;
  final int sourceChatId;
  final int sourceMessageId;
  final String captionText;
  final String? telegramFileId;
  /// `Message.date` from TDLib (Unix seconds); for ordering / incremental logic.
  final int telegramDate;
  /// TDLib [File.size] / [File.expectedSize] for the media attachment when known.
  final int? fileSizeBytes;

  Map<String, dynamic> toPersistenceJson() => {
        'mediaFileId': mediaFileId,
        // Stringify so JSON never truncates large TDLib message ids.
        'sourceChatId': sourceChatId.toString(),
        'sourceMessageId': sourceMessageId.toString(),
        'captionText': captionText,
        'telegramFileId': telegramFileId,
        'telegramDate': telegramDate,
        if (fileSizeBytes != null && fileSizeBytes! > 0)
          'fileSizeBytes': fileSizeBytes,
      };

  static DiscoveredMediaRef? fromPersistenceJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final mid = j['mediaFileId']?.toString() ?? '';
    final tf = j['telegramFileId']?.toString().trim() ?? '';
    if (mid.isEmpty || tf.isEmpty) return null;
    final sc = j['sourceChatId'];
    final sm = j['sourceMessageId'];
    final chatId = sc is int ? sc : int.tryParse(sc?.toString() ?? '') ?? 0;
    final msgId = sm is int ? sm : int.tryParse(sm?.toString() ?? '') ?? 0;
    final cap = j['captionText']?.toString() ?? '';
    final td = j['telegramDate'];
    final date = td is int ? td : int.tryParse(td?.toString() ?? '') ?? 0;
    final fs = j['fileSizeBytes'];
    final fileSize = fs is int
        ? fs
        : (fs != null ? int.tryParse(fs.toString()) : null);
    return DiscoveredMediaRef(
      mediaFileId: mid,
      sourceChatId: chatId,
      sourceMessageId: msgId,
      captionText: cap,
      telegramFileId: tf,
      telegramDate: date,
      fileSizeBytes: (fileSize != null && fileSize > 0) ? fileSize : null,
    );
  }
}

class TvAppApiService {
  static const int _kMaxSyncDiscoverItems = 500;

  TvAppApiService();
  int _requestCounter = 0;

  Dio _dio(String baseUrl) {
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        headers: const {
          // Needed for ngrok dev tunnels; ignored by normal backends.
          'ngrok-skip-browser-warning': 'true',
          'accept': 'application/json',
        },
      ),
    );

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final reqId = ++_requestCounter;
          final startedAt = DateTime.now().microsecondsSinceEpoch;
          options.extra['reqId'] = reqId;
          options.extra['startedAtUs'] = startedAt;
          _apilog(
            'API[$reqId] -> ${options.method} ${options.uri} '
            'headers=${_summarizeHeaders(options.headers)} '
            'body=${_summarizePayload(options.data)}',
          );
          handler.next(options);
        },
        onResponse: (response, handler) {
          final reqId = response.requestOptions.extra['reqId'] ?? '?';
          final startedAt = response.requestOptions.extra['startedAtUs'] as int?;
          final elapsedMs = startedAt == null
              ? -1
              : ((DateTime.now().microsecondsSinceEpoch - startedAt) / 1000)
                    .round();
          _apilog(
            'API[$reqId] <- ${response.statusCode} ${response.requestOptions.uri} '
            'in ${elapsedMs}ms '
            'body=${_summarizePayload(response.data)}',
          );
          handler.next(response);
        },
        onError: (error, handler) {
          final reqId = error.requestOptions.extra['reqId'] ?? '?';
          final startedAt = error.requestOptions.extra['startedAtUs'] as int?;
          final elapsedMs = startedAt == null
              ? -1
              : ((DateTime.now().microsecondsSinceEpoch - startedAt) / 1000)
                    .round();
          final status = error.response?.statusCode;
          _apilog(
            'API[$reqId] !! ${error.type} status=$status '
            '${error.requestOptions.method} ${error.requestOptions.uri} '
            'in ${elapsedMs}ms '
            'error=${error.message} '
            'body=${_summarizePayload(error.response?.data)}',
          );
          handler.next(error);
        },
      ),
    );

    return dio;
  }

  Future<String> authenticateWithTelegram({
    required TdlibFacade tdlib,
    required AppConfig config,
  }) async {
    _apilog(
      'API auth start: baseUrl=${config.tvAppApiBaseUrl}, '
      'bot=${config.botUsername}, shortName=${config.tvAppWebAppShortName}, '
      'fallbackUrlSet=${config.tvAppWebAppUrl.isNotEmpty}',
    );
    final initData = await _fetchSignedInitData(tdlib: tdlib, config: config);
    _apilog(
      'API auth: extracted initData length=${initData.length}',
    );
    final dio = _dio(config.tvAppApiBaseUrl);
    final response = await dio.post<Map<String, dynamic>>(
      '/auth/telegram',
      data: {'initData': initData},
    );

    final accessToken = response.data?['accessToken']?.toString() ?? '';
    if (accessToken.isEmpty) {
      throw StateError('API did not return accessToken');
    }
    _apilog(
      'API auth success: tokenLength=${accessToken.length}',
    );
    return accessToken;
  }

  DateTime? _parseLastIndexedAt(Map<String, dynamic>? body) {
    final raw = body?['lastIndexedAt'];
    if (raw == null) return null;
    final s = raw.toString().trim();
    if (s.isEmpty) return null;
    return DateTime.tryParse(s);
  }

  Future<LibraryFetchResult> fetchLibrary({
    required AppConfig config,
    required String accessToken,
  }) async {
    _apilog(
      'API fetchLibrary start: tokenLength=${accessToken.length}',
    );
    final dio = _dio(config.tvAppApiBaseUrl);
    final response = await dio.get<Map<String, dynamic>>(
      '/me/library',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
    final rawItems = response.data?['items'];
    if (rawItems is List && rawItems.isNotEmpty && rawItems.first is Map<String, dynamic>) {
      final first = rawItems.first as Map<String, dynamic>;
      final firstKeys = first.keys.toList()..sort();
      final hasMedia = first['media'] is Map<String, dynamic>;
      final hasFiles = first['files'] is List;
      final filesLen = hasFiles ? (first['files'] as List).length : -1;
      _apilog(
        'API fetchLibrary raw shape: items=${rawItems.length} '
        'firstKeys=$firstKeys hasMedia=$hasMedia hasFiles=$hasFiles firstFilesLen=$filesLen',
      );
      if (!hasMedia || !hasFiles) {
        _apilog(
          'API fetchLibrary raw shape mismatch: expected aggregate `{media, files[]}` from server',
        );
      }
    } else {
      _apilog(
        'API fetchLibrary raw shape: items is ${rawItems.runtimeType} '
        'value=${_summarizePayload(rawItems)}',
      );
    }
    final items = _readItems(response.data);
    final lastIndexedAt = _parseLastIndexedAt(response.data);
    final parsedFilesTotal = items.fold<int>(0, (sum, e) => sum + e.files.length);
    _apilog(
      'API fetchLibrary success: items=${items.length} parsedFilesTotal=$parsedFilesTotal '
      'lastIndexedAt=$lastIndexedAt',
    );
    return LibraryFetchResult(items: items, lastIndexedAt: lastIndexedAt);
  }

  Future<SyncLibraryResult> syncLibrary({
    required AppConfig config,
    required String accessToken,
    required List<String> mediaFileIds,
    List<DiscoveredMediaRef>? refs,
  }) async {
    _apilog(
      'API syncLibrary start: ids=${mediaFileIds.length}, tokenLength=${accessToken.length}',
    );
    final dio = _dio(config.tvAppApiBaseUrl);
    final body = <String, dynamic>{
      'mediaFileIds': mediaFileIds,
    };
    if (refs != null && refs.isNotEmpty) {
      body['refs'] = refs
          .map(
            (r) => <String, dynamic>{
              'mediaFileId': r.mediaFileId,
              if (r.telegramFileId != null && r.telegramFileId!.isNotEmpty)
                'telegramFileId': r.telegramFileId,
              'sourceChatId': r.sourceChatId,
              'sourceMessageId': r.sourceMessageId,
              'captionText': r.captionText,
              if (r.fileSizeBytes != null && r.fileSizeBytes! > 0)
                'fileSizeBytes': r.fileSizeBytes,
            },
          )
          .toList(growable: false);
    }
    final response = await dio.post<Map<String, dynamic>>(
      '/me/sync',
      data: body,
      options: Options(
        headers: {'Authorization': 'Bearer $accessToken'},
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final code = response.statusCode ?? 0;
    final items = _readItems(response.data);
    final lastIndexedAt = _parseLastIndexedAt(response.data);
    _apilog(
      'API syncLibrary done: status=$code items=${items.length} lastIndexedAt=$lastIndexedAt',
    );
    return SyncLibraryResult(items: items, lastIndexedAt: lastIndexedAt);
  }

  /// Asks [tv-app-api] → provider bot to copy the file from backup channels into the user chat.
  Future<bool> recoverMediaFileFromBackup({
    required AppConfig config,
    required String accessToken,
    required String mediaFileId,
  }) async {
    final dio = _dio(config.tvAppApiBaseUrl);
    _apilog(
      'API recoverFromBackup start mediaFileId=$mediaFileId',
    );
    final response = await dio.post<dynamic>(
      '/me/recover-from-backup',
      data: {'mediaFileId': mediaFileId},
      options: Options(
        headers: {'Authorization': 'Bearer $accessToken'},
        validateStatus: (_) => true,
      ),
    );
    final code = response.statusCode ?? 0;
    final ok = code == 200;
    _apilog(
      'API recoverFromBackup done status=$code recovered=$ok',
    );
    return ok;
  }

  /// Global hashtag search via TDLib `searchMessages` (all non-secret chats).
  /// Results are **reverse chronological** (newest first) per TDLib.
  /// [minMessageDateUtc]: only messages with `date >=` this instant (incremental sync).
  Future<void> collectMediaFileIdsFromTelegram({
    required TdlibFacade tdlib,
    required AppConfig config,
    required Future<void> Function(List<DiscoveredMediaRef> discoveredRefs) onBatch,
    DateTime? minMessageDateUtc,
  }) async {
    final minDateUnix = minMessageDateUtc != null
        ? (minMessageDateUtc.toUtc().millisecondsSinceEpoch ~/ 1000)
        : 0;
    _apilog(
      'Sync discover: searchMessages query=${config.indexTag} maxItems=$_kMaxSyncDiscoverItems '
      'minDateUnix=$minDateUnix',
    );
    await tdlib.ensureAuthorized();

    final byMediaFileId = <String, DiscoveredMediaRef>{};

    bool mergeRef(DiscoveredMediaRef next) {
      final id = next.mediaFileId.trim();
      final tf = next.telegramFileId?.trim() ?? '';
      if (id.isEmpty || tf.isEmpty) return false;
      final existing = byMediaFileId[id];
      if (existing != null) {
        if (next.telegramDate <= existing.telegramDate) return false;
        final mergedSize = (next.fileSizeBytes != null && next.fileSizeBytes! > 0)
            ? next.fileSizeBytes
            : existing.fileSizeBytes;
        byMediaFileId[id] = DiscoveredMediaRef(
          mediaFileId: next.mediaFileId,
          sourceChatId: next.sourceChatId,
          sourceMessageId: next.sourceMessageId,
          captionText: next.captionText,
          telegramFileId: next.telegramFileId,
          telegramDate: next.telegramDate,
          fileSizeBytes: mergedSize,
        );
        return true;
      }
      if (byMediaFileId.length >= _kMaxSyncDiscoverItems) return false;
      byMediaFileId[id] = next;
      return true;
    }

    var offset = '';
    for (var page = 0; page < 30; page++) {
      if (byMediaFileId.length >= _kMaxSyncDiscoverItems) break;
      final batch = await tdlib.send(
        td.SearchMessages(
          chatList: null,
          query: config.indexTag,
          offset: offset,
          limit: 100,
          filter: null,
          minDate: minDateUnix,
          maxDate: 0,
        ),
      );

      if (batch is! td.FoundMessages) {
        _apilog(
          'Sync discover: searchMessages unexpected ${batch.runtimeType}',
        );
        break;
      }
      for (final msg in batch.messages) {
        if (byMediaFileId.length >= _kMaxSyncDiscoverItems) break;
        final text = _extractText(msg);
        final mediaFileId = _extractMediaFileId(text);
        if (mediaFileId == null) continue;
        final telegramFileId = await _resolveTelegramFileId(tdlib, msg);
        var fileSizeBytes =
            await _resolveMediaFileSizeBytes(tdlib: tdlib, msg: msg);
        final tid = telegramFileId;
        if ((fileSizeBytes == null || fileSizeBytes <= 0) &&
            tid != null &&
            tid.isNotEmpty) {
          fileSizeBytes = await _fileSizeFromRemoteFileId(tdlib, tid);
        }
        // Captioner replies with [MessageText] that references the user's video; TDLib
        // download needs the **media** message id, not the bot caption message id.
        final locatorMessageId = _locatorMessageIdForSync(msg);
        mergeRef(
          DiscoveredMediaRef(
            mediaFileId: mediaFileId,
            sourceChatId: msg.chatId,
            sourceMessageId: locatorMessageId,
            captionText: text,
            telegramFileId: telegramFileId,
            telegramDate: msg.date,
            fileSizeBytes: fileSizeBytes,
          ),
        );
      }
      if (batch.nextOffset.isEmpty) break;
      offset = batch.nextOffset;
    }

    final list = byMediaFileId.values.toList(growable: false);
    try {
      await onBatch(list);
    } catch (e) {
      _apilog('Sync discover: onBatch failed with $e');
    }
    _apilog('Sync discover done: total mediaFileIds=${list.length}');
  }

  Future<String> _fetchSignedInitData({
    required TdlibFacade tdlib,
    required AppConfig config,
  }) async {
    await tdlib.ensureAuthorized();
    final resolved = await tdlib.send(
      td.SearchPublicChat(username: config.botUsername),
    );
    if (resolved is! td.Chat || resolved.type is! td.ChatTypePrivate) {
      throw StateError('Cannot resolve BOT_USERNAME to a private chat');
    }
    final botUserId = (resolved.type as td.ChatTypePrivate).userId;

    final privateChat = await tdlib.send(
      td.CreatePrivateChat(userId: botUserId, force: false),
    );
    if (privateChat is! td.Chat) {
      throw StateError('Failed to create private chat with bot');
    }

    String? webAppUrl;
    td.TdError? shortNameError;

    if (config.tvAppWebAppShortName.isNotEmpty) {
      try {
        _apilog(
          'InitData: trying GetWebAppLinkUrl shortName=${config.tvAppWebAppShortName}',
        );
        final result = await tdlib.send(
          td.GetWebAppLinkUrl(
            chatId: privateChat.id,
            botUserId: botUserId,
            webAppShortName: config.tvAppWebAppShortName,
            startParameter: '',
            theme: null,
            applicationName: 'telecima_tv',
            allowWriteAccess: true,
          ),
        );
        if (result is td.HttpUrl) {
          webAppUrl = result.url;
          _apilog(
            'InitData: shortName URL received (len=${webAppUrl.length})',
          );
        }
      } catch (e) {
        if (e is td.TdError) shortNameError = e;
        _apilog('InitData: shortName failed: $e');
      }
    }

    if (webAppUrl == null && config.tvAppWebAppUrl.isNotEmpty) {
      _apilog('InitData: trying GetWebAppUrl fallback');
      final fallbackResult = await tdlib.send(
        td.GetWebAppUrl(
          botUserId: botUserId,
          url: config.tvAppWebAppUrl,
          theme: null,
          applicationName: 'telecima_tv',
        ),
      );
      if (fallbackResult is td.HttpUrl) {
        webAppUrl = fallbackResult.url;
        _apilog(
          'InitData: fallback URL received (len=${webAppUrl.length})',
        );
      }
    }

    if (webAppUrl == null) {
      if (shortNameError != null) {
        throw StateError(
          'WebApp initData failed (${shortNameError.message}). '
          'Set TV_APP_WEBAPP_SHORT_NAME correctly or set TV_APP_WEBAPP_URL fallback.',
        );
      }
      throw StateError(
        'Cannot get WebApp URL. Set TV_APP_WEBAPP_SHORT_NAME or TV_APP_WEBAPP_URL in env.',
      );
    }

    final initData = _extractTgWebAppData(webAppUrl);
    if (initData == null || initData.isEmpty) {
      throw StateError('tgWebAppData not found in web app URL');
    }
    _logInitDataAuthAge(initData);
    _apilog(
      'InitData: tgWebAppData extracted (len=${initData.length})',
    );
    return initData;
  }

  List<AppMediaAggregate> _readItems(Map<String, dynamic>? body) {
    final raw = body?['items'];
    if (raw is! List) return const <AppMediaAggregate>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map((e) {
          try {
            return AppMediaAggregate.fromJson(e);
          } catch (_) {
            return null;
          }
        })
        .whereType<AppMediaAggregate>()
        .toList();
  }

  String _extractText(td.Message msg) {
    final content = msg.content;
    if (content is td.MessageVideo) return content.caption.text;
    if (content is td.MessageDocument) return content.caption.text;
    if (content is td.MessageText) return content.text.text;
    return '';
  }

  String? _extractMediaFileId(String text) {
    if (text.isEmpty) return null;
    final pattern = RegExp(
      r'MediaFileID:\s*(?:<code>)?([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12})',
      caseSensitive: false,
    );
    final match = pattern.firstMatch(text);
    return match?.group(1);
  }

  String? _extractTelegramFileId(td.Message msg) {
    try {
      final content = msg.content;
      if (content is td.MessageVideo) {
        final remote = content.video.video.remote;
        return remote.id.isNotEmpty ? remote.id : null;
      }
      if (content is td.MessageDocument) {
        final remote = content.document.document.remote;
        return remote.id.isNotEmpty ? remote.id : null;
      }
      if (content is td.MessageAnimation) {
        final remote = content.animation.animation.remote;
        return remote.id.isNotEmpty ? remote.id : null;
      }
      if (content is td.MessageVideoNote) {
        final remote = content.videoNote.video.remote;
        return remote.id.isNotEmpty ? remote.id : null;
      }
    } catch (_) {
      // Ignore malformed/unsupported messages.
    }
    return null;
  }

  /// Locator must target the message that **contains** the file. Captioner replies with
  /// [MessageText] that **replies to** the user's media; search returns that text message,
  /// so we use the replied-to [messageId] for [sourceMessageId].
  static int _locatorMessageIdForSync(td.Message msg) {
    final rt = msg.replyTo;
    if (rt is td.MessageReplyToMessage) {
      return rt.messageId;
    }
    return msg.id;
  }

  int? _nonzeroFileSize(td.File f) {
    if (f.size > 0) return f.size;
    if (f.expectedSize > 0) return f.expectedSize;
    return null;
  }

  int? _extractMediaFileSizeBytes(td.Message msg) {
    try {
      final content = msg.content;
      if (content is td.MessageVideo) {
        return _nonzeroFileSize(content.video.video);
      }
      if (content is td.MessageDocument) {
        return _nonzeroFileSize(content.document.document);
      }
      if (content is td.MessageAnimation) {
        return _nonzeroFileSize(content.animation.animation);
      }
      if (content is td.MessageVideoNote) {
        return _nonzeroFileSize(content.videoNote.video);
      }
    } catch (_) {}
    return null;
  }

  /// Resolves byte size from the message that carries the media (follows reply-to like [_resolveTelegramFileId]).
  Future<int?> _resolveMediaFileSizeBytes({
    required TdlibFacade tdlib,
    required td.Message msg,
  }) async {
    final direct = _extractMediaFileSizeBytes(msg);
    if (direct != null && direct > 0) return direct;

    final rt = msg.replyTo;
    if (rt is! td.MessageReplyToMessage) return null;

    var chatId = rt.chatId;
    if (chatId == 0) chatId = msg.chatId;

    try {
      final got = await tdlib.send(
        td.GetMessage(chatId: chatId, messageId: rt.messageId),
      );
      if (got is! td.Message) return null;
      return _extractMediaFileSizeBytes(got);
    } catch (_) {
      return null;
    }
  }

  /// When [GetMessage] on the media row fails, [GetRemoteFile] still exposes [File.size].
  Future<int?> _fileSizeFromRemoteFileId(
    TdlibFacade tdlib,
    String remoteFileId,
  ) async {
    final id = remoteFileId.trim();
    if (id.isEmpty) return null;
    try {
      final obj = await tdlib.send(
        td.GetRemoteFile(remoteFileId: id, fileType: null),
      );
      if (obj is td.File) return _nonzeroFileSize(obj);
    } catch (_) {}
    return null;
  }

  Future<String?> _resolveTelegramFileId(
    TdlibFacade tdlib,
    td.Message msg,
  ) async {
    final direct = _extractTelegramFileId(msg);
    if (direct != null && direct.isNotEmpty) return direct;

    final rt = msg.replyTo;
    if (rt is! td.MessageReplyToMessage) return null;

    var chatId = rt.chatId;
    if (chatId == 0) chatId = msg.chatId;

    final got = await tdlib.send(
      td.GetMessage(chatId: chatId, messageId: rt.messageId),
    );
    if (got is! td.Message) return null;
    return _extractTelegramFileId(got);
  }

  String? _extractTgWebAppData(String webAppUrl) {
    final uri = Uri.tryParse(webAppUrl);
    if (uri == null) return null;

    final fromQuery = uri.queryParameters['tgWebAppData'];
    if (fromQuery != null && fromQuery.isNotEmpty) {
      return Uri.decodeComponent(fromQuery);
    }

    final fragment = uri.fragment;
    if (fragment.isNotEmpty) {
      final fragmentUri = Uri.parse('https://local/?$fragment');
      final fromFragment = fragmentUri.queryParameters['tgWebAppData'];
      if (fromFragment != null && fromFragment.isNotEmpty) {
        return Uri.decodeComponent(fromFragment);
      }
    }
    return null;
  }

  String _summarizeHeaders(Map<String, dynamic> headers) {
    final cleaned = <String, dynamic>{};
    for (final entry in headers.entries) {
      final key = entry.key.toLowerCase();
      if (key == 'authorization') {
        cleaned[entry.key] = '<redacted>';
      } else {
        cleaned[entry.key] = entry.value;
      }
    }
    return cleaned.toString();
  }

  String _summarizePayload(dynamic payload) {
    if (payload == null) return 'null';
    String text;
    try {
      text = payload is String ? payload : jsonEncode(payload);
    } catch (_) {
      text = payload.toString();
    }
    if (text.length > 300) {
      return '${text.substring(0, 300)}...(${text.length} chars)';
    }
    return text;
  }

  void _logInitDataAuthAge(String initData) {
    try {
      final params = Uri.splitQueryString(initData);
      final authDateRaw = params['auth_date'];
      if (authDateRaw == null || authDateRaw.isEmpty) {
        _apilog('InitData: auth_date missing');
        return;
      }
      final authDate = int.tryParse(authDateRaw);
      if (authDate == null) {
        _apilog('InitData: auth_date invalid ($authDateRaw)');
        return;
      }
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final ageSec = nowSec - authDate;
      _apilog(
        'InitData: auth_date=$authDate now=$nowSec ageSec=$ageSec',
      );
    } catch (e) {
      _apilog('InitData: failed to parse auth_date: $e');
    }
  }
}
