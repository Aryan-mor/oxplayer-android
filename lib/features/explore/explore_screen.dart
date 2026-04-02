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

class ExploreScreen extends ConsumerStatefulWidget {
  const ExploreScreen({super.key});

  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends ConsumerState<ExploreScreen> {
  static const int _gridColumns = 5;

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _backFocusNode = FocusNode(debugLabel: 'ExploreBack');
  /// Shell focus for search row (D-pad lands here before typing).
  final FocusNode _searchShellFocusNode =
      FocusNode(debugLabel: 'ExploreSearchShell');
  final List<FocusNode> _gridFocusNodes = <FocusNode>[];

  Timer? _searchDebounce;
  List<ExploreCatalogItem> _items = const [];
  String? _nextCursor;
  bool _end = false;
  bool _loadingInitial = true;
  bool _loadingMore = false;
  String _activeQuery = '';
  String _lastLoadError = '';

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _searchController.addListener(_onSearchTextChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadFirstPage());
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.removeListener(_onSearchTextChanged);
    _searchController.dispose();
    _backFocusNode.dispose();
    _searchShellFocusNode.dispose();
    for (final n in _gridFocusNodes) {
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

  Future<void> _restartCatalogFromSearch() async {
    final q = _searchController.text.trim();
    if (q == _activeQuery && _items.isNotEmpty && !_loadingInitial) {
      return;
    }
    setState(() {
      _activeQuery = q;
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
      setState(() => _activeQuery = _searchController.text.trim());
    }
    await _fetchPage(append: false);
  }

  /// After library sync, always refetch page 1 (same query) so new catalog titles appear.
  Future<void> _reloadCatalogAfterLibrarySync() async {
    final q = _searchController.text.trim();
    setState(() {
      _activeQuery = q;
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

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                TVButton(
                  focusNode: _backFocusNode,
                  autofocus: true,
                  onPressed: () => context.pop(),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.arrow_back_rounded, color: Colors.white),
                      SizedBox(width: 8),
                      Text('Back'),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
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
            const SizedBox(height: 14),
            TVSearchField(
              focusNode: _searchShellFocusNode,
              controller: _searchController,
              hintText: 'Search title, IMDb, or TMDB id…',
              onSubmitted: (_) {
                _searchDebounce?.cancel();
                unawaited(_restartCatalogFromSearch());
              },
            ),
            if (_lastLoadError.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _lastLoadError,
                style: const TextStyle(color: Colors.redAccent, fontSize: 14),
              ),
            ],
            const SizedBox(height: 14),
            Expanded(
              child: _loadingInitial && _items.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : _items.isEmpty
                      ? const Center(
                          child: Text(
                            'No titles match your search.',
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
                                final poster = _posterUrl(item.posterPath) ?? '';
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
                                                  alignment: Alignment.center,
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
                                                  errorWidget: (_, __, ___) =>
                                                      const Center(
                                                    child: Icon(
                                                      Icons.broken_image,
                                                    ),
                                                  ),
                                                ),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.all(10),
                                          child: Text(
                                            item.title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
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
                                      borderRadius: BorderRadius.circular(8),
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
                                          child: CircularProgressIndicator(
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
    );
  }
}
