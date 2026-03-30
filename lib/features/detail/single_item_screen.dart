import 'dart:io';

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
  List<AppMediaFile> _files = [];
  List<int> _seasons = [];
  List<AppMediaFile> _currentEpisodes = [];
  int _selectedSeason = 1;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    AppDebugLog.instance.log('SingleItemScreen: load start globalId=${widget.globalId}');
    
    final allMedia = await ref.read(mediaListProvider.future);
    
    // Find the requested media
    try {
      final item = allMedia.firstWhere((m) => m.media.id == widget.globalId);
      final isSeries = item.media.type == 'SERIES' || item.media.type == '#series';
      
      List<int> seasons = [];
      List<AppMediaFile> episodes = [];
      int selected = 1;

      if (isSeries) {
        final rawSeasons = item.files.map((f) => f.season).whereType<int>().toSet().toList();
        rawSeasons.sort();
        seasons = rawSeasons;
        if (seasons.isNotEmpty) {
          selected = seasons.first;
          episodes = item.files.where((f) => f.season == selected).toList();
          episodes.sort((a, b) => (a.episode ?? 0).compareTo(b.episode ?? 0));
        }
      }

      if (mounted) {
        setState(() {
          _aggregate = item;
          _files = item.files;
          _seasons = seasons;
          _selectedSeason = selected;
          _currentEpisodes = episodes;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _aggregate = null;
          _loading = false;
        });
      }
    }
  }

  void _loadEpisodesForSeason(int seasonNumber) {
    if (_aggregate == null) return;
    final episodes = _aggregate!.files.where((f) => f.season == seasonNumber).toList();
    episodes.sort((a, b) => (a.episode ?? 0).compareTo(b.episode ?? 0));
    setState(() {
      _selectedSeason = seasonNumber;
      _currentEpisodes = episodes;
    });
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
                  Colors.black.withOpacity(0.72),
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
                  child: isSeries
                      ? _SeriesPanel(
                          item: item,
                          seasons: _seasons,
                          episodes: _currentEpisodes,
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
    final dm = dmAsync.value;
    
    final item = aggregate.media;
    final isSeries = item.type == 'SERIES' || item.type == '#series';
    
    // For movies, we just take the first file global state. For series, we don't handle a single download state here.
    final firstFile = aggregate.files.isNotEmpty && !isSeries ? aggregate.files.first : null;
    final globalFileId = firstFile?.id ?? item.id;
    final state = dm?.stateFor(globalFileId) ?? const DownloadIdle();

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
          const SizedBox(height: 16),
          if (!isSeries) ...[
            if (dm == null)
              const CircularProgressIndicator(strokeWidth: 2)
            else
              _DownloadPlayButton(
                globalId: globalFileId,
                state: state,
                item: item,
                file: firstFile,
                dm: dm,
              ),
            const SizedBox(height: 10),
            if (dm != null && state is DownloadCompleted)
              TVButton(
                onPressed: () async {
                  await dm.deleteDownload(globalFileId);
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
    required this.file,
    required this.dm,
  });

  final String globalId;
  final DownloadState state;
  final AppMedia item;
  final AppMediaFile? file;
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
    if (file == null) {
      AppDebugLog.instance.log(
        'SingleItemScreen: startDownload blocked, no variant for globalId=$globalId',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No downloadable variant found.')),
      );
      return;
    }
    
    dm.startDownload(
      globalId: globalId,
      variantId: file!.id,
      telegramFileId: file!.telegramFileId,
      title: item.title,
      year: item.releaseYear?.toString() ?? '',
      fileSize: file!.size,
    );
    AppDebugLog.instance.log(
      'SingleItemScreen: startDownload requested '
      'globalId=$globalId variantId=${file!.id} '
      'telegramFileId=${file!.telegramFileId}',
    );
  }

  String? _bestVariantSizeLabel() {
    final bytes = file?.size;
    if (bytes == null || bytes <= 0) return null;
    return _formatBytes(bytes);
  }

  Future<void> _play(BuildContext context, String path) async {
    AppDebugLog.instance.log('SingleItemScreen: launching external player for $path');
    final launched = await ExternalPlayer.launchVideo(
      path: path,
      title: _formatMovieIntentTitle(
        item.title,
        item.releaseYear?.toString(),
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
}

class _MovieMetaPanel extends StatelessWidget {
  const _MovieMetaPanel({required this.item});

  final AppMedia item;

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
          if (item.imdbId != null && item.imdbId!.isNotEmpty) _MetaRow('IMDb', item.imdbId!),
          if (item.tmdbId != null && item.tmdbId!.isNotEmpty) _MetaRow('TMDB', item.tmdbId!),
          if (item.releaseYear != null) _MetaRow('Year', item.releaseYear.toString()),
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

  final AppMedia item;
  final List<int> seasons;
  final List<AppMediaFile> episodes;
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
                final isSelected = s == selectedSeason;
                return TVButton(
                  autofocus: i == 0,
                  onPressed: () => onSeasonSelected(s),
                  child: Text(
                    'Season $s',
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
                    'No episodes indexed yet.',
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

  final AppMediaFile episode;
  final String seriesTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodeGlobalId = episode.id;
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
              '${episode.episode ?? "?"}',
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
                  'Episode ${episode.episode ?? "?"}${episode.quality != null ? " - ${episode.quality}" : ""}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
  final AppMediaFile episode;
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
      DownloadCompleted(:final localFilePath) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
             TVButton(
              autofocus: false,
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              onPressed: () => _playEpisode(context, localFilePath),
              child: const Icon(Icons.play_arrow,
                  size: 18, color: Colors.white),
            ),
            const SizedBox(width: 4),
             TVButton(
              autofocus: false,
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              onPressed: () {
                dm.deleteDownload(episodeGlobalId);
              },
              child: const Icon(Icons.delete,
                  size: 18, color: Colors.redAccent),
            ),
          ]
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
    dm.startDownload(
      globalId: episodeGlobalId,
      variantId: episode.id,
      telegramFileId: episode.telegramFileId,
      title: _formatSeriesIntentTitle(),
      year: '',
      fileSize: episode.size,
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
    final episodeTitle = 'Episode ${episode.episode}';
    final season = episode.season?.toString().padLeft(2, '0') ?? '??';
    final ep = episode.episode?.toString().padLeft(2, '0') ?? '??';
    return '$seriesTitle - S$season'
        'E$ep - $episodeTitle';
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
