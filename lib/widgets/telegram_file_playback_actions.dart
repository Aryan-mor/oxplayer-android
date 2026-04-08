import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_media.dart';
import '../providers.dart';

/// Displays play/download action buttons for a Telegram media file.
///
/// Shows options to:
/// - Download the file via the download manager
/// - Stream (when a stream URL is available)
class TelegramFilePlaybackActions extends ConsumerWidget {
  const TelegramFilePlaybackActions({
    super.key,
    required this.media,
    required this.file,
    required this.downloadGlobalId,
    required this.downloadTitle,
  });

  final AppMedia media;
  final AppMediaFile file;
  final String downloadGlobalId;
  final String downloadTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: () => _startDownload(context, ref),
          icon: const Icon(Icons.download_rounded),
          label: const Text('Download'),
        ),
        if (file.canStream) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _showStreamingSoon(context),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Stream'),
          ),
        ],
        const SizedBox(height: 8),
        _buildFileInfo(context),
      ],
    );
  }

  Widget _buildFileInfo(BuildContext context) {
    final parts = <String>[];
    if (file.quality != null) parts.add(file.quality!);
    if (file.language != null) parts.add(file.language!);
    if (file.size != null) parts.add(_formatSize(file.size!));
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join(' · '),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
      ),
      textAlign: TextAlign.center,
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _startDownload(BuildContext context, WidgetRef ref) async {
    final dm = ref.read(downloadManagerProvider).valueOrNull;
    if (dm == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Download manager not ready')),
        );
      }
      return;
    }
    try {
      await dm.startDownload(
        globalId: downloadGlobalId,
        variantId: file.id,
        telegramFileId: file.telegramFileId,
        sourceChatId: file.sourceChatId,
        mediaFileId: file.id,
        locatorType: file.locatorType,
        locatorChatId: file.locatorChatId,
        locatorMessageId: file.locatorMessageId,
        locatorBotUsername: file.locatorBotUsername,
        locatorRemoteFileId: file.locatorRemoteFileId,
        expectedFileUniqueId: file.fileUniqueId,
        mediaTitle: media.title,
        displayTitle: media.title,
        releaseYear: media.releaseYear?.toString() ?? '',
        quality: file.quality,
        fileSize: file.size,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Downloading "${media.title}"')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start download: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showStreamingSoon(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Streaming coming soon')),
    );
  }
}
