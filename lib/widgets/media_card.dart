import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../data/models/app_media.dart';
import 'library_media_poster.dart';

class MediaCard extends StatefulWidget {
  const MediaCard({
    super.key,
    required this.item,
    this.onTap,
    this.width = 220,
    this.height,
  });

  final AppMediaAggregate item;
  final VoidCallback? onTap;
  final double width;
  final double? height;

  @override
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard> {
  @override
  Widget build(BuildContext context) {
    final year = widget.item.media.releaseYear;
    final posterHeight = widget.height;
    final posterWidth = widget.width - 6;

    return SizedBox(
      width: widget.width,
      child: InkWell(
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(8),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (posterHeight != null)
                SizedBox(
                  width: posterWidth,
                  height: posterHeight,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LibraryMediaPoster(
                      media: widget.item.media,
                      files: widget.item.files,
                      placeholderIconSize: 32,
                    ),
                  ),
                )
              else
                AspectRatio(
                  aspectRatio: 2 / 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LibraryMediaPoster(
                      media: widget.item.media,
                      files: widget.item.files,
                      placeholderIconSize: 32,
                    ),
                  ),
                ),
              const SizedBox(height: 2),
              Text(
                widget.item.media.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                  color: AppColors.onSurfacePrimary,
                ),
              ),
              Text(
                year?.toString() ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.1,
                  color: AppColors.textMuted.withValues(alpha: 0.92),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
