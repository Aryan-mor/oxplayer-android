import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tdlib/td_api.dart' as td;

import '../../core/config/app_config.dart';
import '../../core/debug/app_debug_log.dart';
import '../../telegram/tdlib_facade.dart';
import '../models/app_media.dart';
import '../models/series_episode_guide.dart';

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

class RequestMediaFileResult {
  const RequestMediaFileResult({
    required this.ok,
    required this.mediaId,
    required this.notifiedAdmins,
    required this.notifyFailed,
  });

  final bool ok;
  final String mediaId;
  final int notifiedAdmins;
  final bool notifyFailed;
}

const _kApiDeviceIdPrefsKey = 'OXPLAYER_API_DEVICE_ID';
const _kDefaultDeviceName = 'Oxplayer Flutter';

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
      posterPath:
          json['posterPath']?.toString() ?? json['poster_path']?.toString(),
    );
  }
}

/// TMDB search row from GET [/me/explore/media] when `q` is non-empty.
class ExploreTmdbItem {
  ExploreTmdbItem({
    required this.tmdbKey,
    required this.title,
    required this.type,
    this.releaseYear,
    this.posterPath,
  });

  final String tmdbKey;
  final String title;
  final String type;
  final int? releaseYear;
  final String? posterPath;

  factory ExploreTmdbItem.fromJson(Map<String, dynamic> json) {
    return ExploreTmdbItem(
      tmdbKey: (json['tmdbKey'] ?? json['tmdb_key'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      type: (json['type'] ?? 'UNKNOWN').toString(),
      releaseYear: json['releaseYear'] as int? ?? json['release_year'] as int?,
      posterPath:
          json['posterPath']?.toString() ?? json['poster_path']?.toString(),
    );
  }
}

class ExploreCatalogPage {
  const ExploreCatalogPage({
    required this.items,
    this.nextCursor,
    this.pendingItems = const [],
    this.pendingNextCursor,
    this.tmdbItems = const [],
    this.tmdbHasMore = false,
  });

  final List<ExploreCatalogItem> items;
  final String? nextCursor;
  final List<ExploreCatalogItem> pendingItems;
  final String? pendingNextCursor;
  final List<ExploreTmdbItem> tmdbItems;
  final bool tmdbHasMore;
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

class OxplayerApiService {
  OxplayerApiService();
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
          final startedAt =
              response.requestOptions.extra['startedAtUs'] as int?;
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
      'API auth start: baseUrl=${config.apiBaseUrl}, '
      'bot=${config.botUsername}, shortName=${config.telegramWebAppShortName}, '
      'fallbackUrlSet=${config.telegramWebAppUrl.isNotEmpty}',
    );
    final initData = await _fetchSignedInitData(tdlib: tdlib, config: config);
    final identity = await _resolveDeviceIdentity();
    _apilog(
      'API auth: extracted initData length=${initData.length} '
      'deviceId=${identity.deviceId}',
    );
    final dio = _dio(config.apiBaseUrl);
    final response = await dio.post<Map<String, dynamic>>(
      '/auth/telegram',
      data: {
        'initData': initData,
        'deviceId': identity.deviceId,
        if (identity.deviceName != null) 'deviceName': identity.deviceName,
      },
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

  /// Single GET [/me/library/media] for one `kind` (`movie` | `series` | `general_video`).
  Future<List<AppMediaAggregate>> fetchLibraryMediaByKind({
    required AppConfig config,
    required String accessToken,
    required String kind,
    int limit = 100,
  }) async {
    final lim = limit.clamp(1, 100);
    final dio = _dio(config.apiBaseUrl);
    final headers = Options(headers: {'Authorization': 'Bearer $accessToken'});
    final response = await dio.get<Map<String, dynamic>>(
      '/me/library/media',
      queryParameters: <String, dynamic>{
        'kind': kind,
        'limit': lim,
        'sort': 'created_desc',
      },
      options: headers,
    );
    final status = response.statusCode;
    final rawItems = response.data?['items'];
    if (rawItems is! List) {
      _apilog(
        'API fetchLibraryMediaByKind kind=$kind: status=$status items not a List '
        '(got ${rawItems?.runtimeType}); dataKeys=${response.data?.keys.toList()}',
      );
      return const [];
    }
    final out = <AppMediaAggregate>[];
    var added = 0;
    var skipped = 0;
    var skipSamplesLogged = 0;
    for (final e in rawItems) {
      if (e is! Map) {
        skipped++;
        continue;
      }
      final map = Map<String, dynamic>.from(e);
      final agg = _libraryMediaRowToAggregate(map);
      if (agg != null) {
        out.add(agg);
        added++;
      } else {
        skipped++;
        if (skipSamplesLogged < 5) {
          skipSamplesLogged++;
          final k = (map['kind'] ?? '').toString();
          final t = (map['title'] ?? '').toString();
          final mid = (map['mediaId'] ?? map['media_id'] ?? '').toString();
          final sid = (map['seriesId'] ?? map['series_id'] ?? '').toString();
          _apilog(
            'API fetchLibraryMediaByKind skip sample#$skipSamplesLogged kind=$kind rowKind=$k '
            'titleLen=${t.length} mediaId="$mid" seriesId="$sid" keys=${map.keys.toList()}',
          );
        }
      }
    }
    out.sort((a, b) => b.media.createdAt.compareTo(a.media.createdAt));
    _apilog(
      'API fetchLibraryMediaByKind kind=$kind: status=$status raw=${rawItems.length} '
      'added=$added skipped=$skipped',
    );
    return out;
  }

  Future<LibraryFetchResult> fetchLibrary({
    required AppConfig config,
    required String accessToken,
    int perKindLimit = 100,
  }) async {
    final limit = perKindLimit.clamp(1, 100);
    _apilog(
      'API fetchLibrary start: tokenLength=${accessToken.length} '
      'perKindLimit=$limit',
    );
    const kinds = ['movie', 'series', 'general_video'];
    final aggregates = <AppMediaAggregate>[];
    for (final kind in kinds) {
      final part = await fetchLibraryMediaByKind(
        config: config,
        accessToken: accessToken,
        kind: kind,
        limit: limit,
      );
      aggregates.addAll(part);
    }

    aggregates.sort(
      (a, b) => b.media.createdAt.compareTo(a.media.createdAt),
    );

    final typeHist = <String, int>{};
    for (final a in aggregates) {
      typeHist[a.media.type] = (typeHist[a.media.type] ?? 0) + 1;
    }
    final titlesPreview = aggregates
        .take(4)
        .map((a) => '"${a.media.title}" (${a.media.type})')
        .join('; ');
    _apilog(
      'API fetchLibrary success: mergedItems=${aggregates.length} typeHist=$typeHist '
      'preview=[$titlesPreview]',
    );
    return LibraryFetchResult(
      items: aggregates,
      sources: const [],
      lastIndexedAt: null,
    );
  }

  /// Maps a light `/me/library/media` row to [AppMediaAggregate] (no files until detail API).
  AppMediaAggregate? _libraryMediaRowToAggregate(Map<String, dynamic> row) {
    final kind = (row['kind'] ?? '').toString();
    final title = (row['title'] ?? '').toString();
    if (title.isEmpty) return null;

    final createdAtRaw = row['createdAt'] ?? row['created_at'];
    final createdAt = createdAtRaw != null
        ? DateTime.tryParse(createdAtRaw.toString()) ?? DateTime.now()
        : DateTime.now();

    final posterPath =
        row['posterPath']?.toString() ?? row['poster_path']?.toString();
    final tmdbId = row['tmdbId']?.toString() ?? row['tmdb_id']?.toString();

    final genresRaw = row['genres'];
    final genres = <MediaGenreRef>[];
    if (genresRaw is List) {
      for (final g in genresRaw) {
        if (g is Map<String, dynamic>) {
          final id = (g['id'] ?? '').toString();
          final t = (g['title'] ?? '').toString();
          if (id.isNotEmpty && t.isNotEmpty) {
            genres.add(MediaGenreRef(id: id, title: t));
          }
        }
      }
    }

    late final String id;
    late final String type;
    switch (kind) {
      case 'series':
        final sid = (row['seriesId'] ?? row['series_id'] ?? '').toString();
        if (sid.isEmpty) return null;
        id = 'series:$sid';
        type = 'SERIES';
      case 'movie':
        final mid = (row['mediaId'] ?? row['media_id'] ?? '').toString();
        if (mid.isEmpty) return null;
        id = mid;
        type = 'MOVIE';
      case 'general_video':
        final mid = (row['mediaId'] ?? row['media_id'] ?? '').toString();
        if (mid.isEmpty) return null;
        id = mid;
        type = 'GENERAL_VIDEO';
      default:
        return null;
    }

    final tid = tmdbId?.trim();
    final overviewRaw = row['overview']?.toString().trim();
    final overview =
        overviewRaw != null && overviewRaw.isNotEmpty ? overviewRaw : null;
    final voteRaw = row['voteAverage'] ?? row['vote_average'];
    final double? voteAvg =
        voteRaw is num && voteRaw.isFinite ? voteRaw.toDouble() : null;

    final media = AppMedia(
      id: id,
      tmdbId: (tid == null || tid.isEmpty) ? null : tid,
      title: title,
      type: type,
      posterPath: posterPath != null && posterPath.trim().isNotEmpty
          ? posterPath.trim()
          : null,
      summary: overview,
      voteAverage: voteAvg,
      genres: genres,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    return AppMediaAggregate(media: media, files: const []);
  }

  Future<List<ExploreGenreRow>> fetchExploreGenres({
    required AppConfig config,
    required String accessToken,
  }) async {
    final dio = _dio(config.apiBaseUrl);
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
    String? pendingCursor,
    String? genreId,
    int limit = 20,
    String? section,
    int? tmdbPage,
  }) async {
    final dio = _dio(config.apiBaseUrl);
    final qp = <String, dynamic>{'limit': limit};
    final q = query.trim();
    if (q.isNotEmpty) qp['q'] = q;
    final c = cursor?.trim();
    if (c != null && c.isNotEmpty) qp['cursor'] = c;
    final pc = pendingCursor?.trim();
    if (pc != null && pc.isNotEmpty) qp['pendingCursor'] = pc;
    final g = genreId?.trim();
    if (g != null && g.isNotEmpty) qp['genreId'] = g;
    final sec = section?.trim();
    if (sec != null && sec.isNotEmpty) qp['section'] = sec;
    if (tmdbPage != null && tmdbPage >= 1) qp['tmdbPage'] = tmdbPage;

    _apilog(
      'API fetchExploreCatalogPage q="$q" cursor=$c pendingCursor=$pc genreId=$g limit=$limit section=$sec tmdbPage=$tmdbPage',
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

    final pendingRaw =
        response.data?['pendingItems'] ?? response.data?['pending_items'];
    final pendingList = <ExploreCatalogItem>[];
    if (pendingRaw is List) {
      for (final e in pendingRaw) {
        if (e is Map<String, dynamic>) {
          try {
            pendingList.add(ExploreCatalogItem.fromJson(e));
          } catch (_) {}
        }
      }
    }

    final tmdbRaw = response.data?['tmdbItems'] ?? response.data?['tmdb_items'];
    final tmdbList = <ExploreTmdbItem>[];
    if (tmdbRaw is List) {
      for (final e in tmdbRaw) {
        if (e is Map<String, dynamic>) {
          try {
            tmdbList.add(ExploreTmdbItem.fromJson(e));
          } catch (_) {}
        }
      }
    }

    final nc = response.data?['nextCursor']?.toString().trim();
    final pnc = response.data?['pendingNextCursor']?.toString().trim() ??
        response.data?['pending_next_cursor']?.toString().trim();
    final thm =
        response.data?['tmdbHasMore'] ?? response.data?['tmdb_has_more'];
    final tmdbHasMore = thm == true || thm == 1 || thm == '1' || thm == 'true';
    _apilog(
      'API fetchExploreCatalogPage done items=${list.length} pending=${pendingList.length} tmdb=${tmdbList.length} nextCursor=$nc pendingNext=$pnc tmdbHasMore=$tmdbHasMore',
    );
    return ExploreCatalogPage(
      items: list,
      nextCursor: (nc != null && nc.isNotEmpty) ? nc : null,
      pendingItems: pendingList,
      pendingNextCursor: (pnc != null && pnc.isNotEmpty) ? pnc : null,
      tmdbItems: tmdbList,
      tmdbHasMore: tmdbHasMore,
    );
  }

  /// Creates or updates a [Media] row from TMDB (explore).
  Future<String> exploreEnsureMediaFromTmdb({
    required AppConfig config,
    required String accessToken,
    required String tmdbKey,
  }) async {
    final dio = _dio(config.apiBaseUrl);
    final k = tmdbKey.trim();
    _apilog('API exploreEnsureMediaFromTmdb tmdbKey=$k');
    final response = await dio.post<Map<String, dynamic>>(
      '/me/explore/media/from-tmdb',
      data: <String, dynamic>{'tmdbKey': k},
      options: Options(
        headers: {'Authorization': 'Bearer $accessToken'},
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final code = response.statusCode ?? 0;
    if (code != 200 || response.data == null) {
      final msg =
          response.data?['message']?.toString() ?? 'Could not add title';
      throw Exception(msg);
    }
    final id = response.data!['mediaId']?.toString().trim() ?? '';
    if (id.isEmpty) throw Exception('Invalid response');
    return id;
  }

  /// Request that admins upload a file; grants [user_access] for this media.
  Future<RequestMediaFileResult> requestMediaFile({
    required AppConfig config,
    required String accessToken,
    required String mediaId,
  }) async {
    final dio = _dio(config.apiBaseUrl);
    final id = mediaId.trim();
    final encoded = Uri.encodeComponent(id);
    _apilog('API requestMediaFile mediaId=$id');
    final response = await dio.post<Map<String, dynamic>>(
      '/me/media/$encoded/request-file',
      options: Options(
        headers: {'Authorization': 'Bearer $accessToken'},
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final code = response.statusCode ?? 0;
    if (code != 200 || response.data == null) {
      final msg = response.data?['message']?.toString() ?? 'Request failed';
      throw Exception(msg);
    }
    final d = response.data!;
    return RequestMediaFileResult(
      ok: d['ok'] == true,
      mediaId: d['mediaId']?.toString() ?? id,
      notifiedAdmins: (d['notifiedAdmins'] is int)
          ? d['notifiedAdmins'] as int
          : int.tryParse(d['notifiedAdmins']?.toString() ?? '') ?? 0,
      notifyFailed: d['notifyFailed'] == true,
    );
  }

  /// Full aggregate from library detail route (works for media id and `series:<id>`).
  Future<AppMediaAggregate?> fetchLibraryMediaDetail({
    required AppConfig config,
    required String accessToken,
    required String mediaId,
  }) async {
    final id = mediaId.trim();
    if (id.isEmpty) return null;
    final dio = _dio(config.apiBaseUrl);
    final encoded = Uri.encodeComponent(id);
    _apilog('API fetchLibraryMediaDetail id=$id');
    final response = await dio.get<Map<String, dynamic>>(
      '/me/library/media/$encoded',
      options: Options(
        headers: {'Authorization': 'Bearer $accessToken'},
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final code = response.statusCode ?? 0;
    if (code == 404 || code == 403 || code == 401) return null;
    if (code != 200 || response.data == null) return null;
    try {
      return AppMediaAggregate.fromJson(response.data!);
    } catch (_) {
      return null;
    }
  }

  /// Full aggregate for a media id (same JSON shape as library items).
  Future<AppMediaAggregate?> fetchExploreMediaDetail({
    required AppConfig config,
    required String accessToken,
    required String mediaId,
  }) async {
    final id = mediaId.trim();
    if (id.isEmpty) return null;
    final dio = _dio(config.apiBaseUrl);
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

  /// TMDB season/episode names for a series (`tmdbId` prefix `tv:` from TMDB). Empty seasons if not a series / no TMDB.
  Future<SeriesEpisodeGuide?> fetchSeriesEpisodeGuide({
    required AppConfig config,
    required String accessToken,
    required String mediaId,
  }) async {
    final id = mediaId.trim();
    if (id.isEmpty) return null;
    final dio = _dio(config.apiBaseUrl);
    final encoded = Uri.encodeComponent(id);
    _apilog('API fetchSeriesEpisodeGuide mediaId=$id');
    final response = await dio.get<Map<String, dynamic>>(
      '/me/media/$encoded/tv-episode-guide',
      options: Options(
        headers: {'Authorization': 'Bearer $accessToken'},
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final code = response.statusCode ?? 0;
    if (code == 403 || code == 401 || code == 404) return null;
    if (code != 200 || response.data == null) return null;
    try {
      return SeriesEpisodeGuide.fromJson(response.data!);
    } catch (_) {
      return null;
    }
  }

  /// Asks the Oxplayer API → provider bot to copy the file from backup channels into the user chat.
  Future<bool> recoverMediaFileFromBackup({
    required AppConfig config,
    required String accessToken,
    required String mediaFileId,
  }) async {
    final dio = _dio(config.apiBaseUrl);
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
    final body = response.data;
    bool ok = false;
    if (body is Map) {
      final rawOk = body['ok'];
      if (rawOk is bool) {
        ok = rawOk;
      } else {
        ok = code == 200;
      }
    } else {
      ok = code == 200;
    }
    _apilog(
      'API recoverFromBackup done status=$code recovered=$ok body=${_summarizePayload(body)}',
    );
    return ok;
  }

  Future<String?> getMediaRecoveryStatus({
    required AppConfig config,
    required String accessToken,
    required String mediaFileId,
  }) async {
    final dio = _dio(config.apiBaseUrl);
    final encoded = Uri.encodeComponent(mediaFileId.trim());
    final response = await dio.get<dynamic>(
      '/me/recover-from-backup/$encoded/status',
      options: Options(
        headers: {'Authorization': 'Bearer $accessToken'},
        validateStatus: (_) => true,
      ),
    );
    if (response.statusCode != 200) return null;
    final body = response.data;
    if (body is! Map) return null;
    final status = body['status']?.toString().trim();
    if (status == null || status.isEmpty) return null;
    return status;
  }

  Future<bool> syncResolvedMediaLocator({
    required AppConfig config,
    required String accessToken,
    required String mediaFileId,
    required String locatorType,
    required int locatorMessageId,
    int? locatorChatId,
    String? locatorBotUsername,
  }) async {
    final dio = _dio(config.apiBaseUrl);
    final payload = <String, dynamic>{
      'mediaFileId': mediaFileId,
      'locatorType': locatorType,
      'locatorMessageId': locatorMessageId,
      if (locatorChatId != null) 'locatorChatId': locatorChatId,
      if (locatorBotUsername != null && locatorBotUsername.trim().isNotEmpty)
        'locatorBotUsername': locatorBotUsername.trim(),
    };
    _apilog('API locatorSync start payload=${_summarizePayload(payload)}');
    final response = await dio.post<dynamic>(
      '/me/media-locator-sync',
      data: payload,
      options: Options(
        headers: {'Authorization': 'Bearer $accessToken'},
        validateStatus: (_) => true,
      ),
    );
    final ok = response.statusCode == 200;
    _apilog(
      'API locatorSync done status=${response.statusCode} ok=$ok '
      'body=${_summarizePayload(response.data)}',
    );
    return ok;
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

    if (config.telegramWebAppShortName.isNotEmpty) {
      try {
        _apilog(
          'InitData: trying GetWebAppLinkUrl shortName=${config.telegramWebAppShortName}',
        );
        final result = await tdlib.send(
          td.GetWebAppLinkUrl(
            chatId: privateChat.id,
            botUserId: botUserId,
            webAppShortName: config.telegramWebAppShortName,
            startParameter: '',
            theme: null,
            applicationName: 'oxplayer',
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

    if (webAppUrl == null && config.telegramWebAppUrl.isNotEmpty) {
      _apilog('InitData: trying GetWebAppUrl fallback');
      final fallbackResult = await tdlib.send(
        td.GetWebAppUrl(
          botUserId: botUserId,
          url: config.telegramWebAppUrl,
          theme: null,
          applicationName: 'oxplayer',
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
          'Set OXPLAYER_TELEGRAM_WEBAPP_SHORT_NAME correctly or set OXPLAYER_TELEGRAM_WEBAPP_URL fallback.',
        );
      }
      throw StateError(
        'Cannot get WebApp URL. Set OXPLAYER_TELEGRAM_WEBAPP_SHORT_NAME or OXPLAYER_TELEGRAM_WEBAPP_URL in env.',
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
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'oxa-$hex';
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
