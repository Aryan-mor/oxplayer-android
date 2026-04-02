import 'dart:async';
import 'dart:io' show File;
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../core/debug/app_debug_log.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tv_button.dart';
import '../../core/tv/tv_expandable_section.dart';
import '../../data/models/app_media.dart';
import '../../download/download_manager.dart';
import '../../player/external_player.dart';
import '../../providers.dart';

void _itemLog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.app);

Future<void> _showDownloadUnavailableHelp(BuildContext context, WidgetRef ref) async {
  final bot = ref.read(appConfigProvider).captionerBotUsername;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Could not locate file'),
      content: Text(
        'We could not find this video in Telegram or recover it from backup.\n\n'
        'Send the media to @$bot, then run library sync in the app so it is indexed again.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

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
    
    final allMedia = (await ref.read(libraryFetchProvider.future)).items;
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
        'SingleItemScreen: not in library globalId=${widget.globalId} ($e), trying explore API',
      );
    }

    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token != null && token.isNotEmpty) {
      try {
        final config = ref.read(appConfigProvider);
        final api = ref.read(tvAppApiServiceProvider);
        final exploreItem = await api.fetchExploreMediaDetail(
          config: config,
          accessToken: token,
          mediaId: widget.globalId,
        );
        if (exploreItem != null && mounted) {
          _itemLog(
            'SingleItemScreen: loaded from explore id=${exploreItem.media.id} '
            'files=${exploreItem.files.length}',
          );
          setState(() {
            _aggregate = exploreItem;
            _loading = false;
          });
          return;
        }
      } catch (e) {
        _itemLog('SingleItemScreen: explore detail failed: $e');
      }
    }

    if (mounted) {
      setState(() {
        _aggregate = null;
        _loading = false;
      });
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
                _PosterPanel(aggregate: agg),
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
  const _PosterPanel({required this.aggregate});

  final AppMediaAggregate aggregate;

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

/// Always-visible overview; long copy uses a TV-focusable "Read more..." control.
class _OverviewSection extends StatefulWidget {
  const _OverviewSection({required this.summary});

  final String? summary;

  @override
  State<_OverviewSection> createState() => _OverviewSectionState();
}

class _OverviewSectionState extends State<_OverviewSection> {
  static const int _kPreviewCharCount = 500;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    const headingStyle = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: Colors.white,
    );
    const bodyStyle = TextStyle(
      color: AppColors.textMuted,
      height: 1.45,
    );

    final trimmed = (widget.summary ?? '').trim();
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Overview', style: headingStyle),
        const SizedBox(height: 8),
        if (trimmed.isEmpty)
          const Text('No description available.', style: bodyStyle)
        else ...[
          Text(
            _bodyText(trimmed),
            style: bodyStyle,
          ),
          if (_needsReadMore(trimmed)) ...[
            const SizedBox(height: 10),
            TVButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              borderRadius: 8,
              child: Text(
                _expanded ? 'Read less' : 'Read more...',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.highlight,
                ),
              ),
            ),
          ],
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: column,
    );
  }

  bool _needsReadMore(String trimmed) =>
      trimmed.characters.length > _kPreviewCharCount;

  String _bodyText(String trimmed) {
    if (!_needsReadMore(trimmed) || _expanded) return trimmed;
    return trimmed.characters.take(_kPreviewCharCount).toString();
  }
}

class _DetailsPanel extends StatelessWidget {
  const _DetailsPanel({required this.aggregate, required this.isSeries});

  final AppMediaAggregate aggregate;
  final bool isSeries;

  @override
  Widget build(BuildContext context) {
    final item = aggregate.media;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 12, 20, 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            color: Colors.black.withValues(alpha: 0.5),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: FocusTraversalGroup(
                policy: OrderedTraversalPolicy(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        if (item.releaseYear != null) _chip('Year ${item.releaseYear}'),
                        _chip(isSeries ? 'Series' : 'Movie'),
                        if (item.originalLanguage != null &&
                            item.originalLanguage!.isNotEmpty)
                          _chip(item.originalLanguage!.toUpperCase()),
                      ],
                    ),
                    if (item.genres.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      const Text(
                        'Genres',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 44,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: item.genres.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (ctx, i) {
                            final g = item.genres[i];
                            return TVButton(
                              onPressed: () {
                                context.push(
                                  '/explore?genreId=${Uri.encodeComponent(g.id)}',
                                );
                              },
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              child: Text(
                                g.title,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Colors.white,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    _OverviewSection(summary: item.summary),
                    if (isSeries)
                      _SeriesVariantsSection(aggregate: aggregate)
                    else
                      _MovieVariantsSection(aggregate: aggregate),
                  ],
                ),
              ),
            ),
          ),
        ),
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
        const Text(
          'Available versions',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        for (final file in aggregate.files)
          _VariantRow(
            media: aggregate.media,
            file: file,
            inSeriesSection: false,
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
        const Text(
          'Seasons',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        for (final season in seasons)
          TvExpandableSection(
            title: 'Season $season',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final ep in (grouped[season]!.keys.toList()..sort()))
                  TvExpandableSection(
                    title: 'Episode ${ep <= 0 ? '?' : ep}',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final file in grouped[season]![ep]!)
                          _VariantRow(
                            media: aggregate.media,
                            file: file,
                            inSeriesSection: true,
                            downloadTitle:
                                '${aggregate.media.title} - S${season.toString().padLeft(2, '0')}E${(ep <= 0 ? 0 : ep).toString().padLeft(2, '0')}',
                            downloadGlobalId: file.id,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

Future<void> _confirmAndDeleteDownload(
  BuildContext context, {
  required DownloadManager dm,
  required String downloadGlobalId,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text(
          'Remove download?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'The file will be deleted from this device. You can download it again later.',
          style: TextStyle(color: AppColors.textMuted, height: 1.35),
        ),
        actions: [
          FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 12,
              runSpacing: 8,
              children: [
                TVButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel', style: TextStyle(color: Colors.white)),
                ),
                TVButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Remove', style: TextStyle(color: Colors.redAccent)),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
  if (confirmed == true && context.mounted) {
    await dm.deleteDownload(downloadGlobalId);
  }
}

class _VariantRow extends ConsumerWidget {
  const _VariantRow({
    required this.media,
    required this.file,
    required this.inSeriesSection,
    required this.downloadTitle,
    required this.downloadGlobalId,
  });

  final AppMedia media;
  final AppMediaFile file;
  /// True when this row lives under the series seasons UI (also used with API type / file ep).
  final bool inSeriesSection;
  final String downloadTitle;
  final String downloadGlobalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSeriesMedia = _effectiveIsSeriesMedia(media, file, inSeriesSection);
    final dm = ref.watch(downloadManagerProvider).value;
    final state = dm?.stateFor(downloadGlobalId) ?? const DownloadIdle();
    final quality = (file.quality ?? '').trim().isEmpty ? 'Unknown quality' : file.quality!.trim();
    final lang = (file.videoLanguage ?? file.language ?? '').trim();
    final size = _formatBytes(file.size);
    final subLabel = _subtitleLabel(file);
    final infoParts = <String>[
      quality,
      lang.isEmpty ? 'Unknown lang' : lang.toUpperCase(),
      size ?? '?',
      if (subLabel != null) subLabel,
    ];

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
              infoParts.join('  •  '),
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
              isSeriesMedia: isSeriesMedia,
              downloadTitle: downloadTitle,
              downloadGlobalId: downloadGlobalId,
            ),
        ],
      ),
    );
  }
}

class _VariantAction extends ConsumerWidget {
  const _VariantAction({
    required this.dm,
    required this.state,
    required this.media,
    required this.file,
    required this.isSeriesMedia,
    required this.downloadTitle,
    required this.downloadGlobalId,
  });

  final DownloadManager dm;
  final DownloadState state;
  final AppMedia media;
  final AppMediaFile file;
  final bool isSeriesMedia;
  final String downloadTitle;
  final String downloadGlobalId;

  Widget _serverInfoButton(BuildContext context) {
    return TVButton(
      onPressed: () => _showServerFileInfoDialog(
        context,
        media: media,
        file: file,
        isSeriesMedia: isSeriesMedia,
        downloadTitle: downloadTitle,
      ),
      child: const Icon(Icons.info_outline, color: Colors.lightBlueAccent),
    );
  }

  /// Info (and completed-state bug) controls — omitted in release builds.
  List<Widget> _debugInfoSuffix(BuildContext context, {double gap = 6}) {
    if (!kDebugMode) return const [];
    return [
      SizedBox(width: gap),
      _serverInfoButton(context),
    ];
  }

  List<Widget> _debugCompletedInfoAndBugSuffix(
    BuildContext context,
    String localFilePath,
  ) {
    if (!kDebugMode) return const [];
    return [
      const SizedBox(width: 6),
      _serverInfoButton(context),
      const SizedBox(width: 6),
      TVButton(
        onPressed: () => _showDownloadDebugDialog(
          context,
          dm: dm,
          media: media,
          file: file,
          isSeriesMedia: isSeriesMedia,
          downloadTitle: downloadTitle,
          downloadGlobalId: downloadGlobalId,
          localPath: localFilePath,
        ),
        child: const Icon(Icons.bug_report, color: Colors.orangeAccent),
      ),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (state) {
      DownloadIdle() => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TVButton(
              onPressed: () => _startDownload(context),
              child: const Icon(Icons.download, color: Colors.white),
            ),
            ..._debugInfoSuffix(context),
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
            ..._debugInfoSuffix(context),
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
            ..._debugInfoSuffix(context),
          ],
        ),
      DownloadUnavailable() => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TVButton(
              onPressed: () => unawaited(_showDownloadUnavailableHelp(context, ref)),
              child: const Text(
                'Not available',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ),
            ..._debugInfoSuffix(context, gap: 8),
          ],
        ),
      Downloading(:final percent) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$percent%', style: const TextStyle(color: AppColors.highlight)),
            const SizedBox(width: 8),
            TVButton(
              onPressed: () => dm.pauseDownload(downloadGlobalId),
              child: const Icon(Icons.pause, color: Colors.white),
            ),
            ..._debugInfoSuffix(context),
          ],
        ),
      DownloadPaused(:final percent) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$percent%', style: const TextStyle(color: AppColors.textMuted)),
            const SizedBox(width: 8),
            TVButton(
              onPressed: () => dm.resumeDownload(downloadGlobalId),
              child: const Icon(Icons.play_arrow, color: Colors.white),
            ),
            const SizedBox(width: 6),
            TVButton(
              onPressed: () => unawaited(
                _confirmAndDeleteDownload(
                  context,
                  dm: dm,
                  downloadGlobalId: downloadGlobalId,
                ),
              ),
              child: const Icon(Icons.delete, color: Colors.redAccent),
            ),
            ..._debugInfoSuffix(context),
          ],
        ),
      DownloadCompleted(:final localFilePath) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TVButton(
              onPressed: () => _play(context, localFilePath),
              child: const Icon(Icons.play_arrow, color: Colors.white),
            ),
            ..._debugCompletedInfoAndBugSuffix(context, localFilePath),
            const SizedBox(width: 6),
            TVButton(
              onPressed: () => unawaited(
                _confirmAndDeleteDownload(
                  context,
                  dm: dm,
                  downloadGlobalId: downloadGlobalId,
                ),
              ),
              child: const Icon(Icons.delete, color: Colors.redAccent),
            ),
          ],
        ),
      DownloadError() => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TVButton(
              onPressed: () => _startDownload(context),
              child: const Icon(Icons.refresh, color: Colors.redAccent),
            ),
            ..._debugInfoSuffix(context),
          ],
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
        mediaTitle: media.title,
        displayTitle: downloadTitle,
        releaseYear: media.releaseYear?.toString() ?? '',
        isSeriesMedia: isSeriesMedia,
        season: file.season,
        episode: file.episode,
        quality: file.quality,
        fileSize: file.size,
      ),
    );
  }

  Future<void> _play(BuildContext context, String path) async {
    await ExternalPlayer.injectMetadata(
      path: path,
      title: downloadTitle,
      year: media.releaseYear?.toString() ?? '',
      mediaTitle: media.title,
      displayTitle: downloadTitle,
      subtitle: _seasonEpisodeLine(isSeriesMedia, file),
      isSeries: isSeriesMedia,
    );
    final launched = await ExternalPlayer.launchVideo(path: path, title: downloadTitle);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No player found.')),
      );
    }
  }
}

bool _effectiveIsSeriesMedia(
  AppMedia media,
  AppMediaFile file,
  bool inSeriesUi,
) {
  final t = media.type.toUpperCase();
  if (t == 'SERIES' || t == '#SERIES') return true;
  if (inSeriesUi) return true;
  if ((file.season ?? 0) > 0) return true;
  if ((file.episode ?? 0) > 0) return true;
  return false;
}

String? _seasonEpisodeLine(bool isSeries, AppMediaFile file) {
  if (!isSeries) return null;
  final s = (file.season ?? 1).clamp(0, 999);
  final e = (file.episode != null && file.episode! > 0)
      ? file.episode!.clamp(0, 999)
      : 0;
  return 'S${s.toString().padLeft(2, '0')}E${e.toString().padLeft(2, '0')}';
}

String _truncateForInfo(String? s, {int max = 120}) {
  if (s == null) return '(null)';
  final t = s.trim();
  if (t.isEmpty) return '(empty)';
  if (t.length <= max) return t;
  return '${t.substring(0, max)}… (${t.length} chars)';
}

Future<void> _showServerFileInfoDialog(
  BuildContext context, {
  required AppMedia media,
  required AppMediaFile file,
  required bool isSeriesMedia,
  required String downloadTitle,
}) async {
  final r = StringBuffer();
  r.writeln('=== API MEDIA (library item) ===');
  r.writeln('id: ${media.id}');
  r.writeln('title: ${media.title}');
  r.writeln('type: ${media.type}');
  r.writeln('releaseYear: ${media.releaseYear}');
  r.writeln('tmdbId: ${media.tmdbId}');
  r.writeln('imdbId: ${media.imdbId}');
  r.writeln('originalLanguage: ${media.originalLanguage}');
  r.writeln('posterPath: ${media.posterPath}');
  r.writeln('summary: ${_truncateForInfo(media.summary, max: 200)}');
  r.writeln('rawDetails: ${_truncateForInfo(media.rawDetails, max: 160)}');
  r.writeln('createdAt: ${media.createdAt.toIso8601String()}');
  r.writeln('updatedAt: ${media.updatedAt.toIso8601String()}');
  r.writeln('');
  r.writeln('=== VARIANT (file row from API) ===');
  r.writeln('id (variant): ${file.id}');
  r.writeln('mediaId: ${file.mediaId}');
  r.writeln('sourceId: ${file.sourceId}');
  r.writeln('sourceChatId: ${file.sourceChatId}');
  r.writeln('fileUniqueId: ${file.fileUniqueId}');
  r.writeln('videoLanguage: ${file.videoLanguage}');
  r.writeln('quality: ${file.quality}');
  r.writeln('size (bytes, API): ${file.size}');
  r.writeln('versionTag: ${file.versionTag}');
  r.writeln('language: ${file.language}');
  r.writeln('season: ${file.season}');
  r.writeln('episode: ${file.episode}');
  r.writeln('createdAt: ${file.createdAt.toIso8601String()}');
  r.writeln('updatedAt: ${file.updatedAt.toIso8601String()}');
  r.writeln('');
  r.writeln('=== TELEGRAM / LOCATOR (from API) ===');
  r.writeln(
    'telegramFileId: ${_truncateForInfo(file.telegramFileId, max: 96)}',
  );
  r.writeln('locatorType: ${file.locatorType}');
  r.writeln('locatorChatId: ${file.locatorChatId}');
  r.writeln('locatorMessageId: ${file.locatorMessageId}');
  r.writeln('locatorBotUsername: ${file.locatorBotUsername}');
  r.writeln(
    'locatorRemoteFileId: ${_truncateForInfo(file.locatorRemoteFileId, max: 96)}',
  );
  r.writeln('');
  r.writeln('=== DISPLAY (how this row is labeled in the app) ===');
  r.writeln('inferred isSeriesMedia: $isSeriesMedia');
  r.writeln('displayTitle (player / tags): $downloadTitle');
  r.writeln('seasonEpisode line: ${_seasonEpisodeLine(isSeriesMedia, file)}');

  final text = r.toString();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      title: const Text(
        'File info (from server)',
        style: TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: 560,
        height: 420,
        child: SingleChildScrollView(
          child: SelectableText(
            text,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              height: 1.35,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied to clipboard')),
              );
            }
          },
          child: const Text('Copy'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

Future<void> _showDownloadDebugDialog(
  BuildContext context, {
  required DownloadManager dm,
  required AppMedia media,
  required AppMediaFile file,
  required bool isSeriesMedia,
  required String downloadTitle,
  required String downloadGlobalId,
  required String localPath,
}) async {
  final record = dm.downloadRecordFor(downloadGlobalId);
  final disk = StringBuffer();
  try {
    final f = File(localPath);
    if (await f.exists()) {
      disk.writeln('exists: true');
      disk.writeln('length_bytes: ${await f.length()}');
      disk.writeln('path: $localPath');
    } else {
      disk.writeln('exists: false');
      disk.writeln('path: $localPath');
    }
  } catch (e) {
    disk.writeln('stat_error: $e');
  }

  final r = StringBuffer();
  r.writeln('=== API MEDIA (library item) ===');
  r.writeln('media.id: ${media.id}');
  r.writeln('media.title: ${media.title}');
  r.writeln('media.type: ${media.type}');
  r.writeln('media.releaseYear: ${media.releaseYear}');
  r.writeln('media.tmdbId: ${media.tmdbId}');
  r.writeln('');
  r.writeln('=== VARIANT (file row from API) ===');
  r.writeln('file.id (variant / download globalId): ${file.id}');
  r.writeln('file.mediaId: ${file.mediaId}');
  r.writeln('file.season: ${file.season}');
  r.writeln('file.episode: ${file.episode}');
  r.writeln('file.quality: ${file.quality}');
  r.writeln('file.size (API): ${file.size}');
  r.writeln('file.mime/telegram: telegramFileId set=${(file.telegramFileId ?? '').isNotEmpty}');
  r.writeln('locatorType: ${file.locatorType}');
  r.writeln('locatorChatId/messageId: ${file.locatorChatId} / ${file.locatorMessageId}');
  r.writeln('');
  r.writeln('=== UI / NAMING INPUTS ===');
  r.writeln('inferred isSeriesMedia: $isSeriesMedia');
  r.writeln('displayTitle (player / tags): $downloadTitle');
  r.writeln('seasonEpisode line: ${_seasonEpisodeLine(isSeriesMedia, file)}');
  r.writeln('');
  r.writeln('=== PERSISTED DOWNLOAD RECORD ===');
  if (record == null) {
    r.writeln('(no record)');
  } else {
    r.writeln('standardizedName: ${record.standardizedName}');
    r.writeln('fileName: ${record.fileName}');
    r.writeln('localFilePath: ${record.localFilePath}');
    r.writeln('displayTitle: ${record.displayTitle}');
    r.writeln('mediaTitle: ${record.mediaTitle}');
    r.writeln('releaseYear: ${record.releaseYear}');
    r.writeln('isSeriesMedia: ${record.isSeriesMedia}');
    r.writeln('season/episode: ${record.season} / ${record.episode}');
    r.writeln('quality: ${record.quality}');
    r.writeln('mimeType: ${record.mimeType}');
    r.writeln('status: ${record.status}');
  }
  r.writeln('');
  r.writeln('=== ON DISK (this session path) ===');
  r.writeln(disk.toString().trimRight());
  r.writeln('');
  r.writeln('=== COMPARE ===');
  r.writeln('basename(localPath): ${p.basename(localPath)}');
  r.writeln('basenameWithoutExtension: ${p.basenameWithoutExtension(localPath)}');

  final text = r.toString();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      title: const Text(
        'Download debug',
        style: TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: 560,
        height: 420,
        child: SingleChildScrollView(
          child: SelectableText(
            text,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              height: 1.35,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied to clipboard')),
              );
            }
          },
          child: const Text('Copy'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
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

String? _subtitleLabel(AppMediaFile file) {
  if (!file.subtitleMentioned) return null;
  final raw = (file.subtitlePresentation ?? '').trim().toLowerCase();
  final kind = raw == 'hardsub' || raw == 'softsub' ? raw : 'sub';
  final lang = (file.subtitleLanguage ?? '').trim().toUpperCase();
  return lang.isEmpty ? 'SUB: ${kind.toUpperCase()}' : 'SUB: ${kind.toUpperCase()} $lang';
}
