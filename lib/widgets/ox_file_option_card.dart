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
import 'plex_style_download_ring_icon.dart';
import 'placeholder_container.dart';

/// One playable OX file variant with optional download controls.
///
/// TV: play (main body) is separate from the download column. Inside the column,
/// primary is pause / resume / queue / delete; when a download is active, a second
/// row offers **Cancel** (remove in-progress download).
class OxFileOptionCard extends StatefulWidget {
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
    this.onQueueDownload,
    this.onPauseDownload,
    this.onResumeDownload,
    this.onCancelActiveDownload,
    this.onDeleteCompletedDownload,
    this.onRetryDownload,
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

  final VoidCallback? onQueueDownload;
  final VoidCallback? onPauseDownload;
  final VoidCallback? onResumeDownload;
  final VoidCallback? onCancelActiveDownload;
  final VoidCallback? onDeleteCompletedDownload;
  final VoidCallback? onRetryDownload;

  @override
  State<OxFileOptionCard> createState() => _OxFileOptionCardState();
}

class _OxFileOptionCardState extends State<OxFileOptionCard> {
  FocusNode? _downloadPrimaryFocusNode;
  FocusNode? _downloadCancelFocusNode;

  bool get _hasDownload =>
      widget.downloadGlobalKey != null &&
      widget.onQueueDownload != null &&
      widget.onPauseDownload != null &&
      widget.onResumeDownload != null &&
      widget.onCancelActiveDownload != null &&
      widget.onDeleteCompletedDownload != null;

  @override
  void initState() {
    super.initState();
    if (_hasDownload) {
      _downloadPrimaryFocusNode = FocusNode(debugLabel: 'ox_file_download_primary');
      _downloadCancelFocusNode = FocusNode(debugLabel: 'ox_file_download_cancel');
    }
  }

  @override
  void didUpdateWidget(OxFileOptionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final had = oldWidget.downloadGlobalKey != null && oldWidget.onQueueDownload != null;
    if (had != _hasDownload) {
      _downloadPrimaryFocusNode?.dispose();
      _downloadCancelFocusNode?.dispose();
      _downloadPrimaryFocusNode = _hasDownload ? FocusNode(debugLabel: 'ox_file_download_primary') : null;
      _downloadCancelFocusNode = _hasDownload ? FocusNode(debugLabel: 'ox_file_download_cancel') : null;
    }
  }

  @override
  void dispose() {
    _downloadPrimaryFocusNode?.dispose();
    _downloadCancelFocusNode?.dispose();
    super.dispose();
  }

  bool _showCancelRow(DownloadProvider dp, String downloadKey) {
    if (dp.isQueueing(downloadKey)) return true;
    final s = dp.getProgress(downloadKey)?.status;
    return s == DownloadStatus.queued ||
        s == DownloadStatus.downloading ||
        s == DownloadStatus.paused;
  }

  @override
  Widget build(BuildContext context) {
    final playFocus = FocusableWrapper(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      disableScale: true,
      descendantsAreFocusable: false,
      onNavigateUp: widget.onNavigateUp,
      onNavigateRight: _hasDownload ? () => _downloadPrimaryFocusNode?.requestFocus() : null,
      onSelect: widget.onTap,
      child: InkWell(
        borderRadius: BorderRadius.circular(FocusTheme.defaultBorderRadius),
        onTap: widget.onTap,
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
                        if (widget.badgeLabel != null && widget.badgeLabel!.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primaryContainer,
                              borderRadius: const BorderRadius.all(Radius.circular(3)),
                            ),
                            child: Text(
                              widget.badgeLabel!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onPrimaryContainer,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        if (widget.badgeLabel != null && widget.badgeLabel!.isNotEmpty) const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.title,
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (widget.infoLine != null && widget.infoLine!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        widget.infoLine!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens(context).textMuted),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (widget.summary != null && widget.summary!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      CollapsibleText(
                        text: widget.summary!,
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
    );

    if (!_hasDownload || _downloadPrimaryFocusNode == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: playFocus,
      );
    }

    final downloadKey = widget.downloadGlobalKey!;

    final downloadColumn = Consumer<DownloadProvider>(
      builder: (context, downloadProvider, _) {
        final progress = downloadProvider.getProgress(downloadKey);
        final isQueueing = downloadProvider.isQueueing(downloadKey);
        final showCancel = _showCancelRow(downloadProvider, downloadKey);

        const ringDiameter = 40.0;
        const ringIconSize = 20.0;
        final primaryColor = Theme.of(context).colorScheme.primary;

        Widget primaryIcon;
        VoidCallback? primaryPressed;
        String primaryTooltip;

        if (isQueueing) {
          primaryIcon = PlexStyleDownloadRingIcon(
            indeterminate: true,
            determinateProgress: null,
            diameter: ringDiameter,
            strokeWidth: 2.5,
            progressColor: tokens(context).textMuted,
            centerIcon: AppIcon(Symbols.pause_rounded, fill: 1, size: ringIconSize, color: primaryColor),
          );
          primaryPressed = null;
          primaryTooltip = 'Preparing download';
        } else if (progress == null) {
          primaryIcon = AppIcon(Symbols.download_rounded, fill: 1, size: 22, color: primaryColor);
          primaryPressed = widget.onQueueDownload;
          primaryTooltip = 'Download';
        } else if (progress.status == DownloadStatus.queued || progress.status == DownloadStatus.downloading) {
          final queued = progress.status == DownloadStatus.queued;
          primaryIcon = PlexStyleDownloadRingIcon(
            indeterminate: queued,
            determinateProgress: queued ? null : progress.progressPercent,
            diameter: ringDiameter,
            strokeWidth: 2.5,
            progressColor: primaryColor,
            centerIcon: AppIcon(Symbols.pause_rounded, fill: 1, size: ringIconSize, color: primaryColor),
          );
          primaryPressed = widget.onPauseDownload;
          primaryTooltip = 'Pause download';
        } else if (progress.status == DownloadStatus.paused) {
          primaryIcon = PlexStyleDownloadRingIcon(
            indeterminate: false,
            determinateProgress: progress.progressPercent,
            diameter: ringDiameter,
            strokeWidth: 2.5,
            progressColor: primaryColor,
            centerIcon: AppIcon(Symbols.play_arrow_rounded, fill: 1, size: ringIconSize, color: primaryColor),
          );
          primaryPressed = widget.onResumeDownload;
          primaryTooltip = 'Resume download';
        } else if (progress.status == DownloadStatus.completed) {
          primaryIcon = AppIcon(
            Symbols.delete_outline_rounded,
            fill: 1,
            size: 22,
            color: Theme.of(context).colorScheme.error,
          );
          primaryPressed = widget.onDeleteCompletedDownload;
          primaryTooltip = 'Delete download';
        } else if (progress.status == DownloadStatus.failed) {
          primaryIcon = AppIcon(
            Symbols.download_rounded,
            fill: 1,
            size: 22,
            color: Theme.of(context).colorScheme.error,
          );
          primaryPressed = widget.onRetryDownload;
          primaryTooltip = 'Retry download';
        } else {
          // cancelled, partial, or unknown — offer download again
          primaryIcon = AppIcon(Symbols.download_rounded, fill: 1, size: 22, color: Theme.of(context).colorScheme.primary);
          primaryPressed = widget.onQueueDownload;
          primaryTooltip = 'Download';
        }

        final primaryControl = FocusableWrapper(
          focusNode: _downloadPrimaryFocusNode,
          disableScale: true,
          descendantsAreFocusable: false,
          onNavigateLeft: () => widget.focusNode?.requestFocus(),
          onNavigateDown: showCancel ? () => _downloadCancelFocusNode?.requestFocus() : null,
          onSelect: () {
            if (primaryPressed != null) primaryPressed();
          },
          child: IconButton(
            onPressed: primaryPressed,
            icon: primaryIcon,
            tooltip: primaryTooltip,
            visualDensity: VisualDensity.compact,
          ),
        );

        if (!showCancel || _downloadCancelFocusNode == null) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              primaryControl,
            ],
          );
        }

        final cancelControl = FocusableWrapper(
          focusNode: _downloadCancelFocusNode!,
          disableScale: true,
          descendantsAreFocusable: false,
          onNavigateUp: () => _downloadPrimaryFocusNode?.requestFocus(),
          onNavigateLeft: () => widget.focusNode?.requestFocus(),
          onSelect: widget.onCancelActiveDownload!,
          child: IconButton(
            onPressed: widget.onCancelActiveDownload,
            icon: AppIcon(Symbols.delete_outline_rounded, fill: 1, size: 20, color: tokens(context).textMuted),
            tooltip: 'Cancel download',
            visualDensity: VisualDensity.compact,
          ),
        );

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            primaryControl,
            cancelControl,
          ],
        );
      },
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: playFocus),
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 2),
            child: downloadColumn,
          ),
        ],
      ),
    );
  }

  Widget _buildThumbnail() {
    if (widget.localPosterPath != null) {
      return Image.file(
        File(widget.localPosterPath!),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            const PlaceholderContainer(child: AppIcon(Symbols.movie_rounded, fill: 1, size: 32)),
      );
    }

    if (widget.imageUrl != null && widget.imageUrl!.isNotEmpty) {
      return Image.network(
        widget.imageUrl!,
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
