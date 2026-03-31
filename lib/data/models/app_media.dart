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
    this.rawDetails,
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
  final String? rawDetails;
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
      rawDetails:
          json['rawDetails']?.toString() ?? json['raw_details']?.toString(),
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
    required this.fileUniqueId,
    this.videoLanguage,
    this.quality,
    this.size,
    this.versionTag,
    this.language,
    this.season,
    this.episode,
    required this.createdAt,
    required this.updatedAt,
    // Note: To play via TDLib, the app might need telegramFileId from file_backups.
    // If backend provides it in the response, we parse it here.
    this.telegramFileId,
  });

  final String id;
  final String mediaId;
  final String? sourceId;
  final String fileUniqueId;
  final String? videoLanguage;
  final String? quality;
  final int? size;
  final String? versionTag;
  final String? language;
  final int? season;
  final int? episode;
  final DateTime createdAt;
  final DateTime updatedAt;

  // Extended fields for client usage
  final String? telegramFileId;

  factory AppMediaFile.fromJson(Map<String, dynamic> json) {
    return AppMediaFile(
      id: (json['id'] ?? '').toString(),
      mediaId: (json['mediaId'] ?? json['media_id'] ?? '').toString(),
      sourceId: json['sourceId']?.toString() ?? json['source_id']?.toString(),
      fileUniqueId:
          (json['fileUniqueId'] ?? json['file_unique_id'] ?? '').toString(),
      videoLanguage: json['videoLanguage']?.toString() ??
          json['video_language']?.toString(),
      quality: json['quality']?.toString(),
      size: json['size'] as int?,
      versionTag:
          json['versionTag']?.toString() ?? json['version_tag']?.toString(),
      language: json['language']?.toString(),
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
    );
  }
}

/// Represents the aggregate response from the library endpoint
class AppMediaAggregate {
  AppMediaAggregate({
    required this.media,
    required this.files,
  });

  final AppMedia media;
  final List<AppMediaFile> files;

  factory AppMediaAggregate.fromJson(Map<String, dynamic> json) {
    return AppMediaAggregate(
      media: AppMedia.fromJson(json['media'] as Map<String, dynamic>? ?? json),
      files: (json['files'] as List<dynamic>?)
              ?.map((e) => AppMediaFile.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}
