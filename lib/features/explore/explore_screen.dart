import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tv_button.dart';
import '../../core/theme/tv_search_field.dart';
import '../../data/api/tv_app_api_service.dart';
import '../../providers.dart';

/// First screenful of genre chips before "+n" expands the rest.
const int _kGenrePreviewCount = 10;

/// Matches API default [/me/explore/media] page size.
const int _kExplorePageSize = 20;

class ExploreScreen extends ConsumerStatefulWidget {
  const ExploreScreen({super.key, this.initialGenreId});

  /// From `/explore?genreId=` — pre-selected TMDB-linked genre (DB id).
  final String? initialGenreId;

  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends ConsumerState<ExploreScreen> {
  static const int _gridColumns = 5;

  final ScrollController _scrollController = ScrollController();
  final ScrollController _sidebarScrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _backFocusNode = FocusNode(debugLabel: 'ExploreBack');
  final FocusNode _searchShellFocusNode =
      FocusNode(debugLabel: 'ExploreSearchShell');
  final FocusNode _genreAllFocusNode = FocusNode(debugLabel: 'ExploreGenreAll');
  final FocusNode _genreMoreFocusNode = FocusNode(debugLabel: 'ExploreGenreMore');
  final FocusNode _showMoreAvailableFocusNode =
      FocusNode(debugLabel: 'ExploreShowMoreAvailable');
  final FocusNode _showMorePendingFocusNode =
      FocusNode(debugLabel: 'ExploreShowMorePending');
  final FocusNode _showMoreTmdbFocusNode =
      FocusNode(debugLabel: 'ExploreShowMoreTmdb');
  final List<FocusNode> _gridFocusNodes = <FocusNode>[];
  final List<FocusNode> _genreChipFocusNodes = <FocusNode>[];

  Timer? _searchDebounce;
  List<ExploreCatalogItem> _items = const [];
  List<ExploreCatalogItem> _pendingItems = const [];
  List<ExploreTmdbItem> _tmdbItems = const [];
  List<ExploreGenreRow> _exploreGenres = const [];
  String? _nextCursor;
  String? _pendingNextCursor;
  String? _busyTmdbKey;
  bool _tmdbHasMore = false;
  /// Next TMDB API page to request for “Show more” (1 after initial load consumed page 1).
  int _tmdbFetchPage = 1;
  bool _loadingInitial = true;
  bool _loadingMoreAvailable = false;
  bool _loadingMorePending = false;
  bool _loadingMoreTmdb = false;
  String _activeQuery = '';
  String? _activeGenreId;
  String? _selectedGenreId;
  bool _genresExpanded = false;
  bool _loadingGenres = true;
  String _genresLoadError = '';
  String _lastLoadError = '';

  @override
  void initState() {
    super.initState();
    _selectedGenreId = _normalizeGenreId(widget.initialGenreId);
    _activeGenreId = _selectedGenreId;
    _searchController.addListener(_onSearchTextChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadGenres());
      unawaited(_loadFirstPage());
    });
  }

  @override
  void didUpdateWidget(covariant ExploreScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _normalizeGenreId(widget.initialGenreId);
    final prev = _normalizeGenreId(oldWidget.initialGenreId);
    if (next != prev) {
      setState(() {
        _selectedGenreId = next;
        _activeGenreId = next;
      });
      unawaited(_restartCatalogFromSearch());
    }
  }

  String? _normalizeGenreId(String? raw) {
    final t = raw?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollController.dispose();
    _sidebarScrollController.dispose();
    _searchController.removeListener(_onSearchTextChanged);
    _searchController.dispose();
    _backFocusNode.dispose();
    _searchShellFocusNode.dispose();
    _genreAllFocusNode.dispose();
    _genreMoreFocusNode.dispose();
    _showMoreAvailableFocusNode.dispose();
    _showMorePendingFocusNode.dispose();
    _showMoreTmdbFocusNode.dispose();
    for (final n in _gridFocusNodes) {
      n.dispose();
    }
    for (final n in _genreChipFocusNodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _onSearchTextChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      unawaited(_restartCatalogFromSearch());
    });
  }

  void _resizeGridFocus(int count) {
    while (_gridFocusNodes.length < count) {
      _gridFocusNodes.add(
        FocusNode(debugLabel: 'ExploreGrid${_gridFocusNodes.length}'),
      );
    }
    while (_gridFocusNodes.length > count) {
      _gridFocusNodes.removeLast().dispose();
    }
  }

  void _resizeGenreChipFocus(int count) {
    while (_genreChipFocusNodes.length < count) {
      _genreChipFocusNodes.add(
        FocusNode(
          debugLabel: 'ExploreGenreChip${_genreChipFocusNodes.length}',
        ),
      );
    }
    while (_genreChipFocusNodes.length > count) {
      _genreChipFocusNodes.removeLast().dispose();
    }
  }

  List<ExploreGenreRow> get _genresVisible {
    if (_exploreGenres.length <= _kGenrePreviewCount || _genresExpanded) {
      return _exploreGenres;
    }
    return _exploreGenres.take(_kGenrePreviewCount).toList(growable: false);
  }

  bool get _showMoreGenres =>
      !_genresExpanded && _exploreGenres.length > _kGenrePreviewCount;

  int get _moreGenresCount => _exploreGenres.length - _kGenrePreviewCount;

  Future<void> _loadGenres() async {
    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) {
      if (mounted) {
        setState(() {
          _loadingGenres = false;
          _genresLoadError = 'Not signed in.';
        });
      }
      return;
    }
    try {
      final config = ref.read(appConfigProvider);
      final api = ref.read(tvAppApiServiceProvider);
      final list = await api.fetchExploreGenres(
        config: config,
        accessToken: token,
      );
      if (!mounted) return;
      setState(() {
        _exploreGenres = list;
        _loadingGenres = false;
        _genresLoadError = '';
      });
      _resizeGenreChipFocus(_genresVisible.length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingGenres = false;
        _genresLoadError = 'Could not load genres: $e';
      });
    }
  }

  Future<void> _restartCatalogFromSearch() async {
    final q = _searchController.text.trim();
    final g = _selectedGenreId;
    if (q == _activeQuery &&
        g == _activeGenreId &&
        (_items.isNotEmpty ||
            _pendingItems.isNotEmpty ||
            _tmdbItems.isNotEmpty) &&
        !_loadingInitial) {
      return;
    }
    setState(() {
      _activeQuery = q;
      _activeGenreId = g;
      _items = const [];
      _pendingItems = const [];
      _tmdbItems = const [];
      _nextCursor = null;
      _pendingNextCursor = null;
      _busyTmdbKey = null;
      _tmdbHasMore = false;
      _tmdbFetchPage = 1;
      _loadingInitial = true;
      _lastLoadError = '';
    });
    _resizeGridFocus(0);
    if (!_scrollController.hasClients) {
      await Future<void>.delayed(Duration.zero);
    }
    _scrollController.jumpTo(0);
    await _fetchFullCatalog();
  }

  Future<void> _loadFirstPage() async {
    if (mounted) {
      setState(() {
        _activeQuery = _searchController.text.trim();
        _activeGenreId = _selectedGenreId;
      });
    }
    await _fetchFullCatalog();
  }

  Future<void> _reloadCatalogAfterLibrarySync() async {
    final q = _searchController.text.trim();
    final g = _selectedGenreId;
    setState(() {
      _activeQuery = q;
      _activeGenreId = g;
      _items = const [];
      _pendingItems = const [];
      _tmdbItems = const [];
      _nextCursor = null;
      _pendingNextCursor = null;
      _busyTmdbKey = null;
      _tmdbHasMore = false;
      _tmdbFetchPage = 1;
      _loadingInitial = true;
      _lastLoadError = '';
    });
    _resizeGridFocus(0);
    if (!_scrollController.hasClients) {
      await Future<void>.delayed(Duration.zero);
    }
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    await _fetchFullCatalog();
    unawaited(_loadGenres());
  }

  Future<void> _fetchFullCatalog() async {
    setState(() {
      _loadingInitial = true;
      _lastLoadError = '';
    });

    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) {
      if (mounted) {
        setState(() {
          _loadingInitial = false;
          _lastLoadError = 'Not signed in.';
        });
      }
      return;
    }

    try {
      final config = ref.read(appConfigProvider);
      final api = ref.read(tvAppApiServiceProvider);
      final page = await api.fetchExploreCatalogPage(
        config: config,
        accessToken: token,
        query: _activeQuery,
        genreId: _activeGenreId,
        limit: _kExplorePageSize,
        tmdbPage: 1,
      );
      if (!mounted) return;
      setState(() {
        _items = List.of(page.items);
        _pendingItems = List.of(page.pendingItems);
        _tmdbItems = List.of(page.tmdbItems);
        _nextCursor = page.nextCursor;
        _pendingNextCursor = page.pendingNextCursor;
        _tmdbHasMore = page.tmdbHasMore;
        _tmdbFetchPage = page.tmdbHasMore ? 2 : 1;
        _loadingInitial = false;
      });
      _resizeGridFocus(
        _items.length + _pendingItems.length + _tmdbItems.length,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingInitial = false;
        _lastLoadError = 'Could not load catalog: $e';
      });
    }
  }

  Future<void> _appendAvailable() async {
    final c = _nextCursor;
    if (c == null || c.isEmpty || _loadingMoreAvailable) return;
    setState(() => _loadingMoreAvailable = true);
    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) {
      if (mounted) setState(() => _loadingMoreAvailable = false);
      return;
    }
    try {
      final config = ref.read(appConfigProvider);
      final api = ref.read(tvAppApiServiceProvider);
      final page = await api.fetchExploreCatalogPage(
        config: config,
        accessToken: token,
        query: _activeQuery,
        cursor: c,
        genreId: _activeGenreId,
        limit: _kExplorePageSize,
        section: 'available',
      );
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...page.items];
        _nextCursor = page.nextCursor;
        _loadingMoreAvailable = false;
      });
      _resizeGridFocus(
        _items.length + _pendingItems.length + _tmdbItems.length,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMoreAvailable = false;
        _lastLoadError = 'Could not load more: $e';
      });
    }
  }

  Future<void> _appendPending() async {
    final c = _pendingNextCursor;
    if (c == null || c.isEmpty || _loadingMorePending) return;
    setState(() => _loadingMorePending = true);
    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) {
      if (mounted) setState(() => _loadingMorePending = false);
      return;
    }
    try {
      final config = ref.read(appConfigProvider);
      final api = ref.read(tvAppApiServiceProvider);
      final page = await api.fetchExploreCatalogPage(
        config: config,
        accessToken: token,
        query: _activeQuery,
        pendingCursor: c,
        genreId: _activeGenreId,
        limit: _kExplorePageSize,
        section: 'pending',
      );
      if (!mounted) return;
      setState(() {
        _pendingItems = [..._pendingItems, ...page.pendingItems];
        _pendingNextCursor = page.pendingNextCursor;
        _loadingMorePending = false;
      });
      _resizeGridFocus(
        _items.length + _pendingItems.length + _tmdbItems.length,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMorePending = false;
        _lastLoadError = 'Could not load more: $e';
      });
    }
  }

  Future<void> _appendTmdb() async {
    if (!_tmdbHasMore || _loadingMoreTmdb) return;
    setState(() => _loadingMoreTmdb = true);
    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) {
      if (mounted) setState(() => _loadingMoreTmdb = false);
      return;
    }
    try {
      final config = ref.read(appConfigProvider);
      final api = ref.read(tvAppApiServiceProvider);
      final page = await api.fetchExploreCatalogPage(
        config: config,
        accessToken: token,
        query: _activeQuery,
        genreId: _activeGenreId,
        limit: _kExplorePageSize,
        section: 'tmdb',
        tmdbPage: _tmdbFetchPage,
      );
      if (!mounted) return;
      setState(() {
        _tmdbItems = [..._tmdbItems, ...page.tmdbItems];
        _tmdbHasMore = page.tmdbHasMore;
        if (page.tmdbHasMore) {
          _tmdbFetchPage += 1;
        }
        _loadingMoreTmdb = false;
      });
      _resizeGridFocus(
        _items.length + _pendingItems.length + _tmdbItems.length,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMoreTmdb = false;
        _lastLoadError = 'Could not load more: $e';
      });
    }
  }

  void _onSelectGenre(String? id) {
    setState(() => _selectedGenreId = id);
    _searchDebounce?.cancel();
    unawaited(_restartCatalogFromSearch());
  }

  void _toggleGenresExpanded() {
    setState(() => _genresExpanded = !_genresExpanded);
    _resizeGenreChipFocus(_genresVisible.length);
  }

  String? _posterUrl(String? posterPath) {
    final value = (posterPath ?? '').trim();
    if (value.isEmpty) return null;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    if (value.startsWith('/')) return 'https://image.tmdb.org/t/p/w500$value';
    return value;
  }

  Widget _sectionTitle(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 18, 0, 10),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }

  /// TMDB block is always its own section; label reflects search vs genre filter.
  String _tmdbSectionLabel() {
    String? genreName;
    final gid = _activeGenreId;
    if (gid != null && gid.isNotEmpty) {
      for (final g in _exploreGenres) {
        if (g.id == gid) {
          genreName = g.title;
          break;
        }
      }
    }
    final q = _activeQuery.trim();
    if (q.isNotEmpty && genreName != null) {
      return 'TMDB search · $genreName';
    }
    if (q.isNotEmpty) {
      return 'TMDB search results';
    }
    if (genreName != null) {
      return 'TMDB · $genreName';
    }
    return 'Popular on TMDB';
  }

  Widget _showMoreSliver({
    required bool visible,
    required bool loading,
    required VoidCallback onPressed,
    required FocusNode focusNode,
  }) {
    if (!visible) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 6, 0, 20),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TVButton(
            focusNode: focusNode,
            enabled: !loading,
            onPressed: onPressed,
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
            child: loading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Show more'),
          ),
        ),
      ),
    );
  }

  Widget _catalogPosterTile({
    required BuildContext context,
    required ExploreCatalogItem item,
    required FocusNode focusNode,
  }) {
    final poster = _posterUrl(item.posterPath) ?? '';
    return TVButton(
      focusNode: focusNode,
      onPressed: () {
        context.push('/item/${Uri.encodeComponent(item.id)}');
      },
      padding: EdgeInsets.zero,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: poster.isEmpty
                  ? Container(
                      color: Colors.black26,
                      alignment: Alignment.center,
                      child: const Icon(Icons.movie, size: 42),
                    )
                  : CachedNetworkImage(
                      imageUrl: poster,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => const Center(
                        child: CircularProgressIndicator(),
                      ),
                      errorWidget: (_, __, ___) => const Center(
                        child: Icon(Icons.broken_image),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tmdbPosterTile({
    required BuildContext context,
    required ExploreTmdbItem item,
    required FocusNode focusNode,
  }) {
    final poster = _posterUrl(item.posterPath) ?? '';
    final busy = _busyTmdbKey == item.tmdbKey;
    return TVButton(
      focusNode: focusNode,
      enabled: !busy,
      onPressed: () => unawaited(_onTmdbItemPressed(context, item)),
      padding: EdgeInsets.zero,
      child: Card(
        clipBehavior: Clip.antiAlias,
        color: AppColors.card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (poster.isEmpty)
                    Container(
                      color: Colors.black26,
                      alignment: Alignment.center,
                      child: const Icon(Icons.movie_creation_outlined, size: 42),
                    )
                  else
                    CachedNetworkImage(
                      imageUrl: poster,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => const Center(
                        child: CircularProgressIndicator(),
                      ),
                      errorWidget: (_, __, ___) => const Center(
                        child: Icon(Icons.broken_image),
                      ),
                    ),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        item.type == 'SERIES' ? 'TV' : 'TMDB',
                        style: const TextStyle(fontSize: 10, color: Colors.white),
                      ),
                    ),
                  ),
                  if (busy)
                    Container(
                      color: Colors.black45,
                      alignment: Alignment.center,
                      child: const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onTmdbItemPressed(BuildContext context, ExploreTmdbItem item) async {
    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) return;
    setState(() => _busyTmdbKey = item.tmdbKey);
    try {
      final config = ref.read(appConfigProvider);
      final api = ref.read(tvAppApiServiceProvider);
      final mediaId = await api.exploreEnsureMediaFromTmdb(
        config: config,
        accessToken: token,
        tmdbKey: item.tmdbKey,
      );
      if (!context.mounted) return;
      unawaited(
        context.push('/item/${Uri.encodeComponent(mediaId)}'),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add title: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busyTmdbKey = null);
      }
    }
  }

  Widget _buildExploreCatalogBody(BuildContext context) {
    final total = _items.length + _pendingItems.length + _tmdbItems.length;
    final showTmdbChrome = _tmdbItems.isNotEmpty || _tmdbHasMore;

    if (_loadingInitial && total == 0) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_loadingInitial && total == 0 && !showTmdbChrome) {
      return const Center(
        child: Text(
          'No titles match your filters.',
          style: TextStyle(color: AppColors.textMuted),
        ),
      );
    }

    const gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: _gridColumns,
      childAspectRatio: 0.66,
      crossAxisSpacing: 14,
      mainAxisSpacing: 14,
    );

    var focusBase = 0;
    final slivers = <Widget>[];

    if (_items.isNotEmpty) {
      slivers.add(SliverToBoxAdapter(child: _sectionTitle('Available')));
      final fb = focusBase;
      slivers.add(
        SliverGrid(
          gridDelegate: gridDelegate,
          delegate: SliverChildBuilderDelegate(
            (ctx, i) => _catalogPosterTile(
              context: ctx,
              item: _items[i],
              focusNode: _gridFocusNodes[fb + i],
            ),
            childCount: _items.length,
          ),
        ),
      );
      focusBase += _items.length;
      slivers.add(
        _showMoreSliver(
          visible: _nextCursor != null && _nextCursor!.isNotEmpty,
          loading: _loadingMoreAvailable,
          focusNode: _showMoreAvailableFocusNode,
          onPressed: () => unawaited(_appendAvailable()),
        ),
      );
    }

    if (_pendingItems.isNotEmpty) {
      slivers.add(SliverToBoxAdapter(child: _sectionTitle('Requested titles')));
      final fb = focusBase;
      slivers.add(
        SliverGrid(
          gridDelegate: gridDelegate,
          delegate: SliverChildBuilderDelegate(
            (ctx, i) => _catalogPosterTile(
              context: ctx,
              item: _pendingItems[i],
              focusNode: _gridFocusNodes[fb + i],
            ),
            childCount: _pendingItems.length,
          ),
        ),
      );
      focusBase += _pendingItems.length;
      slivers.add(
        _showMoreSliver(
          visible: _pendingNextCursor != null && _pendingNextCursor!.isNotEmpty,
          loading: _loadingMorePending,
          focusNode: _showMorePendingFocusNode,
          onPressed: () => unawaited(_appendPending()),
        ),
      );
    }

    if (showTmdbChrome) {
      slivers.add(
        SliverToBoxAdapter(child: _sectionTitle(_tmdbSectionLabel())),
      );
      if (_tmdbItems.isNotEmpty) {
        final fb = focusBase;
        slivers.add(
          SliverGrid(
            gridDelegate: gridDelegate,
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => _tmdbPosterTile(
                context: ctx,
                item: _tmdbItems[i],
                focusNode: _gridFocusNodes[fb + i],
              ),
              childCount: _tmdbItems.length,
            ),
          ),
        );
        focusBase += _tmdbItems.length;
      }
      slivers.add(
        _showMoreSliver(
          visible: _tmdbHasMore,
          loading: _loadingMoreTmdb,
          focusNode: _showMoreTmdbFocusNode,
          onPressed: () => unawaited(_appendTmdb()),
        ),
      );
    }

    return CustomScrollView(
      controller: _scrollController,
      cacheExtent: 1800,
      slivers: slivers,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(exploreCatalogRefreshGenerationProvider, (previous, next) {
      if (previous == null || previous == next) return;
      unawaited(_reloadCatalogAfterLibrarySync());
    });

    final visible = _genresVisible;

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + AppLayout.screenBottomInset,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 300,
              child: FocusTraversalGroup(
                policy: OrderedTraversalPolicy(),
                child: Scrollbar(
                  controller: _sidebarScrollController,
                  thumbVisibility: true,
                  child: ListView(
                    controller: _sidebarScrollController,
                    primary: false,
                    children: [
                      TVButton(
                        focusNode: _backFocusNode,
                        autofocus: true,
                        onPressed: () => context.pop(),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.arrow_back_rounded, color: Colors.white),
                            SizedBox(width: 8),
                            Text('Back'),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Search & genres',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TVSearchField(
                        focusNode: _searchShellFocusNode,
                        controller: _searchController,
                        hintText: 'Title, IMDb, TMDB id…',
                        onSubmitted: (_) {
                          _searchDebounce?.cancel();
                          unawaited(_restartCatalogFromSearch());
                        },
                      ),
                      if (_genresLoadError.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          _genresLoadError,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      if (_loadingGenres)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        )
                      else if (_exploreGenres.isNotEmpty)
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            TVButton(
                              focusNode: _genreAllFocusNode,
                              selected: _selectedGenreId == null,
                              borderRadius: 999,
                              onPressed: () => _onSelectGenre(null),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              child: const Text(
                                'All',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            for (var i = 0; i < visible.length; i++)
                              _GenreFilterButton(
                                focusNode: _genreChipFocusNodes[i],
                                row: visible[i],
                                selected: _selectedGenreId == visible[i].id,
                                onPressed: () => _onSelectGenre(visible[i].id),
                              ),
                            if (_showMoreGenres)
                              TVButton(
                                focusNode: _genreMoreFocusNode,
                                borderRadius: 999,
                                onPressed: _toggleGenresExpanded,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                child: Text(
                                  '+$_moreGenresCount',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Explore',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _loadingInitial
                            ? 'Loading…'
                            : '${_items.length + _pendingItems.length + _tmdbItems.length} '
                                'title${_items.length + _pendingItems.length + _tmdbItems.length == 1 ? '' : 's'}',
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    ],
                  ),
                  if (_lastLoadError.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      _lastLoadError,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 14,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Expanded(
                    child: _buildExploreCatalogBody(context),
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

class _GenreFilterButton extends StatelessWidget {
  const _GenreFilterButton({
    required this.focusNode,
    required this.row,
    required this.selected,
    required this.onPressed,
  });

  final FocusNode focusNode;
  final ExploreGenreRow row;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TVButton(
      focusNode: focusNode,
      selected: selected,
      borderRadius: 999,
      onPressed: onPressed,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              row.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: Colors.white,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${row.mediaCount}',
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}
