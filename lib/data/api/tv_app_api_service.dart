import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:tdlib/td_api.dart' as td;

import '../../core/config/app_config.dart';
import '../../core/debug/app_debug_log.dart';
import '../../telegram/tdlib_facade.dart';
import '../models/app_media.dart';

void _apilog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.api);

class TelegramAuthResult {
  const TelegramAuthResult({
    required this.accessToken,
    this.preferredSubtitleLanguage,
    this.userType,
    this.userId,
    this.telegramId,
    this.username,
    this.firstName,
    this.phoneNumber,
  });

  final String accessToken;
  final String? preferredSubtitleLanguage;
  /// DEFAULT, ADMIN, or VIP from API `user.userType`.
  final String? userType;
  final String? userId;
  final String? telegramId;
  final String? username;
  final String? firstName;
  final String? phoneNumber;
}

class LibrarySourceFilterRow {
  const LibrarySourceFilterRow({
    required this.id,
    required this.label,
    this.thumbnail,
  });

  final String id;
  final String label;
  final String? thumbnail;

  factory LibrarySourceFilterRow.fromJson(Map<String, dynamic> json) {
    final thumb = json['thumbnail']?.toString().trim();
    return LibrarySourceFilterRow(
      id: (json['id'] ?? '').toString(),
      label: (json['label'] ?? json['name'] ?? '').toString(),
      thumbnail: (thumb != null && thumb.isNotEmpty) ? thumb : null,
    );
  }
}

class SyncLibraryResult {
  const SyncLibraryResult({
    required this.items,
    this.sources = const [],
    this.lastIndexedAt,
  });

  final List<AppMediaAggregate> items;
  final List<LibrarySourceFilterRow> sources;
  final DateTime? lastIndexedAt;
}

class LibraryFetchResult {
  const LibraryFetchResult({
    required this.items,
    this.sources = const [],
    this.lastIndexedAt,
  });

  final List<AppMediaAggregate> items;
  final List<LibrarySourceFilterRow> sources;
  final DateTime? lastIndexedAt;
}

/// Row from GET [/me/explore/media] (full catalog, not scoped to user library).
class ExploreCatalogItem {
  ExploreCatalogItem({
    required this.id,
    required this.title,
    required this.type,
    this.releaseYear,
    this.posterPath,
  });

  final String id;
  final String title;
  final String type;
  final int? releaseYear;
  final String? posterPath;

  factory ExploreCatalogItem.fromJson(Map<String, dynamic> json) {
    return ExploreCatalogItem(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      type: (json['type'] ?? 'UNKNOWN').toString(),
      releaseYear: json['releaseYear'] as int? ?? json['release_year'] as int?,
      posterPath: json['posterPath']?.toString() ?? json['poster_path']?.toString(),
    );
  }
}

class ExploreCatalogPage {
  const ExploreCatalogPage({
    required this.items,
    this.nextCursor,
  });

  final List<ExploreCatalogItem> items;
  final String? nextCursor;
}

/// Row from GET [/me/explore/genres].
class ExploreGenreRow {
  const ExploreGenreRow({
    required this.id,
    required this.title,
    required this.mediaCount,
  });

  final String id;
  final String title;
  final int mediaCount;

  factory ExploreGenreRow.fromJson(Map<String, dynamic> json) {
    final c = json['mediaCount'] ?? json['media_count'];
    final n = c is int ? c : int.tryParse(c?.toString() ?? '') ?? 0;
    return ExploreGenreRow(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      mediaCount: n,
    );
  }
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
    this.sourceName,
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
  /// Resolved via [GetChat] / [GetUser] for [Source.name] on the server.
  final String? sourceName;

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
        if (sourceName != null && sourceName!.trim().isNotEmpty)
          'sourceName': sourceName!.trim().length > 255
              ? sourceName!.trim().substring(0, 255)
              : sourceName!.trim(),
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
    final sn = j['sourceName']?.toString().trim();
    return DiscoveredMediaRef(
      mediaFileId: mid,
      sourceChatId: chatId,
      sourceMessageId: msgId,
      captionText: cap,
      telegramFileId: tf,
      telegramDate: date,
      fileSizeBytes: (fileSize != null && fileSize > 0) ? fileSize : null,
      sourceName: (sn != null && sn.isNotEmpty) ? sn : null,
    );
  }
}

class TvAppApiService {
  static const int _kMaxSyncDiscoverItems = 500;
  static const Duration _kSearchMessagesTimeout = Duration(seconds: 120);

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

  Future<TelegramAuthResult> authenticateWithTelegram({
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
    String? prefLang;
    String? userType;
    String? userId;
    String? telegramId;
    String? username;
    String? firstName;
    String? phoneNumber;
    final userRaw = response.data?['user'];
    if (userRaw is Map) {
      final um = Map<String, dynamic>.from(userRaw);
      final p = um['preferredSubtitleLanguage']?.toString().trim();
      prefLang = (p != null && p.isNotEmpty) ? p : null;
      final ut = um['userType']?.toString().trim();
      userType = (ut != null && ut.isNotEmpty) ? ut : null;
      final id = um['id']?.toString().trim();
      userId = (id != null && id.isNotEmpty) ? id : null;
      final tid = um['telegramId']?.toString().trim();
      telegramId = (tid != null && tid.isNotEmpty) ? tid : null;
      final u = um['username']?.toString().trim();
      username = (u != null && u.isNotEmpty) ? u : null;
      final fn = um['firstName']?.toString().trim();
      firstName = (fn != null && fn.isNotEmpty) ? fn : null;
      final ph = um['phoneNumber']?.toString().trim();
      phoneNumber = (ph != null && ph.isNotEmpty) ? ph : null;
    }
    _apilog(
      'API auth success: tokenLength=${accessToken.length} '
      'preferredSubtitleLanguage=${prefLang ?? '(null)'} userType=${userType ?? '(null)'} '
      'phoneNumber=${phoneNumber ?? '(null)'}',
    );
    return TelegramAuthResult(
      accessToken: accessToken,
      preferredSubtitleLanguage: prefLang,
      userType: userType,
      userId: userId,
      telegramId: telegramId,
      username: username,
      firstName: firstName,
      phoneNumber: phoneNumber,
    );
  }

  /// PATCH [/me/profile] — returns updated `user` map from the server.
  Future<Map<String, dynamic>> patchMeProfile({
    required AppConfig config,
    required String accessToken,
    required String phoneNumber,
  }) async {
    final dio = _dio(config.tvAppApiBaseUrl);
    final response = await dio.patch<Map<String, dynamic>>(
      '/me/profile',
      data: {'phoneNumber': phoneNumber.trim()},
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
    final u = response.data?['user'];
    if (u is Map) {
      return Map<String, dynamic>.from(u);
    }
    throw StateError('API did not return user object');
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
    final sources = _readSources(response.data);
    final lastIndexedAt = _parseLastIndexedAt(response.data);
    final parsedFilesTotal = items.fold<int>(0, (sum, e) => sum + e.files.length);
    _apilog(
      'API fetchLibrary success: items=${items.length} sources=${sources.length} '
      'parsedFilesTotal=$parsedFilesTotal lastIndexedAt=$lastIndexedAt',
    );
    return LibraryFetchResult(
      items: items,
      sources: sources,
      lastIndexedAt: lastIndexedAt,
    );
  }

  Future<List<ExploreGenreRow>> fetchExploreGenres({
    required AppConfig config,
    required String accessToken,
  }) async {
    final dio = _dio(config.tvAppApiBaseUrl);
    _apilog('API fetchExploreGenres');
    final response = await dio.get<Map<String, dynamic>>(
      '/me/explore/genres',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
    final raw = response.data?['genres'];
    final out = <ExploreGenreRow>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          try {
            out.add(ExploreGenreRow.fromJson(e));
          } catch (_) {}
        }
      }
    }
    _apilog('API fetchExploreGenres done count=${out.length}');
    return out;
  }

  Future<ExploreCatalogPage> fetchExploreCatalogPage({
    required AppConfig config,
    required String accessToken,
    String query = '',
    String? cursor,
    String? genreId,
    int limit = 30,
  }) async {
    final dio = _dio(config.tvAppApiBaseUrl);
    final qp = <String, dynamic>{'limit': limit};
    final q = query.trim();
    if (q.isNotEmpty) qp['q'] = q;
    final c = cursor?.trim();
    if (c != null && c.isNotEmpty) qp['cursor'] = c;
    final g = genreId?.trim();
    if (g != null && g.isNotEmpty) qp['genreId'] = g;

    _apilog(
      'API fetchExploreCatalogPage q="$q" cursor=$c genreId=$g limit=$limit',
    );
    final response = await dio.get<Map<String, dynamic>>(
      '/me/explore/media',
      queryParameters: qp,
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );

    final raw = response.data?['items'];
    final list = <ExploreCatalogItem>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          try {
            list.add(ExploreCatalogItem.fromJson(e));
          } catch (_) {
            // skip bad row
          }
        }
      }
    }
    final nc = response.data?['nextCursor']?.toString().trim();
    _apilog(
      'API fetchExploreCatalogPage done items=${list.length} nextCursor=$nc',
    );
    return ExploreCatalogPage(
      items: list,
      nextCursor: (nc != null && nc.isNotEmpty) ? nc : null,
    );
  }

  /// Full aggregate for a media id (same JSON shape as library items).
  Future<AppMediaAggregate?> fetchExploreMediaDetail({
    required AppConfig config,
    required String accessToken,
    required String mediaId,
  }) async {
    final id = mediaId.trim();
    if (id.isEmpty) return null;
    final dio = _dio(config.tvAppApiBaseUrl);
    final encoded = Uri.encodeComponent(id);
    _apilog('API fetchExploreMediaDetail id=$id');
    final response = await dio.get<Map<String, dynamic>>(
      '/me/explore/media/$encoded',
      options: Options(
        headers: {'Authorization': 'Bearer $accessToken'},
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final code = response.statusCode ?? 0;
    if (code == 404) return null;
    if (code != 200 || response.data == null) return null;
    try {
      return AppMediaAggregate.fromJson(response.data!);
    } catch (_) {
      return null;
    }
  }

  Future<SyncLibraryResult> syncLibrary({
    required AppConfig config,
    required String accessToken,
    required List<String> mediaFileIds,
    List<String>? mediaIds,
    List<DiscoveredMediaRef>? refs,
  }) async {
    _apilog(
      'API syncLibrary start: fileIds=${mediaFileIds.length} mediaIds=${mediaIds?.length ?? 0} '
      'tokenLength=${accessToken.length}',
    );
    final dio = _dio(config.tvAppApiBaseUrl);
    final body = <String, dynamic>{
      'mediaFileIds': mediaFileIds,
    };
    if (mediaIds != null && mediaIds.isNotEmpty) {
      body['mediaIds'] = mediaIds;
    }
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
              if (r.sourceName != null && r.sourceName!.trim().isNotEmpty)
                'sourceName': r.sourceName!.trim().length > 255
                    ? r.sourceName!.trim().substring(0, 255)
                    : r.sourceName!.trim(),
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
    final sources = _readSources(response.data);
    final lastIndexedAt = _parseLastIndexedAt(response.data);
    _apilog(
      'API syncLibrary done: status=$code items=${items.length} '
      'sources=${sources.length} lastIndexedAt=$lastIndexedAt',
    );
    return SyncLibraryResult(
      items: items,
      sources: sources,
      lastIndexedAt: lastIndexedAt,
    );
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

  static String _clipSourceLabel(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return 'Chat';
    return t.length > 255 ? t.substring(0, 255) : t;
  }

  static String _formatTdUserDisplay(td.User u) {
    final fn = u.firstName.trim();
    final ln = u.lastName.trim();
    final parts = [fn, ln].where((s) => s.isNotEmpty).join(' ');
    if (parts.isNotEmpty) return _clipSourceLabel(parts);
    final active = u.usernames?.activeUsernames ?? const <String>[];
    if (active.isNotEmpty) {
      final un = active.first.trim();
      if (un.isNotEmpty) {
        return _clipSourceLabel(un.startsWith('@') ? un : '@$un');
      }
    }
    return _clipSourceLabel('User ${u.id}');
  }

  static Future<String> _resolveChatSourceLabel(
    TdlibFacade tdlib,
    int chatId,
    int? myUserId,
    Map<int, String> cache,
  ) async {
    final hit = cache[chatId];
    if (hit != null) return hit;
    var label = 'Chat $chatId';
    try {
      final obj = await tdlib.send(td.GetChat(chatId: chatId));
      if (obj is td.Chat) {
        final chat = obj;
        final type = chat.type;
        if (type is td.ChatTypePrivate) {
          if (myUserId != null && type.userId == myUserId) {
            label = 'Saved messages';
          } else if (chat.title.trim().isNotEmpty) {
            label = chat.title.trim();
          } else {
            final u = await tdlib.send(td.GetUser(userId: type.userId));
            if (u is td.User) {
              label = _formatTdUserDisplay(u);
            }
          }
        } else if (chat.title.trim().isNotEmpty) {
          label = chat.title.trim();
        }
      }
    } catch (_) {
      // Keep fallback [label].
    }
    label = _clipSourceLabel(label);
    cache[chatId] = label;
    return label;
  }

  /// Global hashtag search via TDLib `searchMessages` (all non-secret chats).
  /// Results are **reverse chronological** (newest first) per TDLib.
  /// [minMessageDateUtc]: only messages with `date >=` this instant (incremental sync).
  Future<void> collectMediaFileIdsFromTelegram({
    required TdlibFacade tdlib,
    required AppConfig config,
    required Future<void> Function(
      List<DiscoveredMediaRef> discoveredRefs,
      Set<String> discoveredMediaIds,
    ) onBatch,
    DateTime? minMessageDateUtc,
    void Function()? onSyncAbortRequested,
  }) async {
    void abortStep() => onSyncAbortRequested?.call();
    final minDateUnix = minMessageDateUtc != null
        ? (minMessageDateUtc.toUtc().millisecondsSinceEpoch ~/ 1000)
        : 0;
    _apilog(
      'Sync discover: searchMessages query=${config.indexTag} maxItems=$_kMaxSyncDiscoverItems '
      'minDateUnix=$minDateUnix',
    );
    await tdlib.ensureAuthorized();
    abortStep();

    int? myUserId;
    try {
      final me = await tdlib.send(const td.GetMe());
      if (me is td.User) myUserId = me.id;
    } catch (_) {}
    abortStep();

    final chatLabelCache = <int, String>{};
    final byMediaFileId = <String, DiscoveredMediaRef>{};
    final discoveredMediaIds = <String>{};

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
        final mergedName = (next.sourceName != null &&
                next.sourceName!.trim().isNotEmpty)
            ? next.sourceName!.trim()
            : existing.sourceName;
        byMediaFileId[id] = DiscoveredMediaRef(
          mediaFileId: next.mediaFileId,
          sourceChatId: next.sourceChatId,
          sourceMessageId: next.sourceMessageId,
          captionText: next.captionText,
          telegramFileId: next.telegramFileId,
          telegramDate: next.telegramDate,
          fileSizeBytes: mergedSize,
          sourceName: mergedName,
        );
        return true;
      }
      if (byMediaFileId.length >= _kMaxSyncDiscoverItems) return false;
      byMediaFileId[id] = next;
      return true;
    }

    var offset = '';
    syncPages:
    for (var page = 0; page < 30; page++) {
      abortStep();
      if (byMediaFileId.length >= _kMaxSyncDiscoverItems &&
          discoveredMediaIds.length >= _kMaxSyncDiscoverItems) {
        break syncPages;
      }
      td.TdObject batch;
      StreamSubscription<void>? abortWhileSearch;
      try {
        final searchFuture = tdlib
            .send(
              td.SearchMessages(
                chatList: null,
                query: config.indexTag,
                offset: offset,
                limit: 100,
                filter: null,
                minDate: minDateUnix,
                maxDate: 0,
              ),
            )
            .timeout(_kSearchMessagesTimeout);

        if (onSyncAbortRequested != null) {
          final abortFromPoll = Completer<td.TdObject>();
          abortWhileSearch =
              Stream<void>.periodic(const Duration(milliseconds: 300))
                  .listen((_) {
            try {
              onSyncAbortRequested();
            } catch (e, st) {
              if (!abortFromPoll.isCompleted) {
                abortFromPoll.completeError(e, st);
              }
            }
          });
          batch = await Future.any<td.TdObject>([
            searchFuture,
            abortFromPoll.future,
          ]);
        } else {
          batch = await searchFuture;
        }
      } on TimeoutException {
        _apilog(
          'Sync discover: searchMessages timed out after '
          '${_kSearchMessagesTimeout.inSeconds}s (page=$page), using partial results',
        );
        break syncPages;
      } finally {
        await abortWhileSearch?.cancel();
      }

      if (batch is! td.FoundMessages) {
        _apilog(
          'Sync discover: searchMessages unexpected ${batch.runtimeType}',
        );
        break;
      }
      if (page == 0) {
        _apilog(
          'Sync discover: first page rawMessages=${batch.messages.length} '
          'nextOffsetLen=${batch.nextOffset.length}',
        );
      }
      for (final msg in batch.messages) {
        abortStep();
        if (byMediaFileId.length >= _kMaxSyncDiscoverItems &&
            discoveredMediaIds.length >= _kMaxSyncDiscoverItems) {
          break syncPages;
        }
        final text = _extractText(msg);
        final mediaIdTag = _extractMediaIdHashtag(text, config.indexTag);
        final mediaFileId = _extractMediaFileId(text, config.indexTag);
        final telegramFileId = await _resolveTelegramFileId(tdlib, msg);
        final hasFileLocator = telegramFileId != null && telegramFileId.trim().isNotEmpty;

        if (mediaIdTag != null &&
            discoveredMediaIds.length < _kMaxSyncDiscoverItems) {
          discoveredMediaIds.add(mediaIdTag);
        }

        // Access via `${INDEX_TAG}_M_<id>` does not require an attached file or reply.
        // Optional `${INDEX_TAG}_F_<id>` + TDLib file id still refines ingest / discovery store.
        if (byMediaFileId.length >= _kMaxSyncDiscoverItems) {
          continue;
        }
        if (mediaIdTag == null &&
            (mediaFileId == null || !hasFileLocator)) {
          continue;
        }
        if (mediaFileId == null || !hasFileLocator) {
          continue;
        }
        final tfResolved = telegramFileId.trim();
        var fileSizeBytes =
            await _resolveMediaFileSizeBytes(tdlib: tdlib, msg: msg);
        if ((fileSizeBytes == null || fileSizeBytes <= 0) && tfResolved.isNotEmpty) {
          fileSizeBytes = await _fileSizeFromRemoteFileId(tdlib, tfResolved);
        }
        // Captioner replies with [MessageText] that references the user's video; TDLib
        // download needs the **media** message id, not the bot caption message id.
        final locatorMessageId = _locatorMessageIdForSync(msg);
        final sourceLabel = await _resolveChatSourceLabel(
          tdlib,
          msg.chatId,
          myUserId,
          chatLabelCache,
        );
        mergeRef(
          DiscoveredMediaRef(
            mediaFileId: mediaFileId,
            sourceChatId: msg.chatId,
            sourceMessageId: locatorMessageId,
            captionText: text,
            telegramFileId: tfResolved,
            telegramDate: msg.date,
            fileSizeBytes: fileSizeBytes,
            sourceName: sourceLabel,
          ),
        );
      }
      if (batch.nextOffset.isEmpty) break;
      offset = batch.nextOffset;
    }

    final list = byMediaFileId.values.toList(growable: false);
    try {
      await onBatch(list, discoveredMediaIds);
    } catch (e) {
      _apilog('Sync discover: onBatch failed with $e');
    }
    _apilog(
      'Sync discover done: total mediaFileIds=${list.length} mediaIds=${discoveredMediaIds.length}',
    );
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

  List<LibrarySourceFilterRow> _readSources(Map<String, dynamic>? body) {
    final raw = body?['sources'];
    if (raw is! List) return const <LibrarySourceFilterRow>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map((e) {
          try {
            return LibrarySourceFilterRow.fromJson(e);
          } catch (_) {
            return null;
          }
        })
        .whereType<LibrarySourceFilterRow>()
        .toList();
  }

  String _extractText(td.Message msg) {
    final content = msg.content;
    if (content is td.MessageVideo) return content.caption.text;
    if (content is td.MessageDocument) return content.caption.text;
    if (content is td.MessageText) return content.text.text;
    if (content is td.MessagePhoto) return content.caption.text;
    if (content is td.MessageAnimation) return content.caption.text;
    return '';
  }

  static final RegExp _legacyMediaFileIdPattern = RegExp(
    r'MediaFileID:\s*(?:<code>)?([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12})',
    caseSensitive: false,
  );

  /// `${INDEX_TAG}_M_<mediaId>` — grants library access without a Telegram file on the message.
  String? _extractMediaIdHashtag(String text, String indexTag) {
    if (text.isEmpty) return null;
    final taggedNumeric = RegExp(
      '${RegExp.escape(indexTag)}_M_(\\d{1,19})(?!\\d)',
      caseSensitive: false,
    ).firstMatch(text);
    return taggedNumeric?.group(1);
  }

  String? _extractMediaFileId(String text, String indexTag) {
    if (text.isEmpty) return null;
    final taggedNumeric = RegExp(
      '${RegExp.escape(indexTag)}_F_(\\d{1,19})(?!\\d)',
      caseSensitive: false,
    ).firstMatch(text);
    if (taggedNumeric != null) return taggedNumeric.group(1);
    final legacy = _legacyMediaFileIdPattern.firstMatch(text)?.group(1);
    if (legacy != null) return legacy;
    final taggedUuid = RegExp(
      '${RegExp.escape(indexTag)}_F_([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12})',
      caseSensitive: false,
    ).firstMatch(text);
    return taggedUuid?.group(1);
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
