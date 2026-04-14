import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';

/// Download lifecycle for a single Telegram video card (grid + detail share this).
enum TelegramVideoDlPhase { idle, downloading, paused, completed }

class TelegramVideoItemUiState {
  TelegramVideoItemUiState({
    this.phase = TelegramVideoDlPhase.idle,
    this.progress = 0,
    this.fileId,
    this.resumeOffset = 0,
    this.localPath,
    this.cancelRequested = false,
  });

  TelegramVideoDlPhase phase;
  double progress;
  int? fileId;
  int resumeOffset;
  String? localPath;
  bool cancelRequested;
}

/// Progress / pause / play / delete controls shared by the chat grid overlay and the video detail screen.
class TelegramVideoDownloadControls extends StatelessWidget {
  const TelegramVideoDownloadControls({
    super.key,
    required this.phase,
    required this.progress,
    required this.onStopDownload,
    required this.onResumeDownload,
    required this.onDeleteDownload,
    required this.onPlayDownloaded,
    this.compact = true,
  });

  final TelegramVideoDlPhase phase;
  final double progress;
  final VoidCallback onStopDownload;
  final VoidCallback onResumeDownload;
  final VoidCallback onDeleteDownload;
  final VoidCallback onPlayDownloaded;

  /// Smaller padding and typography for the grid card overlay.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final mt = t.myTelegram;
    switch (phase) {
      case TelegramVideoDlPhase.downloading:
        return Material(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 12, vertical: compact ? 6 : 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    minHeight: compact ? 6 : 8,
                    value: (progress > 0 && progress <= 1) ? progress : null,
                  ),
                ),
                SizedBox(height: compact ? 6 : 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: onStopDownload,
                    child: Text(mt.videoStopDownload, style: const TextStyle(color: Colors.white)),
                  ),
                ),
              ],
            ),
          ),
        );
      case TelegramVideoDlPhase.paused:
        return Material(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: EdgeInsets.all(compact ? 4 : 12),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: onResumeDownload,
                    child: Text(mt.videoResumeDownload, overflow: TextOverflow.ellipsis),
                  ),
                ),
                SizedBox(width: compact ? 4 : 8),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                    onPressed: onDeleteDownload,
                    child: Text(mt.videoDeleteDownload, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
            ),
          ),
        );
      case TelegramVideoDlPhase.completed:
        return Material(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: EdgeInsets.all(compact ? 4 : 12),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: onPlayDownloaded,
                    child: Text(mt.videoPlay, overflow: TextOverflow.ellipsis),
                  ),
                ),
                SizedBox(width: compact ? 4 : 8),
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: onDeleteDownload,
                    child: Text(mt.videoDeleteDownload, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
            ),
          ),
        );
      case TelegramVideoDlPhase.idle:
        return const SizedBox.shrink();
    }
  }
}
