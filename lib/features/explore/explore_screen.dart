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
  final List<FocusNode> _gridFocusNodes = <FocusNode>[];
  final List<FocusNode> _genreChipFocusNodes = <FocusNode>[];

  Timer? _searchDebounce;
  List<ExploreCatalogItem> _items = const [];
  List<ExploreGenreRow> _exploreGenres = const [];
  String? _nextCursor;
  bool _end = false;
  bool _loadingInitial = true;
  bool _loadingMore = false;
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
    _scrollController.addListener(_onScroll);
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
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _sidebarScrollController.dispose();
    _searchController.removeListener(_onSearchTextChanged);
    _searchController.dispose();
    _backFocusNode.dispose();
    _searchShellFocusNode.dispose();
    _genreAllFocusNode.dispose();
    _genreMoreFocusNode.dispose();
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

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels < pos.maxScrollExtent - 720) return;
    if (_loadingMore || _loadingInitial || _end || _nextCursor == null) {
      return;
    }
    unawaited(_loadNextPage());
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
        _items.isNotEmpty &&
        !_loadingInitial) {
      return;
    }
    setState(() {
      _activeQuery = q;
      _activeGenreId = g;
      _items = const [];
      _nextCursor = null;
      _end = false;
      _loadingInitial = true;
      _lastLoadError = '';
    });
    _resizeGridFocus(0);
    if (!_scrollController.hasClients) {
      await Future<void>.delayed(Duration.zero);
    }
    _scrollController.jumpTo(0);
    await _fetchPage(append: false);
  }

  Future<void> _loadFirstPage() async {
    if (mounted) {
      setState(() {
        _activeQuery = _searchController.text.trim();
        _activeGenreId = _selectedGenreId;
      });
    }
    await _fetchPage(append: false);
  }

  Future<void> _reloadCatalogAfterLibrarySync() async {
    final q = _searchController.text.trim();
    final g = _selectedGenreId;
    setState(() {
      _activeQuery = q;
      _activeGenreId = g;
      _items = const [];
      _nextCursor = null;
      _end = false;
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
    await _fetchPage(append: false);
    unawaited(_loadGenres());
  }

  Future<void> _loadNextPage() => _fetchPage(append: true);

  Future<void> _fetchPage({required bool append}) async {
    if (_loadingMore && append) return;
    if (append) {
      setState(() => _loadingMore = true);
    } else {
      setState(() {
        _loadingInitial = true;
        _lastLoadError = '';
      });
    }

    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) {
      if (mounted) {
        setState(() {
          _loadingInitial = false;
          _loadingMore = false;
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
        cursor: append ? _nextCursor : null,
        genreId: _activeGenreId,
      );
      if (!mounted) return;
      setState(() {
        if (append) {
          _items = [..._items, ...page.items];
        } else {
          _items = List.of(page.items);
        }
        _nextCursor = page.nextCursor;
        _end = page.nextCursor == null || page.items.isEmpty;
        _loadingInitial = false;
        _loadingMore = false;
      });
      _resizeGridFocus(_items.length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingInitial = false;
        _loadingMore = false;
        _lastLoadError = 'Could not load catalog: $e';
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

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(exploreCatalogRefreshGenerationProvider, (previous, next) {
      if (previous == null || previous == next) return;
      unawaited(_reloadCatalogAfterLibrarySync());
    });

    final visible = _genresVisible;

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(20),
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
                            : '${_items.length} title${_items.length == 1 ? '' : 's'}',
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
                    child: _loadingInitial && _items.isEmpty
                        ? const Center(child: CircularProgressIndicator())
                        : _items.isEmpty
                            ? const Center(
                                child: Text(
                                  'No titles match your filters.',
                                  style: TextStyle(color: AppColors.textMuted),
                                ),
                              )
                            : Stack(
                                children: [
                                  GridView.builder(
                                    controller: _scrollController,
                                    cacheExtent: 1800,
                                    gridDelegate:
                                        const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: _gridColumns,
                                      childAspectRatio: 0.66,
                                      crossAxisSpacing: 14,
                                      mainAxisSpacing: 14,
                                    ),
                                    itemCount: _items.length,
                                    itemBuilder: (context, index) {
                                      final item = _items[index];
                                      final poster =
                                          _posterUrl(item.posterPath) ?? '';
                                      return TVButton(
                                        focusNode: _gridFocusNodes[index],
                                        onPressed: () {
                                          context.push(
                                            '/item/${Uri.encodeComponent(item.id)}',
                                          );
                                        },
                                        padding: EdgeInsets.zero,
                                        child: Card(
                                          clipBehavior: Clip.antiAlias,
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              Expanded(
                                                child: poster.isEmpty
                                                    ? Container(
                                                        color: Colors.black26,
                                                        alignment:
                                                            Alignment.center,
                                                        child: const Icon(
                                                          Icons.movie,
                                                          size: 42,
                                                        ),
                                                      )
                                                    : CachedNetworkImage(
                                                        imageUrl: poster,
                                                        fit: BoxFit.cover,
                                                        placeholder: (_, __) =>
                                                            const Center(
                                                          child:
                                                              CircularProgressIndicator(),
                                                        ),
                                                        errorWidget:
                                                            (_, __, ___) =>
                                                                const Center(
                                                          child: Icon(
                                                            Icons.broken_image,
                                                          ),
                                                        ),
                                                      ),
                                              ),
                                              Padding(
                                                padding:
                                                    const EdgeInsets.all(10),
                                                child: Text(
                                                  item.title,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                  if (_loadingMore)
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      bottom: 12,
                                      child: Center(
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color: AppColors.card,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            border: Border.all(
                                              color: AppColors.border,
                                            ),
                                          ),
                                          child: const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              SizedBox(
                                                width: 18,
                                                height: 18,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                ),
                                              ),
                                              SizedBox(width: 10),
                                              Text('Loading more…'),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
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
