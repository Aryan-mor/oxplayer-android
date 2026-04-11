import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../focus/focus_theme.dart';
import '../focus/focusable_wrapper.dart';
import '../models/download_models.dart';
import '../providers/download_provider.dart';
import '../theme/mono_tokens.dart';
import 'app_icon.dart';
import 'collapsible_text.dart';
import 'placeholder_container.dart';

class OxFileOptionCard extends StatelessWidget {
  const OxFileOptionCard({
    super.key,
    required this.title,
    required this.onTap,
    this.badgeLabel,
    this.infoLine,
    this.summary,
    this.imageUrl,
    this.localPosterPath,
    this.focusNode,
    this.autofocus = false,
    this.onNavigateUp,
    this.downloadGlobalKey,
    this.onDownloadTap,
  });

  final String title;
  final String? badgeLabel;
  final String? infoLine;
  final String? summary;
  final String? imageUrl;
  final String? localPosterPath;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  final bool autofocus;
  final VoidCallback? onNavigateUp;
  final String? downloadGlobalKey;
  final VoidCallback? onDownloadTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: FocusableWrapper(
        focusNode: focusNode,
        autofocus: autofocus,
        disableScale: true,
        onNavigateUp: onNavigateUp,
        onSelect: onTap,
        child: InkWell(
          borderRadius: BorderRadius.circular(FocusTheme.defaultBorderRadius),
          onTap: onTap,
          hoverColor: Theme.of(context).colorScheme.surface.withValues(alpha: 0.05),
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(FocusTheme.defaultBorderRadius),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 160,
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: const BorderRadius.all(Radius.circular(6)),
                        child: AspectRatio(aspectRatio: 16 / 9, child: _buildThumbnail()),
                      ),
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: const BorderRadius.all(Radius.circular(6)),
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Colors.black.withValues(alpha: 0.2)],
                            ),
                          ),
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.6),
                                shape: BoxShape.circle,
                              ),
                              child: const AppIcon(Symbols.play_arrow_rounded, fill: 1, color: Colors.white, size: 20),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (badgeLabel != null && badgeLabel!.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primaryContainer,
                                borderRadius: const BorderRadius.all(Radius.circular(3)),
                              ),
                              child: Text(
                                badgeLabel!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (badgeLabel != null && badgeLabel!.isNotEmpty) const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              title,
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (downloadGlobalKey != null && onDownloadTap != null)
                            Consumer<DownloadProvider>(
                              builder: (context, downloadProvider, _) {
                                final progress = downloadProvider.getProgress(downloadGlobalKey!);
                                final isQueueing = downloadProvider.isQueueing(downloadGlobalKey!);
                                Widget icon;
                                VoidCallback? onPressed = onDownloadTap;

                                if (isQueueing) {
                                  icon = SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: tokens(context).textMuted,
                                    ),
                                  );
                                  onPressed = null;
                                } else {
                                  switch (progress?.status) {
                                    case DownloadStatus.queued:
                                      icon = AppIcon(
                                        Symbols.schedule_rounded,
                                        fill: 1,
                                        size: 18,
                                        color: tokens(context).textMuted,
                                      );
                                      onPressed = () async {
                                        await downloadProvider.pauseDownload(downloadGlobalKey!);
                                      };
                                    case DownloadStatus.downloading:
                                      icon = SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          value: progress?.progressPercent,
                                          strokeWidth: 2,
                                          color: Theme.of(context).colorScheme.primary,
                                        ),
                                      );
                                      onPressed = () async {
                                        await downloadProvider.pauseDownload(downloadGlobalKey!);
                                      };
                                    case DownloadStatus.completed:
                                      icon = const AppIcon(
                                        Symbols.file_download_done_rounded,
                                        fill: 1,
                                        size: 18,
                                        color: Colors.green,
                                      );
                                      onPressed = null;
                                    case DownloadStatus.failed:
                                      icon = AppIcon(
                                        Symbols.download_rounded,
                                        fill: 1,
                                        size: 18,
                                        color: Theme.of(context).colorScheme.error,
                                      );
                                    default:
                                      icon = AppIcon(
                                        Symbols.download_rounded,
                                        fill: 1,
                                        size: 18,
                                        color: Theme.of(context).colorScheme.primary,
                                      );
                                  }
                                }

                                return IconButton(
                                  onPressed: onPressed,
                                  icon: icon,
                                  tooltip: (progress?.status == DownloadStatus.queued ||
                                          progress?.status == DownloadStatus.downloading)
                                      ? 'Pause download'
                                      : 'Download',
                                  visualDensity: VisualDensity.compact,
                                );
                              },
                            ),
                        ],
                      ),
                      if (infoLine != null && infoLine!.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          infoLine!,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens(context).textMuted),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (summary != null && summary!.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        CollapsibleText(
                          text: summary!,
                          maxLines: 3,
                          small: true,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: tokens(context).textMuted,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail() {
    if (localPosterPath != null) {
      return Image.file(
        File(localPosterPath!),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            const PlaceholderContainer(child: AppIcon(Symbols.movie_rounded, fill: 1, size: 32)),
      );
    }

    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return Image.network(
        imageUrl!,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            const PlaceholderContainer(child: AppIcon(Symbols.movie_rounded, fill: 1, size: 32)),
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return const PlaceholderContainer(child: CircularProgressIndicator(strokeWidth: 2));
        },
      );
    }

    return const PlaceholderContainer(child: AppIcon(Symbols.movie_rounded, fill: 1, size: 32));
  }
}