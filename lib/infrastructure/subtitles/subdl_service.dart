import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../../models/plex_metadata.dart';
import '../../services/auth_debug_service.dart';
import '../../utils/app_logger.dart';

class SubdlSearchResult {
  const SubdlSearchResult({
    required this.displayLabel,
    required this.rawDownload,
    this.languageCode,
  });

  final String displayLabel;
  final String rawDownload;
  final String? languageCode;
}

class DownloadedSubtitleFile {
  const DownloadedSubtitleFile({
    required this.file,
    required this.displayLabel,
    this.languageCode,
  });

  final File file;
  final String displayLabel;
  final String? languageCode;
}

class SubdlService {
  static const Duration _searchTimeout = Duration(seconds: 70);
  static const Duration _downloadTimeout = Duration(seconds: 70);
  static const MethodChannel _mediaToolsChannel = MethodChannel(
    'de.aryanmo.oxplayer/media_tools',
  );

  SubdlService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(seconds: 60),
                sendTimeout: const Duration(seconds: 60),
                headers: const {
                  'Accept': 'application/json',
                  'User-Agent': 'OXPlayer/Android SubDL',
                },
              ),
            );

  final Dio _dio;

  Future<List<SubdlSearchResult>?> searchWithNativeUi({
    required PlexMetadata metadata,
    required String preferredLanguageCode,
    String? titleOverride,
  }) async {
    final config = await AppConfig.load();
    if (config.subdlApiKey.isEmpty) {
      throw Exception('SUBDL_API_KEY is not configured.');
    }
    final isTvContent = metadata.mediaType == PlexMediaType.episode ||
        metadata.mediaType == PlexMediaType.season ||
        metadata.mediaType == PlexMediaType.show;
    final result = await _mediaToolsChannel.invokeMethod<List<dynamic>?>('searchSubdlWithDialog', {
      'apiKey': config.subdlApiKey,
      'filmName': (titleOverride ?? metadata.displayTitle).trim(),
      'contentType': isTvContent ? 'tv' : 'movie',
      'preferredLanguageCode': preferredLanguageCode.trim().toUpperCase(),
      'year': metadata.year,
      'seasonNumber': metadata.parentIndex,
      'episodeNumber': metadata.index,
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
    if (config.subdlApiKey.isEmpty) {
      throw Exception('SUBDL_API_KEY is not configured.');
    }
    final isTvContent = metadata.mediaType == PlexMediaType.episode ||
        metadata.mediaType == PlexMediaType.season ||
        metadata.mediaType == PlexMediaType.show;
    final result = await _mediaToolsChannel.invokeMethod<Map<dynamic, dynamic>?>('pickSubdlSubtitle', {
      'apiKey': config.subdlApiKey,
      'filmName': (titleOverride ?? metadata.displayTitle).trim(),
      'contentType': isTvContent ? 'tv' : 'movie',
      'preferredLanguageCode': preferredLanguageCode.trim().toUpperCase(),
      'year': metadata.year,
      'seasonNumber': metadata.parentIndex,
      'episodeNumber': metadata.index,
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
  }) async {
    final stopwatch = Stopwatch()..start();
    final isTvContent = metadata.mediaType == PlexMediaType.episode ||
        metadata.mediaType == PlexMediaType.season ||
        metadata.mediaType == PlexMediaType.show;
    final contentType = isTvContent ? 'tv' : 'movie';
    final normalizedLanguageCode = languageCode.trim().toUpperCase();
    final title = (titleOverride ?? metadata.displayTitle).trim();
    final imdbId = _extractGuidValue(metadata.guid, 'imdb');
    final tmdbId = _extractGuidValue(metadata.guid, 'tmdb');

    final summary =
        'type=$contentType, lang=$normalizedLanguageCode, title=${title.isEmpty ? '<empty>' : title}';
    appLogger.i('SubDL search started: $summary');
    playMediaDebugInfo('SubDL search started: $summary');

    try {
      final config = await AppConfig.load();
      if (config.subdlApiKey.isEmpty) {
        throw Exception('SUBDL_API_KEY is not configured.');
      }

      final rawResults =
          (defaultTargetPlatform == TargetPlatform.android && !kIsWeb)
              ? await _searchOnAndroid(
                  apiKey: config.subdlApiKey,
                  title: title,
                  contentType: contentType,
                  languageCode: normalizedLanguageCode,
                  year: metadata.year,
                  seasonNumber: metadata.parentIndex,
                  episodeNumber: metadata.index,
                  imdbId: imdbId,
                  tmdbId: tmdbId,
                )
              : await _searchDirect(
                  apiKey: config.subdlApiKey,
                  title: title,
                  contentType: contentType,
                  languageCode: normalizedLanguageCode,
                  year: metadata.year,
                  seasonNumber: metadata.parentIndex,
                  episodeNumber: metadata.index,
                  imdbId: imdbId,
                  tmdbId: tmdbId,
                );

      if (rawResults.isEmpty) {
        appLogger.i(
          'SubDL search finished with 0 results in ${stopwatch.elapsedMilliseconds}ms',
        );
        playMediaDebugInfo(
          'SubDL search finished with 0 results in ${stopwatch.elapsedMilliseconds}ms',
        );
        return const [];
      }

      final results = rawResults
          .map(_parseSearchResult)
          .whereType<SubdlSearchResult>()
          .toList(growable: false);
      appLogger.i(
        'SubDL search finished with ${results.length} results in ${stopwatch.elapsedMilliseconds}ms',
      );
      playMediaDebugSuccess(
        'SubDL search finished with ${results.length} results in ${stopwatch.elapsedMilliseconds}ms',
      );
      return results;
    } on TimeoutException catch (error, stackTrace) {
      appLogger.e(
        'SubDL search timed out: $summary',
        error: error,
        stackTrace: stackTrace,
      );
      playMediaDebugError(
        'SubDL search timed out after ${_searchTimeout.inSeconds}s',
      );
      rethrow;
    } on PlatformException catch (error, stackTrace) {
      final message = error.message ?? error.code;
      appLogger.e(
        'SubDL native search failed: $summary',
        error: error,
        stackTrace: stackTrace,
      );
      playMediaDebugError('SubDL search failed: $message');
      throw Exception(message);
    } on DioException catch (error, stackTrace) {
      final message = error.message ?? error.toString();
      appLogger.e(
        'SubDL search request failed: $summary',
        error: error,
        stackTrace: stackTrace,
      );
      playMediaDebugError('SubDL search request failed: $message');
      rethrow;
    } catch (error, stackTrace) {
      appLogger.e(
        'SubDL search failed: $summary',
        error: error,
        stackTrace: stackTrace,
      );
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
    final url = _downloadUrl(rawDownload);
    appLogger.i('SubDL subtitle download started: $displayLabel');
    playMediaDebugInfo('SubDL subtitle download started: $displayLabel');

    final response = await _dio
        .get<List<int>>(
          url,
          options: Options(responseType: ResponseType.bytes),
        )
        .timeout(
          _downloadTimeout,
          onTimeout: () => throw TimeoutException(
            'SubDL subtitle download timed out after ${_downloadTimeout.inSeconds}s.',
          ),
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
        appLogger.i('SubDL subtitle extracted: ${file.path}');
        playMediaDebugSuccess('SubDL subtitle extracted successfully.');
        return DownloadedSubtitleFile(
          file: file,
          displayLabel: displayLabel,
          languageCode: languageCode,
        );
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
    final result = await _mediaToolsChannel.invokeMethod<List<dynamic>>(
      'searchSubdl',
      <String, dynamic>{
        'apiKey': apiKey,
        'filmName': title,
        'contentType': contentType,
        'languages': languageCode,
        'year': year,
        'seasonNumber': seasonNumber,
        'episodeNumber': episodeNumber,
        'imdbId': imdbId,
        'tmdbId': tmdbId,
      },
    ).timeout(
      _searchTimeout,
      onTimeout: () => throw TimeoutException(
        'SubDL search timed out after ${_searchTimeout.inSeconds}s.',
      ),
    );
    if (result == null) {
      return const <Map<String, dynamic>>[];
    }
    return result.whereType<Map>().map((entry) {
      return entry.map((key, value) => MapEntry(key.toString(), value));
    }).toList(growable: false);
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
      query['imdb_id'] = imdbId.replaceFirst(
        RegExp('^tt', caseSensitive: false),
        '',
      );
    }
    if (tmdbId != null && tmdbId.isNotEmpty) {
      query['tmdb_id'] = tmdbId;
    }

    final response = await _dio
        .get<Map<String, dynamic>>(
          'https://api.subdl.com/api/v1/subtitles',
          queryParameters: query,
        )
        .timeout(
          _searchTimeout,
          onTimeout: () => throw TimeoutException(
            'SubDL search timed out after ${_searchTimeout.inSeconds}s.',
          ),
        );

    final data = response.data ?? const <String, dynamic>{};
    if (data['status'] != true) {
      final message = data['error']?.toString().trim();
      throw Exception(
        message == null || message.isEmpty ? 'SubDL search failed.' : message,
      );
    }

    final subtitles = data['subtitles'];
    if (subtitles is! List) {
      return const <Map<String, dynamic>>[];
    }

    return subtitles.whereType<Map>().map((entry) {
      return <String, dynamic>{
        'displayLabel': _buildResultLabel(entry),
        'rawDownload': (entry['download_link']?.toString() ??
                entry['url']?.toString() ??
                entry['zip']?.toString() ??
                entry['link']?.toString() ??
                '')
            .trim(),
        'languageCode': entry['lang']?.toString().trim(),
      };
    }).where((entry) => (entry['rawDownload'] as String).isNotEmpty).toList(
          growable: false,
        );
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
    final match = RegExp(
      '^${RegExp.escape(scheme)}://(.+)',
      caseSensitive: false,
    ).firstMatch(value);
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
      p.join(
        tempDir.path,
        'subdl_subtitles',
        DateTime.now().millisecondsSinceEpoch.toString(),
      ),
    );
    await directory.create(recursive: true);
    return directory;
  }
}
