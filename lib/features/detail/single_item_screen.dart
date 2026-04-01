import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/debug/app_debug_log.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tv_button.dart';
import '../../data/models/app_media.dart';
import '../../download/download_manager.dart';
import '../../player/external_player.dart';
import '../../providers.dart';

void _itemLog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.app);

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
  AppMediaAggregate? _aggregate;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    _itemLog('SingleItemScreen: load start globalId=${widget.globalId}');
    
    final allMedia = await ref.read(mediaListProvider.future);
    final totalFiles = allMedia.fold<int>(0, (sum, it) => sum + it.files.length);
    final sample = allMedia
        .take(5)
        .map((e) => '${e.media.id}:${e.files.length}')
        .join(', ');
    _itemLog(
      'SingleItemScreen: mediaList loaded items=${allMedia.length} totalFiles=$totalFiles '
      'sample(mediaId:files)=[$sample]',
    );
    
    // Find the requested media
    try {
      final item = allMedia.firstWhere((m) => m.media.id == widget.globalId);
      _itemLog(
        'SingleItemScreen: selected media id=${item.media.id} title="${item.media.title}" '
        'type=${item.media.type} files=${item.files.length}',
      );
      if (item.files.isNotEmpty) {
        final first = item.files.first;
        _itemLog(
          'SingleItemScreen: first file sample id=${first.id} '
          'season=${first.season} episode=${first.episode} quality=${first.quality} '
          'lang=${first.videoLanguage ?? first.language} size=${first.size} '
          'hasTelegramFileId=${(first.telegramFileId ?? '').isNotEmpty}',
        );
      } else {
        _itemLog(
          'SingleItemScreen: selected media has zero files; likely server library shape/data issue',
        );
      }
      if (mounted) {
        setState(() {
          _aggregate = item;
          _loading = false;
        });
      }
    } catch (e) {
      _itemLog(
        'SingleItemScreen: target media not found for globalId=${widget.globalId} error=$e',
      );
      if (mounted) {
        setState(() {
          _aggregate = null;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final agg = _aggregate;
    if (agg == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Not Found')),
        body: const Center(child: Text('Media item not found in API.')),
      );
    }

    final item = agg.media;
    final isSeries = item.type == 'SERIES' || item.type == '#series';

    // Simple backdrop resolution wrapper to preserve API layout
    String? resolvePosterUrl(String? posterPath) {
      final value = (posterPath ?? '').trim();
      if (value.isEmpty) return null;
      if (value.startsWith('http://') || value.startsWith('https://')) return value;
      if (value.startsWith('/')) return 'https://image.tmdb.org/t/p/w500$value';
      return value;
    }

    String? backdropUrl; // Use default dark placeholder or standard empty for now
    if (item.posterPath != null) {
      backdropUrl = resolvePosterUrl(item.posterPath); // Placeholder as there's only posterPath
    }

    return Scaffold(
      body: Stack(
        children: [
          // ── Blurred backdrop ─────────────────────────────────────────────
          if (backdropUrl != null)
            Positioned.fill(
              child: ColorFiltered(
                colorFilter: ColorFilter.mode(
                  Colors.black.withValues(alpha: 0.72),
                  BlendMode.darken,
                ),
                child: CachedNetworkImage(
                  imageUrl: backdropUrl,
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
                  aggregate: agg,
                  onDelete: _load,
                ),
                Expanded(
                  child: _DetailsPanel(aggregate: agg, isSeries: isSeries),
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
    required this.aggregate,
    required this.onDelete,
  });

  final AppMediaAggregate aggregate;
  final VoidCallback onDelete;

  String? _resolvePosterUrl(String? posterPath) {
    final value = (posterPath ?? '').trim();
    if (value.isEmpty) return null;
    if (value.startsWith('http://') || value.startsWith('https://')) return value;
    if (value.startsWith('/')) return 'https://image.tmdb.org/t/p/w500$value';
    return value;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dmAsync = ref.watch(downloadManagerProvider);
    final item = aggregate.media;
    final dm = dmAsync.value;
    final downloadedCount = aggregate.files
        .where((f) => dm?.stateFor(f.id) is DownloadCompleted)
        .length;

    final poster = _resolvePosterUrl(item.posterPath) ?? '';

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
              child: poster.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: poster,
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
          const SizedBox(height: 10),
          Text(
            'Available files: ${aggregate.files.length}',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
          Text(
            'Downloaded: $downloadedCount',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _DetailsPanel extends StatelessWidget {
  const _DetailsPanel({required this.aggregate, required this.isSeries});

  final AppMediaAggregate aggregate;
  final bool isSeries;

  @override
  Widget build(BuildContext context) {
    final item = aggregate.media;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.title,
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              if (item.releaseYear != null) _chip('Year ${item.releaseYear}'),
              _chip(isSeries ? 'Series' : 'Movie'),
              if (item.originalLanguage != null && item.originalLanguage!.isNotEmpty)
                _chip(item.originalLanguage!.toUpperCase()),
            ],
          ),
          const SizedBox(height: 14),
          ExpansionTile(
            title: const Text('Overview', style: TextStyle(color: Colors.white)),
            collapsedIconColor: Colors.white,
            iconColor: Colors.white,
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text(
                (item.summary ?? '').trim().isEmpty
                    ? 'No description available.'
                    : item.summary!.trim(),
                style: const TextStyle(color: AppColors.textMuted, height: 1.45),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (isSeries)
            _SeriesVariantsSection(aggregate: aggregate)
          else
            _MovieVariantsSection(aggregate: aggregate),
        ],
      ),
    );
  }
}

Widget _chip(String text) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: AppColors.border),
    ),
    child: Text(text, style: const TextStyle(fontSize: 12, color: Colors.white)),
  );
}

class _MovieVariantsSection extends StatelessWidget {
  const _MovieVariantsSection({required this.aggregate});

  final AppMediaAggregate aggregate;

  @override
  Widget build(BuildContext context) {
    if (aggregate.files.isEmpty) {
      return const Text('No files indexed yet.', style: TextStyle(color: AppColors.textMuted));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Available versions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        for (final file in aggregate.files)
          _VariantRow(
            media: aggregate.media,
            file: file,
            downloadTitle: aggregate.media.title,
            downloadGlobalId: file.id,
          ),
      ],
    );
  }
}

class _SeriesVariantsSection extends StatelessWidget {
  const _SeriesVariantsSection({required this.aggregate});

  final AppMediaAggregate aggregate;

  @override
  Widget build(BuildContext context) {
    if (aggregate.files.isEmpty) {
      return const Text('No episodes indexed yet.', style: TextStyle(color: AppColors.textMuted));
    }

    final grouped = <int, Map<int, List<AppMediaFile>>>{};
    for (final file in aggregate.files) {
      final season = file.season ?? 1;
      final episode = file.episode ?? 0;
      grouped.putIfAbsent(season, () => <int, List<AppMediaFile>>{});
      grouped[season]!.putIfAbsent(episode, () => <AppMediaFile>[]);
      grouped[season]![episode]!.add(file);
    }
    final seasons = grouped.keys.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Seasons', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        for (final season in seasons)
          ExpansionTile(
            title: Text('Season $season', style: const TextStyle(color: Colors.white)),
            collapsedIconColor: Colors.white,
            iconColor: Colors.white,
            childrenPadding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
            children: [
              ...(() {
                final byEpisode = grouped[season]!;
                final episodeNumbers = byEpisode.keys.toList()..sort();
                return episodeNumbers.map((ep) {
                  final variants = byEpisode[ep]!;
                  return ExpansionTile(
                    title: Text('Episode ${ep <= 0 ? '?' : ep}', style: const TextStyle(color: Colors.white)),
                    collapsedIconColor: Colors.white70,
                    iconColor: Colors.white70,
                    childrenPadding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
                    children: [
                      for (final file in variants)
                        _VariantRow(
                          media: aggregate.media,
                          file: file,
                          downloadTitle:
                              '${aggregate.media.title} - S${season.toString().padLeft(2, '0')}E${(ep <= 0 ? 0 : ep).toString().padLeft(2, '0')}',
                          downloadGlobalId: file.id,
                        ),
                    ],
                  );
                });
              })(),
            ],
          ),
      ],
    );
  }
}

class _VariantRow extends ConsumerWidget {
  const _VariantRow({
    required this.media,
    required this.file,
    required this.downloadTitle,
    required this.downloadGlobalId,
  });

  final AppMedia media;
  final AppMediaFile file;
  final String downloadTitle;
  final String downloadGlobalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dm = ref.watch(downloadManagerProvider).value;
    final state = dm?.stateFor(downloadGlobalId) ?? const DownloadIdle();
    final quality = (file.quality ?? '').trim().isEmpty ? 'Unknown quality' : file.quality!.trim();
    final lang = (file.videoLanguage ?? file.language ?? '').trim();
    final size = _formatBytes(file.size);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
        color: AppColors.card,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$quality  •  ${lang.isEmpty ? 'Unknown lang' : lang.toUpperCase()}  •  ${size ?? '?'}',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          if (dm == null)
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          else
            _VariantAction(
              dm: dm,
              state: state,
              media: media,
              file: file,
              downloadTitle: downloadTitle,
              downloadGlobalId: downloadGlobalId,
            ),
        ],
      ),
    );
  }
}

class _VariantAction extends StatelessWidget {
  const _VariantAction({
    required this.dm,
    required this.state,
    required this.media,
    required this.file,
    required this.downloadTitle,
    required this.downloadGlobalId,
  });

  final DownloadManager dm;
  final DownloadState state;
  final AppMedia media;
  final AppMediaFile file;
  final String downloadTitle;
  final String downloadGlobalId;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      DownloadIdle() => TVButton(
          onPressed: () => _startDownload(context),
          child: const Icon(Icons.download, color: Colors.white),
        ),
      DownloadRecovering() => const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.highlight,
          ),
        ),
      DownloadUnavailable() => const Text(
          'Not available',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
      Downloading(:final percent) => Row(
          children: [
            Text('$percent%', style: const TextStyle(color: AppColors.highlight)),
            const SizedBox(width: 8),
            TVButton(onPressed: () => dm.pauseDownload(downloadGlobalId), child: const Icon(Icons.pause, color: Colors.white)),
          ],
        ),
      DownloadPaused(:final percent) => Row(
          children: [
            Text('$percent%', style: const TextStyle(color: AppColors.textMuted)),
            const SizedBox(width: 8),
            TVButton(onPressed: () => dm.resumeDownload(downloadGlobalId), child: const Icon(Icons.play_arrow, color: Colors.white)),
          ],
        ),
      DownloadCompleted(:final localFilePath) => Row(
          children: [
            TVButton(
              onPressed: () => _play(context, localFilePath),
              child: const Icon(Icons.play_arrow, color: Colors.white),
            ),
            const SizedBox(width: 6),
            TVButton(
              onPressed: () => dm.deleteDownload(downloadGlobalId),
              child: const Icon(Icons.delete, color: Colors.redAccent),
            ),
          ],
        ),
      DownloadError() => TVButton(
          onPressed: () => _startDownload(context),
          child: const Icon(Icons.refresh, color: Colors.redAccent),
        ),
    };
  }

  void _startDownload(BuildContext context) {
    if (!_fileMayBeDownloadable(file)) {
      _itemLog(
        'SingleItemScreen: startDownload blocked for file=${file.id}',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This file is not downloadable yet.')),
      );
      return;
    }
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
        title: downloadTitle,
        year: media.releaseYear?.toString() ?? '',
        fileSize: file.size,
      ),
    );
  }

  Future<void> _play(BuildContext context, String path) async {
    final launched = await ExternalPlayer.launchVideo(path: path, title: downloadTitle);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No player found.')),
      );
    }
  }
}

/// TDLib needs a locator or `locatorRemoteFileId`; backup `telegramFileId` alone is often Bot API.
bool _fileMayBeDownloadable(AppMediaFile file) {
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

String? _formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) return null;
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
