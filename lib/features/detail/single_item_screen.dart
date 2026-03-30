import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';
import 'package:tdlib/td_api.dart' as td;

import '../../core/config/app_config.dart';
import '../../core/debug/app_debug_log.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tv_button.dart';
import '../../data/local/entities.dart';
import '../../data/local/isar_provider.dart';
import '../../download/download_manager.dart';
import '../../player/external_player.dart';
import '../../providers.dart';
import '../../telegram/tdlib_facade.dart';

// ─── Route args ──────────────────────────────────────────────────────────────

class SingleItemArgs {
  const SingleItemArgs({required this.globalId});
  final String globalId;
}

// ─── Screen ──────────────────────────────────────────────────────────────────

class SingleItemScreen extends ConsumerStatefulWidget {
  const SingleItemScreen({super.key, required this.globalId});

  final String globalId;

  @override
  ConsumerState<SingleItemScreen> createState() => _SingleItemScreenState();
}

class _SingleItemScreenState extends ConsumerState<SingleItemScreen> {
  MediaItem? _item;
  List<MediaVariant> _variants = [];
  List<MediaSeason> _seasons = [];
  List<MediaEpisode> _episodes = [];
  int _selectedSeason = 1;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    AppDebugLog.instance.log('SingleItemScreen: load start globalId=${widget.globalId}');
    final isar = await ref.read(isarProvider.future);
    
    await isar.runWithRetry(() async {
      final item = await isar.mediaItems.getByGlobalId(widget.globalId);
      final variants = await isar.mediaVariants
          .filter()
          .globalIdEqualTo(widget.globalId)
          .findAll();
      final seasons = await isar.mediaSeasons
          .filter()
          .globalIdEqualTo(widget.globalId)
          .findAll();
      seasons.sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));

      List<MediaEpisode> episodes = [];
      if (seasons.isNotEmpty) {
        final seasonKey = seasons.first.seasonKey;
        episodes = await isar.mediaEpisodes
            .filter()
            .seasonKeyEqualTo(seasonKey)
            .findAll();
        episodes.sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
      }

      var effectiveVariants = variants;
      if (item != null && effectiveVariants.isEmpty) {
        effectiveVariants = await _recoverVariantsFromTelegramIfMissing(
          tdlib: ref.read(tdlibFacadeProvider),
          config: ref.read(appConfigProvider),
          globalId: widget.globalId,
        );
      }

      // Ensure DownloadManager is ready, then reconcile persisted file state.
      final dm = await ref.read(downloadManagerProvider.future);
      final existingPath = await dm.checkExistingFile(widget.globalId);
      final state = dm.stateFor(widget.globalId);

      final downloadRows = await isar.mediaDownloads
          .filter()
          .globalIdEqualTo(widget.globalId)
          .findAll();
      final completedPaths = <String>[];
      for (final row in downloadRows.where((r) => r.status == 'completed')) {
        final p = row.localFilePath;
        if (p == null || p.isEmpty) continue;
        final exists = await File(p).exists();
        completedPaths.add('$p (exists=$exists)');
      }

      final firstVariant =
          effectiveVariants.isNotEmpty ? effectiveVariants.first : null;
      AppDebugLog.instance.log(
        'SingleItemScreen: load result '
        'itemFound=${item != null} '
        'variants=${effectiveVariants.length} '
        'seasons=${seasons.length} '
        'episodes=${episodes.length} '
        'dmState=${state.runtimeType} '
        'existingPath=${existingPath ?? "null"} '
        'downloadRows=${downloadRows.length}',
      );
      if (firstVariant != null) {
        AppDebugLog.instance.log(
          'SingleItemScreen: firstVariant '
          'variantId=${firstVariant.variantId} '
          'chatId=${firstVariant.chatId} '
          'msgId=${firstVariant.msgId} '
          'fileSize=${firstVariant.fileSize} '
          'fileName=${firstVariant.fileName}',
        );
      } else {
        AppDebugLog.instance.log(
          'SingleItemScreen: no variants for globalId=${widget.globalId}',
        );
      }
      if (completedPaths.isNotEmpty) {
        AppDebugLog.instance.log(
          'SingleItemScreen: completed paths ${completedPaths.join(" | ")}',
        );
      }

      if (mounted) {
        setState(() {
          _item = item;
          _variants = effectiveVariants;
          _seasons = seasons;
          _episodes = episodes;
          _selectedSeason = seasons.isNotEmpty ? seasons.first.seasonNumber : 1;
          _loading = false;
        });
      }
    }, debugName: 'SingleItemScreen:load');
  }

  Future<List<MediaVariant>> _recoverVariantsFromTelegramIfMissing({
    required TdlibFacade tdlib,
    required AppConfig config,
    required String globalId,
  }) async {
    AppDebugLog.instance.log(
      'SingleItemScreen: recover variants start globalId=$globalId',
    );

    await tdlib.ensureAuthorized();
    final resolved = await tdlib.send(td.SearchPublicChat(username: config.botUsername));
    if (resolved is! td.Chat || resolved.type is! td.ChatTypePrivate) {
      AppDebugLog.instance.log(
        'SingleItemScreen: recover variants failed to resolve bot chat',
      );
      return const <MediaVariant>[];
    }

    final botUserId = (resolved.type as td.ChatTypePrivate).userId;
    final chatIds = <int>{};
    final privateChat = await tdlib.send(
      td.CreatePrivateChat(userId: botUserId, force: false),
    );
    if (privateChat is td.Chat) {
      chatIds.add(privateChat.id);
    }
    final groups = await tdlib.send(
      td.GetGroupsInCommon(userId: botUserId, offsetChatId: 0, limit: 100),
    );
    if (groups is td.Chats) {
      chatIds.addAll(groups.chatIds);
    }

    final variants = <MediaVariant>[];
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final chatId in chatIds) {
      var fromMessageId = 0;
      var hasMore = true;
      while (hasMore) {
        final batch = await tdlib.send(
          td.SearchChatMessages(
            chatId: chatId,
            query: config.indexTag,
            senderId: null,
            filter: null,
            messageThreadId: 0,
            fromMessageId: fromMessageId,
            offset: 0,
            limit: 100,
          ),
        );

        List<td.Message> messages = const <td.Message>[];
        if (batch is td.FoundChatMessages) {
          messages = batch.messages;
          fromMessageId = batch.nextFromMessageId;
          hasMore = fromMessageId != 0 && messages.isNotEmpty;
        } else if (batch is td.Messages) {
          messages = batch.messages;
          if (messages.isNotEmpty) {
            fromMessageId = messages.last.id;
          }
          hasMore = messages.isNotEmpty;
        } else {
          hasMore = false;
        }

        for (final msg in messages) {
          final resolvedMessage = await _resolveMediaMessageForIndex(tdlib, msg, chatId);
          if (resolvedMessage == null) continue;
          final mediaMessage = resolvedMessage.$1;
          final sourceMessageId = resolvedMessage.$2;
          final text = _extractMessageText(msg);
          final mediaFileId = _extractMediaFileId(text);
          if (mediaFileId != globalId) continue;

          final variantId = '$globalId:$chatId:$sourceMessageId';
          final variant = MediaVariant()
            ..variantId = variantId
            ..globalId = globalId
            ..msgId = sourceMessageId
            ..chatId = chatId
            ..sourceScope = 'telegram'
            ..fileName = _extractMediaFileName(mediaMessage)
            ..mimeType = _extractMediaMimeType(mediaMessage)
            ..fileSize = _extractMediaSize(mediaMessage)
            ..durationSec = _extractMediaDuration(mediaMessage)
            ..qualityLabel = null
            ..bitrateEstimate = null
            ..streamSupported = false
            ..isPremiumNeeded = false
            ..fileReferenceJson = null
            ..createdAt = now;
          variants.add(variant);
        }
      }
    }

    if (variants.isNotEmpty) {
      final isar = await ref.read(isarProvider.future);
      await isar.runWithRetry(
        () => isar.writeTxn(() async {
          for (final variant in variants) {
            await isar.mediaVariants.put(variant);
          }
        }),
        debugName: 'recoverVariantsFromTelegram',
      );
    }

    AppDebugLog.instance.log(
      'SingleItemScreen: recover variants done globalId=$globalId found=${variants.length}',
    );
    return variants;
  }

  String _extractMessageText(td.Message msg) {
    final content = msg.content;
    if (content is td.MessageVideo) return content.caption.text;
    if (content is td.MessageDocument) return content.caption.text;
    if (content is td.MessageText) return content.text.text;
    return '';
  }

  String? _extractMediaFileId(String text) {
    final pattern = RegExp(
      r'MediaFileID:\s*(?:<code>)?([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12})',
      caseSensitive: false,
    );
    return pattern.firstMatch(text)?.group(1);
  }

  Future<(td.Message, int)?> _resolveMediaMessageForIndex(
    TdlibFacade tdlib,
    td.Message msg,
    int chatId,
  ) async {
    if (msg.content is td.MessageVideo || msg.content is td.MessageDocument) {
      return (msg, msg.id);
    }
    if (msg.content is! td.MessageText) return null;
    if (msg.replyTo is! td.MessageReplyToMessage) return null;
    final replyToId = (msg.replyTo as td.MessageReplyToMessage).messageId;
    final replied = await tdlib.send(td.GetMessage(chatId: chatId, messageId: replyToId));
    if (replied is! td.Message) return null;
    if (replied.content is td.MessageVideo || replied.content is td.MessageDocument) {
      return (replied, replied.id);
    }
    return null;
  }

  String? _extractMediaFileName(td.Message msg) {
    final content = msg.content;
    if (content is td.MessageVideo) return content.video.fileName;
    if (content is td.MessageDocument) return content.document.fileName;
    return null;
  }

  String? _extractMediaMimeType(td.Message msg) {
    final content = msg.content;
    if (content is td.MessageVideo) return content.video.mimeType;
    if (content is td.MessageDocument) return content.document.mimeType;
    return null;
  }

  int? _extractMediaSize(td.Message msg) {
    final content = msg.content;
    if (content is td.MessageVideo) return content.video.video.expectedSize;
    if (content is td.MessageDocument) return content.document.document.expectedSize;
    return null;
  }

  int? _extractMediaDuration(td.Message msg) {
    final content = msg.content;
    if (content is td.MessageVideo) return content.video.duration;
    return null;
  }

  Future<void> _loadEpisodesForSeason(int seasonNumber) async {
    final isar = await ref.read(isarProvider.future);
    final seasonKey = '${widget.globalId}:S$seasonNumber';
    
    await isar.runWithRetry(() async {
      final episodes = await isar.mediaEpisodes
          .filter()
          .seasonKeyEqualTo(seasonKey)
          .findAll();
      episodes.sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));

      if (mounted) {
        setState(() {
          _selectedSeason = seasonNumber;
          _episodes = episodes;
        });
      }
    }, debugName: 'SingleItemScreen:loadEpisodes');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final item = _item;
    if (item == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Not Found')),
        body: const Center(child: Text('Media item not found in local index.')),
      );
    }

    final isSeries = item.mediaType == '#series';

    return Scaffold(
      body: Stack(
        children: [
          // ── Blurred backdrop ─────────────────────────────────────────────
          if (item.backdropUrl != null && item.backdropUrl!.isNotEmpty)
            Positioned.fill(
              child: ColorFiltered(
                colorFilter: ColorFilter.mode(
                  Colors.black.withOpacity(0.72),
                  BlendMode.darken,
                ),
                child: CachedNetworkImage(
                  imageUrl: item.backdropUrl!,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => const SizedBox(),
                ),
              ),
            ),
          // ── Content ──────────────────────────────────────────────────────
          SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PosterPanel(
                  item: item,
                  variants: _variants,
                  globalId: widget.globalId,
                  onDelete: _load,
                ),
                Expanded(
                  child: isSeries
                      ? _SeriesPanel(
                          item: item,
                          seasons: _seasons,
                          episodes: _episodes,
                          selectedSeason: _selectedSeason,
                          onSeasonSelected: _loadEpisodesForSeason,
                        )
                      : _MovieMetaPanel(item: item),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PosterPanel extends ConsumerWidget {
  const _PosterPanel({
    required this.item,
    required this.variants,
    required this.globalId,
    required this.onDelete,
  });

  final MediaItem item;
  final List<MediaVariant> variants;
  final String globalId;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dmAsync = ref.watch(downloadManagerProvider);
    final dm = dmAsync.value;
    final state = dm?.stateFor(globalId) ?? const DownloadIdle();

    return Container(
      width: 300,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TVButton(
            onPressed: () => Navigator.of(context).pop(),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.arrow_back, size: 18, color: Colors.white),
                SizedBox(width: 6),
                Text('Back', style: TextStyle(color: Colors.white)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: AspectRatio(
              aspectRatio: 2 / 3,
              child: (item.posterUrl != null && item.posterUrl!.isNotEmpty)
                  ? CachedNetworkImage(
                      imageUrl: item.posterUrl!,
                      fit: BoxFit.cover,
                      placeholder: (_, __) =>
                          const Center(child: CircularProgressIndicator()),
                      errorWidget: (_, __, ___) => Container(
                        color: AppColors.card,
                        child: const Icon(Icons.movie, size: 60),
                      ),
                    )
                  : Container(
                      color: AppColors.card,
                      child: const Icon(Icons.movie, size: 60),
                    ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            item.title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          if (item.genres.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: item.genres
                  .take(3)
                  .map((g) => _GenreChip(label: g))
                  .toList(),
            ),
          const SizedBox(height: 16),
          if (dm == null)
            const CircularProgressIndicator(strokeWidth: 2)
          else
            _DownloadPlayButton(
              globalId: globalId,
              state: state,
              item: item,
              variants: variants,
              dm: dm,
            ),
          const SizedBox(height: 10),
          if (dm != null && state is DownloadCompleted)
            TVButton(
              onPressed: () async {
                await dm.deleteDownload(globalId);
                onDelete();
              },
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                  SizedBox(width: 8),
                  Text('Delete', style: TextStyle(color: Colors.redAccent)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DownloadPlayButton extends StatelessWidget {
  const _DownloadPlayButton({
    required this.globalId,
    required this.state,
    required this.item,
    required this.variants,
    required this.dm,
  });

  final String globalId;
  final DownloadState state;
  final MediaItem item;
  final List<MediaVariant> variants;
  final DownloadManager dm;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      DownloadIdle() => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TVButton(
              autofocus: false,
              onPressed: () => _startDownload(context),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.download, color: Colors.white),
                  SizedBox(width: 8),
                  Text('Download', style: TextStyle(color: Colors.white)),
                ],
              ),
            ),
            if (_bestVariantSizeLabel() != null) ...[
              const SizedBox(width: 10),
              Text(
                _bestVariantSizeLabel()!,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      Downloading(
        :final bytesDownloaded,
        :final totalBytes,
        :final progress,
        :final percent
      ) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Downloading… $percent%',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: AppColors.border,
                color: AppColors.highlight,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${_formatBytes(bytesDownloaded)} / ${totalBytes != null ? _formatBytes(totalBytes) : '?'}',
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const TVButton(
                  enabled: false,
                  onPressed: null,
                  padding:
                      EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.download, color: AppColors.textMuted),
                      SizedBox(width: 6),
                      Text(
                        'Downloading',
                        style: TextStyle(color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TVButton(
                  onPressed: () => dm.pauseDownload(globalId),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.pause, color: Colors.white),
                      SizedBox(width: 6),
                      Text('Pause', style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      DownloadPaused(
        :final bytesDownloaded,
        :final totalBytes,
        :final percent
      ) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Paused at $percent%',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              '${_formatBytes(bytesDownloaded)} / ${totalBytes != null ? _formatBytes(totalBytes) : '?'}',
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 8),
            TVButton(
              onPressed: () => dm.resumeDownload(globalId),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.play_arrow, color: Colors.white),
                  SizedBox(width: 8),
                  Text('Resume', style: TextStyle(color: Colors.white)),
                ],
              ),
            ),
          ],
        ),
      DownloadCompleted(:final localFilePath) => TVButton(
          autofocus: true,
          onPressed: () => _play(context, localFilePath),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.play_arrow, color: Colors.white),
              SizedBox(width: 8),
              Text('Play', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      DownloadError(:final message) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
                SizedBox(width: 6),
                Text('Download failed',
                    style: TextStyle(color: Colors.redAccent)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              message,
              style:
                  const TextStyle(color: AppColors.textMuted, fontSize: 11),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            TVButton(
              onPressed: () => _startDownload(context),
              child: const Text('Retry',
                  style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
    };
  }

  void _startDownload(BuildContext context) {
    final best = _bestVariant();
    if (best == null) {
      AppDebugLog.instance.log(
        'SingleItemScreen: startDownload blocked, no variant for globalId=$globalId',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No downloadable variant found.')),
      );
      return;
    }
    final isSeries = item.mediaType == '#series';
    final year = isSeries ? '' : (_extractYearFromTags(item.tags) ?? '');
    final seriesStem = _seriesStemFromSources(
      tags: item.tags,
      fallbackTitle: item.title,
      variantFileName: best.fileName,
    );
    final downloadTitle = isSeries ? seriesStem : item.title;

    dm.startDownload(
      globalId: globalId,
      variantId: best.variantId,
      msgId: best.msgId,
      chatId: best.chatId,
      title: downloadTitle,
      year: year,
      mimeType: best.mimeType,
      fileSize: best.fileSize,
    );
    AppDebugLog.instance.log(
      'SingleItemScreen: startDownload requested '
      'globalId=$globalId variantId=${best.variantId} '
      'chatId=${best.chatId} msgId=${best.msgId}',
    );
  }

  MediaVariant? _bestVariant() => variants.isNotEmpty ? variants.first : null;

  String? _bestVariantSizeLabel() {
    final bytes = _bestVariant()?.fileSize;
    if (bytes == null || bytes <= 0) return null;
    return _formatBytes(bytes);
  }

  Future<void> _play(BuildContext context, String path) async {
    AppDebugLog.instance.log('SingleItemScreen: launching external player for $path');
    final launched = await ExternalPlayer.launchVideo(
      path: path,
      title: _formatMovieIntentTitle(
        item.title,
        _extractYearFromTags(item.tags),
      ),
    );
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No player found.',
          ),
        ),
      );
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _formatMovieIntentTitle(String rawTitle, String? explicitYear) {
    final normalized = rawTitle.trim();
    final name = normalized;
    final year = (explicitYear ?? '').trim();
    if (year.isEmpty) return name;
    return '$name ($year)';
  }

  static String? _extractYearFromTags(List<String> tags) {
    for (final tag in tags) {
      final match = RegExp(r'^#Y(\d{4})$', caseSensitive: false).firstMatch(tag);
      if (match != null) return match.group(1);
    }
    return null;
  }

  static String _seriesStemFromSources({
    required List<String> tags,
    required String fallbackTitle,
    required String? variantFileName,
  }) {
    int? season;
    int? episode;
    for (final tag in tags) {
      final s = RegExp(r'^#season_(\d+)$', caseSensitive: false).firstMatch(tag);
      if (s != null) season = int.tryParse(s.group(1) ?? '');
      final e = RegExp(r'^#episode_(\d+)$', caseSensitive: false).firstMatch(tag);
      if (e != null) episode = int.tryParse(e.group(1) ?? '');
    }

    if ((season == null || episode == null) &&
        variantFileName != null &&
        variantFileName.isNotEmpty) {
      final m = RegExp(r'[sS](\d{1,2})[eE](\d{1,2})').firstMatch(variantFileName);
      if (m != null) {
        season ??= int.tryParse(m.group(1) ?? '');
        episode ??= int.tryParse(m.group(2) ?? '');
      }
    }

    if (season == null || episode == null) return fallbackTitle;
    final s2 = season.toString().padLeft(2, '0');
    final e2 = episode.toString().padLeft(2, '0');
    return '$fallbackTitle - S$s2'
        'E$e2';
  }
}

class _MovieMetaPanel extends StatelessWidget {
  const _MovieMetaPanel({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Details',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          if (item.imdbId.isNotEmpty) _MetaRow('IMDb', item.imdbId),
          if (item.tmdbId != null) _MetaRow('TMDB', item.tmdbId!),
          if (item.tags.isNotEmpty)
            _MetaRow('Tags', item.tags.take(8).join('  ')),
        ],
      ),
    );
  }
}

class _SeriesPanel extends StatelessWidget {
  const _SeriesPanel({
    required this.item,
    required this.seasons,
    required this.episodes,
    required this.selectedSeason,
    required this.onSeasonSelected,
  });

  final MediaItem item;
  final List<MediaSeason> seasons;
  final List<MediaEpisode> episodes;
  final int selectedSeason;
  final void Function(int) onSeasonSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (seasons.length > 1) ...[
          const Padding(
            padding:
                EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: Text(
              'Seasons',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textMuted,
                letterSpacing: 1.1,
              ),
            ),
          ),
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding:
                  const EdgeInsets.symmetric(horizontal: 24),
              itemCount: seasons.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final s = seasons[i];
                final isSelected = s.seasonNumber == selectedSeason;
                return TVButton(
                  autofocus: i == 0,
                  onPressed: () => onSeasonSelected(s.seasonNumber),
                  child: Text(
                    s.title ?? 'Season ${s.seasonNumber}',
                    style: TextStyle(
                      color: isSelected
                          ? AppColors.highlight
                          : Colors.white,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: episodes.isEmpty
              ? const Center(
                  child: Text(
                    'No episodes indexed yet.\nTrigger a sync to populate episodes.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 300,
                    childAspectRatio: 2.6,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: episodes.length,
                  itemBuilder: (context, i) {
                    return _EpisodeCard(
                      episode: episodes[i],
                      seriesTitle: item.title,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _EpisodeCard extends ConsumerWidget {
  const _EpisodeCard({
    required this.episode,
    required this.seriesTitle,
  });

  final MediaEpisode episode;
  final String seriesTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final globalId = episode.globalId;
    final episodeGlobalId =
        '$globalId:S${episode.seasonNumber}:E${episode.episodeNumber}';
    final dm = ref.watch(downloadManagerProvider).value;
    final state = dm?.stateFor(episodeGlobalId) ?? const DownloadIdle();

    return TVButton(
      onPressed: null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Text(
              '${episode.episodeNumber}',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  episode.title ?? 'Episode ${episode.episodeNumber}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (episode.durationSec != null)
                  Text(
                    _formatDuration(episode.durationSec!),
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textMuted,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (dm != null)
            _EpisodeMiniAction(
              episodeGlobalId: episodeGlobalId,
              state: state,
              episode: episode,
              seriesTitle: seriesTitle,
              dm: dm,
            ),
        ],
      ),
    );
  }

  static String _formatDuration(int secs) {
    final m = secs ~/ 60;
    final s = secs % 60;
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }
}

class _EpisodeMiniAction extends StatelessWidget {
  const _EpisodeMiniAction({
    required this.episodeGlobalId,
    required this.state,
    required this.episode,
    required this.seriesTitle,
    required this.dm,
  });

  final String episodeGlobalId;
  final DownloadState state;
  final MediaEpisode episode;
  final String seriesTitle;
  final DownloadManager dm;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      DownloadIdle() => TVButton(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          onPressed: () => _downloadEpisode(context),
          child: const Icon(Icons.download, size: 18, color: Colors.white),
        ),
      Downloading(:final percent) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 48,
              child: Text(
                '$percent%',
                style: const TextStyle(
                  color: AppColors.highlight,
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 6),
            TVButton(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              onPressed: () => dm.pauseDownload(episodeGlobalId),
              child: const Icon(Icons.pause, size: 18, color: Colors.white),
            ),
          ],
        ),
      DownloadPaused(:final percent) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 48,
              child: Text(
                '$percent%',
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 6),
            TVButton(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              onPressed: () => dm.resumeDownload(episodeGlobalId),
              child:
                  const Icon(Icons.play_arrow, size: 18, color: Colors.white),
            ),
          ],
        ),
      DownloadCompleted(:final localFilePath) => TVButton(
          autofocus: false,
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          onPressed: () => _playEpisode(context, localFilePath),
          child: const Icon(Icons.play_arrow,
              size: 18, color: Colors.white),
        ),
      DownloadError() => TVButton(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          onPressed: () => _downloadEpisode(context),
          child:
              const Icon(Icons.refresh, size: 18, color: Colors.redAccent),
        ),
    };
  }

  void _downloadEpisode(BuildContext context) {
    final msgId = episode.msgId;
    final chatId = episode.chatId;
    final variantId = episode.variantId;
    if (msgId == null || chatId == null || variantId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Episode not yet indexed.')),
      );
      return;
    }
    dm.startDownload(
      globalId: episodeGlobalId,
      variantId: variantId,
      msgId: msgId,
      chatId: chatId,
      title: _formatSeriesIntentTitle(),
      year: '',
      fileSize: episode.fileSize,
    );
  }

  Future<void> _playEpisode(BuildContext context, String path) async {
    final launched = await ExternalPlayer.launchVideo(
      path: path,
      title: _formatSeriesIntentTitle(),
    );
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No player found.'),
        ),
      );
    }
  }

  String _formatSeriesIntentTitle() {
    final episodeTitle = episode.title ?? 'Episode ${episode.episodeNumber}';
    final season = episode.seasonNumber.toString().padLeft(2, '0');
    final ep = episode.episodeNumber.toString().padLeft(2, '0');
    return '$seriesTitle - S$season'
        'E$ep - $episodeTitle';
  }
}

class _GenreChip extends StatelessWidget {
  const _GenreChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.border,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          color: AppColors.textMuted,
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
