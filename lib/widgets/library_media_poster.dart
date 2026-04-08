import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../models/app_media.dart';

/// Displays a poster image for an [AppMedia] item using its [AppMediaFile]s.
///
/// Falls back to a placeholder icon when no artwork URL is available.
class LibraryMediaPoster extends StatelessWidget {
  const LibraryMediaPoster({
    super.key,
    required this.media,
    required this.files,
    this.fit = BoxFit.cover,
    this.placeholderIconSize = 40.0,
    this.progressStrokeWidth = 3.0,
  });

  final AppMedia media;
  final List<AppMediaFile> files;
  final BoxFit fit;
  final double placeholderIconSize;
  final double progressStrokeWidth;

  String? _posterUrl() {
    // First check if the media itself has a poster path (e.g., from TMDB)
    if (media.posterPath != null && media.posterPath!.isNotEmpty) {
      final path = media.posterPath!;
      if (path.startsWith('http')) return path;
      return 'https://image.tmdb.org/t/p/w500$path';
    }
    return null;
  }

  IconData _placeholderIcon() {
    return switch (media.type.toUpperCase()) {
      'SERIES' || '#series' => Icons.tv_rounded,
      'MOVIE' || '#movie' => Icons.movie_rounded,
      _ => Icons.video_file_rounded,
    };
  }

  @override
  Widget build(BuildContext context) {
    final url = _posterUrl();
    if (url != null) {
      return CachedNetworkImage(
        imageUrl: url,
        fit: fit,
        width: double.infinity,
        height: double.infinity,
        placeholder: (_, __) => _buildPlaceholder(context),
        errorWidget: (_, __, ___) => _buildPlaceholder(context),
      );
    }
    return _buildPlaceholder(context);
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          _placeholderIcon(),
          size: placeholderIconSize,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
        ),
      ),
    );
  }
}
