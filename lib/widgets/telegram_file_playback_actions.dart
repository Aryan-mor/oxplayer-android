import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/oxplayer_button.dart';
import '../data/models/app_media.dart';
import '../download/download_manager.dart';
import '../features/sources/source_playback_opener.dart';
import '../providers.dart';

/// Playback row for Telegram-sourced files (e.g. source chat grid overlay).
/// Mirrors the detail screen variant actions for stream / download / play.
class TelegramFilePlaybackActions extends ConsumerStatefulWidget {
  const TelegramFilePlaybackActions({
    super.key,
    required this.media,
    required this.file,
    required this.downloadGlobalId,
    required this.downloadTitle,
    this.isSeriesMedia = false,
  });

  final AppMedia media;
  final AppMediaFile file;
  final String downloadGlobalId;
  final String downloadTitle;
  final bool isSeriesMedia;

  @override
  ConsumerState<TelegramFilePlaybackActions> createState() =>
      _TelegramFilePlaybackActionsState();
}

class _TelegramFilePlaybackActionsState
    extends ConsumerState<TelegramFilePlaybackActions> {
  bool _startingStream = false;

  Widget _btn({
    required VoidCallback? onPressed,
    required Widget child,
    bool enabled = true,
  }) {
    return OxplayerButton(
      enabled: enabled,
      onPressed: onPressed,
      child: child,
    );
  }

  Future<void> _onStream() async {
    if (_startingStream) return;
    setState(() => _startingStream = true);
    try {
      await runSourceChatStream(
        ref: ref,
        context: context,
        media: widget.media,
        file: widget.file,
        downloadGlobalId: widget.downloadGlobalId,
        downloadTitle: widget.downloadTitle,
        isSeriesMedia: widget.isSeriesMedia,
      );
    } finally {
      if (mounted) setState(() => _startingStream = false);
    }
  }

  Future<void> _onDownload(DownloadManager dm) async {
    await runSourceChatDownload(
      ref: ref,
      context: context,
      dm: dm,
      media: widget.media,
      file: widget.file,
      downloadGlobalId: widget.downloadGlobalId,
      downloadTitle: widget.downloadTitle,
      isSeriesMedia: widget.isSeriesMedia,
    );
  }

  Future<void> _onPlayLocal(String path) async {
    await playSourceChatLocalFile(
      ref: ref,
      context: context,
      media: widget.media,
      file: widget.file,
      downloadTitle: widget.downloadTitle,
      localFilePath: path,
      isSeriesMedia: widget.isSeriesMedia,
    );
  }

  @override
  Widget build(BuildContext context) {
    final dm = ref.watch(downloadManagerProvider).valueOrNull;
    if (dm == null) {
      return const SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    final state = dm.stateFor(widget.downloadGlobalId);
    final f = widget.file;

    return switch (state) {
      DownloadIdle() => Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            if (f.canStream)
              _btn(
                enabled: !_startingStream,
                onPressed: _startingStream ? null : () => unawaited(_onStream()),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: _startingStream
                      ? const CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.highlight,
                        )
                      : const Icon(
                          Icons.wifi_tethering,
                          color: AppColors.highlight,
                          size: 24,
                        ),
                ),
              ),
            _btn(
              onPressed: () => unawaited(_onDownload(dm)),
              child: const Icon(Icons.download, color: Colors.white),
            ),
          ],
        ),
      Downloading(:final percent) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$percent%', style: const TextStyle(color: AppColors.highlight)),
            const SizedBox(width: 8),
            if (f.canStream)
              _btn(
                enabled: !_startingStream,
                onPressed: _startingStream ? null : () => unawaited(_onStream()),
                child: const Icon(Icons.wifi_tethering, color: AppColors.highlight),
              ),
            const SizedBox(width: 6),
            _btn(
              onPressed: () => dm.pauseDownload(widget.downloadGlobalId),
              child: const Icon(Icons.pause, color: Colors.white),
            ),
          ],
        ),
      DownloadPaused(:final percent) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$percent%', style: const TextStyle(color: AppColors.textMuted)),
            const SizedBox(width: 8),
            if (f.canStream)
              _btn(
                onPressed: () => unawaited(_onStream()),
                child: const Icon(Icons.wifi_tethering, color: AppColors.highlight),
              ),
            const SizedBox(width: 6),
            _btn(
              onPressed: () => dm.resumeDownload(widget.downloadGlobalId),
              child: const Icon(Icons.play_arrow, color: Colors.white),
            ),
          ],
        ),
      DownloadCompleted(:final localFilePath) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _btn(
              onPressed: () => unawaited(_onPlayLocal(localFilePath)),
              child: const Icon(Icons.play_arrow, color: Colors.white),
            ),
          ],
        ),
      DownloadRecovering() => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.highlight,
              ),
            ),
            if (f.canStream) ...[
              const SizedBox(width: 8),
              _btn(
                onPressed: () => unawaited(_onStream()),
                child: const Icon(Icons.wifi_tethering, color: AppColors.highlight),
              ),
            ],
          ],
        ),
      DownloadLocating() => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.highlight,
              ),
            ),
            if (f.canStream) ...[
              const SizedBox(width: 8),
              _btn(
                onPressed: () => unawaited(_onStream()),
                child: const Icon(Icons.wifi_tethering, color: AppColors.highlight),
              ),
            ],
          ],
        ),
      DownloadUnavailable() => _btn(
          onPressed: null,
          enabled: false,
          child: const Text(
            'Not available',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
        ),
      DownloadError() => _btn(
          onPressed: () => unawaited(_onDownload(dm)),
          child: const Icon(Icons.refresh, color: Colors.redAccent),
        ),
    };
  }
}
