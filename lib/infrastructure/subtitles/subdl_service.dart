import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/plex_metadata.dart';

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
  SubdlService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(seconds: 60),
                sendTimeout: const Duration(seconds: 60),
              ),
            );

  final Dio _dio;

  Future<List<SubdlSearchResult>> search({
    required String apiKey,
    required PlexMetadata metadata,
    required String languageCode,
    String? titleOverride,
  }) async {
    final isTvContent = metadata.mediaType == PlexMediaType.episode ||
        metadata.mediaType == PlexMediaType.season ||
        metadata.mediaType == PlexMediaType.show;
    final query = <String, dynamic>{
      'api_key': apiKey,
      'subs_per_page': 30,
      'type': isTvContent ? 'tv' : 'movie',
      'languages': languageCode.trim().toUpperCase(),
    };

    final title = (titleOverride ?? metadata.displayTitle).trim();
    if (title.isNotEmpty) {
      query['film_name'] = title;
    }
    if (metadata.year != null) {
      query['year'] = metadata.year;
    }
    if (metadata.parentIndex != null) {
      query['season_number'] = metadata.parentIndex;
    }
    if (metadata.index != null) {
      query['episode_number'] = metadata.index;
    }

    final response = await _dio.get<Map<String, dynamic>>(
      'https://api.subdl.com/api/v1/subtitles',
      queryParameters: query,
    );

    final data = response.data ?? const <String, dynamic>{};
    if (data['status'] != true) {
      final message = data['error']?.toString().trim();
      throw Exception(message == null || message.isEmpty ? 'SubDL search failed.' : message);
    }

    final subtitles = data['subtitles'];
    if (subtitles is! List) {
      return const [];
    }

    return subtitles
        .whereType<Map>()
        .map((entry) => entry.map((key, value) => MapEntry(key.toString(), value)))
        .map(_parseResult)
        .whereType<SubdlSearchResult>()
        .toList(growable: false);
  }

  Future<DownloadedSubtitleFile> downloadAndExtract({
    required String rawDownload,
    required String displayLabel,
    String? languageCode,
  }) async {
    final response = await _dio.get<List<int>>(
      _downloadUrl(rawDownload),
      options: Options(responseType: ResponseType.bytes),
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

        final file = File(p.join(directory.path, fileName.isEmpty ? 'subtitle.$extension' : fileName));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.content as List<int>, flush: true);
        return DownloadedSubtitleFile(
          file: file,
          displayLabel: displayLabel,
          languageCode: languageCode,
        );
      }
    }

    throw Exception('No supported subtitle file found in archive.');
  }

  SubdlSearchResult? _parseResult(Map<String, dynamic> json) {
    final release = json['release_name']?.toString().trim() ?? '';
    final name = json['name']?.toString().trim() ?? '';
    final language = json['lang']?.toString().trim() ?? '';
    final rawDownload = (json['download_link']?.toString() ??
            json['url']?.toString() ??
            json['zip']?.toString() ??
            json['link']?.toString() ??
            '')
        .trim();
    if (rawDownload.isEmpty) {
      return null;
    }

    final label = switch ((release.isNotEmpty, name.isNotEmpty, language.isNotEmpty)) {
      (true, _, true) => '$release · $language',
      (true, _, false) => release,
      (false, true, true) => '$name · $language',
      (false, true, false) => name,
      _ => language.isNotEmpty ? language : 'Subtitle',
    };

    return SubdlSearchResult(
      displayLabel: label,
      rawDownload: rawDownload,
      languageCode: language.isEmpty ? null : language,
    );
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