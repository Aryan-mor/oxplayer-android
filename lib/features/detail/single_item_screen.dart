import 'dart:async';
import 'dart:io' show File;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/debug/app_debug_log.dart';
import '../../core/oxplayer/oxplayer_expandable_section.dart';
import '../../core/storage/storage_headroom.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/oxplayer_button.dart';
import '../../data/models/app_media.dart';
import '../../data/models/series_episode_guide.dart';
import '../../download/download_manager.dart';
import '../../player/internal_player.dart';
import '../../player/telegram_range_playback.dart';
import '../../providers.dart';

void _itemLog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.app);

bool _isSeriesMediaType(AppMedia m) {
  final t = m.type.toUpperCase();
  return t == 'SERIES' || t == '#SERIES';
}

bool _hasTmdbId(AppMedia m) => (m.tmdbId ?? '').trim().isNotEmpty;

String? _resolveDetailPosterUrl(String? posterPath) {
  final value = (posterPath ?? '').trim();
  if (value.isEmpty) return null;
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return value;
  }
  if (value.startsWith('/')) return 'https://image.tmdb.org/t/p/w500$value';
  return value;
}

/// Section title for playback blocks (movie / other / series).
const TextStyle _kPlaybackSectionTitleStyle = TextStyle(
  fontSize: 18,
  fontWeight: FontWeight.w700,
  color: Colors.white,
);

/// Outer panel matching home library tiles: elevated card for a major block (info or playback).
class _DetailPanelCard extends StatelessWidget {
  const _DetailPanelCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card,
      elevation: 4,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: child,
      ),
    );
  }
}

/// One indexed file = one option (quality / language / dub). Same shell for movies, other, and series episodes.
class _PlaybackOptionCard extends StatelessWidget {
  const _PlaybackOptionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.card,
        elevation: 0,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: child,
        ),
      ),
    );
  }
}

Future<void> _showDownloadUnavailableHelp(
    BuildContext context, WidgetRef ref) async {
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
  final ScrollController _pageScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    _itemLog('SingleItemScreen: load start globalId=${widget.globalId}');

    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token != null && token.isNotEmpty) {
      try {
        final config = ref.read(appConfigProvider);
        final api = ref.read(oxplayerApiServiceProvider);
        final detail = await api.fetchLibraryMediaDetail(
          config: config,
          accessToken: token,
          mediaId: widget.globalId,
        );
        if (detail != null && mounted) {
          _itemLog(
            'SingleItemScreen: loaded from library detail id=${detail.media.id} '
            'files=${detail.files.length}',
          );
          setState(() {
            _aggregate = detail;
            _loading = false;
          });
          return;
        }
      } catch (e) {
        _itemLog('SingleItemScreen: library detail failed: $e');
      }
    }

    // Fallback to already fetched list (older behavior / offline-ish cache).
    try {
      final allMedia = (await ref.read(libraryFetchProvider.future)).items;
      final item = allMedia.firstWhere((m) => m.media.id == widget.globalId);
      if (mounted) {
        setState(() {
          _aggregate = item;
          _loading = false;
        });
      }
      return;
    } catch (_) {
      _itemLog(
        'SingleItemScreen: not in merged library list globalId=${widget.globalId}',
      );
    }

    if (auth.canAccessExplore && token != null && token.isNotEmpty) {
      try {
        final config = ref.read(appConfigProvider);
        final api = ref.read(oxplayerApiServiceProvider);
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
  void dispose() {
    _pageScrollController.dispose();
    super.dispose();
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
    final isSeries = _isSeriesMediaType(item);
    final auth = ref.watch(authNotifierProvider);
    final exploreGenreLinks = auth.canAccessExplore;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
      ),
      body: Scrollbar(
        controller: _pageScrollController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _pageScrollController,
          primary: false,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 720;
              final hero = wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _DetailHeroPoster(media: item),
                        const SizedBox(width: 24),
                        Expanded(
                          child: _DetailPanelCard(
                            child: _DetailMetaColumn(
                              item: item,
                              hasTmdb: _hasTmdbId(item),
                              exploreGenreLinksEnabled: exploreGenreLinks,
                            ),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(child: _DetailHeroPoster(media: item)),
                        const SizedBox(height: 20),
                        _DetailPanelCard(
                          child: _DetailMetaColumn(
                            item: item,
                            hasTmdb: _hasTmdbId(item),
                            exploreGenreLinksEnabled: exploreGenreLinks,
                          ),
                        ),
                      ],
                    );

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  hero,
                  const SizedBox(height: 28),
                  if (isSeries)
                    _SeriesVariantsSection(aggregate: agg)
                  else
                    _MovieVariantsSection(aggregate: agg),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Poster only (hero row); title and metadata sit beside or below it.
class _DetailHeroPoster extends StatelessWidget {
  const _DetailHeroPoster({required this.media});

  final AppMedia media;

  @override
  Widget build(BuildContext context) {
    final poster = _resolveDetailPosterUrl(media.posterPath) ?? '';
    return SizedBox(
      width: 260,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
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
                    alignment: Alignment.center,
                    child: const Icon(Icons.movie, size: 56),
                  ),
                )
              : Container(
                  color: AppColors.card,
                  alignment: Alignment.center,
                  child: const Icon(Icons.movie, size: 56),
                ),
        ),
      ),
    );
  }
}

/// Title, TMDB score + genres when linked, then overview.
class _DetailMetaColumn extends StatelessWidget {
  const _DetailMetaColumn({
    required this.item,
    required this.hasTmdb,
    required this.exploreGenreLinksEnabled,
  });

  final AppMedia item;
  final bool hasTmdb;
  final bool exploreGenreLinksEnabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.title,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            height: 1.2,
          ),
        ),
        if (item.releaseYear != null ||
            (item.originalLanguage ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (item.releaseYear != null) _chip('Year ${item.releaseYear}'),
              if ((item.originalLanguage ?? '').trim().isNotEmpty)
                _chip(item.originalLanguage!.trim().toUpperCase()),
            ],
          ),
        ],
        if (hasTmdb && item.voteAverage != null) ...[
          const SizedBox(height: 14),
          Text(
            'User score ${item.voteAverage!.toStringAsFixed(1)} / 10',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (hasTmdb && item.genres.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            'Genres',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final g in item.genres)
                exploreGenreLinksEnabled
                    ? OxplayerButton(
                        onPressed: () {
                          context.push(
                            '/explore?genreId=${Uri.encodeComponent(g.id)}',
                          );
                        },
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Text(
                          g.title,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.white,
                          ),
                        ),
                      )
                    : _chip(g.title),
            ],
          ),
        ],
        const SizedBox(height: 14),
        _OverviewSection(summary: item.summary),
      ],
    );
  }
}

/// Always-visible overview; long copy uses a remote-focusable "Read more..." control.
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
            OxplayerButton(
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

/// QR + “send to bot” copy. Optional [trailingBesideQr] sits to the right of the QR (e.g. Request file).
class _IndexingBotQrPanel extends ConsumerWidget {
  const _IndexingBotQrPanel({this.trailingBesideQr});

  final Widget? trailingBesideQr;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(appConfigProvider);
    final botUser = cfg.botUsername.trim();
    final telegramUri = botUser.isNotEmpty ? 'https://t.me/$botUser' : '';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (telegramUri.isNotEmpty) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 156,
                height: 156,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: QrImageView(
                      data: telegramUri,
                      version: QrVersions.auto,
                      gapless: true,
                      eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: Color(0xFF000000),
                      ),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: Color(0xFF000000),
                      ),
                    ),
                  ),
                ),
              ),
              if (trailingBesideQr != null) ...[
                const SizedBox(width: 16),
                trailingBesideQr!,
              ],
            ],
          ),
          const SizedBox(height: 12),
        ] else if (trailingBesideQr != null) ...[
          trailingBesideQr!,
          const SizedBox(height: 12),
        ],
        Text(
          botUser.isNotEmpty
              ? 'Send this episode’s video file to @$botUser on Telegram. '
                  'Scan the QR code to open the bot, then upload the file so it can be indexed.'
              : 'Send the video file to your indexing bot (set BOT_USERNAME in the app env).',
          style: const TextStyle(
            color: AppColors.textMuted,
            height: 1.35,
            fontSize: 14,
          ),
        ),
      ],
    );
  }
}

class _EmptyFilesRequestBlock extends ConsumerStatefulWidget {
  const _EmptyFilesRequestBlock({required this.aggregate});

  final AppMediaAggregate aggregate;

  @override
  ConsumerState<_EmptyFilesRequestBlock> createState() =>
      _EmptyFilesRequestBlockState();
}

class _EmptyFilesRequestBlockState
    extends ConsumerState<_EmptyFilesRequestBlock> {
  /// After a successful POST, until the parent rebuilds with API [currentUserHasAccess].
  bool _requestedLocally = false;

  static const _alreadyRequestedBody =
      'You have already requested a file for this title. The team has been '
      'notified when possible. You can still send the video to the bot using '
      'the QR code above so it can be indexed.';

  @override
  void didUpdateWidget(covariant _EmptyFilesRequestBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.aggregate.media.id != widget.aggregate.media.id) {
      _requestedLocally = false;
    }
  }

  bool get _alreadyRequested =>
      widget.aggregate.currentUserHasAccess || _requestedLocally;

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(appConfigProvider);
    final botUser = cfg.botUsername.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.aggregate.media.type == 'SERIES' ||
                  widget.aggregate.media.type == '#series'
              ? 'No episodes indexed yet.'
              : 'No files indexed yet.',
          style: const TextStyle(color: AppColors.textMuted),
        ),
        const SizedBox(height: 14),
        _IndexingBotQrPanel(
          trailingBesideQr: _alreadyRequested
              ? null
              : OxplayerButton(
                  onPressed: () => unawaited(_onRequestFile(context)),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                  child: const Text('Request file'),
                ),
        ),
        if (_alreadyRequested) ...[
          const Text(
            _alreadyRequestedBody,
            style: TextStyle(
              color: AppColors.textMuted,
              height: 1.35,
              fontSize: 14,
            ),
          ),
        ] else ...[
          const SizedBox(height: 12),
          Text(
            botUser.isNotEmpty
                ? 'You can add this title to your library by sending the '
                    'video file to @$botUser on Telegram. Scan the QR code above '
                    'to open that bot, then send the file so it can be indexed.'
                : 'You can add this title to your library by sending the video '
                    'file to your indexing bot (set BOT_USERNAME in the app env).',
            style: const TextStyle(
              color: AppColors.textMuted,
              height: 1.35,
              fontSize: 14,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _onRequestFile(BuildContext context) async {
    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Not signed in.')),
        );
      }
      return;
    }
    try {
      final config = ref.read(appConfigProvider);
      final api = ref.read(oxplayerApiServiceProvider);
      final r = await api.requestMediaFile(
        config: config,
        accessToken: token,
        mediaId: widget.aggregate.media.id,
      );
      if (!context.mounted) return;
      setState(() => _requestedLocally = true);
      final msg = r.notifyFailed
          ? 'Request saved. Admins could not be notified.'
          : (r.notifiedAdmins > 0
              ? 'Request sent to admins.'
              : 'Request saved.');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      ref.invalidate(libraryFetchProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Request failed: $e')),
        );
      }
    }
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
    child:
        Text(text, style: const TextStyle(fontSize: 12, color: Colors.white)),
  );
}

class _MovieVariantsSection extends ConsumerWidget {
  const _MovieVariantsSection({required this.aggregate});

  final AppMediaAggregate aggregate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: _DetailPanelCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Playback', style: _kPlaybackSectionTitleStyle),
            const SizedBox(height: 14),
            if (aggregate.files.isEmpty)
              _EmptyFilesRequestBlock(aggregate: aggregate)
            else
              for (final file in aggregate.files)
                _PlaybackOptionCard(
                  child: _VariantRow(
                    media: aggregate.media,
                    file: file,
                    inSeriesSection: false,
                    downloadTitle: aggregate.media.title,
                    downloadGlobalId: file.id,
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _SeriesVariantsSection extends ConsumerStatefulWidget {
  const _SeriesVariantsSection({required this.aggregate});

  final AppMediaAggregate aggregate;

  @override
  ConsumerState<_SeriesVariantsSection> createState() =>
      _SeriesVariantsSectionState();
}

class _SeriesVariantsSectionState
    extends ConsumerState<_SeriesVariantsSection> {
  SeriesEpisodeGuide? _guide;
  bool _guideLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => unawaited(_loadSeriesEpisodeGuide()));
  }

  @override
  void didUpdateWidget(covariant _SeriesVariantsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.aggregate.media.id != widget.aggregate.media.id) {
      _guide = null;
      unawaited(_loadSeriesEpisodeGuide());
    }
  }

  bool get _hasSeriesTmdbKey {
    final t = (widget.aggregate.media.tmdbId ?? '').trim().toLowerCase();
    return t.startsWith('tv:');
  }

  Future<void> _loadSeriesEpisodeGuide() async {
    if (!_hasSeriesTmdbKey) return;
    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) return;
    if (!mounted) return;
    setState(() => _guideLoading = true);
    try {
      final api = ref.read(oxplayerApiServiceProvider);
      final cfg = ref.read(appConfigProvider);
      final g = await api.fetchSeriesEpisodeGuide(
        config: cfg,
        accessToken: token,
        mediaId: widget.aggregate.media.id,
      );
      if (!mounted) return;
      setState(() {
        _guide = g;
        _guideLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _guide = null;
        _guideLoading = false;
      });
    }
  }

  Map<int, Map<int, List<AppMediaFile>>> _filesGrouped() {
    final grouped = <int, Map<int, List<AppMediaFile>>>{};
    for (final file in widget.aggregate.files) {
      final season = file.season ?? 1;
      final episode = file.episode ?? 0;
      grouped.putIfAbsent(season, () => <int, List<AppMediaFile>>{});
      grouped[season]!.putIfAbsent(episode, () => <AppMediaFile>[]);
      grouped[season]![episode]!.add(file);
    }
    return grouped;
  }

  String? _tmdbEpisodeName(SeriesEpisodeGuide? guide, int season, int ep) {
    if (guide == null) return null;
    for (final gs in guide.seasons) {
      if (gs.seasonNumber != season) continue;
      for (final ge in gs.episodes) {
        if (ge.episodeNumber == ep) {
          final n = (ge.name ?? '').trim();
          return n.isEmpty ? null : n;
        }
      }
    }
    return null;
  }

  String? _tmdbEpisodeOverview(SeriesEpisodeGuide? guide, int season, int ep) {
    if (guide == null) return null;
    for (final gs in guide.seasons) {
      if (gs.seasonNumber != season) continue;
      for (final ge in gs.episodes) {
        if (ge.episodeNumber == ep) {
          final o = (ge.overview ?? '').trim();
          return o.isEmpty ? null : o;
        }
      }
    }
    return null;
  }

  List<int> _indexedEpisodeNumbers(
    int season,
    Map<int, Map<int, List<AppMediaFile>>> grouped,
  ) {
    final m = grouped[season];
    if (m == null || m.isEmpty) return [];
    final list = m.keys.toList()..sort();
    return list;
  }

  Widget _episodeExpandable({
    required int season,
    required int ep,
    required Map<int, Map<int, List<AppMediaFile>>> grouped,
    required bool useGuide,
  }) {
    final tmdbName = useGuide ? _tmdbEpisodeName(_guide, season, ep) : null;
    final tmdbOv = useGuide ? _tmdbEpisodeOverview(_guide, season, ep) : null;
    final files = grouped[season]?[ep] ?? <AppMediaFile>[];
    if (files.isEmpty) return const SizedBox.shrink();

    final epLabel = ep <= 0 ? '?' : '$ep';
    final header = (tmdbName != null && tmdbName.isNotEmpty)
        ? 'Episode $epLabel — $tmdbName'
        : 'Episode $epLabel';

    final desc = (tmdbOv ?? '').trim().isNotEmpty
        ? tmdbOv!.trim()
        : _firstCaptionAmongFiles(files);

    return OxplayerExpandableSection(
      title: header,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (desc != null && desc.isNotEmpty) ...[
            Text(
              desc,
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
          ],
          for (final file in files)
            _PlaybackOptionCard(
              child: _VariantRow(
                media: widget.aggregate.media,
                file: file,
                inSeriesSection: true,
                episodeTitle: null,
                downloadTitle:
                    '${widget.aggregate.media.title} - S${season.toString().padLeft(2, '0')}E${(ep <= 0 ? 0 : ep).toString().padLeft(2, '0')}',
                downloadGlobalId: file.id,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _filesGrouped();
    final useGuide = _guide != null && _guide!.seasons.isNotEmpty;

    if (widget.aggregate.files.isEmpty) {
      if (_hasSeriesTmdbKey && _guideLoading) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: _DetailPanelCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Playback', style: _kPlaybackSectionTitleStyle),
              const SizedBox(height: 14),
              _EmptyFilesRequestBlock(aggregate: widget.aggregate),
            ],
          ),
        ),
      );
    }

    final seasonList = grouped.keys.toList()..sort();

    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: _DetailPanelCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Playback', style: _kPlaybackSectionTitleStyle),
                if (_guideLoading && _hasSeriesTmdbKey) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 14),
            for (final season in seasonList)
              OxplayerExpandableSection(
                title: 'Season $season',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final ep in _indexedEpisodeNumbers(season, grouped))
                      _episodeExpandable(
                        season: season,
                        ep: ep,
                        grouped: grouped,
                        useGuide: useGuide,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
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
                OxplayerButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel',
                      style: TextStyle(color: Colors.white)),
                ),
                OxplayerButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Remove',
                      style: TextStyle(color: Colors.redAccent)),
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

class _VariantRow extends ConsumerStatefulWidget {
  const _VariantRow({
    required this.media,
    required this.file,
    required this.inSeriesSection,
    required this.downloadTitle,
    required this.downloadGlobalId,
    this.episodeTitle,
  });

  final AppMedia media;
  final AppMediaFile file;

  /// True when this row lives under the series seasons UI (also used with API type / file ep).
  final bool inSeriesSection;
  final String downloadTitle;
  final String downloadGlobalId;

  /// TMDB episode name when available (series only).
  final String? episodeTitle;

  @override
  ConsumerState<_VariantRow> createState() => _VariantRowState();
}

class _VariantRowState extends ConsumerState<_VariantRow> {
  final GlobalKey _cardKey = GlobalKey();
  bool _episodeTitleExpanded = false;

  @override
  void didUpdateWidget(covariant _VariantRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.episodeTitle != widget.episodeTitle ||
        oldWidget.file.id != widget.file.id) {
      _episodeTitleExpanded = false;
    }
  }

  void _scrollCardIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _cardKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: 0.42,
      );
    });
  }

  void _onTitleFocus(bool focused) {
    if (focused) {
      _scrollCardIntoView();
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final isSeriesMedia =
        _effectiveIsSeriesMedia(w.media, w.file, w.inSeriesSection);
    final dm = ref.watch(downloadManagerProvider).value;
    final state = dm?.stateFor(w.downloadGlobalId) ?? const DownloadIdle();
    final quality = (w.file.quality ?? '').trim();
    final lang = (w.file.videoLanguage ?? w.file.language ?? '').trim();
    final size = _formatBytes(w.file.size);
    final subLabel = _subtitleLabel(w.file);
    final infoParts = <String>[
      if (quality.isNotEmpty) quality,
      if (lang.isNotEmpty) lang.toUpperCase(),
      if (size != null && size.isNotEmpty) size,
      if (subLabel != null) subLabel,
    ];
    final infoLine = infoParts.join('  •  ');
    final captionPreview = _captionPreview(w.file.captionText);
    final epTitle = (w.episodeTitle ?? '').trim();
    final hasEpTitle = epTitle.isNotEmpty;

    final action = dm == null
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : _VariantAction(
            dm: dm,
            state: state,
            media: w.media,
            file: w.file,
            isSeriesMedia: isSeriesMedia,
            downloadTitle: w.downloadTitle,
            downloadGlobalId: w.downloadGlobalId,
            onRowButtonFocused: _scrollCardIntoView,
          );

    final Widget titleRowLeading = hasEpTitle
        ? OxplayerButton(
            plainWhenUnfocused: true,
            padding: const EdgeInsets.symmetric(vertical: 2),
            borderRadius: 6,
            onPressed: () =>
                setState(() => _episodeTitleExpanded = !_episodeTitleExpanded),
            onFocusChanged: _onTitleFocus,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                epTitle,
                maxLines: _episodeTitleExpanded ? null : 1,
                overflow: _episodeTitleExpanded
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: TextStyle(
                  color: _episodeTitleExpanded
                      ? Colors.white
                      : AppColors.textMuted,
                  fontSize: _episodeTitleExpanded ? 14 : 13,
                  height: 1.35,
                ),
              ),
            ),
          )
        : (infoLine.isEmpty
            ? const SizedBox.shrink()
            : Text(
                infoLine,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ));

    return RepaintBoundary(
      key: _cardKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    titleRowLeading,
                    if (hasEpTitle && infoLine.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        infoLine,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 2),
                child: action,
              ),
            ],
          ),
          if (captionPreview != null) ...[
            const SizedBox(height: 8),
            Text(
              captionPreview,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _VariantAction extends ConsumerStatefulWidget {
  const _VariantAction({
    required this.dm,
    required this.state,
    required this.media,
    required this.file,
    required this.isSeriesMedia,
    required this.downloadTitle,
    required this.downloadGlobalId,
    this.onRowButtonFocused,
  });

  final DownloadManager dm;
  final DownloadState state;
  final AppMedia media;
  final AppMediaFile file;
  final bool isSeriesMedia;
  final String downloadTitle;
  final String downloadGlobalId;

  /// Called when any action button in this row receives focus (D-pad), so the
  /// parent can scroll the full variant card (incl. caption) into view.
  final VoidCallback? onRowButtonFocused;

  @override
  ConsumerState<_VariantAction> createState() => _VariantActionState();
}

class _VariantActionState extends ConsumerState<_VariantAction> {
  bool _isStartingStream = false;

  DownloadManager get dm => widget.dm;
  DownloadState get state => widget.state;
  AppMedia get media => widget.media;
  AppMediaFile get file => widget.file;
  bool get isSeriesMedia => widget.isSeriesMedia;
  String get downloadTitle => widget.downloadTitle;
  String get downloadGlobalId => widget.downloadGlobalId;

  void _notifyRowButtonFocused(bool focused) {
    if (focused) widget.onRowButtonFocused?.call();
  }

  Widget _rowOxplayerButton({
    required VoidCallback? onPressed,
    required Widget child,
    bool enabled = true,
    KeyEventResult Function(FocusNode node, KeyEvent event)? onKeyEvent,
  }) {
    return OxplayerButton(
      enabled: enabled,
      onPressed: onPressed,
      onKeyEvent: onKeyEvent,
      onFocusChanged:
          widget.onRowButtonFocused == null ? null : _notifyRowButtonFocused,
      child: child,
    );
  }

  Widget _serverInfoButton(BuildContext context) {
    return _rowOxplayerButton(
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
      _rowOxplayerButton(
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

  Future<void> _onStreamPressed(BuildContext context, WidgetRef ref) async {
    if (_isStartingStream) return;
    setState(() => _isStartingStream = true);
    try {
      await _stream(context, ref);
    } finally {
      if (mounted) {
        setState(() => _isStartingStream = false);
      }
    }
  }

  Widget _streamButton(BuildContext context, WidgetRef ref) {
    return _rowOxplayerButton(
      enabled: !_isStartingStream,
      onPressed: _isStartingStream
          ? null
          : () => unawaited(_onStreamPressed(context, ref)),
      child: SizedBox(
        width: 24,
        height: 24,
        child: _isStartingStream
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = ref;
    return switch (state) {
      DownloadIdle() => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (file.canStream) _streamButton(context, r),
            if (file.canStream) const SizedBox(width: 6),
            _rowOxplayerButton(
              onPressed: () => unawaited(_startDownload(context)),
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
            if (file.canStream) const SizedBox(width: 8),
            if (file.canStream) _streamButton(context, r),
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
            if (file.canStream) const SizedBox(width: 8),
            if (file.canStream) _streamButton(context, r),
            ..._debugInfoSuffix(context),
          ],
        ),
      DownloadUnavailable() => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _rowOxplayerButton(
              onPressed: () =>
                  unawaited(_showDownloadUnavailableHelp(context, r)),
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
            Text('$percent%',
                style: const TextStyle(color: AppColors.highlight)),
            const SizedBox(width: 8),
            if (file.canStream) _streamButton(context, r),
            if (file.canStream) const SizedBox(width: 6),
            _rowOxplayerButton(
              onPressed: () => dm.pauseDownload(downloadGlobalId),
              child: const Icon(Icons.pause, color: Colors.white),
            ),
            ..._debugInfoSuffix(context),
          ],
        ),
      DownloadPaused(:final percent) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$percent%',
                style: const TextStyle(color: AppColors.textMuted)),
            const SizedBox(width: 8),
            if (file.canStream) _streamButton(context, r),
            if (file.canStream) const SizedBox(width: 6),
            _rowOxplayerButton(
              onPressed: () => dm.resumeDownload(downloadGlobalId),
              child: const Icon(Icons.play_arrow, color: Colors.white),
            ),
            const SizedBox(width: 6),
            _rowOxplayerButton(
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
            _rowOxplayerButton(
              onPressed: () => _play(context, localFilePath),
              child: const Icon(Icons.play_arrow, color: Colors.white),
            ),
            ..._debugCompletedInfoAndBugSuffix(context, localFilePath),
            const SizedBox(width: 6),
            _rowOxplayerButton(
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
            _rowOxplayerButton(
              onPressed: () => unawaited(_startDownload(context)),
              child: const Icon(Icons.refresh, color: Colors.redAccent),
            ),
            ..._debugInfoSuffix(context),
          ],
        ),
    };
  }

  Future<void> _startDownload(BuildContext context) async {
    if (!_fileMayBeDownloadable(file)) {
      _itemLog(
        'SingleItemScreen: startDownload blocked for file=${file.id}',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This file is not downloadable yet.')),
      );
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

  Future<void> _play(BuildContext context, String path) async {
    if (!context.mounted) return;
    final cfg = ref.read(appConfigProvider);
    final auth = ref.read(authNotifierProvider);
    final ok = await InternalPlayer.playLocalFile(
      path: path,
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

  Future<void> _stream(BuildContext context, WidgetRef ref) async {
    if (!file.canStream) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Streaming is not available for this file.')),
      );
      return;
    }
    final cleanupDecision = await queryStorageCleanupDecision();
    if (cleanupDecision.cleanupMode) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Low storage detected. Cleaning cache...')),
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
    final api = ref.read(oxplayerApiServiceProvider);
    final Uri? url;
    try {
      url = await _openStreamUrlForFile(
        context: context,
        ref: ref,
        targetFile: file,
      );
    } catch (e, st) {
      _itemLog('SingleItemScreen: stream open failed: $e\n$st');
      final token = auth.apiAccessToken;
      if (token == null || token.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not start stream. Please try again.'),
            ),
          );
        }
        return;
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recovering file, please wait...')),
        );
      }
      final recovered = await api.recoverMediaFileFromBackup(
        config: cfg,
        accessToken: token,
        mediaFileId: file.id,
      );
      if (!recovered) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('This file is currently unavailable.')),
          );
        }
        return;
      }
      final freshFile = await _reloadLatestFileLocator(ref);
      if (freshFile == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('This file is currently unavailable.')),
          );
        }
        return;
      }
      if (!context.mounted) return;
      final retriedUrl = await _openStreamUrlForFile(
        context: context,
        ref: ref,
        targetFile: freshFile,
      );
      if (retriedUrl == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('This file is currently unavailable.')),
          );
        }
        return;
      }
      if (!context.mounted) return;
      final retryOk = await InternalPlayer.playHttpUrl(
        url: retriedUrl.toString(),
        title: downloadTitle,
        mediaTitle: media.title,
        releaseYear: media.releaseYear,
        season: freshFile.season,
        episode: freshFile.episode,
        isSeries: isSeriesMedia,
        imdbId: media.imdbId,
        tmdbId: media.tmdbId,
        subdlApiKey: cfg.subdlApiKey,
        metadataSubtitle: _seasonEpisodeLine(isSeriesMedia, freshFile),
        preferredSubtitleLanguage: auth.preferredSubtitleLanguage,
        apiAccessToken: auth.apiAccessToken,
        apiBaseUrl: cfg.apiBaseUrl,
      );
      if (!retryOk && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open internal player.')),
        );
      }
      return;
    }
    if (url == null) {
      final reason = TelegramRangePlayback.instance.lastOpenFailureReason;
      _itemLog('SingleItemScreen: stream open returned null reason=$reason');
      if (reason == 'resolve_failed') {
        final token = auth.apiAccessToken;
        if (token != null && token.isNotEmpty) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Recovering file, please wait...')),
            );
          }
          final recovered = await api.recoverMediaFileFromBackup(
            config: cfg,
            accessToken: token,
            mediaFileId: file.id,
          );
          if (recovered) {
            final freshFile = await _reloadLatestFileLocator(ref);
            if (freshFile != null && context.mounted) {
              final retriedUrl = await _openStreamUrlForFile(
                context: context,
                ref: ref,
                targetFile: freshFile,
              );
              if (retriedUrl != null) {
                final retryOk = await InternalPlayer.playHttpUrl(
                  url: retriedUrl.toString(),
                  title: downloadTitle,
                  mediaTitle: media.title,
                  releaseYear: media.releaseYear,
                  season: freshFile.season,
                  episode: freshFile.episode,
                  isSeries: isSeriesMedia,
                  imdbId: media.imdbId,
                  tmdbId: media.tmdbId,
                  subdlApiKey: cfg.subdlApiKey,
                  metadataSubtitle: _seasonEpisodeLine(isSeriesMedia, freshFile),
                  preferredSubtitleLanguage: auth.preferredSubtitleLanguage,
                  apiAccessToken: auth.apiAccessToken,
                  apiBaseUrl: cfg.apiBaseUrl,
                );
                if (!retryOk && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Could not open internal player.')),
                  );
                }
                return;
              }
            }
          }
        }
      }
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

  Future<Uri?> _openStreamUrlForFile({
    required BuildContext context,
    required WidgetRef ref,
    required AppMediaFile targetFile,
  }) async {
    final tdlib = ref.read(tdlibFacadeProvider);
    final cfg = ref.read(appConfigProvider);
    final auth = ref.read(authNotifierProvider);
    final api = ref.read(oxplayerApiServiceProvider);
    AppMediaFile effectiveFile = targetFile;
    try {
      final fresh = await _reloadLatestFileLocator(ref);
      if (fresh != null && fresh.id == targetFile.id) {
        effectiveFile = fresh;
      }
    } catch (_) {}
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
        if (!allowed.contains(reason)) {
          _itemLog(
            'SingleItemScreen: skip locatorSync reason=$reason '
            'baseType=$baseType chat=${resolved.locatorChatId} msg=$resolvedMsg',
          );
          return;
        }
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

  Future<AppMediaFile?> _reloadLatestFileLocator(WidgetRef ref) async {
    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) return null;
    final cfg = ref.read(appConfigProvider);
    final api = ref.read(oxplayerApiServiceProvider);
    final detail = await api.fetchLibraryMediaDetail(
      config: cfg,
      accessToken: token,
      mediaId: media.id,
    );
    if (detail == null) return null;
    for (final f in detail.files) {
      if (f.id == file.id) return f;
    }
    return null;
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
  r.writeln(
      'file.mime/telegram: telegramFileId set=${(file.telegramFileId ?? '').isNotEmpty}');
  r.writeln('locatorType: ${file.locatorType}');
  r.writeln(
      'locatorChatId/messageId: ${file.locatorChatId} / ${file.locatorMessageId}');
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
  r.writeln(
      'basenameWithoutExtension: ${p.basenameWithoutExtension(localPath)}');

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
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String? _subtitleLabel(AppMediaFile file) {
  if (!file.subtitleMentioned) return null;
  final raw = (file.subtitlePresentation ?? '').trim().toLowerCase();
  final kind = raw == 'hardsub' || raw == 'softsub' ? raw : 'sub';
  final lang = (file.subtitleLanguage ?? '').trim().toUpperCase();
  return lang.isEmpty
      ? 'SUB: ${kind.toUpperCase()}'
      : 'SUB: ${kind.toUpperCase()} $lang';
}

String? _captionPreview(String? rawCaption) {
  if (rawCaption == null) return null;
  final compact = rawCaption
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  if (compact.isEmpty) return null;
  return compact;
}

String? _firstCaptionAmongFiles(List<AppMediaFile> files) {
  for (final f in files) {
    final c = _captionPreview(f.captionText);
    if (c != null && c.trim().isNotEmpty) return c.trim();
  }
  return null;
}
