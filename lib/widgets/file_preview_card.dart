import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../services/plex_client.dart';
import '../focus/focus_theme.dart';
import '../focus/focusable_wrapper.dart';
import '../models/download_models.dart';
import '../providers/download_provider.dart';
import '../theme/mono_tokens.dart';
import '../utils/platform_detector.dart';
import 'app_icon.dart';
import 'placeholder_container.dart';
import 'plex_optimized_image.dart';
import 'plex_style_download_ring_icon.dart';

/// A unified, reusable card widget that presents a single playable file variant
/// with a 16:9 thumbnail on the left, a title/badge/info/description column on
/// the right, and a compact row of icon-button actions (stream, download/pause,
/// delete/cancel, cast) whose visibility and state react to the current download
/// lifecycle via [DownloadProvider].
///
/// This widget is a direct evolution of [OxFileOptionCard] with the action
/// buttons moved inline into the right column (matching [EpisodeCard]'s layout).
class FilePreviewCard extends StatefulWidget {
  const FilePreviewCard({
    super.key,
    // Required
    required this.title,
    this.onStream,
    // Optional display
    this.badgeLabel,
    this.infoLine,
    this.description,
    this.imageUrl,
    this.localPosterPath,
    // Optional Plex client for authenticated image loading
    this.client,
    // Optional focus
    this.focusNode,
    this.autofocus = false,
    this.onNavigateUp,
    this.onNavigateDown,
    // Optional download
    this.downloadGlobalKey,
    this.onDownload,
    this.onPause,
    this.onResume,
    this.onCancelDownload,
    this.onDelete,
    this.onRetry,
    // Optional cast (reserved, always disabled)
    this.onCast,
    // Whether to show the action buttons row (stream, download, cast).
    // Set to false for header/scope cards that only need a tap-to-expand behaviour.
    this.showActions = true,
    // Optional tap callback for the card body (separate from stream action).
    // When provided, tapping the card body calls this instead of onStream.
    this.onTap,
  });

  final String title;
  final VoidCallback? onStream;

  final String? badgeLabel;
  final String? infoLine;
  final String? description;
  final String? imageUrl;
  final String? localPosterPath;

  /// Optional Plex client used to build authenticated thumbnail URLs.
  /// When provided, [imageUrl] is loaded via [PlexOptimizedImage] instead of
  /// plain [Image.network], which is required for Plex server images.
  final PlexClient? client;

  final FocusNode? focusNode;
  final bool autofocus;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateDown;

  final String? downloadGlobalKey;
  final VoidCallback? onDownload;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onCancelDownload;
  final VoidCallback? onDelete;
  final VoidCallback? onRetry;

  /// Reserved for future use; cast button is always disabled regardless of this value.
  final VoidCallback? onCast;

  /// When false, the action buttons row (stream, download, cast) is hidden.
  /// Use for header/scope cards that only need a tap-to-expand behaviour.
  final bool showActions;

  /// Optional tap callback for the card body.
  /// When provided, tapping anywhere on the card body calls this.
  /// When null, the card body has no tap action (actions are button-only).
  final VoidCallback? onTap;

  @override
  State<FilePreviewCard> createState() => _FilePreviewCardState();
}

class _FilePreviewCardState extends State<FilePreviewCard> {
  // TV D-pad focus zones for each action button
  FocusNode? _streamFocusNode;
  FocusNode? _downloadFocusNode;
  FocusNode? _deleteFocusNode;

  bool get _hasDownloadKey => widget.downloadGlobalKey != null;

  @override
  void initState() {
    super.initState();
    _createFocusNodes();
  }

  void _createFocusNodes() {
    if (widget.showActions) {
      _streamFocusNode = FocusNode(debugLabel: 'file_preview_stream');
    }
    if (_hasDownloadKey && widget.showActions) {
      _downloadFocusNode = FocusNode(debugLabel: 'file_preview_download');
      _deleteFocusNode = FocusNode(debugLabel: 'file_preview_delete');
    }
  }

  void _disposeFocusNodes() {
    _streamFocusNode?.dispose();
    _streamFocusNode = null;
    _downloadFocusNode?.dispose();
    _downloadFocusNode = null;
    _deleteFocusNode?.dispose();
    _deleteFocusNode = null;
  }

  @override
  void didUpdateWidget(FilePreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final keyChanged = oldWidget.downloadGlobalKey != widget.downloadGlobalKey;
    final actionsChanged = oldWidget.showActions != widget.showActions;
    if (keyChanged || actionsChanged) {
      _disposeFocusNodes();
      _createFocusNodes();
    }
  }

  @override
  void dispose() {
    _disposeFocusNodes();
    super.dispose();
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
      // Use PlexOptimizedImage when a client is available (handles auth tokens + transcoding)
      if (widget.client != null) {
        return PlexOptimizedImage.thumb(
          client: widget.client,
          imagePath: widget.imageUrl,
          filterQuality: FilterQuality.medium,
          fit: BoxFit.cover,
          placeholder: (context, url) => const PlaceholderContainer(),
          errorWidget: (context, url, error) =>
              const PlaceholderContainer(child: AppIcon(Symbols.movie_rounded, fill: 1, size: 32)),
        );
      }
      return Image.network(
        widget.imageUrl!,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return const PlaceholderContainer(child: CircularProgressIndicator(strokeWidth: 2));
        },
        errorBuilder: (context, error, stackTrace) =>
            const PlaceholderContainer(child: AppIcon(Symbols.movie_rounded, fill: 1, size: 32)),
      );
    }

    return const PlaceholderContainer(child: AppIcon(Symbols.movie_rounded, fill: 1, size: 32));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isTV = PlatformDetector.isTV();

    // On TV, pressing select on the card body triggers stream (if available),
    // otherwise the expand/collapse tap. On touch, the card body has no tap
    // action — only the explicit buttons respond.
    final cardBodySelect = isTV ? (widget.onStream ?? widget.onTap) : widget.onTap;

    // On TV, RIGHT from card body moves focus to the stream button (first action).
    // Only wire this when actions are shown and a stream focus node exists.
    final cardBodyNavigateRight = (widget.showActions && _streamFocusNode != null)
        ? () => _streamFocusNode!.requestFocus()
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: FocusableWrapper(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        disableScale: true,
        descendantsAreFocusable: false,
        onNavigateUp: widget.onNavigateUp,
        onNavigateDown: widget.onNavigateDown,
        onSelect: cardBodySelect,
        onNavigateRight: cardBodyNavigateRight,
        child: InkWell(
          onTap: widget.onTap,
          hoverColor: colorScheme.surface.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(FocusTheme.defaultBorderRadius),
          child: Container(
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(FocusTheme.defaultBorderRadius),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Thumbnail section
                SizedBox(
                  width: 160,
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: const BorderRadius.all(Radius.circular(6)),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: _buildThumbnail(),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Content section
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title row (badge + title)
                      Row(
                        children: [
                          if (widget.badgeLabel != null && widget.badgeLabel!.isNotEmpty) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(
                                color: colorScheme.primaryContainer,
                                borderRadius: const BorderRadius.all(Radius.circular(3)),
                              ),
                              child: Text(
                                widget.badgeLabel!,
                                style: TextStyle(
                                  color: colorScheme.onPrimaryContainer,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: Text(
                              widget.title,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      // Optional info line
                      if (widget.infoLine != null && widget.infoLine!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          widget.infoLine!,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: tokens(context).textMuted),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      // Action buttons row (only when showActions is true)
                      if (widget.showActions) _buildActionButtons(context, isTV: isTV),
                      // Optional description
                      if (widget.description != null && widget.description!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          widget.description!,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: tokens(context).textMuted,
                                height: 1.3,
                              ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
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

  Widget _buildActionButtons(BuildContext context, {required bool isTV}) {
    if (widget.downloadGlobalKey == null) {
      return Row(
        children: [
          _buildStreamButton(context, isTV: isTV, nextFocusNode: null),
          if (!isTV) _buildCastButton(context),
        ],
      );
    }

    return Consumer<DownloadProvider>(
      builder: (context, downloadProvider, _) {
        final progress = downloadProvider.getProgress(widget.downloadGlobalKey!);
        final isQueueing = downloadProvider.isQueueing(widget.downloadGlobalKey!);
        final status = progress?.status;

        final showDeleteCancel = isQueueing ||
            status == DownloadStatus.queued ||
            status == DownloadStatus.downloading ||
            status == DownloadStatus.paused ||
            status == DownloadStatus.completed;

        final showDownload = status != DownloadStatus.completed;

        return Row(
          children: [
            _buildStreamButton(context, isTV: isTV, nextFocusNode: showDownload ? _downloadFocusNode : null),
            if (showDownload)
              _buildDownloadButton(context, progress, isQueueing, showDeleteCancel),
            if (showDeleteCancel)
              _buildDeleteCancelButton(context, progress, isQueueing),
            if (!isTV) _buildCastButton(context),
          ],
        );
      },
    );
  }

  Widget _buildStreamButton(BuildContext context, {required bool isTV, required FocusNode? nextFocusNode}) {
    final button = IconButton(
      onPressed: widget.onStream,
      icon: const AppIcon(Symbols.play_arrow_rounded, fill: 1, size: 22),
      visualDensity: VisualDensity.compact,
    );

    if (!isTV || _streamFocusNode == null) return button;

    return FocusableWrapper(
      focusNode: _streamFocusNode,
      disableScale: true,
      descendantsAreFocusable: false,
      onNavigateLeft: () => widget.focusNode?.requestFocus(),
      onNavigateRight: nextFocusNode != null ? () => nextFocusNode.requestFocus() : null,
      onSelect: widget.onStream,
      child: button,
    );
  }

  Widget _buildDownloadButton(
    BuildContext context,
    DownloadProgress? progress,
    bool isQueueing,
    bool showDeleteCancel,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    const ringDiameter = 40.0;
    const ringIconSize = 20.0;

    Widget iconWidget;
    VoidCallback? callback;

    if (isQueueing) {
      iconWidget = PlexStyleDownloadRingIcon(
        indeterminate: true,
        diameter: ringDiameter,
        strokeWidth: 2.5,
        progressColor: tokens(context).textMuted,
        centerIcon: AppIcon(
          Symbols.pause_rounded,
          fill: 1,
          size: ringIconSize,
          color: colorScheme.primary,
        ),
      );
      callback = null;
    } else if (progress == null) {
      iconWidget = AppIcon(Symbols.download_rounded, fill: 1, size: 22, color: colorScheme.primary);
      callback = widget.onDownload;
    } else {
      switch (progress.status) {
        case DownloadStatus.queued:
          iconWidget = PlexStyleDownloadRingIcon(
            indeterminate: true,
            diameter: ringDiameter,
            strokeWidth: 2.5,
            progressColor: colorScheme.primary,
            centerIcon: AppIcon(
              Symbols.pause_rounded,
              fill: 1,
              size: ringIconSize,
              color: colorScheme.primary,
            ),
          );
          callback = widget.onPause;
        case DownloadStatus.downloading:
          iconWidget = PlexStyleDownloadRingIcon(
            indeterminate: false,
            determinateProgress: progress.progressPercent,
            diameter: ringDiameter,
            strokeWidth: 2.5,
            progressColor: colorScheme.primary,
            centerIcon: AppIcon(
              Symbols.pause_rounded,
              fill: 1,
              size: ringIconSize,
              color: colorScheme.primary,
            ),
          );
          callback = widget.onPause;
        case DownloadStatus.paused:
          iconWidget = PlexStyleDownloadRingIcon(
            indeterminate: false,
            determinateProgress: progress.progressPercent,
            diameter: ringDiameter,
            strokeWidth: 2.5,
            progressColor: colorScheme.primary,
            centerIcon: AppIcon(
              Symbols.play_arrow_rounded,
              fill: 1,
              size: ringIconSize,
              color: colorScheme.primary,
            ),
          );
          callback = widget.onResume;
        case DownloadStatus.failed:
          iconWidget = AppIcon(Symbols.download_rounded, fill: 1, size: 22, color: colorScheme.error);
          callback = widget.onRetry;
        case DownloadStatus.cancelled:
        case DownloadStatus.partial:
          iconWidget = AppIcon(Symbols.download_rounded, fill: 1, size: 22, color: colorScheme.primary);
          callback = widget.onDownload;
        default:
          // completed — should not reach here since showDownload is false
          iconWidget = AppIcon(Symbols.download_rounded, fill: 1, size: 22, color: colorScheme.primary);
          callback = widget.onDownload;
      }
    }

    return FocusableWrapper(
      focusNode: _downloadFocusNode,
      disableScale: true,
      descendantsAreFocusable: false,
      onNavigateLeft: () => (_streamFocusNode ?? widget.focusNode)?.requestFocus(),
      onNavigateDown: showDeleteCancel ? () => _deleteFocusNode?.requestFocus() : null,
      onSelect: () {
        if (callback != null) callback();
      },
      child: IconButton(
        onPressed: callback,
        icon: iconWidget,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Widget _buildDeleteCancelButton(
    BuildContext context,
    DownloadProgress? progress,
    bool isQueueing,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    Widget iconWidget;
    VoidCallback? callback;

    if (progress?.status == DownloadStatus.completed) {
      iconWidget = AppIcon(Symbols.delete_outline_rounded, fill: 1, size: 22, color: colorScheme.error);
      callback = widget.onDelete;
    } else {
      // isQueueing || queued || downloading || paused
      iconWidget = AppIcon(Symbols.delete_outline_rounded, fill: 1, size: 20, color: tokens(context).textMuted);
      callback = widget.onCancelDownload;
    }

    return FocusableWrapper(
      focusNode: _deleteFocusNode,
      disableScale: true,
      descendantsAreFocusable: false,
      onNavigateUp: () => _downloadFocusNode?.requestFocus(),
      onNavigateLeft: () => widget.focusNode?.requestFocus(),
      onSelect: () {
        if (callback != null) callback();
      },
      child: IconButton(
        onPressed: callback,
        icon: iconWidget,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Widget _buildCastButton(BuildContext context) {
    return IconButton(
      onPressed: null,
      icon: AppIcon(Symbols.cast_rounded, fill: 1, size: 22, color: tokens(context).textMuted),
      tooltip: 'Cast (coming soon)',
      visualDensity: VisualDensity.compact,
    );
  }
}
