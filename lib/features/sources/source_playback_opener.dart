import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/debug/app_debug_log.dart';
import '../../core/storage/storage_headroom.dart';
import '../../models/app_media.dart';
import '../../download/download_manager.dart';
import '../../player/internal_player.dart';
import '../../player/telegram_range_playback.dart';
import '../../providers.dart';

bool sourceChatFileMayBeDownloadable(AppMediaFile file) {
  if ((file.locatorRemoteFileId ?? '').trim().isNotEmpty) return true;
  final t = (file.locatorType ?? '').trim();
  if (t == 'CHAT_MESSAGE' &&
      file.locatorChatId != null &&
      file.locatorMessageId != null) {
    return true;
  }
  if (t == 'BOT_PRIVATE_RUNTIME' &&
      (file.locatorBotUsername ?? '').trim().isNotEmpty) {
    return true;
  }
  return (file.telegramFileId ?? '').trim().isNotEmpty;
}

Future<Uri?> openTelegramStreamUri({
  required WidgetRef ref,
  required BuildContext context,
  required AppMedia media,
  required AppMediaFile file,
  required String downloadGlobalId,
  required String downloadTitle,
  bool isSeriesMedia = false,
}) async {
  final tdlib = ref.read(tdlibFacadeProvider);
  final cfg = ref.read(appConfigProvider);
  final auth = ref.read(authNotifierProvider);
  final api = ref.read(oxplayerApiServiceProvider);
  final effectiveFile = file;
  return TelegramRangePlayback.instance.open(
    tdlib: tdlib,
    globalId: downloadGlobalId,
    variantId: effectiveFile.id,
    telegramFileId: effectiveFile.telegramFileId,
    sourceChatId: effectiveFile.sourceChatId,
    mediaFileId: effectiveFile.id,
    locatorType: effectiveFile.locatorType,
    locatorChatId: effectiveFile.locatorChatId,
    locatorMessageId: effectiveFile.locatorMessageId,
    locatorBotUsername: effectiveFile.locatorBotUsername,
    locatorRemoteFileId: effectiveFile.locatorRemoteFileId,
    expectedFileUniqueId: effectiveFile.fileUniqueId,
    mediaTitle: media.title,
    displayTitle: downloadTitle,
    releaseYear: media.releaseYear?.toString() ?? '',
    isSeriesMedia: isSeriesMedia,
    season: effectiveFile.season,
    episode: effectiveFile.episode,
    quality: effectiveFile.quality,
    fileSize: effectiveFile.size,
    onLocatorResolved: (resolved) async {
      final token = auth.apiAccessToken;
      final resolvedMsg = resolved.locatorMessageId;
      if (token == null ||
          token.isEmpty ||
          resolvedMsg == null ||
          resolvedMsg <= 0) {
        return;
      }
      final baseType = (effectiveFile.locatorType ?? '').trim();
      final reason = (resolved.resolutionReason ?? '').trim();
      final runtimeAllowed = <String>{
        'direct_runtime_message',
        'runtime_history_remote_match',
      };
      final chatAllowed = <String>{
        'direct_chat_message',
        'history_remote_id_match',
        'history_unique_id_match',
      };
      final isRuntimeBase = baseType == 'BOT_PRIVATE_RUNTIME';
      final allowed = isRuntimeBase ? runtimeAllowed : chatAllowed;
      if (!allowed.contains(reason)) return;
      final syncType =
          isRuntimeBase ? 'BOT_PRIVATE_RUNTIME' : (resolved.locatorType ?? 'CHAT_MESSAGE');
      final syncChatId = syncType == 'CHAT_MESSAGE' ? resolved.locatorChatId : null;
      await api.syncResolvedMediaLocator(
        config: cfg,
        accessToken: token,
        mediaFileId: effectiveFile.id,
        locatorType: syncType,
        locatorChatId: syncChatId,
        locatorMessageId: resolvedMsg,
        locatorBotUsername:
            syncType == 'BOT_PRIVATE_RUNTIME' ? effectiveFile.locatorBotUsername : null,
      );
    },
    onStatus: (message) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    },
  );
}

String? _seasonEpisodeLine(bool isSeries, AppMediaFile file) {
  if (!isSeries) return null;
  final s = (file.season ?? 1).clamp(0, 999);
  final e = (file.episode != null && file.episode! > 0)
      ? file.episode!.clamp(0, 999)
      : 0;
  return 'S${s.toString().padLeft(2, '0')}E${e.toString().padLeft(2, '0')}';
}

Future<void> runSourceChatStream({
  required WidgetRef ref,
  required BuildContext context,
  required AppMedia media,
  required AppMediaFile file,
  required String downloadGlobalId,
  required String downloadTitle,
  bool isSeriesMedia = false,
}) async {
  if (!file.canStream) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Streaming is not available for this file.'),
        ),
      );
    }
    return;
  }
  final dm = ref.read(downloadManagerProvider).valueOrNull;
  if (dm == null) return;

  final cleanupDecision = await queryStorageCleanupDecision();
  if (cleanupDecision.cleanupMode) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Low storage detected. Cleaning cache...'),
        ),
      );
    }
    final releasedStream = await TelegramRangePlayback.instance
        .releaseActiveCacheIfAny(reason: 'low_storage_stream_entry');
    final releasedDownloads = await dm.releaseInactiveTdlibCache();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Cache cleaned (stream=$releasedStream, downloads=$releasedDownloads). Continuing...',
          ),
        ),
      );
    }
    await Future<void>.delayed(kStorageCleanupPause);
  }

  if (!context.mounted) return;
  final proceed = await ensureStorageHeadroom(
    context: context,
    purpose: StorageHeadroomPurpose.stream,
    catalogFileSizeBytes: file.size,
  );
  if (!proceed || !context.mounted) return;

  final cfg = ref.read(appConfigProvider);
  final auth = ref.read(authNotifierProvider);
  Uri? url;
  try {
    url = await openTelegramStreamUri(
      ref: ref,
      context: context,
      media: media,
      file: file,
      downloadGlobalId: downloadGlobalId,
      downloadTitle: downloadTitle,
      isSeriesMedia: isSeriesMedia,
    );
  } catch (e, st) {
    AppDebugLog.instance.log(
      'runSourceChatStream: failed $e | $st',
      category: AppDebugLogCategory.app,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start stream: $e')),
      );
    }
    return;
  }
  if (url == null) {
    final reason = TelegramRangePlayback.instance.lastOpenFailureReason;
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            reason == null
                ? 'Unable to start stream right now.'
                : 'Unable to start stream right now ($reason).',
          ),
        ),
      );
    }
    return;
  }
  if (!context.mounted) return;

  final ok = await InternalPlayer.playHttpUrl(
    url: url.toString(),
    title: downloadTitle,
    mediaTitle: media.title,
    releaseYear: media.releaseYear,
    season: file.season,
    episode: file.episode,
    isSeries: isSeriesMedia,
    imdbId: media.imdbId,
    tmdbId: media.tmdbId,
    subdlApiKey: cfg.subdlApiKey,
    metadataSubtitle: _seasonEpisodeLine(isSeriesMedia, file),
    preferredSubtitleLanguage: auth.preferredSubtitleLanguage,
    apiAccessToken: auth.apiAccessToken,
    apiBaseUrl: cfg.apiBaseUrl,
  );
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open internal player.')),
    );
  }
}

Future<void> runSourceChatDownload({
  required WidgetRef ref,
  required BuildContext context,
  required DownloadManager dm,
  required AppMedia media,
  required AppMediaFile file,
  required String downloadGlobalId,
  required String downloadTitle,
  bool isSeriesMedia = false,
}) async {
  if (!sourceChatFileMayBeDownloadable(file)) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This file is not downloadable yet.')),
      );
    }
    return;
  }
  final proceed = await ensureStorageHeadroom(
    context: context,
    purpose: StorageHeadroomPurpose.download,
    catalogFileSizeBytes: file.size,
  );
  if (!proceed || !context.mounted) return;
  unawaited(
    dm.startDownload(
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
      displayTitle: downloadTitle,
      releaseYear: media.releaseYear?.toString() ?? '',
      isSeriesMedia: isSeriesMedia,
      season: file.season,
      episode: file.episode,
      quality: file.quality,
      fileSize: file.size,
      onStatus: (message) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      },
    ),
  );
}

Future<void> playSourceChatLocalFile({
  required WidgetRef ref,
  required BuildContext context,
  required AppMedia media,
  required AppMediaFile file,
  required String downloadTitle,
  required String localFilePath,
  bool isSeriesMedia = false,
}) async {
  final cfg = ref.read(appConfigProvider);
  final auth = ref.read(authNotifierProvider);
  final ok = await InternalPlayer.playLocalFile(
    path: localFilePath,
    title: downloadTitle,
    mediaTitle: media.title,
    releaseYear: media.releaseYear,
    season: file.season,
    episode: file.episode,
    isSeries: isSeriesMedia,
    imdbId: media.imdbId,
    tmdbId: media.tmdbId,
    subdlApiKey: cfg.subdlApiKey,
    metadataSubtitle: _seasonEpisodeLine(isSeriesMedia, file),
    preferredSubtitleLanguage: auth.preferredSubtitleLanguage,
    apiAccessToken: auth.apiAccessToken,
    apiBaseUrl: cfg.apiBaseUrl,
  );
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open internal player.')),
    );
  }
}

