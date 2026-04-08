import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/focus/dpad_navigator.dart';
import '../../core/focus/input_mode_tracker.dart';
import '../../core/focus/focusable_wrapper.dart';
import '../../infrastructure/api/oxplayer_api_service.dart';
import '../../models/app_media.dart';
import '../../providers.dart';
import 'explore_presentation_adapter.dart';

class ExploreScreen extends ConsumerStatefulWidget {
  const ExploreScreen({super.key, this.initialGenreId});

  final String? initialGenreId;

  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends ConsumerState<ExploreScreen> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'explore_search');
  final FocusNode _firstResultFocus = FocusNode(debugLabel: 'explore_first_result');
  List<ExploreCatalogItem> _available = const [];
  List<ExploreCatalogItem> _requested = const [];
  List<ExploreTmdbItem> _tmdb = const [];
  List<ExploreGenreRow> _genres = const [];
  String? _selectedGenre;
  bool _loading = true;
  String _error = '';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _selectedGenre = widget.initialGenreId?.trim().isEmpty == true
        ? null
        : widget.initialGenreId;
    _search.addListener(_onSearchChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadGenres());
      unawaited(_loadCatalog());
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _firstResultFocus.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      unawaited(_loadCatalog());
    });
  }

  Future<void> _loadGenres() async {
    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) return;
    final api = ref.read(oxplayerApiServiceProvider);
    final cfg = ref.read(appConfigProvider);
    try {
      final list = await api.fetchExploreGenres(config: cfg, accessToken: token);
      if (!mounted) return;
      setState(() => _genres = list);
    } catch (_) {}
  }

  Future<void> _loadCatalog() async {
    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'Not signed in.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    final api = ref.read(oxplayerApiServiceProvider);
    final cfg = ref.read(appConfigProvider);
    try {
      final page = await api.fetchExploreCatalogPage(
        config: cfg,
        accessToken: token,
        query: _search.text.trim(),
        genreId: _selectedGenre,
        limit: 20,
      );
      if (!mounted) return;
      setState(() {
        _available = page.items;
        _requested = page.pendingItems;
        _tmdb = page.tmdbItems;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  AppMediaAggregate _toAggregateFromCatalog(ExploreCatalogItem item) {
    return AppMediaAggregate(
      media: AppMedia(
        id: item.id,
        title: item.title,
        type: item.type,
        releaseYear: item.releaseYear,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
      files: const [],
    );
  }

  AppMediaAggregate _toAggregateFromTmdb(ExploreTmdbItem item) {
    return AppMediaAggregate(
      media: AppMedia(
        id: item.tmdbKey,
        title: item.title,
        type: item.type,
        releaseYear: item.releaseYear,
        posterPath: item.posterPath,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
      files: const [],
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(exploreCatalogRefreshGenerationProvider, (_, __) {
      unawaited(_loadCatalog());
    });
    final sections = ExplorePresentationAdapter.buildSections(
      available: _available,
      requested: _requested,
      tmdb: _tmdb,
    );
    return InputModeTracker(
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: SafeArea(
          child: CustomScrollView(
            primary: false,
            slivers: [
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 12),
                  child: Text(
                    'Search',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
                  child: Focus(
                    onKeyEvent: _handleSearchInputKeyEvent,
                    child: TextField(
                      controller: _search,
                      focusNode: _searchFocus,
                      decoration: InputDecoration(
                        hintText: 'Search titles',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _search.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded),
                                onPressed: () => _search.clear(),
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
              if (_genres.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _GenreChip(
                          label: 'All',
                          selected: _selectedGenre == null,
                          onTap: () {
                            setState(() => _selectedGenre = null);
                            unawaited(_loadCatalog());
                          },
                        ),
                        for (final g in _genres)
                          _GenreChip(
                            label: g.title,
                            selected: _selectedGenre == g.id,
                            onTap: () {
                              setState(() => _selectedGenre = g.id);
                              unawaited(_loadCatalog());
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              if (_loading)
                const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
              else if (_error.isNotEmpty)
                SliverFillRemaining(child: Center(child: Text('Failed to load explore: $_error')))
              else if (sections.every((s) => s.count == 0))
                const SliverFillRemaining(
                  child: Center(
                    child: Text('No results found.'),
                  ),
                )
              else
                for (final section in sections)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _buildSectionList(
                        section.id,
                        '${section.title} (${section.count})',
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionList(String sectionId, String title) {
    final List<AppMediaAggregate> items = switch (sectionId) {
      'explore_available' => _available.map(_toAggregateFromCatalog).toList(),
      'explore_requested' => _requested.map(_toAggregateFromCatalog).toList(),
      _ => _tmdb.map(_toAggregateFromTmdb).toList(),
    };
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Text('No titles'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 220,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final item = items[index];
              return SizedBox(
                width: 150,
                child: FocusableWrapper(
                  onSelect: () {
                    if (sectionId == 'explore_tmdb') {
                      if (index < _tmdb.length) {
                        unawaited(_ensureTmdbAndOpen(_tmdb[index].tmdbKey, context));
                      }
                      return;
                    }
                    unawaited(context.push('/item/${Uri.encodeComponent(item.media.id)}'));
                  },
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      if (sectionId == 'explore_tmdb') {
                        if (index < _tmdb.length) {
                          unawaited(_ensureTmdbAndOpen(_tmdb[index].tmdbKey, context));
                        }
                        return;
                      }
                      unawaited(context.push('/item/${Uri.encodeComponent(item.media.id)}'));
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Theme.of(context).colorScheme.outline),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Container(
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.movie_creation_outlined),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              item.media.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  KeyEventResult _handleSearchInputKeyEvent(FocusNode _, KeyEvent event) {
    if (!event.isActionable) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final hasAnyResults = _available.isNotEmpty || _requested.isNotEmpty || _tmdb.isNotEmpty;

    if (key.isDownKey && hasAnyResults && !_loading) {
      _firstResultFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (key.isBackKey) {
      if (_search.text.isNotEmpty) {
        _search.clear();
      } else {
        FocusScope.of(context).unfocus();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}

class _GenreChip extends StatelessWidget {
  const _GenreChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FocusableWrapper(
      disableScale: true,
      borderRadius: 999,
      onSelect: onTap,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2) : Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: selected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outline),
          ),
          child: Text(label),
        ),
      ),
    );
  }
}

extension on _ExploreScreenState {
  Future<void> _ensureTmdbAndOpen(String tmdbKey, BuildContext context) async {
    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) return;
    final api = ref.read(oxplayerApiServiceProvider);
    final cfg = ref.read(appConfigProvider);
    try {
      final mediaId = await api.exploreEnsureMediaFromTmdb(
        config: cfg,
        accessToken: token,
        tmdbKey: tmdbKey,
      );
      if (!context.mounted) return;
      unawaited(context.push('/item/${Uri.encodeComponent(mediaId)}'));
    } catch (_) {}
  }
}


