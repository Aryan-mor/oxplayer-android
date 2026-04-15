import 'dart:async' show unawaited;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:oxplayer/theme/mono_tokens.dart';
import 'package:oxplayer/widgets/app_icon.dart';

import '../../focus/input_mode_tracker.dart';
import '../../i18n/strings.g.dart';
import '../../infrastructure/data_repository.dart';
import '../../services/auth_debug_service.dart';
import '../../utils/snackbar_helper.dart';
import '../../utils/video_player_navigation.dart';
import '../../widgets/file_preview_card.dart';
import '../../widgets/media_thumbnail_info_overlay.dart';
import 'telegram_video_download_ui.dart';
import 'telegram_video_metadata.dart';

/// Full-screen actions for one Telegram chat video (same capabilities as the grid long-press sheet).
class MyTelegramVideoDetailScreen extends StatefulWidget {
  const MyTelegramVideoDetailScreen({
    super.key,
    required this.chatTitle,
    required this.video,
    required this.chatId,
    required this.messageId,
    required this.itemUi,
    required this.onItemUiChanged,
  });

  final String chatTitle;
  final TelegramVideoMetadata video;
  final int chatId;
  final int messageId;

  /// Shared with [MyTelegramChatMediaScreen] so grid overlays stay in sync.
  final TelegramVideoItemUiState itemUi;
  final VoidCallback onItemUiChanged;

  @override
  State<MyTelegramVideoDetailScreen> createState() => _MyTelegramVideoDetailScreenState();
}

class _MyTelegramVideoDetailScreenState extends State<MyTelegramVideoDetailScreen> {
  void _notifyParent() {
    widget.onItemUiChanged();
  }

  Future<void> _forwardToMainBot() async {
    try {
      final repo = await DataRepository.create();
      await repo.forwardTelegramMessageToMainBot(fromChatId: widget.chatId, messageId: widget.messageId);
      if (mounted) {
        showSnackBar(context, t.myTelegram.forwardToProviderSent, type: SnackBarType.success);
      }
    } catch (e) {
      if (mounted) {
        showSnackBar(context, '${t.myTelegram.forwardToProviderFailed}: $e', type: SnackBarType.error);
      }
    }
  }

  Future<void> _stream() async {
    final repo = await DataRepository.create();
    try {
      final uri = await repo.resolveTelegramChatMessageStreamUrlForPlayback(
        chatId: widget.chatId,
        messageId: widget.messageId,
      );
      if (!mounted) return;
      if (uri == null) {
        playMediaDebugError(
          'My Telegram detail stream: URL unresolved (chatId=${widget.chatId} messageId=${widget.messageId} '
          '"${widget.video.displayTitle}")',
        );
        showSnackBar(context, t.myTelegram.streamFailed, type: SnackBarType.error);
        return;
      }
      await navigateToInternalVideoPlayerForUrl(
        context,
        metadata: widget.video,
        videoUrl: uri.toString(),
      );
    } catch (e, st) {
      playMediaDebugError(
        'My Telegram detail stream: exception (chatId=${widget.chatId} messageId=${widget.messageId}): $e\n$st',
      );
      if (mounted) {
        showSnackBar(context, '${t.myTelegram.streamFailed}: $e', type: SnackBarType.error);
      }
    } finally {
      await repo.releaseOxMediaPlaybackSession(reason: 'my_telegram_detail_stream_closed');
    }
  }

  void _requestStopDownload() {
    final ui = widget.itemUi;
    if (ui.phase != TelegramVideoDlPhase.downloading) return;
    ui.cancelRequested = true;
    setState(() {});
    _notifyParent();
  }

  Future<void> _runDownload(int fileId) async {
    final ui = widget.itemUi;
    try {
      final repo = await DataRepository.create();
      final path = await repo.downloadTelegramFileToCompletion(
        fileId: fileId,
        startOffset: ui.resumeOffset,
        shouldCancel: () => widget.itemUi.cancelRequested,
        onProgress: (downloaded, total) {
          if (!mounted) return;
          setState(() {
            widget.itemUi.progress = total > 0 ? downloaded / total : 0;
          });
          _notifyParent();
        },
      );
      if (!mounted) return;
      if (path != null && path.isNotEmpty) {
        setState(() {
          widget.itemUi
            ..phase = TelegramVideoDlPhase.completed
            ..localPath = path
            ..cancelRequested = false;
        });
        _notifyParent();
        return;
      }
      if (widget.itemUi.cancelRequested) {
        final prog = await repo.getTelegramFileProgress(fileId);
        setState(() {
          widget.itemUi.phase = TelegramVideoDlPhase.paused;
          widget.itemUi.cancelRequested = false;
          if (prog != null) {
            widget.itemUi.resumeOffset = prog.$1;
          }
        });
        _notifyParent();
        return;
      }
      setState(() {
        widget.itemUi.phase = TelegramVideoDlPhase.idle;
      });
      _notifyParent();
      showSnackBar(context, t.myTelegram.downloadFailed, type: SnackBarType.error);
    } catch (e) {
      if (mounted) {
        setState(() {
          widget.itemUi.phase = TelegramVideoDlPhase.idle;
        });
        _notifyParent();
        showSnackBar(context, '${t.myTelegram.downloadFailed}: $e', type: SnackBarType.error);
      }
    }
  }

  Future<void> _resumeDownload() async {
    final fid = widget.itemUi.fileId;
    if (fid == null) return;
    widget.itemUi
      ..phase = TelegramVideoDlPhase.downloading
      ..cancelRequested = false;
    setState(() {});
    _notifyParent();
    unawaited(_runDownload(fid));
  }

  Future<void> _playDownloadedFile() async {
    final path = widget.itemUi.localPath;
    if (path == null || path.isEmpty) return;
    await navigateToInternalVideoPlayerForUrl(context, metadata: widget.video, videoUrl: path);
  }

  void _deleteDownload() {
    final path = widget.itemUi.localPath;
    if (path != null && path.isNotEmpty) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    setState(() {
      widget.itemUi
        ..phase = TelegramVideoDlPhase.idle
        ..fileId = null
        ..resumeOffset = 0
        ..localPath = null
        ..progress = 0
        ..cancelRequested = false;
    });
    _notifyParent();
  }

  @override
  Widget build(BuildContext context) {
    final mt = t.myTelegram;
    final v = widget.video;
    final fileTechSummary = videoFileTechnicalSummary(v);
    final thumb = v.thumb;
    final ui = widget.itemUi;
    final isKeyboardMode = InputModeTracker.isKeyboardMode(context);
    final colorScheme = Theme.of(context).colorScheme;
    final focusBg = colorScheme.inverseSurface;
    final focusFg = colorScheme.onInverseSurface;
    final tonalBg = colorScheme.secondaryContainer;
    final tonalFg = colorScheme.onSecondaryContainer;
    final noOverlay = WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused)) return Colors.transparent;
      return null;
    });

    ButtonStyle actionIconButtonStyle({Color? foregroundColor}) {
      if (!isKeyboardMode) {
        return IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          maximumSize: const Size(48, 48),
          foregroundColor: foregroundColor,
        );
      }
      return ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
        maximumSize: const WidgetStatePropertyAll(Size(48, 48)),
        overlayColor: noOverlay,
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) return focusBg;
          return tonalBg;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) return focusFg;
          return foregroundColor ?? tonalFg;
        }),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(v.displayTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      thumb != null && thumb.isNotEmpty && File(thumb).existsSync()
                          ? Image.file(File(thumb), fit: BoxFit.cover)
                          : ColoredBox(
                              color: Theme.of(context).colorScheme.surfaceContainerHighest,
                              child: Icon(
                                Symbols.video_library_rounded,
                                size: 64,
                                color: tokens(context).textMuted,
                              ),
                            ),
                      if (fileTechSummary != null)
                        MediaThumbnailInfoOverlay(text: fileTechSummary),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (fileTechSummary != null) VideoFileTechnicalInfoLine(text: fileTechSummary),
              if (fileTechSummary != null) const SizedBox(height: 8),
              Text(
                widget.chatTitle,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: tokens(context).textMuted),
              ),
              if (v.displaySubtitle != null) ...[
                const SizedBox(height: 4),
                Text(v.displaySubtitle!, style: Theme.of(context).textTheme.bodySmall),
              ],
              if (v.summary != null && v.summary!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(v.summary!, style: Theme.of(context).textTheme.bodyMedium),
              ],
              const SizedBox(height: 20),
              FilePreviewCard(
                title: v.displayTitle,
                infoLine: fileTechSummary,
                description: v.summary,
                localPosterPath: thumb != null && thumb.isNotEmpty && File(thumb).existsSync() ? thumb : null,
                onStream: () => unawaited(_stream()),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton.filledTonal(
                    onPressed: () => unawaited(_forwardToMainBot()),
                    icon: const AppIcon(Symbols.cloud_upload_rounded, fill: 1),
                    tooltip: mt.videoActionIndex,
                    iconSize: 22,
                    style: actionIconButtonStyle(),
                  ),
                ],
              ),
              if (ui.phase != TelegramVideoDlPhase.idle) ...[
                const SizedBox(height: 16),
                TelegramVideoDownloadControls(
                  phase: ui.phase,
                  progress: ui.progress,
                  compact: false,
                  onStopDownload: _requestStopDownload,
                  onResumeDownload: () => unawaited(_resumeDownload()),
                  onDeleteDownload: _deleteDownload,
                  onPlayDownloaded: () => unawaited(_playDownloadedFile()),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
