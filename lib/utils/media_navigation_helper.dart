import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import '../infrastructure/data_repository.dart';
import '../infrastructure/media_repository.dart';
import '../models/plex_metadata.dart';
import '../models/plex_playlist.dart';
import '../screens/collection_detail_screen.dart';
import '../screens/main_screen.dart';
import '../screens/media_detail_screen.dart';
import '../screens/playlist/playlist_detail_screen.dart';
import '../utils/global_key_utils.dart';
import '../utils/snackbar_helper.dart';
import 'video_player_navigation.dart';

/// Discover / OX hub items use `ox-preview:`; [MediaDetailScreen] only loads OX rows when [PlexMetadata.key] is `ox-library:`.
/// Call this instead of pushing [MediaDetailScreen] with raw preview metadata (matches MediaCard tap behavior).
Future<bool?> openOxPreviewMediaDetail(
  BuildContext context, {
  required PlexMetadata previewMetadata,
  required bool isOffline,
}) async {
  Future<bool?> openDetail(PlexMetadata metadata) async {
    return Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => MediaDetailScreen(metadata: metadata, isOffline: isOffline),
      ),
    );
  }

  try {
    final repository = await DataRepository.create();
    final mediaRepository = MediaRepository(dataRepository: repository);
    final detail = await mediaRepository.fetchLibraryMediaDetail(previewMetadata.ratingKey);
    if (!context.mounted) return null;

    final mappedMetadata = mapOxLibraryDetailToPlexMetadata(detail, fallback: previewMetadata);
    return openDetail(mappedMetadata);
  } catch (_) {
    if (!context.mounted) return null;
    // If prefetch fails (timeout, 404, parse), still open detail so it can retry and/or show fallback UI.
    final stub = previewMetadata.copyWith(
      key: 'ox-library:${previewMetadata.ratingKey}',
      serverId: previewMetadata.serverId ?? kOxVirtualServerId,
    );
    try {
      return openDetail(stub);
    } catch (_) {
      showGlobalAppSnackBar('Failed to open detail page. Please try again.');
      return null;
    }
  }
}

/// Maps OX library API detail to [PlexMetadata] with `ox-library:` key (shared with [MediaCard]).
PlexMetadata mapOxLibraryDetailToPlexMetadata(OxLibraryMediaDetail detail, {required PlexMetadata fallback}) {
  final media = detail.media;
  final normalizedType = switch (media.type.toUpperCase()) {
    'MOVIE' => 'movie',
    'SERIES' => 'show',
    'GENERAL_VIDEO' => 'movie',
    _ => fallback.type ?? 'movie',
  };
  final posterUrl = _resolveOxPosterUrl(media.posterPath) ?? fallback.thumb;

  return fallback.copyWith(
    ratingKey: media.id,
    key: 'ox-library:${media.id}',
    type: normalizedType,
    title: media.title,
    summary: media.summary,
    rating: media.voteAverage,
    year: media.releaseYear,
    thumb: posterUrl,
    art: posterUrl ?? fallback.art,
  );
}

String? _resolveOxPosterUrl(String? posterPath) {
  final value = posterPath?.trim();
  if (value == null || value.isEmpty) return null;
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return value;
  }
  final normalized = value.startsWith('/') ? value : '/$value';
  return 'https://image.tmdb.org/t/p/w500$normalized';
}

/// Starts OX internal playback after a TV [OxCastOffer] (same flow as [MediaDetailScreen] OX file play).
Future<void> startOxCastPlayback(
  BuildContext context, {
  required String mediaGlobalId,
  required String fileId,
}) async {
  final repository = await DataRepository.create();
  final mediaRepository = MediaRepository(dataRepository: repository);
  final detail = await mediaRepository.fetchLibraryMediaDetail(mediaGlobalId);
  if (!context.mounted) return;

  OxLibraryMediaDetailFile? file;
  for (final f in detail.files) {
    if (f.id == fileId) {
      file = f;
      break;
    }
  }
  if (file == null) {
    showGlobalAppSnackBar('Cast: could not find that file.');
    return;
  }

  final fallback = PlexMetadata(
    ratingKey: mediaGlobalId,
    key: 'ox-library:$mediaGlobalId',
    serverId: kOxVirtualServerId,
    type: 'movie',
    title: detail.media.title,
  );
  final metadata = mapOxLibraryDetailToPlexMetadata(detail, fallback: fallback);

  final playbackResolution = await mediaRepository.resolveStreamUrlForInternalPlaybackWithRecovery(
    file: file,
    detailGlobalId: mediaGlobalId,
  );
  final streamUrl = playbackResolution.streamUrl;

  if (!context.mounted) return;

  if (streamUrl == null) {
    await mediaRepository.releaseInternalPlaybackSession(reason: 'cast_stream_unavailable');
    showGlobalAppSnackBar('Could not start playback.');
    return;
  }

  final videoUrl = streamUrl.toString();
  final playbackFuture = navigateToInternalVideoPlayerForUrl(
    context,
    metadata: metadata,
    videoUrl: videoUrl,
  );
  playbackFuture.whenComplete(() async {
    await mediaRepository.releaseInternalPlaybackSession(reason: 'video_player_closed');
  });
  unawaited(playbackFuture);
}

/// Result of media navigation indicating what action was taken
enum MediaNavigationResult {
  /// Navigation completed successfully
  navigated,

  /// Navigation completed, parent list should be refreshed (e.g., collection deleted)
  listRefreshNeeded,

  /// Item type not supported (e.g., music content)
  unsupported,

  /// Item is a library section — navigated to that library
  librarySelected,
}

/// Navigates to the appropriate screen based on the item type.
///
/// For episodes, starts playback directly via video player.
/// For movies, starts playback directly if [playDirectly] is true, otherwise
/// navigates to media detail screen.
/// For seasons, navigates to season detail screen.
/// For playlists, navigates to playlist detail screen.
/// For collections, navigates to collection detail screen.
/// For other types (shows), navigates to media detail screen.
/// For music types (artist, album, track), returns [MediaNavigationResult.unsupported].
///
/// The [onRefresh] callback is invoked with the item's ratingKey after
/// returning from the detail screen, allowing the caller to refresh state.
///
/// Set [isOffline] to true for downloaded content without server access.
///
/// Set [playDirectly] to true to play movies immediately (e.g., from continue watching).
///
/// Returns a [MediaNavigationResult] indicating what action was taken:
/// - [MediaNavigationResult.navigated]: Navigation completed, item refresh handled
/// - [MediaNavigationResult.listRefreshNeeded]: Caller should refresh entire list
/// - [MediaNavigationResult.unsupported]: Item type not supported, caller should handle
Future<MediaNavigationResult> navigateToMediaItem(
  BuildContext context,
  dynamic item, {
  void Function(String)? onRefresh,
  bool isOffline = false,
  bool playDirectly = false,
}) async {
  // Handle playlists
  if (item is PlexPlaylist) {
    await Navigator.push(context, MaterialPageRoute(builder: (context) => PlaylistDetailScreen(playlist: item)));
    return MediaNavigationResult.navigated;
  }

  final metadata = item as PlexMetadata;

  // Handle library section items (shared whole-library entries)
  if (metadata.isLibrarySection) {
    final sectionKey = metadata.librarySectionKey;
    if (sectionKey != null && metadata.serverId != null) {
      final libraryGlobalKey = buildGlobalKey(metadata.serverId!, sectionKey);
      MainScreenFocusScope.of(context)?.selectLibrary?.call(libraryGlobalKey);
      return MediaNavigationResult.librarySelected;
    }
    return MediaNavigationResult.unsupported;
  }

  // OX Discover preview cards: hub OK uses this helper — same as MediaCard tap (prefetch → `ox-library:` detail).
  if (metadata.key?.startsWith('ox-preview:') == true) {
    final result = await openOxPreviewMediaDetail(
      context,
      previewMetadata: metadata,
      isOffline: isOffline,
    );
    if (result == true) {
      onRefresh?.call(metadata.ratingKey);
    }
    return MediaNavigationResult.navigated;
  }

  switch (metadata.mediaType) {
    case PlexMediaType.collection:
      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (context) => CollectionDetailScreen(collection: metadata)),
      );
      // If collection was deleted, signal that list refresh is needed
      if (result == true) {
        return MediaNavigationResult.listRefreshNeeded;
      }
      return MediaNavigationResult.navigated;

    case PlexMediaType.artist:
    case PlexMediaType.album:
    case PlexMediaType.track:
      // Music types not supported
      return MediaNavigationResult.unsupported;

    case PlexMediaType.clip:
    case PlexMediaType.episode:
      // For episodes and clips (trailers/extras), start playback directly
      final result = await navigateToVideoPlayer(context, metadata: metadata, isOffline: isOffline);
      if (result == true) {
        onRefresh?.call(metadata.ratingKey);
      }
      return MediaNavigationResult.navigated;

    case PlexMediaType.movie:
      if (playDirectly) {
        // For movies in continue watching, start playback directly
        final result = await navigateToVideoPlayer(context, metadata: metadata, isOffline: isOffline);
        if (result == true) {
          onRefresh?.call(metadata.ratingKey);
        }
        return MediaNavigationResult.navigated;
      }
      // Fall through to default case for detail screen
      continue defaultCase;

    case PlexMediaType.season:
      // Navigate to the parent show with the season tab pre-selected
      if (metadata.parentRatingKey != null) {
        final showStub = PlexMetadata(
          ratingKey: metadata.parentRatingKey!,
          key: '/library/metadata/${metadata.parentRatingKey}',
          type: 'show',
          title: metadata.grandparentTitle ?? metadata.parentTitle ?? metadata.displayTitle,
          thumb: metadata.grandparentThumb ?? metadata.parentThumb,
          art: metadata.grandparentArt,
          serverId: metadata.serverId,
          serverName: metadata.serverName,
        );
        final result = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (context) => MediaDetailScreen(
              metadata: showStub,
              isOffline: isOffline,
              initialSeasonIndex: metadata.index,
            ),
          ),
        );
        if (result == true) {
          onRefresh?.call(metadata.ratingKey);
        }
        return MediaNavigationResult.navigated;
      }
      continue defaultCase;

    defaultCase:
    default:
      // For all other types (shows, movies), show detail screen
      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (context) => MediaDetailScreen(metadata: metadata, isOffline: isOffline),
        ),
      );
      if (result == true) {
        onRefresh?.call(metadata.ratingKey);
      }
      return MediaNavigationResult.navigated;
  }
}
