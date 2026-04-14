import 'package:flutter/material.dart';

import '../models/plex_metadata.dart';
import '../screens/telegram/telegram_video_metadata.dart';
import '../utils/formatters.dart';

/// Small duration + file size line for video posters (movies, OX general_video, Telegram).
String? videoFileTechnicalSummary(PlexMetadata metadata) {
  final parts = <String>[];
  final d = metadata.duration;
  if (d != null && d > 0) {
    parts.add(formatDurationTimestamp(Duration(milliseconds: d)));
  }
  final bytes = metadata.primaryFileSize;
  if (bytes != null && bytes > 0) {
    parts.add(ByteFormatter.formatBytes(bytes, decimals: 1));
  }
  if (parts.isEmpty) return null;
  return parts.join(' · ');
}

bool shouldShowVideoPosterTechnicalOverlay(PlexMetadata metadata) {
  if (metadata is TelegramVideoMetadata) return true;
  return metadata.mediaType == PlexMediaType.movie;
}

/// Semi-transparent pill: duration (e.g. `1:30`) and file size — shared by grid posters and hero.
class MediaThumbnailInfoPill extends StatelessWidget {
  const MediaThumbnailInfoPill({super.key, required this.text, this.fontSize = 10});

  final String text;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.95),
                fontSize: fontSize,
                height: 1.15,
                fontWeight: FontWeight.w500,
              ),
        ),
      ),
    );
  }
}

/// Bottom-right overlay on grid/list thumbnails.
class MediaThumbnailInfoOverlay extends StatelessWidget {
  const MediaThumbnailInfoOverlay({
    super.key,
    required this.text,
    this.alignment = Alignment.bottomRight,
    this.padding = const EdgeInsets.fromLTRB(4, 4, 6, 6),
  });

  final String text;
  final Alignment alignment;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: padding,
          child: MediaThumbnailInfoPill(text: text),
        ),
      ),
    );
  }
}

/// Detail page line (same data as poster overlay, for typography below hero or in metadata).
class VideoFileTechnicalInfoLine extends StatelessWidget {
  const VideoFileTechnicalInfoLine({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
    );
  }
}
