import '../models/plex_metadata.dart';
import '../utils/formatters.dart';
import 'data_repository.dart';

const String kOxVirtualServerId = 'ox';

String buildOxDownloadRatingKey(OxLibraryMediaDetailFile file) => 'ox-download:${file.id}';

String buildOxDownloadVariantSuffix(OxLibraryMediaDetailFile file) {
  final parts = <String>[];
  final quality = (file.quality ?? '').trim();
  final language = (file.videoLanguage ?? file.language ?? '').trim().toUpperCase();
  if (quality.isNotEmpty) {
    parts.add(quality);
  }
  if (language.isNotEmpty) {
    parts.add(language);
  }
  return parts.isNotEmpty ? parts.join(' ') : 'File ${file.id}';
}

PlexMetadata buildOxDownloadMetadata({
  required PlexMetadata parentMetadata,
  required OxLibraryMediaDetailFile file,
}) {
  final ratingKey = buildOxDownloadRatingKey(file);
  final type = parentMetadata.mediaType == PlexMediaType.movie ? 'movie' : 'episode';
  final serverId = parentMetadata.serverId ?? kOxVirtualServerId;
  final title = (parentMetadata.title ?? '').trim();
  return parentMetadata.copyWith(
    ratingKey: ratingKey,
    key: 'ox-download:$ratingKey',
    type: type,
    title: title.isNotEmpty ? title : (type == 'movie' ? 'Movie' : 'Episode'),
    serverId: serverId,
  );
}

class OxFileOptionItem {
  const OxFileOptionItem({
    required this.key,
    required this.file,
    required this.title,
    this.badgeLabel,
    this.infoLine,
    this.summary,
  });

  final String key;
  final OxLibraryMediaDetailFile file;
  final String title;
  final String? badgeLabel;
  final String? infoLine;
  final String? summary;
}

class OxSeriesSeasonGroup {
  const OxSeriesSeasonGroup({required this.season, required this.episodes});

  final PlexMetadata season;
  final List<PlexMetadata> episodes;
}

class OxSeriesDetailView {
  const OxSeriesDetailView({
    required this.series,
    required this.seasons,
    required this.fileOptionsByParentKey,
    this.firstEpisode,
  });

  final PlexMetadata series;
  final List<OxSeriesSeasonGroup> seasons;
  final Map<String, List<OxFileOptionItem>> fileOptionsByParentKey;
  final PlexMetadata? firstEpisode;
}

class MediaRepository {
  const MediaRepository({required this.dataRepository});

  final DataRepository dataRepository;

  Future<OxLibraryMediaDetail> fetchLibraryMediaDetail(String globalId) {
    return dataRepository.fetchOxLibraryMediaDetail(globalId);
  }

  /// Picks the first streamable file, or falls back to the first available file.
  OxLibraryMediaDetailFile? selectPreferredFile(OxLibraryMediaDetail detail) {
    return selectPreferredFileFromFiles(detail.files);
  }

  OxLibraryMediaDetailFile? selectPreferredFileFromFiles(Iterable<OxLibraryMediaDetailFile> files) {
    for (final file in files) {
      if (file.canStream == true) {
        return file;
      }
    }
    final iterator = files.iterator;
    if (!iterator.moveNext()) {
      return null;
    }
    return iterator.current;
  }

  List<OxFileOptionItem> buildFileOptions(
    List<OxLibraryMediaDetailFile> files, {
    String? titlePrefix,
  }) {
    final items = <OxFileOptionItem>[];

    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      final fallbackTitle = titlePrefix != null && titlePrefix.isNotEmpty ? '$titlePrefix ${index + 1}' : 'File ${index + 1}';
      final titleParts = <String>[];
      if ((file.quality ?? '').trim().isNotEmpty) {
        titleParts.add(file.quality!.trim());
      }
      if ((file.videoLanguage ?? file.language ?? '').trim().isNotEmpty) {
        titleParts.add((file.videoLanguage ?? file.language)!.trim().toUpperCase());
      }
      final title = titleParts.isNotEmpty ? titleParts.join(' ') : fallbackTitle;

      final infoParts = <String>[];
      if ((file.sourceName ?? '').trim().isNotEmpty) {
        infoParts.add(file.sourceName!.trim());
      }
      if (file.size != null && file.size! > 0) {
        infoParts.add(ByteFormatter.formatBytes(file.size!));
      }
      if (file.canStream == false) {
        infoParts.add('Needs recovery');
      }

      final summaryParts = <String>[];
      if (file.subtitleMentioned == true) {
        final subtitleLabel = (file.subtitleLanguage ?? file.subtitlePresentation ?? '').trim();
        summaryParts.add(subtitleLabel.isNotEmpty ? 'Subs $subtitleLabel' : 'Subtitles');
      }
      final caption = (file.captionText ?? '').trim();
      if (caption.isNotEmpty) {
        summaryParts.add(caption.length > 140 ? '${caption.substring(0, 137)}...' : caption);
      }

      items.add(
        OxFileOptionItem(
          key: file.id,
          file: file,
          title: title,
          badgeLabel: files.length > 1 ? 'F${index + 1}' : null,
          infoLine: infoParts.isNotEmpty ? toBulletedString(infoParts) : null,
          summary: summaryParts.isNotEmpty ? toBulletedString(summaryParts) : null,
        ),
      );
    }

    return items;
  }

  List<OxFileOptionItem> buildMovieFileOptions(OxLibraryMediaDetail detail) {
    return buildFileOptions(detail.files, titlePrefix: detail.media.title);
  }

  OxSeriesDetailView buildSeriesDetailView({
    required OxLibraryMediaDetail detail,
    required PlexMetadata fallback,
  }) {
    final serverId = fallback.serverId ?? kOxVirtualServerId;
    final series = fallback.copyWith(
      ratingKey: detail.media.id,
      key: 'ox-library:${detail.media.id}',
      type: 'show',
      title: detail.media.title,
      summary: detail.media.summary,
      rating: detail.media.voteAverage,
      year: detail.media.releaseYear,
      serverId: serverId,
    );

    final groupedFiles = <int, Map<int, List<OxLibraryMediaDetailFile>>>{};
    for (final file in detail.files) {
      final seasonNumber = file.season ?? 1;
      final episodeNumber = file.episode ?? 0;
      final seasonGroup = groupedFiles.putIfAbsent(seasonNumber, () => <int, List<OxLibraryMediaDetailFile>>{});
      seasonGroup.putIfAbsent(episodeNumber, () => <OxLibraryMediaDetailFile>[]).add(file);
    }

    final seasonNumbers = groupedFiles.keys.toList()..sort();
    final seasons = <OxSeriesSeasonGroup>[];
    final fileOptionsByParentKey = <String, List<OxFileOptionItem>>{};

    for (final seasonNumber in seasonNumbers) {
      final episodeMap = groupedFiles[seasonNumber]!;
      final episodeNumbers = episodeMap.keys.toList()..sort();
      final seasonRatingKey = '${detail.media.id}:season:$seasonNumber';
      final episodeItems = <PlexMetadata>[];

      for (final episodeNumber in episodeNumbers) {
        final files = episodeMap[episodeNumber]!;
        final selectedFile = selectPreferredFileFromFiles(files);
        if (selectedFile == null) {
          continue;
        }

        final episodeRatingKey = '${detail.media.id}:season:$seasonNumber:episode:$episodeNumber';
        final fileOptions = buildFileOptions(
          files,
          titlePrefix: episodeNumber > 0 ? 'Episode $episodeNumber' : 'Episode',
        );
        fileOptionsByParentKey[episodeRatingKey] = fileOptions;

        final qualities = files
            .map((file) => (file.quality ?? '').trim())
            .where((quality) => quality.isNotEmpty)
            .toSet()
            .toList();
        qualities.sort();
        final summaryParts = <String>['${files.length} file${files.length == 1 ? '' : 's'}'];
        if (qualities.isNotEmpty) {
          summaryParts.add(qualities.join(' / '));
        }

        final episodeTitle = episodeNumber > 0 ? 'Episode $episodeNumber' : 'Episode';
        episodeItems.add(
          PlexMetadata(
            ratingKey: episodeRatingKey,
            key: 'ox-library:$episodeRatingKey',
            type: 'episode',
            title: episodeTitle,
            summary: toBulletedString(summaryParts),
            year: detail.media.releaseYear,
            thumb: series.thumb,
            art: series.art,
            grandparentTitle: detail.media.title,
            grandparentThumb: series.thumb,
            grandparentArt: series.art,
            grandparentRatingKey: detail.media.id,
            parentTitle: 'Season $seasonNumber',
            parentThumb: series.thumb,
            parentRatingKey: seasonRatingKey,
            parentIndex: seasonNumber,
            index: episodeNumber > 0 ? episodeNumber : null,
            serverId: serverId,
            serverName: fallback.serverName,
          ),
        );
      }

      seasons.add(
        OxSeriesSeasonGroup(
          season: PlexMetadata(
            ratingKey: seasonRatingKey,
            key: 'ox-library:$seasonRatingKey',
            type: 'season',
            title: 'Season $seasonNumber',
            index: seasonNumber,
            leafCount: episodeItems.length,
            grandparentTitle: detail.media.title,
            grandparentThumb: series.thumb,
            grandparentArt: series.art,
            parentRatingKey: detail.media.id,
            serverId: serverId,
            serverName: fallback.serverName,
          ),
          episodes: episodeItems,
        ),
      );
    }

    PlexMetadata? firstEpisode;
    for (final seasonGroup in seasons) {
      if ((seasonGroup.season.index ?? 0) > 0 && seasonGroup.episodes.isNotEmpty) {
        firstEpisode = seasonGroup.episodes.first;
        break;
      }
    }
    firstEpisode ??= seasons.isNotEmpty && seasons.first.episodes.isNotEmpty ? seasons.first.episodes.first : null;

    return OxSeriesDetailView(
      series: series,
      seasons: seasons,
      fileOptionsByParentKey: fileOptionsByParentKey,
      firstEpisode: firstEpisode,
    );
  }

  Future<String?> resolveFilePathForSystemPlayback(OxLibraryMediaDetailFile file) {
    return dataRepository.resolveOxMediaFilePathForPlayback(
      mediaId: file.id,
      fileUniqueId: file.fileUniqueId,
      locatorType: file.locatorType,
      locatorChatId: file.locatorChatId,
      locatorMessageId: file.locatorMessageId,
      locatorRemoteFileId: file.locatorRemoteFileId,
    );
  }

  Future<String?> resolveFilePathForInternalPlayback(OxLibraryMediaDetailFile file) {
    return dataRepository.resolveOxMediaFilePathForPlayback(
      mediaId: file.id,
      fileUniqueId: file.fileUniqueId,
      locatorType: file.locatorType,
      locatorChatId: file.locatorChatId,
      locatorMessageId: file.locatorMessageId,
      locatorRemoteFileId: file.locatorRemoteFileId,
      allowQuickStart: false,
    );
  }

  Future<String?> resolveFilePathForOfflineDownload(OxLibraryMediaDetailFile file) {
    return dataRepository.resolveOxMediaFilePathForPlayback(
      mediaId: file.id,
      fileUniqueId: file.fileUniqueId,
      locatorType: file.locatorType,
      locatorChatId: file.locatorChatId,
      locatorMessageId: file.locatorMessageId,
      locatorRemoteFileId: file.locatorRemoteFileId,
      allowQuickStart: false,
    );
  }

  Future<Uri?> resolveStreamUrlForInternalPlayback(OxLibraryMediaDetailFile file) {
    return dataRepository.resolveOxMediaStreamUrlForPlayback(
      mediaId: file.id,
      fileUniqueId: file.fileUniqueId,
      locatorType: file.locatorType,
      locatorChatId: file.locatorChatId,
      locatorMessageId: file.locatorMessageId,
      locatorRemoteFileId: file.locatorRemoteFileId,
    );
  }

  Future<int> releaseInternalPlaybackSession({String? reason}) {
    return dataRepository.releaseOxMediaPlaybackSession(reason: reason);
  }

  Future<bool> requestMediaRecovery(String mediaId) {
    return dataRepository.requestOxMediaRecovery(mediaId);
  }

  /// Fetches and caches the Telegram thumbnail for a [general_video] item.
  ///
  /// Delegates to [DataRepository.fetchVideoThumbnail] which resolves the
  /// Telegram file through locator metadata first and falls back to source
  /// message thumbnail extraction only when needed. Returns a local absolute
  /// file path, or `null` when no thumbnail is available.
  Future<String?> fetchVideoThumbnail(OxLibraryMediaItem item) {
    return dataRepository.fetchVideoThumbnail(
      mediaId: item.globalId,
      fileUniqueId: item.fileUniqueId,
      locatorType: item.locatorType,
      locatorChatId: item.locatorChatId,
      locatorMessageId: item.locatorMessageId,
      locatorRemoteFileId: item.locatorRemoteFileId,
      chatId: item.thumbnailSourceChatId,
      messageId: item.thumbnailSourceMessageId,
    );
  }
}