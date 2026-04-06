double? _parseVoteAverage(Object? raw) {
  if (raw == null) return null;
  if (raw is num && raw.isFinite) return raw.toDouble();
  if (raw is String) {
    final v = double.tryParse(raw.trim());
    if (v != null && v.isFinite) return v;
  }
  return null;
}

/// TMDB-linked genre row from API [`media.genres`].
class MediaGenreRef {
  const MediaGenreRef({required this.id, required this.title});

  final String id;
  final String title;

  factory MediaGenreRef.fromJson(Map<String, dynamic> json) {
    return MediaGenreRef(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
    );
  }
}

class AppMedia {
  AppMedia({
    required this.id,
    this.imdbId,
    this.tmdbId,
    required this.title,
    required this.type,
    this.releaseYear,
    this.originalLanguage,
    this.posterPath,
    this.summary,
    /// TMDB-style average user score, 0–10, when provided by the API.
    this.voteAverage,
    this.rawDetails,
    this.genres = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String? imdbId;
  final String? tmdbId;
  final String title;
  final String type; // 'MOVIE' or 'SERIES' or 'UNKNOWN'
  final int? releaseYear;
  final String? originalLanguage;
  final String? posterPath;
  final String? summary;
  final double? voteAverage;
  final String? rawDetails;
  final List<MediaGenreRef> genres;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory AppMedia.fromJson(Map<String, dynamic> json) {
    final resolvedId = (json['id'] ??
            json['mediaId'] ??
            json['media_id'] ??
            json['globalId'] ??
            json['global_id'] ??
            '')
        .toString()
        .trim();
    final genresRaw = json['genres'];
    final genresList = <MediaGenreRef>[];
    if (genresRaw is List) {
      for (final e in genresRaw) {
        if (e is Map<String, dynamic>) {
          final g = MediaGenreRef.fromJson(e);
          if (g.id.isNotEmpty) genresList.add(g);
        }
      }
    }

    return AppMedia(
      id: resolvedId,
      imdbId: json['imdbId']?.toString() ?? json['imdb_id']?.toString(),
      tmdbId: json['tmdbId']?.toString() ?? json['tmdb_id']?.toString(),
      title: (json['title'] ?? '').toString(),
      type: (json['type'] ?? 'UNKNOWN').toString(),
      releaseYear: json['releaseYear'] as int? ?? json['release_year'] as int?,
      originalLanguage: json['originalLanguage']?.toString() ??
          json['original_language']?.toString(),
      posterPath:
          json['posterPath']?.toString() ?? json['poster_path']?.toString(),
      summary: json['summary']?.toString(),
      voteAverage: _parseVoteAverage(json['voteAverage'] ?? json['vote_average']),
      rawDetails:
          json['rawDetails']?.toString() ?? json['raw_details']?.toString(),
      genres: genresList,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'].toString())
          : (json['created_at'] != null
              ? DateTime.parse(json['created_at'].toString())
              : DateTime.now()),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'].toString())
          : (json['updated_at'] != null
              ? DateTime.parse(json['updated_at'].toString())
              : DateTime.now()),
    );
  }
}

class AppSource {
  AppSource({
    required this.id,
    required this.chatId,
    required this.name,
    this.thumbnail,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final int chatId;
  final String name;
  final String? thumbnail;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory AppSource.fromJson(Map<String, dynamic> json) {
    return AppSource(
      id: (json['id'] ?? '').toString(),
      chatId: json['chatId'] as int? ?? json['chat_id'] as int? ?? 0,
      name: (json['name'] ?? '').toString(),
      thumbnail: json['thumbnail']?.toString(),
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'].toString())
          : (json['created_at'] != null
              ? DateTime.parse(json['created_at'].toString())
              : DateTime.now()),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'].toString())
          : (json['updated_at'] != null
              ? DateTime.parse(json['updated_at'].toString())
              : DateTime.now()),
    );
  }
}

class AppMediaFile {
  AppMediaFile({
    required this.id,
    required this.mediaId,
    this.sourceId,
    this.sourceChatId,
    this.sourceName,
    required this.fileUniqueId,
    this.videoLanguage,
    this.quality,
    this.size,
    this.versionTag,
    this.language,
    this.subtitleMentioned = false,
    this.subtitlePresentation,
    this.subtitleLanguage,
    this.captionText,
    this.canStream = false,
    this.season,
    this.episode,
    required this.createdAt,
    required this.updatedAt,
    // Note: To play via TDLib, the app might need telegramFileId from file_backups.
    // If backend provides it in the response, we parse it here.
    this.telegramFileId,
    this.locatorType,
    this.locatorChatId,
    this.locatorMessageId,
    this.locatorBotUsername,
    this.locatorRemoteFileId,
  });

  final String id;
  final String mediaId;
  final String? sourceId;
  final int? sourceChatId;

  /// Resolved label from backend [Source.name] (group title, contact, Saved messages, …).
  final String? sourceName;
  final String fileUniqueId;
  final String? videoLanguage;
  final String? quality;
  final int? size;
  final String? versionTag;
  final String? language;
  final bool subtitleMentioned;
  final String? subtitlePresentation;
  final String? subtitleLanguage;
  final String? captionText;
  final bool canStream;
  final int? season;
  final int? episode;
  final DateTime createdAt;
  final DateTime updatedAt;

  // Extended fields for client usage
  final String? telegramFileId;
  final String? locatorType;
  final int? locatorChatId;
  final int? locatorMessageId;
  final String? locatorBotUsername;
  final String? locatorRemoteFileId;

  factory AppMediaFile.fromJson(Map<String, dynamic> json) {
    return AppMediaFile(
      id: (json['id'] ?? '').toString(),
      mediaId: (json['mediaId'] ?? json['media_id'] ?? '').toString(),
      sourceId: json['sourceId']?.toString() ?? json['source_id']?.toString(),
      sourceChatId: _parseNullableInt(
        json['sourceChatId'] ?? json['source_chat_id'],
      ),
      sourceName: () {
        final raw =
            json['sourceName']?.toString() ?? json['source_name']?.toString();
        if (raw == null) return null;
        final t = raw.trim();
        return t.isEmpty ? null : t;
      }(),
      fileUniqueId:
          (json['fileUniqueId'] ?? json['file_unique_id'] ?? '').toString(),
      videoLanguage: json['videoLanguage']?.toString() ??
          json['video_language']?.toString(),
      quality: json['quality']?.toString(),
      size: _parseNullableInt(
        json['size'] ??
            json['fileSize'] ??
            json['file_size'] ??
            json['bytes'] ??
            json['fileBytes'] ??
            json['file_bytes'],
      ),
      versionTag:
          json['versionTag']?.toString() ?? json['version_tag']?.toString(),
      language: json['language']?.toString(),
      subtitleMentioned: json['subtitleMentioned'] == true ||
          json['subtitle_mentioned'] == true,
      subtitlePresentation: json['subtitlePresentation']?.toString() ??
          json['subtitle_presentation']?.toString(),
      subtitleLanguage: json['subtitleLanguage']?.toString() ??
          json['subtitle_language']?.toString(),
      captionText:
          json['captionText']?.toString() ?? json['caption_text']?.toString(),
      canStream: json['canStream'] == true || json['can_stream'] == true,
      season: json['season'] as int?,
      episode: json['episode'] as int?,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'].toString())
          : (json['created_at'] != null
              ? DateTime.parse(json['created_at'].toString())
              : DateTime.now()),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'].toString())
          : (json['updated_at'] != null
              ? DateTime.parse(json['updated_at'].toString())
              : DateTime.now()),
      telegramFileId: json['telegramFileId']?.toString() ??
          json['telegram_file_id']?.toString(),
      locatorType:
          json['locatorType']?.toString() ?? json['locator_type']?.toString(),
      locatorChatId:
          _parseNullableInt(json['locatorChatId'] ?? json['locator_chat_id']),
      locatorMessageId: _parseNullableInt(
        json['locatorMessageId'] ?? json['locator_message_id'],
      ),
      locatorBotUsername: json['locatorBotUsername']?.toString() ??
          json['locator_bot_username']?.toString(),
      locatorRemoteFileId: json['locatorRemoteFileId']?.toString() ??
          json['locator_remote_file_id']?.toString(),
    );
  }
}

int? _parseNullableInt(dynamic raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw.toString());
}

/// Represents the aggregate response from the library endpoint
class AppMediaAggregate {
  AppMediaAggregate({
    required this.media,
    required this.files,
    this.currentUserHasAccess = false,
  });

  final AppMedia media;
  final List<AppMediaFile> files;
  /// From API: user has [UserAccess] for this media (e.g. after requesting a file).
  final bool currentUserHasAccess;

  factory AppMediaAggregate.fromJson(Map<String, dynamic> json) {
    return AppMediaAggregate(
      media: AppMedia.fromJson(json['media'] as Map<String, dynamic>? ?? json),
      files: (json['files'] as List<dynamic>?)
              ?.map((e) => AppMediaFile.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      currentUserHasAccess: json['currentUserHasAccess'] == true,
    );
  }
}
