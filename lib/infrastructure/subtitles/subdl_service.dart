import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/plex_metadata.dart';
import '../../services/auth_debug_service.dart';
import '../../services/storage_service.dart';
import '../../utils/app_logger.dart';
import '../../utils/subtitle_text_encoding.dart';
import '../config/app_config.dart';

class SubdlSearchResult {
  const SubdlSearchResult({required this.displayLabel, required this.rawDownload, this.languageCode});

  final String displayLabel;
  final String rawDownload;
  final String? languageCode;
}

class DownloadedSubtitleFile {
  const DownloadedSubtitleFile({required this.file, required this.displayLabel, this.languageCode});

  final File file;
  final String displayLabel;
  final String? languageCode;
}

class SubdlService {
  static const Duration _searchTimeout = Duration(seconds: 70);
  static const Duration _downloadTimeout = Duration(seconds: 70);
  static const MethodChannel _mediaToolsChannel = MethodChannel('de.aryanmo.oxplayer/media_tools');

  SubdlService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 60),
              sendTimeout: const Duration(seconds: 60),
              headers: const {'Accept': 'application/json', 'User-Agent': 'OXPlayer/Android SubDL'},
            ),
          );

  final Dio _dio;

  static bool _canUseOxSubtitleProxy(String apiBaseUrl, String accessToken) {
    return apiBaseUrl.trim().isNotEmpty && accessToken.trim().isNotEmpty;
  }

  static Uri _oxSubtitleUri(String apiBaseUrl, String path) {
    final base = apiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$p');
  }

  Future<List<Map<String, dynamic>>> _searchViaOxPlayerApi({
    required String apiBaseUrl,
    required String accessToken,
    required String title,
    required String contentType,
    required String languageCode,
    required int? year,
    required int? seasonNumber,
    required int? episodeNumber,
    required String? imdbId,
    required String? tmdbId,
    String? mediaId,
  }) async {
    final uri = _oxSubtitleUri(apiBaseUrl, '/api/subtitles/search');
    final body = <String, dynamic>{
      'contentType': contentType,
      'languages': languageCode.trim().toUpperCase(),
      if (title.isNotEmpty) 'filmName': title,
      if (imdbId != null && imdbId.isNotEmpty) 'imdbId': imdbId,
      if (tmdbId != null && tmdbId.isNotEmpty) 'tmdbId': tmdbId,
      if (mediaId != null && mediaId.isNotEmpty) 'mediaId': mediaId,
    };
    if (year != null) {
      body['year'] = year;
    }
    if (seasonNumber != null) {
      body['seasonNumber'] = seasonNumber;
    }
    if (episodeNumber != null) {
      body['episodeNumber'] = episodeNumber;
    }
    playMediaDebugInfo('OX subtitle proxy POST /api/subtitles/search');

    final response = await _dio
        .post<Map<String, dynamic>>(
          uri.toString(),
          data: body,
          options: Options(
            headers: <String, String>{
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'User-Agent': 'OXPlayer/Android SubtitleProxy',
            },
          ),
        )
        .timeout(
          _searchTimeout,
          onTimeout: () => throw TimeoutException('OX subtitle search timed out after ${_searchTimeout.inSeconds}s.'),
        );

    final status = response.statusCode ?? 0;
    final data = response.data;
    if (status == 401) {
      throw Exception('OXPlayer session expired. Sign in again.');
    }
    if (status == 403) {
      final err = data?['error']?.toString().trim();
      throw Exception(err == null || err.isEmpty ? 'Subtitle search forbidden (HTTP 403).' : err);
    }
    if (status != 200 || data == null) {
      final err = data?['error']?.toString().trim();
      throw Exception(err == null || err.isEmpty ? 'Subtitle search failed (HTTP $status).' : err);
    }

    final fromCache = data['fromCache'];
    final items = data['items'];
    playMediaDebugInfo('OX subtitle search ok (fromCache=$fromCache, items=${items is List ? items.length : 0})');
    if (items is! List) {
      return const <Map<String, dynamic>>[];
    }
    return items
        .whereType<Map>()
        .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
        .where((m) => (m['rawDownload']?.toString().trim() ?? '').isNotEmpty)
        .toList(growable: false);
  }

  Future<DownloadedSubtitleFile> _downloadSrtViaOxPlayerApi({
    required String apiBaseUrl,
    required String accessToken,
    required String rawDownload,
    required String displayLabel,
    String? languageCode,
    String? fixedFileBaseName,
  }) async {
    final uri = _oxSubtitleUri(apiBaseUrl, '/api/subtitles/srt');
    final body = <String, dynamic>{
      'rawDownload': rawDownload,
      if (displayLabel.trim().isNotEmpty) 'displayLabel': displayLabel.trim(),
      if (languageCode != null && languageCode.trim().isNotEmpty) 'languageCode': languageCode.trim(),
    };
    playMediaDebugInfo('OX subtitle proxy POST /api/subtitles/srt');

    final response = await _dio
        .post<Map<String, dynamic>>(
          uri.toString(),
          data: body,
          options: Options(
            headers: <String, String>{
              'Authorization': 'Bearer $accessToken',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'User-Agent': 'OXPlayer/Android SubtitleProxy',
            },
          ),
        )
        .timeout(
          _downloadTimeout,
          onTimeout: () =>
              throw TimeoutException('OX subtitle download timed out after ${_downloadTimeout.inSeconds}s.'),
        );

    final status = response.statusCode ?? 0;
    final data = response.data;
    if (status == 401) {
      throw Exception('OXPlayer session expired. Sign in again.');
    }
    if (status != 200 || data == null) {
      final err = data?['error']?.toString().trim();
      throw Exception(err == null || err.isEmpty ? 'Subtitle download failed (HTTP $status).' : err);
    }

    final srt = data['srt']?.toString() ?? '';
    if (srt.isEmpty) {
      throw Exception('Subtitle response contained no SRT text.');
    }

    final directory = await _createTargetDirectory();
    final name = fixedFileBaseName == null || fixedFileBaseName.trim().isEmpty
        ? 'subtitle.srt'
        : '${fixedFileBaseName.trim()}.srt';
    final file = File(p.join(directory.path, name));
    await file.parent.create(recursive: true);
    await file.writeAsString(srt, flush: true);
    await rewriteSubtitleFileAsUtf8(file);
    appLogger.i('OX subtitle proxy wrote ${file.path}');
    playMediaDebugSuccess('OX subtitle proxy download finished.');
    return DownloadedSubtitleFile(file: file, displayLabel: displayLabel, languageCode: languageCode);
  }

  Future<List<SubdlSearchResult>?> searchWithNativeUi({
    required PlexMetadata metadata,
    required String preferredLanguageCode,
    String? titleOverride,
  }) async {
    final config = await AppConfig.load();
    final storage = await StorageService.getInstance();
    final token = storage.getApiAccessToken()?.trim() ?? '';
    final isTvContent =
        metadata.mediaType == PlexMediaType.episode ||
        metadata.mediaType == PlexMediaType.season ||
        metadata.mediaType == PlexMediaType.show;
    final (seasonN, episodeN) = metadata.subdlSeasonEpisodeNumbers;
    final title = (titleOverride ?? metadata.displayTitle).trim();

    if (_canUseOxSubtitleProxy(config.apiBaseUrl, token)) {
      try {
        final maps = await _searchViaOxPlayerApi(
          apiBaseUrl: config.apiBaseUrl,
          accessToken: token,
          title: title,
          contentType: isTvContent ? 'tv' : 'movie',
          languageCode: preferredLanguageCode,
          year: metadata.year,
          seasonNumber: seasonN,
          episodeNumber: episodeN,
          imdbId: _extractGuidValue(metadata.guid, 'imdb'),
          tmdbId: _extractGuidValue(metadata.guid, 'tmdb'),
        );
        return maps.map(_parseSearchResult).whereType<SubdlSearchResult>().toList(growable: false);
      } catch (e, st) {
        appLogger.w('OX subtitle search (trial) failed, falling back to SubDL: $e', error: e, stackTrace: st);
        if (config.subdlApiKey.isEmpty) {
          rethrow;
        }
      }
    }

    if (config.subdlApiKey.isEmpty) {
      throw Exception('Subtitle search needs OXPlayer login (API URL + session) or SUBDL_API_KEY in env.');
    }
    final result = await _mediaToolsChannel.invokeMethod<List<dynamic>?>('searchSubdlWithDialog', {
      'apiKey': config.subdlApiKey,
      'filmName': title,
      'contentType': isTvContent ? 'tv' : 'movie',
      'preferredLanguageCode': preferredLanguageCode.trim().toUpperCase(),
      'year': metadata.year,
      'seasonNumber': seasonN,
      'episodeNumber': episodeN,
      'imdbId': _extractGuidValue(metadata.guid, 'imdb'),
      'tmdbId': _extractGuidValue(metadata.guid, 'tmdb'),
    });
    if (result == null) {
      return null;
    }
    return result
        .whereType<Map>()
        .map((entry) => entry.map((key, value) => MapEntry(key.toString(), value)))
        .map(_parseSearchResult)
        .whereType<SubdlSearchResult>()
        .toList(growable: false);
  }

  Future<DownloadedSubtitleFile?> pickSubtitleWithNativeUi({
    required PlexMetadata metadata,
    required String preferredLanguageCode,
    String? titleOverride,
  }) async {
    final config = await AppConfig.load();
    final storage = await StorageService.getInstance();
    final token = storage.getApiAccessToken()?.trim() ?? '';
    if (config.subdlApiKey.isEmpty) {
      if (_canUseOxSubtitleProxy(config.apiBaseUrl, token)) {
        throw Exception('Native SubDL picker needs SUBDL_API_KEY, or use in-app Search Subtitles (OXPlayer proxy).');
      }
      throw Exception('SUBDL_API_KEY is not configured.');
    }
    final isTvContent =
        metadata.mediaType == PlexMediaType.episode ||
        metadata.mediaType == PlexMediaType.season ||
        metadata.mediaType == PlexMediaType.show;
    final (seasonN, episodeN) = metadata.subdlSeasonEpisodeNumbers;
    final result = await _mediaToolsChannel.invokeMethod<Map<dynamic, dynamic>?>('pickSubdlSubtitle', {
      'apiKey': config.subdlApiKey,
      'filmName': (titleOverride ?? metadata.displayTitle).trim(),
      'contentType': isTvContent ? 'tv' : 'movie',
      'preferredLanguageCode': preferredLanguageCode.trim().toUpperCase(),
      'year': metadata.year,
      'seasonNumber': seasonN,
      'episodeNumber': episodeN,
      'imdbId': _extractGuidValue(metadata.guid, 'imdb'),
      'tmdbId': _extractGuidValue(metadata.guid, 'tmdb'),
    });
    if (result == null) {
      return null;
    }
    final filePath = result['filePath']?.toString().trim() ?? '';
    if (filePath.isEmpty) {
      return null;
    }
    final label = result['displayLabel']?.toString().trim() ?? '';
    final language = result['languageCode']?.toString().trim() ?? '';
    return DownloadedSubtitleFile(
      file: File(filePath),
      displayLabel: label.isEmpty ? 'Subtitle' : label,
      languageCode: language.isEmpty ? null : language,
    );
  }

  Future<List<SubdlSearchResult>> search({
    required PlexMetadata metadata,
    required String languageCode,
    String? titleOverride,

    /// When null, [PlexMetadata.subdlSeasonEpisodeNumbers] is used.
    int? seasonNumberOverride,
    int? episodeNumberOverride,
  }) async {
    final stopwatch = Stopwatch()..start();
    final isTvContent =
        metadata.mediaType == PlexMediaType.episode ||
        metadata.mediaType == PlexMediaType.season ||
        metadata.mediaType == PlexMediaType.show;
    final contentType = isTvContent ? 'tv' : 'movie';
    final normalizedLanguageCode = languageCode.trim().toUpperCase();
    final title = (titleOverride ?? metadata.displayTitle).trim();
    final imdbId = _extractGuidValue(metadata.guid, 'imdb');
    final tmdbId = _extractGuidValue(metadata.guid, 'tmdb');

    final (metaSeason, metaEpisode) = metadata.subdlSeasonEpisodeNumbers;
    final seasonN = seasonNumberOverride ?? metaSeason;
    final episodeN = episodeNumberOverride ?? metaEpisode;
    final summary =
        'type=$contentType, lang=$normalizedLanguageCode, title=${title.isEmpty ? '<empty>' : title}'
        '${contentType == 'tv' ? ', S=${seasonN ?? '-'} E=${episodeN ?? '-'}' : ''}';
    appLogger.i('SubDL search started: $summary');
    playMediaDebugInfo('SubDL search started: $summary');

    try {
      final config = await AppConfig.load();
      final storage = await StorageService.getInstance();
      final token = storage.getApiAccessToken()?.trim() ?? '';
      final oxReady = _canUseOxSubtitleProxy(config.apiBaseUrl, token);

      List<Map<String, dynamic>> rawResults = const [];

      if (oxReady) {
        try {
          rawResults = await _searchViaOxPlayerApi(
            apiBaseUrl: config.apiBaseUrl,
            accessToken: token,
            title: title,
            contentType: contentType,
            languageCode: normalizedLanguageCode,
            year: metadata.year,
            seasonNumber: seasonN,
            episodeNumber: episodeN,
            imdbId: imdbId,
            tmdbId: tmdbId,
          );
          playMediaDebugInfo('Subtitle search used OXPlayer API proxy (${rawResults.length} raw rows).');
        } catch (e, st) {
          appLogger.w('OX subtitle search failed, falling back to SubDL: $e', error: e, stackTrace: st);
          playMediaDebugError('OX subtitle search failed, trying SubDL: $e');
          if (config.subdlApiKey.isEmpty) {
            rethrow;
          }
        }
      }

      if (rawResults.isEmpty && !(oxReady && config.subdlApiKey.isEmpty)) {
        if (config.subdlApiKey.isEmpty) {
          throw Exception('Subtitle search needs OXPlayer login (API URL + session) or SUBDL_API_KEY in env.');
        }
        rawResults = (defaultTargetPlatform == TargetPlatform.android && !kIsWeb)
            ? await _searchOnAndroid(
                apiKey: config.subdlApiKey,
                title: title,
                contentType: contentType,
                languageCode: normalizedLanguageCode,
                year: metadata.year,
                seasonNumber: seasonN,
                episodeNumber: episodeN,
                imdbId: imdbId,
                tmdbId: tmdbId,
              )
            : await _searchDirect(
                apiKey: config.subdlApiKey,
                title: title,
                contentType: contentType,
                languageCode: normalizedLanguageCode,
                year: metadata.year,
                seasonNumber: seasonN,
                episodeNumber: episodeN,
                imdbId: imdbId,
                tmdbId: tmdbId,
              );
      }

      if (rawResults.isEmpty) {
        appLogger.i('SubDL search finished with 0 results in ${stopwatch.elapsedMilliseconds}ms');
        playMediaDebugInfo('SubDL search finished with 0 results in ${stopwatch.elapsedMilliseconds}ms');
        return const [];
      }

      final results = rawResults.map(_parseSearchResult).whereType<SubdlSearchResult>().toList(growable: false);
      appLogger.i('SubDL search finished with ${results.length} results in ${stopwatch.elapsedMilliseconds}ms');
      playMediaDebugSuccess(
        'SubDL search finished with ${results.length} results in ${stopwatch.elapsedMilliseconds}ms',
      );
      return results;
    } on TimeoutException catch (error, stackTrace) {
      appLogger.e('SubDL search timed out: $summary', error: error, stackTrace: stackTrace);
      playMediaDebugError('SubDL search timed out after ${_searchTimeout.inSeconds}s');
      rethrow;
    } on PlatformException catch (error, stackTrace) {
      final message = error.message ?? error.code;
      appLogger.e('SubDL native search failed: $summary', error: error, stackTrace: stackTrace);
      playMediaDebugError('SubDL search failed: $message');
      throw Exception(message);
    } on DioException catch (error, stackTrace) {
      final message = error.message ?? error.toString();
      appLogger.e('SubDL search request failed: $summary', error: error, stackTrace: stackTrace);
      playMediaDebugError('SubDL search request failed: $message');
      rethrow;
    } catch (error, stackTrace) {
      appLogger.e('SubDL search failed: $summary', error: error, stackTrace: stackTrace);
      playMediaDebugError('SubDL search failed: $error');
      rethrow;
    }
  }

  Future<DownloadedSubtitleFile> downloadAndExtract({
    required String rawDownload,
    required String displayLabel,
    String? languageCode,
    String? fixedFileBaseName,
  }) async {
    final config = await AppConfig.load();
    final storage = await StorageService.getInstance();
    final token = storage.getApiAccessToken()?.trim() ?? '';

    if (_canUseOxSubtitleProxy(config.apiBaseUrl, token)) {
      try {
        appLogger.i('Subtitle download via OXPlayer API: $displayLabel');
        playMediaDebugInfo('Subtitle download via OXPlayer API: $displayLabel');
        return await _downloadSrtViaOxPlayerApi(
          apiBaseUrl: config.apiBaseUrl,
          accessToken: token,
          rawDownload: rawDownload,
          displayLabel: displayLabel,
          languageCode: languageCode,
          fixedFileBaseName: fixedFileBaseName,
        );
      } catch (e, st) {
        appLogger.w('OX subtitle download failed, falling back to SubDL: $e', error: e, stackTrace: st);
        playMediaDebugError('OX subtitle download failed, trying SubDL zip: $e');
        if (config.subdlApiKey.isEmpty) {
          rethrow;
        }
      }
    } else if (config.subdlApiKey.isEmpty) {
      throw Exception('Subtitle download needs OXPlayer login (API URL + session) or SUBDL_API_KEY in env.');
    }

    final url = _downloadUrl(rawDownload);
    appLogger.i('SubDL subtitle download started: $displayLabel');
    playMediaDebugInfo('SubDL subtitle download started: $displayLabel');

    final response = await _dio
        .get<List<int>>(url, options: Options(responseType: ResponseType.bytes))
        .timeout(
          _downloadTimeout,
          onTimeout: () =>
              throw TimeoutException('SubDL subtitle download timed out after ${_downloadTimeout.inSeconds}s.'),
        );
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) {
      throw Exception('Subtitle download returned no data.');
    }

    final archive = ZipDecoder().decodeBytes(bytes);
    final directory = await _createTargetDirectory();
    const preferredExtensions = ['srt', 'vtt', 'ass', 'ssa'];

    for (final extension in preferredExtensions) {
      for (final entry in archive) {
        if (!entry.isFile) {
          continue;
        }
        final fileName = entry.name.split('/').last;
        if (p.extension(fileName).toLowerCase() != '.$extension') {
          continue;
        }

        final targetFileName = fixedFileBaseName == null || fixedFileBaseName.trim().isEmpty
            ? (fileName.isEmpty ? 'subtitle.$extension' : fileName)
            : '${fixedFileBaseName.trim()}.$extension';
        final file = File(p.join(directory.path, targetFileName));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.content as List<int>, flush: true);
        await rewriteSubtitleFileAsUtf8(file);
        appLogger.i('SubDL subtitle extracted: ${file.path}');
        playMediaDebugSuccess('SubDL subtitle extracted successfully.');
        return DownloadedSubtitleFile(file: file, displayLabel: displayLabel, languageCode: languageCode);
      }
    }

    throw Exception('No supported subtitle file found in archive.');
  }

  SubdlSearchResult? _parseSearchResult(Map<String, dynamic> json) {
    final rawDownload = json['rawDownload']?.toString().trim() ?? '';
    if (rawDownload.isEmpty) {
      return null;
    }
    final label = json['displayLabel']?.toString().trim() ?? 'Subtitle';
    final language = json['languageCode']?.toString().trim() ?? '';
    return SubdlSearchResult(
      displayLabel: label,
      rawDownload: rawDownload,
      languageCode: language.isEmpty ? null : language,
    );
  }

  Future<List<Map<String, dynamic>>> _searchOnAndroid({
    required String apiKey,
    required String title,
    required String contentType,
    required String languageCode,
    required int? year,
    required int? seasonNumber,
    required int? episodeNumber,
    required String? imdbId,
    required String? tmdbId,
  }) async {
    final result = await _mediaToolsChannel
        .invokeMethod<List<dynamic>>('searchSubdl', <String, dynamic>{
          'apiKey': apiKey,
          'filmName': title,
          'contentType': contentType,
          'languages': languageCode,
          'year': year,
          'seasonNumber': seasonNumber,
          'episodeNumber': episodeNumber,
          'imdbId': imdbId,
          'tmdbId': tmdbId,
        })
        .timeout(
          _searchTimeout,
          onTimeout: () => throw TimeoutException('SubDL search timed out after ${_searchTimeout.inSeconds}s.'),
        );
    if (result == null) {
      return const <Map<String, dynamic>>[];
    }
    return result
        .whereType<Map>()
        .map((entry) {
          return entry.map((key, value) => MapEntry(key.toString(), value));
        })
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _searchDirect({
    required String apiKey,
    required String title,
    required String contentType,
    required String languageCode,
    required int? year,
    required int? seasonNumber,
    required int? episodeNumber,
    required String? imdbId,
    required String? tmdbId,
  }) async {
    final query = <String, dynamic>{
      'api_key': apiKey,
      'subs_per_page': 30,
      'type': contentType,
      'languages': languageCode,
    };
    if (title.isNotEmpty) {
      query['film_name'] = title;
    }
    if (year != null) {
      query['year'] = year;
    }
    if (seasonNumber != null) {
      query['season_number'] = seasonNumber;
    }
    if (episodeNumber != null) {
      query['episode_number'] = episodeNumber;
    }
    if (imdbId != null && imdbId.isNotEmpty) {
      query['imdb_id'] = imdbId.replaceFirst(RegExp('^tt', caseSensitive: false), '');
    }
    if (tmdbId != null && tmdbId.isNotEmpty) {
      query['tmdb_id'] = tmdbId;
    }

    final queryForLog = Map<String, dynamic>.from(query);
    final ak = queryForLog['api_key']?.toString() ?? '';
    queryForLog['api_key'] = ak.length > 8 ? '${ak.substring(0, 4)}…${ak.substring(ak.length - 2)}' : '***';
    playMediaDebugInfo('SubDL _searchDirect query: $queryForLog');

    final response = await _dio
        .get<Map<String, dynamic>>('https://api.subdl.com/api/v1/subtitles', queryParameters: query)
        .timeout(
          _searchTimeout,
          onTimeout: () => throw TimeoutException('SubDL search timed out after ${_searchTimeout.inSeconds}s.'),
        );

    var responseUriStr = response.requestOptions.uri.toString();
    if (ak.isNotEmpty) {
      responseUriStr = responseUriStr.replaceAll(ak, '***');
    }
    playMediaDebugInfo('SubDL _searchDirect response URL: $responseUriStr');

    final data = response.data ?? const <String, dynamic>{};
    if (data['status'] != true) {
      final message = data['error']?.toString().trim();
      throw Exception(message == null || message.isEmpty ? 'SubDL search failed.' : message);
    }

    final results = data['results'];
    if (results is List && results.isNotEmpty) {
      final preview = results
          .take(4)
          .map((r) {
            if (r is! Map) {
              return '?';
            }
            final m = Map<String, dynamic>.from(r);
            return 'name=${m['name']} year=${m['year']} type=${m['type']} sd_id=${m['sd_id']}';
          })
          .join(' | ');
      playMediaDebugInfo('SubDL API matched shows (${results.length}): $preview');
    } else {
      playMediaDebugInfo('SubDL API results: empty or missing (API may match by name only).');
    }

    final subtitles = data['subtitles'];
    if (subtitles is! List) {
      return const <Map<String, dynamic>>[];
    }

    final sampleLabels = subtitles
        .take(12)
        .map((e) {
          if (e is! Map) {
            return '?';
          }
          final m = Map<String, dynamic>.from(e);
          final rel = m['release_name']?.toString().trim() ?? '';
          final ep = m['episode'];
          final se = m['season'];
          final lang = m['lang']?.toString().trim() ?? '';
          return rel.isNotEmpty ? '$rel (s=$se ep=$ep $lang)' : '${m['name']} (s=$se ep=$ep $lang)';
        })
        .join('; ');
    playMediaDebugInfo('SubDL API subtitles count=${subtitles.length} sample: $sampleLabels');

    return subtitles
        .whereType<Map>()
        .map((entry) {
          return <String, dynamic>{
            'displayLabel': _buildResultLabel(entry),
            'rawDownload':
                (entry['download_link']?.toString() ??
                        entry['url']?.toString() ??
                        entry['zip']?.toString() ??
                        entry['link']?.toString() ??
                        '')
                    .trim(),
            'languageCode': entry['lang']?.toString().trim(),
          };
        })
        .where((entry) => (entry['rawDownload'] as String).isNotEmpty)
        .toList(growable: false);
  }

  String _buildResultLabel(Map<dynamic, dynamic> entry) {
    final release = entry['release_name']?.toString().trim() ?? '';
    final name = entry['name']?.toString().trim() ?? '';
    final language = entry['lang']?.toString().trim() ?? '';
    if (release.isNotEmpty && language.isNotEmpty) {
      return '$release · $language';
    }
    if (release.isNotEmpty) {
      return release;
    }
    if (name.isNotEmpty && language.isNotEmpty) {
      return '$name · $language';
    }
    if (name.isNotEmpty) {
      return name;
    }
    return language.isNotEmpty ? language : 'Subtitle';
  }

  String? _extractGuidValue(String? guid, String scheme) {
    final value = guid?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    final match = RegExp('^${RegExp.escape(scheme)}://(.+)', caseSensitive: false).firstMatch(value);
    if (match == null) {
      return null;
    }
    final extracted = match.group(1)?.trim();
    return extracted == null || extracted.isEmpty ? null : extracted;
  }

  String _downloadUrl(String rawDownload) {
    final trimmed = rawDownload.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    if (trimmed.startsWith('/')) {
      return 'https://dl.subdl.com$trimmed';
    }
    return 'https://dl.subdl.com/subtitle/$trimmed';
  }

  Future<Directory> _createTargetDirectory() async {
    final tempDir = await getTemporaryDirectory();
    final directory = Directory(
      p.join(tempDir.path, 'subdl_subtitles', DateTime.now().millisecondsSinceEpoch.toString()),
    );
    await directory.create(recursive: true);
    return directory;
  }
}
